"""The canonical provisioning-evidence manifest for a production image.

**One deterministic object, and its digest is the commitment.**
``provisioning_evidence_digest`` in an admission record is the SHA-256 of the
exact canonical bytes produced here — not a hash of a directory, a tar archive,
a console transcript, or an unspecified collection of files. Each of those
would let two people compute different digests over the same evidence, which is
the one property a commitment cannot afford.

**Closed schema.** Fifteen fields, no more and no less. A missing field is a
refusal rather than a default, and an unknown field is a refusal rather than
something carried along: an evidence object that can quietly grow is one whose
digest stops meaning what it meant.

**Raw material stays outside.** The SBOM document, the `podman inspect` output,
and the build log are preserved alongside the manifest as forensic evidence,
and are bound into it by digest where they are authority-relevant. Referencing
them by digest rather than by directory membership means the commitment does
not depend on what happens to be sitting next to it.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §27.
"""

from __future__ import annotations

import hashlib
from typing import Any

from tools.capability.execution import canonical_json
from tools.capability.execution.worker import CONTAINER_INTERPRETER

EVIDENCE_SCHEMA_VERSION = 1

# §27: one fixed governed upstream Python. A distribution package revision may
# differ as the vendor rebuilds it, which is why the image ID identifies the
# artefact while this fixes the semantics.
GOVERNED_PYTHON_VERSION = "3.14.6"

# The governed Python RUNTIME package, as the signed Chainguard SPDX actually
# names it. Ruled 2026-08-14 after the literal "python" was found to match no
# real image: Chainguard names the runtime package for the minor series and
# records the upstream source separately as `cpython v3.14.6`. The runtime
# package is what the image installs and therefore what the governed version
# describes, so it -- not `cpython` -- carries the SBOM proof, and the schema
# stays at fifteen fields.
#
# Derived from the governed version rather than written out a second time: two
# constants that must agree are two constants that can disagree, and a future
# version ruling would otherwise leave the package name behind.
GOVERNED_SBOM_PACKAGE = "python-" + ".".join(GOVERNED_PYTHON_VERSION.split(".")[:2])

# §27 ruled the base family and the pinned form. A tag may find a candidate
# during discovery and must never reach a build, so only the digest form is
# representable here.
BASE_IMAGE_REPOSITORY = "cgr.dev/chainguard/python"

MAXIMUM_EVIDENCE_BYTES = 64 * 1024

_HEX = frozenset("0123456789abcdef")

# The closed schema. `interpreter_link` is the one nullable field, because
# `/usr/bin/python` may or may not be a symlink and §27 records the link value
# either way rather than pretending the distinction does not exist.
EVIDENCE_FIELDS: tuple[str, ...] = (
    "architecture",
    "base_image_reference",
    "containerfile_sha256",
    "evidence_schema_version",
    "interpreter_link",
    "interpreter_path",
    "interpreter_sha256",
    "interpreter_target",
    "oci_image_id",
    "os",
    "python_version",
    "sbom_python_package",
    "sbom_python_version",
    "sbom_sha256",
    "source_commit",
)


class EvidenceError(ValueError):
    """The provisioning evidence is absent, malformed, or self-inconsistent."""


def _hex(value: Any, length: int) -> bool:
    return isinstance(value, str) and len(value) == length and set(value) <= _HEX


def _validate(document: dict[str, Any]) -> dict[str, Any]:
    for name in document:
        if name not in EVIDENCE_FIELDS:
            raise EvidenceError(f"evidence carries unknown field {name!r}")
    for name in EVIDENCE_FIELDS:
        if name not in document:
            raise EvidenceError(f"evidence is missing {name!r}")

    if document["evidence_schema_version"] != EVIDENCE_SCHEMA_VERSION:
        raise EvidenceError(
            f"evidence declares schema {document['evidence_schema_version']!r}, "
            f"and this build implements only {EVIDENCE_SCHEMA_VERSION}")

    # The image identity, in the one governed form: bare lowercase hex. A
    # `sha256:` prefix is the shape every manifest digest arrives in, so it is
    # structurally unrepresentable rather than merely discouraged.
    if not _hex(document["oci_image_id"], 64):
        raise EvidenceError("evidence oci_image_id is not a bare 64-hex image ID")
    for name in ("containerfile_sha256", "interpreter_sha256", "sbom_sha256"):
        if not _hex(document[name], 64):
            raise EvidenceError(f"evidence {name} is not a SHA-256 digest")
    if not _hex(document["source_commit"], 40):
        raise EvidenceError("evidence source_commit is not a commit hash")

    reference = document["base_image_reference"]
    prefix = BASE_IMAGE_REPOSITORY + "@sha256:"
    if not isinstance(reference, str) or not reference.startswith(prefix) \
            or not _hex(reference[len(prefix):], 64):
        raise EvidenceError(
            "evidence base_image_reference is not a digest-pinned "
            f"{BASE_IMAGE_REPOSITORY} reference")

    # §27's three independent proofs of the governed Python: the interpreter's
    # own reported version and the SBOM must both say it, and the base is
    # pinned by digest above. Agreement is required, not any one of them.
    #
    # Exact equality, so a vendor package revision cannot arrive here: the SPDX
    # records `3.14.6-r4`, and §27 rules that -rN may vary while the upstream
    # patch may not. Normalising to the upstream version is therefore the
    # supply-chain tooling's job at extraction, and this refusal is what makes
    # skipping it impossible rather than merely discouraged.
    for name in ("python_version", "sbom_python_version"):
        if document[name] != GOVERNED_PYTHON_VERSION:
            raise EvidenceError(
                f"evidence {name} is {document[name]!r}, "
                f"and the governed version is {GOVERNED_PYTHON_VERSION}")
    if document["sbom_python_package"] != GOVERNED_SBOM_PACKAGE:
        raise EvidenceError(
            f"evidence sbom_python_package is {document['sbom_python_package']!r}, "
            f"and the governed runtime package is {GOVERNED_SBOM_PACKAGE!r}")

    if document["interpreter_path"] != CONTAINER_INTERPRETER:
        raise EvidenceError(
            f"evidence interpreter_path is {document['interpreter_path']!r}, "
            f"and the governed interpreter is {CONTAINER_INTERPRETER}")
    for name in ("interpreter_target", "os", "architecture"):
        if not isinstance(document[name], str) or not document[name]:
            raise EvidenceError(f"evidence {name} is not a non-empty string")
    link = document["interpreter_link"]
    if link is not None and (not isinstance(link, str) or not link):
        raise EvidenceError("evidence interpreter_link is neither absent nor a path")
    return document


def canonical_evidence(fields: dict[str, Any]) -> bytes:
    """The canonical bytes for one evidence manifest, or refuse.

    Serialised through the platform's canonical encoder, so the bytes do not
    depend on the order the caller happened to build the mapping in — two
    operators with the same evidence produce the same digest.
    """
    if not isinstance(fields, dict):
        raise EvidenceError("evidence must be a mapping")
    return canonical_json.serialise(_validate(dict(fields)))


def parse_evidence(body: bytes) -> dict[str, Any]:
    """One validated evidence manifest from canonical bytes, or refuse."""
    try:
        document = canonical_json.parse(body, maximum_bytes=MAXIMUM_EVIDENCE_BYTES)
    except canonical_json.CanonicalJSONError as error:
        raise EvidenceError(f"evidence is not canonical: {error}") from None
    validated = _validate(document)
    # Refuse bytes that parse but are not the canonical encoding of what they
    # parse to. The digest commits bytes, so a document that round-trips
    # differently would commit something nobody reviewed.
    if canonical_json.serialise(validated) != body:
        raise EvidenceError("evidence bytes are not the canonical encoding")
    return validated


def evidence_digest(body: bytes) -> str:
    """The commitment: SHA-256 of the exact canonical manifest bytes."""
    if not isinstance(body, (bytes, bytearray)):
        raise EvidenceError("evidence must be bytes")
    return hashlib.sha256(bytes(body)).hexdigest()
