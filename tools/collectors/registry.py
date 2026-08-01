"""Explicit collector plugin registry.

Registration is explicit and in-process. There is deliberately no filesystem
scanning and no entry-point discovery: a plugin that can appear by being
dropped on disk, or by a dependency declaring an entry point, is a plugin
nobody reviewed. Adding a collector should require editing code that a human
reads.

Registration never instantiates or executes a plugin. Import-time side effects
are the classic way scanning frameworks acquire behaviour their operators did
not intend.
"""

from __future__ import annotations

from .base import CollectorPlugin
from .exceptions import CollectorRegistrationError
from .models import APPROVED_SOURCE_TYPES, CollectorManifest


class CollectorRegistry:
    """Holds collector classes by identifier."""

    def __init__(self) -> None:
        self._plugins: dict[str, type[CollectorPlugin]] = {}

    def register(self, plugin_class: type[CollectorPlugin]) -> str:
        """Register a plugin class and return its identifier.

        Validates the class and its manifest without running the plugin.
        """
        if not isinstance(plugin_class, type) or not issubclass(plugin_class, CollectorPlugin):
            raise CollectorRegistrationError(
                f"{getattr(plugin_class, '__name__', plugin_class)!r} does not implement CollectorPlugin"
            )

        # Reading the manifest requires an instance; construction must stay
        # side-effect free, which the plugin standard requires.
        try:
            manifest = plugin_class().manifest
        except Exception as error:  # noqa: BLE001 - surfaced as a registration failure
            raise CollectorRegistrationError(
                f"could not read manifest for {plugin_class.__name__}: {type(error).__name__}"
            ) from error

        if not isinstance(manifest, CollectorManifest):
            raise CollectorRegistrationError(
                f"{plugin_class.__name__} manifest is not a CollectorManifest"
            )

        problems = manifest.validation_errors()
        if problems:
            raise CollectorRegistrationError(
                f"manifest for '{manifest.id}' is invalid: {'; '.join(problems)}"
            )

        if manifest.source_type not in APPROVED_SOURCE_TYPES:
            raise CollectorRegistrationError(
                f"source_type '{manifest.source_type}' is not approved"
            )

        if manifest.id in self._plugins:
            raise CollectorRegistrationError(
                f"collector id '{manifest.id}' is already registered"
            )

        self._plugins[manifest.id] = plugin_class
        return manifest.id

    def get(self, collector_id: str) -> type[CollectorPlugin]:
        """Return a registered plugin class without instantiating it."""
        if collector_id not in self._plugins:
            raise CollectorRegistrationError(f"collector id '{collector_id}' is not registered")
        return self._plugins[collector_id]

    def list_manifests(self) -> list[CollectorManifest]:
        """Return manifests for every registered plugin, ordered by id."""
        return [self._plugins[key]().manifest for key in sorted(self._plugins)]

    def ids(self) -> list[str]:
        return sorted(self._plugins)

    def __len__(self) -> int:
        return len(self._plugins)
