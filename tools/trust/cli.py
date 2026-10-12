"""Command line interface for the Trust Plane runtime.

Eight commands. Nothing here deletes, updates, restores, scores, or enrolls,
and no flag could be added to make it: the commands that would do those things
do not exist.

What the interface refuses is the interesting part. There is no way to pass an
identity, a key, or a decision body as an argument — write commands read an
input file from an approved directory, checked for containment after full
resolution. There is no default store root, no interactive prompt, no
environment-derived identity, and no implicit current user. Anything else would
move the trust boundary onto whoever typed the command.

Time is explicit. Read commands that depend on it require `--evaluated-at`, so
output is reproducible rather than a race against the clock.

Exit codes:
    0  the command succeeded
    1  trust denied the request, or the store is invalid
    2  the invocation or configuration was unusable
"""

from __future__ import annotations

import argparse
import contextlib
import json
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

from ..common.containment import contained_path
from .errors import TrustError
from .evaluator import create_decision, rehearsing
from .models import (
    TrustEvidenceReference,
    TrustScope,
    TrustVerificationDetails,
)
from .root_authority import declare_root_authority, load_root_declaration
from .root_lineage_backfill import (
    apply_root_lineage_backfill,
    plan_root_lineage_backfill,
)
from .store import TrustStore
from . import query as Q

EXIT_SUCCESS = 0
EXIT_DENIED = 1
EXIT_USAGE = 2


def _emit(payload: Any) -> None:
    """Deterministic JSON on stdout. Diagnostics never go here."""
    print(json.dumps(payload, indent=2, sort_keys=True, default=str))


def _open_store(args) -> TrustStore:
    return TrustStore(args.store_root)


def _parse_time(value: str, name: str) -> datetime:
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        raise TrustError(f"{name} must carry a timezone offset")
    return parsed


def _read_input(name: str, approved_directory: str) -> dict[str, Any]:
    """Read a write-command input file from an approved directory."""
    import yaml

    # The approved directory is the operator's to name, `~` included; the
    # shared primitive answers containment and expands nothing.
    candidate = contained_path(Path(approved_directory).expanduser(), name)
    if candidate is None:
        raise TrustError(f"input file '{name}' resolves outside the approved directory")
    if not candidate.is_file():
        raise TrustError(f"input file '{name}' does not exist in the approved directory")
    data = yaml.safe_load(candidate.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise TrustError(f"input file '{name}' must contain a mapping")
    return data


def command_init_root(args) -> int:
    store = _open_store(args)
    declaration = load_root_declaration(args.input_file,
                                        approved_directory=args.approved_directory)
    authority = declare_root_authority(store, declaration)
    _emit(authority.to_dict())
    return EXIT_SUCCESS


def command_validate_store(args) -> int:
    # Opened for read: validating a store must not create it. See ENG-0002.
    store = TrustStore.open_for_read(args.store_root)
    problems = store.validate()
    _emit({"store_root": str(store.root), "valid": not problems,
           "problems": problems, "counts": store.counts()})
    return EXIT_SUCCESS if not problems else EXIT_DENIED


def command_create_decision(args) -> int:
    """One immutable trust decision, or a rehearsal of one.

    `--preflight` runs the same evaluation against the same store opened
    read-only and stops at the allocation boundary. It is not a second
    algorithm: every authority, evidence, scope, transition and lineage rule
    runs, and what it reports is what the write would decide.
    """
    rehearse = bool(getattr(args, "preflight", False))
    store = (TrustStore.open_for_read(args.store_root) if rehearse
             else _open_store(args))
    payload = _read_input(args.input_file, args.approved_directory)

    details = payload.get("verification_details") or {}
    scope_input = payload.get("trust_scope")
    scope = None
    if isinstance(scope_input, dict):
        scope = TrustScope(
            scope_id=(store.peek_next_id("scope") if rehearse
                      else store.allocate_id("scope")),
            subject_type=str(scope_input.get("subject_type", payload.get("subject_type"))),
            permitted_capabilities=tuple(scope_input.get("permitted_capabilities") or ()),
            permitted_operations=tuple(scope_input.get("permitted_operations") or ()),
            permitted_data_classifications=tuple(
                scope_input.get("permitted_data_classifications") or ()),
            permitted_targets=tuple(scope_input.get("permitted_targets") or ()),
            validity_start=_parse_time(scope_input["validity_start"], "validity_start")
            if scope_input.get("validity_start") else None,
            validity_end=_parse_time(scope_input["validity_end"], "validity_end")
            if scope_input.get("validity_end") else None,
        )

    # The identity an operator cites is carried, not replaced. It used to be a
    # placeholder the store overwrote, so a body naming one piece of evidence
    # produced a record citing another and neither looked wrong on its own.
    references = tuple(
        TrustEvidenceReference(
            evidence_id=str(item["evidence_id"]),
            kind=str(item.get("kind", "attestation")),
            reference=str(item["reference"]),
            recorded_at=_parse_time(item["recorded_at"], "recorded_at"),
        )
        for item in (payload.get("evidence_references") or [])
    )

    runner = rehearsing() if rehearse else contextlib.nullcontext()
    with runner:
      outcome = create_decision(
        store,
        subject_id=str(payload["subject_id"]),
        subject_type=str(payload["subject_type"]),
        requested_state=str(payload["requested_state"]),
        actor_authority_id=str(payload["actor_authority_id"]),
        decided_at=_parse_time(str(payload["decided_at"]), "decided_at"),
        reason=str(payload["reason"]),
        evidence_references=references,
        verification_method=str(payload["verification_method"]),
        verification_details=TrustVerificationDetails(
            subject_property=str(details["subject_property"]),
            observed_value_reference=str(details["observed_value_reference"]),
            comparison_source=str(details["comparison_source"]),
            performed_by=str(details["performed_by"]),
            performed_at=_parse_time(str(details["performed_at"]), "performed_at"),
        ),
        scope=scope,
        expiration=_parse_time(str(payload["expiration"]), "expiration")
        if payload.get("expiration") else None,
        supersedes=payload.get("supersedes"),
        revokes_record_id=payload.get("revokes_record_id"),
        lineage_id=payload.get("lineage_id"),
        supersedes_lineage_id=payload.get("supersedes_lineage_id"),
        approval_source=str(payload.get("approval_source", "named-operator")),
        provenance=payload.get("provenance") or {},
    )
    if rehearse:
        _emit({
            "outcome": "preflight",
            "operation": "create-decision",
            "would_accept": True,
            "mutated": False,
            "predicted_record_id": outcome.record.record_id,
            "predicted_decision_id": outcome.decision.decision_id,
            "predicted_lineage_id": outcome.lineage.lineage_id,
            "predicted_audit_id": outcome.audit_event.audit_id,
            "predicted_evidence_ids": [reference.evidence_id for reference
                                       in outcome.decision.evidence_references],
            "predicted_scope_id": scope.scope_id if scope else None,
            "subject_id": outcome.record.subject_id,
            "subject_type": outcome.record.subject_type,
            "state": outcome.record.state,
            # The Trust plane identifies a decision by its own fingerprint;
            # there is no separate request identity to digest.
            "decision_fingerprint": outcome.decision.decision_fingerprint,
            "record_fingerprint": outcome.record.fingerprint,
            "subject_fingerprint": outcome.record.subject_fingerprint,
            "destination": str(store.path_for("record", outcome.record.record_id)),
            "destination_exists":
                store.path_for("record", outcome.record.record_id).exists(),
            "store_root": str(store.root),
        })
        return EXIT_SUCCESS
    _emit(outcome.to_dict())
    return EXIT_SUCCESS


def command_backfill_root_lineage(args) -> int:
    """Record how the existing Operator Root was established, once.

    `--preflight` runs every precondition and constructs both records against
    the same store opened read-only, then stops before allocating the audit
    identifier. What it reports is what the write would produce.
    """
    rehearse = bool(getattr(args, "preflight", False))
    store = (TrustStore.open_for_read(args.store_root) if rehearse
             else _open_store(args))
    payload = _read_input(args.input_file, args.approved_directory)
    plan = plan_root_lineage_backfill(
        store,
        recorded_at=_parse_time(str(payload["recorded_at"]), "recorded_at"),
        reason=str(payload["reason"]),
        performed_by=str(payload["performed_by"]),
        rehearse=rehearse,
    )
    destination = store.path_for("lineage", plan.lineage.id)
    if rehearse:
        _emit({
            "outcome": "preflight",
            "operation": "backfill-root-lineage",
            "would_accept": True,
            "mutated": False,
            "authority_id": plan.lineage.authority_id,
            "predicted_lineage_record_id": plan.lineage.id,
            "predicted_audit_id": plan.audit_event.audit_id,
            "would_write_lineage": plan.writes_lineage,
            "would_write_audit": plan.writes_audit,
            "establishment_audit_id": plan.lineage.establishment_audit_id,
            "evidence_reference_ids": list(plan.lineage.evidence_reference_ids),
            "established_at": plan.lineage.established_at.isoformat(),
            "recorded_at": plan.lineage.recorded_at.isoformat(),
            "audit_fingerprint": plan.audit_event.fingerprint,
            "destination": str(destination),
            "destination_exists": destination.exists(),
            "store_root": str(store.root),
        })
        return EXIT_SUCCESS
    _emit(apply_root_lineage_backfill(store, plan))
    return EXIT_SUCCESS


def command_show_subject(args) -> int:
    store = _open_store(args)
    result = Q.get_current_trust(store, args.subject_id,
                                 evaluated_at=_parse_time(args.evaluated_at,
                                                          "evaluated-at"))
    _emit(result)
    return EXIT_SUCCESS if result.get("usable") else EXIT_DENIED


def command_show_lineage(args) -> int:
    store = _open_store(args)
    head = Q.get_lineage(store, args.lineage_id)
    if head is None:
        _emit({"lineage_id": args.lineage_id, "found": False,
               "reason": "no such lineage; unknown fails closed"})
        return EXIT_DENIED
    _emit(head)
    return EXIT_SUCCESS


def command_evaluate(args) -> int:
    store = _open_store(args)
    result = Q.evaluate_subject(
        store, args.subject_id,
        evaluated_at=_parse_time(args.evaluated_at, "evaluated-at"),
        capability=args.capability, operation=args.operation,
        data_classification=args.data_classification, target=args.target,
        activity_kind=args.activity_kind)
    _emit(result)
    return EXIT_SUCCESS if result.get("allowed") else EXIT_DENIED


def command_list_history(args) -> int:
    store = _open_store(args)
    _emit({"subject_id": args.subject_id,
           "history": Q.list_subject_history(store, args.subject_id),
           "lineages": Q.list_lineages(store, args.subject_id)})
    return EXIT_SUCCESS


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="trust",
        description=("Trust Plane runtime. Read-only queries and immutable "
                     "decisions; nothing here deletes, updates, or restores trust."))
    subparsers = parser.add_subparsers(dest="command", required=True)

    def with_store(sub):
        sub.add_argument("--store-root", required=True,
                         help="explicit trust store root, outside the repository")
        return sub

    def with_input(sub):
        sub.add_argument("--input-file", required=True,
                         help="file name inside the approved directory")
        sub.add_argument("--approved-directory", required=True,
                         help="directory holding reviewed input files")
        return sub

    init = with_input(with_store(subparsers.add_parser(
        "init-root", help="declare that an external operator root authority exists")))
    init.set_defaults(handler=command_init_root)

    validate = with_store(subparsers.add_parser(
        "validate-store", help="report structural problems; repairs nothing"))
    validate.set_defaults(handler=command_validate_store)

    decision = with_input(with_store(subparsers.add_parser(
        "create-decision", help="record one immutable trust decision")))
    decision.add_argument("--preflight", action="store_true",
                          help="validate everything reachable without mutating: "
                               "allocates no identifier and writes nothing")
    decision.set_defaults(handler=command_create_decision)

    backfill = with_input(with_store(subparsers.add_parser(
        "backfill-root-lineage",
        help="record the root establishment lineage the ceremony omitted; "
             "refused unless exactly that defect is present")))
    backfill.add_argument("--preflight", action="store_true",
                          help="check every precondition and construct both "
                               "records without allocating or writing anything")
    backfill.set_defaults(handler=command_backfill_root_lineage)

    show = with_store(subparsers.add_parser(
        "show-subject", help="current stored and effective state for a subject"))
    show.add_argument("--subject-id", required=True)
    show.add_argument("--evaluated-at", required=True,
                      help="ISO 8601 timestamp with a UTC offset")
    show.set_defaults(handler=command_show_subject)

    lineage = with_store(subparsers.add_parser(
        "show-lineage", help="the newest version of one lineage"))
    lineage.add_argument("--lineage-id", required=True)
    lineage.set_defaults(handler=command_show_lineage)

    evaluate = with_store(subparsers.add_parser(
        "evaluate", help="evaluate an activity and scope request for a subject"))
    evaluate.add_argument("--subject-id", required=True)
    evaluate.add_argument("--evaluated-at", required=True,
                          help="ISO 8601 timestamp with a UTC offset")
    evaluate.add_argument("--activity-kind", default="normal",
                          choices=("normal", "verification", "investigation"))
    evaluate.add_argument("--capability")
    evaluate.add_argument("--operation")
    evaluate.add_argument("--data-classification")
    evaluate.add_argument("--target")
    evaluate.set_defaults(handler=command_evaluate)

    history = with_store(subparsers.add_parser(
        "list-history", help="every decision affecting a subject, oldest first"))
    history.add_argument("--subject-id", required=True)
    history.set_defaults(handler=command_list_history)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.handler(args)
    except TrustError as error:
        print(f"trust: {error}", file=sys.stderr)
        return EXIT_USAGE
    except (KeyError, ValueError) as error:
        print(f"trust: invalid input ({type(error).__name__}: {error})", file=sys.stderr)
        return EXIT_USAGE


if __name__ == "__main__":
    raise SystemExit(main())
