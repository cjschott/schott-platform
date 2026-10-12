"""Command line interface for the Fabric runtime.

The twelve §8 operations, reachable and nothing more. This parses, checks
containment, and hands the governed inputs to the component that owns them. It
resolves no reference, composes no scope, judges no eligibility, chooses no
candidate, and reads no trust standing of its own: a second policy engine at
the edge is how the boundary moves onto whoever typed the command.

What it refuses is the interesting part. There is no execution verb, and no
flag could be added to make one -- the commands that would run a capability do
not exist. There is no way to pass an approving authority, an identity, or a
decision body as an argument: write commands read their body from a file inside
an approved directory, checked for containment after full resolution. There is
no default store root, no environment-derived value, no home directory, and no
implicit current user.

Time is explicit. Every operation that depends on an instant requires it to be
supplied and to carry an offset, so a result is reproducible rather than a race
against the clock.

Recovery is a decision, not an event. Nothing here retries, repairs, or
resubmits: a refused operation leaves no record, and going forward means
another governed decision with its own request identity producing its own
records.

Exit codes:
    0  the command succeeded
    1  the governed layer refused, or the store is not sound
    2  the invocation or configuration was unusable
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from typing import Any

from . import admission, inspection
from .eligibility import evaluate_eligibility
from .errors import FabricError
from .selection import select_candidate
from .store import FabricStore
from ..common.containment import contained_path
from ..trust.store import TrustStore

EXIT_SUCCESS = 0
EXIT_DENIED = 1
EXIT_USAGE = 2

# The outcomes that mean the governed layer said yes. Everything else it
# reports -- refused, invalid, not-found, conflict, unavailable -- is a denial,
# and is still structured output rather than a traceback.
ACCEPTING = ("accepted", "exact-replay")

# The record kind each creating write operation allocates. Withdrawals,
# retirements and refreshes supersede or amend an existing record rather than
# minting a new kind, so they have no identifier to predict.
CREATED_KINDS = {
    "declare-capability": "capability-definition",
    "declare-contract": "capability-contract",
    "declare-package": "capability-package",
    "admit-subject": "capability-host",
    "register-advertisement": "capability-advertisement",
    "admit-instance": "capability-instance",
    "create-route": "capability-route",
}

# The operations that resolve a governed Evidence reference. Both declare a
# verified resource profile, so both must prove the evidence supports it.
NEEDS_EVIDENCE = ("admit-subject", "refresh-subject")

# Which §8 write operations exist, and the released function each delegates to.
# One entry per spelling, so the interface never branches on a governance-
# relevant flag: choosing between withdrawing and retiring is the operator's
# decision, made by naming the command.
WRITE_OPERATIONS = {
    "declare-capability": ("declare_capability", False),
    "declare-contract": ("declare_contract", False),
    "declare-package": ("declare_package", False),
    "admit-subject": ("admit_subject", True),
    "register-advertisement": ("register_advertisement", False),
    "admit-instance": ("admit_instance", True),
    "create-route": ("create_route", False),
    "withdraw-subject": ("withdraw_subject", False),
    "refresh-subject": ("refresh_subject", True),
    "withdraw-instance": ("withdraw_instance", False),
    "retire-instance": ("retire_instance", False),
}

# The fields a decision body may carry as an instant. Named, so a body cannot
# smuggle a timestamp into a field nobody reviewed.
INSTANT_FIELDS = ("recorded_at", "evaluated_at", "observed_at", "valid_until",
                  "admitted_at", "admitted_until", "overlap_starts_at",
                  "overlap_ends_at")


class _Unusable(Exception):
    """The invocation could not be carried out. Exit code 2."""


def _emit(payload: Any) -> None:
    """Deterministic JSON on stdout. Diagnostics never go here."""
    print(json.dumps(payload, indent=2, sort_keys=True, default=str))


def _instant(value: Any, name: str) -> datetime:
    """A supplied instant, placed. Nothing here reads a clock."""
    if not isinstance(value, str):
        raise _Unusable(f"{name} must be supplied as a timestamp")
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        raise _Unusable(f"{name} is not a readable timestamp") from None
    if parsed.tzinfo is None or parsed.tzinfo.utcoffset(parsed) is None:
        raise _Unusable(f"{name} must carry a timezone offset")
    return parsed


def _decision_body(name: str, approved_directory: str) -> dict[str, Any]:
    """One decision body, read from inside an approved directory.

    Containment is checked after full resolution, so a traversing name, an
    absolute path, or a symlink pointing outside is refused rather than
    followed. The body is never composed here: what the operator wrote is what
    the governed component receives.
    """
    candidate = contained_path(approved_directory, name)
    if candidate is None:
        raise _Unusable(f"input file '{name}' resolves outside the approved directory")
    if not candidate.is_file():
        raise _Unusable(f"input file '{name}' does not exist in the approved directory")
    try:
        body = json.loads(candidate.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise _Unusable(f"input file '{name}' is not a readable decision body") from None
    if not isinstance(body, dict):
        raise _Unusable(f"input file '{name}' does not carry a decision body")
    for field in INSTANT_FIELDS:
        if body.get(field) is not None:
            body[field] = _instant(body[field], field)
    return body


def _fabric_store(args, *, for_read: bool = False) -> FabricStore:
    if for_read:
        return FabricStore.open_for_read(args.store_root,
                                         expected_uid=args.expected_uid,
                                         expected_gid=args.expected_gid)
    return FabricStore(args.store_root, expected_uid=args.expected_uid,
                       expected_gid=args.expected_gid)


def _trust_store(args, *, for_read: bool = False) -> TrustStore:
    """The trust store, opened to write or opened to read.

    `for_read` is the difference between a rehearsal and a write. The writing
    constructor provisions the store's directories, so opening one to answer
    *would this succeed* would create the very state the rehearsal promises not
    to touch. `open_for_read` is the released opener that creates nothing.
    """
    if not getattr(args, "trust_store_root", None):
        raise _Unusable("this operation requires --trust-store-root")
    if for_read:
        return TrustStore.open_for_read(args.trust_store_root)
    return TrustStore(args.trust_store_root)


def _evidence_authority(args) -> dict:
    """The Evidence trust boundary, passed through only where it is consumed.

    Supplied explicitly and never defaulted: an operation that resolves a
    governed Evidence reference without being told which authority to trust
    would be choosing one, and the resolver refuses rather than guessing.
    """
    if args.command not in NEEDS_EVIDENCE:
        return {}
    return {"evidence_root": getattr(args, "evidence_root", None),
            "evidence_trusted_uid": getattr(args, "evidence_trusted_uid", None)}


def _governed(result) -> int:
    """Report what the governed layer decided, and exit as it decided."""
    _emit(result.to_dict())
    return EXIT_SUCCESS if result.outcome in ACCEPTING else EXIT_DENIED


def command_write(args) -> int:
    """One governed mutation, delegated whole."""
    if getattr(args, "preflight", False):
        return command_preflight(args)
    function_name, needs_trust = WRITE_OPERATIONS[args.command]
    body = _decision_body(args.input_file, args.approved_directory)
    store = _fabric_store(args)
    operation = getattr(admission, function_name)
    try:
        if needs_trust:
            return _governed(operation(store, _trust_store(args),
                                       **_evidence_authority(args), **body))
        return _governed(operation(store, **body))
    except TypeError:
        # The body named something the operation does not take, or omitted
        # something it requires. That is an unusable invocation, not a
        # governed refusal, and the rejected value is never echoed.
        raise _Unusable("the decision body does not match this operation") from None


def command_preflight(args) -> int:
    """Rehearse one governed write, mutating nothing.

    **The production store is only ever read.** It is opened through
    `open_for_read`, so an absent store is reported as absent rather than built
    and then described, and no sequence, lock, record, or temporary is created
    by asking whether the write would succeed.

    **The real operation runs.** Restating the model's rules here would be a
    second implementation that agrees until it does not, so the body is carried
    through the same approved-directory reader into the same governed
    operation, under `admission.rehearsing()`. Every field check, vocabulary
    check, reference resolution and construction rule therefore runs against
    the real store; the operation stops at its first irreversible act.

    **The identifier is predicted, not taken.** `peek_next_id` reads the real
    store's sequence and applies the allocator's own rule, so the answer cannot
    disagree with what allocation would hand out. It remains a prediction:
    another caller may take it in between, which is why the write path
    allocates for itself rather than being handed this value.

    **The trust store is read the same way.** An operation that needs trust
    standing gets the real trust store opened through `open_for_read`, so the
    real query runs and nothing is provisioned by asking. This surface used to
    refuse those operations outright, on the correct observation that the
    writing constructor creates its root and the mistaken conclusion that no
    read-only opener existed. One does, and it is inherited -- so the governed
    write that most needs a rehearsal was the one that could not have one.
    Trust standing is never simulated here and never skipped; the rehearsal
    asks exactly what the write asks.
    """
    function_name, needs_trust = WRITE_OPERATIONS[args.command]

    body = _decision_body(args.input_file, args.approved_directory)
    store = _fabric_store(args, for_read=True)

    kind = CREATED_KINDS.get(args.command)
    predicted = destination = None
    if kind is not None:
        predicted = store.peek_next_id(kind)
        destination = store.path_for(kind, predicted)
        if destination.exists():
            raise _Unusable(
                f"{predicted} already exists at {destination}; the store and its "
                "sequence disagree and require operator disposition")

    operation = getattr(admission, function_name)
    try:
        with admission.rehearsing():
            if needs_trust:
                # The same trust query and the same Evidence resolution the
                # real write performs, against the real stores, opened so they
                # cannot provision anything. Skipping either would make the
                # rehearsal answer a different question from the write, which
                # is the one thing a rehearsal may not do.
                outcome = operation(store, _trust_store(args, for_read=True),
                                    **_evidence_authority(args), **body)
            else:
                outcome = operation(store, **body)
    except TypeError:
        raise _Unusable("the decision body does not match this operation") from None

    would_accept = outcome.outcome == admission.PREFLIGHT
    _emit({
        "outcome": "preflight",
        "operation": args.command,
        "would_accept": would_accept,
        "rehearsal_outcome": outcome.outcome,
        "rehearsal_reason": outcome.reason,
        "record_kind": kind,
        "predicted_record_id": predicted,
        "destination": str(destination) if destination else None,
        "destination_exists": False if destination else None,
        "store_root": str(store.root),
        "store_exists": store.root.exists(),
        "request_id": outcome.request_id,
        "request_digest": outcome.request_digest,
        "mutated": False,
    })
    return EXIT_SUCCESS if would_accept else EXIT_DENIED


def command_select(args) -> int:
    """Operation 10. The `CSEL` is the governed component's to write.

    `--preflight` runs the same governed selection against the same stores
    opened read-only and stops at the allocation boundary. The route is
    resolved, every candidate the route declares is judged by the same
    eligibility path, and the same declared-order rule picks the same winner --
    what differs is that nothing is allocated and nothing is written.
    """
    rehearse = bool(getattr(args, "preflight", False))
    body = _decision_body(args.input_file, args.approved_directory)
    store = _fabric_store(args, for_read=rehearse)

    kind = "capability-selection"
    predicted = destination = None
    if rehearse:
        predicted = store.peek_next_id(kind)
        destination = store.path_for(kind, predicted)
        if destination.exists():
            raise _Unusable(
                f"{predicted} already exists at {destination}; the store and its "
                "sequence disagree and require operator disposition")

    try:
        if not rehearse:
            return _governed(select_candidate(store, _trust_store(args), **body))
        with admission.rehearsing():
            outcome = select_candidate(
                store, _trust_store(args, for_read=True), **body)
    except TypeError:
        raise _Unusable("the decision body does not match this operation") from None

    would_accept = outcome.outcome == admission.PREFLIGHT
    _emit({
        "outcome": "preflight",
        "operation": args.command,
        "would_accept": would_accept,
        "rehearsal_outcome": outcome.outcome,
        "rehearsal_reason": outcome.reason,
        "record_kind": kind,
        "predicted_record_id": predicted,
        # The decision itself, which is the whole reason to rehearse a
        # selection: an operator wants to know which binding would serve
        # before a `CSEL` identity is spent on finding out.
        "selected_instance_id": outcome.selected_instance_id,
        "destination": str(destination) if destination else None,
        "destination_exists": False if destination else None,
        "store_root": str(store.root),
        "store_exists": store.root.exists(),
        "request_id": outcome.request_id,
        "request_digest": outcome.request_digest,
        "mutated": False,
    })
    return EXIT_SUCCESS if would_accept else EXIT_DENIED


def command_compute_eligibility(args) -> int:
    """Operation 9. Read-only, and it carries no authority to supply."""
    store = _fabric_store(args, for_read=True)
    verdict = evaluate_eligibility(
        store, _trust_store(args), instance_id=args.instance_id,
        request={"capability_id": args.capability_id,
                 "contract_id": args.contract_id,
                 "accepted_contract_versions": tuple(args.accepted_version),
                 "data_classification": args.data_classification},
        evaluated_at=_instant(args.evaluated_at, "--evaluated-at"))
    _emit(verdict.to_dict())
    return EXIT_SUCCESS if verdict.eligible else EXIT_DENIED


def command_inspect(args) -> int:
    """Operation 11. C8's report, unaltered."""
    report = inspection.inspect_records(
        args.store_root, expected_uid=args.expected_uid,
        expected_gid=args.expected_gid, kind=args.kind,
        identifier=args.identifier)
    _emit(report.to_dict())
    return (EXIT_SUCCESS if report.status == inspection.STATUS_REPORTED
            else EXIT_DENIED)


def command_validate(args) -> int:
    """Operation 12. C8's findings, unaltered, and repairs nothing."""
    report = inspection.validate_store(
        args.store_root, expected_uid=args.expected_uid,
        expected_gid=args.expected_gid)
    _emit(report.to_dict())
    sound = report.status == inspection.STATUS_REPORTED and not report.findings
    return EXIT_SUCCESS if sound else EXIT_DENIED


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="fabric",
        description="Read and govern a Fabric store. Nothing here executes a capability.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    def with_store(sub):
        # Required, always: a default store root is a store nobody named.
        sub.add_argument("--store-root", required=True,
                         help="the fabric store root, named explicitly")
        sub.add_argument("--expected-uid", required=True, type=int,
                         help="the owner the store must have")
        sub.add_argument("--expected-gid", required=True, type=int,
                         help="the group the store must have")
        return sub

    def with_trust(sub):
        sub.add_argument("--trust-store-root", required=True,
                         help="the trust store root, named explicitly")
        return sub

    def with_body(sub):
        # No identity, authority, or decision content is accepted as an
        # argument; the body is a file inside an approved directory.
        sub.add_argument("--evidence-root", default=None,
                         help="the trusted deployment Evidence authority root")
        sub.add_argument("--evidence-trusted-uid", default=None, type=int,
                         help="the uid the Evidence authority must be owned by")
        sub.add_argument("--input-file", required=True,
                         help="file name inside the approved directory")
        sub.add_argument("--approved-directory", required=True,
                         help="the directory a decision body may come from")
        return sub

    for name, (_, needs_trust) in WRITE_OPERATIONS.items():
        sub = with_body(with_store(subparsers.add_parser(name)))
        if needs_trust:
            with_trust(sub)
        # Rehearse without governing. Every write subcommand takes it, because
        # a preflight only some operations offer is one an operator has to
        # remember the exceptions to.
        sub.add_argument("--preflight", action="store_true",
                         help="validate everything reachable without mutating: "
                              "creates no store, allocates no identifier, "
                              "writes nothing")
        sub.set_defaults(handler=command_write)

    choose = with_trust(with_body(with_store(subparsers.add_parser("select"))))
    choose.add_argument("--preflight", action="store_true",
                        help="resolve the route and judge every candidate "
                             "without mutating: allocates no identifier and "
                             "writes nothing")
    choose.set_defaults(handler=command_select)

    eligible = with_trust(with_store(subparsers.add_parser("compute-eligibility")))
    eligible.add_argument("--instance-id", required=True)
    eligible.add_argument("--capability-id", required=True)
    eligible.add_argument("--contract-id", required=True)
    eligible.add_argument("--accepted-version", required=True, action="append",
                          help="an accepted contract version; repeat for a set")
    eligible.add_argument("--data-classification", required=True)
    eligible.add_argument("--evaluated-at", required=True,
                          help="the instant to answer for, with an offset")
    eligible.set_defaults(handler=command_compute_eligibility)

    look = with_store(subparsers.add_parser("inspect"))
    look.add_argument("--kind", default=None, help="one accepted record kind")
    look.add_argument("--identifier", default=None, help="one record identity")
    look.set_defaults(handler=command_inspect)

    sound = with_store(subparsers.add_parser("validate"))
    sound.set_defaults(handler=command_validate)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.handler(args)
    except _Unusable as error:
        print(f"fabric: {error}", file=sys.stderr)
        return EXIT_USAGE
    except FabricError as error:
        # The store itself could not be used as named -- ownership, containment,
        # a link, or a root that is not there.
        print(f"fabric: {error}", file=sys.stderr)
        return EXIT_USAGE


if __name__ == "__main__":
    raise SystemExit(main())
