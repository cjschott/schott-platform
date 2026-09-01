"""Coordinator-side supervision of one governed execution.

**It satisfies the adapter contract from the other side of the boundary.** The
coordinator has always taken an object with `execute(binding) -> AdapterOutcome`
and persisted what came back. Until G11-AT the only implementation was
`PythonPodmanAdapter`, which runs *inside the worker* — so the released path had
an adapter seam nothing could fill, and `cli.py` called
`prepare_invocation` with no adapter at all. This is the implementation that
fits: it drives the privileged launch, speaks the protocol, and concludes an
outcome from what the worker reported.

**It starts no process and it holds no Podman authority.** Everything under
`tools/capability/` is asserted to reach no subprocess, and that is not relaxed
here. Launching the transition is an injected collaborator, reconciliation is an
injected collaborator, and neither of them is constructed in this package.

**It observes nothing and it re-derives nothing.** The coordinator cannot see
the container — it has no runtime authority and must not gain any — so every
fact below arrived over the protocol as a conclusion somebody else reached. T8
compared the observed profile, T13 classified the terminal state, T14 admitted
the result. What this adds is sequencing, correlation, and the one decision that
is genuinely the coordinator's: whether to authorise the start.

**Start is authority.** `start_now` is the only message this side sends in the
normal flow, and it is reachable exactly once, only after `verified_profile` was
received and checked, and only naming the container `created` announced. A
worker cannot start a workload it was not granted.

**Disposal is proven before a result is concluded.** A supervised execution that
cannot prove its container is gone does not return a terminal outcome at all: it
raises, so no `CRES` is written and the invocation stays unresolved for the
readiness gate to find. Recording success beside a container that may still be
running is the one outcome this whole boundary exists to prevent, and a
`disposal_proven=False` flag on a successful record would be exactly that with a
footnote.

**Process death is not a terminal state.** End of stream means the worker
stopped talking, which says nothing about the container. It is never mapped to
an execution outcome; it routes to reconciliation, and what reconciliation
proves is what gets reported.
"""

from __future__ import annotations

import dataclasses
from typing import Any

from .adapter import AdapterOutcome
from .protocol import (Channel, MessageKind, ProtocolEnded, ProtocolError,
                       ProtocolViolation)
from .types import Classification

# How long the worker is given to finish after the conversation ends, before it
# is considered stuck. Bounded because a supervisor that could wait forever is
# one that never reports, and an unreported execution is indistinguishable from
# a lost one.
REAP_TIMEOUT_SECONDS = 30

class SupervisionRefused(ValueError):
    """The supervised execution will not be concluded, and says why.

    Raised rather than returned. A refusal here means either the conversation
    could not be trusted or the container's disposal could not be proven, and in
    both cases the correct durable state is *no terminal record* — an invocation
    that stays unresolved is one the readiness gate will find, while a `CRES`
    saying "adapter-error" would close the question without answering it.
    """

    def __init__(self, message: str, *, cinv: Any = None,
                 classification: Classification | None = None,
                 reconciled: Any = None) -> None:
        super().__init__(message)
        self.cinv = cinv
        self.classification = classification
        self.reconciled = reconciled


@dataclasses.dataclass(frozen=True)
class SupervisedTerminal:
    """The runtime facts the worker reported, in the shape the record reads.

    Deliberately not a `TerminalClassification`. That type is T13's conclusion
    built from an observation this side never made, and constructing one here
    would be this module claiming to have classified something it only heard
    about. What the durable record actually reads off a terminal is the two
    timestamps, so those are what this carries, beside the facts that explain
    them.
    """

    container_id: str
    lifecycle_state: str
    outcome_class: str
    exit_code: Any
    started_proven: bool
    started_at: Any
    finished_at: Any


@dataclasses.dataclass(frozen=True)
class SupervisionTrace:
    """What the supervisor observed happening, for the caller to report.

    Carried separately from the outcome because it is evidence about the
    *supervision*, not about the capability: which protocol states were reached,
    how the worker process ended, and what reconciliation proved. A caller that
    wants to explain an interruption needs this; the durable result does not.
    """

    cinv: str
    states: tuple[str, ...]
    worker_exit: Any
    worker_reaped: bool
    protocol_complete: bool
    reconciled: Any
    disposal_proven: bool


@dataclasses.dataclass(frozen=True)
class SupervisedBinding:
    """What the coordinator knows about an execution it will not perform.

    Deliberately **not** an `ExecutionBinding`. That type carries the argv, the
    environment and the output descriptor, and its whole point is that those are
    governed values somebody constructed once; the coordinator constructs none
    of them and never sees them. A supervised binding with an empty argv would
    be that type wearing a value that is not true of it.

    Three fields, and each is something the coordinator genuinely holds: the
    invocation it authorised, the profile it published, and the digest it sealed
    that profile under.
    """

    cinv: str
    profile: Any
    profile_digest: str


def _require_binding(binding: Any) -> SupervisedBinding:
    if not isinstance(binding, SupervisedBinding):
        raise SupervisionRefused("a SupervisedBinding is required")
    return binding


def _require_same_container(expected: Any, message: Any) -> str:
    """Every later message must name the container `created` announced.

    A conversation that changed container half way through would be two
    executions wearing one invocation's name, and every check after that point
    would be about the wrong object.
    """
    named = message.field_map().get("container_id")
    if expected is not None and named != expected:
        raise ProtocolViolation(
            f"{message.kind.value} names a different container")
    return named


class ExecutionSupervisor:
    """The coordinator's half of one governed execution.

    Collaborators are injected because each is a boundary somebody else governs:
    the launcher is the only thing in the platform that starts the privileged
    transition, the reconciler is the governed cleanup operation G11-AQ built,
    and the clock is what a bounded wait is measured against. Constructing any
    of them here would be this module granting itself the authority the split
    exists to deny it.
    """

    def __init__(self, *, launcher: Any, reconciler: Any) -> None:
        self._launcher = launcher
        self._reconciler = reconciler
        # What the last supervised execution did, whether it concluded or not.
        self.trace: SupervisionTrace | None = None

    # --- the conversation ---------------------------------------------------

    def _expect(self, channel: Any, kind: Any, states: list) -> Any:
        """The next message, which must be ``kind`` or a terminating one.

        `receive` refuses anything the current state does not permit, so
        ordering is the protocol's decision and not a check repeated here. What
        this adds is the distinction the supervisor has to act on: an `error`
        arriving where `started` was due is a conclusion the worker reached, and
        a `terminal` arriving there is a worker that has lost the thread.
        """
        message = channel.receive()
        states.append(channel.state.value)
        if message.kind is kind:
            return message
        if message.kind is MessageKind.ERROR:
            detail = message.field_map().get("detail")
            raise SupervisionRefused(
                f"the worker reported {detail} while {kind.value} was due",
                classification=Classification.of(detail))
        raise ProtocolViolation(
            f"expected {kind.value}, received {message.kind.value}")

    def _check_verified_profile(self, binding: SupervisedBinding, message: Any,
                                container_id: str) -> None:
        """Confirm the worker verified the profile THIS coordinator published.

        **T8 is not repeated here and could not be.** The comparison that
        matters is between the governed profile and the container Podman
        actually created, and the observation exists only on the worker's side
        of the boundary. The worker performing it is the authority, and a
        coordinator that re-ran it would be a second opinion built from less
        evidence.

        What is checkable here is correlation, and it is the part that would
        otherwise be assumed: that the profile the worker verified is the one
        this invocation sealed, for this implementation, this image and this
        identity. A worker that verified some other well-formed profile
        perfectly would still not have verified this one.
        """
        fields = message.field_map()
        expected = {
            "container_id": container_id,
            "profile_digest": binding.profile_digest,
            "oci_image_id": binding.profile.oci_image_id,
            "cimp": binding.profile.cimp,
            "profile_schema_version": binding.profile.profile_schema_version,
            "execution_uid": binding.profile.execution_uid,
            "execution_gid": binding.profile.execution_gid,
        }
        for name, value in expected.items():
            if fields.get(name) != value:
                raise ProtocolViolation(
                    f"the verified profile reports {name}="
                    f"{fields.get(name)!r}, and this invocation published "
                    f"{value!r}")

    def _converse(self, binding: SupervisedBinding, channel: Any,
                  states: list) -> tuple[str, Any, Any]:
        """Drive the accepted sequence, or refuse. Returns terminal facts.

        The order is the protocol's and every step is a gate on the next:
        nothing is authorised before the profile is verified, nothing is
        collected before a terminal state is reached, and the coordinator sends
        exactly one message in the whole exchange.
        """
        created = self._expect(channel, MessageKind.CREATED, states)
        container_id = _require_same_container(None, created)

        verified = self._expect(channel, MessageKind.VERIFIED_PROFILE, states)
        _require_same_container(container_id, verified)
        self._check_verified_profile(binding, verified, container_id)

        # The one authority-bearing message, and the only one this side sends.
        # It is reachable here and nowhere else: the channel's own state machine
        # refuses `start_now` before `verified_profile`, so an earlier send is
        # not a mistake this code could make.
        channel.send(MessageKind.START_NOW, container_id=container_id)
        states.append(channel.state.value)

        started = self._expect(channel, MessageKind.STARTED, states)
        _require_same_container(container_id, started)

        terminal_message = self._expect(channel, MessageKind.TERMINAL, states)
        _require_same_container(container_id, terminal_message)
        facts = terminal_message.field_map()
        terminal = SupervisedTerminal(
            container_id=container_id,
            lifecycle_state=facts["lifecycle_state"],
            outcome_class=facts["outcome_class"],
            exit_code=facts["exit_code"],
            started_proven=facts["started_proven"],
            started_at=facts["started_at"],
            finished_at=facts["finished_at"])

        collected = self._expect(channel, MessageKind.COLLECTED, states)
        return container_id, terminal, collected.field_map()

    # --- conclusions --------------------------------------------------------

    def _conclude(self, binding: SupervisedBinding, container_id: str,
                  terminal: SupervisedTerminal,
                  collected: dict) -> AdapterOutcome:
        """Turn reported facts into the outcome the coordinator records.

        **Nothing is recomputed.** The outcome class is T13's own conclusion,
        carried on the wire rather than re-derived here from the two facts that
        happen to travel beside it -- a supervisor that recomputed it could not
        see `timed_out` at all and would silently file every timeout as a
        provider error. The admission verdict is the presence of the digest T14
        concluded. This module adds no judgement of its own, which is why it can
        be short.

        `succeeded` is the digest's presence and nothing else. A workload that
        exited zero and produced no result is `completed` with nothing admitted,
        which `record_terminal_result` already names `result_missing` — the case
        that used to read as success.
        """
        digest = collected.get("result_digest")
        return AdapterOutcome(
            cinv=binding.cinv,
            container_id=container_id,
            outcome_class=terminal.outcome_class,
            classification=None,
            terminal=terminal,
            result=None,
            output=None,
            started_proven=terminal.started_proven,
            succeeded=digest is not None,
            result_digest=f"sha256:{digest}" if digest else None)

    def _dispose(self, cinv: str) -> Any:
        """Prove the container is gone, through the one governed operation.

        Called on every path, success included, because a report that the
        container was cleaned is weaker evidence than an operation that looked.
        Reconciliation is idempotent and treats absence as success, so this is
        cheap where nothing is left and conclusive where something is.

        The supervisor holds no Podman authority: this is the injected
        collaborator that crosses the privilege boundary, and the only value
        that crosses with it is the `CINV`.
        """
        try:
            report = self._reconciler(cinv)
        except Exception as error:  # noqa: BLE001 - any failure is unproven
            raise SupervisionRefused(
                f"the container's disposal could not be established: {error}",
                cinv=cinv) from None
        if not isinstance(report, dict) or report.get("final_absent") is not True:
            raise SupervisionRefused(
                "reconciliation did not prove the container absent",
                cinv=cinv, reconciled=report)
        return report

    # --- the adapter contract -----------------------------------------------

    def execute(self, binding: Any) -> AdapterOutcome:
        """Supervise one execution and return what was established, or refuse.

        The child is launched, the conversation is driven, the process is
        reaped, and the container's disposal is proven — in that order, and the
        last two happen whatever the conversation did. A supervisor that
        returned without reaping would leave a zombie; one that returned without
        proving disposal would be reporting an outcome beside a container it did
        not look for.
        """
        binding = _require_binding(binding)
        states: list[str] = []
        child = self._launcher.launch(binding.cinv)
        channel = Channel(binding.cinv, reader=child.reader, writer=child.writer)

        failure: SupervisionRefused | None = None
        result: tuple[str, Any, dict] | None = None
        try:
            result = self._converse(binding, channel, states)
        except SupervisionRefused as error:
            failure = error
        except ProtocolEnded as error:
            # The worker stopped talking. That is a process fact and says
            # nothing about the container, so it is never mapped to an execution
            # outcome -- reconciliation below is what decides what is true.
            failure = SupervisionRefused(
                f"the worker ended the conversation: {error}",
                cinv=binding.cinv)
        except ProtocolError as error:
            failure = SupervisionRefused(
                f"the conversation could not be trusted: {error}",
                cinv=binding.cinv,
                classification=Classification.EXECUTION_PROTOCOL_VIOLATION)
        except OSError as error:
            # The descriptor failed rather than the protocol: a worker that
            # died while this side was writing gives a broken pipe, not an
            # end of stream. It means the same thing and gets the same
            # treatment -- a process fact, carrying no claim about the
            # container, routed to reconciliation below.
            failure = SupervisionRefused(
                f"the worker's stream failed: {error}", cinv=binding.cinv)
        finally:
            exit_status, reaped = child.reap(REAP_TIMEOUT_SECONDS)

        # Recorded before anything is raised or returned, because a caller
        # explaining an interruption needs to know how far the conversation got
        # and what the worker process did -- and both are facts about a run that
        # failed just as much as one that did not.
        def remember(reconciled, disposal_proven):
            self.trace = SupervisionTrace(
                cinv=binding.cinv, states=tuple(states),
                worker_exit=exit_status, worker_reaped=reaped,
                protocol_complete=result is not None,
                reconciled=reconciled, disposal_proven=disposal_proven)

        try:
            reconciled = self._dispose(binding.cinv)
        except SupervisionRefused as error:
            remember(error.reconciled, False)
            raise
        remember(reconciled, True)

        if failure is not None:
            failure.reconciled = reconciled
            raise failure
        if not reaped:
            raise SupervisionRefused(
                "the worker process could not be reaped", cinv=binding.cinv,
                reconciled=reconciled)

        container_id, terminal, collected = result
        return self._conclude(binding, container_id, terminal, collected)
