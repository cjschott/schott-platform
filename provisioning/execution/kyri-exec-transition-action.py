"""Privileged action layer for the ENG-0005 execution-transition helper.

**This file is source, not an installed helper.** Installation is gate G2 and
the first real transition is gate G6; both are closed. Nothing here runs during
the test suite: every privileged operation goes through an injected backend, so
the sequence is proven without a process ever changing its credentials.

**It decides nothing.** The policy module already decided which invocation is
admissible, which identity to become, which executable to run, and with what
environment. This layer consumes that immutable decision and performs it. It
accepts no `CINV`, no uid, no executable, no environment, and no path of its
own — there is no parameter through which a second opinion could enter.

**Order is the security property, not a style.** ``setgroups`` must precede
``setgid``, which must precede ``setuid``, because each step spends privilege
the next one needs. Verification then follows the drop, because a drop that
did not take is worse than one that never happened: the process would carry
privilege while believing it had none. ``no_new_privs`` comes after the drop
deliberately — it needs no root, so there is no reason to exercise FFI while
uid 0 is still held.

**Failure short-circuits, always toward not running.** Any step that fails
prevents every later step and, above all, prevents ``execve``. A partially
dropped process that execs is the one outcome worse than refusing.

**The FFI exception is two calls wide.** Python exposes no binding for
``PR_SET_NO_NEW_PRIVS``, so ``ctypes`` reaches libc for exactly
``prctl(38, 1, 0, 0, 0)`` and ``prctl(39, 0, 0, 0, 0)`` — fixed constants,
fixed arguments, the current process rather than a named library, one symbol,
and no reusable wrapper. Calling the setter and assuming it worked is not
setting it, so the getter must read back ``1``.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §6.
"""

from __future__ import annotations

import ctypes
import dataclasses
import os
import sys
from typing import Any, NoReturn, Sequence

PR_SET_NO_NEW_PRIVS = 38
PR_GET_NO_NEW_PRIVS = 39

# One binding, to the current process rather than a named library path. There
# is nothing here for a caller to influence and no second symbol to reach.
_LIBC = ctypes.CDLL(None, use_errno=True)


class WorkerExecuted(BaseException):
    """Raised by a test backend in place of an exec that never returns.

    Derives from ``BaseException`` so an ordinary ``except Exception`` in the
    transition path cannot swallow it and continue past the point of no return.
    """


@dataclasses.dataclass(frozen=True)
class Credentials:
    """Observed process credentials, in full.

    Real, effective, and saved are all carried because checking only the
    effective ones would miss a saved-uid that permits regaining privilege.
    """

    ruid: int
    euid: int
    suid: int
    rgid: int
    egid: int
    sgid: int
    groups: tuple[int, ...]

    def privileged(self) -> bool:
        return 0 in (self.ruid, self.euid, self.suid,
                     self.rgid, self.egid, self.sgid) or 0 in self.groups


class SystemBackend:
    """The production backend, bound to real primitives.

    Never exercised by the test suite: the tests inject a recorder instead, so
    no test can change this process's credentials even by accident.
    """

    def close_extra_descriptors(self, allowlist: Sequence[int]) -> None:
        keep = set(allowlist)
        for descriptor in keep:
            os.set_inheritable(descriptor, True)
        highest = max(keep) if keep else 2
        os.closerange(highest + 1, 4096)

    def setgroups(self, groups: Sequence[int]) -> None:
        os.setgroups(list(groups))

    def setgid(self, gid: int) -> None:
        os.setgid(gid)

    def setuid(self, uid: int) -> None:
        os.setuid(uid)

    def credentials(self) -> Credentials:
        ruid, euid, suid = os.getresuid()
        rgid, egid, sgid = os.getresgid()
        return Credentials(ruid, euid, suid, rgid, egid, sgid,
                           tuple(os.getgroups()))

    def set_no_new_privs(self) -> None:
        if _LIBC.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "PR_SET_NO_NEW_PRIVS failed")

    def get_no_new_privs(self) -> int:
        return _LIBC.prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0)

    def execve(self, path: str, argv: Sequence[str],
               environment: Sequence[tuple[str, str]]) -> NoReturn:
        os.execve(path, list(argv), dict(environment))
        raise OSError("execve returned")


def _policy() -> Any:
    """The policy module, however it was loaded.

    An installed helper and the test fixture load it under different names, so
    it is looked up rather than imported by a path that only one of them has.
    """
    for name in ("kyri_exec_transition", "kyri-exec-transition"):
        module = sys.modules.get(name)
        if module is not None:
            return module
    raise RuntimeError("the transition policy module is not loaded")


def ambiguous(reason: str) -> Exception:
    """A refusal whose execution outcome cannot be excluded.

    Built rather than subclassed so there is exactly one refusal type and one
    place that decides when `transition_failed_before_execution` applies. That
    classification asserts nothing ran; this is precisely the case where nobody
    can assert it, so the flag withholds it and reconciliation takes over.
    """
    return _policy().TransitionRefused(reason, execution_excluded=False)


def perform_transition(policy: Any, *, backend: Any, quota: Any,
                       assume_root: bool) -> NoReturn:
    """Perform the accepted credential drop and exec, or refuse.

    ``assume_root`` is what a caller asserts about holding privilege; the
    production entry point derives it from the observed credentials rather than
    from anything a caller said.

    ``quota`` is required rather than optional, and that is the point: there is
    no signature here that reaches ``execve`` without an established output
    project, so an unquotaed execution is not a path somebody could forget to
    take — it does not exist.
    """
    module = _policy()
    refused = module.TransitionRefused

    if not isinstance(policy, module.TransitionPolicy):
        raise refused("a validated TransitionPolicy is required")
    if not assume_root:
        raise refused("the transition requires root and does not hold it")

    # Before any privilege is spent, and before the worker could exist. Every
    # failure below is conclusive: nothing has run, so the refusal keeps its
    # default `execution_excluded`, which is what makes
    # `transition_failed_before_execution` honest here.
    #
    # There is no fallback to unquotaed execution. A quota failure costs
    # availability; the alternative would be a container writing into a tree
    # nothing is accounting, which costs the containment this whole boundary
    # exists for.
    try:
        established = quota.apply(policy.cinv)
        expected = quota.project_id(policy.cinv)
    except Exception as error:  # noqa: BLE001 — any failure is a refusal
        raise refused(f"the output quota was not established: {error}") from None
    if not isinstance(established, int) or isinstance(established, bool):
        raise refused("the output quota reported no project identity")
    if established != expected:
        raise refused(
            f"the output quota established project {established}, and "
            f"{policy.cinv} derives {expected}")

    try:
        backend.close_extra_descriptors(policy.inherited_descriptors)
        backend.setgroups((policy.worker_gid,))
        backend.setgid(policy.worker_gid)
        backend.setuid(policy.worker_uid)
    except OSError as error:
        raise refused(f"the credential drop failed: {error}") from None

    after = backend.credentials()
    if after.privileged():
        raise refused("privilege survived the drop")
    if (after.ruid, after.euid, after.suid) != (policy.worker_uid,) * 3:
        raise refused("the uid drop is not complete in every component")
    if (after.rgid, after.egid, after.sgid) != (policy.worker_gid,) * 3:
        raise refused("the gid drop is not complete in every component")
    if tuple(after.groups) != (policy.worker_gid,):
        raise refused("the supplementary group set is not the expected one")

    try:
        backend.set_no_new_privs()
        observed = backend.get_no_new_privs()
    except OSError as error:
        raise refused(f"no_new_privs failed: {error}") from None
    if observed != 1:
        raise refused("no_new_privs did not read back as set")

    final = backend.credentials()
    if final.privileged() or final != after:
        raise refused("credentials changed after verification")

    try:
        backend.execve(policy.worker_interpreter, policy.worker_argv,
                       policy.environment)
    except OSError as error:
        # The syscall conclusively failed, so nothing ran. There is no second
        # attempt, no alternate interpreter, and no fallback.
        raise refused(f"execve failed: {error}") from None
    raise refused("execve returned without executing")
