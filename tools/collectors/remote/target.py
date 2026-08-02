"""Loading and validating explicitly approved remote targets.

Targets are declared, never discovered. There is no scan, no address range,
and no default: a host this platform has not been told about in a reviewed
file cannot be contacted.

Target files are read only from an approved directory, and only if they stay
inside it. A symlink pointing out of the directory is refused, because a
containment check that follows links does not contain anything.

Credential material in a target file is refused outright rather than ignored.
Ignoring it would leave a working secret sitting in a reviewed file that
everyone assumes holds none.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from .models import (
    SUPPORTED_AUTHENTICATION_KINDS,
    SUPPORTED_HOST_KEY_POLICIES,
    SUPPORTED_PLATFORMS,
    SUPPORTED_TRUST_CLASSIFICATIONS,
    AuthenticationReference,
    RemoteTarget,
)

TARGET_ID = re.compile(r"^RTGT-[0-9]{4}$")

# A DNS name, requiring at least one letter. Two things fall out of that
# requirement, both intended: a bare address literal is refused, and so is an
# address range, which is otherwise hard to distinguish from a name because
# hyphens and digits are both legal in labels.
#
# Names are also the reviewable form. An address in a target file says nothing
# about which machine it is, and it silently follows whatever now answers to it.
HOSTNAME = re.compile(
    r"^(?=.*[A-Za-z])"
    r"[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
    r"(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"
)

# A label of the form "1-50": the shape of an address range.
RANGE_LABEL = re.compile(r"^[0-9]+-[0-9]+$")

# Keys that would put credential material in a target file. Refused wherever
# they appear, at any depth. The key is reported; the value never is.
CREDENTIAL_KEYS = frozenset({
    "password", "passwd", "passphrase", "private_key", "privatekey",
    "key_content", "secret", "secret_key", "token", "api_key", "apikey",
    "credential", "credentials", "identity_file_content",
})

MAX_PORT = 65535


class TargetError(Exception):
    """A target is unusable, or a target file is not permitted.

    Never contains a value read from the file: these messages land in logs,
    and a refusal that echoes the credential it objected to has published it.
    """


def _validate_hostname(hostname: str) -> list[str]:
    problems: list[str] = []
    name = str(hostname or "").strip()
    if not name:
        problems.append("hostname is required")
        return problems
    if len(name) > 253:
        problems.append("hostname is longer than 253 characters")
    if any(label and RANGE_LABEL.match(label) for label in name.split(".")):
        problems.append("hostname looks like an address range; declare one host")
    elif not HOSTNAME.match(name):
        problems.append(
            "hostname must be a single DNS name: no wildcard, no address range, "
            "and not a bare address literal"
        )
    return problems


def validation_errors(target: RemoteTarget) -> list[str]:
    """Everything wrong with a target, as human-readable problems."""
    problems: list[str] = []

    if not TARGET_ID.match(str(target.target_id or "")):
        problems.append("target_id must be of the form RTGT-0000")

    problems.extend(_validate_hostname(target.hostname))

    try:
        port = int(target.port)
    except (TypeError, ValueError):
        port = -1
    if not 1 <= port <= MAX_PORT:
        problems.append(f"port must be between 1 and {MAX_PORT}")

    if not str(target.username or "").strip():
        problems.append("username is required")

    if target.host_key_policy not in SUPPORTED_HOST_KEY_POLICIES:
        problems.append(
            f"host_key_policy '{target.host_key_policy}' is not permitted; "
            "host-key verification is mandatory"
        )

    if not str(target.known_hosts_reference or "").strip():
        problems.append("known_hosts_reference is required")

    if target.authentication_reference is None:
        problems.append("authentication_reference is required")
    else:
        problems.extend(target.authentication_reference.validation_errors())

    if target.platform not in SUPPORTED_PLATFORMS:
        problems.append(f"platform '{target.platform}' is not supported")

    if target.trust_classification not in SUPPORTED_TRUST_CLASSIFICATIONS:
        problems.append(
            f"trust_classification '{target.trust_classification}' is not recognised")

    for field, value in (
        ("connect_timeout_seconds", target.connect_timeout_seconds),
        ("command_timeout_seconds", target.command_timeout_seconds),
        ("max_stdout_bytes", target.max_stdout_bytes),
        ("max_stderr_bytes", target.max_stderr_bytes),
    ):
        try:
            number = int(value)
        except (TypeError, ValueError):
            number = 0
        if number <= 0:
            problems.append(f"{field} must be a positive integer")

    return problems


def validate_target(target: RemoteTarget) -> RemoteTarget:
    """Return the target, or raise TargetError describing every problem."""
    problems = validation_errors(target)
    if problems:
        raise TargetError(
            f"target '{target.target_id}' is not usable: {'; '.join(problems)}")
    return target


def _reject_credential_keys(node: Any, path: str = "") -> None:
    """Raise if any key anywhere names credential material."""
    if isinstance(node, dict):
        for key, value in node.items():
            name = str(key)
            if name.lower() in CREDENTIAL_KEYS:
                location = f"{path}.{name}" if path else name
                raise TargetError(
                    f"target file contains credential material at '{location}'; "
                    "authentication must be referenced, never stored"
                )
            _reject_credential_keys(value, f"{path}.{name}" if path else name)
    elif isinstance(node, (list, tuple)):
        for index, value in enumerate(node):
            _reject_credential_keys(value, f"{path}[{index}]")


def _contained_path(name: str, approved_directory: str) -> Path:
    """Resolve a target file inside the approved directory, or refuse.

    Both sides are fully resolved before comparison, so a symlink out of the
    directory is refused rather than followed.
    """
    approved = Path(approved_directory).resolve(strict=False)
    candidate = (approved / name).resolve(strict=False)

    if candidate == approved or approved not in candidate.parents:
        raise TargetError(
            f"target file '{name}' resolves outside the approved directory")
    if not candidate.is_file():
        raise TargetError(f"target file '{name}' does not exist in the approved directory")
    return candidate


def target_from_mapping(data: dict[str, Any]) -> RemoteTarget:
    """Build a validated target from an already-parsed mapping."""
    _reject_credential_keys(data)

    reference = data.get("authentication_reference") or {}
    if not isinstance(reference, dict):
        raise TargetError("authentication_reference must be a mapping")

    kind = str(reference.get("kind", ""))
    if kind and kind not in SUPPORTED_AUTHENTICATION_KINDS:
        raise TargetError(f"authentication kind '{kind}' is not supported")

    target = RemoteTarget(
        target_id=str(data.get("target_id", "")),
        hostname=str(data.get("hostname", "")),
        port=int(data.get("port", 22)),
        username=str(data.get("username", "")),
        host_key_policy=str(data.get("host_key_policy", "")),
        known_hosts_reference=str(data.get("known_hosts_reference", "")),
        authentication_reference=AuthenticationReference(
            kind=kind, reference=str(reference.get("reference", ""))),
        platform=str(data.get("platform", "")),
        trust_classification=str(data.get("trust_classification", "")),
        allowed_operation_ids=tuple(data.get("allowed_operation_ids") or ()),
        connect_timeout_seconds=int(data.get("connect_timeout_seconds", 5)),
        command_timeout_seconds=int(data.get("command_timeout_seconds", 15)),
        max_stdout_bytes=int(data.get("max_stdout_bytes", 65536)),
        max_stderr_bytes=int(data.get("max_stderr_bytes", 4096)),
        allowed_units=tuple(data.get("allowed_units") or ()),
    )
    return validate_target(target)


def load_target(name: str, approved_directory: str) -> RemoteTarget:
    """Load one approved target by file name.

    `name` is a file name inside `approved_directory`, never a path the caller
    controls: containment is enforced before the file is opened.
    """
    import yaml  # imported here so the module stays importable without PyYAML

    path = _contained_path(name, approved_directory)

    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as error:
        raise TargetError(
            f"target file '{name}' is not valid YAML ({type(error).__name__})") from None

    if not isinstance(data, dict):
        raise TargetError(f"target file '{name}' must contain a mapping")

    return target_from_mapping(data)
