"""The G6.1 verification-only worker. **Not installed by anything in this repo.**

This file becomes `/usr/libexec/kyri-exec-verify-worker.py`, owned `root:root`,
mode `0444`. Installing it is part of the G6.1 ceremony.

**No shebang, and no executable bit**, exactly as the production worker: the
transition names the interpreter explicitly and passes this file to it as an
argument, so the shebang is out of the trust chain and mode `0444` means the
question of who may run it never arises. The exec tuple is

    execve("/usr/bin/python3",
           ("/usr/bin/python3", "/usr/libexec/kyri-exec-verify-worker.py",
            "CINV-nnnnnn", "CIMP-nnnnnn", "<64 lowercase hex profile digest>"),
           CLOSED_ENVIRONMENT)

— the same five elements, from the same authenticated launch record, over the
same sealed descriptor 3. Nothing about the invocation is weaker.

**It runs the production verification chain, not a version of it.**
``verification.verify_only`` calls ``worker.verify_execution``, which is the
production gate and the only route to ``create_argv``. There is no subset here,
no relaxed branch, and no flag that skips a step.

**It cannot reach execution, structurally.** This file imports
``tools.capability.execution.verification``. That module imports named symbols
from ``worker`` and never binds the module object, so ``create_argv`` is not
reachable by attribute access from either of them, and ``worker.create_argv``
imports ``snapshot`` lazily inside its own body, so a verification run never
loads ``snapshot`` at all. The absence is the mechanism, not a convention — the
suite asserts that ``snapshot`` is still absent from ``sys.modules`` after a
successful run, and that ``create_argv`` is unbound in every module this
entrypoint reaches.

**The one contact with the image store is a read.**
``require_image_present`` asks the execution identity's rootless store whether
the already-authorised image ID exists, and `image_store.RootlessImageStore`
answers it by reading the store's own image index — no process is started and
no container runtime is invoked, exactly as `kyri-exec-quota` sets a project
through ``ioctl`` rather than by driving ``xfs_quota``. That is what lets
``podman_invoked: false`` in the success record be literally true;
``image_presence_probed: true`` states the read, so the record does not
overclaim by omission either.

**Its output is one line of canonical JSON on success, and nothing on
failure.** A reader is entitled to treat that line as proof that the whole
chain ran, so it is emitted after the last check and never before one. Any
refusal exits non-zero having printed no record at all.

**It publishes identifiers and booleans only.** No payload bytes, no package
bytes, no profile contents beyond the schema version, no environment, no
authority records. Proving the chain ran does not require showing what it read.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §7,
§17, the execution transition boundary §8, and the G6.1 milestone.

Intended installed ownership and mode: ``root:root``, ``0444``.
"""

from __future__ import annotations

import os
import sys

USAGE = ("usage: /usr/bin/python3 /usr/libexec/kyri-exec-verify-worker.py "
         "CINV-nnnnnn CIMP-nnnnnn <64-hex profile_digest>")

# The canonical installed library root, compiled in and not configurable, for
# the same reason as the production worker: every other way of arriving at it
# is something an attacker or an accident can influence, and this process must
# load its policy from one root-owned tree. It is emphatically not the
# coordinator-owned checkout.
RUNTIME_LIBRARY_ROOT = "/usr/lib/kyri/python"

HANDOFF_ROOT = "/data/kyri/capability-handoff"


def _library():
    """The verification driver and the worker grammar, or refuse.

    Both come from the canonical root, and the root is proved to hold them
    before any import runs: a search that falls through to another tree has
    already executed that tree's module-level code by the time anything could
    object.
    """
    expected = os.path.join(RUNTIME_LIBRARY_ROOT, "tools", "capability",
                            "execution", "verification.py")
    identity_expected = os.path.join(RUNTIME_LIBRARY_ROOT, "tools", "capability",
                                     "execution", "identity.py")
    if not os.path.isfile(identity_expected):
        raise SystemExit(
            "the governed execution identity authority reader is not installed "
            f"at {identity_expected}")
    if not os.path.isdir(RUNTIME_LIBRARY_ROOT) or not os.path.isfile(expected):
        raise SystemExit(
            f"the governed verification library is not installed at {expected}")

    if RUNTIME_LIBRARY_ROOT not in sys.path:
        sys.path.insert(0, RUNTIME_LIBRARY_ROOT)

    try:
        from tools.capability.execution import verification
        # Named imports, never the module object: binding `worker` here would
        # put `create_argv` one attribute access away from a file whose whole
        # purpose is that it is not.
        from tools.capability.execution import identity as identity_module
        from tools.capability.execution.worker import (
            WorkerRefused, profile_from_descriptor, require_launch_context,
            require_worker_identity, PROFILE_FD)
    except ImportError as error:
        raise SystemExit(
            f"the governed verification library is not importable from "
            f"{RUNTIME_LIBRARY_ROOT}: {error}") from None

    resolved = getattr(verification, "__file__", None)
    if not resolved or not os.path.realpath(resolved).startswith(
            os.path.realpath(RUNTIME_LIBRARY_ROOT) + os.sep):
        raise SystemExit(
            f"the verification library resolved outside {RUNTIME_LIBRARY_ROOT} "
            f"({resolved}); refusing rather than executing it")
    return (verification, identity_module, WorkerRefused,
            profile_from_descriptor, require_launch_context,
            require_worker_identity, PROFILE_FD)


def main(argv: list[str]) -> int:
    """Verify everything, emit the record, and stop short of execution.

    The order is the production order because the steps are the production
    steps: argument shape, then identity, then the authenticated launch
    context, then the sealed profile, then the shared gate. Only after all of
    it does anything reach stdout.
    """
    if len(argv) != 4:
        raise SystemExit(USAGE)

    (verification, identity_module, WorkerRefused, profile_from_descriptor,
     require_launch_context, require_worker_identity, profile_fd) = _library()

    try:
        # The deployment's execution principal, from root-owned authority. Read
        # before anything else, because every step below is a claim about which
        # identity this process is.
        try:
            identity = identity_module.read_execution_identity()
        except identity_module.ExecutionIdentityError as error:
            raise WorkerRefused(str(error)) from None

        # The execution identity, by the library's own rule. Root is refused
        # there explicitly.
        require_worker_identity(uid=os.getuid(), gid=os.getgid(),
                                identity=identity)

        # The launch context, through the library's grammar rather than a local
        # copy of it.
        context = require_launch_context(
            cinv=argv[1], cimp=argv[2], profile_digest=argv[3])

        # The sealed object the transition authored, and the only place the
        # governed profile may come from. Seals are checked there.
        profile = profile_from_descriptor(context, descriptor=profile_fd)

        # The handoff root, opened the way the production worker opens it.
        try:
            root_fd = os.open(HANDOFF_ROOT,
                              os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
                              | os.O_DIRECTORY)
        except OSError as error:
            raise WorkerRefused(f"the handoff root is unusable: {error}") from None

        try:
            record = verification.verify_only(
                context, profile, root_fd=root_fd, images=_images(),
                identity=identity)
        finally:
            os.close(root_fd)

        line = verification.success_record(record, identity=identity)
    except WorkerRefused as error:
        # No record, no partial output, and a non-zero exit. A reader that sees
        # nothing on stdout has been told everything it needs.
        raise SystemExit(f"refused: {error}") from None

    sys.stdout.write(line + "\n")
    sys.stdout.flush()
    return 0


def _images():
    """The image store this identity may ask one question of.

    Presence only, for an identity `CIMP` resolution already decided, read from
    the rootless store this process owns. The store cannot resolve a tag, pull,
    inspect, create or run — it starts no process at all — and
    `require_image_present` refuses anything but a boolean back, so a store that
    tried to be clever would be refused rather than believed.
    """
    from tools.capability.execution.image_store import RootlessImageStore
    return RootlessImageStore()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
