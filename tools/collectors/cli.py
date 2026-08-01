"""Command line interface for the read-only collectors.

Prints JSON to stdout and diagnostics to stderr. Writes nothing: output is
piped into a future evidence orchestrator, which is what decides whether an
observation becomes a record. The CLI assigns no evidence identifier.

Exit status:
    0  collection succeeded
    1  collection ran and failed
    2  invocation or configuration error

Attestation payloads are accepted only as a file inside a caller-approved
directory, never as a command-line argument. Command lines are retained in
shell history and visible in process listings, so an attestation passed that
way is disclosed before it is ever validated.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tools.collectors.exceptions import CollectorRegistrationError  # noqa: E402
from tools.collectors.models import CollectionContext  # noqa: E402
from tools.collectors.redaction import redact  # noqa: E402
from tools.collectors.registry import build_default_registry  # noqa: E402

EXIT_OK = 0
EXIT_COLLECTION_FAILED = 1
EXIT_INVOCATION_ERROR = 2


def _emit(payload) -> None:
    """Print deterministic JSON. Sorted keys so output is diffable and stable."""
    print(json.dumps(payload, indent=2, sort_keys=True, default=str))


def _fail(message: str) -> int:
    print(f"ERROR {message}", file=sys.stderr)
    return EXIT_INVOCATION_ERROR


def _result_to_dict(result) -> dict:
    payload = {
        "collector_id": result.collector_id,
        "target": result.target,
        "status": result.status,
        "started_at": result.started_at,
        "completed_at": result.completed_at,
        "content_fingerprint": result.content_fingerprint,
        "observations": [asdict(o) for o in result.observations],
        "errors": [asdict(e) for e in result.errors],
    }
    # Belt and braces: the collectors redact at source, but the CLI is the last
    # point before output reaches a terminal or a log.
    redacted, _ = redact(payload)
    return redacted


def _load_attestation(path_argument: str, approved_directory: str) -> dict:
    approved = Path(approved_directory).resolve()
    if not approved.is_dir():
        raise ValueError("approved attestation directory does not exist")

    candidate = Path(path_argument)
    resolved = (approved / candidate).resolve() if not candidate.is_absolute() else candidate.resolve()

    # resolve() follows symlinks, so a link pointing outside the approved
    # directory fails the same containment check as ordinary traversal.
    if not str(resolved).startswith(str(approved) + "/") and resolved != approved:
        raise ValueError("attestation file escapes the approved directory")
    if not resolved.is_file():
        raise ValueError("attestation file does not exist")

    with resolved.open(encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise ValueError("attestation file must contain a JSON object")
    return payload


def command_list(registry) -> int:
    _emit([
        {
            "id": m.id,
            "name": m.name,
            "version": m.version,
            "source_type": m.source_type,
            "permissions": list(m.permissions),
            "network_access": m.network_access,
            "subprocess_access": m.subprocess_access,
            "filesystem_access": m.filesystem_access,
            "supported_targets": list(m.supported_targets),
        }
        for m in registry.list_manifests()
    ])
    return EXIT_OK


def command_validate(registry) -> int:
    problems: list[str] = []
    for manifest in registry.list_manifests():
        problems.extend(f"{manifest.id}: {issue}" for issue in manifest.validation_errors())
    if problems:
        for problem in problems:
            print(f"ERROR {problem}", file=sys.stderr)
        return EXIT_COLLECTION_FAILED
    _emit({"validated": registry.ids(), "status": "ok"})
    return EXIT_OK


def command_collect(registry, args) -> int:
    try:
        plugin_class = registry.get(args.collector)
    except CollectorRegistrationError as error:
        return _fail(str(error))

    options: dict = {}
    if args.collector == "git-repository":
        if not args.path:
            return _fail("git-repository requires --path")
        options["path"] = args.path
    elif args.collector == "configuration-render":
        if not args.compose_file or not args.env_file:
            return _fail("configuration-render requires --compose-file and --env-file")
        options.update(compose_file=args.compose_file, env_file=args.env_file,
                       repository_root=args.repository_root or ".")
    elif args.collector == "manual-attestation":
        if not args.attestation_file:
            return _fail(
                "manual-attestation requires --attestation-file; raw JSON is not accepted "
                "as an argument because shell history would retain it"
            )
        try:
            options["attestation"] = _load_attestation(
                args.attestation_file, args.attestation_dir or "."
            )
        except (ValueError, json.JSONDecodeError, OSError) as error:
            return _fail(f"attestation input rejected: {error}")
    elif args.collector == "example-synthetic":
        options = {}

    context = CollectionContext(
        target=args.target,
        declared={},
        requested_facts=(),
        collected_at=args.collected_at,
        synthetic=bool(args.synthetic),
        options=options or None,
    )

    result = plugin_class().execute(context)
    _emit(_result_to_dict(result))
    return EXIT_COLLECTION_FAILED if result.is_terminal_failure() else EXIT_OK


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="tools.collectors.cli",
        description="Run local read-only collectors. Output is JSON on stdout; nothing is persisted.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("list", help="List registered collectors")
    sub.add_parser("validate", help="Validate registered collector manifests")

    collect = sub.add_parser("collect", help="Run one collector")
    collect.add_argument("--collector", required=True)
    collect.add_argument("--target", required=True)
    collect.add_argument("--collected-at", default=None,
                         help="RFC 3339 timestamp with offset, supplied by the caller")
    collect.add_argument("--path", default=None, help="git-repository: repository path")
    collect.add_argument("--compose-file", default=None)
    collect.add_argument("--env-file", default=None)
    collect.add_argument("--repository-root", default=None)
    collect.add_argument("--attestation-file", default=None,
                         help="manual-attestation: JSON file inside --attestation-dir")
    collect.add_argument("--attestation-dir", default=None,
                         help="Directory the attestation file must stay inside")
    collect.add_argument("--synthetic", action="store_true")

    args = parser.parse_args(argv)
    registry = build_default_registry()

    if args.command == "list":
        return command_list(registry)
    if args.command == "validate":
        return command_validate(registry)

    if not args.collected_at:
        # The orchestrator owns the collection timestamp. Defaulting it here
        # would let two runs of the same command produce different evidence
        # times for the same logical collection.
        from datetime import datetime, timezone
        args.collected_at = datetime.now(timezone.utc).astimezone().isoformat()

    return command_collect(registry, args)


if __name__ == "__main__":
    raise SystemExit(main())
