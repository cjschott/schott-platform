"""Data models for remote read-only collection.

These types define what a remote collector may say and, as importantly, what
it has no way to say. There is no field for a credential value, no field for
a command string, and no field in which "the host is down" could be recorded:
every failure category below describes the collection attempt.

Standard-library dataclasses and enums only.

See docs/decisions/ADR-0010-remote-read-only-collection.md.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

# The only platform this release can observe. Named as a set rather than a
# bare comparison so adding one later is a reviewed change.
SUPPORTED_PLATFORMS = frozenset({"linux"})

# Host-key verification is mandatory. "strict" is the only accepted value, and
# the absence of a permissive alternative is the point: a policy field that can
# express "ignore" will eventually be set to it.
SUPPORTED_HOST_KEY_POLICIES = frozenset({"strict"})

# How authentication is located. Every kind is a reference to material held
# somewhere else; none of them can carry the material itself.
SUPPORTED_AUTHENTICATION_KINDS = frozenset({
    "ssh-key-path", "ssh-agent", "secret-source",
})

SUPPORTED_TRUST_CLASSIFICATIONS = frozenset({
    "internal", "restricted", "untrusted",
})


class RemoteFailureCategory(str, Enum):
    """Why a collection attempt did not produce facts.

    Every value describes the attempt, never the target. A collector that
    could not connect has learned nothing about the host: the network may be
    broken, the credential may have expired, DNS may be wrong. Reporting any
    of that as an outage manufactures one out of an observation gap.

    There is deliberately no category meaning "the host is down", because
    nothing in this package is in a position to know that.
    """

    AUTHENTICATION_FAILURE = "authentication_failure"
    HOST_KEY_FAILURE = "host_key_failure"
    TIMEOUT = "timeout"
    OUTPUT_LIMIT = "output_limit"
    TRANSPORT_FAILURE = "transport_failure"
    UNSUPPORTED_TARGET = "unsupported_target"
    COLLECTION_FAILURE = "collection_failure"


@dataclass(frozen=True)
class AuthenticationReference:
    """Where authentication material lives — never the material.

    `reference` is a path or a secret-source identifier. Nothing in this
    package reads it; it is passed to the ssh client as an option value and
    resolved by the client itself.
    """

    kind: str
    reference: str

    def validation_errors(self) -> list[str]:
        problems: list[str] = []
        if self.kind not in SUPPORTED_AUTHENTICATION_KINDS:
            problems.append(f"authentication kind '{self.kind}' is not supported")
        if not str(self.reference or "").strip():
            problems.append("authentication reference must not be empty")
        return problems


@dataclass(frozen=True)
class RemoteTarget:
    """One explicitly approved host.

    Frozen: a target that can be edited at runtime is not a declaration.

    Note the fields that do not exist. There is no credential field of any
    kind, and no field carrying command text. A target says which host may be
    observed and which catalog operations are permitted against it; it cannot
    say what to run.
    """

    target_id: str
    hostname: str
    port: int
    username: str
    host_key_policy: str
    known_hosts_reference: str
    authentication_reference: AuthenticationReference | None
    platform: str
    trust_classification: str
    allowed_operation_ids: tuple[str, ...] = ()
    connect_timeout_seconds: int = 5
    command_timeout_seconds: int = 15
    max_stdout_bytes: int = 65536
    max_stderr_bytes: int = 4096
    # Units this target permits inspection of. Enumerating every unit on a host
    # returns an unbounded list shaped by whatever happens to be installed and
    # turns a targeted question into a survey.
    allowed_units: tuple[str, ...] = ()

    def permits(self, operation_id: str) -> bool:
        return operation_id in self.allowed_operation_ids


@dataclass(frozen=True)
class RemoteOperation:
    """One code-owned, read-only operation.

    `argv` is a tuple of discrete arguments defined in the catalog. It is
    never assembled from configuration and never joined into a string.
    """

    operation_id: str
    description: str
    argv: tuple[str, ...]
    platform: str
    sensitivity: str
    timeout_ceiling_seconds: int
    output_ceiling_bytes: int
    read_only: bool = True
    required_privilege: str = "unprivileged"


@dataclass(frozen=True)
class RemoteExecutionRequest:
    """A target paired with the operation to run against it."""

    target: RemoteTarget
    operation: RemoteOperation


@dataclass(frozen=True)
class RemoteExecutionResult:
    """The outcome of one attempt.

    `stdout` and `stderr` are already redacted by the transport, before any
    parsing and before any fingerprint is computed.

    `failure_category` is None only when the operation completed within its
    time and byte ceilings. Truncated output is a failure, not a partial
    success: a parser handed half a file produces a confident wrong answer.
    """

    operation_id: str
    exit_status: int | None
    stdout: str
    stderr: str
    failure_category: str | None = None
    summary: str = ""
    truncated: bool = False

    @property
    def succeeded(self) -> bool:
        return self.failure_category is None and self.exit_status == 0
