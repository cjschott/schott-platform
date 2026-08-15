#!/usr/bin/python3
"""The G6.1 privileged verification entrypoint. **Not installed by anything here.**

This file becomes `/usr/libexec/kyri-exec-verify`, owned `root:root` and
executable. Installing it, and granting sudo over it, is the G6.1 ceremony and
is closed until an operator review authorises it.

**One command, one argument.** The whole public interface is

    /usr/libexec/kyri-exec-verify CINV-nnnnnn

and nothing else — no option parser, no mode, no target, no environment
variable. It is the production entrypoint's interface exactly, because it is
the production transition exactly; what differs is which governed policy module
is compiled in below, and therefore which worker the transition ends at.

**The selection is the path, not a flag.** `POLICY_MODULE` is a literal in this
file, the policy module it names compiles in one worker target, and nothing on
the command line contributes to either. So the authority granted over *this*
path cannot be turned into the authority granted over the production path: not
by an argument, not by an environment variable, not by a working directory, and
not by a `PATH` search, because there is none. A caller who can run this can run
verification, and a caller who can run verification still cannot execute a
container.

**Everything privileged is the production code.** The action layer resolves its
policy module by name, finds `kyri_exec_transition` — which the verification
policy imports — and performs the production sequence: establish the output
quota, authenticate the launch record, authenticate and seal the profile, place
descriptor 3, close every other descriptor, drop `setgroups`/`setgid`/`setuid`,
verify the drop, set and read back `no_new_privs`, and `execve`. Not a subset,
not a copy, and not a version with a step relaxed. The single value this
entrypoint changes is `policy.worker_script`.

**It cannot reach container execution.** The worker it execs is the
verification worker, which imports no snapshot materialisation, binds no
`create_argv`, and has no terminal action but a JSON record on stdout. Reaching
the production worker from here would require a different policy module, which
would require a different literal in this file, which would require a different
installed artifact and therefore a different sudoers digest.

**Root is observed, never asserted.** Whether privilege is held is read from
the process, not taken from anything a caller said.

Governed by ``docs/superpowers/specs/2026-08-11-execution-transition-boundary.md``
§3.2 and §3.3, and the G6.1 milestone.

Intended installed ownership and mode: ``root:root``, ``0555``.
"""

from __future__ import annotations

import os
import sys

HELPER_PATH = "/usr/libexec/kyri-exec-verify"

# Compiled in, exactly as in the production entrypoint and for the same reason:
# every other way of arriving at the library root is something an attacker or an
# accident can influence.
RUNTIME_LIBRARY_ROOT = "/usr/lib/kyri/python"

# Internal library components. The policy module is the one line that makes this
# the verification boundary rather than the production one; the action and quota
# modules are the production ones, unmodified, because the transition being
# proven is the production transition.
POLICY_MODULE = "kyri_exec_verify"
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
    accepted transition, and this file adds no step to that sequence and removes
    none.

    The policy is checked for the one property that makes this entrypoint what
    it claims to be: that it names the verification worker. A policy module that
    resolved to the production target would mean this privileged path had become
    the production path, which is the one outcome the G6.1 boundary exists to
    prevent — so it is refused here, before any privilege is spent, rather than
    trusted because the right module name was compiled in.
    """
    if len(argv) != 2:
        raise SystemExit(USAGE)

    policy_module = _installed(POLICY_MODULE)
    action = _installed(ACTION_MODULE)
    quota = _installed(QUOTA_MODULE)

    backend = action.SystemBackend()

    try:
        policy = policy_module.policy_for(argv)
        if policy.worker_script != policy_module.WORKER_SCRIPT:
            raise policy_module.TransitionRefused(
                f"the verification transition executes "
                f"{policy_module.WORKER_SCRIPT} and nothing else")
        if policy.worker_script == policy_module.PRODUCTION_WORKER_SCRIPT:
            raise policy_module.TransitionRefused(
                "the verification transition may not name the production worker")
        # Authorisation is read and checked before the transition is asked to
        # do anything, and what comes back is a closed type only the policy
        # layer can build.
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
    # perform_transition never returns: it execs the verification worker or
    # refuses.
    raise SystemExit("the transition returned without executing")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
