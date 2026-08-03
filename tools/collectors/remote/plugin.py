"""Shared lifecycle for remote collectors.

Three collectors need the same six steps: find the target and transport in the
context, validate the target, confirm every operation is authorised, run them,
refuse anything that failed, and parse what came back. Writing that three times
would mean an authorisation check could be fixed in one collector and stay
broken in the other two.

The transport is supplied by the caller and never constructed here. That is
what lets the entire path be exercised against a fake, and it means a collector
has no way to reach a host the orchestrator did not hand it.

Failure is all-or-nothing per collector. If any operation fails, the whole
collection fails and no observations are emitted. A record mixing fresh facts
with silently missing ones is read as complete, and this platform's core rule
is that absent measures are absent rather than zero.
"""

from __future__ import annotations

from typing import Any

from ...trust import gateway as trust_gateway
from ..base import CollectorPlugin
from ..exceptions import CollectorConfigurationError
from ..models import CollectionContext, Observation
from ..normalizer import normalize_observations
from .command_catalog import CatalogError, operation_for
from .models import RemoteExecutionResult, RemoteTarget
from .result import collection_failed, error_for, error_from_exception
from .target import TargetError, validate_target
from .transport import RemoteTransport


class RemoteCollectorPlugin(CollectorPlugin):
    """Base for collectors that observe an approved remote target."""

    # Operation identifiers this collector needs, in the order it runs them.
    OPERATIONS: tuple[str, ...] = ()

    def required_operations(self, context: CollectionContext) -> tuple[str, ...]:
        """Operations this collection will attempt. Overridden where the set
        depends on the target, as it does for named service units."""
        return self.OPERATIONS

    @staticmethod
    def _option(context: CollectionContext, name: str) -> Any:
        return (context.options or {}).get(name)

    def target_of(self, context: CollectionContext) -> RemoteTarget:
        target = self._option(context, "target")
        if target is None:
            raise CollectorConfigurationError(
                "a remote target must be supplied by the orchestrator; "
                "collectors do not discover or default one"
            )
        return target

    def transport_of(self, context: CollectionContext) -> RemoteTransport:
        transport = self._option(context, "transport")
        if transport is None:
            raise CollectorConfigurationError(
                "a remote transport must be supplied by the orchestrator"
            )
        return transport

    def validate_configuration(self, context: CollectionContext) -> None:
        target = self.target_of(context)
        self.transport_of(context)

        try:
            validate_target(target)
        except TargetError as error:
            raise CollectorConfigurationError(str(error)) from None

        if target.platform != self.manifest_platform:
            raise CollectorConfigurationError(
                f"target '{target.target_id}' declares platform "
                f"'{target.platform}'; this collector observes "
                f"'{self.manifest_platform}' targets"
            )

        # Host authorization is a trust decision, so it is asked rather than
        # made here. The gateway owns the rule; this module owns the lifecycle.
        for operation_id in self.required_operations(context):
            verdict = trust_gateway.query(
                domain="host", subject_id=target.target_id, action=operation_id,
                context={"target": target})
            verdict.require(CollectorConfigurationError)

    @property
    def manifest_platform(self) -> str:
        return "linux"

    def run_operations(
        self, context: CollectionContext, requests: tuple[tuple[str, str | None], ...]
    ) -> dict[str, RemoteExecutionResult]:
        """Run each (operation_id, argument) pair and return the successes.

        Raises when anything failed, so a caller can never parse a stream that
        arrived truncated or after a timeout.
        """
        target = self.target_of(context)
        transport = self.transport_of(context)

        outcomes: dict[str, RemoteExecutionResult] = {}
        errors = []

        for operation_id, argument in requests:
            try:
                operation = operation_for(operation_id, argument)
            except CatalogError as error:
                raise CollectorConfigurationError(str(error)) from None

            try:
                execution = transport.run(target, operation)
            except Exception as error:  # noqa: BLE001 - converted to a redacted error
                errors.append(error_from_exception(operation_id, error))
                continue

            if execution.failure_category is not None or execution.exit_status not in (0, None):
                errors.append(error_for(execution))
                continue

            key = argument or operation_id
            outcomes[key] = execution

        if errors:
            raise collection_failed(errors)

        return outcomes

    def normalize(self, raw_result: Any, context: CollectionContext) -> list[Observation]:
        return normalize_observations(
            raw_result,
            source=self.manifest.source_type,
            collected_at=context.collected_at,
        )
