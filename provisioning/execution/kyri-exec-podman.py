"""The governed Podman backend. **Not installed by anything in this repo.**

This file becomes `/usr/lib/kyri/python/kyri_exec_podman.py`, owned `root:root`,
mode `0444`. Installing it is part of the Generation-13 ceremony.

**It is the only module in Kyri that starts a process.** Everything under
`tools/capability/` is asserted to reach no subprocess at all, and
`lifecycle.py` -- the first module allowed even to *name* Podman -- is held to
"naming it is all that is permitted: no socket, no API, no remote URI, no
subprocess". So the binding lives out here, on the installed side, where the
worker already runs.

**It executes the argv it is given and composes none of it.** The governed
command line is built by `worker.create_argv` from an authenticated snapshot,
and this module does not add a flag, drop one, or reorder them. The one thing
it may prepend is a storage location, and only `--root`/`--runroot` with
absolute paths -- the seam that lets an isolated store be tested without a
second code path. Production passes none.

**Four verbs, and they are a closed set.** `create`, `inspect`, `start` and the
lifecycle reads. `pull`, `build`, `run`, `load`, `push`, `tag`, `exec` and
`cp` are absent rather than unused, and `_run` refuses a subcommand outside the
set before any process exists.

**Observation is translation, never substitution.** Every field of the returned
report comes from what Podman actually said. Where Podman spells something
differently from the accepted observation shape the name is translated; where
Podman does not report a thing, the key is left out so it arrives as `None` and
fails verification. Nothing is filled in from the profile: that is the whole
point of observing, and G11-AJ and G11-AK each removed a field that had been
doing exactly that.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §7,
§12 and §17.

Intended installed ownership and mode: ``root:root``, ``0444``.
"""

from __future__ import annotations

import json
import subprocess
from typing import Any, Mapping, Sequence

# The one executable this may reach, by absolute path. Not looked up on PATH:
# a runtime resolved through the environment is a runtime an attacker can aim.
PODMAN = "/usr/bin/podman"

# Every subcommand the accepted protocol needs, and nothing else. `ps` is here
# because reconciliation must be able to ask whether a container is still
# active without inspecting one that may have been removed.
PERMITTED_SUBCOMMANDS = frozenset({"create", "inspect", "start", "stop",
                                   "kill", "rm", "ps"})

# The environment the Podman process itself gets. This is the *host* side --
# the container's own environment is the adapter's closed set and travels in
# the argv, never here.
#
# `HOME` and `XDG_RUNTIME_DIR` are what rootless Podman resolves its storage
# and runtime state from, and they are exactly the two the transition sets in
# `worker.ENVIRONMENT`. They are taken from the transition rather than compiled
# in: the values below are the production ones and the default, but a backend
# that hardcoded them could only ever run as one identity, and the seam that
# makes it testable is the same seam the transition already owns.
BACKEND_ENVIRONMENT: tuple[tuple[str, str], ...] = (
    ("HOME", "/data/kyri/capability"),
    ("PATH", "/usr/bin:/bin"),
    ("XDG_RUNTIME_DIR", "/run/user/999"),
)

# Closed: three names, and no route by which a fourth could arrive.
PERMITTED_ENVIRONMENT = frozenset({"HOME", "PATH", "XDG_RUNTIME_DIR"})

# Generous for a container inspection and small enough that a runtime returning
# something pathological is refused rather than parsed.
MAXIMUM_OUTPUT_BYTES = 4 * 1024 * 1024
DEFAULT_TIMEOUT_SECONDS = 60

# Podman renders a container that never ran with the zero time rather than an
# absent one. Carried through as absence, because "started at the beginning of
# the calendar" is not a start.
ZERO_TIME = "0001-01-01T00:00:00Z"

_HEX = frozenset("0123456789abcdef")


class PodmanBackendRefused(OSError):
    """The backend will not proceed, and says why without concluding.

    Derives from `OSError` because `lifecycle.create` converts exactly that
    into a `LifecycleRefused`, so a refusal here becomes a refusal there rather
    than an unhandled exception halfway through an invocation.
    """


def _require_container_id(value: Any) -> str:
    """The full 64-character identity, or refuse.

    Podman prints the identity on stdout, and a short form is a convenience for
    humans rather than authority: two containers can share a prefix and the
    whole verification chain is anchored on this being unambiguous.
    """
    if not isinstance(value, str) or len(value) != 64 or set(value) - _HEX:
        raise PodmanBackendRefused(
            "the runtime did not return a full 64-character container identity")
    return value


def _require_container_name(value: Any) -> str:
    """A governed container name, or refuse.

    Closed grammar: the runtime's prefix and one CINV. A caller cannot reach
    this -- the reconciler derives the name from an invocation identity -- and
    the check is here so that stays true if anything ever tries.
    """
    if not isinstance(value, str) or not value.startswith("kyri-CINV-"):
        raise PodmanBackendRefused(
            "only a governed kyri-CINV container name may be named")
    suffix = value[len("kyri-CINV-"):]
    if len(suffix) != 6 or set(suffix) - set("0123456789"):
        raise PodmanBackendRefused("the container name is not kyri-CINV-nnnnnn")
    return value


def _canonical_image_id(value: Any) -> Any:
    """A bare 64-hex image identity, or ``None``.

    Podman spells the same identity two ways depending on which command
    produced it: `images --no-trunc` prefixes the algorithm, container inspect
    does not. Only that one known difference is normalised. A truncated id, an
    uppercase one, a tag, or a longer string containing the identity is not a
    different spelling of it -- it is a different thing, and returning `None`
    makes it fail rather than match.
    """
    if not isinstance(value, str):
        return None
    bare = value[len("sha256:"):] if value.startswith("sha256:") else value
    if len(bare) != 64 or set(bare) - _HEX:
        return None
    return bare


def _tmpfs(reported: Any, destination: str = "/tmp") -> tuple[Any, Any, Any]:
    """Size, mode and options for the governed tmpfs, as Podman states them.

    Podman reports the mount as one option string -- `size=16m,mode=1777,...`
    -- so it is parsed rather than read. Anything unparseable yields `None` and
    fails verification; nothing is assumed from the governed value.
    """
    if not isinstance(reported, Mapping) or destination not in reported:
        return None, None, None
    options = reported[destination]
    if not isinstance(options, str):
        return None, None, None

    size: Any = None
    mode: Any = None
    words: list[str] = []
    for option in options.split(","):
        if option.startswith("size="):
            raw = option[len("size="):]
            multiplier = 1
            if raw[-1:].lower() == "m":
                multiplier, raw = 1024 * 1024, raw[:-1]
            elif raw[-1:].lower() == "k":
                multiplier, raw = 1024, raw[:-1]
            if raw.isdigit():
                size = int(raw) * multiplier
        elif option.startswith("mode="):
            raw = option[len("mode="):]
            if raw.isdigit():
                # Podman states the mode in octal, as it was given.
                mode = int(raw, 8)
        elif option in ("noexec", "nosuid", "nodev"):
            words.append(option)
    return size, mode, tuple(words) if words else None


def _capabilities(host_config: Mapping[str, Any],
                  report: Mapping[str, Any]) -> tuple[Any, Any]:
    """What the container may hold, and the claim that everything was dropped.

    Two facts, and the second is derived from the first rather than from the
    request.

    `BoundingCaps` is the set a process in this container could ever hold.
    Verified against the installed Podman: a container created without
    `--cap-drop ALL` reports all eleven of this host's capabilities there,
    and one created with it omits the key entirely. So a present, non-empty
    bounding set is positive evidence that capabilities remain, and it fails.

    The profile states the policy as the single word `ALL`, while Podman states
    the same fact as an eleven-name expansion. Normalising the expansion back
    to `ALL` is only done when the bounding set agrees that nothing remains --
    otherwise the raw expansion is reported and the comparison fails. The
    normalisation follows the evidence rather than the flag that was passed.
    """
    bounding = report.get("BoundingCaps")
    effective: tuple[str, ...] = tuple(bounding) if bounding else ()

    dropped = host_config.get("CapDrop")
    if dropped is None:
        return None, effective
    if effective == () and tuple(dropped):
        return ("ALL",), effective
    return tuple(dropped), effective


class PodmanBackend:
    """The governed runtime binding, and the only process this platform starts.

    ``storage`` exists so an isolated `--root`/`--runroot` can be exercised
    without a second code path through the argv. It is not a widening: only
    those two flags are accepted, both values must be absolute, production
    supplies none, and nothing here reaches the environment for a default.
    """

    __slots__ = ("_environment", "_storage", "_timeout")

    def __init__(self, *, storage: Sequence[str] = (),
                 environment: Sequence[tuple[str, str]] = BACKEND_ENVIRONMENT,
                 timeout: int = DEFAULT_TIMEOUT_SECONDS) -> None:
        closed: dict[str, str] = {}
        for name, value in environment:
            if name not in PERMITTED_ENVIRONMENT:
                raise PodmanBackendRefused(
                    f"the backend environment may not carry {name!r}")
            if name != "PATH" and not value.startswith("/"):
                raise PodmanBackendRefused(f"{name} must be an absolute path")
            closed[name] = value
        self._environment = tuple(sorted(closed.items()))
        prefix: list[str] = []
        pending: str | None = None
        for word in storage:
            if pending is not None:
                if not isinstance(word, str) or not word.startswith("/"):
                    raise PodmanBackendRefused(
                        f"{pending} requires an absolute path")
                prefix.extend((pending, word))
                pending = None
                continue
            if word not in ("--root", "--runroot"):
                raise PodmanBackendRefused(
                    "only --root and --runroot may precede the subcommand")
            pending = word
        if pending is not None:
            raise PodmanBackendRefused(f"{pending} was given no value")
        self._storage = tuple(prefix)
        self._timeout = timeout

    # --- the subprocess boundary ------------------------------------------
    #
    # One place where a process is created, and every property of it is stated
    # here rather than at a call site. No caller supplies an executable, a
    # shell, an environment, or a timeout, and no `subprocess` object escapes:
    # what comes back is bytes or a refusal.

    def _run(self, subcommand: str, arguments: Sequence[str]) -> str:
        if subcommand not in PERMITTED_SUBCOMMANDS:
            raise PodmanBackendRefused(
                f"{subcommand!r} is not a permitted Podman subcommand")
        argv = [PODMAN, *self._storage, subcommand, *arguments]
        return self._execute(argv)

    def _execute(self, argv: Sequence[str]) -> str:
        for word in argv:
            if not isinstance(word, str):
                raise PodmanBackendRefused(
                    "the command line holds a non-string argument")
        try:
            completed = subprocess.run(  # noqa: S603 - argv vector, never a shell
                list(argv),
                executable=PODMAN,
                shell=False,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                env=dict(self._environment),
                timeout=self._timeout,
                check=False,
            )
        except subprocess.TimeoutExpired:
            raise PodmanBackendRefused(
                f"the runtime did not answer within {self._timeout}s") from None
        except OSError as error:
            raise PodmanBackendRefused(
                f"the runtime could not be executed: {error}") from None

        if len(completed.stdout) > MAXIMUM_OUTPUT_BYTES:
            raise PodmanBackendRefused("the runtime returned an unbounded reply")
        if completed.returncode != 0:
            detail = completed.stderr[:2048].decode("utf-8", "replace").strip()
            raise PodmanBackendRefused(
                f"the runtime refused: {detail or completed.returncode}")
        return completed.stdout.decode("utf-8", "strict")

    def _inspect_document(self, container_id: str) -> Mapping[str, Any]:
        raw = self._run("inspect", ["--type", "container", container_id])
        try:
            document = json.loads(raw)
        except ValueError as error:
            raise PodmanBackendRefused(
                f"the inspection is not readable JSON: {error}") from None
        if not isinstance(document, list) or len(document) != 1:
            raise PodmanBackendRefused(
                "the inspection did not describe exactly one container")
        entry = document[0]
        if not isinstance(entry, dict):
            raise PodmanBackendRefused("the inspection is not an object")
        if entry.get("Id") != container_id:
            raise PodmanBackendRefused(
                "the inspection describes a different container")
        return entry

    # --- the protocol -----------------------------------------------------

    def create(self, argv: Sequence[str],
               environment: Sequence[tuple[str, str]]) -> str:
        """Create the container from the governed argv, exactly as given.

        ``environment`` is the transition's own. It is not merged into the
        child -- the Podman process gets the closed set this backend was built
        with, and the container gets the adapter's closed set through the argv.
        Accepting it here and ignoring it would be dishonest, so it is checked:
        a caller passing something other than what this backend was configured
        with is a caller whose assumptions are wrong, and that is worth a
        refusal rather than a silent divergence.
        """
        if not argv or argv[0] != PODMAN:
            raise PodmanBackendRefused(
                "the governed command line does not name the runtime")
        if tuple(argv[1:2]) != ("create",):
            raise PodmanBackendRefused(
                "the backend creates containers and does nothing else")
        for name, value in environment:
            if (name, value) not in self._environment:
                raise PodmanBackendRefused(
                    f"the transition environment carries an unexpected {name}")
        # The storage seam goes between the binary and the subcommand, which is
        # where Podman takes it; the governed argv is otherwise untouched.
        composed = [argv[0], *self._storage, *argv[1:]]
        return _require_container_id(self._execute(composed).strip())

    def inspect(self, container_id: str) -> dict[str, Any]:
        """Translate one container inspection into the accepted shape.

        Names are translated where Podman spells them differently. Nothing is
        defaulted and nothing is taken from the profile: a key Podman did not
        report is left out, arrives as ``None``, and fails verification.
        """
        entry = self._inspect_document(container_id)
        host = entry.get("HostConfig")
        config = entry.get("Config")
        if not isinstance(host, dict) or not isinstance(config, dict):
            raise PodmanBackendRefused("the inspection has no configuration")

        dropped, effective = _capabilities(host, entry)
        tmpfs_bytes, tmpfs_mode, tmpfs_options = _tmpfs(host.get("Tmpfs"))
        mappings = host.get("IDMappings")
        mappings = mappings if isinstance(mappings, dict) else {}
        security = host.get("SecurityOpt")

        report: dict[str, Any] = {
            # `Image` is the immutable local id the container was actually
            # instantiated from. `ImageName` is whatever mutable reference was
            # used at create and `ImageDigest` is a registry manifest digest,
            # so neither is read: a retag must not move the identity a
            # container is verified against.
            "Image": _canonical_image_id(entry.get("Image")),
            "NetworkMode": host.get("NetworkMode"),
            # Podman spells it with a lowercase 'o'.
            "ReadOnlyRootfs": host.get("ReadonlyRootfs"),
            "NoNewPrivileges": ("no-new-privileges" in security
                                if isinstance(security, list) else None),
            "CapDrop": dropped,
            "EffectiveCaps": effective,
            "Memory": host.get("Memory"),
            "MemorySwap": host.get("MemorySwap"),
            "CpuQuota": host.get("CpuQuota"),
            "CpuPeriod": host.get("CpuPeriod"),
            "PidsLimit": host.get("PidsLimit"),
            "User": config.get("User"),
            "Hostname": config.get("Hostname"),
            "Mounts": entry.get("Mounts"),
            "Devices": host.get("Devices"),
            "TmpfsSize": tmpfs_bytes,
            "TmpfsMode": tmpfs_mode,
            "TmpfsOptions": tmpfs_options,
            "UidMap": mappings.get("UidMap"),
            "GidMap": mappings.get("GidMap"),
        }
        # Deliberately absent: ProfileSchemaVersion, which is not a property of
        # a container, and Sockets, which Podman does not report and which the
        # observation derives from these mounts instead.
        return report

    def start(self, container_id: str) -> None:
        """Start exactly the recorded container, and wait for it to finish.

        ``--attach`` rather than a detached start and a poll: attaching makes
        the call return when the workload has actually terminated, so the
        lifecycle read that follows describes a finished container rather than
        one that may still be running. A non-zero workload exit is not a
        backend failure -- it is the result -- so the exit status is not
        checked here and is read from the container's own state instead.
        """
        recorded = _require_container_id(container_id)
        argv = [PODMAN, *self._storage, "start", "--attach", recorded]
        try:
            subprocess.run(  # noqa: S603 - argv vector, never a shell
                argv, executable=PODMAN, shell=False,
                stdin=subprocess.DEVNULL, capture_output=True,
                env=dict(self._environment), timeout=self._timeout,
                check=False)
        except subprocess.TimeoutExpired:
            # The client stopped waiting; the container has not been stopped.
            # Saying so is the whole point -- reconciliation is the caller's,
            # and a backend that reported success here would have invented it.
            raise PodmanBackendRefused(
                f"the workload did not finish within {self._timeout}s") from None
        except OSError as error:
            raise PodmanBackendRefused(
                f"the container could not be started: {error}") from None

    def lifecycle(self, container_id: str) -> dict[str, Any]:
        """What the container's own state says happened."""
        recorded = _require_container_id(container_id)
        entry = self._inspect_document(recorded)
        state = entry.get("State")
        if not isinstance(state, dict):
            raise PodmanBackendRefused("the container reports no state")
        started = state.get("StartedAt")
        finished = state.get("FinishedAt")
        status = state.get("Status")
        return {
            "container_id": recorded,
            "state": status.lower() if isinstance(status, str) else None,
            # The zero time is Podman's rendering of "never", and is carried
            # through as absence rather than as a timestamp.
            "started_at": None if started in (None, ZERO_TIME) else started,
            "finished_at": None if finished in (None, ZERO_TIME) else finished,
            "exit_code": state.get("ExitCode"),
        }

    # --- reconciliation ---------------------------------------------------

    def still_active(self, container_id: str) -> bool:
        """Whether the container itself is still running.

        Asked of the container rather than of this process: a client that
        stopped waiting has not stopped anything.
        """
        recorded = _require_container_id(container_id)
        raw = self._run("ps", ["--all", "--no-trunc", "--filter",
                               f"id={recorded}", "--format", "{{.State}}"])
        return raw.strip().lower() in ("running", "paused", "stopping")

    def terminate(self, container_id: str) -> None:
        """Ask the container to stop, within the governed grace period."""
        recorded = _require_container_id(container_id)
        self._run("stop", ["--time", "2", recorded])

    def kill(self, container_id: str) -> None:
        """Stop the container without asking."""
        recorded = _require_container_id(container_id)
        self._run("kill", ["--signal", "KILL", recorded])

    def remove(self, container_id: str) -> None:
        """Remove the container once its evidence has been read."""
        recorded = _require_container_id(container_id)
        self._run("rm", ["--force", recorded])

    # --- reconciliation ---------------------------------------------------
    #
    # Keyed by NAME rather than by container id, because reconciliation starts
    # from an invocation identity and the container id is exactly what is lost
    # when supervision is lost. The name is derived from the CINV by the
    # reconciler; nothing here accepts a name a caller composed.

    def find_container(self, name: str) -> Any:
        """The inspection for one named container, or ``None`` if absent.

        Absence is a value, not an error: it is the terminal state
        reconciliation is trying to reach, and the ordinary case after a normal
        execution. Every other failure still raises.
        """
        _require_container_name(name)
        argv = [PODMAN, *self._storage, "inspect", "--type", "container", name]
        try:
            completed = subprocess.run(  # noqa: S603 - argv vector, never a shell
                argv, executable=PODMAN, shell=False,
                stdin=subprocess.DEVNULL, capture_output=True,
                env=dict(self._environment), timeout=self._timeout, check=False)
        except subprocess.TimeoutExpired:
            raise PodmanBackendRefused(
                f"the runtime did not answer within {self._timeout}s") from None
        except OSError as error:
            raise PodmanBackendRefused(
                f"the runtime could not be executed: {error}") from None
        if completed.returncode != 0:
            detail = completed.stderr.decode("utf-8", "replace")
            # Podman distinguishes "no such container" from every other
            # failure, and only that one is an answer rather than a problem.
            if "no such container" in detail.lower():
                return None
            raise PodmanBackendRefused(f"the runtime refused: {detail[:512].strip()}")
        document = json.loads(completed.stdout)
        if not isinstance(document, list) or len(document) != 1:
            raise PodmanBackendRefused(
                "the inspection did not describe exactly one container")
        return document[0]

    def stop_container(self, name: str, *, timeout: int) -> None:
        """Ask one named container to stop, within a bounded time."""
        _require_container_name(name)
        self._run("stop", ["--time", str(int(timeout)), name])

    def kill_container(self, name: str) -> None:
        """Stop one named container without asking."""
        _require_container_name(name)
        self._run("kill", ["--signal", "KILL", name])

    def remove_container(self, name: str) -> None:
        """Remove one named container."""
        _require_container_name(name)
        self._run("rm", ["--force", name])


# --- the closed backend registry -------------------------------------------
#
# One adapter identity, one implementation, resolved by equality. There is no
# import by name, no entry point, no plugin directory, no configured module and
# no operator-supplied executable: the mapping is this dictionary, and a
# adapter identity that is not in it has no implementation rather than a
# default one.
_REGISTRY = {"python-podman-v1": PodmanBackend}


def backend_for(adapter_identity: str, **options: Any) -> PodmanBackend:
    """The governed backend for an adapter identity, or refuse."""
    implementation = _REGISTRY.get(adapter_identity)
    if implementation is None:
        raise PodmanBackendRefused(
            f"no governed backend is bound to {adapter_identity!r}")
    return implementation(**options)


__all__ = ["BACKEND_ENVIRONMENT", "PERMITTED_ENVIRONMENT", "PODMAN",
           "PERMITTED_SUBCOMMANDS",
           "PodmanBackend", "PodmanBackendRefused", "backend_for"]
