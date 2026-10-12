"""The one governed execution adapter for ENG-0005.

**It orchestrates and it decides nothing.** Every judgement below belongs to a
module that already made it: the profile comparison is T8's, the terminal
classification is T13's, result admission is T14's, and the outcome class this
returns is copied from T13 rather than recomputed. An adapter that re-derived
any of them would be a second opinion, and a second opinion is the thing a
governed runtime cannot have.

**No authority is duplicated here.** There is no JSON parser, no package
validation, no argv construction, no filesystem traversal, no cleanup, no
quarantine, and no `CADM`. Those exist once each, and this module reaches them
rather than reimplementing them — which is also why it is short.

**It never manufactures a favourable conclusion.** If the workload cannot be
excluded from having run, nothing here says it did not: the adapter has no
`transition_failed_before_execution` to emit, invents no cleanup success, and
turns no ambiguity into a clean lifecycle. What it cannot establish, it reports
as unestablished and leaves to reconciliation.

**Nothing is started twice and nothing is retried.** One create, one
authorised start, one terminal reading. A failure is reported where it happened
and stops there.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md``
§7 and §9.
"""

from __future__ import annotations

import dataclasses
from typing import Any

from . import collector as collector_module
from . import lifecycle as lifecycle_module
from .profile import ExecutionProfile, ProfileMismatch, verify_observed
from .protocol import MessageKind, ProtocolError
from .types import Classification

# What the adapter is allowed to conclude on its own: nothing. Every value here
# arrives from T13, and the mapping exists only so the coordinator can read one
# field instead of five.
OUTCOME_ADAPTER_ERROR = "adapter-error"

# The governed name of the result file, as the collector writes it into its own
# manifest. Imported rather than restated so the digest below and the file T14
# admitted cannot come to mean different files.
RESULT_NAME = collector_module.RESULT_NAME


def _admitted_digest(result: Any) -> str | None:
    """The digest of the result T14 admitted, or nothing.

    Read from the collector's own manifest entry for the governed result file,
    in the released `sha256:<64hex>` form. Deliberately not recomputed: the
    bytes that were admitted are the bytes hashed during collection, and hashing
    whatever is on disk now would answer a different question.

    It lives here rather than in the coordinator, where it used to, because
    "which file was the result" is a conclusion of collection. A coordinator
    walking the manifest was a second reader of somebody else's evidence, and
    across the privilege boundary there is no manifest to walk at all.
    """
    if result is None:
        return None
    manifest = getattr(result, "manifest", None)
    for entry in getattr(manifest, "files", ()) or ():
        if getattr(entry, "relative_path", None) == RESULT_NAME:
            return f"sha256:{entry.sha256}"
    return None


@dataclasses.dataclass(frozen=True)
class ExecutionBinding:
    """One governed execution, already bound and already verified.

    The adapter builds none of this. The argv came from T12's construction, the
    profile from T8's adapter-owned values, and the identity from the
    coordinator; assembling any of them here would put a second author on the
    thing whose single authorship is the point.
    """

    cinv: str
    profile: ExecutionProfile
    # The digest the transition sealed and told the worker on argv. It is not a
    # field of the profile -- a document cannot carry its own hash -- and the
    # coordinator needs it back to confirm the worker verified the profile IT
    # published rather than some other well-formed one.
    profile_digest: str
    argv: tuple[str, ...]
    environment: tuple[tuple[str, str], ...]
    output_fd: int | None = None


@dataclasses.dataclass(frozen=True)
class AdapterOutcome:
    """What one execution established, and what it did not.

    ``succeeded`` is true only where T14 produced a trusted result, which needs
    every §11 condition. Everything else is reported as it was concluded
    elsewhere: this type carries findings, it does not form them.
    """

    cinv: str
    container_id: str | None
    outcome_class: str
    classification: Classification | None
    terminal: Any
    result: Any
    output: Any
    started_proven: bool
    succeeded: bool
    # The digest of the result T14 admitted, in the released `sha256:<64hex>`
    # form, or nothing. Concluded here rather than by whoever reads this: the
    # bytes that were admitted are the bytes collection hashed, and a second
    # walk of the manifest downstream would be a second opinion about which
    # file was the result. It is also the one field a supervised execution can
    # carry across the privilege boundary, where no manifest travels.
    result_digest: str | None = None


class AdapterRefused(ValueError):
    """The adapter will not proceed, and says why without concluding."""

    def __init__(self, message: str,
                 classification: Classification | None = None) -> None:
        super().__init__(message)
        self.classification = classification


class PythonPodmanAdapter:
    """The §7 adapter: create, verify, start on authority, read, collect.

    Collaborators are injected because every one of them is a boundary someone
    else governs — the runtime backend behind G6, the protocol session that
    carries start authority, and the clock the timeout is measured against.
    Constructing any of them here would be this module granting itself the
    authority it exists to be denied.
    """

    def __init__(self, *, backend: Any, session: Any, clock: Any) -> None:
        self._backend = backend
        self._session = session
        self._clock = clock

    def _verify(self, binding: ExecutionBinding, container_id: str) -> None:
        """T8 compares; this only carries the refusal."""
        observed = lifecycle_module.observe(self._backend, container_id)
        try:
            verify_observed(binding.profile, observed)
        except ProfileMismatch as error:
            raise AdapterRefused(
                f"the observed container does not match the governed profile: "
                f"{error}", Classification.EXECUTION_IDENTITY_MISMATCH) from None

    def _collect(self, binding: ExecutionBinding, terminal: Any) -> tuple[Any, Any]:
        """Collect through T14, and admit a result only where T14 permits.

        Collection happens whatever the terminal state says, because a failed
        execution's output is still evidence; admission is the part the gate
        governs. A refusal to admit is not a refusal to have looked.
        """
        if binding.output_fd is None:
            return None, None
        try:
            tree = collector_module.collect(binding.output_fd)
        except collector_module.OutputRefused:
            return None, None
        if not terminal.may_collect_result:
            return tree, None
        try:
            return tree, collector_module.read_result(tree, terminal)
        except collector_module.OutputRefused:
            return tree, None

    def _report(self, kind: Any, **fields: Any) -> None:
        """Tell the coordinator what was just established, or refuse.

        **Reporting is not deciding.** Every value here was concluded by the
        module that owns it a line earlier; this states it on the wire so the
        other side of the privilege boundary can see the same facts. The
        coordinator cannot observe the container -- it has no Podman authority
        and must not gain any -- so a fact that is not reported is a fact it
        will never have.

        A session that cannot send is refused rather than tolerated. Until
        G11-AT nothing ever called `protocol.encode` in production, which is
        exactly how the coordinator ended up blind, and a silent fallback here
        would restore that.
        """
        sender = getattr(self._session, "send", None)
        if sender is None:
            raise AdapterRefused(
                "a governed execution reports its progress; this session "
                "cannot send")
        sender(kind, **fields)

    def execute(self, binding: Any) -> AdapterOutcome:
        """Run one governed execution and report what was established.

        The order is the specification's: create, verify the observed container
        against the governed profile, start only when the coordinator has
        authorised it, read the lifecycle, let T13 classify it, and only then
        let T14 decide whether anything may be trusted.

        Each step is announced as it completes, which is what makes the
        conversation a supervision rather than a monologue: `created` before the
        coordinator could authorise anything, `verified_profile` before it
        should, `started` only after it did, and `terminal`/`collected` carrying
        the conclusions T13 and T14 reached.
        """
        if not isinstance(binding, ExecutionBinding):
            raise AdapterRefused("an ExecutionBinding is required")

        container_id: str | None = None
        try:
            container_id = lifecycle_module.create(
                self._backend, binding.argv, binding.environment)
            self._report(MessageKind.CREATED, container_id=container_id)

            self._verify(binding, container_id)
            self._report(
                MessageKind.VERIFIED_PROFILE, container_id=container_id,
                profile_digest=binding.profile_digest,
                oci_image_id=binding.profile.oci_image_id,
                cimp=binding.profile.cimp,
                profile_schema_version=binding.profile.profile_schema_version,
                execution_uid=binding.profile.execution_uid,
                execution_gid=binding.profile.execution_gid)

            started = self._clock()
            # The gate. `start_when_authorised` is what consumes `start_now`,
            # so the report below is only reachable once the coordinator has
            # granted it -- the worker cannot announce a start it was not given.
            lifecycle_module.start_when_authorised(
                self._backend, container_id, session=self._session)
            self._report(MessageKind.STARTED, container_id=container_id)

            observed = lifecycle_module.observe_lifecycle(
                self._backend, container_id)
        except AdapterRefused as error:
            return self._unestablished(binding, container_id, error.classification)
        except lifecycle_module.LifecycleRefused as error:
            # A lifecycle refusal is reported where it happened. It is not
            # turned into "never started": whether the workload ran is exactly
            # what this could not establish.
            return self._unestablished(binding, container_id, None, str(error))

        timed_out = lifecycle_module.timed_out(elapsed=self._clock() - started)
        terminal = lifecycle_module.classify(observed, timed_out=timed_out)
        self._report(
            MessageKind.TERMINAL, container_id=container_id,
            lifecycle_state=lifecycle_module.reported_state(observed),
            outcome_class=terminal.outcome_class,
            exit_code=terminal.exit_code,
            started_proven=terminal.started_proven,
            started_at=terminal.started_at, finished_at=terminal.finished_at)

        tree, result = self._collect(binding, terminal)
        digest = _admitted_digest(result)
        self._report(
            MessageKind.COLLECTED,
            result_digest=digest[len("sha256:"):] if digest else None,
            output_manifest_digest=None,
            stdout_truncated=False, stderr_truncated=False)

        return AdapterOutcome(
            cinv=binding.cinv,
            container_id=container_id,
            outcome_class=terminal.outcome_class,
            classification=terminal.classification,
            terminal=terminal,
            result=result,
            output=tree,
            started_proven=terminal.started_proven,
            succeeded=result is not None,
            result_digest=digest)

    def _unestablished(self, binding: ExecutionBinding, container_id: str | None,
                       classification: Classification | None,
                       detail: str = "") -> AdapterOutcome:
        """Report a failure without concluding what the workload did.

        Deliberately not `transition_failed_before_execution`: that
        classification asserts execution can be excluded, and reaching here
        means it cannot. The coordinator routes this into reconciliation, which
        is where a question this module cannot answer belongs.

        The failure is announced where the protocol still allows it. If it does
        not -- the conversation already ended, or the pipe is gone because the
        coordinator died first -- nothing further is attempted and nothing is
        pretended: the coordinator sees end of stream instead, which it already
        treats as an execution whose fate is unknown. That is the honest
        reading, and it is why this is narrow rather than a bare except.
        """
        if classification is not None:
            try:
                self._report(MessageKind.ERROR, detail=classification.value)
            except (AdapterRefused, ProtocolError, OSError):
                pass
        return AdapterOutcome(
            cinv=binding.cinv,
            container_id=container_id,
            outcome_class=OUTCOME_ADAPTER_ERROR,
            classification=classification,
            terminal=None,
            result=None,
            output=None,
            started_proven=False,
            succeeded=False)
