#!/usr/bin/python3
"""The one privileged public entrypoint. **Not installed by anything here.**

This file becomes `/usr/libexec/kyri-exec-transition`, owned `root:root` and
executable. Installing it is gate G2; granting sudo over it is G3.

**One command, one argument.** The whole public interface is

    /usr/libexec/kyri-exec-transition CINV-nnnnnn

and nothing else. There is no option parser, because an option parser is a
place for flags to be added later, and no second privileged command: the policy
and the action are **internal library components** installed beneath the
canonical root, not separately authorised executables. A sudoers rule over this
path therefore grants exactly one operation, and cannot be made to reach the
interpreter, a module name, the quota component, a shell, Podman, or
`xfs_quota`.

**Nothing about where the implementation lives comes from the caller.** Not the
library root, not the module names, not the interpreter, not the action. All of
them are literals below. The argument is one `CINV`, and it is validated by the
policy module's own grammar rather than a copy of it here.

**The library root is the installed tree, never the checkout.** The repository
is source material; the installed copy is the runtime authority. Importing
coordinator-writable code from a root process is the one mistake this file
exists to make impossible.

**Root is observed, never asserted.** Whether privilege is held is read from
the process, not taken from anything a caller said.

Governed by ``docs/superpowers/specs/2026-08-11-execution-transition-boundary.md``
§3.2 and §3.3.

Intended installed ownership and mode: ``root:root``, ``0555``.
"""

from __future__ import annotations

import os
import sys

HELPER_PATH = "/usr/libexec/kyri-exec-transition"

# Compiled in, exactly as in the worker entrypoint and for the same reason.
RUNTIME_LIBRARY_ROOT = "/usr/lib/kyri/python"

# Internal library components. Module names are literals: a name taken from the
# caller would turn one authorised command into an arbitrary module loader.
POLICY_MODULE = "kyri_exec_transition"
ACTION_MODULE = "kyri_exec_transition_action"
QUOTA_MODULE = "kyri_exec_quota"

USAGE = f"usage: {HELPER_PATH} CINV-nnnnnn"


def _installed(name: str):
    """One internal module from the canonical root, or refuse.

    The root goes to the front of the search path and the module is then asked
    where it came from, because a search path expresses a preference and this
    needs a fact. Anything that resolved elsewhere is refused.
    """
    # Checked before the import. A search that falls through to another tree
    # has already run that tree's module-level code before anything could
    # object, so absence is refused rather than searched around.
    expected = os.path.join(RUNTIME_LIBRARY_ROOT, name + ".py")
    if not os.path.isdir(RUNTIME_LIBRARY_ROOT) or not os.path.isfile(expected):
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
    """Validate, load the installed implementation, and hand over.

    The argument shape is checked before anything is loaded, so a malformed
    invocation never reaches an import. Everything after that belongs to the
    accepted transition: it validates the deployment's execution identity,
    establishes the output quota, drops credentials, sets `no_new_privs`, and
    execs the worker, in that order, and this file adds no step to that sequence
    and removes none.

    **The identity is read before the policy is built, and there is no order in
    which it could be skipped.** `policy_for` requires it, so a transition
    policy without an approved execution identity is not something this file
    could construct by forgetting a line.
    """
    if len(argv) != 2:
        raise SystemExit(USAGE)

    policy_module = _installed(POLICY_MODULE)
    action = _installed(ACTION_MODULE)
    quota = _installed(QUOTA_MODULE)

    backend = action.SystemBackend()

    try:
        identity = action.execution_identity(backend=backend)
        policy = policy_module.policy_for(argv, identity=identity)
        # Authorisation is read and checked before the transition is asked to
        # do anything, and what comes back is a closed type only the policy
        # layer can build. The `CIMP` and profile digest the worker is told to
        # trust come from here and from nowhere a caller can reach.
        launch = action.authenticate_launch(policy, backend=backend)
    except policy_module.TransitionRefused as error:
        raise SystemExit(f"refused: {error}") from None

    action.perform_transition(
        policy,
        launch_authorisation=launch,
        backend=backend,
        quota=quota,
        # Observed, not asserted. A caller saying it holds root is not
        # evidence, and the action refuses without it.
        assume_root=os.geteuid() == 0,
    )
    # perform_transition never returns: it execs the worker or refuses.
    raise SystemExit("the transition returned without executing")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
