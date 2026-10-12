#!/usr/bin/env bash
set -Eeuo pipefail

# A supervised invocation that lost supervision must be discoverable.
#
# UNPRIVILEGED AND ISOLATED. No sudo, no privileged helper, no Podman, no
# container, no production path. The reconciler is a stub; what is under test is
# which invocations the coordinator decides to ask about, not what the answer is.
#
# WHAT THIS EXISTS FOR
# ====================
# G11-BB Stage 3 ended unresolved, and while root-causing it the recovery
# surface turned out to be unable to see the invocation at all.
#
# `unresolved_invocations` keyed discovery on `CINV.adapter_identity`, which
# G11-AO added for the locally executed adapter and which is written before the
# adapter is entered. THE SUPERVISED PATH NEVER WRITES IT. `command_invoke`
# passes neither adapter nor execution binding by construction, so the field is
# null; and nothing fills it afterwards, because `CINV` is immutable
# pre-execution evidence and `record_terminal_result` "never touches the
# invocation record".
#
# So every supervised invocation was skipped. For G11-BB that reported the
# materially correct state by luck -- no container had been created -- but it
# would have reported the same had one been orphaned after `authorise-launch`.
#
# THE FIX IS NOT TO FILL THE FIELD LATER
# ======================================
# Making `CINV` mutable, or back-filling `adapter_identity` after the fact,
# would destroy the property that makes an interrupted execution attributable:
# the record is written before the adapter precisely so a crash mid-flight is
# still evidence. Discovery instead reads the LIFECYCLE TRANSITION JOURNAL,
# which `authorise_launch` writes before the privileged boundary is crossed and
# which is immutable thereafter. An invocation at or beyond `launch_authorized`
# with no terminal result is one where execution was authorised and its outcome
# was never established.
#
# `launch_authorized` and not `created`, deliberately: the container is created
# on the far side of the privilege drop and the state advances to `created` only
# once the coordinator learns of it, so between those two facts a container can
# exist that no state records.
#
# THE PROPERTIES THIS SUITE HOLDS
# ===============================
#   * A supervised invocation with a null adapter identity, at
#     `launch_authorized`, with no result, IS discovered.  <- the G11-BB gap
#   * Without the journal that same invocation is invisible -- the old defect,
#     pinned so a future refactor cannot quietly reintroduce it.
#   * A locally executed invocation carrying an adapter identity is STILL
#     discovered, with or without a journal. The old signature is not dropped.
#   * An invocation that only ever `reserved` is NOT discovered: capacity was
#     taken, launch was never authorised, no container can exist.
#   * An invocation with a terminal result is NOT discovered. It is resolved.
#   * The safety gate still writes nothing.

cd "$(dirname "$0")/.."

python3 - <<'PYTEST'
import os
import shutil
import sys
import tempfile

from tools.capability.execution import recovery
from tools.capability.execution import capacity as capacity_module
from tools.capability.execution import state as state_module
from tools.capability.execution.backing_store import (
    verify_backing_store, ObservedFilesystem)
from tools.capability.execution.canonical_json import serialise
from tools.capability.execution.mutation import CMUT_COUNTER
from tools.capability.execution.state import TRANSITIONS_DIRECTORY
from tools.capability.execution.capacity import LOCKS_DIRECTORY
from tools.capability.execution.types import LifecycleState

UUID = "12774bf1-cf2a-4c8c-ba19-42fd9a8a0a96"
failures = []


def check(label, condition):
    print(f"{'ok  ' if condition else 'FAIL'}  {label}")
    if not condition:
        failures.append(label)


def anchored(work):
    """One verified execution root, built as the capacity suite builds it."""
    base = os.path.join(work, "execution")
    for sub in ("root/mutations", "root/state", "root/" + TRANSITIONS_DIRECTORY,
                "root/" + LOCKS_DIRECTORY):
        os.makedirs(os.path.join(base, sub))
    with open(os.path.join(base, "backing-store.json"), "wb") as handle:
        handle.write(serialise({"filesystem_uuid": UUID,
                                "filesystem_type": "xfs",
                                "mount_point": "/data"}))
    with open(os.path.join(base, "root", CMUT_COUNTER), "wb") as handle:
        handle.write(b"000000000000\n")
    cfg = os.open(os.path.join(base, "backing-store.json"), os.O_RDONLY)
    rt = os.open(os.path.join(base, "root"), os.O_RDONLY | os.O_DIRECTORY)
    try:
        root = verify_backing_store(cfg, rt, observed=ObservedFilesystem(
            filesystem_uuid=UUID, filesystem_type="xfs",
            mount_point="/data", device_name="/dev/sdb1"))
    finally:
        os.close(cfg)
        os.close(rt)
    return base, root


class FakeStore:
    """Just the two record listings `unresolved_invocations` reads."""

    def __init__(self, invocations, results):
        self._invocations = invocations
        self._results = results

    def list_records(self, kind):
        return (self._invocations if kind == "capability-invocation"
                else self._results)


def invocation(cinv, adapter_identity=None, invocation_id=None):
    """One invocation record.

    `invocation_id` is the OPAQUE, operator-supplied identity and is a different
    thing from `invocation_record_id`. It defaults to the `CINV` only because
    most cases here do not care; the production shape is the two differing, and
    the cases that turn on that pass it explicitly. A fixture that always made
    them equal is what let the G11-BB-Z defect survive this suite.
    """
    return {"invocation_record_id": cinv,
            "invocation_id": cinv if invocation_id is None else invocation_id,
            "adapter_identity": adapter_identity}


# The real shape, taken from production: the operator names the invocation and
# the store names the record, and they are not the same string.
OPAQUE = "g11bb2-second-controlled-invoke"


work = tempfile.mkdtemp()
try:
    base, root = anchored(work)

    # CINV-000001: supervised, reached launch_authorized, no result.
    # Exactly the G11-BB shape.
    capacity_module.reserve(root, "CINV-000001")
    state_module.transition(root, "CINV-000001", LifecycleState.RESERVED,
                            LifecycleState.LAUNCH_AUTHORIZED)
    # CINV-000002: reserved only -- launch was never authorised.
    capacity_module.reserve(root, "CINV-000002")

    states = state_module.all_states(root)
    check("the journal records launch_authorized for CINV-000001",
          states.get("CINV-000001") is LifecycleState.LAUNCH_AUTHORIZED)
    check("the journal records reserved for CINV-000002",
          states.get("CINV-000002") is LifecycleState.RESERVED)

    # --- 1. the G11-BB gap -------------------------------------------------
    store = FakeStore([invocation("CINV-000001")], [])
    found = recovery.unresolved_invocations(store, execution_root=root)
    check("a supervised launch_authorized invocation is discovered",
          [item.invocation_id for item in found] == ["CINV-000001"])
    check("and it is reported by lifecycle state, not adapter identity",
          bool(found) and found[0].adapter_identity is None
          and found[0].lifecycle_state == "launch_authorized")

    # The regression this suite exists to prevent.
    check("without the journal the same invocation is invisible (the old defect)",
          recovery.unresolved_invocations(store) == ())

    # --- 2. the locally executed path is not dropped -----------------------
    local = FakeStore(
        [invocation("CINV-000009", adapter_identity="python-local-v1")], [])
    check("a local adapter invocation is discovered without a journal",
          [item.invocation_id
           for item in recovery.unresolved_invocations(local)] == ["CINV-000009"])
    check("a local adapter invocation is discovered with a journal too",
          [item.invocation_id
           for item in recovery.unresolved_invocations(
               local, execution_root=root)] == ["CINV-000009"])

    # --- 3. reserved-only is not discoverable ------------------------------
    reserved = FakeStore([invocation("CINV-000002")], [])
    check("a reserved-only invocation is not discovered",
          recovery.unresolved_invocations(reserved, execution_root=root) == ())

    # --- 4. a resolved invocation is not discoverable ----------------------
    resolved = FakeStore(
        [invocation("CINV-000001")],
        [{"invocation_record_id": "CINV-000001",
          "capability_result_id": "CRES-000001"}])
    check("an invocation with a terminal result is not discovered",
          recovery.unresolved_invocations(resolved, execution_root=root) == ())

    # --- 6. THE PRODUCTION SHAPE: an opaque invocation_id ------------------
    #
    # G11-BB-Z. The lifecycle journal is keyed by the CINV record id, because
    # that is what `authorise_launch` transitions on. Discovery looked the state
    # up by the OPAQUE `invocation_id`, so the lookup missed on every real
    # invocation and the supervised signature never fired. Both production
    # invocations sat at launch_authorized with no result and neither was
    # returned.
    #
    # Every case above used a fixture whose opaque id equalled the CINV, which
    # is the one shape the broken lookup handled -- so this suite passed while
    # the defect it exists to prevent was live.
    opaque = FakeStore([invocation("CINV-000001", invocation_id=OPAQUE)], [])
    found = recovery.unresolved_invocations(opaque, execution_root=root)
    check("a supervised invocation with an OPAQUE invocation_id is discovered",
          [item.invocation_record_id for item in found] == ["CINV-000001"])
    check("and it is reported at its journal lifecycle state",
          bool(found) and found[0].lifecycle_state == "launch_authorized")

    # What the reconciler is handed must be the CINV. `launcher.reconcile`
    # validates `^CINV-[0-9]{6}$` and the sudo grant pins the same shape, so an
    # opaque identity could never be reconciled -- it would refuse, the finding
    # would stay unresolved, and the invocation could never be cleared.
    check("the identity carried for reconciliation is the CINV, not the opaque id",
          bool(found) and found[0].invocation_id == "CINV-000001")

    handed = []
    findings = recovery.reconcile_unresolved(
        opaque,
        reconciler=lambda cinv: (handed.append(cinv) or
                                 {"invocation_id": cinv, "outcome": "absent",
                                  "final_absent": True}),
        execution_root=root)
    check("reconciliation is asked about the CINV", handed == ["CINV-000001"])
    check("and the reconciled invocation stops blocking",
          len(findings) == 1 and findings[0].final_absent is True)

    # --- 7. the safety gate must not pass vacuously ------------------------
    #
    # A gate that discovers nothing reports READY for the same reason an empty
    # store does, and cannot tell the two apart. With the opaque shape it
    # reported READY while an invocation sat at launch_authorized unproven.
    seen = []

    def refusing(cinv):
        seen.append(cinv)
        raise RuntimeError("the reconciliation helper refused")

    verdict = recovery.execution_safety(opaque, reconciler=refusing,
                                        execution_root=root)
    check("an unproven supervised invocation is INSPECTED, not skipped",
          seen == ["CINV-000001"])
    check("and blocks readiness until disposal is proven",
          verdict.state == recovery.NOT_READY and verdict.checked == 1
          and [f.invocation_record_id for f in verdict.unresolved] == ["CINV-000001"])

    proven = recovery.execution_safety(
        opaque,
        reconciler=lambda cinv: {"invocation_id": cinv, "outcome": "absent",
                                 "final_absent": True},
        execution_root=root)
    check("readiness returns only after the invocation was actually checked",
          proven.state == recovery.READY and proven.checked == 1
          and proven.unresolved == ())

    # An empty store is ready too -- but for a different reason, and the count
    # is what distinguishes a real check from a vacuous one.
    empty = recovery.execution_safety(
        FakeStore([], []), reconciler=refusing, execution_root=root)
    check("an empty store is ready with nothing checked",
          empty.state == recovery.READY and empty.checked == 0)

    # --- 5. the gate still writes nothing ----------------------------------
    transitions = os.path.join(base, "root", TRANSITIONS_DIRECTORY)
    before = sorted(os.listdir(transitions))
    recovery.execution_safety(
        store,
        reconciler=lambda cinv: {"invocation_id": cinv, "outcome": "absent",
                                 "final_absent": True},
        execution_root=root)
    check("the safety gate wrote nothing",
          sorted(os.listdir(transitions)) == before)
finally:
    shutil.rmtree(work, ignore_errors=True)

print()
if failures:
    print(f"{len(failures)} assertion(s) failed:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)
print("recovery discovery: all assertions hold")
PYTEST
