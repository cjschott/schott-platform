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

PROFILE_SCHEMA_VERSION = 2

# The runtime contracts this build implements. They live beside the policy they
# belong to rather than in the resolution layer, because the worker must check
# them too and a second copy is a second answer. `authorisation` re-exports
# these names so its callers are unaffected.
ADAPTER_IDENTITY = "python-podman-v1"
ARGV_CONTRACT_IDENTITY = "fixed-python-entrypoint-v1"

# The bound applied to canonical profile bytes before they are parsed. The
# governed profile is a fixed shape of a few hundred bytes; anything near this
# is already not the document it claims to be.
MAXIMUM_PROFILE_BYTES = 65536

NETWORK = "none"
HOSTNAME = "trackb"

# The governed CONTAINER identity, stated once and derived nowhere else.
#
# This is the identity the admitted image declares, and it is emphatically not
# the host execution identity: the worker runs as `kyri-capability` 999:987 and
# the workload runs as 65532:65532 inside. Conflating them is what the user
# namespace mapping exists to avoid.
#
# It was 1000:1000 until G11-AJ. That was true of the Track B alpine image and
# was never revisited when CIMP-000001 admitted a Chainguard image whose
# `User` is 65532:65532. The G5 ceremony has always checked the built image's
# default user as an admission contract (`IMAGE_EXPECT_USER`), but nothing tied
# that contract to this constant, so the two drifted while every layer inside
# the runtime went on agreeing with itself.
#
# `worker.CONTAINER_UID` is an alias of this rather than a second copy, and
# `tests/test-capability-execution-container-identity.sh` holds this value and
# the ceremony's contract together. Two constants that happen to be equal today
# are the mechanism that produced the defect, not a defence against it.
EXECUTION_UID = 65532
EXECUTION_GID = 65532

# The one mapping entry that proves the container identity really is the
# worker, rather than some subordinate id that merely shares its number.
#
# `Config.User` cannot prove this: it is an echo of what Podman was asked for
# and reads 65532:65532 even when no mapping exists and the workload cannot
# write its output. The uid/gid map is established by the kernel and is not
# determined by the request, which is what makes it evidence.
#
# `<id>:0:1` reads: container id `<id>` maps to host id 0 -- the invoking
# rootless user, i.e. the worker -- for a range of one.
def identity_mapping(container_id: int) -> str:
    """The map entry binding a container id to the invoking execution identity."""
    return f"{container_id}:0:1"

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


class ProfilePolicyViolation(ProfileError):
    """A profile field does not equal this build's governed value.

    Distinct from ``ProfileMismatch``, which is about a *container* disagreeing
    with a profile. This is about the profile itself carrying a value nobody
    was authorised to choose — authenticated bytes saying something the policy
    never said.
    """

    classification = Classification.EXECUTION_IDENTITY_MISMATCH


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
    payload_digest: str
    package_digest: str
    package_entrypoint: str


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
    # Deliberately no `profile_schema_version`. It is not a property of a
    # running container, so a backend could only obtain it from the profile --
    # and T8 comparing the profile with itself is not verification. It is
    # enforced where it can be: at profile parsing, in the fingerprint, by the
    # worker, and by the schema guard at the top of `verify_observed`.
    #
    # The identity mapping the runtime actually established. Reported so it can
    # be verified against the governed identity: this is the field that
    # distinguishes a container whose workload really is the worker from one
    # that was merely asked for the same number.
    uid_map: Any = None
    gid_map: Any = None


_HEX = frozenset("0123456789abcdef")


def _require_digest(value: Any, what: str) -> None:
    """Exactly 64 lowercase hexadecimal characters, or refuse.

    Lowercase is required rather than folded, for the same reason the launch
    record requires it: two spellings of one digest are two commitments.
    """
    if not isinstance(value, str) or len(value) != 64 or set(value) - _HEX:
        raise ProfileError(f"the {what} is not 64 lowercase hex characters")


def _require_entrypoint(value: Any) -> None:
    """One relative, traversal-free ``.py`` path, or refuse.

    The package contract already proved this against the tree it validated.
    Re-checking the *shape* here is not a second opinion about membership: it
    is the guarantee that whatever reaches the profile cannot be absolute, walk
    upward, or name something that is not Python source, whichever caller
    supplied it.
    """
    if not isinstance(value, str) or not value:
        raise ProfileError("the package entrypoint must be a relative path")
    if value.startswith("/"):
        raise ProfileError("the package entrypoint must not be absolute")
    if not value.endswith(".py"):
        raise ProfileError("the package entrypoint must be a .py file")
    if any(part in ("", ".", "..") for part in value.split("/")):
        raise ProfileError("the package entrypoint must be traversal-free")


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

    _require_digest(binding.payload_digest, "payload digest")
    _require_digest(binding.package_digest, "package digest")
    _require_entrypoint(binding.package_entrypoint)

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
        payload_digest=binding.payload_digest,
        package_digest=binding.package_digest,
        package_entrypoint=binding.package_entrypoint,
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
        "payload_digest": profile.payload_digest,
        "package_digest": profile.package_digest,
        "package_entrypoint": profile.package_entrypoint,
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
        "payload_digest", "package_digest", "package_entrypoint",
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
        payload_digest=_text(document, "payload_digest"),
        package_digest=_text(document, "package_digest"),
        package_entrypoint=_text(document, "package_entrypoint"),
    )

    if canonical_profile(profile) != bytes(data):
        raise ProfileNotCanonical(
            "the profile document is not the canonical form of what it decodes to")
    return profile


# Collections whose order carries no meaning. The canonical form sorts them,
# so a profile decoded from canonical bytes arrives in sorted order while the
# constant above is written in the order a human reads it. Comparing them as
# sequences would fail for a perfectly governed profile.
_UNORDERED = frozenset({"tmpfs_options", "dropped_capabilities", "devices",
                        "sockets", "mounts"})


def governed_policy() -> dict[str, Any]:
    """Every compiled-in control this build governs, by profile field name.

    **One source.** ``build_profile`` produces these values and the worker
    checks against these values; there is no second table anywhere. A field
    added to ``ExecutionProfile`` that belongs to policy and is not added here
    is caught by the coverage assertion in the gate suite rather than silently
    escaping verification.

    Identity and invocation commitments are deliberately absent: `CINV`,
    `CIMP`, the image, the contract identities, the schema version, and the
    payload/package commitments are not compiled-in policy and are verified by
    the checks that own them.
    """
    return {
        "network": NETWORK,
        "hostname": HOSTNAME,
        "execution_uid": EXECUTION_UID,
        "execution_gid": EXECUTION_GID,
        "memory_bytes": MEMORY_BYTES,
        "memory_swap_bytes": MEMORY_SWAP_BYTES,
        "cpus": CPUS,
        "cpu_quota_us": CPU_QUOTA_US,
        "cpu_period_us": CPU_PERIOD_US,
        "pids_limit": PIDS_LIMIT,
        "timeout_seconds": TIMEOUT_SECONDS,
        "grace_seconds": GRACE_SECONDS,
        "read_only_rootfs": True,
        "no_new_privileges": True,
        "cap_drop_all": True,
        "dropped_capabilities": DROPPED_CAPABILITIES,
        "tmpfs_bytes": TMPFS_BYTES,
        "tmpfs_mode": TMPFS_MODE,
        "tmpfs_options": TMPFS_OPTIONS,
        "mounts": (
            Mount(destination=PACKAGE_MOUNT, read_only=True, source_kind="bind"),
            Mount(destination=PAYLOAD_MOUNT, read_only=True, source_kind="bind"),
            Mount(destination=OUTPUT_MOUNT, read_only=False, source_kind="bind"),
        ),
        "devices": (),
        "sockets": (),
        "privileged": False,
        "host_network": False,
        "host_pid": False,
        "gpu": False,
    }


def verify_governed_policy(profile: ExecutionProfile) -> None:
    """Confirm every governed control is this build's value, or refuse.

    **This is the check the sealed transport cannot make.** Generation 5 proves
    the profile is exactly the bytes the coordinator committed to; it cannot
    prove those values were ever allowed, because the same party authored the
    digest. Here the values are re-derived from the constants this build
    compiled in and compared.

    **Nothing is repaired and nothing is normalised.** A profile carrying
    ``network: "host"`` is refused, not corrected to ``"none"`` and run —
    correcting it would execute something nobody authorised while reporting
    success, which is worse than either refusing or failing loudly.
    """
    if not isinstance(profile, ExecutionProfile):
        raise ProfileError("a built ExecutionProfile is required")
    differing: list[str] = []
    for field, expected in governed_policy().items():
        actual = getattr(profile, field)
        if field in _UNORDERED:
            if sorted(actual, key=repr) != sorted(expected, key=repr):
                differing.append(field)
        elif type(actual) is not type(expected) or actual != expected:
            differing.append(field)
    if differing:
        raise ProfilePolicyViolation(
            "the profile is not this build's governed policy at: "
            + ", ".join(sorted(differing)))


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

    # The identity mapping, which is the only part of the container identity
    # the request does not determine.
    #
    # `execution_uid` above compares the profile against `Config.User`, and
    # `Config.User` is an echo: Podman reports whatever it was asked for. In
    # the G11-AJ experiments it read 65532:65532 in all four configurations,
    # including the two where the workload could not write its output and the
    # one where no namespace mapping existed at all. Comparing it proves the
    # runtime received the request, not that the request took effect.
    #
    # The map is established by the kernel. Requiring the governed entry in
    # both directions is what makes the uid and gid checks above mean
    # something, and it is why a wrong gid mapping -- which still writes
    # successfully through a 0700 directory owned by the right uid -- is
    # caught here rather than passing silently.
    for field, expected_id in (("uid_map", profile.execution_uid),
                               ("gid_map", profile.execution_gid)):
        seen = getattr(observed, field)
        if not isinstance(seen, (list, tuple)) \
                or identity_mapping(expected_id) not in seen:
            differing.append(field)

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
