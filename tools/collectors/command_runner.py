"""The single audited chokepoint for local read-only command execution.

This is the only module in the collector framework permitted to import
`subprocess`. Everything else calls through here, which is what makes the
v0.6.0 subprocess permission a narrowing of the v0.5.0 prohibition rather than
a relaxation of it: the capability exists in exactly one reviewable place.

Guarantees enforced here, not by convention:

- `shell=False` always. There is no code path that builds a shell string.
- The executable must be explicitly allow-listed by the caller.
- Shells and network tools are refused even if a caller allow-lists them.
- A positive timeout is mandatory; there is no unbounded execution.
- stdout and stderr are captured with a byte ceiling and fail closed on
  truncation unless the caller opts in.
- The child receives a minimal environment, never the ambient one.
- Arguments that look like credentials are refused, and the refusal never
  echoes the offending value.

This is deliberately not a general-purpose execution framework. It exists to
run a handful of read-only inspection commands and nothing else.
"""

from __future__ import annotations

import os
import shutil
import subprocess  # noqa: S404 - the one audited use in this package
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Mapping

from .exceptions import CollectorConfigurationError, CollectorExecutionError

# Refused even when a caller allow-lists them. A shell reintroduces the
# injection surface `shell=False` removes; the network tools would let a
# "read-only" collector reach the outside world.
NEVER_EXECUTABLE = frozenset({
    "sh", "bash", "zsh", "dash", "ksh", "csh", "fish",
    "powershell", "pwsh", "cmd", "cmd.exe",
    "ssh", "scp", "sftp", "rsync", "curl", "wget", "nc", "ncat", "netcat",
    "telnet", "ftp", "python", "python3", "perl", "ruby", "node", "env", "xargs",
})

# Argument fragments that would carry a credential on a command line. Command
# lines are visible in process listings and shell history, so a secret passed
# this way is already disclosed.
SECRET_ARGUMENT_MARKERS = (
    "--password", "--passwd", "--token", "--api-key", "--apikey",
    "--secret", "--client-secret", "--bearer", "--credential",
    "authorization:", "bearer ", "api_key=", "apikey=", "token=",
    "password=", "secret=",
)

DEFAULT_MAX_STDOUT_BYTES = 1_048_576
DEFAULT_MAX_STDERR_BYTES = 65_536


@dataclass(frozen=True)
class CommandResult:
    """Normalized outcome of one command. Carries no environment values."""

    argv: tuple[str, ...]
    exit_code: int
    stdout: str
    stderr: str
    stdout_truncated: bool = False
    stderr_truncated: bool = False
    duration_note: str = "not-measured"

    @property
    def succeeded(self) -> bool:
        return self.exit_code == 0


def _minimal_environment(extra: Mapping[str, str] | None) -> dict[str, str]:
    """Build the child environment explicitly.

    The ambient environment is never inherited. A collector process may hold
    credentials from its own invocation context, and passing those to a child
    is how a read-only inspection command ends up authenticating to something.
    """
    env: dict[str, str] = {
        "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
    }
    if extra:
        for key, value in extra.items():
            if not isinstance(key, str) or not isinstance(value, str):
                raise CollectorConfigurationError("sanitized environment entries must be strings")
            lowered = key.lower()
            if any(marker in lowered for marker in ("secret", "token", "password", "key", "cred")):
                raise CollectorConfigurationError(
                    f"environment variable '{key}' looks secret-bearing and must not be passed"
                )
            env[key] = value
    return env


def _screen_arguments(argv: tuple[str, ...]) -> None:
    for argument in argv:
        lowered = str(argument).lower()
        for marker in SECRET_ARGUMENT_MARKERS:
            if marker in lowered:
                # The value is never included: an error that echoes the secret
                # it objected to has disclosed it to whatever captured the log.
                raise CollectorConfigurationError(
                    f"argument containing '{marker}' is not permitted; value withheld"
                )


def run_read_only_command(
    argv: Iterable[str],
    *,
    cwd: Path | str,
    timeout_seconds: int,
    allowed_executables: Iterable[str],
    max_stdout_bytes: int = DEFAULT_MAX_STDOUT_BYTES,
    max_stderr_bytes: int = DEFAULT_MAX_STDERR_BYTES,
    sanitized_environment: Mapping[str, str] | None = None,
    accept_truncation: bool = False,
) -> CommandResult:
    """Run one local read-only command and return normalized output.

    Raises CollectorConfigurationError for anything disallowed before
    execution, and CollectorExecutionError for timeouts and truncation.
    Never prints command output and never logs environment values.
    """
    argv = tuple(str(part) for part in argv)
    if not argv:
        raise CollectorConfigurationError("argv must not be empty")

    if not isinstance(timeout_seconds, int) or timeout_seconds <= 0:
        raise CollectorConfigurationError("timeout_seconds must be a positive integer")

    executable = argv[0]
    name = Path(executable).name
    allowed = {str(item) for item in allowed_executables}

    if name in NEVER_EXECUTABLE or executable in NEVER_EXECUTABLE:
        raise CollectorConfigurationError(
            f"executable '{name}' is never permitted in a collector"
        )
    if name not in allowed and executable not in allowed:
        raise CollectorConfigurationError(
            f"executable '{name}' is not in the caller's allowlist"
        )

    resolved = shutil.which(executable) if not Path(executable).is_absolute() else executable
    if not resolved or not Path(resolved).exists():
        raise CollectorConfigurationError(f"executable '{name}' could not be resolved")

    _screen_arguments(argv)

    directory = Path(cwd)
    if not directory.is_dir():
        raise CollectorConfigurationError("working directory does not exist")

    try:
        completed = subprocess.run(  # noqa: S603 - argv list, shell=False, allow-listed
            [resolved, *argv[1:]],
            cwd=str(directory),
            capture_output=True,
            text=True,
            shell=False,
            timeout=timeout_seconds,
            stdin=subprocess.DEVNULL,
            env=_minimal_environment(sanitized_environment),
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise CollectorExecutionError(
            f"command '{name}' exceeded its {timeout_seconds}s timeout"
        ) from error
    except OSError as error:
        raise CollectorExecutionError(
            f"command '{name}' could not be executed: {type(error).__name__}"
        ) from error

    stdout = completed.stdout or ""
    stderr = completed.stderr or ""
    stdout_truncated = len(stdout.encode("utf-8")) > max_stdout_bytes
    stderr_truncated = len(stderr.encode("utf-8")) > max_stderr_bytes

    if stdout_truncated:
        stdout = stdout.encode("utf-8")[:max_stdout_bytes].decode("utf-8", "ignore")
    if stderr_truncated:
        stderr = stderr.encode("utf-8")[:max_stderr_bytes].decode("utf-8", "ignore")

    if (stdout_truncated or stderr_truncated) and not accept_truncation:
        # Fail closed: a silently truncated inspection produces facts that look
        # complete and are not.
        raise CollectorExecutionError(
            f"command '{name}' output exceeded the configured byte limit"
        )

    return CommandResult(
        argv=(name, *argv[1:]),
        exit_code=completed.returncode,
        stdout=stdout,
        stderr=stderr.strip(),
        stdout_truncated=stdout_truncated,
        stderr_truncated=stderr_truncated,
    )
