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
from .inspection import STATUS_NOT_FOUND, STATUS_REPORTED, inspect_records, validate_store
from .store import CapabilityStore

EXIT_SUCCESS = 0
EXIT_DENIED = 1
EXIT_USAGE = 2

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
        capability_package_id=args.package_id, invocation_id=args.invocation_id,
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
