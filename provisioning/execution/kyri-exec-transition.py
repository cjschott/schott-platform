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

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §6.
"""

from __future__ import annotations

import dataclasses
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

# Adapter-owned and complete. Nothing is inherited from the caller; these two
# exist because rootless Podman needs them and for no other reason. With
# XDG_DATA_HOME unset, storage resolves to $HOME/.local/share/containers/storage
# -- the graphroot Track B provisioned -- and XDG_RUNTIME_DIR carries rootless
# runtime state. No CONTAINERS_*, no storage override, no socket selector.
ENVIRONMENT: tuple[tuple[str, str], ...] = (
    ("HOME", "/data/kyri/capability"),
    ("XDG_RUNTIME_DIR", "/run/user/999"),
)

# Only the protocol descriptors cross. No ambient inheritance, and no caller
# may name a descriptor number.
INHERITED_DESCRIPTORS = (0, 1, 2)

EVIDENCE_MODE = 0o600
HANDOFF_MODE = 0o555

_DIGITS = frozenset("0123456789")
_HEX = frozenset("0123456789abcdef")

# The §6 minimum, and nothing more. Widening this is the schema stop condition:
# if the helper needs broad A1-A5 semantics to decide, that is a halt-and-rule
# event rather than a bigger record.
LAUNCH_RECORD_SCHEMA = (
    "cinv", "cimp", "oci_digest", "handoff_root", "profile_schema_version",
    "commitment_digest", "lifecycle_state",
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
    worker_argv: tuple[str, ...]
    evidence_path: str
    handoff_path: str
    environment: tuple[tuple[str, str], ...]
    working_directory: str
    inherited_descriptors: tuple[int, ...]


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


def _require(condition: bool, reason: str) -> None:
    if not condition:
        raise TransitionRefused(reason)


def check_launch_authorisation(record: Any, cinv: str) -> None:
    """Confirm the record authorises launching exactly ``cinv``, or refuse.

    Authorisation comes from this record and nothing else. Neither the handoff
    existing, nor a package being present, nor a file's age, nor a lock, nor
    the caller's assertion is evidence that a launch was authorised.
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

    digest = record["oci_digest"]
    _require(isinstance(digest, str) and digest.startswith("sha256:")
             and len(digest) == 71 and not (set(digest[7:]) - _HEX),
             "the launch record has a malformed OCI digest")

    commitment = record["commitment_digest"]
    _require(isinstance(commitment, str) and len(commitment) == 64
             and not (set(commitment) - _HEX),
             "the launch record has a malformed commitment digest")

    version = record["profile_schema_version"]
    _require(isinstance(version, int) and not isinstance(version, bool)
             and version == SUPPORTED_PROFILE_SCHEMA_VERSION,
             "the launch record names an unsupported profile schema")

    _require(record["handoff_root"] == HANDOFF_ROOT,
             "the launch record names a different handoff root")

    state = record["lifecycle_state"]
    _require(isinstance(state, str) and state == LAUNCH_AUTHORIZED,
             "the invocation is not launch_authorized")


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
        worker_argv=(WORKER_INTERPRETER, WORKER_SCRIPT, cinv),
        evidence_path=evidence_path(cinv),
        handoff_path=handoff_path(cinv),
        environment=ENVIRONMENT,
        working_directory=WORKING_DIRECTORY,
        inherited_descriptors=INHERITED_DESCRIPTORS,
    )
