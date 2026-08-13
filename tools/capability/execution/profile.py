"""The fixed, adapter-owned execution profile for the ENG-0005 first adapter.

**This module says what the sandbox must be. It never creates one.** No Podman,
no subprocess, no namespace, no mount, no filesystem — only values, a canonical
form, and an exact comparison.

**Metadata is refused, never ignored.** A capability asking for a different
network, image, mount, device, capability, or limit gets an error. Silently
dropping the request would make "asked and was denied" indistinguishable from
"never asked", and only one of those is safe to be wrong about. That is why
*any* metadata refuses, not merely the dangerous keys: a caller that sent
something believed it would take effect.

**Verification is exact, and expectation is not evidence.** A missing observed
field fails rather than being filled in from the profile — the whole point of
observing is to learn whether the runtime actually enforced the control, and
substituting what we wanted would answer the question with itself.

**Order is canonicalised only where it carries no meaning.** Capability sets,
device lists, and mount collections are compared as sets keyed by identity,
because a runtime may report them in any order. Nothing whose order matters is
sorted.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §12, §17.
"""

from __future__ import annotations

import dataclasses
import hashlib
from typing import Any, Mapping

from . import canonical_json
from .implementation_authority import Admission
from .types import Classification, ExecutionFingerprint, ExecutionProfile, Mount

PROFILE_SCHEMA_VERSION = 1

# The bound applied to canonical profile bytes before they are parsed. The
# governed profile is a fixed shape of a few hundred bytes; anything near this
# is already not the document it claims to be.
MAXIMUM_PROFILE_BYTES = 65536

NETWORK = "none"
HOSTNAME = "trackb"
EXECUTION_UID = 1000
EXECUTION_GID = 1000

MEMORY_BYTES = 256 * 1024 * 1024
MEMORY_SWAP_BYTES = 256 * 1024 * 1024
# The decimal string is what a runtime is told; the quota/period pair is what
# the kernel enforces. Both are carried so neither has to be re-derived, and
# neither is a float: 0.5 has no exact binary representation and a profile
# comparison must never turn on rounding.
CPUS = "0.5"
CPU_QUOTA_US = 50000
CPU_PERIOD_US = 100000
PIDS_LIMIT = 64
TIMEOUT_SECONDS = 30
GRACE_SECONDS = 2

TMPFS_BYTES = 16 * 1024 * 1024
TMPFS_MODE = 0o1777
TMPFS_OPTIONS = ("noexec", "nosuid", "nodev")

PACKAGE_MOUNT = "/kyri/package"
PAYLOAD_MOUNT = "/run/kyri/input/payload"
OUTPUT_MOUNT = "/kyri/output"

DROPPED_CAPABILITIES = ("ALL",)

# Every governed control, by the name a caller might use to ask for it. Used
# only to make refusal messages name the offending key.
_GOVERNED_KEYS = frozenset({
    "network", "memory", "memory_bytes", "memory_swap", "cpus", "cpu",
    "cpu_quota_us", "cpu_period_us", "pids_limit", "pids", "privileged",
    "devices", "device", "gpu", "cap_add", "cap_drop", "capabilities",
    "mounts", "mount", "volumes", "image", "oci_image_id", "user", "uid", "gid",
    "hostname", "read_only", "read_only_rootfs", "security_opt",
    "no_new_privileges", "timeout_seconds", "grace_seconds", "tmpfs",
    "sockets", "host_network", "host_pid",
})


class ProfileError(ValueError):
    """Base for every refusal this module makes."""

    classification: Classification | None = None


class MetadataOverrideRefused(ProfileError):
    """Capability metadata tried to influence the governed profile."""


class UnsupportedProfileSchema(ProfileError):
    """A profile schema version this build does not implement."""

    classification = Classification.EXECUTION_PROFILE_VERSION_UNSUPPORTED


class ProfileNotCanonical(ProfileError):
    """Bytes that are not the exact canonical form of the profile they decode to.

    Separate from a malformed document on purpose: the digest is taken over
    canonical bytes, so a document that parses but re-serialises differently is
    one whose identity nobody can agree on — and accepting it would let two
    spellings of the same profile carry two different commitments.
    """


class ProfileMismatch(ProfileError):
    """The observed runtime configuration is not the governed profile."""

    classification = Classification.EXECUTION_IDENTITY_MISMATCH

    def __init__(self, differing_fields: tuple[str, ...]) -> None:
        super().__init__(
            "observed execution profile differs in: "
            + ", ".join(differing_fields))
        self.differing_fields = differing_fields


@dataclasses.dataclass(frozen=True)
class ProfileBinding:
    """The governed identities a profile is built for.

    Carries identity only. Nothing here can change a security control; a
    different `CIMP` or image digest produces a different expected profile, not
    a differently configured sandbox.
    """

    cinv: str
    admission: Admission


@dataclasses.dataclass(frozen=True)
class ObservedProfile:
    """What a runtime was independently seen to have configured.

    Every field is optional in the sense that it may arrive as ``None`` — and
    ``None`` always fails. Absence is reported so it can be refused, not so it
    can be defaulted.
    """

    oci_image_id: Any
    network: Any
    read_only_rootfs: Any
    no_new_privileges: Any
    dropped_capabilities: Any
    effective_capabilities: Any
    memory_bytes: Any
    memory_swap_bytes: Any
    cpu_quota_us: Any
    cpu_period_us: Any
    pids_limit: Any
    execution_uid: Any
    execution_gid: Any
    hostname: Any
    mounts: Any
    devices: Any
    sockets: Any
    tmpfs_bytes: Any
    tmpfs_mode: Any
    tmpfs_options: Any
    profile_schema_version: Any


def build_profile(binding: ProfileBinding,
                  metadata: Mapping[str, Any] | None = None) -> ExecutionProfile:
    """The governed profile for ``binding``, or refuse.

    ``metadata`` exists so that an attempt to influence the profile is an
    error. It is never merged, filtered, or partially honoured.
    """
    if not isinstance(binding, ProfileBinding):
        raise ProfileError("binding must be a ProfileBinding")
    if metadata:
        offending = sorted(metadata)
        governed = [key for key in offending if key in _GOVERNED_KEYS]
        named = governed[0] if governed else offending[0]
        raise MetadataOverrideRefused(
            f"capability metadata may not influence the execution profile "
            f"(refused at {named!r})")

    admission = binding.admission
    if admission.execution_profile_schema_version != PROFILE_SCHEMA_VERSION:
        raise UnsupportedProfileSchema(
            f"admission declares profile schema "
            f"{admission.execution_profile_schema_version}, and this build "
            f"implements only {PROFILE_SCHEMA_VERSION}")

    return ExecutionProfile(
        cinv=binding.cinv,
        oci_image_id=admission.oci_image_id,
        network=NETWORK,
        memory_bytes=MEMORY_BYTES,
        memory_swap_bytes=MEMORY_SWAP_BYTES,
        cpus=CPUS,
        pids_limit=PIDS_LIMIT,
        timeout_seconds=TIMEOUT_SECONDS,
        grace_seconds=GRACE_SECONDS,
        read_only_rootfs=True,
        no_new_privileges=True,
        cap_drop_all=True,
        tmpfs_bytes=TMPFS_BYTES,
        profile_schema_version=PROFILE_SCHEMA_VERSION,
        cimp=admission.cimp,
        adapter_identity=admission.adapter_identity,
        payload_schema_version=admission.payload_schema_version,
        execution_uid=EXECUTION_UID,
        execution_gid=EXECUTION_GID,
        hostname=HOSTNAME,
        cpu_quota_us=CPU_QUOTA_US,
        cpu_period_us=CPU_PERIOD_US,
        tmpfs_mode=TMPFS_MODE,
        tmpfs_options=TMPFS_OPTIONS,
        dropped_capabilities=DROPPED_CAPABILITIES,
        mounts=(
            Mount(destination=PACKAGE_MOUNT, read_only=True, source_kind="bind"),
            Mount(destination=PAYLOAD_MOUNT, read_only=True, source_kind="bind"),
            Mount(destination=OUTPUT_MOUNT, read_only=False, source_kind="bind"),
        ),
        devices=(),
        sockets=(),
        privileged=False,
        host_network=False,
        host_pid=False,
        gpu=False,
    )


def _mount_form(mounts: Any) -> list[dict[str, Any]]:
    return [
        {"destination": m.destination, "read_only": m.read_only,
         "source_kind": m.source_kind}
        for m in sorted(mounts, key=lambda m: m.destination)
    ]


def canonical_profile(profile: ExecutionProfile) -> bytes:
    """The canonical bytes a profile digest is taken over.

    Built from an explicit field list rather than from ``dataclasses.asdict``
    so that adding a field to the type cannot silently join the digest, and
    from canonical JSON rather than any Python repr so the bytes do not depend
    on formatting, dict ordering, or interpreter version.
    """
    return canonical_json.serialise({
        "schema": profile.profile_schema_version,
        "cinv": profile.cinv,
        "adapter_identity": profile.adapter_identity,
        "cimp": profile.cimp,
        "oci_image_id": profile.oci_image_id,
        "payload_schema_version": profile.payload_schema_version,
        "network": profile.network,
        "read_only_rootfs": profile.read_only_rootfs,
        "no_new_privileges": profile.no_new_privileges,
        "cap_drop_all": profile.cap_drop_all,
        "dropped_capabilities": sorted(profile.dropped_capabilities),
        "privileged": profile.privileged,
        "host_network": profile.host_network,
        "host_pid": profile.host_pid,
        "gpu": profile.gpu,
        "memory_bytes": profile.memory_bytes,
        "memory_swap_bytes": profile.memory_swap_bytes,
        "cpus": profile.cpus,
        "cpu_quota_us": profile.cpu_quota_us,
        "cpu_period_us": profile.cpu_period_us,
        "pids_limit": profile.pids_limit,
        "timeout_seconds": profile.timeout_seconds,
        "grace_seconds": profile.grace_seconds,
        "execution_uid": profile.execution_uid,
        "execution_gid": profile.execution_gid,
        "hostname": profile.hostname,
        "tmpfs_bytes": profile.tmpfs_bytes,
        "tmpfs_mode": profile.tmpfs_mode,
        "tmpfs_options": sorted(profile.tmpfs_options),
        "mounts": _mount_form(profile.mounts),
        "devices": sorted(profile.devices),
        "sockets": sorted(profile.sockets),
    })


def _text(document: Mapping[str, Any], key: str) -> str:
    value = document[key]
    if not isinstance(value, str) or not value:
        raise ProfileError(f"the profile field {key!r} is not text")
    return value


def _number(document: Mapping[str, Any], key: str) -> int:
    value = document[key]
    if not isinstance(value, int) or isinstance(value, bool):
        raise ProfileError(f"the profile field {key!r} is not an integer")
    return value


def _flag(document: Mapping[str, Any], key: str) -> bool:
    value = document[key]
    if not isinstance(value, bool):
        raise ProfileError(f"the profile field {key!r} is not a boolean")
    return value


def _words(document: Mapping[str, Any], key: str) -> tuple[str, ...]:
    value = document[key]
    if not isinstance(value, list) or not all(
            isinstance(item, str) and item for item in value):
        raise ProfileError(f"the profile field {key!r} is not a list of text")
    return tuple(value)


def _mounts(document: Mapping[str, Any]) -> tuple[Mount, ...]:
    value = document["mounts"]
    if not isinstance(value, list):
        raise ProfileError("the profile mounts are not a list")
    built: list[Mount] = []
    for item in value:
        if not isinstance(item, dict) or set(item) != {
                "destination", "read_only", "source_kind"}:
            raise ProfileError("a profile mount has the wrong shape")
        if not isinstance(item["destination"], str) \
                or not isinstance(item["source_kind"], str) \
                or not isinstance(item["read_only"], bool):
            raise ProfileError("a profile mount has a wrongly typed field")
        built.append(Mount(destination=item["destination"],
                           read_only=item["read_only"],
                           source_kind=item["source_kind"]))
    return tuple(built)


def parse_canonical_profile(data: bytes) -> ExecutionProfile:
    """The profile ``data`` is the canonical form of, or refuse.

    The inverse of ``canonical_profile`` and deliberately nothing more. It
    accepts no partial document, fills in no absent field, and coerces no type
    — every value comes from the bytes or the bytes are refused.

    The last check is the one that matters: the decoded profile is
    re-serialised and required to be **byte-identical** to the input. That is
    what makes the digest meaningful across the privilege boundary. Without it
    a document could parse to the right values while its bytes committed to
    something else, and the reader would have verified a digest over one
    document while acting on another.
    """
    try:
        document = canonical_json.parse(data, maximum_bytes=MAXIMUM_PROFILE_BYTES)
    except canonical_json.CanonicalJSONError as error:
        # Re-raised in this module's vocabulary rather than propagated. A
        # caller holding a profile refusal must not have to know which encoder
        # this module happens to use to catch "these bytes are not a profile".
        raise ProfileError(f"the profile document is not canonical JSON: {error}") from None

    expected = {
        "schema", "cinv", "adapter_identity", "cimp", "oci_image_id",
        "payload_schema_version", "network", "read_only_rootfs",
        "no_new_privileges", "cap_drop_all", "dropped_capabilities",
        "privileged", "host_network", "host_pid", "gpu", "memory_bytes",
        "memory_swap_bytes", "cpus", "cpu_quota_us", "cpu_period_us",
        "pids_limit", "timeout_seconds", "grace_seconds", "execution_uid",
        "execution_gid", "hostname", "tmpfs_bytes", "tmpfs_mode",
        "tmpfs_options", "mounts", "devices", "sockets",
    }
    if set(document) != expected:
        missing = sorted(expected - set(document))
        unknown = sorted(set(document) - expected)
        raise ProfileError(
            f"the profile document is not the governed field set "
            f"(missing {missing}, unknown {unknown})")

    version = _number(document, "schema")
    if version != PROFILE_SCHEMA_VERSION:
        raise UnsupportedProfileSchema(
            f"no reader for profile schema {version}, and this build "
            f"implements only {PROFILE_SCHEMA_VERSION}")

    profile = ExecutionProfile(
        cinv=_text(document, "cinv"),
        oci_image_id=_text(document, "oci_image_id"),
        network=_text(document, "network"),
        memory_bytes=_number(document, "memory_bytes"),
        memory_swap_bytes=_number(document, "memory_swap_bytes"),
        cpus=_text(document, "cpus"),
        pids_limit=_number(document, "pids_limit"),
        timeout_seconds=_number(document, "timeout_seconds"),
        grace_seconds=_number(document, "grace_seconds"),
        read_only_rootfs=_flag(document, "read_only_rootfs"),
        no_new_privileges=_flag(document, "no_new_privileges"),
        cap_drop_all=_flag(document, "cap_drop_all"),
        tmpfs_bytes=_number(document, "tmpfs_bytes"),
        profile_schema_version=version,
        cimp=_text(document, "cimp"),
        adapter_identity=_text(document, "adapter_identity"),
        payload_schema_version=_number(document, "payload_schema_version"),
        execution_uid=_number(document, "execution_uid"),
        execution_gid=_number(document, "execution_gid"),
        hostname=_text(document, "hostname"),
        cpu_quota_us=_number(document, "cpu_quota_us"),
        cpu_period_us=_number(document, "cpu_period_us"),
        tmpfs_mode=_number(document, "tmpfs_mode"),
        tmpfs_options=_words(document, "tmpfs_options"),
        dropped_capabilities=_words(document, "dropped_capabilities"),
        mounts=_mounts(document),
        devices=_words(document, "devices"),
        sockets=_words(document, "sockets"),
        privileged=_flag(document, "privileged"),
        host_network=_flag(document, "host_network"),
        host_pid=_flag(document, "host_pid"),
        gpu=_flag(document, "gpu"),
    )

    if canonical_profile(profile) != bytes(data):
        raise ProfileNotCanonical(
            "the profile document is not the canonical form of what it decodes to")
    return profile


def fingerprint(profile: ExecutionProfile) -> ExecutionFingerprint:
    """The identity an observed container must match.

    Carries the canonical digest *and* the explicit fields, because a digest
    alone can only say that something differs, and a reconciliation needs to
    say what.
    """
    return ExecutionFingerprint(
        cinv=profile.cinv,
        profile_digest=hashlib.sha256(canonical_profile(profile)).hexdigest(),
        oci_image_id=profile.oci_image_id,
        cimp=profile.cimp,
        adapter_identity=profile.adapter_identity,
        profile_schema_version=profile.profile_schema_version,
        execution_uid=profile.execution_uid,
        execution_gid=profile.execution_gid,
    )


def verify_observed(profile: ExecutionProfile,
                    observed: ObservedProfile) -> None:
    """Confirm ``observed`` is exactly ``profile``, or refuse.

    Every difference is collected before raising so a reconciliation sees the
    whole picture rather than the first thing that happened to be checked.
    """
    if profile.profile_schema_version != PROFILE_SCHEMA_VERSION:
        raise UnsupportedProfileSchema(
            f"no verifier for profile schema {profile.profile_schema_version}")
    if not isinstance(observed, ObservedProfile):
        raise ProfileError("observed must be an ObservedProfile")

    differing: list[str] = []

    def compare(field: str, expected: Any, seen: Any) -> None:
        if seen is None or seen != expected:
            differing.append(field)

    compare("oci_image_id", profile.oci_image_id, observed.oci_image_id)
    compare("network", profile.network, observed.network)
    compare("read_only_rootfs", profile.read_only_rootfs,
            observed.read_only_rootfs)
    compare("no_new_privileges", profile.no_new_privileges,
            observed.no_new_privileges)
    compare("memory_bytes", profile.memory_bytes, observed.memory_bytes)
    compare("memory_swap_bytes", profile.memory_swap_bytes,
            observed.memory_swap_bytes)
    compare("cpu_quota_us", profile.cpu_quota_us, observed.cpu_quota_us)
    compare("cpu_period_us", profile.cpu_period_us, observed.cpu_period_us)
    compare("pids_limit", profile.pids_limit, observed.pids_limit)
    compare("execution_uid", profile.execution_uid, observed.execution_uid)
    compare("execution_gid", profile.execution_gid, observed.execution_gid)
    compare("hostname", profile.hostname, observed.hostname)
    compare("tmpfs_bytes", profile.tmpfs_bytes, observed.tmpfs_bytes)
    compare("tmpfs_mode", profile.tmpfs_mode, observed.tmpfs_mode)
    compare("profile_schema_version", profile.profile_schema_version,
            observed.profile_schema_version)

    # Order-independent collections, compared as sets.
    for field, expected in (
            ("dropped_capabilities", profile.dropped_capabilities),
            ("tmpfs_options", profile.tmpfs_options),
            ("devices", profile.devices),
            ("sockets", profile.sockets)):
        seen = getattr(observed, field)
        if seen is None or sorted(seen) != sorted(expected):
            differing.append(field)

    # Any effective capability at all contradicts cap-drop ALL.
    if observed.effective_capabilities is None \
            or tuple(observed.effective_capabilities) != ():
        differing.append("effective_capabilities")

    if observed.mounts is None:
        differing.append("mounts")
    else:
        try:
            if _mount_form(observed.mounts) != _mount_form(profile.mounts):
                differing.append("mounts")
        except AttributeError:
            differing.append("mounts")

    if differing:
        raise ProfileMismatch(tuple(differing))
