"""The installed worker entrypoint. **Not installed by anything in this repo.**

This file becomes `/usr/libexec/kyri-exec-worker.py`, owned `root:root`, mode
`0444`. Installing it is gate G2.

**No shebang, and no executable bit.** The transition names the interpreter
explicitly and passes this file to it as an argument, so the shebang line is
out of the trust chain entirely: a script that cannot be executed cannot be
executed by the wrong interpreter, and at mode `0444` the question of who may
run it never arises. The exec tuple is exactly

    execve("/usr/bin/python3",
           ("/usr/bin/python3", "/usr/libexec/kyri-exec-worker.py",
            "CINV-nnnnnn", "CIMP-nnnnnn", "<64 lowercase hex profile digest>"),
           CLOSED_ENVIRONMENT)

**Five elements, and no optional shorter form.** The `CIMP` and the digest come
from the launch record the transition already authenticated. They are here
because the profile cannot be checked against itself and this process must not
read the coordinator-owned record — not because a caller may supply them. There
is no legacy three-element invocation to fall back to: accepting one would mean
accepting a profile nobody had bound to an implementation.

**It delegates and decides nothing.** Every rule about what a container may be
lives in `tools/capability/execution/worker.py` — the argv, the profile, the
mounts, the fixed container environment — and none of it is restated here. A
second copy of a Podman contract is one more than can be kept correct, and this
file exists to be an entrypoint rather than a policy.

**The arguments are revalidated here.** The sudoers policy already constrains
`^CINV-[0-9]{6}$` and the helper checks it again; this checks it a third time,
through the library's own grammar, because a validator that only runs somewhere
else is one syntax error away from not running at all.

**It holds no privilege and takes none.** By the time this runs the transition
has already dropped to `kyri-capability` and set `no_new_privs`. There is no
credential change here, no quota administration, no trust decision, and no
authority that a caller could aim: the inputs are three fixed-grammar tokens,
the profile arrives sealed on descriptor 3, and the protocol arrives on the
inherited descriptors 0, 1, and 2.

**G6 is open, and this is where it opens.** The governed Podman backend is
bound here, at the boundary, rather than inside `tools/capability/` — that
package is asserted to reach no subprocess at all, and the adapter takes its
backend by injection precisely so the choice is visible at one place. The
backend is selected by the *authenticated profile's* adapter identity through a
closed registry, so an identity with no implementation has no backend rather
than a default one.

**Podman runs only after the permanent drop, by construction.** By the time
this process exists the transition has already set the credentials and
`no_new_privs` and exec'd. There is no privileged step left here to perform and
none is performed, so the container is created from a permanently unprivileged
context as a property of where this code runs rather than of what it remembers
to do.

**The exit status says whether a result was admitted**, never merely whether
this process finished. A capability that failed, timed out, or produced nothing
collectable exits non-zero, so a parent cannot read "the worker exited" as "the
capability succeeded". The richer classification travels in the evidence, which
is where it can carry a reason.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §7,
§17, and the execution transition boundary §8.

Intended installed ownership and mode: ``root:root``, ``0444``.
"""

from __future__ import annotations

import os
import sys
import time

USAGE = ("usage: /usr/bin/python3 /usr/libexec/kyri-exec-worker.py "
         "CINV-nnnnnn CIMP-nnnnnn <64-hex profile_digest>")

_DIR_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY

# The protocol arrives on the inherited descriptor the transition left open.
# Bounded, because a coordinator that never stops talking must not be able to
# make this process consume memory without limit.
PROTOCOL_FD = 0
MAXIMUM_PROTOCOL_BYTES = 64 * 1024


def _frames():
    """The coordinator's already-written frames, read once and bounded.

    `protocol.Session` deliberately takes frames rather than a descriptor --
    reading them is somebody else's authority -- so this is that authority, and
    it is the whole of it: it splits on newlines and validates nothing. Every
    rule about what a frame may say belongs to the protocol module.
    """
    body = b""
    while len(body) <= MAXIMUM_PROTOCOL_BYTES:
        chunk = os.read(PROTOCOL_FD, 4096)
        if not chunk:
            break
        body += chunk
    if len(body) > MAXIMUM_PROTOCOL_BYTES:
        raise SystemExit("refused: the protocol stream exceeded its bound")
    return [line for line in body.split(b"\n") if line]

# The canonical installed library root, compiled in and not configurable.
#
# It is a literal because every other way of arriving at it is something an
# attacker or an accident can influence: argv, an environment variable, the
# working directory, package data, or the protocol. The execution identity must
# load its policy from one root-owned tree, and this is the only statement of
# which one.
#
# It is emphatically **not** the repository checkout. That tree is owned by the
# coordinator, and the worker holds rootless Podman authority the coordinator
# must never have — so importing coordinator-writable code here would hand the
# coordinator arbitrary execution as the execution identity and collapse the
# authority split the whole transition exists to create.
RUNTIME_LIBRARY_ROOT = "/usr/lib/kyri/python"


def _library():
    """The accepted worker implementation from the installed tree, or refuse.

    Imported rather than reimplemented, and imported from one place. The
    canonical root goes to the front of the search path so it wins against
    anything already there, and then the module is asked where it actually came
    from: a search path is a preference, and this needs a fact.

    Resolution from anywhere else — a stale entry, an inherited `PYTHONPATH`
    that should not exist, a directory that happened to be first — is refused
    rather than used. Ambiguity here is indistinguishable from substitution.
    """
    # Checked before the import, not after. A search that falls through to
    # somebody else's tree has already executed that tree's module-level code
    # by the time anything downstream could object, so the refusal has to come
    # first: if the canonical root does not hold the module, there is nothing
    # to import and no search to run.
    expected = os.path.join(RUNTIME_LIBRARY_ROOT, "tools", "capability",
                            "execution", "worker.py")
    if not os.path.isdir(RUNTIME_LIBRARY_ROOT) or not os.path.isfile(expected):
        raise SystemExit(
            f"the governed worker library is not installed at {expected}")

    if RUNTIME_LIBRARY_ROOT not in sys.path:
        sys.path.insert(0, RUNTIME_LIBRARY_ROOT)

    try:
        from tools.capability.execution import worker
    except ImportError as error:
        raise SystemExit(
            f"the governed worker library is not importable from "
            f"{RUNTIME_LIBRARY_ROOT}: {error}") from None

    resolved = getattr(worker, "__file__", None)
    if not resolved or not os.path.realpath(resolved).startswith(
            os.path.realpath(RUNTIME_LIBRARY_ROOT) + os.sep):
        raise SystemExit(
            f"the worker library resolved outside {RUNTIME_LIBRARY_ROOT} "
            f"({resolved}); refusing rather than executing it")
    return worker


def _backend_module():
    """The governed runtime backend from the installed tree, or refuse.

    Resolved exactly the way the worker library is, and for the same reason: a
    backend that arrived from a stale path entry or an inherited `PYTHONPATH`
    would be a different program holding this identity's Podman authority.

    This is the one import in Kyri that reaches a module which starts a
    process. It is here rather than inside `tools/capability/` because that
    package is asserted to reach no subprocess at all, and because the adapter
    takes its backend by injection precisely so the choice is made at the
    boundary rather than buried in the library.
    """
    expected = os.path.join(RUNTIME_LIBRARY_ROOT, "kyri_exec_podman.py")
    if not os.path.isfile(expected):
        raise SystemExit(
            f"the governed runtime backend is not installed at {expected}")
    if RUNTIME_LIBRARY_ROOT not in sys.path:
        sys.path.insert(0, RUNTIME_LIBRARY_ROOT)
    try:
        import kyri_exec_podman
    except ImportError as error:
        raise SystemExit(
            f"the governed runtime backend is not importable from "
            f"{RUNTIME_LIBRARY_ROOT}: {error}") from None
    resolved = getattr(kyri_exec_podman, "__file__", None)
    if not resolved or not os.path.realpath(resolved).startswith(
            os.path.realpath(RUNTIME_LIBRARY_ROOT) + os.sep):
        raise SystemExit(
            f"the runtime backend resolved outside {RUNTIME_LIBRARY_ROOT} "
            f"({resolved}); refusing rather than executing it")
    return kyri_exec_podman


def run_execution(worker, context, profile, *, backend_module, session, clock,
                  handoff_fd, snapshot_fd, images):
    """Everything after the profile is authenticated, in the one accepted order.

    Factored out of `main` so it can be exercised without being the execution
    identity, which `main` requires before it reaches here. That is a testing
    seam and not a widening: nothing calls this except `main`, every
    collaborator is passed in rather than discovered, and `main` performs the
    identity check first -- pinned structurally, because an ordering that is
    only true by reading is one refactor away from not being true.

    **The snapshot stands between the coordinator and the container.** The
    handoff is coordinator-owned, so the bind sources handed to Podman are the
    worker's own copy and never the published material: `create_argv` takes the
    snapshot binding and nothing else, so there is no path by which a
    coordinator-controlled source could be mounted.
    """
    # The gate. One path, in one order: identity binding, governed policy,
    # runtime contracts, image presence, then the payload and package
    # commitments. A refusal here means nothing was created.
    verified = worker.verify_execution(context, profile, root_fd=handoff_fd,
                                       images=images)

    # The worker-owned copy, and the only thing the container may see.
    from tools.capability.execution import snapshot as snapshot_module
    binding = snapshot_module.materialise(verified, handoff_fd=handoff_fd,
                                          snapshot_fd=snapshot_fd)

    # The backend is chosen by the *authenticated profile's* adapter identity,
    # through a closed registry. An identity with no implementation has no
    # backend rather than a default one.
    backend = backend_module.backend_for(profile.adapter_identity,
                                         environment=worker.ENVIRONMENT)

    from tools.capability.execution import adapter as adapter_module
    execution = adapter_module.ExecutionBinding(
        cinv=profile.cinv, profile=profile,
        argv=worker.create_argv(binding), environment=worker.ENVIRONMENT,
        output_fd=os.open(binding.output, _DIR_FLAGS))
    try:
        return adapter_module.PythonPodmanAdapter(
            backend=backend, session=session, clock=clock).execute(execution)
    finally:
        os.close(execution.output_fd)


def main(argv: list[str]) -> int:
    """Validate the invocation, confirm the identity, and execute.

    Order matters, and it is the same order as before with one step added at
    the end. The argument shape is checked before anything is derived from it,
    the identity is confirmed before any work is attempted, the profile is
    authenticated before anything could be built from it, and only then is a
    container created.

    **Nothing here runs before the transition has permanently dropped
    privilege.** By the time this process exists the transition has already set
    the credentials and `no_new_privs` and exec'd; there is no privileged step
    left to perform and none is performed. The backend therefore starts Podman
    from a permanently unprivileged context by construction, not by convention.
    """
    if len(argv) != 4:
        raise SystemExit(USAGE)

    worker = _library()

    # The execution identity, confirmed by the library's own rule. Root is
    # refused there explicitly: a worker running as root would drive rootless
    # Podman into a different storage tree entirely.
    try:
        worker.require_worker_identity(uid=os.getuid(), gid=os.getgid())
    except worker.WorkerRefused as error:
        raise SystemExit(f"refused: {error}") from None

    # Validated through the library's grammar rather than a local copy of it.
    try:
        context = worker.require_launch_context(
            cinv=argv[1], cimp=argv[2], profile_digest=argv[3])
    except worker.WorkerRefused as error:
        raise SystemExit(f"{USAGE}\nrefused: {error}") from None

    # The sealed object the transition authored, and the only place the
    # governed profile may come from.
    try:
        profile = worker.profile_from_descriptor(
            context, descriptor=worker.PROFILE_FD)
    except worker.WorkerRefused as error:
        raise SystemExit(f"refused: {error}") from None

    from tools.capability.execution import image_store, protocol, snapshot

    handoff_fd = os.open(worker.HANDOFF_ROOT, _DIR_FLAGS)
    try:
        snapshot_fd = snapshot.open_snapshot_root()
        try:
            outcome = run_execution(
                worker, context, profile,
                backend_module=_backend_module(),
                session=protocol.Session(_frames()),
                clock=time.monotonic,
                handoff_fd=handoff_fd, snapshot_fd=snapshot_fd,
                images=image_store.RootlessImageStore())
        finally:
            os.close(snapshot_fd)
    finally:
        os.close(handoff_fd)

    # The exit status carries whether a *result* was admitted, never merely
    # whether this process finished. A capability that failed, timed out, or
    # produced nothing collectable exits non-zero, so a parent cannot mistake
    # "the worker exited" for "the capability succeeded"; the richer
    # classification travels in the evidence, not in eight bits.
    return 0 if outcome.succeeded else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
