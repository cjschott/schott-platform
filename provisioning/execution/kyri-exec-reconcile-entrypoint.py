#!/usr/bin/python3
"""The privileged reconciliation entrypoint. **Not installed by anything here.**

This file becomes `/usr/libexec/kyri-exec-reconcile`, owned `root:root` and
executable. Installing it is part of the privileged helper ceremony; granting
sudo over it is a separate authority from the launch grant and is withdrawable
on its own.

**One command, one argument.** The whole public interface is

    /usr/libexec/kyri-exec-reconcile CINV-nnnnnn

and nothing else. No container name, no uid, no image, no flag. A sudoers rule
over this path grants exactly one operation on exactly one invocation's
container, and cannot be made to reach Podman, a shell, an image, or another
invocation.

**Why a second entrypoint rather than a subcommand.** The launch entrypoint
takes two argv elements and says why: "there is no option parser here on
purpose: an option parser is a place for flags to be added later." A `reconcile`
subcommand would introduce exactly that, and would bundle two capabilities into
one grant. Two entrypoints, two digests, two rules -- the authority to reconcile
is simply not the authority to launch, and that is a property of which paths
exist rather than of a check somebody remembered to write.

**G11-AR could not write this file, and the reason was the identity.** The whole
job of a privileged entrypoint is to become the execution principal, and the
only way to learn which identity that was would have been to read two constants
compiled into the source -- reproducing, inside a new privileged binary, exactly
the defect G11-AH removed from the launch helper. The deployment now states it:
`/etc/kyri/execution-identity.json`, root-owned, provisioned and never
generated, with nothing to fall back to when it is absent.

**Podman is unreachable from this process.** Neither this file nor the action
module it calls imports the runtime backend or the reconciliation module. Both
are reached only by the worker on the far side of `execve`, which happens after
the credential drop. Reconciliation running as root is therefore not a mistake
this code can make; there is no route by which it could.

**Root is observed, never asserted.** Whether privilege is held is read from the
process, not taken from anything a caller said.

Intended installed ownership and mode: ``root:root``, ``0555``.
"""

from __future__ import annotations

import os
import sys

HELPER_PATH = "/usr/libexec/kyri-exec-reconcile"

# Compiled in, exactly as in the launch entrypoint and for the same reason.
RUNTIME_LIBRARY_ROOT = "/usr/lib/kyri/python"

# Internal library components. Module names are literals: a name taken from the
# caller would turn one authorised command into an arbitrary module loader.
#
# The policy and action modules are the launch transition's, deliberately. The
# `CINV` grammar, the execution identity parser, the descriptor closure and the
# credential drop are the same code the launch path runs -- a second copy of any
# of them would be a second thing to keep correct and a first thing to get
# wrong.
POLICY_MODULE = "kyri_exec_transition"
ACTION_MODULE = "kyri_exec_transition_action"

USAGE = f"usage: {HELPER_PATH} CINV-nnnnnn"


def _installed(name: str):
    """One internal module from the canonical root, or refuse.

    The root goes to the front of the search path and the module is then asked
    where it came from, because a search path expresses a preference and this
    needs a fact. Anything that resolved elsewhere is refused.
    """
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

    The order is the launch order with the steps reconciliation does not need
    removed, and none added: the argument shape, the deployment's execution
    identity, the policy, then the descriptor closure, the credential drop,
    `no_new_privs`, and the exec.

    There is no quota and no launch record here. Reconciliation writes no
    output, so there is nothing to account; and nothing about a container's
    existence is authorised by a coordinator record -- the container is already
    there, or it is not.
    """
    if len(argv) != 2:
        raise SystemExit(USAGE)

    policy_module = _installed(POLICY_MODULE)
    action = _installed(ACTION_MODULE)

    backend = action.SystemBackend()

    try:
        identity = action.execution_identity(backend=backend)
        policy = policy_module.reconciliation_policy_for(argv,
                                                         identity=identity)
    except policy_module.TransitionRefused as error:
        raise SystemExit(f"refused: {error}") from None

    action.perform_reconciliation(
        policy,
        backend=backend,
        # Observed, not asserted. A caller saying it holds root is not
        # evidence, and the action refuses without it.
        assume_root=os.geteuid() == 0,
    )
    # perform_reconciliation never returns: it execs the worker or refuses.
    raise SystemExit("the reconciliation returned without executing")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
