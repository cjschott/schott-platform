"""The ordinary implementation-admission transaction, offline and operator-run.

**Publishing an admission record is not granting authority.** The record
commits bytes; only a current generation commits authority. Those are two
atomic publications, and the window between them is a real state with a name —
pending disposition — rather than an accident to be hidden. This module makes
that window as short as it can be and leaves it readable when it is not
survived, which is the whole reason the reader classifies rather than freezes.

**Governed values are derived, never supplied.** The caller brings external
evidence — the image identity it observed, the provisioning-evidence manifest —
and nothing else. The `CIMP`, the `CGEN`, the adapter and argv contract
identities, both schema versions, every digest, and every published byte are
determined here. An admission API that accepted a contract identity would let
an operator admit an implementation this build cannot honour.

**The reader is the authority on success.** Preconditions and the final result
are both established by the same reader the runtime uses, not by this module's
own opinion of what it just wrote. A transaction that reported success on a
namespace the runtime would reject would be worse than one that failed.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md``
§5, §5.1–§5.7, §27.
"""

from __future__ import annotations

import contextlib
import dataclasses
import hashlib
import os
from typing import Any

from tools.capability.execution import canonical_json
from tools.capability.execution.authorisation import (
    ADAPTER_IDENTITY, ARGV_CONTRACT_IDENTITY)
from tools.capability.execution.implementation_authority import (
    NamespaceState, PendingDisposition, current_generation,
    resolve_implementation)
from tools.capability.execution.payload import PAYLOAD_SCHEMA_VERSION
from tools.capability.execution.profile import PROFILE_SCHEMA_VERSION
from tools.provisioning import authority_bootstrap as bootstrap
from tools.provisioning.provisioning_evidence import (
    EvidenceError, evidence_digest, parse_evidence)

_ADMISSION = "admission"
_HEX = frozenset("0123456789abcdef")

# The governed contract identities an admission commits, re-exported from the
# runtime module that defines what this build implements.
#
# One definition, and it lives on the runtime side: the writer must admit only
# what the runtime can honour, so the runtime is the thing that gets to say
# what that is. Offline tooling may depend on runtime; runtime never depends on
# offline tooling. They are deliberately not in the reader, which stays free of
# any container-runtime name and deliberately does not enforce contracts at
# all -- a retired CIMP admitted under an older contract must stay readable.


class AdmissionRefused(ValueError):
    """The transaction refused before granting authority."""


@dataclasses.dataclass(frozen=True)
class AdmissionRequest:
    """The external evidence an operator brings, and nothing else.

    Deliberately three fields. Everything an admission record also carries is
    governed by this build, so accepting it here would be accepting a claim
    where a constant belongs.
    """

    # The identity to admit: `podman image inspect .Id`, bare lowercase hex.
    oci_image_id: str
    # Canonical provisioning-evidence manifest bytes.
    evidence: bytes
    # The same identity, observed independently by the operator at admission
    # time. Carried separately so the transaction can require agreement rather
    # than trust one reading of one source.
    observed_image_id: str


@dataclasses.dataclass(frozen=True)
class AdmissionResult:
    """What was admitted, as evidence for the operator record."""

    cimp: str
    cgen: str
    oci_image_id: str
    admission_digest: str
    authority_set_digest: str
    generation_digest: str
    provisioning_evidence_digest: str


def _require_image_id(value: Any, what: str) -> str:
    if not isinstance(value, str) or len(value) != 64 or set(value) - _HEX:
        raise AdmissionRefused(
            f"{what} is not a bare 64-character lowercase hex image ID")
    return value


def _agreeing_image_id(request: AdmissionRequest, evidence: dict[str, Any]) -> str:
    """One identity all three sources name, or refuse.

    A tag or repository name cannot participate: none of the three is
    permitted to be anything but the bare local image ID, so agreement is
    between three readings of the same immutable identity rather than between
    a name and the thing it currently points at.
    """
    requested = _require_image_id(request.oci_image_id, "the requested image ID")
    observed = _require_image_id(request.observed_image_id, "the observed image ID")
    recorded = _require_image_id(evidence["oci_image_id"], "the evidence image ID")
    if not requested == observed == recorded:
        raise AdmissionRefused(
            "the requested, observed, and recorded image identities disagree: "
            f"{requested} / {observed} / {recorded}")
    return requested


def _verify_authority_prerequisites(request: AdmissionRequest) -> tuple[dict[str, Any], str, str]:
    """Everything that must hold before authority may be granted.

    Re-performed rather than assumed at every point it matters, because a valid
    admission record proves only that a record was written. The evidence is
    parsed from its exact bytes, the commitment is computed over those bytes,
    and the three image identities must agree.
    """
    if not isinstance(request, AdmissionRequest):
        raise AdmissionRefused("the request is not an AdmissionRequest")
    try:
        evidence = parse_evidence(request.evidence)
    except EvidenceError as error:
        raise AdmissionRefused(f"provisioning evidence refused: {error}") from None
    image_id = _agreeing_image_id(request, evidence)
    return evidence, image_id, evidence_digest(request.evidence)


def _require_admissible(authority_fd: int) -> Any:
    """The current generation, if the namespace may be mutated at all.

    Consumes the reader's classification rather than re-deriving it: two
    interpretations of the same namespace is one more than can be kept in
    agreement, and the reader is the one the runtime trusts.
    """
    try:
        generation = current_generation(authority_fd)
    except FileNotFoundError:
        # An absent namespace is not an empty one. Genesis is explicit, so
        # this says which step is missing rather than surfacing a bare errno.
        raise AdmissionRefused(
            "the implementation-authority namespace is not initialised; "
            "genesis must be published first") from None
    if generation.state is not NamespaceState.VALID:
        outstanding = ", ".join(
            f"{entry.cimp} ({entry.disposition.value})"
            for entry in generation.pending)
        raise AdmissionRefused(
            "ordinary admission requires a namespace with nothing outstanding; "
            f"disposition is required first for: {outstanding}")
    return generation


def _successor_authority_set(generation: Any, cimp: str,
                             admission_digest: str) -> bytes:
    """The complete successor set: everything current, plus the one new entry.

    Built from the validated current authority set rather than by scanning the
    implementations directory. The set is the record of what was decided, and
    a directory listing is only what happens to be on disk — using the second
    would let an interrupted transaction promote itself.
    """
    entries = []
    for entry in generation.entries:
        if entry.cimp == cimp:
            raise AdmissionRefused(f"{cimp} is already in the authority set")
        entries.append({
            "cimp": entry.cimp,
            "admission": entry.admission_digest,
            "retirement": entry.retirement_digest,
        })
    entries.append({"cimp": cimp, "admission": admission_digest,
                    "retirement": None})
    entries.sort(key=lambda row: int(row["cimp"][5:]))
    return canonical_json.serialise({"entries": entries})


def _stage(staging_fd: int, name: str, files: dict[str, bytes]) -> None:
    """Build one staged directory and prove its bytes before publication."""
    # Final modes before publication: the staged directory and its records are
    # renamed into the published namespace, and rename carries the mode with
    # them. Setting them afterwards would be a publish-then-chmod window on
    # authority material.
    bootstrap._make_directory(name, staging_fd)
    handle = os.open(name, bootstrap._DIR_FLAGS, dir_fd=staging_fd)
    try:
        for filename, body in files.items():
            bootstrap._write_durable(filename, body, handle,
                                     bootstrap.PUBLISHED_RECORD_MODE)
        for filename, body in files.items():
            if bootstrap._read_regular(filename, handle, 1 << 20) != body:
                raise AdmissionRefused(f"the staged {filename} did not verify")
    finally:
        os.close(handle)


def _publish(staging_fd: int, name: str, destination_fd: int) -> None:
    os.rename(name, name, src_dir_fd=staging_fd, dst_dir_fd=destination_fd)
    os.fsync(destination_fd)


def publish_successor(authority_fd: int, staging_fd: int, *, generation: Any,
                      authority_set: bytes, cgen: str) -> tuple[bytes, str]:
    """Stage, verify, and publish one successor generation, non-current.

    Factored so admission and disposition share one publication path. A second
    implementation of this would be a second set of durability decisions, and
    the two would drift in exactly the places that matter least often and cost
    most when they do.

    The generation is immutable the moment it lands and grants nothing: only
    the pointer decides what is authoritative.
    """
    record = canonical_json.serialise({
        "cgen": cgen,
        "predecessor_cgen": generation.cgen,
        "predecessor_generation_digest": generation.generation_digest,
        "authority_set_digest": hashlib.sha256(authority_set).hexdigest(),
    })
    _stage(staging_fd, cgen, {
        bootstrap.AUTHORITY_SET: authority_set,
        bootstrap.GENERATION: record,
    })
    generations_fd = os.open(
        bootstrap.GENERATIONS, bootstrap._DIR_FLAGS, dir_fd=authority_fd)
    try:
        _publish(staging_fd, cgen, generations_fd)
    finally:
        os.close(generations_fd)
    return record, hashlib.sha256(record).hexdigest()


def advance_pointer(authority_fd: int, *, cgen: str, generation_digest: str) -> None:
    """Move `current-generation`, the one step that grants anything.

    A regular canonical-JSON file replaced by durable atomic rename. It is the
    only object in the namespace legitimately replaced rather than created
    once, because it is a pointer and not a record.
    """
    pointer = canonical_json.serialise({
        "cgen": cgen, "generation_digest": generation_digest})
    temporary = f".{bootstrap.CURRENT_GENERATION}.{cgen}"
    with contextlib.suppress(FileNotFoundError):
        os.unlink(temporary, dir_fd=authority_fd)
    bootstrap._write_durable(temporary, pointer, authority_fd,
                             bootstrap.PUBLISHED_RECORD_MODE)
    os.rename(temporary, bootstrap.CURRENT_GENERATION,
              src_dir_fd=authority_fd, dst_dir_fd=authority_fd)
    os.fsync(authority_fd)


def admit_implementation(authority_fd: int, control_fd: int, *,
                         request: AdmissionRequest) -> AdmissionResult:
    """Admit one implementation, or refuse without granting authority.

    The order is the accepted one and each step is where it is for a reason.
    The precondition runs before an identifier is burned; the admission record
    is published before the prerequisites are re-checked, so a prerequisite
    failure leaves a readable pending state rather than a half-written record;
    and the pointer moves last, because it is the only step that grants
    anything.
    """
    evidence, image_id, provisioning_digest = _verify_authority_prerequisites(request)

    with bootstrap.implementation_lifecycle_lock(control_fd):
        generation = _require_admissible(authority_fd)
        staging_fd = bootstrap._require_clean_staging(control_fd)
        try:
            cimp = bootstrap.allocate_cimp(control_fd)

            admission = canonical_json.serialise({
                "cimp": cimp,
                "oci_image_id": image_id,
                "adapter_identity": ADAPTER_IDENTITY,
                "argv_contract_identity": ARGV_CONTRACT_IDENTITY,
                "payload_schema_version": PAYLOAD_SCHEMA_VERSION,
                "execution_profile_schema_version": PROFILE_SCHEMA_VERSION,
                "provisioning_evidence_digest": provisioning_digest,
            })
            admission_digest = hashlib.sha256(admission).hexdigest()

            _stage(staging_fd, cimp, {_ADMISSION: admission})
            implementations_fd = os.open(
                bootstrap.IMPLEMENTATIONS, bootstrap._DIR_FLAGS, dir_fd=authority_fd)
            try:
                _publish(staging_fd, cimp, implementations_fd)
            finally:
                os.close(implementations_fd)

            # The record is immutable from here. Everything below either
            # completes the transaction or leaves it pending disposition; it
            # never deletes, rewrites, or retires what was just published.
            published = current_generation(authority_fd)
            outstanding = [entry for entry in published.pending
                           if entry.cimp == cimp]
            if (published.state is not NamespaceState.VALID_WITH_PENDING_DISPOSITION
                    or len(outstanding) != 1
                    or outstanding[0].disposition
                    is not PendingDisposition.PENDING_ADMISSION):
                raise AdmissionRefused(
                    f"{cimp} did not publish as a pending admission")

            # Re-performed after publication, exactly as the disposition
            # ceremony will have to: a published record is not authority, and
            # what grants authority is checked at the moment it is granted.
            recheck, recheck_image, recheck_digest = \
                _verify_authority_prerequisites(request)
            if recheck_image != image_id or recheck_digest != provisioning_digest:
                raise AdmissionRefused("the provisioning evidence changed mid-transaction")

            cgen = bootstrap.allocate_cgen(control_fd)
            authority_set = _successor_authority_set(
                generation, cimp, admission_digest)
            record, generation_digest = publish_successor(
                authority_fd, staging_fd, generation=generation,
                authority_set=authority_set, cgen=cgen)
        finally:
            os.close(staging_fd)

        advance_pointer(authority_fd, cgen=cgen,
                        generation_digest=generation_digest)

        # Success is what the reader says, not what this function believes.
        final = current_generation(authority_fd)
        if final.state is not NamespaceState.VALID or final.pending:
            raise AdmissionRefused(f"the admitted namespace is {final.state}")
        if final.cgen != cgen:
            raise AdmissionRefused(f"the pointer names {final.cgen}, not {cgen}")
        admitted = resolve_implementation(authority_fd, cimp, generation=final)
        if admitted.oci_image_id != image_id:
            raise AdmissionRefused("the admitted image identity did not survive")
        if admitted.provisioning_evidence_digest != provisioning_digest:
            raise AdmissionRefused("the admitted evidence commitment did not survive")

        return AdmissionResult(
            cimp=cimp,
            cgen=cgen,
            oci_image_id=image_id,
            admission_digest=admission_digest,
            authority_set_digest=hashlib.sha256(authority_set).hexdigest(),
            generation_digest=generation_digest,
            provisioning_evidence_digest=provisioning_digest,
        )
