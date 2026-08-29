"""Command line interface for the Capability Runtime.

Three operations, and nothing more. `invoke` carries one governed selection
through preparation and stops; `inspect` and `validate` read. **There is no
execution verb and no flag that could become one** — the commands that would
run a capability do not exist, and neither does the mechanism they would call.

**Nothing authority-bearing is inferred.** Every root, every expected owner,
the actor, the identity, the instant: supplied explicitly, or refused. No
default store root, no environment value, no home directory, no current user,
no clock, and no generated identity. A default is a decision nobody recorded
making.

**The payload arrives as a file inside an approved payload directory**, opened
through the reviewed descriptor-safe primitive and read from that descriptor.
That directory bounds and safely reads caller input; it establishes nothing
about the payload's meaning. Authority comes from canonicalising the logical
value and binding its digest to the invocation — not from where the file sat.

**Duplicate object keys refuse.** A permissive parser silently keeps the last
one, so `{"a":1,"a":2}` would quietly become a different payload than it looks
like and then receive a perfectly valid digest. Two exit codes separate the
kinds of failure: 2 means the request was unusable, 1 means it was understood
and the answer is no.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

from ..common.trusted_source import (TrustedSourceError,
                                     open_trusted_regular_file)
from .coordinator import prepare_invocation
from .errors import CapabilityError
from .execution.backing_store import (BackingStoreError, ObservedFilesystem,
                                      verify_backing_store)
from .execution.launch import HANDOFF_ROOT, LaunchError, authorise_launch
from .inspection import STATUS_NOT_FOUND, STATUS_REPORTED, inspect_records, validate_store
from .store import CapabilityStore

EXIT_SUCCESS = 0
EXIT_DENIED = 1
EXIT_USAGE = 2

# The normative host layout, compiled in rather than offered as arguments.
#
# This is not the "no default store root" rule being bent. A default is a value
# the caller could have supplied and did not, so the code picked one; these are
# values the caller *cannot* supply at all, which is the stronger statement and
# the one the rest of the execution plane already makes. The privileged
# transition compiles in the same two roots on its side, so the ceremony and the
# boundary that consumes it agree by construction rather than by an operator
# keeping two flags consistent.
#
# `invoke`, `inspect` and `validate` still take an explicit `--store-root`:
# those verbs legitimately run against a store an operator chose. This one
# produces material root will later read from one fixed place, so choosing
# another place could only produce a ceremony nothing consumes.
#
# The two `prod-path-reference` markers below are the repository's own
# mechanism for a line that legitimately names a production path. These are not
# defaults -- nothing here creates either path, and no argument can override
# them; both are read-only inputs this verb refuses to run without.
CAPABILITY_RUNTIME_ROOT = "/data/kyri/capability-runtime"
AUTHORITY_ROOT = "/var/lib/kyri/implementation-authority"   # prod-path-reference
BACKING_STORE_CONFIG = "/etc/kyri/backing-store.json"       # prod-path-reference

# Read from the bridge so the two can never disagree about what it spells.
from .execution.launch import LIFECYCLE_STATE as LAUNCH_AUTHORIZED_STATE

_MOUNTINFO = "/proc/self/mountinfo"
_BY_UUID = "/dev/disk/by-uuid"
_DIR_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY

# Invocation input is structured control content, not bulk artefact content.
# Anything large belongs behind a governed package reference.
PAYLOAD_MAXIMUM_BYTES = 1048576


class _Unusable(Exception):
    """The request could not be carried out as stated. Exit code 2."""


class _DuplicateKey(ValueError):
    """One JSON object carried the same key twice."""


def _no_duplicates(pairs):
    """A JSON object, refusing a repeated key at any depth.

    The hook fires for every object, so nesting is covered without walking the
    result afterwards.
    """
    seen = {}
    for key, value in pairs:
        if key in seen:
            raise _DuplicateKey(f"duplicate object key '{key}'")
        seen[key] = value
    return seen


def _emit(payload: Any) -> None:
    """Deterministic JSON on stdout. Diagnostics never go here."""
    print(json.dumps(payload, indent=2, sort_keys=True, default=str))


def _instant(value: Any, name: str) -> datetime:
    if not isinstance(value, str):
        raise _Unusable(f"{name} must be supplied as a timestamp")
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        raise _Unusable(f"{name} is not a readable timestamp") from None
    if parsed.tzinfo is None or parsed.tzinfo.utcoffset(parsed) is None:
        raise _Unusable(f"{name} must carry a timezone offset")
    return parsed


def _payload(approved_payload_root: Any, name: Any, payload_source_uid: Any) -> Any:
    """One logical payload, from bytes read through one descriptor."""
    try:
        handle = open_trusted_regular_file(
            approved_payload_root, name, expected_uid=payload_source_uid,
            require_single_link=True, maximum_bytes=PAYLOAD_MAXIMUM_BYTES,
            refuse_oversize=True)
    except TrustedSourceError as error:
        raise _Unusable(f"the payload file could not be read ({error})") from None

    chunks: list[bytes] = []
    total = 0
    try:
        while True:
            chunk = os.read(handle, 65536)
            if not chunk:
                break
            total += len(chunk)
            if total > PAYLOAD_MAXIMUM_BYTES:
                raise _Unusable("the payload exceeds its bound")
            chunks.append(chunk)
    except OSError:
        raise _Unusable("the payload file could not be read") from None
    finally:
        os.close(handle)

    try:
        text = b"".join(chunks).decode("utf-8")
    except UnicodeDecodeError:
        raise _Unusable("the payload is not valid UTF-8") from None

    decoder = json.JSONDecoder(object_pairs_hook=_no_duplicates)
    try:
        value, consumed = decoder.raw_decode(text.lstrip())
    except _DuplicateKey as error:
        raise _Unusable(f"the payload carries a {error}") from None
    except ValueError:
        raise _Unusable("the payload is not one valid JSON value") from None
    # Exactly one document: trailing content is a second payload nobody asked
    # about, and silently ignoring it hides which one was bound.
    if text.lstrip()[consumed:].strip():
        raise _Unusable("the payload carries more than one JSON value")
    return value


def _runtime_store(args) -> CapabilityStore:
    try:
        return CapabilityStore(args.store_root, expected_uid=args.expected_uid,
                               expected_gid=args.expected_gid)
    except CapabilityError as error:
        raise _Unusable(f"the capability runtime store is unusable ({error})") from None


def command_invoke(args) -> int:
    """One governed invocation, prepared and then stopped."""
    payload = _payload(args.approved_payload_root, args.payload_file,
                       args.payload_source_uid)
    requested_at = _instant(args.requested_at, "--requested-at")
    store = _runtime_store(args)
    decision = prepare_invocation(
        store, fabric_root=args.fabric_root,
        fabric_expected_uid=args.fabric_expected_uid,
        fabric_expected_gid=args.fabric_expected_gid,
        approved_artifact_root=args.approved_artifact_root,
        trusted_source_uid=args.trusted_source_uid,
        staging_root=args.staging_root, coordinator_uid=args.coordinator_uid,
        selection_id=args.selection_id, instance_id=args.instance_id,
        capability_package_id=args.package_id, operation=args.operation,
        invocation_id=args.invocation_id,
        payload=payload, actor=args.actor, request_id=args.request_id,
        requested_at=requested_at)
    _emit({
        "status": decision.status, "reason": decision.reason,
        "invocation_id": decision.invocation_id,
        "invocation_record_id": decision.invocation_record_id,
        "result_record_id": decision.result_record_id,
        "binding_digest": decision.binding_digest,
        "payload_digest": decision.payload_digest,
        "artifact_digest": decision.artifact_digest,
        "staged_path": decision.staged_path,
    })
    # Every outcome reachable here is a governed negative: a preparation that
    # cannot proceed, a refusal, a replay, or a conflict.
    return EXIT_DENIED


def _observed_filesystem(path: str) -> ObservedFilesystem:
    """The host facts about the filesystem under ``path``, observed here.

    `verify_backing_store` cannot obtain a filesystem UUID from a descriptor —
    the kernel offers no such call — so the caller observes and it compares.
    Observation is this layer's authority and nothing more: every value below is
    read from the kernel, and any disagreement with the provisioned
    configuration is that module's refusal to make, not this one's.
    """
    target = os.path.realpath(path)
    best = ("", "", "")
    try:
        with open(_MOUNTINFO, "r", encoding="utf-8") as handle:
            for line in handle:
                fields = line.split()
                if "-" not in fields:
                    continue
                separator = fields.index("-")
                mount_point = fields[4]
                # The longest mount point that is a prefix of the target is the
                # filesystem the target actually sits on.
                if target == mount_point or target.startswith(
                        mount_point.rstrip("/") + "/"):
                    if len(mount_point) >= len(best[0]):
                        best = (mount_point, fields[separator + 1],
                                fields[separator + 2])
    except OSError:
        raise _Unusable("the mount table could not be read") from None
    if not best[0]:
        raise _Unusable(f"no mounted filesystem carries {path}")

    mount_point, filesystem_type, device_name = best
    uuid = ""
    try:
        for entry in os.listdir(_BY_UUID):
            if os.path.realpath(os.path.join(_BY_UUID, entry)) == \
                    os.path.realpath(device_name):
                uuid = entry
                break
    except OSError:
        uuid = ""
    return ObservedFilesystem(filesystem_uuid=uuid,
                              filesystem_type=filesystem_type,
                              mount_point=mount_point,
                              device_name=device_name)


def _anchored(root: str):
    """A verified root descriptor over ``root``, or refuse.

    The provisioned backing-store configuration is the authority; this opens it
    and the root no-follow and hands both to the governed verifier.
    """
    try:
        config = os.open(BACKING_STORE_CONFIG,
                         os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as error:
        raise _Unusable(
            f"the backing-store configuration is unusable ({error.strerror})") from None
    try:
        try:
            handle = os.open(root, _DIR_FLAGS)
        except OSError as error:
            raise _Unusable(f"{root} is unusable ({error.strerror})") from None
        try:
            return verify_backing_store(
                config, handle, observed=_observed_filesystem(root))
        except BackingStoreError as error:
            raise _Unusable(f"the backing store does not verify ({error})") from None
        finally:
            os.close(handle)
    finally:
        os.close(config)


def command_authorise_launch(args) -> int:
    """Carry one prepared invocation to a verifiable handoff, and stop.

    Every judgement belongs to the Generation-8 bridge: eligibility, the
    profile, the commitment, the lifecycle transition, the journalled
    projection, the handoff, and what a repeat means. This opens the ruled
    roots, hands them over, and reports what came back.

    The package tree is taken from the prepared invocation's own durable
    record rather than from an argument. An operator able to name it would be
    an operator able to name a different one, and the invocation already says
    which tree it staged.
    """
    try:
        store = CapabilityStore(CAPABILITY_RUNTIME_ROOT,
                                expected_uid=args.expected_uid,
                                expected_gid=args.expected_gid)
    except CapabilityError as error:
        raise _Unusable(
            f"the capability runtime store is unusable ({error})") from None
    try:
        record = store.read_record("capability-invocation", args.cinv)
    except CapabilityError as error:
        print(f"capability: {error}", file=sys.stderr)
        return EXIT_DENIED
    staged = record.get("staged_path")
    if not isinstance(staged, str) or not staged:
        print(f"capability: {args.cinv} carries no staged package",
              file=sys.stderr)
        return EXIT_DENIED

    try:
        payload = open_trusted_regular_file(
            args.approved_payload_root, args.payload_file,
            expected_uid=args.expected_uid, require_single_link=True,
            maximum_bytes=PAYLOAD_MAXIMUM_BYTES, refuse_oversize=True)
    except TrustedSourceError as error:
        raise _Unusable(f"the payload file could not be read ({error})") from None

    execution_root = handoff_root = None
    artefact = -1
    try:
        try:
            artefact = os.open(staged, _DIR_FLAGS)
        except OSError as error:
            raise _Unusable(
                f"the staged package is unusable ({error.strerror})") from None
        execution_root = _anchored(os.path.join(CAPABILITY_RUNTIME_ROOT,
                                                "execution"))
        handoff_root = _anchored(HANDOFF_ROOT)
        try:
            authority = os.open(AUTHORITY_ROOT, _DIR_FLAGS)
        except OSError as error:
            raise _Unusable(
                f"the authority namespace is unusable ({error.strerror})") from None
        try:
            ready = authorise_launch(
                store=store, execution_root=execution_root,
                handoff_root=handoff_root, authority_fd=authority,
                cinv=args.cinv, cimp=args.cimp, payload_fd=payload,
                package_entrypoint=args.package_entrypoint,
                artefact_fd=artefact)
        finally:
            os.close(authority)
    except ValueError as error:
        # Every governed refusal in the execution plane subclasses ValueError:
        # LaunchError, PackageError, PayloadError, ProfileError,
        # ImplementationAuthorityError, ExecutionStateError, CapabilityError.
        # Rendering the base rather than a list of them means a refusal added
        # later arrives here as a clean denial instead of a traceback, which is
        # the failure direction an operator surface should prefer. The cost is
        # that a genuine ValueError bug would also read as a denial; the
        # message is printed verbatim so it is still identifiable.
        print(f"capability: {type(error).__name__}: {error}", file=sys.stderr)
        return EXIT_DENIED
    finally:
        os.close(payload)
        if artefact != -1:
            os.close(artefact)
        for anchor in (execution_root, handoff_root):
            if anchor is not None:
                anchor.close()

    # Identifiers and digests only. What the invocation carries is not this
    # command's to publish.
    _emit({
        "cinv": ready.cinv,
        "cimp": ready.cimp,
        "lifecycle_state": LAUNCH_AUTHORIZED_STATE,
        "profile_digest": ready.profile_digest,
        "commitment_digest": ready.commitment_digest,
        "package_digest": ready.handoff.package_digest,
        "payload_digest": ready.handoff.payload_digest,
        "handoff_published": True,
        "resumed": ready.resumed,
    })
    return EXIT_SUCCESS


def command_inspect(args) -> int:
    """Records as stored, in a canonical order."""
    store = _runtime_store(args)
    try:
        report = inspect_records(store, kind=args.kind, identifier=args.identifier)
    except CapabilityError as error:
        raise _Unusable(str(error)) from None
    _emit({"status": report.status, "records": list(report.records),
           "findings": list(report.findings)})
    return EXIT_SUCCESS if report.status == STATUS_REPORTED else EXIT_DENIED


def command_validate(args) -> int:
    """Findings, and nothing repaired."""
    store = _runtime_store(args)
    report = validate_store(store)
    _emit({"status": report.status, "findings": list(report.findings)})
    sound = report.status == STATUS_REPORTED and not report.findings
    return EXIT_SUCCESS if sound else EXIT_DENIED


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="capability",
        description="Prepare and inspect governed capability invocations. "
                    "Nothing here executes a capability.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    def with_store(sub):
        sub.add_argument("--store-root", required=True)
        sub.add_argument("--expected-uid", required=True, type=int)
        sub.add_argument("--expected-gid", required=True, type=int)
        return sub

    invoke = with_store(subparsers.add_parser("invoke"))
    invoke.add_argument("--fabric-root", required=True)
    invoke.add_argument("--fabric-expected-uid", required=True, type=int)
    invoke.add_argument("--fabric-expected-gid", required=True, type=int)
    invoke.add_argument("--approved-artifact-root", required=True)
    invoke.add_argument("--trusted-source-uid", required=True, type=int)
    invoke.add_argument("--staging-root", required=True)
    invoke.add_argument("--coordinator-uid", required=True, type=int)
    invoke.add_argument("--approved-payload-root", required=True)
    invoke.add_argument("--payload-source-uid", required=True, type=int)
    invoke.add_argument("--payload-file", required=True,
                        help="file name inside the approved payload directory")
    invoke.add_argument("--invocation-id", required=True)
    invoke.add_argument("--selection-id", required=True)
    invoke.add_argument("--instance-id", required=True)
    invoke.add_argument("--package-id", required=True)
    # Required, and never defaulted. A selection names a binding; it does not
    # name an action, so the action is named here or the invocation is refused.
    invoke.add_argument("--operation", required=True)
    invoke.add_argument("--actor", required=True)
    invoke.add_argument("--request-id", required=True)
    invoke.add_argument("--requested-at", required=True)
    invoke.set_defaults(handler=command_invoke)

    look = with_store(subparsers.add_parser("inspect"))
    look.add_argument("--kind", default=None)
    look.add_argument("--identifier", default=None)
    look.set_defaults(handler=command_inspect)

    sound = with_store(subparsers.add_parser("validate"))
    sound.set_defaults(handler=command_validate)

    # The S5 operator surface. No root is an argument: every one is compiled in
    # above, and the staged package comes from the invocation's own record.
    launch = subparsers.add_parser("authorise-launch")
    launch.add_argument("--expected-uid", required=True, type=int)
    launch.add_argument("--expected-gid", required=True, type=int)
    launch.add_argument("--cinv", required=True)
    launch.add_argument("--cimp", required=True)
    launch.add_argument("--approved-payload-root", required=True)
    launch.add_argument("--payload-file", required=True,
                        help="file name inside the approved payload directory")
    launch.add_argument("--package-entrypoint", required=True)
    launch.set_defaults(handler=command_authorise_launch)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as error:
        # argparse exits 2 for a usage problem and 0 for --help; both are
        # interface outcomes rather than governed ones.
        return EXIT_USAGE if error.code not in (0, None) else EXIT_SUCCESS
    try:
        return args.handler(args)
    except _Unusable as error:
        print(f"capability: {error}", file=sys.stderr)
        return EXIT_USAGE
    except CapabilityError as error:
        print(f"capability: {error}", file=sys.stderr)
        return EXIT_USAGE


if __name__ == "__main__":
    raise SystemExit(main())
