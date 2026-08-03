"""The code-owned catalog of permitted remote operations.

This module is the containment boundary. Everything a remote collector can
cause to happen on another machine is written out here, in reviewed code, as
a tuple of discrete arguments. Nothing assembles an argv from configuration,
and nothing joins one into a string.

That is the whole design. An operation identifier is the only thing
configuration may choose; adding a new fact requires a code change and a
review. This is deliberate friction. The alternative — command text supplied
as data — is a remote execution service with an observability label on it,
because configuration is reviewed as data rather than as code.

Every operation here is read-only, requires no privilege, and returns bounded
output. There is no escalation, no package manager, no mutation verb, and no
interpreter.

See docs/decisions/ADR-0010-remote-read-only-collection.md.
"""

from __future__ import annotations

import re
from types import MappingProxyType

from .models import RemoteOperation

# One unit name, validated before it is ever appended to an argv. Anchored at
# both ends and with no character class permitting a separator, a path
# traversal, or a glob.
UNIT_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9@._-]{0,127}\.service$")

DEFAULT_TIMEOUT_CEILING_SECONDS = 15
DEFAULT_OUTPUT_CEILING_BYTES = 65536


class CatalogError(Exception):
    """An operation was requested that the catalog does not define.

    Never echoes the offending identifier's surrounding context; an unknown
    identifier is reported by name only.
    """


def _operation(
    operation_id: str,
    description: str,
    argv: tuple[str, ...],
    sensitivity: str = "internal",
    timeout_ceiling_seconds: int = DEFAULT_TIMEOUT_CEILING_SECONDS,
    output_ceiling_bytes: int = DEFAULT_OUTPUT_CEILING_BYTES,
) -> RemoteOperation:
    return RemoteOperation(
        operation_id=operation_id,
        description=description,
        argv=argv,
        platform="linux",
        sensitivity=sensitivity,
        timeout_ceiling_seconds=timeout_ceiling_seconds,
        output_ceiling_bytes=output_ceiling_bytes,
        read_only=True,
        required_privilege="unprivileged",
    )


_OPERATIONS: dict[str, RemoteOperation] = {
    op.operation_id: op
    for op in (
        _operation(
            "linux.hostname",
            "Fully qualified host name as the host reports it.",
            ("hostname", "-f"),
            sensitivity="public",
        ),
        _operation(
            "linux.os_release",
            "Operating system identity from the standard release file.",
            ("cat", "/etc/os-release"),
            sensitivity="public",
        ),
        _operation(
            "linux.kernel",
            "Running kernel release string.",
            ("uname", "-r"),
            sensitivity="public",
        ),
        _operation(
            "linux.architecture",
            "Machine hardware architecture.",
            ("uname", "-m"),
            sensitivity="public",
        ),
        _operation(
            "linux.uptime",
            "Seconds since boot, read from the kernel.",
            ("cat", "/proc/uptime"),
            sensitivity="public",
        ),
        _operation(
            "linux.cpu_summary",
            "Processor topology as reported by the kernel.",
            ("lscpu",),
        ),
        _operation(
            "linux.memory_summary",
            "Total and available memory, read from the kernel.",
            ("cat", "/proc/meminfo"),
        ),
        _operation(
            "linux.filesystem_summary",
            "Capacity of mounted real filesystems, in bytes.",
            ("df", "-B1", "--output=source,fstype,size,avail,target"),
        ),
        # The unit name is appended by operation_for() after validation, and
        # only ever as its own argv entry. Enumerating every unit on a host is
        # deliberately absent: it returns an unbounded list shaped by whatever
        # happens to be installed, turning a targeted question into a survey.
        _operation(
            "linux.service_state",
            "Load, active, and enablement state of one named unit.",
            ("systemctl", "show", "--no-pager",
             "--property=Id,LoadState,ActiveState,SubState,UnitFileState"),
        ),
    )
}

# Read-only mapping: a catalog with a mutation entry point is not an allowlist.
# MappingProxyType has no add, register, extend, or update.
CATALOG = MappingProxyType(_OPERATIONS)

# Operations that take one validated argument. Everything else takes none.
_PARAMETERISED = frozenset({"linux.service_state"})


def operation_ids() -> tuple[str, ...]:
    """Every defined operation identifier, in a stable order."""
    return tuple(sorted(CATALOG))


def operation_for(identifier: str, argument: str | None = None) -> RemoteOperation:
    """Return the operation for an identifier, optionally with one argument.

    Raises CatalogError for an unknown identifier, for an argument supplied to
    an operation that takes none, and for an argument that fails validation.
    Fails closed: there is no path that appends an unvalidated string.
    """
    # Whether an identifier is one the platform may run is a trust decision.
    # The catalog still owns the argv -- that is containment, not a decision,
    # and moving reviewed argv into a policy function would put executable text
    # one indirection further from review.
    from ...trust import gateway as trust_gateway

    verdict = trust_gateway.query(
        domain="remote-transport", subject_id=identifier, action=identifier)
    verdict.require(CatalogError)
    operation = CATALOG.get(identifier)
    if operation is None:  # pragma: no cover - the gateway already refused
        raise CatalogError(f"unknown remote operation identifier '{identifier}'")

    if argument is None:
        return operation

    if identifier not in _PARAMETERISED:
        raise CatalogError(f"operation '{identifier}' accepts no argument")

    if not isinstance(argument, str) or not UNIT_NAME.match(argument):
        # The rejected value is not echoed: it is attacker-influenced text and
        # this message lands in logs.
        raise CatalogError(f"operation '{identifier}' was given an invalid unit name")

    return RemoteOperation(
        operation_id=operation.operation_id,
        description=operation.description,
        argv=operation.argv + (argument,),
        platform=operation.platform,
        sensitivity=operation.sensitivity,
        timeout_ceiling_seconds=operation.timeout_ceiling_seconds,
        output_ceiling_bytes=operation.output_ceiling_bytes,
        read_only=operation.read_only,
        required_privilege=operation.required_privilege,
    )
