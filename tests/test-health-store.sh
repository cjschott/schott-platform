#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0006-H6 Health store.
#
# B1 (the append-only store and its filesystem boundary) and B2 (sequence
# allocation and identifier widths), as assigned by ENG-0006-D.
#
# FIXTURE ROOTS ONLY. Every store in this suite is built under a scratch
# directory. The production root `/var/lib/kyri/health` is created by H18 and
# this suite asserts that H6 refuses to provision it.
#
# THE TEST ORACLE IS THE COMMITTED SCHEMA AND ADR-0013, NOT THE MODULE.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

python3 - "${ROOT}" <<'PY'
import atexit
import os
import shutil
import stat
import sys
import tempfile
import threading
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root))
failures = 0


def check(condition, description):
    global failures
    if condition:
        print(f"PASS: {description}")
    else:
        print(f"FAIL: {description}", file=sys.stderr)
        failures += 1


import yaml  # noqa: E402

SCHEMAS = {}
for name in ("envelope", "observation", "state", "recommendation"):
    SCHEMAS[name] = yaml.safe_load(
        (root / f"platform-model/schemas/capability-health-{name}.schema.yaml").read_text())
DEG = yaml.safe_load(
    (root / "platform-model/schemas/capability-degradation-event.schema.yaml").read_text())
BEAT = yaml.safe_load(
    (root / "platform-model/schemas/capability-heartbeat.schema.yaml").read_text())

print("--- the oracle is the committed schema ---")
check(SCHEMAS["envelope"]["id_pattern"] == "^CHENV-[0-9]{4}$",
      "the envelope schema declares a FOUR-digit identifier")
for name, prefix in (("observation", "CHOBS"), ("state", "CHSTATE"),
                     ("recommendation", "CHREC")):
    check(SCHEMAS[name]["id_pattern"] == f"^{prefix}-[0-9]{{6}}$",
          f"the {name} schema declares a six-digit identifier")
check(DEG["id_pattern"] == "^CHDEG-[0-9]{6}$",
      "the degradation-event schema declares a six-digit identifier")
check(BEAT["id_pattern"] == "^CHBEAT-[0-9]{6}$",
      "the heartbeat schema declares a six-digit identifier")
check(SCHEMAS["state"]["mutability"] == "immutable",
      "health records are declared immutable")
check(SCHEMAS["state"]["update_methods"] == "none"
      and SCHEMAS["state"]["delete_methods"] == "none",
      "the schema declares no update and no delete method")
check(SCHEMAS["state"]["append_only_history"] is True,
      "the schema declares append-only history")

try:
    from tools.health import store as S
    from tools.health import records as H
    import tools.health as PKG
    print("PASS: tools.health.store imports")
except Exception as error:  # noqa: BLE001
    print(f"FAIL: import failed: {type(error).__name__}: {error}", file=sys.stderr)
    raise SystemExit(1)

for name in ("HealthStore", "HealthStoreError"):
    if hasattr(S, name):
        print(f"PASS: the store module exposes {name}")
    else:
        print(f"FAIL: the store module does not expose {name}", file=sys.stderr)
        failures += 1
if not hasattr(S, "HealthStore"):
    print(f"\nHealth store validation FAILED with {failures + 1} error(s).",
          file=sys.stderr)
    raise SystemExit(1)

HealthStore = S.HealthStore
StoreError = S.HealthStoreError

# ADR-0013's six families, in the order the committed record model declares
# them. The store must not invent a second ordering.
FAMILIES = ("capability-health-envelope", "capability-health-observation",
            "capability-health-state", "capability-degradation-event",
            "capability-health-recommendation", "capability-heartbeat")

# --- fixtures ---------------------------------------------------------------
SCRATCH = Path(tempfile.mkdtemp(prefix="h6-store-"))
# Removed even when an assertion raises rather than merely failing. This suite
# creates directories, so an aborted run that left them behind would quietly
# litter the host -- which is the opposite of what a store suite should model.
# The explicit removal at the end stays, so that it is also ASSERTED.
atexit.register(shutil.rmtree, SCRATCH, True)
_n = [0]


def fresh_root(name=None):
    _n[0] += 1
    path = SCRATCH / (name or f"root-{_n[0]:03d}")
    path.mkdir(parents=True, exist_ok=True)
    return path


def envelope(identifier="CHENV-0001"):
    return H.parse("capability-health-envelope", {
        "envelope_id": identifier, "envelope_version": 1,
        "subject_type": "capability-instance", "subject_id": "CINST-000007",
        "dimensions": {"latency": {
            "dimension": "latency", "unit": "milliseconds",
            "entry_condition": {"operator": "gt", "value": "2000"},
            "exit_condition": {"operator": "le", "value": "1500"},
            "hysteresis": {"kind": "duration", "seconds": 120,
                           "max_gap_seconds": 30, "min_samples": 3},
            "freshness_policy_seconds": 60,
            "aggregation": {"kind": "instant"}}},
        "evaluation": "worst-dimension-wins", "provenance": {"tool": "test"}})


def observation(identifier="CHOBS-000001"):
    return H.parse("capability-health-observation", {
        "observation_id": identifier, "subject_type": "capability-instance",
        "subject_id": "CINST-000007", "dimension": "latency",
        "measured_value": "1500", "unit": "milliseconds",
        "observed_at": "2026-10-22T12:00:00+00:00", "collector_id": "COLL-0001",
        "source_fingerprint": "sha256:abc", "collection_status": "collected",
        "provenance": {"tool": "test"}})


def refuses(label, thunk, *, forbidden=None, kind=None):
    global failures
    try:
        thunk()
    except (kind or StoreError) as error:
        if forbidden is not None and str(forbidden) in str(error):
            print(f"FAIL: {label}: the refusal echoed {forbidden!r}", file=sys.stderr)
            failures += 1
            return None
        print(f"PASS: {label}")
        return error
    except Exception as error:  # noqa: BLE001
        print(f"FAIL: {label}: raised {type(error).__name__}, not a store error: "
              f"{error}", file=sys.stderr)
        failures += 1
        return None
    print(f"FAIL: {label}: accepted", file=sys.stderr)
    failures += 1
    return None


# --- the six families and the directory layout ------------------------------
print("--- six closed record families, and a dedicated sequence directory ---")
check(tuple(HealthStore.record_dirs) == FAMILIES,
      "the store declares exactly the six Health families, in order")
check(tuple(HealthStore.record_dirs) == tuple(H.KINDS),
      "and in the record model's own declared order, not a second ordering")
check(set(HealthStore.record_dirs) == set(H.KINDS),
      "and exactly the families the record model declares")
check(HealthStore.extra_dirs == ("sequences",),
      "the store declares a dedicated sequences directory")
check(len(set(HealthStore.record_dirs.values())) == 6,
      "the six directory names are distinct")
for kind, directory in HealthStore.record_dirs.items():
    check(directory == kind + "s",
          f"{kind} maps to the pluralised convention {kind}s")

store_root = fresh_root("layout")
store = HealthStore(store_root)
for kind, directory in HealthStore.record_dirs.items():
    check((store_root / directory).is_dir(), f"the {directory} directory is created")
check((store_root / "sequences").is_dir(), "the sequences directory is created")
check(len([p for p in store_root.iterdir() if p.is_dir()]) == 7,
      "exactly seven directories exist: six families and sequences")

print("--- permissions are 0700 on directories and 0600 on files ---")
for directory in (*HealthStore.record_dirs.values(), "sequences"):
    mode = stat.S_IMODE((store_root / directory).stat().st_mode)
    check(mode == 0o700, f"{directory} is 0700, not {oct(mode)}")
written = store.write_record("capability-health-envelope", envelope())
check(stat.S_IMODE(written.stat().st_mode) == 0o600,
      "a written record is 0600")
check(written.name == "CHENV-0001.yaml",
      "the record is named for its identifier")
seq = store_root / "sequences"
store.allocate_id("capability-health-observation")
for path in seq.glob("*.seq"):
    check(stat.S_IMODE(path.stat().st_mode) == 0o600,
          f"the sequence file {path.name} is 0600")

# --- identifier widths (B2) -------------------------------------------------
print("--- identifier widths: CHENV four digits, the other five six ---")
check(HealthStore.id_widths["capability-health-envelope"] == 4,
      "the envelope width is declared as 4")
for kind in FAMILIES[1:]:
    check(HealthStore.id_widths[kind] == 6, f"the {kind} width is declared as 6")
widths_root = fresh_root("widths")
widths = HealthStore(widths_root)
EXPECTED_FIRST = {
    "capability-health-envelope": "CHENV-0001",
    "capability-heartbeat": "CHBEAT-000001",
    "capability-health-observation": "CHOBS-000001",
    "capability-health-state": "CHSTATE-000001",
    "capability-degradation-event": "CHDEG-000001",
    "capability-health-recommendation": "CHREC-000001",
}
for kind, expected in EXPECTED_FIRST.items():
    got = widths.allocate_id(kind)
    check(got == expected, f"{kind} allocates {expected}, got {got}")
    check(H.PATTERNS[kind].fullmatch(got) is not None,
          f"and {got} satisfies its own committed pattern")

print("--- allocation is monotonic, and never reuses an identifier ---")
mono_root = fresh_root("mono")
mono = HealthStore(mono_root)
issued = [mono.allocate_id("capability-health-observation") for _ in range(25)]
check(issued == sorted(issued), "allocation is monotonic")
check(len(set(issued)) == 25, "and issues no duplicate")
check(issued[0] == "CHOBS-000001" and issued[-1] == "CHOBS-000025",
      "the sequence runs 000001..000025 without a gap")

print("--- width exhaustion refuses rather than rolling over ---")
ex_root = fresh_root("exhaust")
ex = HealthStore(ex_root)
(ex_root / "sequences" / "capability-health-envelope.seq").write_text("9998\n")
check(ex.allocate_id("capability-health-envelope") == "CHENV-9999",
      "the last four-digit envelope identifier is issued")
refuses("a fifth envelope digit is refused rather than rolled over",
        lambda: ex.allocate_id("capability-health-envelope"))
(ex_root / "sequences" / "capability-health-observation.seq").write_text("999998\n")
check(ex.allocate_id("capability-health-observation") == "CHOBS-999999",
      "the last six-digit observation identifier is issued")
refuses("a seventh observation digit is refused rather than rolled over",
        lambda: ex.allocate_id("capability-health-observation"))
check(not (ex_root / "capability-health-envelopes" / "CHENV-10000.yaml").exists(),
      "no over-width record was created")

print("--- a refused write does not make its identifier reusable ---")
reuse_root = fresh_root("reuse")
reuse = HealthStore(reuse_root)
first = reuse.allocate_id("capability-health-observation")
reuse.write_record("capability-health-observation", observation(first))
refuses("rewriting an existing record is refused as immutable",
        lambda: reuse.write_record("capability-health-observation", observation(first)))
second = reuse.allocate_id("capability-health-observation")
check(second != first, "the next allocation does not reuse the written identifier")
check(second == "CHOBS-000002", "and advances by one")
# A write refused for its own reasons must not roll the sequence backwards.
third = reuse.allocate_id("capability-health-observation")
check(third == "CHOBS-000003", "a refused write leaves the sequence advanced")

print("--- an existing record filename is never overwritten by allocation ---")
skip_root = fresh_root("skip")
skip = HealthStore(skip_root)
planted = skip_root / "capability-health-observations" / "CHOBS-000001.yaml"
planted.write_text("observation_id: CHOBS-000001\n")
allocated = skip.allocate_id("capability-health-observation")
check(allocated == "CHOBS-000002",
      "allocation skips an identifier whose file already exists")
check(planted.read_text() == "observation_id: CHOBS-000001\n",
      "and the planted file is untouched")

print("--- concurrent allocation is serialised ---")
conc_root = fresh_root("concurrent")
conc = HealthStore(conc_root)
collected: list = []
lock = threading.Lock()


def allocate_many():
    local = [conc.allocate_id("capability-health-state") for _ in range(20)]
    with lock:
        collected.extend(local)


threads = [threading.Thread(target=allocate_many) for _ in range(4)]
for t in threads:
    t.start()
for t in threads:
    t.join()
check(len(collected) == 80, "eighty identifiers were allocated")
check(len(set(collected)) == 80, "every concurrently allocated identifier is unique")
check(sorted(collected)[0] == "CHSTATE-000001"
      and sorted(collected)[-1] == "CHSTATE-000080",
      "and they form an unbroken run under concurrency")
check((conc_root / "sequences" / "capability-health-state.seq").read_text().strip()
      == "80", "the sequence file records the final value")

print("--- sequence files stay inside the store root ---")
for path in (conc_root / "sequences").glob("*.seq"):
    check(path.resolve().is_relative_to(conc_root.resolve()),
          f"{path.name} resolves inside the store root")
check(len(list((widths_root / "sequences").glob("*.seq"))) == 6,
      "six sequence files exist, one per family")

# --- append-only -------------------------------------------------------------
print("--- the store is append-only: no update and no delete surface ---")
for banned in ("update", "update_record", "delete", "delete_record", "remove",
               "remove_record", "overwrite", "replace", "replace_record",
               "truncate", "purge", "rewrite"):
    check(not hasattr(HealthStore, banned),
          f"HealthStore exposes no {banned}()")
ap_root = fresh_root("append")
ap = HealthStore(ap_root)
ap.write_record("capability-health-observation", observation("CHOBS-000001"))
refuses("an existing record cannot be replaced",
        lambda: ap.write_record("capability-health-observation",
                                observation("CHOBS-000001")))
body = (ap_root / "capability-health-observations" / "CHOBS-000001.yaml").read_text()
refuses("and a second attempt still refuses",
        lambda: ap.write_record("capability-health-observation",
                                observation("CHOBS-000001")))
check((ap_root / "capability-health-observations" / "CHOBS-000001.yaml").read_text()
      == body, "the stored bytes are unchanged by the refused writes")

# --- atomicity ---------------------------------------------------------------
print("--- atomic write with exclusive temporary creation ---")
check(HealthStore.exclusive_temporary_create is True,
      "the store declares exclusive temporary creation")
tmp_root = fresh_root("atomic")
tmp = HealthStore(tmp_root)
directory = tmp_root / "capability-health-observations"
squatter = directory / ".CHOBS-000001.tmp"
squatter.write_text("someone else's interrupted write\n")
refuses("a pre-existing temporary artefact is refused, not truncated",
        lambda: tmp.write_record("capability-health-observation",
                                 observation("CHOBS-000001")))
check(squatter.read_text() == "someone else's interrupted write\n",
      "and the pre-existing artefact is left exactly as it was")
check(not (directory / "CHOBS-000001.yaml").exists(),
      "no record was committed behind the refusal")
problems = tmp.validate()
check(any("CHOBS-000001" in p and "tmp" in p for p in problems),
      "validate() REPORTS the temporary residue")
check(squatter.exists(), "and validate() does not repair or remove it")
squatter.unlink()
check(tmp.write_record("capability-health-observation",
                       observation("CHOBS-000001")).is_file(),
      "with the artefact cleared, the write succeeds")
check(not squatter.exists(), "and leaves no temporary of its own behind")

# --- validation --------------------------------------------------------------
print("--- validation reads each family's identity field, not `id` ---")
val_root = fresh_root("validate")
val = HealthStore(val_root)
val.write_record("capability-health-envelope", envelope("CHENV-0001"))
val.write_record("capability-health-observation", observation("CHOBS-000001"))
check(val.validate() == [],
      "a clean store validates with no problems")
# A Health record carries `envelope_id`, never `id`. A validator reading `id`
# would report every correct record as broken.
stored = yaml.safe_load(
    (val_root / "capability-health-envelopes" / "CHENV-0001.yaml").read_text())
check("id" not in stored and "envelope_id" in stored,
      "the stored envelope carries envelope_id and no `id` key")
bad = val_root / "capability-health-observations" / "CHOBS-000002.yaml"
bad.write_text("observation_id: CHOBS-000099\n")
problems = val.validate()
check(any("CHOBS-000002" in p for p in problems),
      "a filename that disagrees with its identity field is reported")
bad.unlink()
nonmap = val_root / "capability-health-states" / "CHSTATE-000001.yaml"
nonmap.write_text("- not a mapping\n")
check(any("CHSTATE-000001" in p for p in val.validate()),
      "a file that is not a record mapping is reported")
nonmap.unlink()
missing = val_root / "capability-degradation-events" / "CHDEG-000001.yaml"
missing.write_text("event_id: ''\n")
check(any("CHDEG-000001" in p for p in val.validate()),
      "an empty identity field is reported")
missing.unlink()
corrupt = val_root / "capability-health-recommendations" / "CHREC-000001.yaml"
corrupt.write_text("recommendation_id: [unclosed\n")
problems = val.validate()
check(any("CHREC-000001" in p for p in problems),
      "an unreadable file is REPORTED rather than raised")
corrupt.unlink()
link = val_root / "capability-health-observations" / "CHOBS-000002.yaml"
os.symlink(SCRATCH / "elsewhere.yaml", link)
check(any("CHOBS-000002" in p for p in val.validate()),
      "a record file that is a symbolic link is reported")
link.unlink()
# A file whose name AND identity field both carry a trailing newline. Under
# `match` the pattern accepts it and the filename agrees with it, so it would
# be reported as a perfectly valid record; only fullmatch rejects it.
newline_file = val_root / "capability-health-observations" / "CHOBS-000003\n.yaml"
newline_file.write_text('observation_id: "CHOBS-000003\\n"\n')
check(newline_file.stem == "CHOBS-000003\n",
      "the fixture filename really does carry the newline")
problems = val.validate()
check(any("CHOBS-000003" in p for p in problems),
      "a newline-bearing identifier is reported, not blessed")
newline_file.unlink()
check(val.validate() == [], "and the store is clean again once they are removed")

print("--- validation is deterministic and repairs nothing ---")
det_root = fresh_root("deterministic")
det = HealthStore(det_root)
for identifier in ("CHOBS-000003", "CHOBS-000001", "CHOBS-000002"):
    (det_root / "capability-health-observations" / f"{identifier}.yaml").write_text(
        "observation_id: CHOBS-999999\n")
(det_root / "capability-health-states" / ".CHSTATE-000001.tmp").write_text("x")
runs = {tuple(det.validate()) for _ in range(10)}
check(len(runs) == 1, "ten validate() runs return one identical ordered list")
first_run = list(runs)[0]
check(list(first_run) == sorted(first_run) or len(first_run) == len(set(first_run)),
      "the reported problems are in a stable order")
before = sorted(p.name for p in det_root.rglob("*") if p.is_file())
det.validate()
after = sorted(p.name for p in det_root.rglob("*") if p.is_file())
check(before == after, "validate() changed no file on disk")

print("--- counts and listing are deterministic ---")
counts = val.counts()
check(counts["capability-health-envelope"] == 1
      and counts["capability-health-observation"] == 1,
      "counts() reports one envelope and one observation")
check(set(counts) == set(FAMILIES), "counts() covers all six families")
listed = [val.list_records("capability-health-observation") for _ in range(5)]
check(all(entry == listed[0] for entry in listed),
      "list_records() is deterministic across repeats")

# --- reading without provisioning -------------------------------------------
print("--- open_for_read provisions nothing ---")
absent = SCRATCH / "never-created"
check(not absent.exists(), "the root does not exist beforehand")
reader = HealthStore.open_for_read(absent)
check(not absent.exists(), "open_for_read did not create the root")
check(reader.list_records("capability-health-observation") == [],
      "an absent store reads as empty rather than raising")
check(reader.counts() == {kind: 0 for kind in FAMILIES},
      "and counts zero for every family")
check(reader.validate() == [], "and validates as having no problems")
check(not absent.exists(), "and still did not create the root")

# --- root safety -------------------------------------------------------------
print("--- a repository root is refused unless a fixture opts in ---")
refuses("a store root inside this repository is refused",
        lambda: HealthStore(root / "tools" / "health" / "scratch-store"))
refuses("the repository root itself is refused",
        lambda: HealthStore(root))
opted = SCRATCH / "opt-in-probe"
check(HealthStore(opted, allow_repository_root=True).root == opted.resolve(),
      "an explicit fixture opt-in is honoured outside the repository")
for bad in ("", "   ", None):
    refuses(f"a root of {bad!r} is refused", lambda b=bad: HealthStore(b))

print("--- the production root is never provisioned ---")
refuses("initialising the production Health root is refused",
        lambda: HealthStore("/var/lib/kyri/health"))
check(not Path("/var/lib/kyri/health").exists(),
      "and /var/lib/kyri/health still does not exist")
refuses("initialising inside the production Health root is refused",
        lambda: HealthStore("/var/lib/kyri/health/capability-health-observations"))
check(not Path("/var/lib/kyri/health").exists(),
      "and it still does not exist after that attempt")

print("--- no Fabric or Trust write path, by path and by module ---")
for plane in ("/var/lib/kyri/fabric", "/var/lib/kyri/trust"):
    refuses(f"a store root at {plane} is refused",
            lambda p=plane: HealthStore(p))
    refuses(f"a store root inside {plane} is refused",
            lambda p=plane: HealthStore(p + "/capability-health-observations"))
source = (root / "tools/health/store.py").read_text()
imports = [line for line in source.splitlines()
           if line.startswith(("import ", "from "))]
for plane in ("tools.fabric", "tools.trust", "tools.capability",
              "tools.collectors", "..fabric", "..trust", "..capability"):
    check(not any(plane in line for line in imports),
          f"the store module imports nothing from {plane}")
check(any("immutable_store" in line for line in imports),
      "and it imports the shared ImmutableStore, as B1 requires")

print("--- symlink escape and traversal are refused ---")
# A root that is a symlink pointing at another plane's store must not be
# followed into it: resolving a symlink is not the same as trusting it.
link_root = SCRATCH / "symlinked-root"
decoy = fresh_root("decoy-target")
os.symlink(decoy, link_root)
check(link_root.is_symlink(), "the fixture root is a symlink")
refuses("a store root that is a symlink is refused",
        lambda: HealthStore(link_root))
plane_link = SCRATCH / "plane-link"
os.symlink("/var/lib/kyri/fabric", plane_link)
refuses("a symlink pointing into the Fabric store is refused",
        lambda: HealthStore(plane_link))
# A planted symlink inside a record directory must not redirect a write.
esc_root = fresh_root("escape")
esc = HealthStore(esc_root)
outside = SCRATCH / "outside-target.yaml"
hijack = esc_root / "capability-health-observations" / "CHOBS-000001.yaml"
os.symlink(outside, hijack)
refuses("writing through a planted symlink is refused",
        lambda: esc.write_record("capability-health-observation",
                                 observation("CHOBS-000001")))
check(not outside.exists(),
      "and nothing was written outside the store root")
# The write above is also refused by the shared write path, because os.link
# fails on an existing name. Reading is not: without the store's own check, a
# record read through a planted symlink would return content from OUTSIDE the
# store and report it as stored. That is the case that proves the check.
outside.write_text("observation_id: CHOBS-000001\nsmuggled: true\n")
refuses("reading a record through a planted symlink is refused",
        lambda: esc.read_record("capability-health-observation", "CHOBS-000001"))
refuses("and resolving its path is refused",
        lambda: esc.path_for("capability-health-observation", "CHOBS-000001"))
check("smuggled" not in str(esc.validate()),
      "and validate() never reports the symlink target's contents")
refuses("allocation refuses rather than skipping a symlinked record name",
        lambda: esc.allocate_id("capability-health-observation"))
outside.unlink()
dir_link = esc_root / "capability-health-states"
shutil.rmtree(dir_link)
os.symlink(SCRATCH / "decoy-target", dir_link)
refuses("a symlinked record directory is refused",
        lambda: esc.path_for("capability-health-state", "CHSTATE-000001"))
refuses("and reading through it is refused too",
        lambda: esc.list_records("capability-health-state"))
check(any("capability-health-states" in p for p in esc.validate()),
      "and validate() reports the symlinked directory")
# Identifier-shaped traversal must never reach path construction.
trav = fresh_root("traversal")
trav_store = HealthStore(trav)
for attempt in ("../../etc/passwd", "..", "CHOBS-000001/../../x",
                "/etc/passwd", "CHOBS-00000", "CHOBS-0000001",
                "chobs-000001", "CHOBS-000001.yaml", "CHOBS-000001\n",
                "CHOBS-000001\n/x"):
    refuses(f"path_for refuses the identifier {attempt!r}",
            lambda a=attempt: trav_store.path_for("capability-health-observation", a))
check(sorted(p.name for p in (trav / "capability-health-observations").iterdir()) == [],
      "and no file was created by any traversal attempt")
refuses("path_for refuses an unknown record kind",
        lambda: trav_store.path_for("capability-health-nonsense", "CHOBS-000001"))

print("--- the identity field is also the kind check ---")
mis_root = fresh_root("mismatch")
mis = HealthStore(mis_root)
refuses("an observation record offered as a state is refused",
        lambda: mis.write_record("capability-health-state", observation()))
refuses("an observation record offered as an envelope is refused",
        lambda: mis.write_record("capability-health-envelope", observation()))
refuses("an envelope record offered as an observation is refused",
        lambda: mis.write_record("capability-health-observation", envelope()))
refuses("a record offered to an unknown kind is refused",
        lambda: mis.write_record("capability-health-nonsense", observation()))
check(mis.validate() == [], "and nothing was written by any of them")

print("--- a trailing newline never reaches a filename ---")
# `^...$` with re.match() admits a trailing newline, so an identifier carrying
# one passes the record layer. The store must not turn that into a filename.
nl_root = fresh_root("newline")
nl = HealthStore(nl_root)
refuses("an identifier with a trailing newline is refused by path_for",
        lambda: nl.path_for("capability-health-observation", "CHOBS-000001\n"))
# ENG-0006-H6A / Q-H6-4. The record layer now refuses the newline itself, so
# no such record can be built to hand to the store. The store's own refusal
# above is retained as the second of two independent barriers: the store is
# what turns an identifier into a filename, so it must not depend on the
# parser having been correct.
refuses("the record layer refuses to build the record at all",
        lambda: observation("CHOBS-000002\n"), kind=Exception)

print("--- the parser and the store agree on identifier validity ---")
# Q-H6-4 was a DISAGREEMENT: the parser accepted an identifier the store had
# to refuse. Agreement is asserted directly, over one shared candidate set,
# rather than inferred from the two layers having similar code.
agree = HealthStore(fresh_root("agreement"))
CANDIDATES = ("CHOBS-000001", "CHOBS-000001\n", "CHOBS-000001\r\n",
              "CHOBS-000001\r", "CHOBS-000001\t", "CHOBS-000001 ",
              " CHOBS-000001", "\nCHOBS-000001", "CHOBS-000001\nx",
              "CHOBS-000001\nCHOBS-000002", "CHOBS-000001x", "CHOBS-000001.yaml",
              "CHOBS-00001", "CHOBS-0000001", "chobs-000001", "CHOBS-000001/..",
              "../CHOBS-000001", "CHOBS-000001\x00", "")
accepted_by_both = 0
for candidate in CANDIDATES:
    try:
        observation(candidate)
        parser_accepts = True
    except Exception:  # noqa: BLE001
        parser_accepts = False
    try:
        agree.path_for("capability-health-observation", candidate)
        store_accepts = True
    except StoreError:
        store_accepts = False
    check(parser_accepts == store_accepts,
          f"parser and store agree on {candidate!r}: "
          f"{'both accept' if parser_accepts else 'both refuse'}")
    accepted_by_both += 1 if (parser_accepts and store_accepts) else 0
check(accepted_by_both == 1,
      "exactly one of the candidates is valid, and both layers say so")
check(sorted(p.name for p in (nl_root / "capability-health-observations").iterdir()) == [],
      "no file with a newline in its name was created")

print("--- the module boundary ---")
check(hasattr(PKG, "HealthStore") and PKG.HealthStore is S.HealthStore,
      "tools.health re-exports the SAME HealthStore")
check(not hasattr(H, "HealthStore"),
      "the record model does not carry the store")
for banned in ("datetime.now", "time.time", "socket", "subprocess", "requests",
               "urllib", "asyncio", "threading", "multiprocessing"):
    check(banned not in source, f"the store module never uses {banned}")

shutil.rmtree(SCRATCH, ignore_errors=True)
check(not SCRATCH.exists(), "the scratch fixture tree is removed")

print()
if failures:
    print(f"Health store validation FAILED with {failures} error(s).",
          file=sys.stderr)
    raise SystemExit(1)
print("All health store assertions passed.")
PY
