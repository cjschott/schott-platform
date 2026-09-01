"""Finding and resolving executions whose supervision was lost.

**The Capability Runtime records are the source of truth, not Podman.** The
coordinator has no runtime authority and must not gain any, so it cannot ask
"what containers exist" and must not be able to. What it can ask is "which
invocations did this platform authorise an adapter for, and never record a
result about" — and that question is answered entirely from records it already
owns.

**The signature of a lost execution.** G11-AO made this decidable by writing the
adapter identity onto the invocation record *before* the adapter is entered. So
an invocation carrying `adapter_identity` with no terminal `CRES` is one where
execution was authorised and its outcome was never established. That is not the
same as a failure — a failure has a result saying so — and it is exactly the
state a killed worker or a killed coordinator leaves behind.

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
    adapter_identity: str


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


def unresolved_invocations(store: Any) -> tuple[Unresolved, ...]:
    """Every invocation that authorised an adapter and has no terminal result.

    Read from the two record kinds and nothing else. There is no container
    enumeration here and no runtime call: the coordinator is answering a
    question about its own durable state, which is the only question it has the
    authority to ask.

    An invocation with no ``adapter_identity`` is not unresolved -- nothing was
    ever authorised to run, so there is no container it could have left. That is
    the distinction the field was added for.
    """
    resolved = {record.get("invocation_record_id")
                for record in store.list_records(RESULT_KIND)}
    found: list[Unresolved] = []
    for record in store.list_records(INVOCATION_KIND):
        adapter_identity = record.get("adapter_identity")
        if not adapter_identity:
            continue
        record_id = record.get("invocation_record_id")
        if record_id in resolved:
            continue
        found.append(Unresolved(
            invocation_record_id=record_id,
            invocation_id=_invocation_identity(record),
            adapter_identity=adapter_identity))
    return tuple(found)


def reconcile_unresolved(store: Any, *, reconciler: Any) -> tuple[Finding, ...]:
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
    for invocation in unresolved_invocations(store):
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


def execution_safety(store: Any, *, reconciler: Any) -> ExecutionSafety:
    """Whether new execution may be accepted on this deployment.

    **Not a capacity question.** Free slots say a container could be created;
    this says whether creating one would be safe. An invocation whose container
    might still be running means the platform cannot currently promise that a
    governed container belongs to exactly one live invocation, and that promise
    is what every later verification is built on.

    Ready means every unresolved invocation's container was *proven* absent. An
    empty store is ready for the same reason: there is nothing unproven.
    """
    findings = reconcile_unresolved(store, reconciler=reconciler)
    blocking = tuple(finding for finding in findings
                     if finding.disposition == DISPOSITION_UNRESOLVED)
    return ExecutionSafety(state=NOT_READY if blocking else READY,
                          unresolved=blocking, checked=len(findings))
