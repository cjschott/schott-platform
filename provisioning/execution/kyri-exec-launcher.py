"""The coordinator's process boundary. **Not installed by anything here.**

This file becomes `/usr/lib/kyri/python/kyri_exec_launcher.py`, owned
`root:root`, mode `0444`. Installing it is part of the Generation-13 ceremony.

**It is the only coordinator-side module that starts a process.** Everything
under `tools/capability/` is asserted to reach no subprocess at all, and
`supervision.py` -- the module that drives an execution -- takes its launcher by
injection precisely so the choice is made out here rather than buried in the
library. `kyri_exec_podman.py` is the same shape on the worker's side of the
boundary, for the same reason.

**Two commands, and they are a closed set.** The launch helper and the
reconciliation helper, each by absolute path, each taking exactly one canonical
`CINV`. There is no third, no shell, no `PATH` lookup, and no argument a caller
contributes: `sudo` itself is named absolutely, the helpers are named
absolutely, and the one value that crosses is validated here before any list is
built.

**It grants nothing.** Whether the coordinator may run either helper is decided
by sudoers, which pins each to a digest and an argument regex. This module can
only ask; a host without the grants gets a refusal, which is exactly what an
uninstalled deployment should get.

**The protocol descriptors are the whole interface.** The child receives the
coordinator's frames on descriptor 0 and writes its own on descriptor 1. It
receives nothing else: no backend, no container identity, no package path, no
image, no Podman argv, no result path. Everything the worker needs, it derives
from the `CINV` and the profile the transition seals onto descriptor 3 -- which
this side never sees and could not forge.

Intended installed ownership and mode: ``root:root``, ``0444``.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
from typing import Any, Sequence

SUDO = "/usr/bin/sudo"
TRANSITION_HELPER = "/usr/libexec/kyri-exec-transition"
RECONCILE_HELPER = "/usr/libexec/kyri-exec-reconcile"

# Closed: the two governed operations and no others. A registry rather than a
# parameter, so "which privileged command may this run" is a property of the
# source rather than of whatever a caller passed.
PERMITTED_HELPERS = frozenset({TRANSITION_HELPER, RECONCILE_HELPER})

# The environment the helper is started with. Closed and absolute, for the
# reason the backend's is: an environment inherited from the coordinator is an
# environment an attacker who reached the coordinator can aim.
LAUNCH_ENVIRONMENT: tuple[tuple[str, str], ...] = (
    ("PATH", "/usr/bin:/bin"),
)

# How long the reconciliation helper is given. Bounded because a cleanup that
# could hang forever is one that never proves anything, and unproven disposal is
# the case the readiness gate exists to catch.
RECONCILE_TIMEOUT_SECONDS = 120

MAXIMUM_REPORT_BYTES = 64 * 1024

_DIGITS = frozenset("0123456789")


class LauncherRefused(OSError):
    """The launcher will not proceed, and says why without concluding.

    Derives from `OSError` so a refusal here reaches the supervisor as the kind
    of failure it already handles, rather than as an unhandled exception halfway
    through an execution.
    """


def _require_cinv(value: Any) -> str:
    """The one value that crosses the privileged command interface, or refuse.

    Checked totally rather than sanitised: no stripping, no case folding, no
    normalisation, because each of those turns an input that should have been
    refused into one that was accepted. The helper validates it again on the
    far side; these are the two sides of a privilege boundary, and each checks
    what it uses.
    """
    if not isinstance(value, str) or len(value) != 11 \
            or not value.startswith("CINV-") or set(value[5:]) - _DIGITS:
        raise LauncherRefused(f"{value!r} is not a canonical CINV identity")
    return value


def _argv(helper: str, cinv: str) -> list[str]:
    """The exact command line, built from constants and one validated CINV."""
    if helper not in PERMITTED_HELPERS:
        raise LauncherRefused(f"{helper!r} is not a governed helper")
    # `-n`: never prompt. A launcher that could block on a password would hang
    # an invocation on a terminal nobody is watching.
    return [SUDO, "-n", helper, _require_cinv(cinv)]


class LaunchedWorker:
    """One running privileged transition, and the frames it exchanges.

    Owns the child's lifetime completely. The supervisor asks it for frames and
    for a bounded reap; it never receives the process object, so there is no
    signal, no argument and no descriptor it could reach around this class to
    touch.
    """

    __slots__ = ("_process", "_buffer", "cinv")

    def __init__(self, cinv: str, process: Any) -> None:
        self.cinv = cinv
        self._process = process
        self._buffer = bytearray()

    def reader(self) -> Any:
        """The next newline-delimited frame, or ``None`` at end of stream.

        Bounded, because a worker that never stops talking must not be able to
        make the coordinator consume memory without limit. End of stream is
        reported as absence rather than as an error: the supervisor treats a
        peer that stopped talking as a process fact, and turning it into an
        exception here would decide that question in the wrong module.
        """
        stream = self._process.stdout
        while True:
            index = self._buffer.find(b"\n")
            if index >= 0:
                frame = bytes(self._buffer[:index + 1])
                del self._buffer[:index + 1]
                return frame
            if len(self._buffer) > MAXIMUM_REPORT_BYTES:
                raise LauncherRefused("the worker's stream exceeded its bound")
            try:
                chunk = os.read(stream.fileno(), 4096)
            except OSError as error:
                raise LauncherRefused(
                    f"the worker's stream is unreadable: {error}") from None
            if not chunk:
                return None
            self._buffer.extend(chunk)

    def writer(self, frame: Any) -> None:
        """One encoded frame to the worker, completely.

        A short write is a partial message, and a partial message is a frame the
        worker will refuse. A closed pipe is a refusal rather than a silent
        success: the coordinator must not believe it authorised a start that
        never arrived.
        """
        if not isinstance(frame, (bytes, bytearray)):
            raise LauncherRefused("a frame is bytes")
        stream = self._process.stdin
        written = 0
        while written < len(frame):
            try:
                step = os.write(stream.fileno(), frame[written:])
            except OSError as error:
                raise LauncherRefused(
                    f"the worker's stream is unwritable: {error}") from None
            if step <= 0:
                raise LauncherRefused("the worker's stream stopped short")
            written += step

    def reap(self, timeout: Any) -> tuple[Any, bool]:
        """Wait, bounded, and always leave no child behind.

        Returns the exit status and whether the process was reaped within the
        bound. A worker that outlives it is signalled and waited for again --
        not abandoned, because an abandoned child is a zombie and a zombie is a
        process the platform has stopped accounting for.

        **The exit status is never an outcome.** It says the process ended, not
        that the capability succeeded; the supervisor keeps the two apart and
        this returns the fact rather than an interpretation of it.
        """
        for stream in (self._process.stdin, self._process.stdout):
            try:
                stream.close()
            except OSError:
                pass
        try:
            return self._process.wait(timeout=timeout), True
        except subprocess.TimeoutExpired:
            pass
        try:
            self._process.send_signal(signal.SIGKILL)
        except OSError:
            pass
        try:
            return self._process.wait(timeout=timeout), False
        except subprocess.TimeoutExpired:
            return None, False


class HelperLauncher:
    """The governed launch and reconcile operations, as the coordinator sees them.

    One object rather than two because they are the same authority boundary
    approached twice: both are `sudo` over an exact helper path with one
    `CINV`, and separating them would mean two copies of the argv rule.
    """

    __slots__ = ("_environment",)

    def __init__(self, *,
                 environment: Sequence[tuple[str, str]] = LAUNCH_ENVIRONMENT
                 ) -> None:
        self._environment = dict(environment)

    def launch(self, cinv: Any) -> LaunchedWorker:
        """Start the privileged transition for one invocation.

        Descriptor 0 and 1 are pipes this process owns both ends of; descriptor
        2 is inherited so the helper's refusals reach the operator's terminal
        rather than a pipe nobody reads. `close_fds` is the default and is left
        alone: everything else the coordinator holds stays on this side.
        """
        identity = _require_cinv(cinv)
        try:
            process = subprocess.Popen(  # noqa: S603 - closed argv, no shell
                _argv(TRANSITION_HELPER, identity),
                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=None, bufsize=0, shell=False, close_fds=True,
                env=self._environment)
        except OSError as error:
            raise LauncherRefused(
                f"the transition helper could not be started: {error}") from None
        return LaunchedWorker(identity, process)

    def reconcile(self, cinv: Any) -> dict:
        """Run the governed reconciliation for one invocation, or refuse.

        Returns the helper's own structured report. Nothing is inferred from the
        exit status: the report carries `final_absent`, which is the field the
        supervisor and the readiness gate act on, and a helper that exited zero
        without proving absence has not proven absence.
        """
        identity = _require_cinv(cinv)
        try:
            done = subprocess.run(  # noqa: S603 - closed argv, no shell
                _argv(RECONCILE_HELPER, identity),
                stdin=subprocess.DEVNULL, capture_output=True,
                timeout=RECONCILE_TIMEOUT_SECONDS, shell=False,
                check=False, env=self._environment)
        except (OSError, subprocess.SubprocessError) as error:
            raise LauncherRefused(
                f"the reconciliation helper did not complete: {error}") from None
        body = done.stdout
        if len(body) > MAXIMUM_REPORT_BYTES:
            raise LauncherRefused("the reconciliation report exceeded its bound")
        try:
            report = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise LauncherRefused(
                "the reconciliation helper produced no readable report") from None
        if not isinstance(report, dict) or report.get("invocation_id") != identity:
            raise LauncherRefused(
                "the reconciliation report names a different invocation")
        return report


__all__ = ["HelperLauncher", "LaunchedWorker", "LauncherRefused",
           "PERMITTED_HELPERS", "RECONCILE_HELPER", "SUDO", "TRANSITION_HELPER"]
