"""The remote transport contract, and the fake that every test drives.

Two implementations exist. `SSHRemoteTransport` can reach another machine and
is never executed under test. `FakeRemoteTransport` cannot reach anything and
is what every behavioural test uses. The split is the reason this sprint could
be developed without contacting a host.

Both funnel through `prepare_result`, so ceiling enforcement, decoding, and
redaction are defined once. A fake that redacted differently from the real
transport would be a test that proves nothing about production.

Partial output is never accepted. Output that exceeded its ceiling is
discarded rather than truncated and parsed: a parser handed half a file
produces a confident wrong answer, which is worse than no answer.
"""

from __future__ import annotations

from abc import ABC, abstractmethod

from .models import (
    RemoteExecutionResult,
    RemoteFailureCategory,
    RemoteOperation,
    RemoteTarget,
)
from .redaction import decode_remote_bytes, redact_remote_output


class TransportError(Exception):
    """The transport could not complete an attempt.

    Messages are redacted before they reach a result; this type may carry
    detail useful for diagnosis, and callers must not assume it is safe to
    emit verbatim.
    """


def effective_ceiling(target: RemoteTarget, operation: RemoteOperation) -> int:
    """The smaller of the target's and the operation's byte ceilings.

    The lower bound wins so neither side can raise the other's limit.
    """
    return min(int(target.max_stdout_bytes), int(operation.output_ceiling_bytes))


def prepare_result(
    target: RemoteTarget,
    operation: RemoteOperation,
    exit_status: int | None,
    stdout: bytes | str,
    stderr: bytes | str,
    failure_category: str | None = None,
    summary: str = "",
) -> RemoteExecutionResult:
    """Decode, bound, and redact one attempt's streams.

    Redaction happens here — before parsing, before normalization, and before
    any fingerprint — so no unredacted remote string ever exists inside a
    collector.
    """
    stdout_bytes = stdout if isinstance(stdout, bytes) else str(stdout).encode("utf-8")
    stderr_bytes = stderr if isinstance(stderr, bytes) else str(stderr).encode("utf-8")

    ceiling = effective_ceiling(target, operation)
    if failure_category is None and len(stdout_bytes) > ceiling:
        return RemoteExecutionResult(
            operation_id=operation.operation_id,
            exit_status=exit_status,
            stdout="",
            stderr="",
            failure_category=RemoteFailureCategory.OUTPUT_LIMIT.value,
            summary=(
                f"operation '{operation.operation_id}' produced more than "
                f"{ceiling} bytes; output was discarded rather than truncated"
            ),
            truncated=True,
        )

    stderr_bytes = stderr_bytes[: int(target.max_stderr_bytes)]

    clean_stdout, _ = redact_remote_output(decode_remote_bytes(stdout_bytes))
    clean_stderr, _ = redact_remote_output(decode_remote_bytes(stderr_bytes))

    return RemoteExecutionResult(
        operation_id=operation.operation_id,
        exit_status=exit_status,
        stdout=clean_stdout,
        stderr=clean_stderr,
        failure_category=failure_category,
        summary=summary,
    )


class RemoteTransport(ABC):
    """How a collector reaches a target.

    The interface has exactly one method, and it takes an operation rather
    than a command. There is no entry point through which a caller could
    supply text to execute.
    """

    @abstractmethod
    def run(self, target: RemoteTarget, operation: RemoteOperation) -> RemoteExecutionResult:
        """Attempt one operation and return its outcome."""


# Failure modes the fake can simulate, mapped to the category each produces.
FAKE_FAILURE_MODES = {
    "timeout": RemoteFailureCategory.TIMEOUT.value,
    "output_limit": RemoteFailureCategory.OUTPUT_LIMIT.value,
    "authentication_failure": RemoteFailureCategory.AUTHENTICATION_FAILURE.value,
    "host_key_failure": RemoteFailureCategory.HOST_KEY_FAILURE.value,
    "transport_failure": RemoteFailureCategory.TRANSPORT_FAILURE.value,
    "unsupported_target": RemoteFailureCategory.UNSUPPORTED_TARGET.value,
}

# Summaries describe the attempt. None of them claims the host is down, that a
# service failed, or that declared state is wrong — this layer is in no
# position to know any of that.
FAKE_FAILURE_SUMMARIES = {
    "timeout": "the operation did not complete within its time ceiling",
    "output_limit": "the operation produced more output than its ceiling permits",
    "authentication_failure": "the target refused the offered authentication",
    "host_key_failure": "the target's host key did not match the approved entry",
    "transport_failure": "the connection attempt did not complete",
    "unsupported_target": "the target does not support this operation",
}


class FakeRemoteTransport(RemoteTransport):
    """A transport that cannot reach anything.

    Returns canned output for each operation identifier. It exists so the
    entire remote collection path can be exercised — including every failure
    category and the secret-leak paths — without a network, a credential, or
    a host.

    `leak` injects a credential-bearing string into a chosen stream, or raises
    it as an exception, to prove secrets do not survive into a result.
    """

    def __init__(
        self,
        responses: dict[str, str] | None = None,
        failure_mode: str | None = None,
        leak: tuple[str, str] | None = None,
        raw_bytes: bytes | None = None,
        fail_operations: dict[str, str] | None = None,
    ) -> None:
        self.responses = dict(responses or {})
        self.failure_mode = failure_mode
        self.leak = leak
        self.raw_bytes = raw_bytes
        # Per-operation failure. Lets a test make some operations succeed and
        # one fail, which is the only way to prove that successful
        # intermediate output is discarded rather than never fetched.
        self.fail_operations = dict(fail_operations or {})
        # Recorded so a test can assert which operations were attempted. Holds
        # identifiers only; no output is retained here.
        self.attempted: list[str] = []

    @staticmethod
    def _credential_payload(secret: str) -> str:
        """A realistically shaped leak: a URL with embedded credentials."""
        return f"https://operator:{secret}@internal.invalid/path\n"

    def run(self, target: RemoteTarget, operation: RemoteOperation) -> RemoteExecutionResult:
        self.attempted.append(operation.operation_id)

        mode = self.fail_operations.get(operation.operation_id, self.failure_mode)
        if mode is not None:
            category = FAKE_FAILURE_MODES.get(
                mode, RemoteFailureCategory.TRANSPORT_FAILURE.value)
            summary = FAKE_FAILURE_SUMMARIES.get(
                mode, "the collection attempt did not complete")
            return RemoteExecutionResult(
                operation_id=operation.operation_id,
                exit_status=None,
                stdout="",
                stderr="",
                failure_category=category,
                summary=summary,
                truncated=mode == "output_limit",
            )

        stdout: bytes | str
        stderr: bytes | str = ""

        if self.leak is not None:
            stream, secret = self.leak
            payload = self._credential_payload(secret)
            if stream == "exception":
                raise TransportError(f"connection failed for {payload.strip()}")
            if stream == "stderr":
                stdout = self.responses.get(operation.operation_id, "")
                stderr = payload
            else:
                stdout = payload
        elif self.raw_bytes is not None:
            stdout = self.raw_bytes
        else:
            stdout = self.responses.get(operation.operation_id, "")

        return prepare_result(
            target=target,
            operation=operation,
            exit_status=0,
            stdout=stdout,
            stderr=stderr,
        )
