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
            "CINV-nnnnnn"),
           CLOSED_ENVIRONMENT)

**It delegates and decides nothing.** Every rule about what a container may be
lives in `tools/capability/execution/worker.py` — the argv, the profile, the
mounts, the fixed container environment — and none of it is restated here. A
second copy of a Podman contract is one more than can be kept correct, and this
file exists to be an entrypoint rather than a policy.

**One argument, and it is revalidated here.** The sudoers policy already
constrains `^CINV-[0-9]{6}$` and the helper checks it again; this checks it a
third time, through the library's own grammar, because a validator that only
runs somewhere else is one syntax error away from not running at all.

**It holds no privilege and takes none.** By the time this runs the transition
has already dropped to `kyri-capability` and set `no_new_privs`. There is no
credential change here, no quota administration, no trust decision, and no
authority that a caller could aim: the only input is one `CINV`, and the
protocol arrives on the inherited descriptors 0, 1, and 2.

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

USAGE = "usage: /usr/bin/python3 /usr/libexec/kyri-exec-worker.py CINV-nnnnnn"


def _library():
    """The accepted worker implementation, or a refusal.

    Imported rather than reimplemented. The import is attempted against the
    interpreter's own search path and **nothing is added to it here**: the
    worker environment is closed and carries no `PYTHONPATH`, and a path
    compiled in at this point would decide, without review, which tree the
    execution identity loads its code from. Where that tree lives is a
    provisioning question — see `README.md` — and until it is answered this
    refuses instead of guessing.
    """
    try:
        from tools.capability.execution import worker
    except ImportError as error:
        raise SystemExit(
            f"the governed worker library is not importable: {error}") from None
    return worker


def main(argv: list[str]) -> int:
    """Validate the invocation, confirm the identity, and hand off.

    Order matters. The argument shape is checked before anything is derived
    from it, the identity is confirmed before any work is attempted, and the
    absence of a bound runtime is a refusal rather than a silent no-op.
    """
    if len(argv) != 2:
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
    # The derived name is discarded: what is wanted here is the refusal.
    try:
        worker.container_name(argv[1])
    except worker.WorkerRefused as error:
        raise SystemExit(f"{USAGE}\nrefused: {error}") from None

    # Everything above is the entrypoint's whole contribution. Binding a real
    # process to /usr/bin/podman is gate G6, and until it opens there is
    # nothing here that could honestly proceed.
    raise SystemExit(
        "kyri-exec-worker: no governed runtime backend is bound; "
        "container execution is gated at G6")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
