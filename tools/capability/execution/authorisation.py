"""Coordinator-side implementation-authority resolution.

**One direction, one authority.** A request names a `CIMP`; everything else is
derived. The image identity comes from the resolved immutable admission and
from nowhere else — not a tag, not a repository name, not a store listing, not
capability metadata, and not the caller. That is what makes *image presence is
not image authority* a property of the code rather than a rule someone follows.

**The coordinator resolves; nobody downstream does.** The root transition
helper understands one bounded launch record, the worker chooses no image, and
the adapter consumes a governed profile rather than picking an implementation.
This module is the single place where a `CIMP` becomes a profile, and it is
read-only: it allocates nothing, publishes nothing, takes no lock, and cannot
reach the offline writer.

**Record integrity and runtime compatibility are different questions.** The
reader deliberately keeps historical and retired records readable — refusing
them would let one old entry poison the whole namespace — so it does not judge
whether a contract is one *this build* can honour. That judgement belongs here,
after resolution and before a profile exists, because a structurally perfect
admission for an adapter this runtime does not implement must never reach the
transition.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md``
§5, §5.1–§5.7, §12.
"""

from __future__ import annotations

import dataclasses
from typing import Any, Mapping

from .implementation_authority import (
    RESERVED_CIMP, Admission, ImplementationAuthorityError,
    UnknownImplementation, current_generation, resolve_implementation)
from .payload import PAYLOAD_SCHEMA_VERSION
from .profile import (
    PROFILE_SCHEMA_VERSION, ExecutionFingerprint, ExecutionProfile,
    ProfileBinding, build_profile, fingerprint)

# The governed contract identities this build implements. An admission naming
# anything else is readable history, not something the current runtime may bind.
ADAPTER_IDENTITY = "python-podman-v1"
ARGV_CONTRACT_IDENTITY = "fixed-python-entrypoint-v1"


class IncompatibleImplementation(ImplementationAuthorityError):
    """Validly admitted, and not something this build can honour.

    Deliberately distinct from ``UnknownImplementation`` and
    ``RetiredImplementation``: the record is sound and the decision to admit it
    stands, so reporting it as absent or as withdrawn would misdescribe both
    the namespace and the reason nothing can run.
    """


@dataclasses.dataclass(frozen=True)
class AuthorisedImplementation:
    """One resolved implementation, ready to be bound to an invocation.

    Carries values only. No descriptor, no path, no mutable metadata, and no
    handle onto anything that could authorise a second time — this is the
    result of an authority decision, not a means of making one.
    """

    cinv: str
    cimp: str
    oci_image_id: str
    profile: ExecutionProfile
    fingerprint: ExecutionFingerprint
    provisioning_evidence_digest: str


def _require_compatible(admission: Admission) -> None:
    """Refuse an admission this build cannot honour, before a profile exists.

    Every field here is a contract between the admission and the running code.
    A mismatch means the implementation was admitted for a different runtime,
    which is a refusal rather than something to reconcile: adapting to it would
    mean executing under a contract nobody reviewed against this build.
    """
    if admission.adapter_identity != ADAPTER_IDENTITY:
        raise IncompatibleImplementation(
            f"{admission.cimp} was admitted for adapter "
            f"{admission.adapter_identity!r}, and this build implements "
            f"{ADAPTER_IDENTITY!r}")
    if admission.argv_contract_identity != ARGV_CONTRACT_IDENTITY:
        raise IncompatibleImplementation(
            f"{admission.cimp} was admitted for argv contract "
            f"{admission.argv_contract_identity!r}, and this build implements "
            f"{ARGV_CONTRACT_IDENTITY!r}")
    if admission.payload_schema_version != PAYLOAD_SCHEMA_VERSION:
        raise IncompatibleImplementation(
            f"{admission.cimp} declares payload schema "
            f"{admission.payload_schema_version}, and this build implements "
            f"{PAYLOAD_SCHEMA_VERSION}")
    if admission.execution_profile_schema_version != PROFILE_SCHEMA_VERSION:
        raise IncompatibleImplementation(
            f"{admission.cimp} declares profile schema "
            f"{admission.execution_profile_schema_version}, and this build "
            f"implements {PROFILE_SCHEMA_VERSION}")


def authorise_implementation(authority_fd: int, *, cinv: str, cimp: str,
                             metadata: Mapping[str, Any] | None = None
                             ) -> AuthorisedImplementation:
    """Turn a requested `CIMP` into a governed profile, or refuse.

    ``authority_fd`` is an already-open descriptor on the published authority
    root, supplied by service startup rather than by whoever is asking for an
    execution. Taking a path here would make the authority namespace something
    a caller could choose, which is the one input that must never be caller
    controlled.

    ``metadata`` exists so that an attempt to influence the profile is an
    error rather than something quietly dropped; it is passed straight to
    ``build_profile``, which refuses anything governed.

    Failures keep their distinctions. Corruption raises the reader's integrity
    failure and is **not** downgraded to "unknown": a namespace nobody can
    vouch for is a different situation from an implementation that was never
    admitted, and collapsing them would hide a freeze behind a typo.
    """
    if cimp == RESERVED_CIMP:
        raise UnknownImplementation(
            f"{RESERVED_CIMP} is reserved and is never an implementation")

    # The reader is the only interpreter of the namespace. Nothing below
    # scans implementations, parses a record, or picks a "latest" anything.
    generation = current_generation(authority_fd)
    admission = resolve_implementation(authority_fd, cimp, generation=generation)

    _require_compatible(admission)

    profile = build_profile(
        ProfileBinding(cinv=cinv, admission=admission), metadata)

    # The agreements the design requires, asserted rather than assumed. Each
    # would be a silent substitution if it ever failed.
    if profile.cimp != admission.cimp or admission.cimp != cimp:
        raise IncompatibleImplementation(
            f"the resolved implementation is {admission.cimp}, not {cimp}")
    if profile.oci_image_id != admission.oci_image_id:
        raise IncompatibleImplementation(
            f"{cimp} bound image {profile.oci_image_id}, and its admission "
            f"names {admission.oci_image_id}")

    return AuthorisedImplementation(
        cinv=cinv,
        cimp=admission.cimp,
        oci_image_id=admission.oci_image_id,
        profile=profile,
        fingerprint=fingerprint(profile),
        provisioning_evidence_digest=admission.provisioning_evidence_digest,
    )
