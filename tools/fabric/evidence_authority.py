"""Reading governed Platform Evidence from the trusted deployment authority.

**Why Fabric may not read the checkout.** A `CapabilityHost` claims a verified
resource profile, and `verification_reference` names the Evidence that verified
it. Resolving that reference out of `platform-model/evidence/` would make a
permanent, immutable governance record depend on a mutable Git working tree:
one that can be checked out at another revision, edited between two reads, or
absent entirely on the machine doing the resolving. The same argument the
artifact authority already settled for package bytes, applied to evidence.

So there are three Evidence planes, and this module reads exactly one:

    platform-model/evidence/     declarative, reviewed, Git-governed. SOURCE.
    /var/lib/kyri/evidence       root-owned deployment authority. WHAT THIS READS.
    tools/observation store      dynamic collector history, outside any repository.

The middle one is materialised from a pinned reviewed commit by
`provisioning/evidence/install-host-evidence.sh`, and this module never writes
to it, never creates it, and never repairs it.

**The dynamic store is deliberately not reused.** `EvidenceStore` provisions its
subdirectories on construction and allocates identities from a locked sequence.
Both are correct for recording what a collector saw over time and wrong for
reading one already-governed declarative record: a reader that creates the
thing it is about to describe answers partly about its own side effects, and an
allocator has nothing to allocate for an identity the model already fixed.

**The identity is the location.** The destination is derived from the governed
`EVID-NNNNNN` identity and from nothing a caller supplies, so there is no path
to traverse, no name to escape with, and no way for two identities to resolve
to one record.

**Existence is not verification.** `resolve_evidence` answers *what does this
record say*; `supports_profile` answers *does it say what this host claims*.
They are separate because an Evidence record that exists, parses, and
fingerprints correctly can still be about a different machine or a different
dimension — and accepting it on the strength of being well-formed is exactly
the mistake the split prevents.

Governed by:
  ``platform-model/schemas/evidence.schema.yaml``
  ``platform-model/schemas/capability-host.schema.yaml`` (platform_model_node_identity)
  ``docs/standards/evidence-standard.md``
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from typing import Any, Mapping

from ..common.trusted_source import TrustedSourceError, open_trusted_regular_file
from ..common.yaml_strict import loads_strict
from ..platform_model import evidence_fingerprint

# The governed Evidence identity, taken from `evidence.schema.yaml`'s
# `id_pattern` and matching `tools/observation/models.EVIDENCE_ID` exactly. A
# second grammar here would be a second answer to what an Evidence identity is.
EVIDENCE_ID = re.compile(r"^EVID-[0-9]{6}$")

# The evidence-standard bound. A record needing more than this is refused for
# being oversized rather than read to discover that it was.
MAXIMUM_BYTES = 65536

# The fields this module reads. Not the schema's full required set: schema
# validity is proven at publication, where the schema lives, and re-deriving it
# here would put a second copy of the model in the governance plane.
_REQUIRED = ("api_version", "id", "type", "target", "status", "facts",
             "content_fingerprint")

_STATUS_SUCCESS = "success"
_TYPE_EVIDENCE = "evidence"

REASON_IDENTITY = "evidence-identity-malformed"
REASON_UNAVAILABLE = "evidence-unavailable"
REASON_MALFORMED = "evidence-not-readable"
REASON_SCHEMA = "evidence-schema-invalid"
REASON_FINGERPRINT = "evidence-fingerprint-mismatch"
REASON_STATUS = "evidence-status-not-success"
REASON_TARGET = "evidence-target-mismatch"
REASON_DIMENSION = "evidence-dimension-not-governed"
REASON_VALUE = "evidence-value-mismatch"


@dataclass(frozen=True)
class ResolvedEvidence:
    """One governed Evidence record, or the reason there is not one.

    `supported` false always carries a reason; true always carries the facts.
    A single type with an optional flag would let a caller read the facts of a
    record that was never resolved.
    """

    supported: bool
    reason: str | None = None
    evidence_id: str | None = None
    target: str | None = None
    governed_field: str | None = None
    canonical_value: Any = None
    status: str | None = None


def _refused(reason: str) -> ResolvedEvidence:
    return ResolvedEvidence(False, reason)


def resolve_evidence(*, evidence_id: Any, evidence_root: Any,
                     trusted_source_uid: Any) -> ResolvedEvidence:
    """The governed Evidence record for one identity, or a refusal.

    `evidence_root` and `trusted_source_uid` are supplied explicitly and are
    never inferred: a root discovered from the environment and a uid read off
    the running process are both the caller agreeing with itself.

    Reads. Creates nothing, writes nothing, and repairs nothing — an authority
    that cannot be opened is reported as unavailable rather than provisioned.
    """
    if not isinstance(evidence_id, str) or not EVIDENCE_ID.fullmatch(evidence_id):
        return _refused(REASON_IDENTITY)
    if evidence_root is None or str(evidence_root).strip() == "":
        return _refused(REASON_UNAVAILABLE)
    if not isinstance(trusted_source_uid, int) or isinstance(trusted_source_uid, bool):
        return _refused(REASON_UNAVAILABLE)

    # Derived from the identity, never from a caller. `EVID-000001` can only
    # ever name `EVID-000001.yaml` directly beneath the root.
    name = f"{evidence_id}.yaml"

    try:
        handle = open_trusted_regular_file(
            evidence_root, name, expected_uid=trusted_source_uid,
            require_single_link=True, maximum_bytes=MAXIMUM_BYTES,
            refuse_oversize=True)
    except TrustedSourceError:
        return _refused(REASON_UNAVAILABLE)
    try:
        raw = os.read(handle, MAXIMUM_BYTES + 1)
    except OSError:
        return _refused(REASON_UNAVAILABLE)
    finally:
        os.close(handle)
    if len(raw) > MAXIMUM_BYTES:
        return _refused(REASON_UNAVAILABLE)

    try:
        record = loads_strict(raw.decode("utf-8"), source=name)
    except Exception:  # noqa: BLE001
        # Bytes that will not decode, will not parse, or repeat a key are all
        # one answer: unreadable. The loader spans several exception types and
        # the distinction does not change what a caller can do about it.
        return _refused(REASON_MALFORMED)
    if not isinstance(record, dict):
        return _refused(REASON_MALFORMED)

    if any(field not in record for field in _REQUIRED):
        return _refused(REASON_SCHEMA)
    if record.get("type") != _TYPE_EVIDENCE:
        return _refused(REASON_SCHEMA)
    # The record that came back must be the record that was asked for. A store
    # answering with a different identity is answering a different question.
    if record.get("id") != evidence_id:
        return _refused(REASON_SCHEMA)
    facts = record.get("facts")
    if not isinstance(facts, dict):
        return _refused(REASON_SCHEMA)

    # The fingerprint is what makes the bytes a claim rather than a file. It is
    # recomputed through the released primitive, never trusted as declared.
    declared = record.get("content_fingerprint")
    if not evidence_fingerprint.is_well_formed(declared):
        return _refused(REASON_FINGERPRINT)
    try:
        recomputed = evidence_fingerprint.fingerprint(record)
    except evidence_fingerprint.FingerprintError:
        return _refused(REASON_FINGERPRINT)
    if recomputed != declared:
        return _refused(REASON_FINGERPRINT)

    if record.get("status") != _STATUS_SUCCESS:
        return _refused(REASON_STATUS)

    return ResolvedEvidence(
        True, None,
        evidence_id=evidence_id,
        target=record.get("target"),
        governed_field=facts.get("governed_field"),
        canonical_value=facts.get("canonical_value"),
        status=record.get("status"),
    )


def supports_profile(evidence: ResolvedEvidence, *, node_identity_reference: Any,
                     verified_resource_profile: Any) -> str | None:
    """`None` where the evidence supports the claim, else the reason it does not.

    Two questions, both of which a merely-existing record fails to answer.

    **Is it about this machine?** `EVID.target` and `node_identity_reference`
    are the same Platform Model host identity, which is what the
    `platform_model_node_identity` rule fixed. Nothing is inferred from a
    hostname, and there is no alias table.

    **Does it prove what is claimed?** Every dimension the profile claims must
    be one this record governs, and the claimed value must equal the canonical
    value exactly. Both are already normalised — the record carries the
    canonical token beside the raw observations it came from, and the profile
    carries the governed token — so this compares and never normalises. A
    comparison that normalised its inputs would be deciding what a governed
    record meant at the moment it was read.

    **One record governs one dimension.** A profile claiming two dimensions
    cannot be supported by one Evidence record, and this returns the
    unsupported dimension rather than accepting the one it does prove. Richer
    profiles need a reference per governed field, which the host record cannot
    yet express: `verification_reference` is a single value. That is a real
    limit and it is reported rather than worked around.
    """
    if not isinstance(evidence, ResolvedEvidence) or not evidence.supported:
        return REASON_UNAVAILABLE
    if evidence.target != node_identity_reference:
        return REASON_TARGET
    if not isinstance(verified_resource_profile, Mapping):
        return REASON_DIMENSION
    for dimension, claimed in verified_resource_profile.items():
        if dimension != evidence.governed_field:
            return REASON_DIMENSION
        if claimed != evidence.canonical_value:
            return REASON_VALUE
    return None
