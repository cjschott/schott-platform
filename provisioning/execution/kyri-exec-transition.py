"""Policy logic for the ENG-0005 privileged execution-transition helper.

**This file is source, not an installed helper.** Its presence in the
repository puts nothing on the host. Installation is gate G2 and is closed.

**Policy is separated from action deliberately.** Every decision the helper
must make — which argument is admissible, where the evidence lives, whether the
invocation is authorised, what ownership and modes are required, which identity
and executable to become — is made here, and provably without privilege. The
privileged skeleton wires these decisions to the syscalls; it does not re-make
them. That split is what lets the security-critical reasoning be tested by an
ordinary user, instead of only in the one context where a mistake matters most.

**The caller chooses one thing: a canonical `CINV`.** No executable, no argv,
no identity, no environment, no working directory, no path component. The
worker executable is compiled in and the worker identity comes from root-owned
deployment authority, so there is nothing for a caller to influence and no
`PATH` to search.

**Validate first, construct second.** A path is never built from an
unvalidated argument and then inspected for escapes; a malformed `CINV` is
refused before any string concatenation happens, so there is no normalisation
step that could make bad input acceptable.

**Refusals here mean execution never began.** Every refusal this module makes
happens before any container could exist, which is exactly the condition
`transition_failed_before_execution` requires. A refusal that could *not*
exclude execution must not carry that classification, so the flag is explicit
rather than assumed.

**The authenticated launch record is a type, not a dictionary.** `CIMP` and the
profile digest decide what the worker is told it is running, so a value that
merely *looks* like a checked record must not be usable as one. `check_launch_-
authorisation` is the only thing that can build an `AuthenticatedLaunch`, and
the privileged action accepts nothing else — which is what makes bypassing the
check impossible rather than merely discouraged.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §6
and §14.1.
"""

from __future__ import annotations

import dataclasses
import json
import os
import stat as stat_module
from pathlib import PurePosixPath
from typing import Any, Sequence

# Installed locations, compiled in. These are the trust anchor: the helper runs
# before any verified descriptor exists, so a constant is what anchors it.
HELPER_PATH = "/usr/libexec/kyri-exec-transition"
WORKER_INTERPRETER = "/usr/bin/python3"
# Not directly executed and mode 0444 when installed: naming the
# interpreter explicitly keeps the shebang line out of the trust chain.
WORKER_SCRIPT = "/usr/libexec/kyri-exec-worker.py"
# The reconciliation terminal target. A second worker rather than a mode on the
# first: which operation runs is decided by which entrypoint the operator was
# authorised to invoke, and that is a property of which paths exist rather than
# of a flag somebody checked.
RECONCILE_WORKER_SCRIPT = "/usr/libexec/kyri-exec-reconcile-worker.py"
EXECUTION_ROOT = "/data/kyri/capability-runtime/execution"
HANDOFF_ROOT = "/data/kyri/capability-handoff"
WORKING_DIRECTORY = "/"

# The rootless runtime directory's parent. The uid that completes it is the
# deployment's, so the path is derived rather than written out -- see
# `execution_environment`.
RUNTIME_DIRECTORY_ROOT = "/run/user"

# Kyri's own layout, not a deployment fact. Which filesystem lives under `/data`
# is deployment authority and `backing-store.json` states it; where beneath that
# filesystem Kyri keeps its trees is a property of Kyri, in the same class as
# `EXECUTION_ROOT` and `HELPER_PATH` above. It is deliberately not a field on
# the execution identity authority: that record names a principal, not a path.
EXECUTION_HOME = "/data/kyri/capability"

# The coordinator is a DEPLOYMENT identity, and this is where the deployment
# states it. There is deliberately no constant here to fall back to.
#
# A compiled-in coordinator uid used to live at this line. It was never derived
# and never provisioned: it was true of `schai` because `cschott` happens to be
# uid 1000, and three suites passed on that coincidence. A helper meant to be
# deployment-independent cannot carry one deployment's account number as if it
# were a property of Kyri.
#
# The file sits beside `backing-store.json` in `/etc/kyri` and follows the same
# rule: provisioned, never generated, and a malformed one is a refusal rather
# than a prompt to write a fresh one. Absent, wrongly owned, or writable by
# anyone but root fails closed -- and because the constant is gone, there is
# nothing for a failure to silently degrade to.
COORDINATOR_AUTHORITY_PATH = "/etc/kyri/coordinator-identity.json"
COORDINATOR_AUTHORITY_SCHEMA = (
    "coordinator_account", "coordinator_uid", "schema_version",
)
SUPPORTED_COORDINATOR_SCHEMA_VERSION = 1
MAXIMUM_COORDINATOR_AUTHORITY_BYTES = 4096

# The execution identity is the OTHER deployment identity, and a separate
# record because it is a separate security role. The coordinator prepares and
# may never touch Podman; the execution principal holds rootless Podman
# authority and may never write Capability Runtime records. One file naming
# both would make the two roles editable together and would read as if the
# split were a detail of one document rather than the boundary the whole
# transition exists to create.
#
# A compiled-in `WORKER_USER`, `WORKER_UID` and `WORKER_GID` used to live here.
# They were true of `schai` because `useradd` happened to assign those numbers,
# and the comment above the coordinator authority already said why that is not
# good enough -- it just said it about the other identity. This record is that
# comment applied to this one.
#
# It answers exactly one question: which local kernel identity is authorised to
# execute capability workloads and own the rootless execution substrate on this
# deployment. Not where storage lives, not what the container runs as, not what
# the coordinator is.
EXECUTION_AUTHORITY_PATH = "/etc/kyri/execution-identity.json"
EXECUTION_AUTHORITY_SCHEMA = (
    "execution_account", "execution_gid", "execution_uid", "schema_version",
)
SUPPORTED_EXECUTION_SCHEMA_VERSION = 1
MAXIMUM_EXECUTION_AUTHORITY_BYTES = 4096

LAUNCH_RECORD_NAME = "launch-authorisation"
LAUNCH_AUTHORIZED = "launch_authorized"

# The coordinator's published profile, inside the per-invocation handoff. It is
# publication material: the sealed copy the transition authors from these bytes
# is what becomes execution authority, and this name exists so that no caller
# can aim the read anywhere else.
PROFILE_NAME = "profile"

# The unallocated implementation identity. Grammatically valid and semantically
# meaningless, so it is refused by name rather than left to look admissible.
UNALLOCATED_CIMP = "CIMP-000000"

# The protocol descriptors, plus the one governed exception: the sealed profile
# object the transition authors itself. This is not a return to ambient
# inheritance -- no caller may name a descriptor number, and a caller descriptor
# that happens to occupy a governed one is replaced, never honoured.
PROFILE_FD = 3
INHERITED_DESCRIPTORS = (0, 1, 2, 3)

# Reconciliation gets its own allowlist, derived rather than inherited.
# Descriptor 3 is on the launch list because the transition seals a profile
# object onto it; reconciliation authors no profile, holds no protocol session
# with a worker, and is handed one `CINV`. There is nothing for a fourth
# descriptor to carry, so it is closed -- and the launch list is untouched,
# because narrowing that one would break the supervision session it exists for.
RECONCILE_INHERITED_DESCRIPTORS = (0, 1, 2)

EVIDENCE_MODE = 0o600
HANDOFF_MODE = 0o555
PROFILE_MODE = 0o444

# Bounds applied to the raw bytes before anything parses or copies them. Both
# objects are small and fixed-shape; a document larger than this is refused for
# being oversized rather than for whatever a reader noticed first.
MAXIMUM_LAUNCH_RECORD_BYTES = 4096
MAXIMUM_PROFILE_BYTES = 65536

# `fcntl` seal bits, stated as literals because the decision about which seals
# are mandatory belongs here rather than to whichever module performs them. A
# subset is not acceptable: without F_SEAL_SEAL the set itself is still
# editable, and without any one of the others a mutation route survives.
F_SEAL_SEAL = 0x0001
F_SEAL_SHRINK = 0x0002
F_SEAL_GROW = 0x0004
F_SEAL_WRITE = 0x0008
REQUIRED_SEALS = F_SEAL_SEAL | F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_WRITE

_DIGITS = frozenset("0123456789")
_HEX = frozenset("0123456789abcdef")
# POSIX portable account names, plus the two separators Debian's `useradd`
# accepts. Constrained here rather than at the sudoers writer because a name
# that cannot appear in a grant must not be readable as authority either: a
# principal carrying whitespace, a comma, or a newline could change what a
# sudoers line means.
_ACCOUNT_CHARACTERS = frozenset(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")

# The §6 minimum, and nothing more. Widening this is the schema stop condition:
# if the helper needs broad A1-A5 semantics to decide, that is a halt-and-rule
# event rather than a bigger record.
#
# vNext, ruled in §14.1: `profile_digest` replaces the image identity, and the
# image identity is not reintroduced. Root commits to *bytes* and stays opaque
# to what they say; naming an image here would put an execution field back in
# the privileged parser and make root a second opinion about the profile.
LAUNCH_RECORD_SCHEMA = (
    "cinv", "cimp", "profile_digest", "handoff_root",
    "profile_schema_version", "commitment_digest", "lifecycle_state",
)

SUPPORTED_PROFILE_SCHEMA_VERSION = 1


class TransitionRefused(Exception):
    """A transition that will not proceed.

    ``execution_excluded`` records whether this refusal can prove nothing ran.
    Policy refusals can; a refusal raised after a container might exist cannot,
    and must not borrow the classification that says otherwise.
    """

    def __init__(self, reason: str, *, execution_excluded: bool = True) -> None:
        super().__init__(reason)
        self.execution_excluded = execution_excluded

    @property
    def classification(self) -> Any:
        if not self.execution_excluded:
            return None
        # Imported lazily so the policy module stays loadable by an installed
        # helper that does not carry the repository package.
        from tools.capability.execution.types import Classification
        return Classification.TRANSITION_FAILED_BEFORE_EXECUTION


@dataclasses.dataclass(frozen=True)
class TransitionPolicy:
    """The complete, fixed decision the privileged skeleton will act on.

    Carries no generic execution field. There is nowhere here for a command, a
    shell, an image, a mount, or a caller-chosen identity to appear, which is
    the guarantee rather than a rule about one.
    """

    cinv: str
    worker_user: str
    worker_uid: int
    worker_gid: int
    worker_interpreter: str
    worker_script: str
    evidence_path: str
    handoff_path: str
    profile_path: str
    environment: tuple[tuple[str, str], ...]
    working_directory: str
    inherited_descriptors: tuple[int, ...]
    profile_fd: int


@dataclasses.dataclass(frozen=True)
class ReconciliationPolicy:
    """The complete, fixed decision the reconciliation entrypoint will act on.

    A separate type rather than a flag on `TransitionPolicy`, because the two
    transitions are not the same shape and a boolean that switched between them
    would be a place for one to acquire the other's fields. There is no profile
    here, no handoff, no evidence path and no quota: reconciliation authors
    nothing and reads no coordinator-published object.
    """

    cinv: str
    worker_user: str
    worker_uid: int
    worker_gid: int
    worker_interpreter: str
    worker_script: str
    environment: tuple[tuple[str, str], ...]
    working_directory: str
    inherited_descriptors: tuple[int, ...]


# The token no caller has. Held in a closure-free module global rather than
# passed around, because the only thing that needs it is the one function below
# that is allowed to declare a record authenticated.
_AUTHENTICATED = object()


class AuthenticatedLaunch:
    """A launch record that has passed ``check_launch_authorisation``.

    Deliberately not a plain dataclass. A ``dataclass`` can be constructed by
    anybody and copied with ``replace``, and this value decides which `CIMP`
    and which profile digest the worker is told it is running — so "was this
    checked?" must be answerable from the object's *type* rather than from
    trusting whoever produced it.

    It carries a projection of the record and no reference to the record
    itself: nothing downstream can reach an unvalidated field by going around
    the accessors, because there is no unvalidated field left to reach.
    """

    __slots__ = LAUNCH_RECORD_SCHEMA

    def __init__(self, token: Any, **fields: Any) -> None:
        if token is not _AUTHENTICATED:
            raise TransitionRefused(
                "an authenticated launch record is produced by "
                "check_launch_authorisation and cannot be constructed")
        for name in LAUNCH_RECORD_SCHEMA:
            object.__setattr__(self, name, fields[name])

    def __setattr__(self, name: str, value: Any) -> None:
        raise TransitionRefused("the authenticated launch record is immutable")

    def __delattr__(self, name: str) -> None:
        raise TransitionRefused("the authenticated launch record is immutable")

    def __repr__(self) -> str:
        return (f"AuthenticatedLaunch({self.cinv}, {self.cimp}, "
                f"{self.profile_digest})")


def validate_cinv(value: Any) -> str:
    """The one caller-supplied value, or refuse.

    Checked totally rather than sanitised: there is no stripping, no case
    folding, and no normalisation, because every one of those turns an input
    that should have been refused into one that was accepted.
    """
    if not isinstance(value, str):
        raise TransitionRefused("the invocation identity must be a string")
    if len(value) != 11:
        raise TransitionRefused("the invocation identity is not 11 characters")
    if not value.startswith("CINV-"):
        raise TransitionRefused("the invocation identity is not a CINV")
    if set(value[5:]) - _DIGITS:
        raise TransitionRefused("the invocation identity is not CINV-nnnnnn")
    return value


def evidence_path(cinv: str) -> str:
    """The launch-authorisation record for ``cinv``, from the compiled-in root."""
    validated = validate_cinv(cinv)
    return str(PurePosixPath(EXECUTION_ROOT) / validated / LAUNCH_RECORD_NAME)


def handoff_path(cinv: str) -> str:
    """The per-invocation handoff root for ``cinv``, from the compiled-in root."""
    validated = validate_cinv(cinv)
    return str(PurePosixPath(HANDOFF_ROOT) / validated)


def profile_path(cinv: str) -> str:
    """The published profile for ``cinv``, from the compiled-in root.

    Derived exactly like every other governed path: validated identity first,
    constants second, no caller-supplied component at any position. The
    privileged action opens it descriptor-safely rather than by this string —
    this is the decision about *which* object, not the means of reaching it.
    """
    return str(PurePosixPath(handoff_path(cinv)) / PROFILE_NAME)


def _require(condition: bool, reason: str) -> None:
    if not condition:
        raise TransitionRefused(reason)


def _require_digest(value: Any, what: str) -> str:
    """Exactly 64 lowercase hexadecimal characters, or refuse.

    Lowercase is checked rather than folded, and a ``sha256:`` prefix is
    refused rather than stripped: two spellings of one digest is two answers to
    the question this value exists to settle.
    """
    _require(isinstance(value, str) and len(value) == 64
             and not (set(value) - _HEX), f"the launch record has a malformed {what}")
    return value


def parse_launch_record(data: Any) -> dict[str, Any]:
    """One bounded JSON object from ``data``, or refuse.

    The bound is applied to the raw bytes before parsing. Duplicate keys are
    refused rather than collapsed, because a dictionary has already discarded
    the evidence that a record said two different things.
    """
    _require(isinstance(data, (bytes, bytearray)),
             "the launch record must be bytes")
    _require(len(data) <= MAXIMUM_LAUNCH_RECORD_BYTES,
             f"the launch record exceeds {MAXIMUM_LAUNCH_RECORD_BYTES} bytes")
    try:
        text = bytes(data).decode("utf-8")
    except UnicodeDecodeError:
        raise TransitionRefused("the launch record is not valid UTF-8") from None

    def pairs(items: list[tuple[str, Any]]) -> dict[str, Any]:
        seen: set[str] = set()
        for key, _ in items:
            if key in seen:
                raise TransitionRefused(
                    f"the launch record repeats the field {key!r}")
            seen.add(key)
        return dict(items)

    try:
        document = json.loads(text, object_pairs_hook=pairs)
    except TransitionRefused:
        raise
    except ValueError:
        raise TransitionRefused(
            "the launch record is not one JSON document") from None
    _require(isinstance(document, dict),
             "the launch record is not a JSON object")
    return document


_APPROVED = object()


class CoordinatorAuthority:
    """The deployment's approved coordinator, as read from provisioned authority.

    Not a plain dataclass, for the same reason ``AuthenticatedLaunch`` is not:
    this value decides whose published objects the privileged boundary will
    accept, so "was this read from root-owned authority?" must be answerable
    from the type rather than from trusting the producer. Only
    ``load_coordinator_authority`` can build one.
    """

    __slots__ = ("coordinator_account", "coordinator_uid")

    def __init__(self, token: Any, **fields: Any) -> None:
        if token is not _APPROVED:
            raise TransitionRefused(
                "a coordinator authority is produced by "
                "load_coordinator_authority and cannot be constructed")
        for name in self.__slots__:
            object.__setattr__(self, name, fields[name])

    def __setattr__(self, name: str, value: Any) -> None:
        raise TransitionRefused("the coordinator authority is immutable")

    def __delattr__(self, name: str) -> None:
        raise TransitionRefused("the coordinator authority is immutable")


def check_coordinator_authority_object(info: os.stat_result) -> None:
    """The deployment authority must be root's, and writable by nobody else.

    Ownership is the whole protection. The coordinator is the identity this
    file exists to name, so a file the coordinator can write is a file that
    names whoever the coordinator likes -- which is not an authority, it is a
    declaration. Group and world write bits are refused for the same reason;
    the read bits are not constrained, because 0400 and 0444 are both root's
    decision to make and neither weakens anything.
    """
    _require(stat_module.S_ISREG(info.st_mode),
             "the coordinator authority is not a regular file")
    _require(info.st_uid == 0,
             "the coordinator authority is not owned by root")
    _require(info.st_gid == 0,
             "the coordinator authority is not owned by the root group")
    _require(not (stat_module.S_IMODE(info.st_mode) & 0o022),
             "the coordinator authority is writable by other than root")


def _parse_authority(data: Any, *, label: str, maximum: int) -> dict[str, Any]:
    """One bounded JSON object from ``data``, or refuse.

    The bound is applied to the raw bytes before parsing, and duplicate keys
    are refused rather than collapsed -- the same rule the launch record gets,
    for the same reason: a dictionary has already discarded the evidence that a
    record said two different things about who an identity is.

    Shared by both deployment authorities on purpose. Two copies of a parser
    are two things that can come to disagree about what a well-formed authority
    is, and "the launch and reconcile paths accept the same documents" is a
    property that should hold by construction rather than by inspection.
    """
    _require(isinstance(data, (bytes, bytearray)), f"the {label} must be bytes")
    _require(len(data) <= maximum, f"the {label} exceeds {maximum} bytes")
    try:
        text = bytes(data).decode("utf-8")
    except UnicodeDecodeError:
        raise TransitionRefused(f"the {label} is not valid UTF-8") from None

    def pairs(items: list[tuple[str, Any]]) -> dict[str, Any]:
        seen: set[str] = set()
        for key, _ in items:
            if key in seen:
                raise TransitionRefused(
                    f"the {label} repeats the field {key!r}")
            seen.add(key)
        return dict(items)

    try:
        document = json.loads(text, object_pairs_hook=pairs)
    except TransitionRefused:
        raise
    except ValueError:
        raise TransitionRefused(
            f"the {label} is not one JSON document") from None
    _require(isinstance(document, dict), f"the {label} is not a JSON object")
    return document


def _require_closed_schema(document: dict[str, Any], schema: Sequence[str], *,
                           label: str, version: int) -> None:
    """Exactly ``schema``, no more and no less, at the supported version."""
    for name in document:
        _require(name in schema, f"the {label} carries unknown field {name!r}")
    for name in schema:
        _require(name in document, f"the {label} is missing {name!r}")
    declared = document["schema_version"]
    _require(isinstance(declared, int) and not isinstance(declared, bool)
             and declared == version,
             f"the {label} declares an unsupported schema")


def _require_identity_number(value: Any, *, label: str, field: str) -> int:
    """A usable, non-root kernel identity number, or refuse.

    `bool` first: `True == 1` would otherwise make a boolean an acceptable id.
    Zero is refused by name -- root is the identity the helper already has, and
    an identity that is root is not a boundary.
    """
    _require(isinstance(value, int) and not isinstance(value, bool)
             and 0 < value < 2 ** 31, f"the {label} does not name a {field}")
    return value


def _require_account_name(value: Any, *, label: str) -> str:
    _require(isinstance(value, str) and value and value.strip() == value
             and len(value) <= 32 and not (set(value) - _ACCOUNT_CHARACTERS),
             f"the {label} does not name an account")
    return value


def parse_coordinator_authority(data: Any) -> dict[str, Any]:
    """One bounded JSON object from ``data``, or refuse."""
    return _parse_authority(data, label="coordinator authority",
                            maximum=MAXIMUM_COORDINATOR_AUTHORITY_BYTES)


def load_coordinator_authority(data: Any,
                               info: os.stat_result) -> CoordinatorAuthority:
    """The deployment's approved coordinator, or refuse.

    Ownership is judged before the bytes are read as authority: a file the
    coordinator could have written says nothing, however well-formed it is.

    **The uid is the authority and the account name is not.** The kernel fact
    the helper can check is ``st_uid`` on a descriptor it already holds. A name
    would have to be resolved through NSS at the privileged boundary -- a
    lookup the helper must not depend on, through a database an attacker who
    reached it could aim. The name is carried because the sudoers grant is
    written in names, and ``sudoers_principal`` derives it from this object so
    the grant and the boundary cannot come to disagree.
    """
    check_coordinator_authority_object(info)
    document = parse_coordinator_authority(data)
    _require_closed_schema(document, COORDINATOR_AUTHORITY_SCHEMA,
                           label="coordinator authority",
                           version=SUPPORTED_COORDINATOR_SCHEMA_VERSION)
    return CoordinatorAuthority(
        _APPROVED,
        coordinator_uid=_require_identity_number(
            document["coordinator_uid"], label="coordinator authority",
            field="uid"),
        coordinator_account=_require_account_name(
            document["coordinator_account"], label="coordinator authority"))


def sudoers_principal(authority: Any) -> str:
    """The sudoers principal for an approved coordinator, or refuse.

    Type first, and for the reason the whole function exists: the grant is
    written in account names while the boundary checks numbers, so the one way
    they could drift is a principal derived from something other than the
    record the helper actually read. Taking ``CoordinatorAuthority`` -- which
    only ``load_coordinator_authority`` can produce -- makes a look-alike
    mapping structurally unusable here rather than merely discouraged.
    """
    _require(isinstance(authority, CoordinatorAuthority),
             "a sudoers principal is derived from an approved coordinator "
             "authority and from nothing else")
    return authority.coordinator_account


class ExecutionIdentity:
    """The deployment's execution principal, as read from provisioned authority.

    Token-guarded and immutable for the reason `CoordinatorAuthority` is: this
    value decides which kernel identity root permanently becomes, so "was this
    read from root-owned authority and bound to a real account?" must be
    answerable from the type rather than from trusting whoever built it.
    """

    __slots__ = ("account", "uid", "gid")

    def __init__(self, token: Any, **fields: Any) -> None:
        if token is not _APPROVED:
            raise TransitionRefused(
                "an execution identity is produced by load_execution_identity "
                "and cannot be constructed")
        for name in self.__slots__:
            object.__setattr__(self, name, fields[name])

    def __setattr__(self, name: str, value: Any) -> None:
        raise TransitionRefused("the execution identity is immutable")

    def __delattr__(self, name: str) -> None:
        raise TransitionRefused("the execution identity is immutable")

    def __repr__(self) -> str:
        return f"ExecutionIdentity({self.account}, {self.uid}:{self.gid})"


def check_execution_authority_object(info: os.stat_result) -> None:
    """The execution authority must be root's, and writable by nobody else.

    The same rule the coordinator authority gets, and it matters more here: a
    file the execution principal could write is a file naming whichever identity
    that principal prefers, which would let one compromised worker choose what
    the next transition becomes.
    """
    _require(stat_module.S_ISREG(info.st_mode),
             "the execution authority is not a regular file")
    _require(info.st_uid == 0, "the execution authority is not owned by root")
    _require(info.st_gid == 0,
             "the execution authority is not owned by the root group")
    _require(not (stat_module.S_IMODE(info.st_mode) & 0o022),
             "the execution authority is writable by other than root")


def parse_execution_authority(data: Any) -> dict[str, Any]:
    """One bounded JSON object from ``data``, or refuse."""
    return _parse_authority(data, label="execution authority",
                            maximum=MAXIMUM_EXECUTION_AUTHORITY_BYTES)


def load_execution_identity(data: Any, info: os.stat_result, *,
                            resolve: Any) -> ExecutionIdentity:
    """The deployment's execution principal, or refuse.

    **Both halves of the identity are required to agree.** The coordinator
    authority deliberately treats the uid as authority and the name as
    documentation: the helper checks `st_uid` on descriptors it already holds,
    which is a kernel fact needing no lookup. This identity is different in kind
    -- it is a target to *become* rather than a publisher to recognise -- and
    the failure it must survive is a stale authority naming an account whose uid
    was later reassigned. A number alone cannot detect that, and a name alone
    would put NSS in charge of who root becomes. So the record carries both and
    they are required to still agree, which is a fact neither could establish on
    its own.

    ``resolve`` is injected and required. It is not defined here: this module is
    the *pure* decision layer, provably testable without privilege and without
    ambient system state, and the T10 backstop forbids it the `pwd` and `grp`
    modules for exactly that reason. The account database is a syscall
    dependency, so it lives with the other syscall dependencies in the action
    layer, and the binding still happens inside this parser -- where a caller
    cannot skip it -- rather than as a second opinion somewhere downstream.

    Requiring it rather than defaulting it also means a test cannot forget to
    override it and quietly assert against the host's own account database,
    which is exactly the coincidence this record exists to stop depending on.
    """
    check_execution_authority_object(info)
    document = parse_execution_authority(data)
    _require_closed_schema(document, EXECUTION_AUTHORITY_SCHEMA,
                           label="execution authority",
                           version=SUPPORTED_EXECUTION_SCHEMA_VERSION)

    account = _require_account_name(document["execution_account"],
                                    label="execution authority")
    uid = _require_identity_number(document["execution_uid"],
                                   label="execution authority", field="uid")
    gid = _require_identity_number(document["execution_gid"],
                                   label="execution authority", field="gid")

    _require(callable(resolve), "an account resolver is required")
    resolved_uid, resolved_gid = resolve(account)
    _require(resolved_uid == uid,
             f"the account database resolves {account!r} to uid "
             f"{resolved_uid}, and the execution authority names {uid}")
    _require(resolved_gid == gid,
             f"the account database resolves {account!r} to primary gid "
             f"{resolved_gid}, and the execution authority names {gid}")

    return ExecutionIdentity(_APPROVED, account=account, uid=uid, gid=gid)


def execution_environment(identity: Any) -> tuple[tuple[str, str], ...]:
    """The closed rootless environment for ``identity``, or refuse.

    Adapter-owned and complete. Nothing is inherited from the caller; these two
    exist because rootless Podman needs them and for no other reason. With
    XDG_DATA_HOME unset, storage resolves to
    $HOME/.local/share/containers/storage -- the graphroot Track B provisioned
    -- and XDG_RUNTIME_DIR carries rootless runtime state. No CONTAINERS_*, no
    storage override, no socket selector.

    `XDG_RUNTIME_DIR` is *derived* from the authority's uid rather than stored
    beside it. The rootless runtime directory is a function of the identity, and
    a record that carried both could state a pair that disagreed.
    """
    _require(isinstance(identity, ExecutionIdentity),
             "the execution environment is derived from an approved execution "
             "identity and from nothing else")
    return (("HOME", EXECUTION_HOME),
            ("XDG_RUNTIME_DIR", f"{RUNTIME_DIRECTORY_ROOT}/{identity.uid}"))


def check_launch_authorisation(record: Any, cinv: str) -> AuthenticatedLaunch:
    """Confirm the record authorises launching exactly ``cinv``, or refuse.

    Authorisation comes from this record and nothing else. Neither the handoff
    existing, nor a package being present, nor a file's age, nor a lock, nor
    the caller's assertion is evidence that a launch was authorised.

    Returns a closed projection rather than the caller's dictionary. The
    privileged action needs `CIMP` and the profile digest, and handing back the
    raw mapping would let a later reader take a field this function never
    checked from an object this function appeared to bless.
    """
    validated = validate_cinv(cinv)
    _require(isinstance(record, dict), "the launch record is not an object")

    for name in record:
        _require(name in LAUNCH_RECORD_SCHEMA,
                 f"the launch record carries unknown field {name!r}")
    for name in LAUNCH_RECORD_SCHEMA:
        _require(name in record, f"the launch record is missing {name!r}")

    _require(record["cinv"] == validated,
             "the launch record names a different invocation")

    cimp = record["cimp"]
    _require(isinstance(cimp, str) and len(cimp) == 11
             and cimp.startswith("CIMP-") and not (set(cimp[5:]) - _DIGITS),
             "the launch record has a malformed CIMP")
    # Grammatical and meaningless. Refused by name so that "no implementation
    # was allocated" cannot travel as if it were an implementation.
    _require(cimp != UNALLOCATED_CIMP,
             "the launch record names the unallocated CIMP")

    _require_digest(record["profile_digest"], "profile digest")
    _require_digest(record["commitment_digest"], "commitment digest")

    version = record["profile_schema_version"]
    _require(isinstance(version, int) and not isinstance(version, bool)
             and version == SUPPORTED_PROFILE_SCHEMA_VERSION,
             "the launch record names an unsupported profile schema")

    _require(record["handoff_root"] == HANDOFF_ROOT,
             "the launch record names a different handoff root")

    state = record["lifecycle_state"]
    _require(isinstance(state, str) and state == LAUNCH_AUTHORIZED,
             "the invocation is not launch_authorized")

    return AuthenticatedLaunch(
        _AUTHENTICATED, **{name: record[name] for name in LAUNCH_RECORD_SCHEMA})


def require_authenticated(launch: Any, cinv: str) -> AuthenticatedLaunch:
    """The authenticated record for ``cinv``, or refuse.

    Type first, because only ``check_launch_authorisation`` can produce this
    type — a duck-typed stand-in carrying the right attribute names is exactly
    what this refuses. The identity is then rebound to the invocation actually
    being transitioned, so an authentic record for a *different* `CINV` is no
    more usable than a forged one.
    """
    _require(isinstance(launch, AuthenticatedLaunch),
             "an authenticated launch record is required")
    validated = validate_cinv(cinv)
    _require(launch.cinv == validated,
             "the authenticated record names a different invocation")
    return launch


def check_evidence_object(info: os.stat_result, *, expected_uid: int) -> None:
    """The launch record must be a private regular file owned by the coordinator."""
    _require(stat_module.S_ISREG(info.st_mode),
             "the launch record is not a regular file")
    _require(info.st_uid == expected_uid,
             "the launch record is owned by the wrong identity")
    _require(stat_module.S_IMODE(info.st_mode) == EVIDENCE_MODE,
             "the launch record does not have the expected mode")


def check_handoff_object(info: os.stat_result, *, expected_uid: int) -> None:
    """The handoff must be a read-only directory owned by the coordinator."""
    _require(stat_module.S_ISDIR(info.st_mode),
             "the handoff is not a directory")
    _require(info.st_uid == expected_uid,
             "the handoff is owned by the wrong identity")
    _require(stat_module.S_IMODE(info.st_mode) == HANDOFF_MODE,
             "the handoff does not have the expected mode")


def check_profile_object(info: os.stat_result, *, expected_uid: int) -> None:
    """The published profile must be the coordinator's read-only regular file.

    These are pre-transition expectations, not protection. The file stays
    coordinator-owned and coordinator-replaceable for its whole life; what
    protects the bytes is the sealed copy taken from them. Checking type, owner,
    mode, and size here refuses an obviously wrong object early and cheaply —
    it is not the reason the transport is safe, and must not be read as one.
    """
    _require(stat_module.S_ISREG(info.st_mode),
             "the published profile is not a regular file")
    _require(info.st_uid == expected_uid,
             "the published profile is owned by the wrong identity")
    _require(stat_module.S_IMODE(info.st_mode) == PROFILE_MODE,
             "the published profile does not have the expected mode")
    _require(0 < info.st_size <= MAXIMUM_PROFILE_BYTES,
             f"the published profile is not within 1..{MAXIMUM_PROFILE_BYTES} bytes")


def worker_argv(launch: Any, *, worker_script: str) -> tuple[str, ...]:
    """The exact five-element worker command line, or refuse.

    Every element is a compiled-in constant or a field of an authenticated
    record. There is no parameter here through which a caller could contribute
    an argument, and the two added values exist because the worker cannot
    check `profile.cimp` or the digest against the profile itself — that is
    circular — and must not read the coordinator-owned launch record.

    **`worker_script` is required and has no default.** It comes from the
    `TransitionPolicy` a governed policy module built, which is where the
    target was already declared and — until G6.1 — was then ignored here in
    favour of this module's own constant. Requiring it means the exec site acts
    on the policy that was decided rather than on a second copy of it, and a
    default would silently restore the divergence.

    It is still not caller-reachable: `policy_for` is the only producer of a
    `TransitionPolicy`, each governed policy module compiles in exactly one
    target, and nothing on the command line contributes to either.
    """
    _require(isinstance(launch, AuthenticatedLaunch),
             "the worker command line requires an authenticated launch record")
    _require(isinstance(worker_script, str) and worker_script.startswith("/usr/libexec/"),
             "the worker target must be an absolute governed path")
    return (WORKER_INTERPRETER, worker_script, launch.cinv, launch.cimp,
            launch.profile_digest)


def _validated_argv(argv: Sequence[str]) -> str:
    """The one `CINV` on a two-element command line, or refuse.

    There is no option parser here on purpose: an option parser is a place for
    flags to be added later. Shared by both entrypoints so neither can acquire
    a second argument without the other noticing.
    """
    _require(isinstance(argv, (list, tuple)), "argv must be a sequence")
    _require(len(argv) == 2, "exactly one invocation identity is accepted")
    return validate_cinv(argv[1])


def policy_for(argv: Sequence[str], *, identity: Any) -> TransitionPolicy:
    """The complete transition decision for ``argv``, or refuse.

    ``argv`` is the whole command line, including the program name. Exactly one
    argument follows it, and it is a `CINV`.

    ``identity`` is required and has no default. It is the deployment's
    execution principal, and requiring it here means there is no signature that
    produces a transition policy without one -- so an unpoliced identity is not
    a path somebody could forget to take, it does not exist.
    """
    cinv = _validated_argv(argv)
    _require(isinstance(identity, ExecutionIdentity),
             "a transition policy requires an approved execution identity")

    return TransitionPolicy(
        cinv=cinv,
        worker_user=identity.account,
        worker_uid=identity.uid,
        worker_gid=identity.gid,
        worker_interpreter=WORKER_INTERPRETER,
        worker_script=WORKER_SCRIPT,
        evidence_path=evidence_path(cinv),
        handoff_path=handoff_path(cinv),
        profile_path=profile_path(cinv),
        environment=execution_environment(identity),
        working_directory=WORKING_DIRECTORY,
        inherited_descriptors=INHERITED_DESCRIPTORS,
        profile_fd=PROFILE_FD,
    )


def reconciliation_policy_for(argv: Sequence[str], *,
                              identity: Any) -> ReconciliationPolicy:
    """The complete reconciliation decision for ``argv``, or refuse.

    Same grammar, same identity authority, same environment derivation, and a
    narrower descriptor allowlist. It lives beside `policy_for` rather than in a
    module of its own precisely so those four cannot drift: a second policy
    module would need its own copy of the `CINV` grammar and its own copy of the
    identity parser, which is the drift the shared authority exists to prevent.
    """
    cinv = _validated_argv(argv)
    _require(isinstance(identity, ExecutionIdentity),
             "a reconciliation policy requires an approved execution identity")

    return ReconciliationPolicy(
        cinv=cinv,
        worker_user=identity.account,
        worker_uid=identity.uid,
        worker_gid=identity.gid,
        worker_interpreter=WORKER_INTERPRETER,
        worker_script=RECONCILE_WORKER_SCRIPT,
        environment=execution_environment(identity),
        working_directory=WORKING_DIRECTORY,
        inherited_descriptors=RECONCILE_INHERITED_DESCRIPTORS,
    )
