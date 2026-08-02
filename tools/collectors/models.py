"""Data models for the collector framework.

Standard-library dataclasses and enums only. These types define what a
collector may say, and — as importantly — what it has no way to say. There is
no field for an evidence identifier, no field for a remediation action, and no
field capable of carrying a raw secret value.

See docs/standards/collector-plugin-standard.md.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Any

# Fact and manifest keys that would carry a secret value. Rejected wherever
# they appear; the key is reported and the value is never echoed.
SECRET_BEARING_KEYS = frozenset({
    "password", "passwd", "api_key", "apikey", "secret_key", "master_key",
    "private_key", "access_token", "bearer_token", "session_cookie",
    "authorization", "auth_header", "credentials", "token", "secret",
})

# Secret metadata is permitted: that a credential exists and where it comes
# from is useful for verification; its value is a liability with no benefit.
PERMITTED_SECRET_METADATA_KEYS = frozenset({
    "secret_present", "secret_source", "secret_length_class",
    "secret_last_rotated", "secret_requirements",
})

APPROVED_SOURCE_TYPES = frozenset({
    "manual-attestation", "command-output", "ssh-command", "api-response",
    "file-inspection", "configuration-render", "health-check",
    "backup-report", "monitoring-query", "git-repository",
})

APPROVED_PERMISSIONS = frozenset({
    "read-declared-model", "read-repository-files", "synthetic-fixture-only",
    "read-remote-host",
})

# The one permission that unlocks network access, and the only way to get it.
# A collector holding it may observe an explicitly approved remote target
# through the audited transport; it may not administer one.
REMOTE_PERMISSION = "read-remote-host"

FORBIDDEN_PERMISSIONS = frozenset({
    "write-platform-model", "write-evidence-store", "modify-runtime",
    "execute-remediation", "manage-secrets", "network-admin", "host-admin",
})

COLLECTOR_ID = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")


class ResultStatus(str, Enum):
    """Outcome of a collection attempt.

    FAILED and UNAVAILABLE describe the collection, never the target: a
    collector that could not look has learned nothing about health.
    """

    SUCCESS = "success"
    PARTIAL = "partial"
    FAILED = "failed"
    UNAVAILABLE = "unavailable"


class Sensitivity(str, Enum):
    PUBLIC = "public"
    INTERNAL = "internal"
    RESTRICTED = "restricted"
    SECRET_METADATA = "secret-metadata"


class ErrorCategory(str, Enum):
    CONFIGURATION = "configuration"
    UNSUPPORTED = "unsupported"
    UNREACHABLE = "unreachable"
    PERMISSION = "permission"
    MALFORMED_SOURCE = "malformed-source"
    INTERNAL = "internal"


def is_timezone_aware(value: Any) -> bool:
    """Return True when value is an ISO 8601 timestamp carrying an offset.

    A time without a zone is not a point in time, so comparing it to anything
    is guesswork. Naive values are rejected rather than assumed local.
    """
    if isinstance(value, datetime):
        return value.tzinfo is not None
    if not isinstance(value, str):
        return False
    text = value.strip()
    if text.lower() in {"now", "today", "latest", "current", "recently"}:
        return False
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return False
    return parsed.tzinfo is not None


@dataclass(frozen=True)
class CollectorManifest:
    """Declared metadata for a collector plugin.

    Frozen: a manifest that can be edited at runtime is not a declaration.
    """

    id: str
    name: str
    version: str
    source_type: str
    description: str
    permissions: tuple[str, ...] = ()
    capabilities: tuple[str, ...] = ()
    supported_targets: tuple[str, ...] = ()
    network_access: bool = False
    subprocess_access: bool = False
    filesystem_access: bool | str = False
    secret_requirements: tuple[str, ...] = ()
    output_contract: tuple[str, ...] = ()
    lifecycle: str = "draft"

    def validation_errors(self) -> list[str]:
        """Return human-readable problems. Never includes a field value that
        looked secret-bearing."""
        problems: list[str] = []

        if not COLLECTOR_ID.match(self.id or ""):
            problems.append(f"collector id '{self.id}' must be lowercase kebab-case")
        if self.source_type not in APPROVED_SOURCE_TYPES:
            problems.append(f"source_type '{self.source_type}' is not approved")

        for permission in self.permissions:
            if permission in FORBIDDEN_PERMISSIONS:
                problems.append(f"permission '{permission}' is forbidden for collectors")
            elif permission not in APPROVED_PERMISSIONS:
                problems.append(f"permission '{permission}' is not approved")

        # Network access was refused unconditionally through v0.8.6. From
        # v0.9.0 it is narrowed rather than relaxed, exactly as v0.6.0 narrowed
        # the subprocess prohibition: the capability exists in one reviewable
        # form, gated by one permission, and is refused in every other case.
        #
        # The pairing is enforced in both directions on purpose. Network access
        # without the permission is an undeclared capability; the permission
        # without network access is a manifest claiming a boundary it does not
        # actually sit behind. Either mismatch means the manifest no longer
        # describes the collector.
        if self.network_access and REMOTE_PERMISSION not in self.permissions:
            problems.append(
                f"network_access requires the '{REMOTE_PERMISSION}' permission; "
                "collectors are read-only and reach nothing they have not declared"
            )
        if REMOTE_PERMISSION in self.permissions and not self.network_access:
            problems.append(
                f"the '{REMOTE_PERMISSION}' permission requires network_access to be true"
            )

        # Subprocess and filesystem access are declarable from v0.6.0, but only
        # in the narrowed forms the framework can enforce: subprocess runs
        # exclusively through command_runner.py, and filesystem access is
        # read-only. Write access remains outside the trust boundary.
        if self.subprocess_access not in (True, False):
            problems.append("subprocess_access must be a boolean")
        if self.filesystem_access not in (True, False, "read-only"):
            problems.append(
                "filesystem_access must be false or 'read-only'; write access is not permitted"
            )
        if self.filesystem_access is True:
            problems.append(
                "filesystem_access must be declared 'read-only' rather than true"
            )

        for requirement in self.secret_requirements:
            lowered = str(requirement).lower()
            if lowered in SECRET_BEARING_KEYS:
                problems.append(
                    f"secret_requirements entry '{requirement}' names a secret directly; "
                    "describe the requirement instead"
                )

        return problems


@dataclass(frozen=True)
class CollectionContext:
    """What the orchestrator hands a plugin.

    Carries no raw secret values. The collection timestamp is supplied by the
    orchestrator rather than read from the clock inside a plugin, so results
    stay reproducible and a plugin cannot backdate its own observation.
    """

    target: str
    declared: dict[str, Any]
    requested_facts: tuple[str, ...] | list[str]
    collected_at: str
    synthetic: bool = False
    # Collector-specific inputs (paths, attestation payloads). Supplied by the
    # orchestrator; never read from the environment by a plugin.
    options: dict[str, Any] | None = None

    def validation_errors(self) -> list[str]:
        problems: list[str] = []
        if not self.target:
            problems.append("context target is required")
        if not is_timezone_aware(self.collected_at):
            problems.append("collected_at must be an ISO 8601 timestamp with timezone information")
        for key in self.declared or {}:
            if str(key).lower() in SECRET_BEARING_KEYS:
                problems.append(
                    f"declared metadata key '{key}' is secret-bearing and must not reach a plugin"
                )
        return problems


@dataclass(frozen=True)
class Observation:
    """One normalized fact, observed at a moment.

    Provenance is fixed to "observed": an observation that could claim to be
    declared would let collected data masquerade as reviewed intent.
    """

    fact: str
    value: Any
    value_type: str
    collected_at: str
    source: str
    sensitivity: str = Sensitivity.INTERNAL.value
    redacted: bool = False
    confidence: str = "high"
    provenance: str = "observed"


@dataclass(frozen=True)
class CollectorError:
    """A redacted description of something that went wrong.

    Carries a summary, never a value. `retryable` distinguishes a transient
    condition from a structural one.
    """

    category: str
    summary: str
    retryable: bool = False
    redacted: bool = True


@dataclass
class CollectorResult:
    """What a plugin returns.

    Deliberately has no evidence identifier field: a collector that numbers
    its own records controls the audit trail. Identity is assigned outside
    the plugin.
    """

    collector_id: str
    target: str
    status: str
    started_at: str
    completed_at: str
    observations: list[Observation] = field(default_factory=list)
    errors: list[CollectorError] = field(default_factory=list)
    content_fingerprint: str = ""

    def is_terminal_failure(self) -> bool:
        return self.status in {ResultStatus.FAILED.value, ResultStatus.UNAVAILABLE.value}
