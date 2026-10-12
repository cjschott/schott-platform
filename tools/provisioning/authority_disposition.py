"""Explicit disposition of pending published CIMPs, offline and operator-run.

**A pending CIMP is an interrupted transaction, not a steady state.** Something
was published and the generation that would have accounted for it never became
current. Only an operator decides what that means, and there are exactly two
answers: COMPLETE, which makes the already-immutable admission eligible, and
RETIRE, which guarantees it never will be. There is no delete, no repair, no
force, and no automatic anything — each of those would be a way for the system
to decide on the operator's behalf what a half-finished decision meant.

**One generation for the whole pending set.** Disposing of pending CIMPs one at
a time would raise the high-water mark past a still-pending lower ordinal,
which is precisely the condition the reader treats as corruption — so a
sequential ceremony would walk the namespace through global freeze on its way
to a valid state. Every decision therefore lands in a single successor
generation, and a request that does not account for every pending CIMP is
refused before anything is touched.

**Retirement is one-way.** Once a retirement record is published the decision
is immutable, so `COMPLETE` is no longer available for that CIMP. The reader
hands over the subtype directly, which is what makes that enforceable without
a second reading of raw namespace bytes.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md``
§5.1–§5.7, §27.
"""

from __future__ import annotations

import dataclasses
import enum
import hashlib
import os
from typing import Any

from tools.capability.execution import canonical_json
from tools.capability.execution.implementation_authority import (
    NamespaceState, PendingDisposition, current_generation)
from tools.capability.execution import implementation_authority as authority
from tools.capability.execution.payload import PAYLOAD_SCHEMA_VERSION
from tools.capability.execution.profile import PROFILE_SCHEMA_VERSION
from tools.provisioning import authority_bootstrap as bootstrap
from tools.provisioning.authority_admission import (
    ADAPTER_IDENTITY, ARGV_CONTRACT_IDENTITY, _publish, _require_image_id,
    _stage, advance_pointer, publish_successor)
from tools.provisioning.provisioning_evidence import (
    EvidenceError, evidence_digest, parse_evidence)

_ADMISSION = "admission"
_RETIREMENT = "retirement"


class DispositionRefused(ValueError):
    """The ceremony refused before changing what is authoritative."""


class Disposition(enum.Enum):
    """The two answers an operator may give, and there are no others."""

    # The published admission becomes eligible in the successor generation.
    COMPLETE = "complete"
    # The published admission is permanently prevented from becoming eligible.
    RETIRE = "retire"


@dataclasses.dataclass(frozen=True)
class Decision:
    """One operator decision about one pending CIMP.

    `evidence` and `observed_image_id` are required for COMPLETE and forbidden
    otherwise: retiring something grants no authority, so it needs no proof
    about an image. The admitted image identity is never taken from here — it
    comes from the immutable published admission.
    """

    cimp: str
    disposition: Disposition
    evidence: bytes | None = None
    observed_image_id: str | None = None


@dataclasses.dataclass(frozen=True)
class DispositionRequest:
    """The complete set of decisions for the complete pending set."""

    decisions: tuple[Decision, ...]


@dataclasses.dataclass(frozen=True)
class DispositionResult:
    """What one disposition ceremony settled."""

    cgen: str
    authority_set_digest: str
    generation_digest: str
    completed: tuple[str, ...]
    retired: tuple[str, ...]


def _read_record(authority_fd: int, cimp: str, name: str) -> bytes:
    base = os.open(bootstrap.IMPLEMENTATIONS, bootstrap._DIR_FLAGS,
                   dir_fd=authority_fd)
    try:
        handle = os.open(cimp, bootstrap._DIR_FLAGS, dir_fd=base)
        try:
            return bootstrap._read_regular(name, handle, 1 << 20)
        finally:
            os.close(handle)
    finally:
        os.close(base)


def _decided(request: DispositionRequest,
             pending: tuple[Any, ...]) -> dict[str, Decision]:
    """One decision per pending CIMP, exactly, or refuse.

    Checked against the reader's pending set rather than against the
    directory: the reader already decided what is pending and why, and asking
    the disk again would be a second opinion nobody arbitrates.
    """
    if not isinstance(request, DispositionRequest):
        raise DispositionRefused("the request is not a DispositionRequest")
    decisions: dict[str, Decision] = {}
    for decision in request.decisions:
        if not isinstance(decision, Decision):
            raise DispositionRefused("a decision is not a Decision")
        if not isinstance(decision.disposition, Disposition):
            raise DispositionRefused(
                f"{decision.cimp} carries an unknown disposition")
        if decision.cimp in decisions:
            raise DispositionRefused(
                f"{decision.cimp} carries more than one decision")
        decisions[decision.cimp] = decision

    outstanding = {entry.cimp: entry for entry in pending}
    missing = sorted(set(outstanding) - set(decisions))
    if missing:
        raise DispositionRefused(
            "every pending CIMP must be dispositioned in one ceremony; "
            f"undecided: {', '.join(missing)}")
    unknown = sorted(set(decisions) - set(outstanding))
    if unknown:
        raise DispositionRefused(
            f"not pending, so not this ceremony's to decide: {', '.join(unknown)}")

    for cimp, decision in decisions.items():
        subtype = outstanding[cimp].disposition
        if (subtype is PendingDisposition.PENDING_RETIREMENT
                and decision.disposition is not Disposition.RETIRE):
            raise DispositionRefused(
                f"{cimp} already carries an immutable retirement; COMPLETE is "
                "not available and a retirement is never reversed")
        if decision.disposition is Disposition.COMPLETE:
            if decision.evidence is None or decision.observed_image_id is None:
                raise DispositionRefused(
                    f"{cimp} COMPLETE requires provisioning evidence and an "
                    "independently observed image ID")
        elif decision.evidence is not None or decision.observed_image_id is not None:
            raise DispositionRefused(
                f"{cimp} RETIRE grants no authority and takes no image evidence")
    return decisions


def _verify_complete(authority_fd: int, cimp: str, decision: Decision) -> str:
    """Re-perform every prerequisite before this CIMP may become eligible.

    A valid immutable admission proves a record was written, never that the
    external facts still hold — the image may be gone, the evidence may have
    been for something else, and neither is visible from the record alone.
    """
    body = _read_record(authority_fd, cimp, _ADMISSION)
    try:
        admitted = authority._admission(body, cimp)
    except authority.ImplementationAuthorityError as error:
        raise DispositionRefused(f"{cimp} admission no longer validates: {error}") from None

    if admitted.adapter_identity != ADAPTER_IDENTITY:
        raise DispositionRefused(
            f"{cimp} was admitted for adapter {admitted.adapter_identity!r}")
    if admitted.argv_contract_identity != ARGV_CONTRACT_IDENTITY:
        raise DispositionRefused(
            f"{cimp} was admitted for argv contract "
            f"{admitted.argv_contract_identity!r}")
    if admitted.payload_schema_version != PAYLOAD_SCHEMA_VERSION:
        raise DispositionRefused(
            f"{cimp} declares payload schema {admitted.payload_schema_version}")
    if admitted.execution_profile_schema_version != PROFILE_SCHEMA_VERSION:
        raise DispositionRefused(
            f"{cimp} declares profile schema "
            f"{admitted.execution_profile_schema_version}")

    try:
        evidence = parse_evidence(decision.evidence)
    except EvidenceError as error:
        raise DispositionRefused(f"{cimp} evidence refused: {error}") from None
    if evidence_digest(decision.evidence) != admitted.provisioning_evidence_digest:
        raise DispositionRefused(
            f"{cimp} evidence does not match the commitment its admission made")

    # The admitted identity is the immutable one; the other two must agree
    # with it rather than with each other.
    observed = _require_image_id(decision.observed_image_id,
                                 f"{cimp} observed image ID")
    if evidence["oci_image_id"] != admitted.oci_image_id:
        raise DispositionRefused(
            f"{cimp} evidence names {evidence['oci_image_id']}, and the "
            f"admission names {admitted.oci_image_id}")
    if observed != admitted.oci_image_id:
        raise DispositionRefused(
            f"{cimp} was observed as {observed}, and the admission names "
            f"{admitted.oci_image_id}")
    return hashlib.sha256(body).hexdigest()


def _verify_retire(authority_fd: int, cimp: str,
                   subtype: PendingDisposition) -> tuple[str, str | None]:
    """The admission digest, and the retirement digest if one already exists."""
    body = _read_record(authority_fd, cimp, _ADMISSION)
    try:
        authority._admission(body, cimp)
    except authority.ImplementationAuthorityError as error:
        raise DispositionRefused(f"{cimp} admission no longer validates: {error}") from None
    admission_digest = hashlib.sha256(body).hexdigest()

    if subtype is not PendingDisposition.PENDING_RETIREMENT:
        return admission_digest, None
    # Already published: validated and reused, never rewritten. Republishing
    # would replace an immutable decision with an identical-looking one and
    # lose the fact that it was already made.
    retirement = _read_record(authority_fd, cimp, _RETIREMENT)
    try:
        authority._retirement(retirement, cimp)
    except authority.ImplementationAuthorityError as error:
        raise DispositionRefused(f"{cimp} retirement does not validate: {error}") from None
    return admission_digest, hashlib.sha256(retirement).hexdigest()


def _successor(generation: Any, settled: dict[str, tuple[str, str | None]]) -> bytes:
    """The current authority set, preserved exactly, plus every decision."""
    entries = []
    for entry in generation.entries:
        if entry.cimp in settled:
            raise DispositionRefused(f"{entry.cimp} is already accounted for")
        entries.append({"cimp": entry.cimp, "admission": entry.admission_digest,
                        "retirement": entry.retirement_digest})
    for cimp, (admission_digest, retirement_digest) in settled.items():
        entries.append({"cimp": cimp, "admission": admission_digest,
                        "retirement": retirement_digest})
    entries.sort(key=lambda row: int(row["cimp"][5:]))
    return canonical_json.serialise({"entries": entries})


def dispose_pending(authority_fd: int, control_fd: int, *,
                    request: DispositionRequest) -> DispositionResult:
    """Settle every pending CIMP in one successor generation, or refuse.

    Everything that can fail without mutating runs first: the classification,
    the decision set, every COMPLETE prerequisite, and every existing
    retirement. Only then is a retirement published or an identifier burned, so
    a malformed request costs nothing and leaves nothing behind.
    """
    with bootstrap.implementation_lifecycle_lock(control_fd):
        generation = current_generation(authority_fd)
        if generation.state is not NamespaceState.VALID_WITH_PENDING_DISPOSITION:
            raise DispositionRefused(
                f"there is nothing to disposition: the namespace is {generation.state}")

        decisions = _decided(request, generation.pending)
        subtypes = {entry.cimp: entry.disposition for entry in generation.pending}

        # Every check that can fail, before anything is written.
        settled: dict[str, tuple[str, str | None]] = {}
        to_publish: list[str] = []
        for cimp in sorted(decisions, key=lambda name: int(name[5:])):
            decision = decisions[cimp]
            if decision.disposition is Disposition.COMPLETE:
                settled[cimp] = (_verify_complete(authority_fd, cimp, decision), None)
                continue
            admission_digest, retirement_digest = _verify_retire(
                authority_fd, cimp, subtypes[cimp])
            settled[cimp] = (admission_digest, retirement_digest)
            if retirement_digest is None:
                to_publish.append(cimp)

        staging_fd = bootstrap._require_clean_staging(control_fd)
        try:
            implementations_fd = os.open(
                bootstrap.IMPLEMENTATIONS, bootstrap._DIR_FLAGS, dir_fd=authority_fd)
            try:
                for cimp in to_publish:
                    body = canonical_json.serialise({"cimp": cimp})
                    staged = f"{cimp}.retirement"
                    _stage(staging_fd, staged, {_RETIREMENT: body})
                    target = os.open(cimp, bootstrap._DIR_FLAGS,
                                     dir_fd=implementations_fd)
                    try:
                        os.rename(_RETIREMENT, _RETIREMENT,
                                  src_dir_fd=os.open(staged, bootstrap._DIR_FLAGS,
                                                     dir_fd=staging_fd),
                                  dst_dir_fd=target)
                        os.fsync(target)
                    finally:
                        os.close(target)
                    os.rmdir(staged, dir_fd=staging_fd)
                    settled[cimp] = (settled[cimp][0],
                                     hashlib.sha256(body).hexdigest())
            finally:
                os.close(implementations_fd)

            # One identifier for the whole ceremony, burned only once every
            # decision is already durable.
            cgen = bootstrap.allocate_cgen(control_fd)
            authority_set = _successor(generation, settled)
            record, generation_digest = publish_successor(
                authority_fd, staging_fd, generation=generation,
                authority_set=authority_set, cgen=cgen)
        finally:
            os.close(staging_fd)

        advance_pointer(authority_fd, cgen=cgen,
                        generation_digest=generation_digest)

        final = current_generation(authority_fd)
        if final.state is not NamespaceState.VALID or final.pending:
            raise DispositionRefused(f"the settled namespace is {final.state}")
        if final.cgen != cgen:
            raise DispositionRefused(f"the pointer names {final.cgen}, not {cgen}")

        completed = tuple(sorted(
            (cimp for cimp, decision in decisions.items()
             if decision.disposition is Disposition.COMPLETE),
            key=lambda name: int(name[5:])))
        retired = tuple(sorted(
            (cimp for cimp, decision in decisions.items()
             if decision.disposition is Disposition.RETIRE),
            key=lambda name: int(name[5:])))
        for cimp in completed:
            if cimp not in final.eligible_cimps:
                raise DispositionRefused(f"{cimp} did not become eligible")
        for cimp in retired:
            if cimp in final.eligible_cimps:
                raise DispositionRefused(f"{cimp} became eligible despite retirement")

        return DispositionResult(
            cgen=cgen,
            authority_set_digest=hashlib.sha256(authority_set).hexdigest(),
            generation_digest=generation_digest,
            completed=completed,
            retired=retired,
        )
