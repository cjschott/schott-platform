"""Code-owned trust policy: the migrated decision rules.

Before v0.9.4 these rules lived wherever they happened to be needed — a
frozenset in the collector models, a membership test in the registry, a method
on a remote target, an allowlist in the command runner. Each was defensible on
its own and together they were four trust systems nobody could audit as one.

This module is where that logic now lives, once. The call sites ask; they no
longer decide.

Every function here is pure and deny-by-default: it returns the reasons a
request is refused, and an empty tuple means nothing objected. Returning
reasons rather than a boolean is deliberate — a denial an operator cannot read
is a denial they will route around.

**These rules are not root-terminated.** They are reviewed code, not decisions
traceable to an external Operator Root Authority. Where a trust store is
configured, the Trust Plane runtime is authoritative and these are not
consulted. Until then they are the honest description of what the platform
actually enforces, and `docs/trust/trust-migration.md` says so plainly rather
than implying a chain that does not yet exist.

See docs/decisions/ADR-0011-trust-plane.md.
"""

from __future__ import annotations

from typing import Any, Mapping

# Which ADR-0011 domain each migrated mechanism belongs to. No new domain is
# invented: operation authorization is host trust expressed through scope, not
# a sixteenth category.
DOMAIN_FOR_MECHANISM: Mapping[str, str] = {
    "collector-manifest-authorization": "collector-plugin",
    "collector-source-type": "collector-plugin",
    "collector-registration": "collector-plugin",
    "remote-target-operation": "host",
    "remote-host-key-policy": "ssh-host-key",
    "remote-operation-catalog": "remote-transport",
    "local-command-execution": "remote-transport",
    "authentication-reference": "user",
    "platform-capability": "capability-package",
}

# Every domain this release can decide for. An unrecognised domain fails closed
# rather than falling through to a permissive default.
SUPPORTED_DOMAINS = frozenset(DOMAIN_FOR_MECHANISM.values())


def evaluate_policy(domain: str, subject_id: str, action: str | None,
                    context: Mapping[str, Any] | None = None) -> tuple[str, ...]:
    """Return the reasons this request is refused; empty means permitted.

    Deny-by-default: an unrecognised domain, a missing subject, or a mechanism
    with no rule returns a reason rather than silence.
    """
    context = dict(context or {})

    if domain not in SUPPORTED_DOMAINS:
        return (
            f"domain '{domain}' is not one this release decides for; "
            "an unrecognised domain fails closed",
        )

    if not str(subject_id or "").strip():
        return ("no subject was named; a request with no subject is denied",)

    if domain == "host":
        return _host_policy(subject_id, action, context)
    if domain == "collector-plugin":
        return _plugin_policy(subject_id, action, context)
    if domain == "remote-transport":
        return _transport_policy(subject_id, action, context)
    if domain == "ssh-host-key":
        return _host_key_policy(subject_id, context)
    if domain in {"user", "capability-package"}:
        return _declared_policy(domain, subject_id, context)

    return (
        f"domain '{domain}' has no policy in this release; nothing permitted it",
    )


def _host_policy(subject_id: str, action: str | None,
                 context: Mapping[str, Any]) -> tuple[str, ...]:
    """Whether a remote target authorises an operation.

    Migrated from `RemoteTarget.permits()` as consulted in the remote collector
    lifecycle. The wording of the refusal is preserved exactly, because a
    released error message is part of released behaviour.
    """
    target = context.get("target")
    if target is None:
        return ("no remote target was supplied; a host decision requires the "
                "declared target it concerns",)

    if action is None:
        return ("no operation was named; host authorization is per-operation "
                "and unstated dimensions are denied",)

    permitted = tuple(getattr(target, "allowed_operation_ids", ()) or ())
    if action not in permitted:
        return (
            f"target '{getattr(target, 'target_id', subject_id)}' does not authorize "
            f"operation '{action}'; the target's allowed_operation_ids is "
            "the authorization boundary",
        )
    return ()


class _ManifestView:
    """Reads a raw manifest mapping with the dataclass's attribute names."""

    _DEFAULTS = {
        "id": "", "source_type": "", "permissions": (), "network_access": False,
        "subprocess_access": False, "filesystem_access": False,
        "secret_requirements": (),
    }

    def __init__(self, mapping: Mapping[str, Any]) -> None:
        self._mapping = mapping

    def __getattr__(self, name: str) -> Any:
        if name not in self._DEFAULTS:
            raise AttributeError(name)
        value = self._mapping.get(name, self._DEFAULTS[name])
        return self._DEFAULTS[name] if value is None else value


def _plugin_policy(subject_id: str, action: str | None,
                   context: Mapping[str, Any]) -> tuple[str, ...]:
    """Whether a collector plugin manifest is authorised.

    Migrated from `CollectorManifest.validation_errors()` and the registry's
    source-type gate. Message text is preserved verbatim so a caller that
    reported a problem before reports the same problem now.
    """
    from ..collectors.models import (
        APPROVED_PERMISSIONS,
        APPROVED_SOURCE_TYPES,
        COLLECTOR_ID,
        FORBIDDEN_PERMISSIONS,
        REMOTE_PERMISSION,
        SECRET_BEARING_KEYS,
    )

    manifest = context.get("manifest")
    if manifest is None:
        return ("no manifest was supplied; a plugin decision requires the "
                "declaration it concerns",)

    # A manifest reaches this function either as the framework dataclass or as
    # the raw mapping parsed from manifest.yaml. Both are the same declaration,
    # so both are decided by the same rules rather than by two near-copies.
    if isinstance(manifest, Mapping):
        manifest = _ManifestView(manifest)

    problems: list[str] = []

    if not COLLECTOR_ID.match(getattr(manifest, "id", "") or ""):
        problems.append(
            f"collector id '{manifest.id}' must be lowercase kebab-case")
    if manifest.source_type not in APPROVED_SOURCE_TYPES:
        problems.append(f"source_type '{manifest.source_type}' is not approved")

    for permission in manifest.permissions:
        if permission in FORBIDDEN_PERMISSIONS:
            problems.append(
                f"permission '{permission}' is forbidden for collectors")
        elif permission not in APPROVED_PERMISSIONS:
            problems.append(f"permission '{permission}' is not approved")

    # The v0.9.0 narrowing, unchanged: network access exists in exactly one
    # declarable form and is refused in every other.
    if manifest.network_access and REMOTE_PERMISSION not in manifest.permissions:
        problems.append(
            f"network_access requires the '{REMOTE_PERMISSION}' permission; "
            "collectors are read-only and reach nothing they have not declared"
        )
    if REMOTE_PERMISSION in manifest.permissions and not manifest.network_access:
        problems.append(
            f"the '{REMOTE_PERMISSION}' permission requires network_access to be true"
        )

    if manifest.subprocess_access not in (True, False):
        problems.append("subprocess_access must be a boolean")
    if manifest.filesystem_access not in (True, False, "read-only"):
        problems.append(
            "filesystem_access must be false or 'read-only'; write access is not permitted"
        )
    if manifest.filesystem_access is True:
        problems.append(
            "filesystem_access must be declared 'read-only' rather than true"
        )

    for requirement in manifest.secret_requirements:
        if str(requirement).lower() in SECRET_BEARING_KEYS:
            problems.append(
                f"secret_requirements entry '{requirement}' names a secret directly; "
                "describe the requirement instead"
            )

    return tuple(problems)


def _transport_policy(subject_id: str, action: str | None,
                      context: Mapping[str, Any]) -> tuple[str, ...]:
    """Whether an operation identifier is one the code-owned catalog defines.

    Migrated from the membership test inside `operation_for()`. The catalog
    itself stays where it is: it holds the argv, which is containment rather
    than a trust decision, and moving reviewed argv into a decision function
    would put executable text one indirection further from review.
    """
    from ..collectors.remote.command_catalog import CATALOG

    if action is None:
        return ("no operation was named; transport authorization is "
                "per-operation and unstated dimensions are denied",)
    if action not in CATALOG:
        return (f"unknown remote operation identifier '{action}'",)
    return ()


def _host_key_policy(subject_id: str, context: Mapping[str, Any]) -> tuple[str, ...]:
    """Whether a target's host-key policy is acceptable.

    Migrated from target validation. Only `strict` has ever been permitted and
    that does not change here: the absence of a permissive alternative is the
    mechanism, not an oversight.
    """
    from ..collectors.remote.models import SUPPORTED_HOST_KEY_POLICIES

    target = context.get("target")
    if target is None:
        return ("no remote target was supplied; a host-key decision requires "
                "the declared target it concerns",)
    policy = getattr(target, "host_key_policy", None)
    if policy not in SUPPORTED_HOST_KEY_POLICIES:
        return (
            f"host_key_policy '{policy}' is not permitted; "
            "host-key verification is mandatory",
        )
    return ()


def _declared_policy(domain: str, subject_id: str,
                     context: Mapping[str, Any]) -> tuple[str, ...]:
    """Domains whose subjects are declared but not yet decided at runtime.

    Identity and capability trust are declared in reviewed files today. Nothing
    in this release grants them at runtime, so the honest answer is a denial
    naming the gap rather than an allow that implies a decision nobody made.
    """
    return (
        f"domain '{domain}' has no runtime grant in v0.9.4; subjects are declared "
        "in reviewed files and are not yet decided by the Trust Plane",
    )
