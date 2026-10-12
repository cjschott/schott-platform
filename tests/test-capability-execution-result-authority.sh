#!/usr/bin/env bash
set -Eeuo pipefail

# F7: a terminal result is sound only when execution authority is PROVABLE.
#
# WHY THIS SUITE EXISTS
# =====================
# The released validator tested for execution authority with
# `adapter_identity is not None` on the invocation record. The released
# supervised path never writes that field -- `coordinator.py` says so at the
# point of cause: "command_invoke supplies neither an adapter nor a binding,
# which is why adapter_identity is always null". So the validator asked for the
# one signal the released writer does not produce, and ignored the one it does.
#
# The result was that production -- produced entirely by the released path --
# was REJECTED by the released validator with EXIT_DENIED:
#
#   CINV-000002: result-without-execution-authority
#   CINV-000003: result-without-execution-authority
#
# WHAT THE AUTHORITY ACTUALLY IS. `launch.py` is normative and unambiguous:
#
#   "The lifecycle transition is the authority. RESERVED -> LAUNCH_AUTHORIZED is
#    committed first and is the only thing that decides whether a launch was
#    approved. The launch-authorisation record is a *projection* of that
#    decision, and the handoff is *materialisation* of it."
#
# So the journal is the authority and the projection is not. This suite pins the
# general invariant and -- more importantly -- pins that it still FAILS CLOSED,
# because the easy wrong fix is to suppress the finding or to accept the
# projection, and either would make a fabricated result validate.
#
# THE INVARIANT
# =============
# A terminal CRES is sound only if execution authority for its CINV is provable
# from durable evidence, which is exactly one of:
#
#   1. SUPERVISED  -- the append-only lifecycle journal contains a committed
#                     LAUNCH_AUTHORIZED transition for that CINV;
#   2. ADAPTER     -- the CINV record carries a non-null `adapter_identity`;
#   3. LEGACY      -- schema_version != INVOCATION_SCHEMA_VERSION, unchanged.
#
# Anything else is `result-without-execution-authority`.
#
# WHY CURRENT STATE IS NOT ENOUGH, which is the trap this suite is built around.
# `all_states()` returns the CURRENT state, and neither terminal state is the
# authority:
#
#   CONCLUDED  proves it -- ADR-0017: `launch_authorized` is the ONLY state that
#              reaches concluded.
#   ABANDONED  does NOT prove it -- abandonment.py: "only reserved and
#              launch_authorized are abandonable". An invocation abandoned from
#              `reserved` never had a launch authorised.
#
# Production's two flagged invocations differ exactly here: CINV-000003 is
# concluded, CINV-000002 is abandoned. Reading only the current state would
# accept a fabricated result on an invocation abandoned from `reserved`. So the
# evidence is the JOURNAL HISTORY, and cases 4 and 5 below are what make that
# distinction a requirement rather than a comment.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT

# Every case is a fixture built in-process against the released modules. No
# production path, no store root under /data, no governed mutator.
if ! (cd "${ROOT}" && python3 - "${WORK}" <<'HARNESS'
import os
import pathlib
import sys

sys.path.insert(0, ".")
from tools.capability import inspection
from tools.capability.execution.types import LifecycleState

work = pathlib.Path(sys.argv[1])
SCHEMA = inspection.RESULT_SCHEMA_VERSION
INV_SCHEMA = inspection.INVOCATION_SCHEMA_VERSION
FINDING = inspection.FINDING_RESULT_WITHOUT_AUTHORITY


# A REAL store over a temporary root, not a stand-in. `validate_store` also
# walks the record directories for partial-write residue, so a hand-made double
# would have to guess that surface; using the released store means the fixture
# cannot drift from what the validator actually reads.
from tools.capability.store import CapabilityStore

_seq = iter(range(1, 10_000))


def build(invocations, results):
    root = work / f"store-{next(_seq):04d}"
    root.mkdir()
    store = CapabilityStore(root, expected_uid=os.getuid(),
                            expected_gid=os.getgid())
    for record in invocations:
        store.write_atomic(
            store.path_for(inspection.INVOCATION_KIND,
                           record["invocation_record_id"]), record)
    for record in results:
        store.write_atomic(
            store.path_for(inspection.RESULT_KIND,
                           record["capability_result_id"]), record)
    return store


# THE FIXTURE SHAPES ARE PRODUCTION'S OWN, read-only, not invented. Taking the
# real CINV-000002 and CRES-000001 as templates means the fixture cannot drift
# from the shape the released writer produces -- which is the whole subject of
# this defect. CINV-000002's actual historical shape is therefore exercised
# directly rather than approximated.
import yaml

PRODUCTION = pathlib.Path("/data/kyri/capability-runtime")
_INV_TEMPLATE = None
_RES_TEMPLATE = None
if PRODUCTION.is_dir():
    with open(PRODUCTION / "capability-invocations" / "CINV-000002.yaml",
              encoding="utf-8") as handle:
        _INV_TEMPLATE = yaml.safe_load(handle)
    with open(PRODUCTION / "capability-results" / "CRES-000001.yaml",
              encoding="utf-8") as handle:
        _RES_TEMPLATE = yaml.safe_load(handle)


def _base_invocation():
    if _INV_TEMPLATE is not None:
        return dict(_INV_TEMPLATE)
    # Portable fallback: every required member, from the released field set, so
    # this suite is not host-only.
    return {name: None for name in inspection.INVOCATION_FIELDS} | {
        "kind": inspection.INVOCATION_KIND,
        "schema_version": INV_SCHEMA,
        "evidence": {"outcome": "execution-prepared"},
        "effect_class": "computational",
    }


def _base_result():
    if _RES_TEMPLATE is not None:
        return dict(_RES_TEMPLATE)
    return {name: None for name in inspection.RESULT_FIELDS} | {
        "kind": inspection.RESULT_KIND,
        "schema_version": SCHEMA,
        "outcome_class": "completed",
        "attempt_number": 1,
        "evidence": {"outcome": "completed"},
    }


def invocation(identity, *, adapter_identity=None, schema_version=INV_SCHEMA,
               outcome="execution-prepared"):
    record = _base_invocation()
    record["invocation_record_id"] = identity
    record["invocation_id"] = f"opaque-{identity}"
    record["schema_version"] = schema_version
    record["adapter_identity"] = adapter_identity
    record["evidence"] = dict(record.get("evidence") or {}, outcome=outcome)
    return record


def result(identity, cinv, *, outcome_class="completed"):
    record = _base_result()
    record["capability_result_id"] = identity
    record["invocation_record_id"] = cinv
    record["schema_version"] = SCHEMA
    record["outcome_class"] = outcome_class
    record["attempt_number"] = 1
    return record


def findings_for(store, **kwargs):
    report = inspection.validate_store(store, **kwargs)
    return list(report.findings)


results = []


def case(name, condition, detail=""):
    results.append((bool(condition), name, detail))


# Does the released validator even accept the keyword? If not, every case below
# that needs it is reported as the defect rather than as an error.
import inspect as _inspect
accepts = "launch_authorised" in _inspect.signature(
    inspection.validate_store).parameters
case("validate_store accepts a supervised-authority argument", accepts,
     "" if accepts else "signature is "
     f"{_inspect.signature(inspection.validate_store)}")

kw = {"launch_authorised": frozenset()} if accepts else {}


def authorised(*cinvs):
    return {"launch_authorised": frozenset(cinvs)} if accepts else {}


# ---- 1. the production-shaped supervised success ---------------------------
# A prepared v2 invocation, a terminal result, no adapter_identity, and the
# journal proving LAUNCH_AUTHORIZED. This is exactly what production holds.
store = build([invocation("CINV-000003")], [result("CRES-000002", "CINV-000003")])
got = findings_for(store, **authorised("CINV-000003"))
case("1. supervised success with journalled launch authority validates clean",
     got == [], f"findings={got}")

# ---- 2. the same shape with NO supervised authority -----------------------
# The journal proves nothing for it. This must still fail closed: it is the
# fabricated-result case.
got = findings_for(store, **authorised())
case("2. the same shape with no journalled authority still FAILS CLOSED",
     got == [f"CINV-000003: {FINDING}"], f"findings={got}")

# ---- 3. a fabricated result for an invocation that never launched ---------
store = build([invocation("CINV-000009")], [result("CRES-000009", "CINV-000009")])
got = findings_for(store, **authorised("CINV-000003"))
case("3. a fabricated result for an un-launched invocation fails",
     got == [f"CINV-000009: {FINDING}"], f"findings={got}")

# ---- 4. authority naming ANOTHER CINV does not transfer ------------------
# The journal is keyed per CINV, so authority for one cannot authorise another.
store = build([invocation("CINV-000008")], [result("CRES-000008", "CINV-000008")])
got = findings_for(store, **authorised("CINV-000003", "CINV-000002"))
case("4. launch authority for other invocations does not authorise this one",
     got == [f"CINV-000008: {FINDING}"], f"findings={got}")

# ---- 5. abandoned-from-reserved must NOT be accepted ---------------------
# The trap. `abandoned` is a legal closure from `reserved`, so an invocation
# that never launched can still be abandoned. If the fix read the CURRENT state
# and treated a terminal state as proof, this case would wrongly pass.
store = build([invocation("CINV-000007")], [result("CRES-000007", "CINV-000007")])
got = findings_for(store, **authorised())
case("5. abandoned without a launch_authorized transition still fails",
     got == [f"CINV-000007: {FINDING}"], f"findings={got}")

# ---- 6. adapter-bound authority remains valid ---------------------------
# The architecturally permitted local path. Latent, not live, but it must not
# regress.
store = build([invocation("CINV-000006", adapter_identity="python-podman-v1")],
             [result("CRES-000006", "CINV-000006")])
got = findings_for(store, **authorised())
case("6. adapter-bound authority is still accepted with no journal",
     got == [], f"findings={got}")

# ---- 7. legacy: the guard in the authority branch is UNREACHABLE --------
# `_shape` rejects any invocation whose schema_version is not the current one as
# `record-malformed`, so a v1 invocation never reaches the authority branch and
# the `not legacy` guard there can never fire. Asserted as the fact it is rather
# than as the behaviour the branch appears to promise -- and the guard is left
# exactly as accepted, because removing it would be an unrelated change.
store = build([invocation("CINV-000005", schema_version=1)],
             [result("CRES-000005", "CINV-000005")])
got = findings_for(store, **authorised())
case("7. a legacy invocation is caught by the shape check, so the authority "
     "branch's legacy guard is unreachable",
     got == ["CRES-000005: result-without-invocation",
             "capability-invocation: record-malformed"], f"findings={got}")

# ---- 8. the other findings are untouched -------------------------------
# A refusal result under a prepared invocation is still a mismatch, and more
# than one terminal result is still a mismatch -- proving the fix did not
# collapse the branch it sits in.
store = build([invocation("CINV-000004")],
             [result("CRES-000004", "CINV-000004", outcome_class="refused")])
got = findings_for(store, **authorised("CINV-000004"))
case("8a. a refusal result under a prepared invocation is still a mismatch",
     got == [f"CINV-000004: {inspection.FINDING_OUTCOME_MISMATCH}"], f"findings={got}")

store = build([invocation("CINV-000004")],
             [result("CRES-000004", "CINV-000004"),
              result("CRES-000014", "CINV-000004")])
got = findings_for(store, **authorised("CINV-000004"))
case("8b. more than one terminal result is still a mismatch",
     got == [f"CINV-000004: {inspection.FINDING_OUTCOME_MISMATCH}"], f"findings={got}")

# ---- 9. a prepared invocation with no result stays unreported ----------
store = build([invocation("CINV-000010")], [])
got = findings_for(store, **authorised())
case("9. prepared with no result is still not reported",
     got == [], f"findings={got}")

# ---- 10. the interrupted case survives --------------------------------
store = build([invocation("CINV-000011", adapter_identity="python-podman-v1")], [])
got = findings_for(store, **authorised())
case("10. adapter bound with no result is still execution-interrupted",
     got == [f"CINV-000011: {inspection.FINDING_INTERRUPTED_EXECUTION}"],
     f"findings={got}")

# ---- 11. ABANDONED/CONCLUDED are off the linear order ------------------
# Pinned because the fix must not be tempted to read the enum positionally to
# decide authority.
case("11. abandoned and concluded are not positionally after launch_authorized",
     LifecycleState.ABANDONED.value == "abandoned"
     and LifecycleState.CONCLUDED.value == "concluded"
     and list(LifecycleState)[-2:] == [LifecycleState.ABANDONED,
                                       LifecycleState.CONCLUDED])

print()
bad = 0
for ok, name, detail in results:
    if ok:
        print(f"PASS: {name}")
    else:
        bad += 1
        print(f"FAIL: {name}" + (f" -- {detail}" if detail else ""), file=sys.stderr)
print()
sys.exit(1 if bad else 0)
HARNESS
); then
  fail "the result-authority invariant does not hold"
else
  pass "every result-authority case holds"
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Result-authority validation passed.\n'
else
  printf 'Result-authority validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
