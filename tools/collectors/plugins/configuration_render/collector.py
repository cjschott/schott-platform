"""Configuration render collector — local, read-only.

Renders a Docker Compose file with `docker compose config` and reports the
declared configuration. It reports what Compose *would* do, never what is
running: no container is created, started, stopped, or inspected, and no
Docker API is called.

Environment values are never emitted. For each variable the collector reports
the name and how the value would be supplied — literal, defaulted, or
externally supplied — because the shape of the configuration is the useful
operational fact and the value is a liability.

Only `*.env.example` files are accepted. `ai/.env` holds real credentials and
is refused by name and by suffix rule.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

import yaml

from ...base import CollectorPlugin
from ...command_runner import run_read_only_command
from ...exceptions import CollectorConfigurationError, CollectorExecutionError
from ...models import CollectionContext, CollectorManifest, Observation
from ...normalizer import normalize_observations
from ...redaction import is_secret_value, redact_text

COMPOSE_TIMEOUT_SECONDS = 120

# The one approved Docker invocation. Any runtime verb (up, down, pull, build,
# run, exec, ps, inspect) is absent by construction.
COMPOSE_CONFIG_SUBCOMMAND = ("compose", "--env-file", "{env}", "-f", "{compose}", "config")

MANIFEST = CollectorManifest(
    id="configuration-render",
    name="Configuration Render Collector",
    version="0.1.0",
    source_type="configuration-render",
    description=(
        "Renders declared Docker Compose configuration and reports service, "
        "port, volume, network, and environment-variable-name facts. Reports "
        "declared configuration only, never running state."
    ),
    permissions=("read-repository-files",),
    capabilities=("CAP-0002",),
    supported_targets=("service", "repository"),
    network_access=False,
    subprocess_access=True,
    filesystem_access="read-only",
    secret_requirements=(),
    output_contract=(
        "compose_file", "service_names", "images", "published_ports",
        "volumes", "networks", "restart_policies", "healthcheck_services",
        "environment_variable_names",
    ),
    lifecycle="production",
)

# ${VAR}, ${VAR:-default}, ${VAR-default}
INTERPOLATION = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(:?-)?([^}]*)?\}")


def _resolve_inside(root: Path, candidate: str) -> Path:
    """Resolve a path and require it to stay inside the repository root.

    resolve() follows symlinks, so a symlink pointing outside the root is
    caught by the same containment check as ordinary traversal.
    """
    resolved = (root / candidate).resolve() if not Path(candidate).is_absolute() else Path(candidate).resolve()
    root_resolved = root.resolve()
    if not str(resolved).startswith(str(root_resolved) + "/") and resolved != root_resolved:
        raise CollectorConfigurationError(
            "path escapes the repository root and is not permitted"
        )
    return resolved


def classify_environment(raw_value: Any) -> str:
    """Describe how a value would be supplied, without revealing it."""
    if raw_value is None:
        return "externally-supplied"
    text = str(raw_value)
    if text == "":
        # Compose renders an unset variable to empty. Calling that "literal"
        # would imply the compose file hard-codes a value it does not.
        return "externally-supplied"
    match = INTERPOLATION.search(text)
    if match:
        return "defaulted" if match.group(3) else "externally-supplied"
    return "literal"


class ConfigurationRenderCollector(CollectorPlugin):
    """Collects declared Compose configuration facts."""

    @property
    def manifest(self) -> CollectorManifest:
        return MANIFEST

    def validate_configuration(self, context: CollectionContext) -> None:
        options = context.options or {}
        compose_file = options.get("compose_file")
        env_file = options.get("env_file")
        if not compose_file or not env_file:
            raise CollectorConfigurationError(
                "configuration-render requires explicit 'compose_file' and 'env_file' options"
            )

        env_name = Path(str(env_file)).name
        # Belt and braces: refuse the real environment file by name, and refuse
        # anything not ending in .example by rule. Either check alone would be
        # enough; both together mean a rename cannot defeat the guard.
        if env_name == ".env" or not env_name.endswith(".example"):
            raise CollectorConfigurationError(
                f"environment file '{env_name}' is not approved; only *.env.example files may be rendered"
            )

        root = Path(str(options.get("repository_root") or ".")).resolve()
        compose_path = _resolve_inside(root, str(compose_file))
        env_path = _resolve_inside(root, str(env_file))
        if not compose_path.is_file():
            raise CollectorConfigurationError("compose file does not exist")
        if not env_path.is_file():
            raise CollectorConfigurationError("environment example file does not exist")

    def collect(self, context: CollectionContext) -> dict[str, Any]:
        options = context.options or {}
        root = Path(str(options.get("repository_root") or ".")).resolve()
        compose_path = _resolve_inside(root, str(options["compose_file"]))
        env_path = _resolve_inside(root, str(options["env_file"]))

        argv = ["docker", "compose", "--env-file", str(env_path), "-f", str(compose_path), "config"]
        result = run_read_only_command(
            argv,
            cwd=root,
            timeout_seconds=COMPOSE_TIMEOUT_SECONDS,
            allowed_executables={"docker"},
            max_stdout_bytes=4_194_304,
        )
        if not result.succeeded:
            message, _ = redact_text(result.stderr or "compose config failed")
            raise CollectorExecutionError(f"compose config failed: {message[:300]}")

        try:
            rendered = yaml.safe_load(result.stdout) or {}
        except Exception as error:  # noqa: BLE001
            raise CollectorExecutionError("rendered compose output was not parseable YAML") from error

        services = rendered.get("services") or {}
        images, ports, volumes, restarts, healthchecks = [], [], [], {}, []
        env_names: dict[str, str] = {}

        for name in sorted(services):
            definition = services[name] or {}
            if definition.get("image"):
                images.append(str(definition["image"]))
            for entry in definition.get("ports") or []:
                if isinstance(entry, dict):
                    published = entry.get("published")
                    target = entry.get("target")
                    if published is not None:
                        ports.append(f"{published}:{target}/{entry.get('protocol', 'tcp')}")
                else:
                    ports.append(str(entry))
            for entry in definition.get("volumes") or []:
                if isinstance(entry, dict):
                    volumes.append(f"{entry.get('source', 'anonymous')}:{entry.get('target', '')}")
                else:
                    volumes.append(str(entry))
            if definition.get("restart"):
                restarts[name] = str(definition["restart"])
            if definition.get("healthcheck"):
                healthchecks.append(name)

            environment = definition.get("environment") or {}
            items = environment.items() if isinstance(environment, dict) else (
                (str(e).split("=", 1)[0], None) for e in environment
            )
            for key, value in items:
                # Only the name and the supply mechanism leave this loop.
                if is_secret_value(str(value)) if value is not None else False:
                    env_names[str(key)] = "redacted-literal"
                else:
                    env_names[str(key)] = classify_environment(value)

        return {
            "compose_file": str(compose_path.relative_to(root)) if str(compose_path).startswith(str(root)) else compose_path.name,
            "service_names": sorted(services),
            "images": sorted(set(images)),
            "published_ports": sorted(set(ports)),
            "volumes": sorted(set(volumes)),
            "networks": sorted((rendered.get("networks") or {}).keys()),
            "named_volumes": sorted((rendered.get("volumes") or {}).keys()),
            "restart_policies": dict(sorted(restarts.items())),
            "healthcheck_services": sorted(healthchecks),
            "environment_variable_names": dict(sorted(env_names.items())),
            "collection_scope": "declared-configuration-only",
        }

    def normalize(self, raw_result: Any, context: CollectionContext) -> list[Observation]:
        return normalize_observations(
            raw_result,
            source="configuration-render",
            collected_at=context.collected_at,
            sensitivity="internal",
        )
