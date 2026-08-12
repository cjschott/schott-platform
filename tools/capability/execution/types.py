"""Immutable execution-domain types for the ENG-0005 first adapter.

**Pure by construction.** Nothing here reads a clock, an environment variable,
a file, or a process; nothing generates an identity; nothing executes. Every
value is supplied by a caller that already had authority to know it, and the
types only record it in a form that cannot later be altered.

**The classification set is closed.** ``Classification`` enumerates exactly the
reasons §25 of the specification defines, and ``Classification.of`` refuses
anything else rather than accepting an unrecognised string. This is the point
of the increment: a reason that does not exist here cannot be reported at all,
so an omission surfaces as a refusal during implementation instead of as an
unreviewed vocabulary that grew one call site at a time.

Adding a member is therefore a specification change, not a convenience.
"""

from __future__ import annotations

import dataclasses
import enum


class UnknownClassification(ValueError):
    """A reason string outside the specification's closed vocabulary."""


@enum.unique
class Classification(enum.Enum):
    """Every failure and reconciliation reason §25 defines, and no others."""

    # Execution
    EXECUTION_CAPACITY_EXHAUSTED = "execution_capacity_exhausted"
    # The bound digest is absent from the rootless store at a required check.
    # It authorises no pull, no substitute digest, and no different CIMP.
    EXECUTION_IMAGE_UNAVAILABLE = "execution_image_unavailable"
    # Transition failed with launch_authorized provably not issued. Only usable
    # when execution can be excluded; otherwise the reconciliation path applies.
    TRANSITION_FAILED_BEFORE_EXECUTION = "transition_failed_before_execution"
    EXECUTION_CONTAINER_NAME_COLLISION = "execution_container_name_collision"
    EXECUTION_CONTAINER_NAME_COLLISION_UNSTABLE = (
        "execution_container_name_collision_unstable")
    EXECUTION_STATE_LOST = "execution_state_lost"
    EXECUTION_STATE_LOST_DURING_MUTATION_FREEZE = (
        "execution_state_lost_during_mutation_freeze")
    EXECUTION_IDENTITY_MISMATCH = "execution_identity_mismatch"
    EXECUTION_PROFILE_VERSION_UNSUPPORTED = (
        "execution_profile_version_unsupported")
    EXECUTION_PROFILE_VERIFIER_UNAVAILABLE = (
        "execution_profile_verifier_unavailable")
    EXECUTION_START_OUTCOME_UNKNOWN = "execution_start_outcome_unknown"
    START_RECONCILED_RUNNING = "start_reconciled_running"
    START_RECONCILED_TERMINAL = "start_reconciled_terminal"
    EXECUTION_LIFECYCLE_INTEGRITY_FAILURE = (
        "execution_lifecycle_integrity_failure")
    EXECUTION_CLEANUP_INCOMPLETE = "execution_cleanup_incomplete"
    EXECUTION_PROTOCOL_VIOLATION = "execution_protocol_violation"

    # Result and output
    # The two result members are about one document: the tree was valid and the
    # canonical result was absent, or it was present and failed its contract.
    # A hostile tree shape is neither, and is kept separate so that an attack on
    # the privileged reader is never reported as a capability's malformed JSON.
    RESULT_MISSING = "result_missing"
    RESULT_INVALID = "result_invalid"
    OUTPUT_TREE_POLICY_VIOLATION = "output_tree_policy_violation"

    # Quarantine
    QUARANTINE_COLLECTION_INCOMPLETE = "quarantine_collection_incomplete"
    QUARANTINE_INCOMPLETE_INTEGRITY_FAILURE = (
        "quarantine_incomplete_integrity_failure")
    QUARANTINE_BACKING_STORE_MISMATCH = "quarantine_backing_store_mismatch"
    QUARANTINE_BACKING_STORE_CONFIG_INTEGRITY_FAILURE = (
        "quarantine_backing_store_config_integrity_failure")

    # Implementation authority
    IMPLEMENTATION_AUTHORITY_INTEGRITY_FAILURE = (
        "implementation_authority_integrity_failure")
    IMPLEMENTATION_AUTHORITY_SCAN_LIMIT_EXCEEDED = (
        "implementation_authority_scan_limit_exceeded")
    IMPLEMENTATION_AUTHORITY_FINDINGS_TRUNCATED = (
        "implementation_authority_findings_truncated")
    IMPLEMENTATION_AUTHORITY_CAPACITY_EXHAUSTED = (
        "implementation_authority_capacity_exhausted")

    # Administrative
    ADMINISTRATIVE_RECORD_INTEGRITY_FAILURE = (
        "administrative_record_integrity_failure")
    ADMINISTRATIVE_RECORD_UNEXPECTED_OBJECT = (
        "administrative_record_unexpected_object")
    ADMINISTRATIVE_INTEGRITY_FINDINGS_TRUNCATED = (
        "administrative_integrity_findings_truncated")
    ADMINISTRATIVE_INTEGRITY_SCAN_LIMIT_EXCEEDED = (
        "administrative_integrity_scan_limit_exceeded")
    INSPECTION_AUDIT_COMMIT_FAILED = "inspection_audit_commit_failed"

    # Mutation
    MUTATION_JOURNAL_INTEGRITY_FAILURE = "mutation_journal_integrity_failure"

    @classmethod
    def of(cls, reason: str) -> "Classification":
        """The classification for ``reason``, or refuse.

        Refusing is the behaviour under test. A caller that cannot name its
        failure in the accepted vocabulary has found a specification gap, and
        the gap should stop it rather than be papered over with a new string.
        """
        try:
            return cls(reason)
        except ValueError:
            raise UnknownClassification(
                f"{reason!r} is not a specified classification") from None


@enum.unique
class LifecycleState(enum.Enum):
    """The §16 lifecycle, in order.

    Declaration order is the specification's order and is relied upon: the
    states are read positionally when a transition is checked, so reordering
    them would silently redefine which transitions are legal.
    """

    RESERVED = "reserved"
    LAUNCH_AUTHORIZED = "launch_authorized"
    CREATED = "created"
    CONTAINER_VERIFIED = "container_verified"
    START_AUTHORIZED = "start_authorized"
    STARTED = "started"
    RUNNING = "running"
    TERMINAL = "terminal"
    CLASSIFIED = "classified"
    COLLECTED = "collected"
    CLEANED = "cleaned"
    RELEASED = "released"


@dataclasses.dataclass(frozen=True)
class Mount:
    """One mount in the governed topology.

    Compared by destination rather than by the order a runtime happens to
    report, because mount order carries no meaning while destination does.
    """

    destination: str
    read_only: bool
    source_kind: str


@dataclasses.dataclass(frozen=True)
class ExecutionProfile:
    """The §12 runtime profile, owned by the adapter.

    Every field is adapter-owned. No capability, package, or caller value
    reaches this type — that is enforced where the profile is built, and the
    type exists so the built result cannot be edited afterwards.

    No field carries a default. A security control that could be omitted at
    construction is one that can be forgotten, and a forgotten control looks
    exactly like a control nobody needed.
    """

    cinv: str
    image_digest: str
    network: str
    memory_bytes: int
    memory_swap_bytes: int
    cpus: str
    pids_limit: int
    timeout_seconds: int
    grace_seconds: int
    read_only_rootfs: bool
    no_new_privileges: bool
    cap_drop_all: bool
    tmpfs_bytes: int
    profile_schema_version: int
    cimp: str
    adapter_identity: str
    payload_schema_version: int
    execution_uid: int
    execution_gid: int
    hostname: str
    cpu_quota_us: int
    cpu_period_us: int
    tmpfs_mode: int
    tmpfs_options: tuple[str, ...]
    dropped_capabilities: tuple[str, ...]
    mounts: tuple[Mount, ...]
    devices: tuple[str, ...]
    sockets: tuple[str, ...]
    privileged: bool
    host_network: bool
    host_pid: bool
    gpu: bool


@dataclasses.dataclass(frozen=True)
class ExecutionFingerprint:
    """The security-critical identity an observed container must match.

    Carried separately from the profile digest because §17 requires both: the
    canonical digest proves the profile was not edited, and these explicit
    fields let a mismatch say which property diverged rather than only that
    something did.
    """

    cinv: str
    profile_digest: str
    image_digest: str
    cimp: str
    adapter_identity: str
    profile_schema_version: int
    execution_uid: int
    execution_gid: int


@dataclasses.dataclass(frozen=True)
class SlotReservation:
    """One of the two global execution slots, held for one invocation.

    Deliberately carries no timestamp. A reservation's authority comes from
    the durable record that created it, never from how old it looks, and a
    clock-derived field here would invite exactly that inference.
    """

    cinv: str
    slot_index: int
