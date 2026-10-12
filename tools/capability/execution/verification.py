"""The verification-only terminal action, and nothing that could execute.

**G6.1.** The production worker and this module run the *same* verification
chain, because it is the same function: ``worker.verify_execution`` is the one
route to ``create_argv``, and everything before that point is shared rather
than reimplemented. Only the terminal action differs — production materialises
a snapshot and creates a container; this returns a record saying what was
proven and stops.

**What is deliberately absent.** This module does not import
``create_argv``, does not import ``snapshot``, and names no container runtime.
Those are not omissions to be tidied up later: the verification entrypoint
exists to be structurally unable to reach execution, and an import is
reachability. ``worker.create_argv`` imports ``snapshot`` lazily inside its own
body, so a verification run never loads that module at all — which is a fact a
test can check, not a promise.

**It re-derives nothing it is given.** The execution identity, the profile
schema version and the seal requirement all come from the governed contracts
being verified. Writing them out again here would mean the record could agree
with itself while disagreeing with the runtime.

**It verifies the transition's own claims.** The privileged transition asserts
that it closed the extra descriptors, dropped credentials permanently, and set
``no_new_privs``. This process is the only place those claims can be checked
from the far side of ``execve``, so it checks them: the credentials it actually
holds, the descriptors it actually has, and the flag the kernel actually
reports. A claim verified only by the party making it is not verified.

**The record carries identifiers and booleans, never material.** No payload
bytes, no package bytes, no profile contents beyond the schema version, no
environment, and no authority record beyond the two identifiers the proof is
about. The point is to prove the chain ran, not to publish what it read.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §7,
§17, and the execution transition boundary §8.
"""

from __future__ import annotations

import fcntl
import os
from typing import Any

# Named imports only, and deliberately not `from . import worker`: binding the
# module would put `create_argv` one attribute access away, and the whole point
# of this module is that it is not.
from .identity import ExecutionIdentity
from .worker import (PROFILE_FD, REQUIRED_SEALS, LaunchContext, WorkerRefused,
                     verify_execution)
from .profile import PROFILE_SCHEMA_VERSION
from .types import ExecutionProfile

WORKER_MODE = "verification-only"

# The descriptors the ruled transition passes through `execve`, and the only
# ones this process may hold. Anything else is something that survived a
# closure that was supposed to have happened.
EXPECTED_DESCRIPTORS = frozenset((0, 1, 2, PROFILE_FD))

_PROC_STATUS = "/proc/self/status"
_PROC_FD = "/proc/self/fd"


def require_no_new_privs() -> int:
    """Confirm the kernel reports ``no_new_privs``, or refuse.

    Read from ``/proc/self/status`` rather than asserted from the transition's
    say-so. The transition sets the flag and reads it back, which proves the
    flag was set in *that* process; this proves it survived into this one,
    which is the property the container actually depends on.

    A missing field is a refusal, not a zero: an unreadable answer and a
    negative answer are different facts, and only one of them is safe.
    """
    try:
        with open(_PROC_STATUS, "r", encoding="ascii") as handle:
            for line in handle:
                if line.startswith("NoNewPrivs:"):
                    value = line.split(":", 1)[1].strip()
                    if value != "1":
                        raise WorkerRefused(
                            f"no_new_privs is {value!r}, and execution requires 1")
                    return 1
    except OSError as error:
        raise WorkerRefused(f"no_new_privs could not be read: {error}") from None
    raise WorkerRefused("no_new_privs is not reported by this kernel")


def require_descriptor_closure() -> tuple[int, ...]:
    """Confirm this process holds exactly the ruled descriptors, or refuse.

    The transition closes everything outside its allowlist before dropping
    privilege. An extra descriptor here is one that survived that closure, and
    a descriptor opened by a privileged process and inherited by an
    unprivileged one is precisely the thing the closure exists to prevent.

    Asking the question costs a descriptor: reading ``/proc/self/fd`` opens a
    directory, and on this platform the read duplicates it again, so the
    listing contains one or two entries that exist only because it was
    produced. Guessing which numbers those were would be a rule about an
    implementation detail. Instead the listing is taken first and each number in
    it is then confirmed still open — the descriptors the listing itself used
    are closed by that point, so they drop out for the right reason rather than
    by being subtracted.
    """
    try:
        names = os.listdir(_PROC_FD)
    except OSError as error:
        raise WorkerRefused(f"the descriptor table could not be read: {error}") from None

    held = set()
    for name in names:
        try:
            number = int(name)
        except ValueError:
            continue
        try:
            fcntl.fcntl(number, fcntl.F_GETFD)
        except OSError:
            continue
        held.add(number)

    unexpected = sorted(held - EXPECTED_DESCRIPTORS)
    if unexpected:
        raise WorkerRefused(
            f"descriptors survived the transition's closure: {unexpected}")
    missing = sorted(EXPECTED_DESCRIPTORS - held)
    if missing:
        raise WorkerRefused(f"the ruled descriptors are not present: {missing}")
    return tuple(sorted(held))


def require_dropped_credentials(*, uid: int, gid: int) -> None:
    """Confirm the drop was permanent, or refuse.

    ``require_worker_identity`` checks the effective identity. This checks that
    there is no way back: a saved-set identity still holding root would mean
    the drop was a change of costume rather than a change of authority, and
    ``setuid`` would restore it.
    """
    if not hasattr(os, "getresuid") or not hasattr(os, "getresgid"):
        raise WorkerRefused("this platform cannot report the saved-set identity")
    real_uid, effective_uid, saved_uid = os.getresuid()
    real_gid, effective_gid, saved_gid = os.getresgid()
    if {real_uid, effective_uid, saved_uid} != {uid}:
        raise WorkerRefused(
            f"the uid drop is not permanent: real/effective/saved are "
            f"{real_uid}/{effective_uid}/{saved_uid}, expected {uid}")
    if {real_gid, effective_gid, saved_gid} != {gid}:
        raise WorkerRefused(
            f"the gid drop is not permanent: real/effective/saved are "
            f"{real_gid}/{effective_gid}/{saved_gid}, expected {gid}")
    groups = set(os.getgroups())
    if groups - {gid}:
        raise WorkerRefused(
            f"supplementary groups survived the drop: {sorted(groups - {gid})}")


def execution_record(context: Any, profile: Any, *,
                     identity: Any) -> dict[str, Any]:
    """What was proven, derived from the contracts that proved it.

    Split out from `verify_only` because the three self-checks above are facts
    about the *process* — its credentials, its descriptors, its `no_new_privs`
    — and are therefore only true in the process the transition created. This
    is the part that is a pure function of the verified inputs, so it can be
    exercised directly, and every value in it is read from the governed
    contract rather than written out again here.

    Producing this dictionary is not proof of anything and confers no
    authority. `verify_only` is what runs the chain, and the worker calls
    nothing else.
    """
    if not isinstance(context, LaunchContext):
        raise WorkerRefused("a validated LaunchContext is required")
    if not isinstance(profile, ExecutionProfile):
        raise WorkerRefused("a built ExecutionProfile is required")
    if not isinstance(identity, ExecutionIdentity):
        raise WorkerRefused("a loaded ExecutionIdentity is required")
    return {
        "result": "verified",
        "cinv": context.cinv,
        "cimp": context.cimp,
        # From the same deployment authority the drop was checked against, so a
        # record cannot agree with itself while disagreeing with the identity
        # that was required.
        "execution_uid": identity.uid,
        "execution_gid": identity.gid,
        "profile_sealed": True,
        "handoff_verified": True,
        # No container was created, started or run, and `create_argv` was never
        # called -- it is not reachable from this module at all.
        "podman_invoked": False,
        # Stated separately so the line above cannot be read as more than it
        # claims. `verify_execution` consults the rootless store for presence,
        # which is a read of the store's own index rather than an invocation of
        # anything. A record that left the read implicit would be claiming, by
        # omission, that the store was never consulted at all.
        "image_presence_probed": True,
        # From the sealed profile, which `require_runtime_contract` has already
        # required to equal this build's implemented schema.
        "profile_schema_version": profile.profile_schema_version,
        "worker_mode": WORKER_MODE,
    }


def verify_only(context: Any, profile: Any, *, root_fd: int, images: Any,
                identity: Any) -> dict[str, Any]:
    """Run the whole shared chain and return what was proven, or refuse.

    The order is the production order, because it *is* the production order:
    ``verify_execution`` is called with the same arguments the production
    worker passes it, and its refusal is this function's refusal. What differs
    is only what happens after it returns — production builds a snapshot and a
    container, and this builds a sentence.

    The verified result is deliberately dropped. It carries the payload bytes
    and the resolved entrypoint, and this function's contract is to prove the
    chain ran rather than to hand anyone what it read.
    """
    if not isinstance(context, LaunchContext):
        raise WorkerRefused("a validated LaunchContext is required")
    if not isinstance(profile, ExecutionProfile):
        raise WorkerRefused("a built ExecutionProfile is required")
    if not isinstance(identity, ExecutionIdentity):
        raise WorkerRefused("a loaded ExecutionIdentity is required")

    # The transition's own claims, checked from the far side of execve against
    # the deployment authority rather than against a compiled-in pair.
    require_dropped_credentials(uid=identity.uid, gid=identity.gid)
    require_descriptor_closure()
    require_no_new_privs()

    # The shared chain. Not a reimplementation, not a subset: the same call the
    # production worker makes, and the only route to create_argv.
    verify_execution(context, profile, root_fd=root_fd, images=images)

    # Built only after every check above returned. If the profile and the build
    # disagreed about the schema, `require_runtime_contract` inside
    # `verify_execution` has already refused and this line is unreachable.
    return execution_record(context, profile, identity=identity)


def success_record(record: dict[str, Any], *, identity: Any) -> str:
    """One line of canonical JSON, or refuse.

    Serialised through the platform's canonical encoder so two runs of the same
    verification produce the same bytes, and so the record cannot carry a type
    the rest of the system would not accept.

    Every field is checked against what it is supposed to be before it is
    emitted. A success record is the one output a reader is entitled to trust,
    so it does not get to be approximately right.
    """
    from .canonical_json import serialise

    required = {
        "result": "verified",
        "profile_sealed": True,
        "handoff_verified": True,
        "podman_invoked": False,
        "image_presence_probed": True,
        "worker_mode": WORKER_MODE,
    }
    if not isinstance(record, dict):
        raise WorkerRefused("a success record is a mapping")
    if not isinstance(identity, ExecutionIdentity):
        raise WorkerRefused("a loaded ExecutionIdentity is required")

    for name, expected in required.items():
        actual = record.get(name)
        # Type identity as well as value. In Python `False == 0` and
        # `True == 1`, so a record carrying an integer where a boolean belongs
        # would otherwise pass every comparison while meaning something else to
        # whatever reads the JSON.
        if type(actual) is not type(expected) or actual != expected:
            raise WorkerRefused(f"the success record is not a success at {name!r}")

    for name, expected in (("execution_uid", identity.uid),
                           ("execution_gid", identity.gid),
                           ("profile_schema_version", PROFILE_SCHEMA_VERSION)):
        actual = record.get(name)
        if isinstance(actual, bool) or not isinstance(actual, int) \
                or actual != expected:
            raise WorkerRefused(
                f"the success record does not name the governed {name}")

    for name in ("cinv", "cimp"):
        actual = record.get(name)
        if not isinstance(actual, str) or len(actual) != 11:
            raise WorkerRefused(f"the success record has a malformed {name}")

    # Nothing beyond the proof. A record that can quietly grow is one whose
    # meaning drifts, and material has no business in it at all.
    unexpected = set(record) - (set(required) | {
        "cinv", "cimp", "execution_uid", "execution_gid", "profile_schema_version"})
    if unexpected:
        raise WorkerRefused(f"the success record carries {sorted(unexpected)}")
    return serialise(record).decode("ascii")


__all__ = ["EXPECTED_DESCRIPTORS", "REQUIRED_SEALS", "WORKER_MODE",
           "execution_record", "require_descriptor_closure",
           "require_dropped_credentials", "require_no_new_privs",
           "success_record", "verify_only"]
