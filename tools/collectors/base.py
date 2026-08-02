"""Abstract base class for collector plugins.

The base class owns the lifecycle so a plugin cannot skip validation, and owns
failure conversion so an unexpected plugin fault becomes a redacted result
rather than an exception reaching the orchestrator.

It performs no network access, no subprocess invocation, and no filesystem
write, and it assigns no evidence identifier.

See docs/standards/collector-plugin-standard.md.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any

from .exceptions import CollectorConfigurationError, CollectorFailure
from .models import (
    CollectionContext,
    CollectorError,
    CollectorManifest,
    CollectorResult,
    ErrorCategory,
    Observation,
    ResultStatus,
)
from .normalizer import NormalizationError, fingerprint_observations


class CollectorPlugin(ABC):
    """Contract every collector implements.

    Subclasses supply `manifest`, `validate_configuration`, `collect`, and
    `normalize`. `execute` is final in spirit: it sequences the lifecycle and
    should not be overridden, because the guarantees live there.
    """

    @property
    @abstractmethod
    def manifest(self) -> CollectorManifest:
        """Declared plugin metadata."""

    @abstractmethod
    def validate_configuration(self, context: CollectionContext) -> None:
        """Raise CollectorConfigurationError when the context is unusable."""

    @abstractmethod
    def collect(self, context: CollectionContext) -> Any:
        """Gather raw material. Must not write, remediate, or persist."""

    @abstractmethod
    def normalize(self, raw_result: Any, context: CollectionContext) -> list[Observation]:
        """Convert raw material into normalized observations."""

    def discover(self, context: CollectionContext) -> tuple[str, ...]:
        """Facts this collector could produce for the target.

        Defaults to the manifest's declared output contract.
        """
        return tuple(self.manifest.output_contract)

    def execute(self, context: CollectionContext) -> CollectorResult:
        """Run the lifecycle and return a result.

        Never raises for an expected failure. Fails closed: a bad manifest or
        context produces a failed result with no collection attempted.
        """
        started_at = context.collected_at
        manifest = self.manifest

        def failure(category: ErrorCategory, summary: str, status: ResultStatus) -> CollectorResult:
            return CollectorResult(
                collector_id=manifest.id,
                target=context.target,
                status=status.value,
                started_at=started_at,
                completed_at=started_at,
                observations=[],
                errors=[CollectorError(category=category.value, summary=summary)],
                content_fingerprint="",
            )

        manifest_problems = manifest.validation_errors()
        if manifest_problems:
            return failure(
                ErrorCategory.CONFIGURATION,
                f"manifest is invalid: {'; '.join(manifest_problems)}",
                ResultStatus.FAILED,
            )

        context_problems = context.validation_errors()
        if context_problems:
            return failure(
                ErrorCategory.CONFIGURATION,
                f"collection context is invalid: {'; '.join(context_problems)}",
                ResultStatus.FAILED,
            )

        try:
            self.validate_configuration(context)
        except CollectorConfigurationError as error:
            return failure(ErrorCategory.CONFIGURATION, str(error), ResultStatus.FAILED)

        # Only Exception is caught. KeyboardInterrupt and SystemExit must stay
        # interruptible; swallowing BaseException makes a hung collector
        # impossible to stop.
        try:
            raw = self.collect(context)
            observations = self.normalize(raw, context)
        except NormalizationError as error:
            return failure(ErrorCategory.MALFORMED_SOURCE, str(error), ResultStatus.FAILED)
        except CollectorFailure as categorised:
            # The plugin already knows why this failed and said so in its own
            # vocabulary. Reporting it as "internal" would discard exactly the
            # information an operator needs.
            return CollectorResult(
                collector_id=manifest.id,
                target=context.target,
                status=categorised.status,
                started_at=started_at,
                completed_at=context.collected_at,
                observations=[],
                errors=list(categorised.errors),
                content_fingerprint="",
            )
        except Exception as error:  # noqa: BLE001 - converted to a redacted result
            return failure(
                ErrorCategory.INTERNAL,
                f"{type(error).__name__} during collection",
                ResultStatus.FAILED,
            )

        if not observations:
            return failure(
                ErrorCategory.UNSUPPORTED,
                "collector produced no observations for this target",
                ResultStatus.UNAVAILABLE,
            )

        return CollectorResult(
            collector_id=manifest.id,
            target=context.target,
            status=ResultStatus.SUCCESS.value,
            started_at=started_at,
            completed_at=context.collected_at,
            observations=list(observations),
            errors=[],
            content_fingerprint=fingerprint_observations(observations),
        )
