"""Reconcile one Kyri execution container. **Not installed by anything here.**

This file becomes `/usr/lib/kyri/python/kyri_exec_reconcile.py`, owned
`root:root`, mode `0444`. Installing it is part of the privileged helper
ceremony.

**Why this exists.** `podman start --attach` attaches a client; killing the
client does not stop the container. A worker that takes `SIGKILL` mid-execution
therefore leaves its container *running*, and neither escape is available: a
`finally` clause does not run after `SIGKILL`, and the coordinator has no
Podman authority and must not gain any. Without this operation, "worker death
leaves no orphan" is a promise the platform cannot keep.

**It is not Podman authority.** One operation, one invocation identity, and a
closed set of things it may do to exactly one container. It cannot list
containers, manage images, prune anything, or act on a container a caller
names. The only value that crosses from outside is a `CINV`.

**Name is not identity.** A name is a string anything could occupy, and this
operation stops and removes what it finds. So a container must carry the
governed label the runtime wrote -- which no caller can influence -- and the
label must name the same invocation as the lookup. Name-only agreement is
refused, because the whole point is to be certain before destroying something.

**Every uncertainty refuses.** An unreadable state, a state this does not
recognise, a label that disagrees, more than one candidate: each returns a
refusal that leaves the container exactly as it was. Reconciliation that cannot
prove what it is looking at does not act on it, and an orphan left visible is
better than an unrelated container removed.

**It concludes nothing about the capability.** Stopping a container says
nothing about how far the workload got, so this never writes a result and never
touches the invocation record. The invocation stays interrupted, which is the
honest reading of an execution whose supervision was lost.

Governed by ``docs/superpowers/specs/2026-08-10-capability-runtime-design.md``
§17 and the first-adapter design's lifecycle sections.

Intended installed ownership and mode: ``root:root``, ``0444``.
"""

from __future__ import annotations

from typing import Any

# The label the runtime writes on every governed execution container. Stated
# here as a literal rather than imported: this module installs beside the
# runtime library but is reached by a different entrypoint, and the tests hold
# the two copies together -- the same discipline `PROFILE_FD` already gets.
INVOCATION_LABEL = "io.kyri.invocation-id"

# The deterministic name, derived from the CINV and nothing else. Duplicated
# from `worker.container_name` for the same reason and pinned by the same test.
NAME_PREFIX = "kyri-"

# How long a graceful stop is given before force. Bounded, because a
# reconciliation that could wait indefinitely is one that never finishes.
STOP_TIMEOUT_SECONDS = 5

_DIGITS = frozenset("0123456789")

# Every container state this operation recognises. Anything else refuses:
# acting on a state nobody enumerated is acting on a situation nobody reviewed.
STATE_CREATED = "created"
STATE_RUNNING = "running"
STATE_EXITED = "exited"
STATE_PAUSED = "paused"
STATE_STOPPING = "stopping"
KNOWN_STATES = (STATE_CREATED, STATE_RUNNING, STATE_EXITED, STATE_PAUSED,
                STATE_STOPPING)

# The closed outcome vocabulary returned to the coordinator.
OUTCOME_ABSENT = "absent"
OUTCOME_REMOVED_EXITED = "removed-exited"
OUTCOME_STOPPED_AND_REMOVED = "stopped-and-removed"
OUTCOME_REFUSED = "refused"
OUTCOME_FAILED = "failed"


class ReconciliationRefused(ValueError):
    """The container will not be touched, and the reason says why.

    A refusal always leaves the container exactly as it was found.
    """


def validate_cinv(value: Any) -> str:
    """The one value that crosses from outside, checked totally.

    No stripping, no case folding, no normalisation: each of those turns an
    input that should have been refused into one that was accepted.
    """
    if not isinstance(value, str):
        raise ReconciliationRefused("the invocation identity must be a string")
    if len(value) != 11 or not value.startswith("CINV-"):
        raise ReconciliationRefused("the invocation identity is not a CINV")
    if set(value[5:]) - _DIGITS:
        raise ReconciliationRefused("the invocation identity is not CINV-nnnnnn")
    return value


def container_name(cinv: str) -> str:
    """The deterministic name this CINV's container must have."""
    return f"{NAME_PREFIX}{validate_cinv(cinv)}"


def _identity_matches(document: Any, cinv: str) -> None:
    """Confirm this really is the container for this invocation, or refuse.

    Two independent facts, and both must agree. The name is what was looked up;
    the label is what the runtime wrote when it created the container and what
    no caller could influence. Requiring only the name would mean removing
    whatever happened to hold it.
    """
    if not isinstance(document, dict):
        raise ReconciliationRefused("the container inspection is not an object")

    expected = container_name(cinv)
    name = document.get("Name")
    if name != expected:
        raise ReconciliationRefused(
            f"the container is named {name!r}, not {expected!r}")

    config = document.get("Config")
    labels = config.get("Labels") if isinstance(config, dict) else None
    if not isinstance(labels, dict):
        raise ReconciliationRefused("the container carries no labels")
    bound = labels.get(INVOCATION_LABEL)
    if bound != cinv:
        raise ReconciliationRefused(
            f"the container is labelled for {bound!r}, not {cinv!r}; "
            "refusing rather than removing a container this did not create")


def _state(document: Any) -> str:
    state = document.get("State") if isinstance(document, dict) else None
    status = state.get("Status") if isinstance(state, dict) else None
    if not isinstance(status, str) or status.lower() not in KNOWN_STATES:
        raise ReconciliationRefused(
            f"the container is in state {status!r}, which this does not "
            "recognise; refusing rather than guessing what to do with it")
    return status.lower()


def reconcile(cinv: Any, *, backend: Any) -> dict[str, Any]:
    """Bring exactly one invocation's container to absent, or refuse.

    Idempotent by construction: the absent case is a success, so running this
    twice is safe and the second run does nothing. Nothing here is retried and
    nothing is forced past a refusal.

    ``backend`` is injected because Podman authority belongs to the execution
    identity, and this module is reached only after the privilege drop.
    """
    identity = validate_cinv(cinv)
    name = container_name(identity)
    report: dict[str, Any] = {
        "invocation_id": identity,
        "outcome": OUTCOME_REFUSED,
        "prior_state": None,
        "container_identity_verified": False,
        "final_absent": False,
        "reason": None,
    }

    try:
        document = backend.find_container(name)
    except Exception as error:  # noqa: BLE001 - any lookup failure is a refusal
        report["reason"] = f"the container state could not be read: {error}"
        return report

    if document is None:
        # Already absent. The common case after a normal execution, and the
        # terminal state this operation exists to reach.
        report.update({"outcome": OUTCOME_ABSENT, "prior_state": None,
                       "final_absent": True, "container_identity_verified": True})
        return report

    try:
        _identity_matches(document, identity)
        prior = _state(document)
    except ReconciliationRefused as error:
        report["reason"] = str(error)
        return report

    report["prior_state"] = prior
    report["container_identity_verified"] = True

    try:
        if prior in (STATE_RUNNING, STATE_PAUSED, STATE_STOPPING):
            # Bounded stop, then look again. Not fire-and-forget: the whole
            # value of this operation is that it can say the container is
            # stopped, which requires observing it.
            backend.stop_container(name, timeout=STOP_TIMEOUT_SECONDS)
            if _still_running(backend, name):
                backend.kill_container(name)
                if _still_running(backend, name):
                    report["outcome"] = OUTCOME_FAILED
                    report["reason"] = (
                        "the container is still running after a bounded stop "
                        "and kill")
                    return report
            outcome = OUTCOME_STOPPED_AND_REMOVED
        else:
            outcome = OUTCOME_REMOVED_EXITED

        backend.remove_container(name)
    except ReconciliationRefused as error:
        report["reason"] = str(error)
        return report
    except Exception as error:  # noqa: BLE001
        report["outcome"] = OUTCOME_FAILED
        report["reason"] = f"the container could not be reconciled: {error}"
        return report

    # Proven, not assumed. A remove that reported success while leaving the
    # container present would be exactly the false guarantee this exists to
    # avoid.
    try:
        remaining = backend.find_container(name)
    except Exception as error:  # noqa: BLE001
        report["outcome"] = OUTCOME_FAILED
        report["reason"] = f"the container's absence could not be confirmed: {error}"
        return report

    if remaining is not None:
        report["outcome"] = OUTCOME_FAILED
        report["reason"] = "the container is still present after removal"
        return report

    report.update({"outcome": outcome, "final_absent": True})
    return report


def _still_running(backend: Any, name: str) -> bool:
    document = backend.find_container(name)
    if document is None:
        return False
    state = document.get("State") if isinstance(document, dict) else None
    return bool(state.get("Running")) if isinstance(state, dict) else True


__all__ = ["INVOCATION_LABEL", "KNOWN_STATES", "OUTCOME_ABSENT",
           "OUTCOME_FAILED", "OUTCOME_REFUSED", "OUTCOME_REMOVED_EXITED",
           "OUTCOME_STOPPED_AND_REMOVED", "ReconciliationRefused",
           "container_name", "reconcile", "validate_cinv"]
