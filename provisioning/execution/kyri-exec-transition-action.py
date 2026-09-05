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

**The profile is authenticated bytes and never anything more.** This layer
opens the coordinator's published profile, hashes exactly what it read, checks
that digest against the launch record it already authenticated, copies those
bytes into an object only root has ever written, and seals it. It does not
parse them. Root understanding one bounded record and nothing else is what
keeps §6's schema stop condition true, so there is no `ExecutionProfile` here,
no image identity, no mount, and no resource field — only a blob, a digest, and
a descriptor.

**The sealed copy is the authority; the published file stops being one.** The
coordinator owns the directory the profile lives in, so it can always restore
write access and replace what it published, and a descriptor pins an inode
rather than its contents — both models were tried and both were disproved.
What survives is `worker bytes == the exact bytes root authenticated`, and the
only way to hold that is to copy them somewhere nobody can reach.

**`FD_CLOEXEC` is cleared explicitly, never as a side effect.** If the memfd is
itself allocated as descriptor 3, `dup2(3, 3)` is a POSIX no-op that returns
success and leaves the flag set — the descriptor would close at `execve` and
the worker would receive nothing. Measured, and the reason for one otherwise
redundant-looking `fcntl`.

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
import fcntl
import hashlib
import os
import sys
from typing import Any, NoReturn, Sequence

PR_SET_NO_NEW_PRIVS = 38
PR_GET_NO_NEW_PRIVS = 39

# The anonymous object's name. It appears only in /proc and is not authority:
# the digest comparison is, and this ruling claims no more than that.
PROFILE_OBJECT_NAME = "kyri-exec-profile"

# O_NONBLOCK is load-bearing rather than an optimisation. Opening a FIFO for
# reading blocks until a writer arrives, so without it a coordinator could
# replace the profile with a named pipe and hang the privileged helper before
# it ever reached the check that would have refused. It has no effect on the
# regular file this is supposed to be.
_READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
_DIR_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY

# A governed root is opened as an anchor for `openat` and nothing else, so it
# asks for search rather than read. See `SystemBackend.open_directory`.
_ANCHOR_FLAGS = os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY
_CHUNK = 65536

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

    def open_directory(self, path: str) -> int:
        """One governed root, opened no-follow as a traversal anchor.

        The only filesystem seam in the backend, and it opens a *root* rather
        than a target: everything beneath it is reached descriptor-relatively
        by the code above, so a replaced component is refused rather than
        followed and the path is never walked a second time.

        **`O_PATH`, because an anchor is all this is.** Every caller uses the
        descriptor solely as `dir_fd` for an `openat`, and `openat` needs
        search on the directory, not read. Two of the three governed roots are
        `0711` by design -- `/etc/kyri` and `/data/kyri/capability-handoff`,
        both traverse-only so a non-owner may reach a named child without
        enumerating siblings -- so `O_RDONLY` asked for a permission the
        deployment deliberately withholds and refused whenever this ran after
        the credential drop. G11-BB hit that twice: in the worker against the
        handoff root, and here in the reconcile worker against `/etc/kyri`.

        An `O_PATH` descriptor also cannot be read at all, so "no sibling
        enumeration" stops depending on the mode and becomes a property of the
        descriptor. Nothing is widened: the roots keep their governed modes.
        """
        return os.open(path, _ANCHOR_FLAGS)

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


def _require_policy(policy: Any, module: Any) -> None:
    if not isinstance(policy, module.TransitionPolicy):
        raise module.TransitionRefused("a validated TransitionPolicy is required")


def _read_member(dir_fd: int, name: str, check: Any, maximum: int,
                 module: Any, *, expected_uid: int) -> bytes:
    """One governed file beneath ``dir_fd``, read exactly once.

    Opened relative to a descriptor with ``O_NOFOLLOW``, so no component can be
    swapped for a link between the check and the read, and closed before the
    bytes are used for anything.
    """
    refused = module.TransitionRefused
    try:
        handle = os.open(name, _READ_FLAGS, dir_fd=dir_fd)
    except OSError as error:
        raise refused(f"the governed {name} is unusable: {error}") from None
    try:
        check(os.fstat(handle), expected_uid=expected_uid)
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(handle, _CHUNK)
            if not chunk:
                break
            total += len(chunk)
            if total > maximum:
                raise refused(f"the governed {name} exceeds {maximum} bytes")
            chunks.append(chunk)
    except OSError as error:
        raise refused(f"the governed {name} could not be read: {error}") from None
    finally:
        os.close(handle)
    return b"".join(chunks)


def _read_authority(module: Any, *, backend: Any, path: str, label: str,
                    maximum: int) -> tuple[bytes, Any]:
    """One root-owned deployment authority's bytes and status, or refuse.

    Read through the same descriptor-relative seam everything else uses: the
    directory is opened no-follow and the file is opened relative to it, so no
    component can be swapped between the check and the read. No new backend
    primitive is introduced -- widening that seam to fetch one file would be a
    larger change to the privileged surface than the thing it fetches.

    The path is a compiled-in constant belonging to the policy module. There is
    no parameter here a caller could reach, which is what keeps "the authority
    is at one location" a property of the code rather than a convention.
    """
    refused = module.TransitionRefused
    directory, _, name = path.rpartition("/")
    try:
        root = backend.open_directory(directory)
    except OSError as error:
        raise refused(f"the {label} directory is unusable: {error}") from None
    try:
        try:
            handle = os.open(name, _READ_FLAGS, dir_fd=root)
        except OSError as error:
            raise refused(f"the {label} is unusable: {error}") from None
        try:
            info = os.fstat(handle)
            chunks: list[bytes] = []
            total = 0
            while True:
                chunk = os.read(handle, _CHUNK)
                if not chunk:
                    break
                total += len(chunk)
                if total > maximum:
                    raise refused(f"the {label} exceeds {maximum} bytes")
                chunks.append(chunk)
        except OSError as error:
            raise refused(f"the {label} could not be read: {error}") from None
        finally:
            os.close(handle)
    finally:
        os.close(root)
    return b"".join(chunks), info


def coordinator_authority(module: Any, *, backend: Any) -> Any:
    """The deployment's approved coordinator, read from provisioned authority.

    There is no cache and no default. Every privileged decision that needs the
    coordinator identity reads it, so a deployment that removes or damages the
    authority stops authorising transitions immediately rather than at the next
    restart.
    """
    data, info = _read_authority(
        module, backend=backend, path=module.COORDINATOR_AUTHORITY_PATH,
        label="coordinator authority",
        maximum=module.MAXIMUM_COORDINATOR_AUTHORITY_BYTES)
    return module.load_coordinator_authority(data, info)


def resolve_account(account: str) -> tuple[int, int]:
    """The kernel identity the account database gives ``account``, or refuse.

    It lives here rather than in the policy module because the policy module is
    the pure decision layer -- the T10 backstop forbids it `pwd` and `grp`, and
    that rule is correct: a decision that consults ambient system state is not
    one that can be proved without privilege.

    The coordinator authority deliberately does *not* do this. It treats the uid
    as authority and the name as documentation, because the fact it needs is
    `st_uid` on a descriptor it already holds and NSS would be a dependency it
    does not need. The execution identity is a different kind of thing: it is a
    target to become rather than a publisher to recognise, and the failure it
    must survive is an authority naming an account whose uid was later
    reassigned. Nothing but the account database can detect that.

    ``pwd`` is imported at the call rather than at module scope so the one place
    this boundary reaches NSS is visible where it happens.
    """
    import pwd

    module = _policy()
    try:
        entry = pwd.getpwnam(account)
    except KeyError:
        raise module.TransitionRefused(
            f"the account database does not know {account!r}") from None
    except OSError as error:
        raise module.TransitionRefused(
            f"the account database is unusable: {error}") from None
    return entry.pw_uid, entry.pw_gid


def execution_identity(*, backend: Any) -> Any:
    """The deployment's execution principal, read from provisioned authority.

    Read the same way and cached the same amount, which is not at all. The
    identity this returns is the one root permanently becomes, so a deployment
    that removes the authority must stop transitioning immediately rather than
    keep acting on a value read at some earlier time.

    The account is resolved through the policy module's own resolver, so the
    binding between the name and the numbers happens inside the parser that
    already refuses everything else -- not here, where it would be a second
    opinion the parser knew nothing about.

    The policy module is resolved rather than passed, for the reason
    `authenticate_launch` resolves it: the G6.1 verification policy is a thin
    derivation of the production one, and the identity authority must be the
    production module's regardless of which entrypoint is running. A `module`
    parameter would be a place for a governed variant to supply a different
    authority path.
    """
    module = _policy()
    data, info = _read_authority(
        module, backend=backend, path=module.EXECUTION_AUTHORITY_PATH,
        label="execution authority",
        maximum=module.MAXIMUM_EXECUTION_AUTHORITY_BYTES)
    return module.load_execution_identity(data, info, resolve=resolve_account)


def _open_invocation(root_fd: int, cinv: str, check: Any, module: Any, *,
                     expected_uid: int | None = None) -> int:
    """The per-invocation directory beneath a governed root, no-follow."""
    refused = module.TransitionRefused
    try:
        handle = os.open(cinv, _DIR_FLAGS, dir_fd=root_fd)
    except OSError as error:
        raise refused(
            f"the governed directory for {cinv} is unusable: {error}") from None
    try:
        if check is not None:
            check(os.fstat(handle), expected_uid=expected_uid)
    except BaseException:
        os.close(handle)
        raise
    return handle


def authenticate_launch(policy: Any, *, backend: Any) -> Any:
    """The authenticated launch record for ``policy``, or refuse.

    The record is the whole basis for `CIMP` and the profile digest, so it is
    read here — from a compiled-in root and the validated `CINV`, through
    descriptors — and handed to the policy layer to be checked. What comes back
    is a closed type the policy layer alone can build, which is what makes it
    impossible for a caller to reach the transition with values that never
    passed the check.
    """
    module = _policy()
    refused = module.TransitionRefused
    _require_policy(policy, module)
    approved = coordinator_authority(module, backend=backend)

    try:
        root = backend.open_directory(module.EXECUTION_ROOT)
    except OSError as error:
        raise refused(f"the execution root is unusable: {error}") from None
    try:
        invocation = _open_invocation(root, policy.cinv, None, module)
        try:
            data = _read_member(invocation, module.LAUNCH_RECORD_NAME,
                                module.check_evidence_object,
                                module.MAXIMUM_LAUNCH_RECORD_BYTES, module,
                                expected_uid=approved.coordinator_uid)
        finally:
            os.close(invocation)
    finally:
        os.close(root)

    return module.check_launch_authorisation(
        module.parse_launch_record(data), policy.cinv)


def authenticate_profile_source(policy: Any, launch: Any, *,
                                backend: Any) -> bytes:
    """The coordinator's published profile bytes, authenticated, or refuse.

    Returns bytes and only bytes. The digest is taken over exactly what was
    read from the descriptor that was checked — not over a second read, not
    over a reopened path — and compared with the digest the launch record
    already committed to. Nothing here interprets a single field of it.
    """
    module = _policy()
    refused = module.TransitionRefused
    _require_policy(policy, module)
    authorised = module.require_authenticated(launch, policy.cinv)
    approved = coordinator_authority(module, backend=backend)

    try:
        root = backend.open_directory(module.HANDOFF_ROOT)
    except OSError as error:
        raise refused(f"the handoff root is unusable: {error}") from None
    try:
        invocation = _open_invocation(root, authorised.cinv,
                                      module.check_handoff_object, module,
                                      expected_uid=approved.coordinator_uid)
        try:
            data = _read_member(invocation, module.PROFILE_NAME,
                                module.check_profile_object,
                                module.MAXIMUM_PROFILE_BYTES, module,
                                expected_uid=approved.coordinator_uid)
        finally:
            os.close(invocation)
    finally:
        os.close(root)

    if hashlib.sha256(data).hexdigest() != authorised.profile_digest:
        raise refused(
            "the published profile does not hash to the authorised digest")
    return data


def seal_profile_object(data: bytes, digest: str) -> int:
    """A sealed anonymous object holding exactly ``data``, or refuse.

    There is no fallback to a temporary file. A fallback would silently
    reinstate a model this design rejected, and a host that cannot provide the
    sealing contract is a host this transition refuses to run on.

    The copy is proved rather than assumed: a successful write count is not
    identity, so the object is rewound, read back, compared byte for byte, and
    hashed again before a single seal is applied.
    """
    module = _policy()
    refused = module.TransitionRefused
    if not isinstance(data, bytes) or not data:
        raise refused("the sealed copy requires the authenticated bytes")
    if hashlib.sha256(data).hexdigest() != digest:
        raise refused("the sealed copy was asked to commit to other bytes")

    try:
        handle = os.memfd_create(
            PROFILE_OBJECT_NAME, os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING)
    except (AttributeError, OSError) as error:
        raise refused(
            f"a sealable anonymous object is unavailable: {error}") from None

    try:
        written = 0
        while written < len(data):
            step = os.write(handle, data[written:])
            if step <= 0:
                raise refused("the sealed copy stopped before the end")
            written += step
        os.lseek(handle, 0, os.SEEK_SET)
        chunks: list[bytes] = []
        while True:
            chunk = os.read(handle, _CHUNK)
            if not chunk:
                break
            chunks.append(chunk)
        copied = b"".join(chunks)
        if copied != data:
            raise refused("the sealed copy does not read back as it was written")
        if hashlib.sha256(copied).hexdigest() != digest:
            raise refused("the sealed copy does not hash to the authorised digest")

        fcntl.fcntl(handle, fcntl.F_ADD_SEALS, module.REQUIRED_SEALS)
        seals = fcntl.fcntl(handle, fcntl.F_GET_SEALS)
        if seals & module.REQUIRED_SEALS != module.REQUIRED_SEALS:
            raise refused("the sealed copy does not carry the mandatory seals")
        os.lseek(handle, 0, os.SEEK_SET)
    except OSError as error:
        os.close(handle)
        raise refused(f"the sealed copy failed: {error}") from None
    except BaseException:
        os.close(handle)
        raise
    return handle


def place_profile_descriptor(handle: int) -> int:
    """Establish the sealed object as the governed descriptor, or refuse.

    Both placement cases are handled and neither is assumed: a caller sitting
    on the number is replaced atomically, and an object already allocated there
    is left alone — but the close-on-exec flag is cleared explicitly either
    way, because `dup2(3, 3)` succeeds without clearing it and the descriptor
    would then be closed by `execve`.
    """
    module = _policy()
    refused = module.TransitionRefused
    target = module.PROFILE_FD
    try:
        if handle != target:
            os.dup2(handle, target)
            # The redundant original goes now: a second handle to the same
            # object is one more descriptor than the worker should ever see.
            os.close(handle)
        fcntl.fcntl(target, fcntl.F_SETFD, 0)
        if fcntl.fcntl(target, fcntl.F_GETFD) & fcntl.FD_CLOEXEC:
            raise refused("the profile descriptor is still close-on-exec")
        if not os.get_inheritable(target):
            raise refused("the profile descriptor is not inheritable")
        os.lseek(target, 0, os.SEEK_SET)
    except OSError as error:
        raise refused(
            f"the profile descriptor could not be placed: {error}") from None
    return target


def verify_profile_descriptor(descriptor: int, digest: str) -> None:
    """Confirm the governed descriptor still holds the sealed bytes, or refuse.

    Run again after the descriptor cleanup, because the cleanup is the last
    thing that could plausibly have disturbed it, and a check that stops one
    step before the risk proves nothing about the step after.
    """
    module = _policy()
    refused = module.TransitionRefused
    try:
        seals = fcntl.fcntl(descriptor, fcntl.F_GET_SEALS)
    except OSError as error:
        raise refused(
            f"the profile descriptor is not a sealed object: {error}") from None
    if seals & module.REQUIRED_SEALS != module.REQUIRED_SEALS:
        raise refused("the profile descriptor lost its mandatory seals")
    try:
        info = os.fstat(descriptor)
        body = os.pread(descriptor, module.MAXIMUM_PROFILE_BYTES + 1, 0)
    except OSError as error:
        raise refused(f"the profile descriptor is unreadable: {error}") from None
    if len(body) != info.st_size:
        raise refused("the profile descriptor did not read back completely")
    if hashlib.sha256(body).hexdigest() != digest:
        raise refused("the profile descriptor does not hold the authorised bytes")


def drop_privilege(policy: Any, *, backend: Any) -> None:
    """Become the policy's identity, permanently and provably, or refuse.

    **Order is the security property.** ``setgroups`` before ``setgid`` before
    ``setuid``, because each step spends privilege the next one needs; and
    ``no_new_privs`` after the drop rather than before, because setting it while
    still root would be setting it on the wrong process.

    **The drop is verified in every component**, not just the effective one. A
    process that kept a saved uid can take privilege back, so a check of
    ``euid`` alone would report a drop that had not happened.

    Shared by the launch and reconciliation transitions on purpose. This is the
    security-critical sequence in the whole boundary, and a second copy of it
    would be a second thing to keep correct and a first thing to get wrong --
    the argument `kyri_exec_verify` already makes about the policy.

    The identity comes from ``policy``, which only a governed policy builder can
    produce and which only an approved execution authority can populate. There
    is no uid parameter here for a caller to supply.
    """
    module = _policy()
    refused = module.TransitionRefused

    try:
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


def perform_reconciliation(policy: Any, *, backend: Any,
                           assume_root: bool) -> NoReturn:
    """Close descriptors, drop permanently, and exec the reconcile worker.

    Deliberately shorter than `perform_transition`, and the omissions are the
    design. There is no quota, because reconciliation writes no output. There is
    no profile transport, because it authors nothing and reads no
    coordinator-published object. There is no launch record, because nothing
    about a container's existence is authorised by one -- the container is
    already there, or it is not.

    What is identical is the part that must be: the descriptor closure and the
    credential drop are the same code the launch transition runs, so the two
    privileged paths cannot come to disagree about what a complete drop is.

    **Podman is not reachable from here.** This module never imports the
    backend, and the reconcile worker that does is only reached through
    ``execve`` below -- which happens after the drop. Running the operation as
    root is therefore not a mistake this code can make; there is no route.
    """
    module = _policy()
    refused = module.TransitionRefused

    if not isinstance(policy, module.ReconciliationPolicy):
        raise refused("a validated ReconciliationPolicy is required")
    if not assume_root:
        raise refused("the reconciliation requires root and does not hold it")

    try:
        backend.close_extra_descriptors(policy.inherited_descriptors)
    except OSError as error:
        raise refused(f"the descriptor cleanup failed: {error}") from None

    drop_privilege(policy, backend=backend)

    try:
        backend.execve(policy.worker_interpreter,
                       (policy.worker_interpreter, policy.worker_script,
                        policy.cinv),
                       policy.environment)
    except OSError as error:
        raise refused(f"execve failed: {error}") from None
    raise refused("execve returned without executing")


def perform_transition(policy: Any, *, launch_authorisation: Any, backend: Any,
                       quota: Any, assume_root: bool) -> NoReturn:
    """Perform the accepted transport, credential drop, and exec, or refuse.

    ``assume_root`` is what a caller asserts about holding privilege; the
    production entry point derives it from the observed credentials rather than
    from anything a caller said.

    ``launch_authorisation`` must already be authenticated, and the type system
    is what says so: only ``check_launch_authorisation`` can produce one, so
    there is no route by which a caller-supplied `CIMP` or profile digest could
    arrive here having skipped the check. Both values then travel to the worker
    unchanged, in an argv this layer builds and the caller cannot reach.

    ``quota`` is required rather than optional, and that is the point: there is
    no signature here that reaches ``execve`` without an established output
    project, so an unquotaed execution is not a path somebody could forget to
    take — it does not exist.
    """
    module = _policy()
    refused = module.TransitionRefused

    _require_policy(policy, module)
    if not assume_root:
        raise refused("the transition requires root and does not hold it")
    launch = module.require_authenticated(launch_authorisation, policy.cinv)

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

    # The whole profile transport happens here, while privilege is still held
    # and before anything is closed: authenticate the coordinator's bytes,
    # copy them somewhere only this process has ever written, seal that, and
    # fix its descriptor number. After this the published file is no longer
    # authority for anything.
    authenticated = authenticate_profile_source(policy, launch, backend=backend)
    sealed = seal_profile_object(authenticated, launch.profile_digest)
    place_profile_descriptor(sealed)

    try:
        backend.close_extra_descriptors(policy.inherited_descriptors)
    except OSError as error:
        raise refused(f"the descriptor cleanup failed: {error}") from None

    # After the cleanup, because the cleanup is the last step that could have
    # disturbed it, and before any credential change, because a refusal here
    # must still be one that excludes execution.
    verify_profile_descriptor(policy.profile_fd, launch.profile_digest)

    drop_privilege(policy, backend=backend)

    try:
        # The target comes from the authenticated policy, not from the policy
        # module's own constant. Both are compiled-in and neither is
        # caller-reachable, but only one of them is the decision this
        # transition was authorised to act on -- which is what lets a governed
        # verification-only policy select a different terminal target without
        # a flag, an environment variable, or a caller-supplied pathname.
        backend.execve(policy.worker_interpreter,
                       module.worker_argv(launch,
                                          worker_script=policy.worker_script),
                       policy.environment)
    except OSError as error:
        # The syscall conclusively failed, so nothing ran. There is no second
        # attempt, no alternate interpreter, and no fallback.
        raise refused(f"execve failed: {error}") from None
    raise refused("execve returned without executing")
