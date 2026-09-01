#!/usr/bin/python3
"""The unprivileged half of reconciliation. **Not installed by anything here.**

This file becomes `/usr/libexec/kyri-exec-reconcile-worker.py`, owned
`root:root`, mode `0444`. It is named as the terminal target of
`/usr/libexec/kyri-exec-reconcile` and is never executed directly by an
operator: by the time it exists, the entrypoint has permanently dropped
credentials and set `no_new_privs`, so this process holds the execution
identity's Podman authority and nothing else.

**It confirms the drop from the far side of `execve`.** The entrypoint verified
the credentials it had just set; this reads the deployment authority again and
requires the identity it now holds to be the one the deployment authorised. Two
independent reads of the same root-owned record, either of which failing stops
the operation -- rather than one side trusting what the other said.

**Nothing here reaches the Capability Runtime store.** Reconciliation stops a
container; it concludes nothing about how far the workload got, writes no result
and never touches an invocation record. An invocation whose supervision was lost
stays interrupted, which is the honest reading.

**The whole reconciliation path is helper-ceremony authority.** The four modules
this reaches -- the reconciler, the Podman backend, the transition policy and
its action -- are all installed by the privileged helper ceremony. Nothing here
imports `tools.capability`, so a host that has not yet taken a Generation can
still recover an orphaned container, which is exactly when recovery matters
most.

Intended installed ownership and mode: ``root:root``, ``0444``.
"""

from __future__ import annotations

import json
import os
import sys

HELPER_PATH = "/usr/libexec/kyri-exec-reconcile-worker.py"
RUNTIME_LIBRARY_ROOT = "/usr/lib/kyri/python"

POLICY_MODULE = "kyri_exec_transition"
ACTION_MODULE = "kyri_exec_transition_action"
RECONCILE_MODULE = "kyri_exec_reconcile"
BACKEND_MODULE = "kyri_exec_podman"

# The adapter whose backend governs execution containers. A literal, because
# reconciliation acts on containers this platform created and there is exactly
# one runtime that creates them.
ADAPTER_IDENTITY = "python-podman-v1"

USAGE = f"usage: {HELPER_PATH} CINV-nnnnnn"


def _installed(name: str):
    """One internal module from the canonical root, or refuse.

    Resolved exactly the way the production worker resolves its library, and
    for the same reason: a module that arrived from a stale path entry or an
    inherited `PYTHONPATH` would be a different program holding this identity's
    Podman authority.
    """
    expected = os.path.join(RUNTIME_LIBRARY_ROOT, name + ".py")
    if not os.path.isfile(expected):
        raise SystemExit(f"{name} is not installed at {expected}")

    if RUNTIME_LIBRARY_ROOT not in sys.path:
        sys.path.insert(0, RUNTIME_LIBRARY_ROOT)

    try:
        module = __import__(name)
    except ImportError as error:
        raise SystemExit(
            f"{name} is not importable from {RUNTIME_LIBRARY_ROOT}: "
            f"{error}") from None

    resolved = getattr(module, "__file__", None)
    if not resolved or not os.path.realpath(resolved).startswith(
            os.path.realpath(RUNTIME_LIBRARY_ROOT) + os.sep):
        raise SystemExit(
            f"{name} resolved outside {RUNTIME_LIBRARY_ROOT} ({resolved}); "
            "refusing rather than executing it")
    return module


def main(argv: list[str]) -> int:
    """Confirm the identity, reconcile one container, and report.

    The `CINV` is revalidated through the reconciler's own grammar rather than
    trusted because the entrypoint already checked it. The two checks are not
    redundant: they are the two sides of a privilege boundary, and the rule
    everywhere else in this boundary is that each side validates what it acts
    on.
    """
    if len(argv) != 2:
        raise SystemExit(USAGE)

    policy_module = _installed(POLICY_MODULE)
    action = _installed(ACTION_MODULE)
    reconciler = _installed(RECONCILE_MODULE)
    runtime = _installed(BACKEND_MODULE)

    # Root is refused before anything else. A reconciliation running as root
    # would drive rootless Podman into an entirely different storage tree, and
    # the container it failed to find would still be running.
    uid, gid = os.getuid(), os.getgid()
    if uid == 0 or gid == 0:
        raise SystemExit("refused: reconciliation must never run as root")

    try:
        identity = action.execution_identity(backend=action.SystemBackend())
        if (uid, gid) != (identity.uid, identity.gid):
            raise policy_module.TransitionRefused(
                f"reconciliation must run as {identity.uid}:{identity.gid}, "
                f"not {uid}:{gid}")
        environment = policy_module.execution_environment(identity)
    except policy_module.TransitionRefused as error:
        raise SystemExit(f"refused: {error}") from None

    try:
        backend = runtime.backend_for(ADAPTER_IDENTITY, environment=environment)
        report = reconciler.reconcile(argv[1], backend=backend)
    except (reconciler.ReconciliationRefused,
            runtime.PodmanBackendRefused) as error:
        raise SystemExit(f"refused: {error}") from None

    # The closed structured report, on one line. A reader acts on `final_absent`
    # and nothing else needs parsing out of Podman's own output, because none of
    # Podman's own output reaches here.
    sys.stdout.write(json.dumps(report, sort_keys=True, separators=(",", ":"))
                     + "\n")
    sys.stdout.flush()
    return 0 if report["final_absent"] else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
