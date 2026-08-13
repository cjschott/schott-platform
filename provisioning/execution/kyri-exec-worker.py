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

**It fails closed.** Driving a real container needs a Podman backend bound to
`/usr/bin/podman`, which is gate G6 and does not exist yet. Until it does, this
refuses rather than pretending: the identity is confirmed, the identity of the
work is confirmed, and then it stops.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §7,
§17, and the execution transition boundary §8.

Intended installed ownership and mode: ``root:root``, ``0444``.
"""

from __future__ import annotations

import os
import sys

USAGE = ("usage: /usr/bin/python3 /usr/libexec/kyri-exec-worker.py "
         "CINV-nnnnnn CIMP-nnnnnn <64-hex profile_digest>")

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


def main(argv: list[str]) -> int:
    """Validate the invocation, confirm the identity, and hand off.

    Order matters. The argument shape is checked before anything is derived
    from it, the identity is confirmed before any work is attempted, the
    profile is authenticated before anything could be built from it, and the
    absence of a bound runtime is a refusal rather than a silent no-op.
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
    # governed profile may come from. The verified result is discarded here:
    # this entrypoint delegates, and what is wanted at this point is the
    # refusal, not the profile.
    try:
        worker.profile_from_descriptor(context, descriptor=worker.PROFILE_FD)
    except worker.WorkerRefused as error:
        raise SystemExit(f"refused: {error}") from None

    # Everything above is the entrypoint's whole contribution. Binding a real
    # process to /usr/bin/podman is gate G6, and until it opens there is
    # nothing here that could honestly proceed.
    raise SystemExit(
        "kyri-exec-worker: no governed runtime backend is bound; "
        "container execution is gated at G6")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
