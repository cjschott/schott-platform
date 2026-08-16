"""The coordinator execution-authorization bridge for ENG-0005.

**It connects `execution-prepared` to a handoff a privileged boundary may
later verify, and it stops there.** Nothing here elevates, executes, or
contacts a container runtime; the privileged transition consumes what this
produces and never creates the decision itself.

**The lifecycle transition is the authority.** `RESERVED -> LAUNCH_AUTHORIZED`
is committed first and is the only thing that decides whether a launch was
approved. The launch-authorisation record is a *projection* of that decision,
and the handoff is *materialisation* of it. Both are deterministic functions of
the committed authority plus material the coordinator already published, which
is exactly what makes an interrupted run resumable: everything after the
transition can be recomputed, and nothing after it may disagree.

**Authority is never re-decided.** A `CINV` that already stands at
`LAUNCH_AUTHORIZED` is resumed, never re-authorised: the transition is not
attempted again, no second `CMUT` is spent, and no second identity is
allocated. An exact repeat returns the same answer; anything that disagrees
with the committed authority is refused.

**Nothing is repaired.** A projection or a handoff that disagrees is a refusal,
not something to delete and rebuild. There is no `unlink`, no `rmtree`, no
`chmod`, and no truncating open anywhere in this module, because a bridge that
could tidy up a disagreement could also tidy away the evidence of one.

**It re-runs no governed decision it does not own.** Fabric selection and
package resolution happened at preparation and are read back from the durable
invocation record; Trust is not consulted at all. What this re-derives is the
execution profile, which is a pure function of the invocation identity and the
implementation authority — an independent namespace the coordinator can read
and cannot write.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §6,
§13 and §16, and the execution transition boundary §3.
"""

from __future__ import annotations

import dataclasses
import hashlib
import os
from typing import Any

from ..errors import CapabilityError
from ..invocation_identity import payload_digest as invocation_payload_digest
from ..records import INVOCATION_KIND
from . import canonical_json
from . import capacity as capacity_module
from . import state as state_module
from .authorisation import authorise_implementation
from .backing_store import RootDescriptor
from .handoff import (HANDOFF_MODES, OUTPUT_DIRECTORY, PACKAGE_DIRECTORY,
                      PAYLOAD_NAME, PROFILE_NAME, HandoffBinding,
                      publish_handoff)
from .mutation import (LAUNCH_AUTHORISATION_NAME, Mutation, MutationTarget,
                       TargetKind)
from .package_contract import validate_package
from .payload import validate_payload
from .profile import fingerprint
from .types import LifecycleState

# The compiled-in handoff root the privileged transition requires the record to
# name. Stated here so the projection cannot be aimed at another tree, and
# compared rather than derived from whatever root was passed in.
HANDOFF_ROOT = "/data/kyri/capability-handoff"

# The launch-record transport schema. Deliberately *not* the execution
# profile's schema version: this numbers the seven-field record the privileged
# helper parses, and the profile it points at carries its own.
TRANSPORT_SCHEMA_VERSION = 1

# The exact literal the privileged helper requires, and the lifecycle state it
# projects. One value, spelled once, so the two cannot drift apart.
LIFECYCLE_STATE = LifecycleState.LAUNCH_AUTHORIZED.value

# The vNext seven fields, in the helper's own order.
LAUNCH_RECORD_SCHEMA = ("cinv", "cimp", "profile_digest", "handoff_root",
                        "profile_schema_version", "commitment_digest",
                        "lifecycle_state")

# What the durable invocation record must say for a launch to be considered at
# all. Anything else is a preparation that did not succeed, or one that has
# already been decided.
PREPARED_OUTCOME = "execution-prepared"

_DIGEST_PREFIX = "sha256:"
_HEX = frozenset("0123456789abcdef")
_DIGITS = frozenset("0123456789")
_DIR_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY
_READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC


class LaunchError(ValueError):
    """Base for every refusal this module makes."""


class LaunchRefused(LaunchError):
    """The invocation is not eligible to be authorised for launch."""


class LaunchDisagreement(LaunchError):
    """Committed authority and existing material do not describe each other."""


@dataclasses.dataclass(frozen=True)
class LaunchReady:
    """One authorised invocation, materialised and proven.

    ``resumed`` says whether this call made the authority decision or found it
    already committed. It is reported rather than hidden because "authorised
    now" and "authorised earlier" are different facts, and a caller that cannot
    tell them apart cannot tell an idempotent repeat from a first run.
    """

    cinv: str
    cimp: str
    profile_digest: str
    commitment_digest: str
    handoff: HandoffBinding
    resumed: bool


def commitment_digest(binding_digest: Any) -> str:
    """The commitment, taken from the invocation binding that already exists.

    Ruling A: the commitment *is* the prepared invocation's binding digest,
    carried in the bare form the privileged parser accepts. The binding already
    commits to the invocation identity together with the governed selection,
    instance, package, actor and payload, so deriving a second digest over the
    same facts would be a second answer to one question.

    The released form is `sha256:<64 lowercase hex>` and the record form is the
    64-hex body. The prefix is removed only after it has been proved present:
    stripping first and validating afterwards would accept a bare digest as
    though it had carried one.
    """
    if not isinstance(binding_digest, str):
        raise LaunchRefused("the invocation binding digest must be text")
    if not binding_digest.startswith(_DIGEST_PREFIX):
        raise LaunchRefused(
            f"the invocation binding digest is not in {_DIGEST_PREFIX} form")
    body = binding_digest[len(_DIGEST_PREFIX):]
    if len(body) != 64 or set(body) - _HEX:
        raise LaunchRefused(
            "the invocation binding digest body is not 64 lowercase hex digits")
    return body


def _require_hex64(value: Any, what: str) -> str:
    """Exactly 64 lowercase hex characters, or refuse.

    Lowercase is checked rather than folded and a prefix is refused rather than
    stripped, matching the privileged parser exactly: two spellings of one
    digest is two answers to the question the value exists to settle.
    """
    if not isinstance(value, str) or len(value) != 64 or set(value) - _HEX:
        raise LaunchRefused(f"the {what} is not 64 lowercase hex digits")
    return value


def _require_cinv(value: Any) -> str:
    if not isinstance(value, str) or len(value) != 11 \
            or not value.startswith("CINV-") or set(value[5:]) - _DIGITS:
        raise LaunchRefused(f"{value!r} is not a CINV identity")
    return value


def _require_cimp(value: Any) -> str:
    if not isinstance(value, str) or len(value) != 11 \
            or not value.startswith("CIMP-") or set(value[5:]) - _DIGITS:
        raise LaunchRefused(f"{value!r} is not a CIMP identity")
    if value == "CIMP-000000":
        raise LaunchRefused("CIMP-000000 is reserved and is never an implementation")
    return value


def launch_record(*, cinv: str, cimp: str, profile_digest: str,
                  commitment_digest: str) -> dict[str, Any]:
    """The seven-field projection, built from checked values only.

    Every field is validated to the privileged parser's own rule before it is
    placed, so a record this function returns is one that parser accepts. The
    two constants it does not take — the handoff root and the transport schema
    version — are compiled in here for the same reason they are compiled in
    there: they are not decisions a caller gets to make.
    """
    return {
        "cinv": _require_cinv(cinv),
        "cimp": _require_cimp(cimp),
        "profile_digest": _require_hex64(profile_digest, "profile digest"),
        "handoff_root": HANDOFF_ROOT,
        "profile_schema_version": TRANSPORT_SCHEMA_VERSION,
        "commitment_digest": _require_hex64(commitment_digest,
                                            "commitment digest"),
        "lifecycle_state": LIFECYCLE_STATE,
    }


def _prepared_invocation(store: Any, cinv: str) -> dict[str, Any]:
    """The durable record for ``cinv``, proven to be a prepared one.

    The record is authority about what was decided at preparation. It is read
    rather than reconstructed, and every value this bridge later relies on is
    taken from it — so a launch cannot be built on a selection, package or
    payload other than the one that was actually prepared.
    """
    try:
        record = store.read_record(INVOCATION_KIND, cinv)
    except CapabilityError as error:
        raise LaunchRefused(f"{cinv} is not a readable invocation: {error}") from None

    evidence = record.get("evidence")
    if not isinstance(evidence, dict) or evidence.get("outcome") != PREPARED_OUTCOME:
        raise LaunchRefused(f"{cinv} is not {PREPARED_OUTCOME}")
    if not record.get("staged_path"):
        raise LaunchRefused(f"{cinv} carries no staged package")
    return record


def _published_handoff(root: RootDescriptor, cinv: str) -> bool:
    try:
        status = os.stat(cinv, dir_fd=root.fd, follow_symlinks=False)
    except FileNotFoundError:
        return False
    if not (status.st_mode & 0o170000) == 0o040000:
        raise LaunchDisagreement(
            f"{cinv} exists in the handoff root and is not a directory")
    return True


def _read_member(name: str, dir_fd: int) -> bytes:
    handle = os.open(name, _READ_FLAGS, dir_fd=dir_fd)
    try:
        chunks: list[bytes] = []
        while True:
            chunk = os.read(handle, 65536)
            if not chunk:
                break
            chunks.append(chunk)
    finally:
        os.close(handle)
    return b"".join(chunks)


def _verify_handoff(root: RootDescriptor, cinv: str, *, payload_bytes: bytes,
                    profile_bytes: bytes, package: Any) -> None:
    """Prove an existing handoff is the exact one this authority requires.

    Existence is not the question and never becomes it. Every published byte is
    re-read and compared against what the committed authority says must be
    there, and the modes are compared too, because a tree with the right bytes
    and the wrong permissions is not the tree the privileged boundary was
    designed to consume.
    """
    try:
        invocation = os.open(cinv, _DIR_FLAGS, dir_fd=root.fd)
    except OSError as error:
        raise LaunchDisagreement(
            f"the published handoff for {cinv} is unusable: {error}") from None
    try:
        expected_modes = {
            PAYLOAD_NAME: (payload_bytes, HANDOFF_MODES["payload"]),
            PROFILE_NAME: (profile_bytes, HANDOFF_MODES["profile"]),
        }
        for name, (expected, mode) in expected_modes.items():
            try:
                status = os.stat(name, dir_fd=invocation, follow_symlinks=False)
            except FileNotFoundError:
                raise LaunchDisagreement(
                    f"the published handoff for {cinv} is missing {name}") from None
            if not (status.st_mode & 0o170000) == 0o100000:
                raise LaunchDisagreement(f"{cinv}/{name} is not a regular file")
            if (status.st_mode & 0o7777) != mode:
                raise LaunchDisagreement(
                    f"{cinv}/{name} has mode {oct(status.st_mode & 0o7777)}, "
                    f"not {oct(mode)}")
            if _read_member(name, invocation) != expected:
                raise LaunchDisagreement(
                    f"{cinv}/{name} does not hold the bytes this authorisation "
                    "committed to")

        for name, mode in ((PACKAGE_DIRECTORY, HANDOFF_MODES["package"]),
                           (OUTPUT_DIRECTORY, HANDOFF_MODES["output"])):
            try:
                status = os.stat(name, dir_fd=invocation, follow_symlinks=False)
            except FileNotFoundError:
                raise LaunchDisagreement(
                    f"the published handoff for {cinv} is missing {name}") from None
            if not (status.st_mode & 0o170000) == 0o040000:
                raise LaunchDisagreement(f"{cinv}/{name} is not a directory")

        # The package is re-validated through the contract that produced the
        # commitment, so a tree that gained, lost or altered a file is refused
        # by the same rule that bound it rather than by a weaker local one.
        tree = os.open(PACKAGE_DIRECTORY, _DIR_FLAGS, dir_fd=invocation)
        try:
            republished = validate_package(tree, entrypoint=package.entrypoint)
        finally:
            os.close(tree)
        if republished.digest != package.digest:
            raise LaunchDisagreement(
                f"the published package for {cinv} is not the committed one")
    finally:
        os.close(invocation)


def _commit_projection(execution_root: RootDescriptor, cinv: str,
                       body: bytes) -> None:
    """Journal the projection, or prove the journalled one already agrees.

    The record is authority-bearing, so it goes through the mutation substrate
    rather than beside it. An existing record is read back and compared with
    the bytes this authority requires: agreement is a resumed run, and
    disagreement is a refusal rather than something to replace.
    """
    try:
        invocation = os.open(cinv, _DIR_FLAGS, dir_fd=execution_root.fd)
    except FileNotFoundError:
        invocation = None
    if invocation is not None:
        try:
            try:
                existing = _read_member(LAUNCH_AUTHORISATION_NAME, invocation)
            except FileNotFoundError:
                existing = None
        finally:
            os.close(invocation)
        if existing is not None:
            if existing != body:
                raise LaunchDisagreement(
                    f"the journalled launch-authorisation for {cinv} is not "
                    "the projection this authority requires")
            return

    mutation = Mutation(execution_root)
    target = MutationTarget(kind=TargetKind.LAUNCH_AUTHORISATION, name=cinv)
    cmut = mutation.begin(target, schema_type="launch-authorisation",
                          expected_sha256=hashlib.sha256(body).hexdigest())
    mutation.install(cmut, body)
    mutation.commit(cmut)


def authorise_launch(*, store: Any, execution_root: RootDescriptor,
                     handoff_root: RootDescriptor, authority_fd: int,
                     cinv: str, cimp: str, payload_fd: int,
                     package_entrypoint: str,
                     artefact_fd: int) -> LaunchReady:
    """Authorise one prepared invocation for launch, or refuse.

    The order is the ruled order and every step after the first is a function
    of the ones before it:

    validate the prepared invocation, derive the deterministic profile, derive
    the projection, commit the lifecycle transition, journal the projection,
    publish the handoff, verify the materialisation, and return.

    ``payload_fd`` is a descriptor on the payload as the caller holds it. It
    arrives as a descriptor for the same reason the package and the authority
    namespace do: this module reads governed material and never materialises
    a copy of anyone's bytes. The payload is re-presented rather than stored,
    and is checked against the digest the prepared record already committed to,
    so a different payload is a different binding and may not borrow this
    authorisation.
    """
    identity = _require_cinv(cinv)
    requested_cimp = _require_cimp(cimp)
    record = _prepared_invocation(store, identity)

    # The commitment, taken from the binding the preparation already made.
    commitment = commitment_digest(record.get("binding_digest"))

    # The payload, validated through the governed schema and then bound to what
    # was prepared. The two digests here are over the same logical payload under
    # two governed canonicalisations, each used only in its own domain -- the
    # invocation binding's, and the published handoff's. Neither is compared
    # with the other, because they answer different questions.
    payload_binding = validate_payload(payload_fd, schema_version=1)
    if invocation_payload_digest(payload_binding.document) \
            != record.get("payload_digest"):
        raise LaunchRefused(
            f"the presented payload is not the one {identity} was prepared with")

    package = validate_package(artefact_fd, entrypoint=package_entrypoint)

    # The profile, re-derived from the implementation authority the coordinator
    # can read and cannot write. Not read back from anywhere it could have been
    # influenced, and not carried across from preparation.
    authorised = authorise_implementation(
        authority_fd, cinv=identity, cimp=requested_cimp,
        payload_digest=payload_binding.digest, package_digest=package.digest,
        package_entrypoint=package.entrypoint)
    profile = authorised.profile
    profile_digest = fingerprint(profile).profile_digest

    body = canonical_json.serialise(launch_record(
        cinv=identity, cimp=authorised.cimp, profile_digest=profile_digest,
        commitment_digest=commitment))

    # --- authority ---------------------------------------------------------
    current = state_module.current_state(execution_root, identity)
    if current is None:
        capacity_module.reserve(execution_root, identity)
        state_module.transition(execution_root, identity,
                                LifecycleState.RESERVED,
                                LifecycleState.LAUNCH_AUTHORIZED)
        resumed = False
    elif current is LifecycleState.RESERVED:
        # Reserved and not yet authorised: the decision has not been made, so
        # making it now is the first run rather than a resume.
        state_module.transition(execution_root, identity,
                                LifecycleState.RESERVED,
                                LifecycleState.LAUNCH_AUTHORIZED)
        resumed = False
    elif current is LifecycleState.LAUNCH_AUTHORIZED:
        resumed = True
    else:
        raise LaunchRefused(
            f"{identity} is {current.value} and is no longer awaiting launch "
            "authorisation")

    # --- projection --------------------------------------------------------
    _commit_projection(execution_root, identity, body)

    # --- materialisation ---------------------------------------------------
    profile_bytes = _profile_bytes(profile)
    if _published_handoff(handoff_root, identity):
        _verify_handoff(handoff_root, identity,
                        payload_bytes=payload_binding.canonical_bytes,
                        profile_bytes=profile_bytes, package=package)
        binding = HandoffBinding(
            cinv=identity, package_digest=package.digest,
            payload_digest=payload_binding.digest,
            profile_digest=profile_digest, entrypoint=package.entrypoint,
            entry_count=package.entry_count)
    else:
        binding = publish_handoff(handoff_root, identity, artefact_fd,
                                  payload_binding, package, profile=profile)
        _verify_handoff(handoff_root, identity,
                        payload_bytes=payload_binding.canonical_bytes,
                        profile_bytes=profile_bytes, package=package)

    if binding.profile_digest != profile_digest:
        raise LaunchDisagreement(
            f"the published handoff for {identity} does not carry the "
            "authorised profile")

    return LaunchReady(cinv=identity, cimp=authorised.cimp,
                       profile_digest=profile_digest,
                       commitment_digest=commitment, handoff=binding,
                       resumed=resumed)


def _profile_bytes(profile: Any) -> bytes:
    from .profile import canonical_profile
    return canonical_profile(profile)


__all__ = ["HANDOFF_ROOT", "LAUNCH_RECORD_SCHEMA", "LIFECYCLE_STATE",
           "TRANSPORT_SCHEMA_VERSION", "LaunchDisagreement", "LaunchError",
           "LaunchReady", "LaunchRefused", "authorise_launch",
           "commitment_digest", "launch_record"]
