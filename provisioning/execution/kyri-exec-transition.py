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
worker identity and executable are compiled in, so there is nothing for a
caller to influence and no `PATH` to search.

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
EXECUTION_ROOT = "/data/kyri/capability-runtime/execution"
HANDOFF_ROOT = "/data/kyri/capability-handoff"
WORKING_DIRECTORY = "/"

WORKER_USER = "kyri-capability"
WORKER_UID = 999
WORKER_GID = 987
COORDINATOR_UID = 1000

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

# Adapter-owned and complete. Nothing is inherited from the caller; these two
# exist because rootless Podman needs them and for no other reason. With
# XDG_DATA_HOME unset, storage resolves to $HOME/.local/share/containers/storage
# -- the graphroot Track B provisioned -- and XDG_RUNTIME_DIR carries rootless
# runtime state. No CONTAINERS_*, no storage override, no socket selector.
ENVIRONMENT: tuple[tuple[str, str], ...] = (
    ("HOME", "/data/kyri/capability"),
    ("XDG_RUNTIME_DIR", "/run/user/999"),
)

# The protocol descriptors, plus the one governed exception: the sealed profile
# object the transition authors itself. This is not a return to ambient
# inheritance -- no caller may name a descriptor number, and a caller descriptor
# that happens to occupy a governed one is replaced, never honoured.
PROFILE_FD = 3
INHERITED_DESCRIPTORS = (0, 1, 2, 3)

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


def policy_for(argv: Sequence[str]) -> TransitionPolicy:
    """The complete transition decision for ``argv``, or refuse.

    ``argv`` is the whole command line, including the program name. Exactly one
    argument follows it, and it is a `CINV`. There is no option parser here on
    purpose: an option parser is a place for flags to be added later.
    """
    _require(isinstance(argv, (list, tuple)), "argv must be a sequence")
    _require(len(argv) == 2,
             "exactly one invocation identity is accepted")
    cinv = validate_cinv(argv[1])

    return TransitionPolicy(
        cinv=cinv,
        worker_user=WORKER_USER,
        worker_uid=WORKER_UID,
        worker_gid=WORKER_GID,
        worker_interpreter=WORKER_INTERPRETER,
        worker_script=WORKER_SCRIPT,
        evidence_path=evidence_path(cinv),
        handoff_path=handoff_path(cinv),
        profile_path=profile_path(cinv),
        environment=ENVIRONMENT,
        working_directory=WORKING_DIRECTORY,
        inherited_descriptors=INHERITED_DESCRIPTORS,
        profile_fd=PROFILE_FD,
    )
