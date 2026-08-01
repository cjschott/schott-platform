"""Synthetic example collector — TEST-ONLY, NON-PRODUCTION.

This is not a real collector and must never be treated as one. It observes
nothing: it does not inspect the host, read environment variables, open files,
touch the network, or spawn a subprocess. It returns fixed example
observations so the framework contract can be exercised without a live source.

It refuses to run unless the caller explicitly marks the collection context
synthetic. That refusal is the point: a fixture plugin that would happily run
in a production pipeline is a fixture waiting to be mistaken for real data.

Governed by: docs/standards/collector-plugin-standard.md
"""

from __future__ import annotations

from typing import Any

from ...base import CollectorPlugin
from ...exceptions import CollectorConfigurationError
from ...models import CollectionContext, CollectorManifest, Observation
from ...normalizer import normalize_observations

# Fixed synthetic facts. Deterministic so the resulting fingerprint is stable
# across runs, which the framework tests assert.
SYNTHETIC_FACTS: dict[str, Any] = {
    "attested_hostname": "example-host",
    "attestation_note": "synthetic fixture; no real observation was made",
}

MANIFEST = CollectorManifest(
    id="example-synthetic",
    name="Example Synthetic Collector",
    version="0.1.0",
    source_type="manual-attestation",
    description=(
        "Non-production fixture plugin. Returns deterministic example "
        "observations from caller-supplied synthetic context."
    ),
    permissions=("synthetic-fixture-only",),
    capabilities=("CAP-0002",),
    supported_targets=("host",),
    network_access=False,
    subprocess_access=False,
    filesystem_access=False,
    secret_requirements=(),
    output_contract=("attested_hostname", "attestation_note"),
    lifecycle="draft",
)


class ExampleSyntheticCollector(CollectorPlugin):
    """Returns fixed observations for a synthetic context."""

    @property
    def manifest(self) -> CollectorManifest:
        return MANIFEST

    def validate_configuration(self, context: CollectionContext) -> None:
        """Fail closed unless the caller marked the context synthetic."""
        if not context.synthetic:
            raise CollectorConfigurationError(
                "example-synthetic refuses non-synthetic execution; it observes "
                "nothing real and must not appear in a production pipeline"
            )

    def collect(self, context: CollectionContext) -> dict[str, Any]:
        """Return fixture data.

        Reads nothing: no host, no environment, no file, no socket. The
        context is not modified.
        """
        return dict(SYNTHETIC_FACTS)

    def normalize(self, raw_result: Any, context: CollectionContext) -> list[Observation]:
        return normalize_observations(
            raw_result,
            source="example-synthetic",
            collected_at=context.collected_at,
            sensitivity="internal",
        )
