"""Finding and resolving executions whose supervision was lost.

**The Capability Runtime records are the source of truth, not Podman.** The
coordinator has no runtime authority and must not gain any, so it cannot ask
"what containers exist" and must not be able to. What it can ask is "which
invocations did this platform authorise an adapter for, and never record a
result about" — and that question is answered entirely from records it already
owns.

**The signature of a lost execution, and there are two of them.** G11-AO made
this decidable for a locally executed adapter by writing the adapter identity
onto the invocation record *before* the adapter is entered. So an invocation
carrying `adapter_identity` with no terminal `CRES` is one where execution was
authorised and its outcome was never established. That is not the same as a
failure — a failure has a result saying so — and it is exactly the state a
killed worker or a killed coordinator leaves behind.

**The supervised path leaves no adapter identity, and G11-BB found out the hard
way.** `command_invoke` supplies neither adapter nor execution binding by
construction, so the field is null on every supervised invocation, and nothing
later fills it because `CINV` is immutable. Keying discovery on that field alone
made supervised invocations invisible to the one surface built to find them: a
container orphaned after `authorise-launch` would have been reported as nothing
to see. So the supervised path is recognised by the evidence it does leave — the
lifecycle transition journal, written before the privileged boundary is crossed
and immutable thereafter. Either signature qualifies; neither replaces the
other.

**It synthesises nothing.** No `CRES` is written for an interrupted invocation,
and the invocation record is never touched. `CINV` is the immutable
pre-execution evidence, and recording completion by editing it would destroy the
property that makes an interruption attributable at all. What this module does
is prove what became of the *container*, which is a different question with a
different answer.

**Reconciliation is injected and takes one `CINV`.** The governed operation
G11-AQ built and G11-AS made reachable. There is no path here to a container
name, an image, a Podman argv or a second invocation's material; a caller that
wanted one would have to add it.

**Idempotent by construction.** Reconciliation treats absence as success, so a
second pass over the same invocations proves the same thing and changes nothing:
no record is written, no identity allocated, and nothing in the runtime store
advances.

**Safety is not capacity.** A platform with free slots and an invocation whose
container might still be running is not safe to execute anything on, because the
one guarantee execution rests on -- that a governed container belongs to exactly
one live invocation -- is currently unproven. The gate says so.

**It is named for safety rather than for readiness deliberately.** What it
decides is the readiness gate this checkpoint was asked for, but the Capability
Runtime is architecturally barred from the health and orchestration plane --
liveness, heartbeat, scheduling -- and `tests/test-capability-runtime.sh`
enforces that by name. Borrowing that plane's vocabulary for a question decided
entirely from this package's own records would make the boundary harder to see
for no gain, and "is it safe to admit new execution" is the more exact
question anyway.
"""

from __future__ import annotations

import dataclasses
from typing import Any

from ..records import INVOCATION_KIND, RESULT_KIND
from . import state as state_module
from .types import LifecycleState

# The lifecycle order, so "has this invocation reached the point where a
# container could exist" is a comparison rather than a set somebody maintains.
_LIFECYCLE_ORDER: tuple[LifecycleState, ...] = (
    LifecycleState.RESERVED,
    LifecycleState.LAUNCH_AUTHORIZED,
    LifecycleState.CREATED,
    LifecycleState.CONTAINER_VERIFIED,
    LifecycleState.START_AUTHORIZED,
    LifecycleState.STARTED,
    LifecycleState.RUNNING,
    LifecycleState.TERMINAL,
    LifecycleState.CLASSIFIED,
    LifecycleState.COLLECTED,
    LifecycleState.CLEANED,
    LifecycleState.RELEASED,
)

# `LAUNCH_AUTHORIZED` and not `CREATED`, deliberately. The container is created
# by the worker on the far side of the privilege drop, and the state advances
# to `CREATED` only once the coordinator learns of it. Between those two facts
# a container can exist that no state records, so the conservative boundary is
# the last state the coordinator wrote *before* handing over.
_CONTAINER_POSSIBLE_FROM = LifecycleState.LAUNCH_AUTHORIZED

# What a finding concluded about one unresolved invocation's container.
DISPOSITION_ABSENT = "absent"
DISPOSITION_RECONCILED = "reconciled"
DISPOSITION_UNRESOLVED = "unresolved"

# The two readiness verdicts. There is no third: "probably" is the answer this
# gate exists to refuse to give.
READY = "ready"
NOT_READY = "not-ready"


@dataclasses.dataclass(frozen=True)
class Unresolved:
    """One invocation that authorised execution and recorded no outcome."""

    invocation_record_id: str
    invocation_id: Any
    # Why this invocation is unresolved. `adapter_identity` is the locally
    # executed adapter's evidence and is absent on the supervised path;
    # `lifecycle_state` is the supervised path's, read from the immutable
    # transition journal. At least one is always present.
    adapter_identity: Any = None
    lifecycle_state: Any = None


@dataclasses.dataclass(frozen=True)
class Finding:
    """What became of one unresolved invocation's container.

    ``interrupted`` is always true here and is stated rather than implied: every
    invocation this module reports on is one with no terminal result, and that
    is the honest reading whatever reconciliation found. Proving the container
    gone resolves the *container*; it does not turn a lost execution into a
    completed one.
    """

    invocation_record_id: str
    invocation_id: Any
    disposition: str
    interrupted: bool
    final_absent: bool
    reason: Any
    report: Any


@dataclasses.dataclass(frozen=True)
class ExecutionSafety:
    """Whether new execution may safely be accepted, and what is blocking it."""

    state: str
    unresolved: tuple[Finding, ...]
    checked: int

    @property
    def ready(self) -> bool:
        return self.state == READY


def _invocation_identity(record: Any) -> Any:
    """The `CINV` reconciliation takes, as the record itself names it."""
    return record.get("invocation_id") or record.get("invocation_record_id")


def _lifecycle_states(execution_root: Any) -> dict[str, LifecycleState]:
    """Every `CINV`'s current lifecycle state, or nothing readable.

    An unreadable journal is reported as no states rather than raised, because
    the caller's other signal still stands and a recovery surface that raised
    here would be a recovery surface nobody could run.
    """
    if execution_root is None:
        return {}
    try:
        return state_module.all_states(execution_root)
    except Exception:  # noqa: BLE001 - an unreadable journal is not a verdict
        return {}


def _container_possible(state: Any) -> bool:
    """Whether a container could exist for an invocation in ``state``."""
    if not isinstance(state, LifecycleState):
        return False
    try:
        return (_LIFECYCLE_ORDER.index(state)
                >= _LIFECYCLE_ORDER.index(_CONTAINER_POSSIBLE_FROM))
    except ValueError:
        return False


def unresolved_invocations(store: Any, *,
                           execution_root: Any = None) -> tuple[Unresolved, ...]:
    """Every invocation that authorised execution and has no terminal result.

    Read from this package's own durable records and nothing else. There is no
    container enumeration here and no runtime call: the coordinator is
    answering a question about its own state, which is the only question it has
    the authority to ask.

    **Two signatures, because there are two execution paths.**

    A locally executed adapter writes ``adapter_identity`` onto the invocation
    before it is entered, and G11-AO made that the signature of a lost
    execution. **The supervised path never writes it.** `command_invoke`
    supplies neither adapter nor execution binding by construction, so the
    bound adapter identity is ``None``, and `record_terminal_result` never
    touches the invocation afterwards -- correctly, because `CINV` is immutable
    pre-execution evidence and filling it later would destroy that. G11-BB
    found the consequence: a supervised invocation that lost supervision after
    creating a container was invisible to the one surface built to find it.

    So the supervised path is recognised by the evidence it *does* leave: the
    lifecycle transition journal, written by `authorise_launch` before the
    privileged boundary is crossed and immutable thereafter. An invocation at
    or beyond ``launch_authorized`` with no terminal result is one where
    execution was authorised and its outcome was never established.

    **Neither signature is dropped.** An invocation qualifies on either, so the
    locally executed path keeps exactly the behaviour it had and the supervised
    path gains the coverage it never had. ``execution_root`` is optional so a
    caller without a journal still gets the original answer rather than an
    error.
    """
    resolved = {record.get("invocation_record_id")
                for record in store.list_records(RESULT_KIND)}
    states = _lifecycle_states(execution_root)
    found: list[Unresolved] = []
    for record in store.list_records(INVOCATION_KIND):
        adapter_identity = record.get("adapter_identity")
        identity = _invocation_identity(record)
        state = states.get(identity) if isinstance(identity, str) else None
        if not adapter_identity and not _container_possible(state):
            continue
        record_id = record.get("invocation_record_id")
        if record_id in resolved:
            continue
        found.append(Unresolved(
            invocation_record_id=record_id,
            invocation_id=identity,
            adapter_identity=adapter_identity,
            lifecycle_state=(state.value if isinstance(state, LifecycleState)
                             else None)))
    return tuple(found)


def reconcile_unresolved(store: Any, *, reconciler: Any,
                         execution_root: Any = None) -> tuple[Finding, ...]:
    """Prove what became of every unresolved invocation's container.

    One governed reconciliation per invocation, by `CINV`. A refusal, an
    ambiguity, or a report that does not prove absence each yields an
    ``unresolved`` finding rather than an exception: the caller needs the whole
    picture to decide readiness, and stopping at the first problem would hide
    every one after it.

    Nothing here writes. The store is read for the enumeration and never
    reopened for a mutation, which is what makes running this twice harmless.
    """
    findings: list[Finding] = []
    for invocation in unresolved_invocations(
            store, execution_root=execution_root):
        cinv = invocation.invocation_id
        try:
            report = reconciler(cinv)
        except Exception as error:  # noqa: BLE001 - any failure is unresolved
            findings.append(Finding(
                invocation_record_id=invocation.invocation_record_id,
                invocation_id=cinv, disposition=DISPOSITION_UNRESOLVED,
                interrupted=True, final_absent=False,
                reason=f"reconciliation did not complete: {error}",
                report=None))
            continue
        outcome = report.get("outcome") if isinstance(report, dict) else None
        absent = isinstance(report, dict) and report.get("final_absent") is True
        if not absent:
            findings.append(Finding(
                invocation_record_id=invocation.invocation_record_id,
                invocation_id=cinv, disposition=DISPOSITION_UNRESOLVED,
                interrupted=True, final_absent=False,
                reason=(report.get("reason") if isinstance(report, dict)
                        else "the reconciliation report is unreadable"),
                report=report))
            continue
        findings.append(Finding(
            invocation_record_id=invocation.invocation_record_id,
            invocation_id=cinv,
            # Absence that was already true is a safe interrupted state;
            # absence this operation had to establish is a recovery. Both are
            # resolved, and the caller can tell them apart because an operator
            # reading a recovery learns something a no-op would not have told
            # them.
            disposition=(DISPOSITION_ABSENT if outcome == "absent"
                         else DISPOSITION_RECONCILED),
            interrupted=True, final_absent=True, reason=None, report=report))
    return tuple(findings)


def execution_safety(store: Any, *, reconciler: Any,
                     execution_root: Any = None) -> ExecutionSafety:
    """Whether new execution may be accepted on this deployment.

    **Not a capacity question.** Free slots say a container could be created;
    this says whether creating one would be safe. An invocation whose container
    might still be running means the platform cannot currently promise that a
    governed container belongs to exactly one live invocation, and that promise
    is what every later verification is built on.

    Ready means every unresolved invocation's container was *proven* absent. An
    empty store is ready for the same reason: there is nothing unproven.
    """
    findings = reconcile_unresolved(store, reconciler=reconciler,
                                    execution_root=execution_root)
    blocking = tuple(finding for finding in findings
                     if finding.disposition == DISPOSITION_UNRESOLVED)
    return ExecutionSafety(state=NOT_READY if blocking else READY,
                          unresolved=blocking, checked=len(findings))
