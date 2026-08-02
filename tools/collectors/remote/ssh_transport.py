"""The one component that can reach another machine.

This module is the only place in the remote package permitted to import
`subprocess`, and it is the one component no test ever executes. Tests inspect
the argv it *would* build. That is a deliberate limit rather than a claim of
safety: nothing here proves the OpenSSH client behaves as modelled against a
live host, and first real use needs supervised validation.

Every relevant client option is pinned explicitly rather than inherited. A
user's `~/.ssh/config`, an agent socket in the environment, or a distribution
default could otherwise change what this does without any change here.

The command is passed as discrete argv entries. No shell is invoked, on either
side of the connection, and no string is ever joined into one.
"""

from __future__ import annotations

import os
import shutil
import subprocess  # noqa: S404 - the one audited use in the remote package
from typing import Mapping

from .models import RemoteFailureCategory, RemoteOperation, RemoteTarget
from .models import RemoteExecutionResult
from .redaction import redact_remote_output
from .target import TargetError
from .transport import RemoteTransport, prepare_result

# Options pinned on every invocation. Each is set to the value this platform
# requires rather than left to whatever the client would otherwise choose.
#
#   BatchMode                 never prompt; a hung prompt is an unbounded wait
#   StrictHostKeyChecking     an unknown or changed key fails the attempt
#   PasswordAuthentication    keys or agent only
#   ForwardAgent / ForwardX11 the target is never granted a channel back
#   RequestTTY                no terminal is allocated; this is not a session
#   ClearAllForwardings       cancels anything an inherited config asked for
PINNED_SSH_OPTIONS: tuple[str, ...] = (
    "BatchMode=yes",
    "StrictHostKeyChecking=yes",
    "PasswordAuthentication=no",
    "KbdInteractiveAuthentication=no",
    "PubkeyAuthentication=yes",
    "ForwardAgent=no",
    "ForwardX11=no",
    "RequestTTY=no",
    "ClearAllForwardings=yes",
)

# Fragments the client writes to stderr, mapped to what they say about the
# attempt. Each describes the connection, never the host's health.
STDERR_SIGNATURES: tuple[tuple[str, str], ...] = (
    ("host key verification failed", RemoteFailureCategory.HOST_KEY_FAILURE.value),
    ("no matching host key", RemoteFailureCategory.HOST_KEY_FAILURE.value),
    ("remote host identification has changed",
     RemoteFailureCategory.HOST_KEY_FAILURE.value),
    ("permission denied", RemoteFailureCategory.AUTHENTICATION_FAILURE.value),
    ("too many authentication failures",
     RemoteFailureCategory.AUTHENTICATION_FAILURE.value),
)

FAILURE_SUMMARIES = {
    RemoteFailureCategory.HOST_KEY_FAILURE.value:
        "the target's host key did not match the approved known-hosts entry",
    RemoteFailureCategory.AUTHENTICATION_FAILURE.value:
        "the target refused the offered authentication",
    RemoteFailureCategory.TRANSPORT_FAILURE.value:
        "the connection attempt did not complete",
    RemoteFailureCategory.TIMEOUT.value:
        "the operation did not complete within its time ceiling",
}


def ssh_executable() -> str:
    """Resolve the system ssh client.

    Falls back to the bare name when it is not on PATH so argv construction
    stays inspectable on a host without an ssh client installed.
    """
    return shutil.which("ssh") or "ssh"


def build_ssh_argv(target: RemoteTarget, operation: RemoteOperation) -> tuple[str, ...]:
    """Build the exact argv for one attempt.

    Pure and deterministic: it reads no clock, no environment, and no config
    file, so the same target and operation always produce the same argv. This
    is what makes the transport testable without running it.

    Fails before producing an argv when a reference is missing, so a target
    with no approved known-hosts file can never reach the client at all.
    """
    known_hosts = str(target.known_hosts_reference or "").strip()
    if not known_hosts:
        raise TargetError(
            f"target '{target.target_id}' has no known-hosts reference; "
            "host-key verification cannot be performed"
        )

    authentication = target.authentication_reference
    if authentication is None or not str(authentication.reference or "").strip():
        raise TargetError(
            f"target '{target.target_id}' has no authentication reference"
        )

    argv: list[str] = [ssh_executable()]
    for option in PINNED_SSH_OPTIONS:
        argv += ["-o", option]

    argv += ["-o", f"UserKnownHostsFile={known_hosts}"]
    argv += ["-o", f"ConnectTimeout={int(target.connect_timeout_seconds)}"]

    if authentication.kind == "ssh-key-path":
        # IdentitiesOnly stops the client offering every key an agent holds to
        # a host that only needs one.
        argv += ["-o", "IdentitiesOnly=yes"]
        argv += ["-i", authentication.reference]

    argv += ["-p", str(int(target.port))]
    argv += ["-l", target.username]
    argv.append(target.hostname)

    # The operation's words are appended as discrete entries. They are never
    # joined, quoted, or interpolated into a single string.
    argv.extend(operation.argv)

    return tuple(argv)


def child_environment(target: RemoteTarget) -> Mapping[str, str]:
    """The minimal environment the ssh client receives.

    The ambient environment is not inherited: it routinely carries agent
    sockets, proxy settings, and credentials that would silently change what
    the client does.
    """
    environment = {
        "PATH": "/usr/bin:/bin",
        "HOME": "/nonexistent",
        "LC_ALL": "C",
    }
    reference = target.authentication_reference
    if reference is not None and reference.kind == "ssh-agent":
        socket = os.environ.get("SSH_AUTH_SOCK")
        if socket:
            environment["SSH_AUTH_SOCK"] = socket
    return environment


def classify_stderr(text: str) -> str | None:
    """Map client diagnostics to a failure category, or None."""
    lowered = text.lower()
    for fragment, category in STDERR_SIGNATURES:
        if fragment in lowered:
            return category
    return None


class SSHRemoteTransport(RemoteTransport):
    """Runs one catalog operation over the system ssh client.

    Never executed by the test suite. Everything asserted about it is asserted
    against `build_ssh_argv`.
    """

    def run(self, target: RemoteTarget, operation: RemoteOperation) -> RemoteExecutionResult:
        argv = build_ssh_argv(target, operation)
        timeout = min(int(target.command_timeout_seconds),
                      int(operation.timeout_ceiling_seconds))

        try:
            completed = subprocess.run(  # noqa: S603 - argv-only, shell=False
                argv,
                shell=False,
                capture_output=True,
                timeout=timeout,
                env=dict(child_environment(target)),
                check=False,
            )
        except subprocess.TimeoutExpired:
            return RemoteExecutionResult(
                operation_id=operation.operation_id,
                exit_status=None,
                stdout="",
                stderr="",
                failure_category=RemoteFailureCategory.TIMEOUT.value,
                summary=FAILURE_SUMMARIES[RemoteFailureCategory.TIMEOUT.value],
            )
        except OSError as error:
            return RemoteExecutionResult(
                operation_id=operation.operation_id,
                exit_status=None,
                stdout="",
                stderr="",
                failure_category=RemoteFailureCategory.TRANSPORT_FAILURE.value,
                summary=(
                    f"{FAILURE_SUMMARIES[RemoteFailureCategory.TRANSPORT_FAILURE.value]}"
                    f" ({type(error).__name__})"
                ),
            )

        stderr_text, _ = redact_remote_output(
            completed.stderr.decode("utf-8", errors="replace"))
        category = classify_stderr(stderr_text)

        if category is None and completed.returncode != 0:
            category = RemoteFailureCategory.COLLECTION_FAILURE.value

        if category is not None:
            return RemoteExecutionResult(
                operation_id=operation.operation_id,
                exit_status=completed.returncode,
                stdout="",
                stderr=stderr_text,
                failure_category=category,
                summary=FAILURE_SUMMARIES.get(
                    category,
                    f"operation '{operation.operation_id}' returned a non-zero status",
                ),
            )

        return prepare_result(
            target=target,
            operation=operation,
            exit_status=completed.returncode,
            stdout=completed.stdout,
            stderr=completed.stderr,
        )
