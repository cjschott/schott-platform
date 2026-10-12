"""The deployment's execution identity, read from root-owned authority.

**Which identity is authorised to execute capability workloads and own the
rootless execution substrate on this deployment.** That is the whole question
this module answers. Not where storage lives, not what the container runs as,
not who the coordinator is -- each of those is a different authority domain and
belongs to a different record.

**Why this is not a constant.** A compiled-in `WORKER_UID` and `WORKER_GID`
used to live in `worker.py`, and they were true of `schai` only because
`useradd` happened to assign those numbers. G11-AH had already made this
argument about the coordinator identity and removed its compiled-in uid; the
same argument was never applied to the identity on the far side. A platform
meant to be deployment-independent cannot carry one deployment's account number
as if it were a property of Kyri.

**Two parsers, one specification, and that is deliberate.** The privileged
launch and reconciliation helpers install beneath a root that must stay usable
without the runtime package, so they cannot import this module and carry their
own implementation of the same grammar in ``kyri-exec-transition.py``. Two
implementations of an authority parser are two things that can come to disagree,
so `tests/test-capability-execution-identity-authority.sh` drives a single set
of vectors through both and requires identical verdicts. This is the discipline
`PROFILE_FD` and `REQUIRED_SEALS` already get, applied to behaviour rather than
to a number.

**Name and numbers must still agree.** The record carries both, and loading it
resolves the account through the system account database and requires the
result to match. Neither half is sufficient alone: a number cannot notice that
an authority naming ``kyri-capability`` now names a uid that was reassigned to
something else, and a name alone would put NSS in charge of which identity the
platform becomes.

**There is no default and no environment fallback.** An absent, wrongly owned,
malformed or unresolvable authority is a refusal. Nothing here can invent one,
and because no compiled-in identity remains, there is nothing for a failure to
silently degrade to.
"""

from __future__ import annotations

import dataclasses
import json
import os
import stat as stat_module
from typing import Any, Sequence

# The one location, compiled in. It is a literal for the reason the library root
# is: every other way of arriving at it -- an argument, an environment variable,
# a working directory -- is something an accident or an attacker can influence.
# The `prod-path-reference` marker is the repository's own mechanism for a line
# that legitimately names a production path. This is not a default: nothing here
# creates the file, no argument overrides it, and its absence is a refusal.
EXECUTION_AUTHORITY_PATH = "/etc/kyri/execution-identity.json"  # prod-path-reference

# Closed, and sorted the way the canonical encoder emits it.
EXECUTION_AUTHORITY_SCHEMA = (
    "execution_account", "execution_gid", "execution_uid", "schema_version",
)
SUPPORTED_EXECUTION_SCHEMA_VERSION = 1
MAXIMUM_EXECUTION_AUTHORITY_BYTES = 4096

# The rootless runtime directory's parent. The uid that completes it comes from
# the authority, so the path is derived rather than stored -- a record carrying
# both could state a pair that disagreed.
RUNTIME_DIRECTORY_ROOT = "/run/user"

# Kyri's own layout, not a deployment fact, and deliberately not a field on the
# identity authority: that record names a principal, not a path. Which
# filesystem lives under `/data` is deployment authority and `backing-store.json`
# states it. Duplicated from the privileged policy module's `EXECUTION_HOME` for
# the reason `PROFILE_FD` is duplicated, and held to it by the same test.
EXECUTION_HOME = "/data/kyri/capability"

# POSIX portable account names plus the two separators Debian's `useradd`
# accepts. Constrained for the reason the privileged side constrains it: a name
# that cannot appear in a sudoers grant must not be readable as authority
# either.
_ACCOUNT_CHARACTERS = frozenset(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")

_READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC


class ExecutionIdentityError(ValueError):
    """The execution identity authority will not be accepted."""


@dataclasses.dataclass(frozen=True)
class ExecutionIdentity:
    """One deployment's execution principal, name and numbers together."""

    account: str
    uid: int
    gid: int


def _require(condition: Any, reason: str) -> None:
    if not condition:
        raise ExecutionIdentityError(reason)


def check_authority_object(info: os.stat_result) -> None:
    """The authority must be root's regular file, writable by nobody else.

    Ownership is the whole protection. A file the execution principal could
    write is a file naming whichever identity that principal prefers, which
    would let one compromised worker choose what the next transition becomes.
    The read bits are not constrained: 0400 and 0444 are both root's decision
    and neither weakens anything.
    """
    _require(stat_module.S_ISREG(info.st_mode),
             "the execution authority is not a regular file")
    _require(info.st_uid == 0, "the execution authority is not owned by root")
    _require(info.st_gid == 0,
             "the execution authority is not owned by the root group")
    _require(not (stat_module.S_IMODE(info.st_mode) & 0o022),
             "the execution authority is writable by other than root")


def parse_authority(data: Any) -> dict[str, Any]:
    """One bounded JSON object from ``data``, or refuse.

    The bound is applied to the raw bytes before parsing, and duplicate keys are
    refused rather than collapsed: a dictionary has already discarded the
    evidence that a record said two different things about who the execution
    principal is.
    """
    _require(isinstance(data, (bytes, bytearray)),
             "the execution authority must be bytes")
    _require(len(data) <= MAXIMUM_EXECUTION_AUTHORITY_BYTES,
             f"the execution authority exceeds "
             f"{MAXIMUM_EXECUTION_AUTHORITY_BYTES} bytes")
    try:
        text = bytes(data).decode("utf-8")
    except UnicodeDecodeError:
        raise ExecutionIdentityError(
            "the execution authority is not valid UTF-8") from None

    def pairs(items: list[tuple[str, Any]]) -> dict[str, Any]:
        seen: set[str] = set()
        for key, _ in items:
            if key in seen:
                raise ExecutionIdentityError(
                    f"the execution authority repeats the field {key!r}")
            seen.add(key)
        return dict(items)

    try:
        document = json.loads(text, object_pairs_hook=pairs)
    except ExecutionIdentityError:
        raise
    except ValueError:
        raise ExecutionIdentityError(
            "the execution authority is not one JSON document") from None
    _require(isinstance(document, dict),
             "the execution authority is not a JSON object")
    return document


def _identity_number(value: Any, field: str) -> int:
    """A usable, non-root kernel identity number, or refuse.

    `bool` first: `True == 1` would otherwise make a boolean an acceptable id.
    Zero is refused by name -- an execution principal that is root would drive
    rootless Podman into an entirely different storage tree, and every later
    verification would be about the wrong container.
    """
    _require(isinstance(value, int) and not isinstance(value, bool)
             and 0 < value < 2 ** 31,
             f"the execution authority does not name a {field}")
    return value


def resolve_account(account: str) -> tuple[int, int]:
    """The kernel identity the account database gives ``account``, or refuse."""
    import pwd

    try:
        entry = pwd.getpwnam(account)
    except KeyError:
        raise ExecutionIdentityError(
            f"the account database does not know {account!r}") from None
    except OSError as error:
        raise ExecutionIdentityError(
            f"the account database is unusable: {error}") from None
    return entry.pw_uid, entry.pw_gid


def load_execution_identity(data: Any, info: os.stat_result, *,
                            resolve: Any) -> ExecutionIdentity:
    """The deployment's execution principal, or refuse.

    Ownership is judged before the bytes are read as authority: a file the
    execution principal could have written says nothing, however well-formed.

    ``resolve`` is required rather than defaulted. Production passes
    ``resolve_account``; a default would let a test forget to override it and
    quietly assert against the host's own account database, which is exactly the
    coincidence this record exists to stop depending on.
    """
    check_authority_object(info)
    document = parse_authority(data)

    for name in document:
        _require(name in EXECUTION_AUTHORITY_SCHEMA,
                 f"the execution authority carries unknown field {name!r}")
    for name in EXECUTION_AUTHORITY_SCHEMA:
        _require(name in document,
                 f"the execution authority is missing {name!r}")

    version = document["schema_version"]
    _require(isinstance(version, int) and not isinstance(version, bool)
             and version == SUPPORTED_EXECUTION_SCHEMA_VERSION,
             "the execution authority declares an unsupported schema")

    account = document["execution_account"]
    _require(isinstance(account, str) and account and account.strip() == account
             and len(account) <= 32 and not (set(account) - _ACCOUNT_CHARACTERS),
             "the execution authority does not name an account")
    uid = _identity_number(document["execution_uid"], "uid")
    gid = _identity_number(document["execution_gid"], "gid")

    _require(callable(resolve), "an account resolver is required")
    resolved_uid, resolved_gid = resolve(account)
    _require(resolved_uid == uid,
             f"the account database resolves {account!r} to uid "
             f"{resolved_uid}, and the execution authority names {uid}")
    _require(resolved_gid == gid,
             f"the account database resolves {account!r} to primary gid "
             f"{resolved_gid}, and the execution authority names {gid}")

    return ExecutionIdentity(account=account, uid=uid, gid=gid)


def read_execution_identity(*, resolve: Any = resolve_account
                            ) -> ExecutionIdentity:
    """The deployment's execution principal, read from the one location.

    **There is no path parameter**, which is the point: production must not be
    able to be aimed at an authority somebody chose. Tests drive
    ``load_execution_identity`` with fixture bytes and a fixture status instead,
    which is the same seam the privileged side is tested through.

    Opened ``O_NOFOLLOW`` so a symlink at the final component is refused rather
    than followed, and the status is taken from the descriptor that was opened
    rather than from a second look at the name.
    """
    try:
        handle = os.open(EXECUTION_AUTHORITY_PATH, _READ_FLAGS)
    except OSError as error:
        raise ExecutionIdentityError(
            f"the execution authority is unusable: {error}") from None
    try:
        info = os.fstat(handle)
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(handle, 65536)
            if not chunk:
                break
            total += len(chunk)
            if total > MAXIMUM_EXECUTION_AUTHORITY_BYTES:
                raise ExecutionIdentityError(
                    "the execution authority exceeds "
                    f"{MAXIMUM_EXECUTION_AUTHORITY_BYTES} bytes")
            chunks.append(chunk)
    except OSError as error:
        raise ExecutionIdentityError(
            f"the execution authority could not be read: {error}") from None
    finally:
        os.close(handle)
    return load_execution_identity(b"".join(chunks), info, resolve=resolve)


def environment(identity: Any) -> tuple[tuple[str, str], ...]:
    """The closed rootless environment for ``identity``, or refuse.

    Adapter-owned and complete. With ``XDG_DATA_HOME`` unset, storage resolves
    to ``$HOME/.local/share/containers/storage`` -- the graphroot Track B
    provisioned -- and ``XDG_RUNTIME_DIR`` carries rootless runtime state. No
    ``CONTAINERS_*``, no storage override, no socket selector.
    """
    _require(isinstance(identity, ExecutionIdentity),
             "the execution environment is derived from a loaded execution "
             "identity and from nothing else")
    return (("HOME", EXECUTION_HOME),
            ("XDG_RUNTIME_DIR", f"{RUNTIME_DIRECTORY_ROOT}/{identity.uid}"))


def require_identity(identity: Any, *, uid: int, gid: int) -> None:
    """Confirm this process is ``identity``, or refuse.

    Root is refused explicitly rather than incidentally, and before the
    comparison: an authority that somehow named root would otherwise be
    satisfied by a root process.
    """
    _require(isinstance(identity, ExecutionIdentity),
             "the execution identity must come from provisioned authority")
    _require(uid != 0 and gid != 0, "the worker must never run as root")
    _require(uid == identity.uid and gid == identity.gid,
             f"the worker must run as {identity.uid}:{identity.gid}, "
             f"not {uid}:{gid}")


__all__: Sequence[str] = (
    "EXECUTION_AUTHORITY_PATH", "EXECUTION_AUTHORITY_SCHEMA", "EXECUTION_HOME",
    "MAXIMUM_EXECUTION_AUTHORITY_BYTES", "RUNTIME_DIRECTORY_ROOT",
    "SUPPORTED_EXECUTION_SCHEMA_VERSION", "ExecutionIdentity",
    "ExecutionIdentityError", "check_authority_object", "environment",
    "load_execution_identity", "parse_authority", "read_execution_identity",
    "require_identity", "resolve_account",
)
