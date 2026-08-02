"""Command line interface for remote read-only collection.

Three commands: list what may be run, check that a target is usable, and
collect. Nothing here enrolls a host key, stores a credential, installs
anything, or changes remote state — and there is no flag that could.

Note what the interface does not accept. There is no way to pass a hostname,
a command, or a credential on the command line. A target is named by its file
inside an approved directory, and what runs against it comes from the catalog.
Anything else would move the trust boundary onto whoever typed the command.

Results are printed. They are never written to the evidence store: a collector
that numbers and stores its own records controls the audit trail (ADR-0004).

Exit codes:
    0  the command succeeded
    1  the command ran and the collection or validation failed
    2  the invocation was unusable
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import sys
from typing import Any

from .models import CollectionContext
from .remote.command_catalog import CATALOG, operation_ids
from .remote.ssh_transport import SSHRemoteTransport
from .remote.target import TargetError, load_target

EXIT_SUCCESS = 0
EXIT_FAILURE = 1
EXIT_USAGE = 2

# A record identifier is never assigned here. Results printed by this CLI are
# not evidence; identity is assigned by the observation layer.
UNPERSISTED_RESULT_ID = "UNPERSISTED-REMOTE-RESULT"


def _collectors() -> dict[str, Any]:
    """Import collectors lazily so `list-operations` needs no plugin import."""
    from .plugins.linux_host.collector import LinuxHostCollector
    from .plugins.linux_resources.collector import LinuxResourcesCollector
    from .plugins.linux_services.collector import LinuxServicesCollector

    return {
        "linux-host": LinuxHostCollector,
        "linux-resources": LinuxResourcesCollector,
        "linux-services": LinuxServicesCollector,
    }


def command_list_operations(_: argparse.Namespace) -> int:
    """Print the catalog. Sorted, so the output is stable across runs."""
    for identifier in operation_ids():
        operation = CATALOG[identifier]
        print(f"{identifier}\t{operation.platform}\t{operation.sensitivity}\t"
              f"{operation.description}")
    return EXIT_SUCCESS


def command_validate_target(args: argparse.Namespace) -> int:
    try:
        target = load_target(args.target, approved_directory=args.approved_directory)
    except TargetError as error:
        print(f"target is not usable: {error}", file=sys.stderr)
        return EXIT_FAILURE

    print(json.dumps({
        "target_id": target.target_id,
        "hostname": target.hostname,
        "platform": target.platform,
        "trust_classification": target.trust_classification,
        "host_key_policy": target.host_key_policy,
        "authentication_kind": (
            target.authentication_reference.kind
            if target.authentication_reference else None
        ),
        "allowed_operation_ids": list(target.allowed_operation_ids),
        "allowed_units": list(target.allowed_units),
    }, indent=2, sort_keys=True))
    return EXIT_SUCCESS


def command_collect(args: argparse.Namespace) -> int:
    collectors = _collectors()
    factory = collectors.get(args.collector)
    if factory is None:
        print(f"unknown collector '{args.collector}'", file=sys.stderr)
        return EXIT_USAGE

    try:
        target = load_target(args.target, approved_directory=args.approved_directory)
    except TargetError as error:
        print(f"target is not usable: {error}", file=sys.stderr)
        return EXIT_USAGE

    context = CollectionContext(
        target=target.target_id,
        declared={},
        requested_facts=(),
        collected_at=args.collected_at,
        options={"target": target, "transport": SSHRemoteTransport()},
    )

    result = factory().execute(context)

    print(json.dumps({
        "result_id": UNPERSISTED_RESULT_ID,
        "collector_id": result.collector_id,
        "target": result.target,
        "status": result.status,
        "observations": [dataclasses.asdict(o) for o in result.observations],
        "errors": [dataclasses.asdict(e) for e in result.errors],
        "content_fingerprint": result.content_fingerprint,
    }, indent=2, sort_keys=True, default=str))

    return EXIT_SUCCESS if result.status == "success" else EXIT_FAILURE


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="remote-collect",
        description=(
            "Collect explicitly approved facts from explicitly approved remote "
            "hosts. Read-only: nothing here changes remote state."
        ),
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    listing = subparsers.add_parser(
        "list-operations", help="print every operation the catalog defines")
    listing.set_defaults(handler=command_list_operations)

    validate = subparsers.add_parser(
        "validate-target", help="check that an approved target file is usable")
    validate.add_argument("--target", required=True,
                          help="target file name inside the approved directory")
    validate.add_argument("--approved-directory", required=True,
                          help="directory holding reviewed target files")
    validate.set_defaults(handler=command_validate_target)

    collect = subparsers.add_parser(
        "collect", help="run a remote collector against an approved target")
    collect.add_argument("--collector", required=True,
                         choices=sorted(("linux-host", "linux-resources",
                                         "linux-services")))
    collect.add_argument("--target", required=True,
                         help="target file name inside the approved directory")
    collect.add_argument("--approved-directory", required=True,
                         help="directory holding reviewed target files")
    collect.add_argument("--collected-at", required=True,
                         help="ISO 8601 timestamp with a UTC offset")
    collect.set_defaults(handler=command_collect)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.handler(args)


if __name__ == "__main__":
    raise SystemExit(main())
