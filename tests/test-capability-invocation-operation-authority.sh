#!/usr/bin/env bash
set -Eeuo pipefail

# ENG-0005 G11-X. Per-invocation operation authority and effective-scope
# enforcement at the pre-stage invocation boundary.
#
# G11-W proved that nothing between a persisted `CSEL` and `execve` ever read
# `effective_scope`, and that no operation value existed anywhere in the
# request vocabulary. Selection answers *which binding serves this request
# class*; it does not answer *what action is being requested now*. This suite
# pins the answer to the second question at the last fully refusable point.
#
# Every assertion runs against temporary fixtures. Nothing here reads or writes
# a production path, stages a package, allocates a `CINV`, authorises a launch,
# or reaches an adapter.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"

PRODUCTION_FABRIC=/var/lib/kyri/fabric
BEFORE="$(mktemp)"
AFTER="$(mktemp)"
trap 'rm -f "${BEFORE}" "${AFTER}"' EXIT
if [[ -d "${PRODUCTION_FABRIC}" ]]; then
  ( cd "${PRODUCTION_FABRIC}" && find . -mindepth 1 -printf '%y %m %s %p\n' | sort ) > "${BEFORE}"
fi

python3 - <<'PYTHON'
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, ".")
sys.dont_write_bytecode = True

import os

from tools.capability.fabric_evidence import verify_selected_evidence
from tools.fabric.store import FabricStore

UID, GID = os.geteuid(), os.getegid()
NOW = datetime(2026, 8, 28, 12, 0, 0, tzinfo=timezone(timedelta(hours=-5)))
OPENED = NOW - timedelta(days=1)
EXPIRES = NOW + timedelta(days=1)
NODE = "HOST-0001"

FAILURES = []


def check(condition, label):
    print(("PASS: " if condition else "FAIL: ") + label)
    if not condition:
        FAILURES.append(label)


SCOPE = {
    "permitted_capabilities": ["CAPDEF-0001"],
    "permitted_operations": ["execute"],
    "permitted_data_classifications": ["internal"],
    "permitted_targets": [NODE],
}

IDENTITY_FIELD = {
    "capability-definition": "capability_id",
    "capability-contract": "contract_id",
    "capability-package": "capability_package_id",
    "capability-host": "capability_host_id",
    "capability-instance": "instance_id",
    "capability-selection": "selection_id",
}


def chain(tmp, **overrides):
    """One authoritative, already-selected chain, mirroring production shape.

    Carries the records the released governance path actually writes: a host
    declaring its node identity, an instance carrying a composed
    `effective_scope`, and a selection carrying its governed request class.
    """
    fabric_root = Path(tmp) / "fabric"
    store = FabricStore(fabric_root, expected_uid=UID, expected_gid=GID)
    records = {
        "capability-definition": {
            "capability_id": "CAPDEF-0001", "name": "boundary-probe",
            "description": "A probe.", "effect_class": "computational",
            "contract_ids": ["CCON-0001"], "kind": "capability-definition"},
        "capability-contract": {
            "contract_id": "CCON-0001", "capability_id": "CAPDEF-0001",
            "contract_version": "1.0.0", "effect_class": "computational",
            "determinism_class": "deterministic", "kind": "capability-contract"},
        "capability-package": {
            "capability_package_id": "CPKG-0001", "capability_id": "CAPDEF-0001",
            "contract_id": "CCON-0001", "package_version": "1.0.0",
            "artifact_reference": "tree:boundary-probe/1.0.0",
            "manifest_reference": "file:boundary.manifest.json",
            "kind": "capability-package"},
        "capability-host": {
            "capability_host_id": "CHOST-0001",
            "node_identity_reference": NODE,
            "location_class": "on-premises", "data_classification": "internal",
            "availability_intent": "in-service", "kind": "capability-host"},
        "capability-instance": {
            "instance_id": "CINST-000002", "capability_id": "CAPDEF-0001",
            "capability_package_id": "CPKG-0001", "contract_id": "CCON-0001",
            "capability_host_id": "CHOST-0001", "lifecycle_state": "admitted",
            "effective_scope": dict(SCOPE),
            "admitted_at": OPENED.isoformat(), "admitted_until": EXPIRES.isoformat(),
            "admission_decision_id": "eng-0005-probe", "kind": "capability-instance"},
        "capability-selection": {
            "selection_id": "CSEL-000001", "selected_instance_id": "CINST-000002",
            "selection_reason": "first eligible candidate in declared order",
            "selected_at": NOW.isoformat(), "route_id": "CROUTE-0002",
            "route_version": 2, "local_node_identity": NODE,
            "request_class": {
                "capability_id": "CAPDEF-0001", "contract_id": "CCON-0001",
                "accepted_contract_versions": ["1.0.0"],
                "data_classification": "internal", "locality": "local-only"},
            "kind": "capability-selection"},
    }
    for kind, changes in overrides.items():
        if changes is None:
            records.pop(kind, None)
        else:
            records[kind].update(changes)
    for kind, record in records.items():
        store.write_atomic(store.path_for(kind, record[IDENTITY_FIELD[kind]]),
                           record)
    return fabric_root


def verify(fabric_root, **overrides):
    asked = dict(selection_id="CSEL-000001", instance_id="CINST-000002",
                 capability_package_id="CPKG-0001", operation="execute",
                 evaluated_at=NOW)
    asked.update(overrides)
    return verify_selected_evidence(fabric_root, expected_uid=UID,
                                    expected_gid=GID, **asked)


def inventory(base):
    """Every path under a root, with its bytes, so a write cannot hide."""
    entries = {}
    for path in sorted(Path(base).rglob("*")):
        info = path.lstat()
        entries[str(path.relative_to(base))] = (
            info.st_mode, info.st_size,
            path.read_bytes() if path.is_file() else b"")
    return entries


print("=" * 74)
print("PART 1 — the interface carries an operation, explicitly")
print("=" * 74)

import inspect
signature = inspect.signature(verify_selected_evidence)
check("operation" in signature.parameters,
      "verify_selected_evidence takes an operation")
if "operation" in signature.parameters:
    parameter = signature.parameters["operation"]
    check(parameter.default is inspect.Parameter.empty,
          "the operation parameter has no default")
    check(parameter.kind is inspect.Parameter.KEYWORD_ONLY,
          "the operation parameter is keyword-only, so it cannot be passed by "
          "position into another field's place")

from tools.capability import coordinator as _coordinator
check("operation" in inspect.signature(_coordinator.prepare_invocation).parameters,
      "prepare_invocation takes an operation")
check(inspect.signature(_coordinator.prepare_invocation)
      .parameters.get("operation", inspect.Parameter.empty) is inspect.Parameter.empty
      or inspect.signature(_coordinator.prepare_invocation)
      .parameters["operation"].default is inspect.Parameter.empty,
      "prepare_invocation's operation has no default")

from tools.capability import invocation_identity as _identity
check("operation" in inspect.signature(_identity.bind).parameters,
      "the invocation binding digest takes an operation")

from tools.capability.records import INVOCATION_FIELDS
check("operation" in INVOCATION_FIELDS,
      "the durable invocation record carries the operation")

print()
print("=" * 74)
print("PART 2 — the permitted request is supported")
print("=" * 74)

with TemporaryDirectory() as tmp:
    root = chain(tmp)
    before = inventory(root)
    verdict = verify(root)
    check(verdict.supported,
          f"the exact selected chain with a permitted operation is supported "
          f"({verdict.reason})")
    check(verdict.reason is None, "a supported verdict names no refusal")
    check(verdict.instance_id == "CINST-000002",
          "the verdict carries the selected instance")
    check(inventory(root) == before,
          "verification wrote nothing to the fabric")

print()
print("=" * 74)
print("PART 3 — each scope dimension refuses independently")
print("=" * 74)

CASES = [
    ("the operation is absent",
     {}, {"operation": None}, "operation-not-supplied"),
    ("the operation is empty text",
     {}, {"operation": "   "}, "operation-not-supplied"),
    ("the operation is not a string",
     {}, {"operation": 7}, "operation-not-supplied"),
    ("an unknown operation is requested",
     {}, {"operation": "delete"}, "operation-not-permitted-by-scope"),
    ("the scope permits no operations",
     {"capability-instance": {"effective_scope": dict(SCOPE, permitted_operations=[])}},
     {}, "operation-not-permitted-by-scope"),
    ("the capability is outside the permitted capabilities",
     {"capability-instance": {
         "effective_scope": dict(SCOPE, permitted_capabilities=["CAPDEF-0002"])}},
     {}, "capability-not-permitted-by-scope"),
    ("the classification is outside the permitted classifications",
     {"capability-instance": {
         "effective_scope": dict(SCOPE, permitted_data_classifications=["secret"])}},
     {}, "classification-not-permitted-by-scope"),
    ("the node identity is outside the permitted targets",
     {"capability-instance": {
         "effective_scope": dict(SCOPE, permitted_targets=["HOST-0002"])}},
     {}, "target-not-permitted-by-scope"),
    ("the permitted targets name the host record rather than the node",
     {"capability-instance": {
         "effective_scope": dict(SCOPE, permitted_targets=["CHOST-0001"])}},
     {}, "target-not-permitted-by-scope"),
    ("the effective scope is absent",
     {"capability-instance": {"effective_scope": None}}, {}, "invalid-effective-scope"),
    ("the effective scope is not a mapping",
     {"capability-instance": {"effective_scope": ["execute"]}}, {},
     "invalid-effective-scope"),
    ("a scope dimension is missing entirely",
     {"capability-instance": {"effective_scope": {
         "permitted_capabilities": ["CAPDEF-0001"],
         "permitted_operations": ["execute"],
         "permitted_data_classifications": ["internal"]}}},
     {}, "invalid-effective-scope"),
    ("a scope dimension holds something that is not text",
     {"capability-instance": {
         "effective_scope": dict(SCOPE, permitted_operations=[7])}},
     {}, "invalid-effective-scope"),
    ("the host the instance binds is absent",
     {"capability-host": None}, {}, "host-not-found"),
    ("the host declares no node identity",
     {"capability-host": {"node_identity_reference": None}}, {},
     "record-chain-incoherent"),
    ("the selection carries no request class",
     {"capability-selection": {"request_class": None}}, {},
     "record-chain-incoherent"),
]

for label, records, asked, expected in CASES:
    with TemporaryDirectory() as tmp:
        root = chain(tmp, **records)
        before = inventory(root)
        verdict = verify(root, **asked)
        check(not verdict.supported and verdict.reason == expected,
              f"{label} refuses as {expected} "
              f"(got supported={verdict.supported} reason={verdict.reason})")
        check(inventory(root) == before,
              f"{label}: the refusal wrote nothing")

print()
print("=" * 74)
print("PART 4 — the pre-existing refusals keep their vocabulary")
print("=" * 74)

PRIOR = [
    ("a selection that named no instance",
     {"capability-selection": {"selected_instance_id": None}}, {},
     "selection-recorded-no-instance"),
    ("a claimed instance the selection did not choose",
     {}, {"instance_id": "CINST-000009"}, "claimed-instance-not-selected"),
    ("an instance that is not admitted",
     {"capability-instance": {"lifecycle_state": "withdrawn"}}, {},
     "instance-not-admitted"),
    ("a superseded instance",
     {"capability-instance": {"superseded_by": "CINST-000003"}}, {},
     "instance-superseded"),
    ("an instance whose admission window has closed",
     {}, {"evaluated_at": EXPIRES + timedelta(hours=1)},
     "admission-window-not-open"),
    ("a package the instance does not bind",
     {}, {"capability_package_id": "CPKG-0009"}, "claimed-package-not-bound"),
    ("a contract whose effect class may not execute",
     {"capability-contract": {"effect_class": "side-effecting"}}, {},
     "effect-class-not-executable"),
]

for label, records, asked, expected in PRIOR:
    with TemporaryDirectory() as tmp:
        root = chain(tmp, **records)
        verdict = verify(root, **asked)
        check(not verdict.supported and verdict.reason == expected,
              f"{label} still refuses as {expected} "
              f"(got supported={verdict.supported} reason={verdict.reason})")

print()
print("=" * 74)
print("PART 5 — a scope refusal precedes package and contract resolution")
print("=" * 74)

# If the scope check ran after package resolution, removing the package would
# change the reason. It must not: the cheapest governed refusal wins, and an
# unpermitted operation must never reach a staging decision.
with TemporaryDirectory() as tmp:
    root = chain(tmp, **{"capability-package": None})
    verdict = verify(root, operation="delete")
    check(not verdict.supported
          and verdict.reason == "operation-not-permitted-by-scope",
          f"an unpermitted operation refuses before the package is resolved "
          f"(got {verdict.reason})")

with TemporaryDirectory() as tmp:
    root = chain(tmp, **{"capability-contract": None})
    verdict = verify(root, operation="delete")
    check(not verdict.supported
          and verdict.reason == "operation-not-permitted-by-scope",
          f"an unpermitted operation refuses before the contract is resolved "
          f"(got {verdict.reason})")

print()
print("=" * 74)
print("PART 6 — the operation is bound to the invocation evidence")
print("=" * 74)

payload = {"document": "hello"}
common = dict(payload=payload, invocation_id="INV-1", selection_id="CSEL-000001",
              instance_id="CINST-000002", capability_package_id="CPKG-0001",
              actor="primary-platform-operator")
execute_digest = _identity.bind(operation="execute", **common)
delete_digest = _identity.bind(operation="delete", **common)
check(execute_digest != delete_digest,
      "changing the operation changes the invocation binding digest")
check(_identity.bind(operation="execute", **common) == execute_digest,
      "the binding digest is stable for one operation")

print()
if FAILURES:
    print(f"FAILURES: {len(FAILURES)}")
    for item in FAILURES:
        print(f"  - {item}")
    sys.exit(1)
print("Invocation operation-authority validation passed.")
PYTHON
status=$?

if [[ -d "${PRODUCTION_FABRIC}" ]]; then
  ( cd "${PRODUCTION_FABRIC}" && find . -mindepth 1 -printf '%y %m %s %p\n' | sort ) > "${AFTER}"
  if diff -q "${BEFORE}" "${AFTER}" >/dev/null; then
    printf 'PASS: %s\n' "no production path changed while this suite ran"
  else
    printf 'FAIL: %s\n' "a production path changed while this suite ran" >&2
    status=1
  fi
fi

exit "${status}"
