#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for ENG-0006-H18's operator commands and helpers.
#
# `tools.health.operator` is what the three installed helpers do: draft a
# canonical approval statement, publish a reviewed one into a root-owned
# approval directory, and run ingestion and `verify` as the `kyri-health`
# service identity. The helpers in provisioning/health/ are entry points that
# check who they run as and load that module from a root-owned library.
#
# FIXTURES ONLY. The approval directory, the store and the "installed" library
# are temporary trees owned by the user running this suite, and the helpers'
# compiled-in production values are overridden on a loaded copy of each
# helper -- the files themselves are never edited. The publisher must BE the
# trusted UID, so publication runs with this user's UID as trusted; ingestion
# and verify opt in with `allow_own_uid_fixture`, as the H7 suites do.
#
# The confirmation prompt is driven through a real pseudo-terminal: the helper
# opens /dev/tty, so the test gives it a controlling terminal and types into
# it after the prompt has appeared. Nothing waits on elapsed time.
#
# Nothing here contacts a host or writes outside a temporary directory, and the
# production Health root is only ever checked for absence.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PRODUCTION_HEALTH_ROOT="/var/lib/kyri/health"   # prod-path-reference
if [[ -e "${PRODUCTION_HEALTH_ROOT}" ]]; then
  production_before="present"
else
  production_before="absent"
fi

python3 - "${ROOT}" <<'PY'
import ast
import atexit
import copy
import hashlib
import json
import os
import pty
import re
import select
import shutil
import stat
import subprocess
import sys
import tempfile
import time
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


from tools.common import canonical_json  # noqa: E402
from tools.health import ingest as I  # noqa: E402
from tools.health import operator as O  # noqa: E402
from tools.health.store import HealthStore  # noqa: E402

UID = os.geteuid()
GID = os.getegid()
SCRATCH = Path(tempfile.mkdtemp(prefix="h18-operator-"))
SCRATCH.chmod(0o755)
atexit.register(shutil.rmtree, SCRATCH, True)
_n = [0]


def fresh(name, mode=0o755):
    _n[0] += 1
    path = SCRATCH / f"{name}-{_n[0]:03d}"
    path.mkdir()
    path.chmod(mode)
    return path


def approvals():
    path = fresh("approvals")
    (path / O.STAGING).mkdir()
    (path / O.STAGING).chmod(0o700)
    return path


def store_root():
    path = fresh("store")
    HealthStore(path)
    path.chmod(0o700)
    return path


def tree(path):
    """Every entry beneath `path` with its bytes and mode, for no-change checks."""
    found = {}
    for entry in sorted(Path(path).rglob("*")):
        info = entry.lstat()
        found[str(entry.relative_to(path))] = (
            stat.filemode(info.st_mode), info.st_ino,
            entry.read_bytes() if entry.is_file() and not entry.is_symlink() else None)
    return found


ENVELOPE = {
    "envelope_version": 1,
    "subject_type": "capability-instance",
    "subject_id": "CINST-000007",
    "dimensions": {"latency": {
        "dimension": "latency", "unit": "milliseconds",
        "aggregation": {"kind": "instant"},
        "entry_condition": {"operator": "gt", "value": "2000"},
        "exit_condition": {"operator": "le", "value": "1500"},
        "hysteresis": {"kind": "duration", "seconds": 120,
                       "max_gap_seconds": 30, "min_samples": 3},
        "freshness_policy_seconds": 60}},
    "evaluation": "worst-dimension-wins",
    "provenance": {"class": "declared", "reviewed_in": "fixture review",
                   "notes": "café"},
}
MEMBERS = dict(actor="operator", approving_authority="operator-review",
               approved_at="2026-11-20T09:00:00-06:00")


def hand_statement(request_id="REQ-0001", envelope=None, **members):
    """Built without the implementation, so the draft is compared to it."""
    body = {
        "approval_statement_version": 1,
        "approval_domain": "capability-health-envelope",
        "operation": "initial",
        "request_id": request_id,
        "canonicalisation": "kyri-strict-canonical-json/v1",
        "digest_algorithm": "sha256",
        "envelope": copy.deepcopy(ENVELOPE) if envelope is None else envelope,
        **MEMBERS,
    }
    body.update(members)
    return body


def draft(request_id="REQ-0001", envelope=None, operation="initial", **members):
    values = {**MEMBERS, **members}
    return O.draft_statement(copy.deepcopy(ENVELOPE) if envelope is None else envelope,
                             request_id=request_id, operation=operation, **values)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


class Typist:
    """A confirmation that records what it was shown."""

    def __init__(self, typed):
        self.typed, self.shown = typed, []

    def __call__(self, rendered):
        self.shown.append(rendered)
        return self.typed


def publish(raw, directory, request_id="REQ-0001", *, digest=None, typed=None,
            trusted_uid=UID):
    digest = sha(raw) if digest is None else digest
    typist = Typist(digest[:12] + "\n" if typed is None else typed)
    result = O.publish_statement(raw, request_id=request_id, expected_sha256=digest,
                                 approval_root=directory, trusted_uid=trusted_uid,
                                 confirm=typist)
    return result, typist


# =============================================================================
print("--- drafting")
raw = draft()
check(raw == canonical_json.serialise(hand_statement()),
      "the draft is exactly the canonical bytes of the hand-built statement")
check(I.examine_statement(raw, "REQ-0001").refusal is None,
      "the draft passes every pre-store ingestion check")
check(not raw.endswith(b"\n"), "the draft carries no trailing newline")
replacement = draft("REQ-0002", envelope={**copy.deepcopy(ENVELOPE),
                                          "envelope_version": 2,
                                          "supersedes": "CHENV-0001"},
                    operation="replacement")
check(json.loads(replacement)["operation"] == "replacement",
      "a replacement drafts with its supersedes and version")


def draft_refusal(**kwargs):
    try:
        draft(**kwargs)
    except O.DraftRefused as error:
        return error.stage, error.reason
    return None


check(draft_refusal(request_id="a/b") == ("V1", "request-id-malformed"),
      "a request id with a separator is refused at V1")
check(draft_refusal(operation="replacement") == ("V6", "approval-operation-mismatch"),
      "a replacement without a predecessor is refused at V6")
check(draft_refusal(actor="CINST-000007", approving_authority="CINST-000007")
      == ("V9", "self-approval"), "self-approval is refused at V9")
check(draft_refusal(approved_at="yesterday") == ("V5", "envelope-invalid"),
      "an unparseable approval time is refused at V5")
check(draft_refusal(envelope={**ENVELOPE, "envelope_id": "CHENV-0001"})
      == ("V4", "approval-schema-invalid"), "an envelope naming its own id is refused")
check(draft_refusal(envelope={**ENVELOPE, "subject_id": 1.5})
      == ("V3", "approval-unreadable"), "a float cannot be drafted")
check(draft_refusal(envelope={**ENVELOPE, "notes": None})
      is not None, "an explicit null member is refused")

# --- the drafting CLI --------------------------------------------------------
CLI = root / "provisioning/health/draft-health-approval.py"


def cli(envelope_text, *extra):
    path = fresh("draft") / "envelope.json"
    path.write_text(envelope_text, encoding="utf-8")
    arguments = ["--envelope", str(path), "--request-id", "REQ-0001",
                 "--operation", "initial", "--actor", MEMBERS["actor"],
                 "--approving-authority", MEMBERS["approving_authority"],
                 "--approved-at", MEMBERS["approved_at"], *extra]
    return subprocess.run([sys.executable, str(CLI), *arguments],
                          capture_output=True, cwd=SCRATCH)


ran = cli(json.dumps(ENVELOPE, indent=2))
check(ran.returncode == 0 and ran.stdout == raw,
      "the CLI writes exactly the drafted bytes to stdout")
check(ran.stderr.decode().strip() == f"sha256 {sha(raw)}",
      "the CLI reports the digest sha256sum would compute")
ran = cli('{"subject_id": "A", "subject_id": "B"}')
check(ran.returncode == 1 and b"duplicate key" in ran.stderr and not ran.stdout,
      "the CLI refuses a duplicate key")
ran = cli(json.dumps(ENVELOPE).replace('"seconds": 120', '"seconds": 120.0'))
check(ran.returncode == 1 and not ran.stdout, "the CLI refuses a non-integer number")
ran = cli("subject_id: CINST-000007\n")
check(ran.returncode == 1 and not ran.stdout, "the CLI refuses YAML")
ran = cli(json.dumps(ENVELOPE), "--operation", "replacement")
check(ran.returncode == 1 and b"V6" in ran.stderr and not ran.stdout,
      "the CLI refuses a statement ingestion would refuse")
ran = subprocess.run([sys.executable, str(CLI), "--request-id", "REQ-0001"],
                     capture_output=True, cwd=SCRATCH)
check(ran.returncode == 2 and not ran.stdout, "the CLI defaults no member")

# --- examine_statement is ingestion's own pre-store decision -----------------
print("--- examine_statement agrees with ingestion")
battery = {
    "canonical": raw,
    "pretty": json.dumps(hand_statement(), indent=1).encode(),
    "not json": b"{",
    "wrong request": canonical_json.serialise(hand_statement("REQ-0009")),
    "version 2": canonical_json.serialise(hand_statement(approval_statement_version=2)),
    "self-approval": canonical_json.serialise(
        hand_statement(actor="CINST-000007", approving_authority="CINST-000007")),
    "operation mismatch": canonical_json.serialise(hand_statement(operation="replacement")),
    "bad envelope": canonical_json.serialise(
        hand_statement(envelope={**ENVELOPE, "envelope_version": 0})),
    "null member": canonical_json.serialise(
        hand_statement(envelope={**ENVELOPE, "notes": None})),
}
for label, data in battery.items():
    directory = fresh("parity")
    (directory / "REQ-0001.json").write_bytes(data)
    (directory / "REQ-0001.json").chmod(0o444)
    examined = I.examine_statement(data, "REQ-0001").refusal
    ingested = I.ingest_envelope(HealthStore(fresh("parity-store")),
                                 request_id="REQ-0001", approval_root=directory,
                                 trusted_uid=UID, allow_own_uid_fixture=True)
    if examined is None:
        check(ingested.status == "accepted", f"{label}: examined clean and ingested")
    else:
        check((examined.stage, examined.reason, examined.record_code)
              == (ingested.stage, ingested.reason, ingested.record_code),
              f"{label}: examine refuses exactly as ingestion ({examined.reason})")
check(I.examine_statement("text", "REQ-0001").refusal.reason == "approval-unreadable",
      "examine refuses a non-bytes statement")

# =============================================================================
print("--- publication")
directory = approvals()
result, typist = publish(raw, directory)
published = directory / "REQ-0001.json"
check(result.status == "published" and result.digest == "sha256:" + sha(raw),
      "a reviewed statement is published")
check(published.read_bytes() == raw, "the published bytes are the reviewed bytes")
info = published.lstat()
check(stat.S_IMODE(info.st_mode) == 0o444 and info.st_nlink == 1 and info.st_uid == UID,
      "the statement is 0444, single-linked and owned by the trusted UID")
check(os.listdir(directory / O.STAGING) == [], "staging is empty after publication")
shown = typist.shown[0]
for fragment in ('"REQ-0001"', '"initial"', '"capability-instance"', '"CINST-000007"',
                 '"operator-review"', '"2026-11-20T09:00:00-06:00"', 'dimension "latency"',
                 '"operator": "gt", "value": "2000"', '"freshness_policy_seconds"',
                 "caf\\u00e9", "sha256:" + sha(raw)):
    check(fragment in shown, f"the operator is shown {fragment!r}")
check(shown.rstrip().endswith("sha256:" + sha(raw)), "the digest is shown last")
check(all(" " <= c <= "~" or c == "\n" for c in shown),
      "the rendering is printable ASCII and newlines only")
hostile_envelope = copy.deepcopy(ENVELOPE)
hostile_envelope["provenance"]["notes"] = "\x1b[2J\u009b2K\x7f\u202e"
hostile_raw = draft(envelope=hostile_envelope)
hostile_shown = O.render_statement(I.examine_statement(hostile_raw, "REQ-0001"))
check(all(" " <= c <= "~" or c == "\n" for c in hostile_shown)
      and "\\u001b[2J" in hostile_shown and "\\u009b" in hostile_shown
      and "\\u202e" in hostile_shown,
      "terminal control sequences in a candidate are shown escaped, never emitted")
store = store_root()
status, ingested = O.ingest_command("REQ-0001", store_root=store,
                                    approval_root=directory, trusted_uid=UID,
                                    allow_own_uid_fixture=True)
check(status == 0 and ingested["status"] == "accepted"
      and ingested["approval_digest"] == result.digest,
      "ingestion accepts the published statement")

before = tree(directory)
result, typist = publish(raw, directory)
check(result.status == "already-published" and not typist.shown,
      "republishing identical bytes is idempotent and asks nothing")
check(tree(directory) == before, "an idempotent republish changes nothing")


def refused_unchanged(label, data, directory, expected, **kwargs):
    before = tree(directory)
    result, typist = publish(data, directory, **kwargs)
    check(result.status == "refused" and result.reason == expected,
          f"{label}: refused {expected} (got {result.reason})")
    check(tree(directory) == before, f"{label}: the approval directory is unchanged")
    return typist


other = draft(envelope={**copy.deepcopy(ENVELOPE), "subject_id": "CINST-000008"})
typist = refused_unchanged("different bytes under a published name", other,
                           directory, "approval-exists")
check(not typist.shown, "an occupied name is refused before confirmation")

fresh_directory = approvals()
typist = refused_unchanged("wrong confirmation", raw, fresh_directory,
                           "confirmation-refused", typed="000000000000")
check(len(typist.shown) == 1, "the wrong confirmation was asked for once")
refused_unchanged("confirmation of eleven digits", raw, fresh_directory,
                  "confirmation-refused", typed=sha(raw)[:11])
refused_unchanged("confirmation of the full digest", raw, fresh_directory,
                  "confirmation-refused", typed=sha(raw))
refused_unchanged("uppercase confirmation", raw, fresh_directory,
                  "confirmation-refused", typed=sha(raw)[:12].upper())
result, _ = publish(raw, approvals(), typed="  " + sha(raw)[:12] + " \r\n")
check(result.status == "published", "surrounding whitespace in the confirmation is ignored")

flipped = bytearray(raw)
flipped[-3] ^= 0x01
typist = refused_unchanged("one flipped byte", bytes(flipped), fresh_directory,
                           "digest-mismatch", digest=sha(raw))
check(not typist.shown, "a digest mismatch is refused before confirmation")
for bad in (sha(raw).upper(), sha(raw)[:63], sha(raw) + "0", "", "g" * 64):
    refused_unchanged(f"digest {bad[:8]!r}…", raw, fresh_directory, "digest-malformed",
                      digest=bad)
refused_unchanged("oversize candidate", b" " * (I.MAXIMUM_STATEMENT_BYTES + 1),
                  fresh_directory, "candidate-oversize")
for label, data in battery.items():
    if label == "canonical":
        continue
    expected = I.examine_statement(data, "REQ-0001").refusal.reason
    typist = refused_unchanged(f"ingestion would refuse: {label}", data,
                               fresh_directory, expected)
    check(not typist.shown, f"{label}: refused before confirmation")
refused_unchanged("request id with a separator", raw, fresh_directory,
                  "request-id-malformed", request_id="REQ/0001")
refused_unchanged("trusted UID not the publisher", raw, fresh_directory,
                  "publisher-not-trusted-uid", trusted_uid=UID + 1)
result = O.publish_statement(raw, request_id="REQ-0001", expected_sha256=sha(raw),
                             approval_root=fresh_directory, trusted_uid=UID,
                             confirm="not callable")
check(result.reason == "parameters-invalid", "a non-callable confirmation is refused")
result = O.publish_statement(raw, request_id="REQ-0001", expected_sha256=sha(raw),
                             approval_root=fresh_directory, trusted_uid=True,
                             confirm=Typist(""))
check(result.reason == "parameters-invalid", "a boolean trusted UID is refused")

# The approval directory and its staging directory.
loose = approvals()
loose.chmod(0o775)
refused_unchanged("group-writable approval root", raw, loose, "approval-root-untrusted")
link = SCRATCH / "approvals-link"
link.symlink_to(approvals())
result, _ = publish(raw, link)
check(result.reason == "approval-root-untrusted", "a symlinked approval root is refused")
result, _ = publish(raw, SCRATCH / "absent")
check(result.reason == "approval-root-untrusted", "an absent approval root is refused")
for label, prepare in (
        ("absent staging", lambda d: (d / O.STAGING).rmdir()),
        ("group-readable staging", lambda d: (d / O.STAGING).chmod(0o750)),
        ("symlinked staging", lambda d: ((d / O.STAGING).rmdir(),
                                         (d / O.STAGING).symlink_to(fresh("elsewhere", 0o700))))):
    candidate = approvals()
    prepare(candidate)
    refused_unchanged(label, raw, candidate, "staging-untrusted")
hostile = approvals()
(hostile / "REQ-0001.json").symlink_to(published)
refused_unchanged("a symlink occupying the name", raw, hostile, "approval-exists")
loose_file = approvals()
(loose_file / "REQ-0001.json").write_bytes(raw)
(loose_file / "REQ-0001.json").chmod(0o664)
refused_unchanged("identical bytes in a writable file", raw, loose_file, "approval-exists")


# The name appears between the check and the link: link() refuses, nothing is
# overwritten, and the temporary is removed.
def racing(contents):
    directory = approvals()

    def confirm(rendered):
        target = directory / "REQ-0001.json"
        target.write_bytes(contents)
        target.chmod(0o444)
        return sha(raw)[:12]
    result = O.publish_statement(raw, request_id="REQ-0001", expected_sha256=sha(raw),
                                 approval_root=directory, trusted_uid=UID,
                                 confirm=confirm)
    return result, directory


result, raced = racing(other)
check(result.reason == "approval-exists"
      and (raced / "REQ-0001.json").read_bytes() == other,
      "a statement that appears during confirmation is never overwritten")
check(os.listdir(raced / O.STAGING) == [], "the temporary is removed after a lost race")
result, raced = racing(raw)
check(result.status == "already-published", "a race to the same bytes is idempotent")

# =============================================================================
print("--- the service commands")
check(O.identity_refusal(expected_uid=5, expected_gid=6, euid=5, egid=6, groups=[6]) is None,
      "exactly the service identity is accepted")
check(O.identity_refusal(expected_uid=5, expected_gid=6, euid=5, egid=6, groups=[]) is None,
      "no supplementary groups is accepted")
check(O.identity_refusal(expected_uid=5, expected_gid=6, euid=4, egid=6, groups=[6])
      == "identity-mismatch", "another UID is refused")
check(O.identity_refusal(expected_uid=5, expected_gid=6, euid=5, egid=7, groups=[6])
      == "identity-mismatch", "another GID is refused")
check(O.identity_refusal(expected_uid=5, expected_gid=6, euid=5, egid=6, groups=[6, 27])
      == "identity-has-supplementary-groups", "a supplementary group is refused")

directory = approvals()
publish(raw, directory)
store = store_root()
status, result = O.ingest_command("REQ-0001", store_root=store, approval_root=directory,
                                  trusted_uid=UID, allow_own_uid_fixture=True)
check(status == 0 and result["status"] == "accepted", "ingest: accepted exits 0")
status, result = O.ingest_command("REQ-0001", store_root=store, approval_root=directory,
                                  trusted_uid=UID, allow_own_uid_fixture=True)
check(status == 0 and result["status"] == "replayed", "ingest: replayed exits 0")
status, result = O.ingest_command("REQ-0404", store_root=store, approval_root=directory,
                                  trusted_uid=UID, allow_own_uid_fixture=True)
check(status == 1 and result["reason"] == "approval-unavailable", "ingest: refused exits 1")
status, result = O.ingest_command("REQ-0001", store_root=store, approval_root=directory,
                                  trusted_uid=UID)
check(status == 1 and result["reason"] == "trusted-uid-is-own-uid",
      "ingest: the own-UID opt-in is still required")
check(set(result) == {"status", "stage", "reason", "envelope_id", "approval_digest",
                      "record_code"}, "ingest reports identifiers and codes only")

before = tree(store)
status, report = O.verify_command(store_root=store, approval_root=directory,
                                  trusted_uid=UID, allow_own_uid_fixture=True)
check(status == 0 and report["status"] == "clean"
      and report["heads"] == [{"subject": ["capability-instance", "CINST-000007"],
                               "head": "CHENV-0001"}], "verify: clean exits 0 and names the head")
check(tree(store) == before, "verify changes nothing in the store")
(directory / "REQ-0001.json").unlink()
status, report = O.verify_command(store_root=store, approval_root=directory,
                                  trusted_uid=UID, allow_own_uid_fixture=True)
check(status == 1 and [f["code"] for f in report["findings"]]
      == ["approval-statement-unavailable"]
      and report["frozen"] == [["capability-instance", "CINST-000007"]],
      "verify: a missing statement is a finding, exits 1 and freezes the subject")
status, report = O.verify_command(store_root=store, approval_root=directory, trusted_uid=UID)
check(status == 2 and report["reason"] == "trusted-uid-is-own-uid", "verify: refused exits 2")
check(json.loads(json.dumps(report)) == report, "the verify report is plain JSON")

for label, make, expected in (
        ("absent", lambda: SCRATCH / "no-store", "store-unavailable"),
        ("group-readable", lambda: (lambda p: (p.chmod(0o750), p)[1])(store_root()),
         "store-untrusted"),
        ("a file", lambda: (lambda p: (p.write_text(""), p)[1])(SCRATCH / "store-file"),
         "store-untrusted")):
    path = make()
    status, result = O.ingest_command("REQ-0001", store_root=path, approval_root=directory,
                                      trusted_uid=UID, allow_own_uid_fixture=True)
    check(status == 2 and result["reason"] == expected, f"ingest: {label} store is {expected}")
    status, report = O.verify_command(store_root=path, approval_root=directory,
                                      trusted_uid=UID, allow_own_uid_fixture=True)
    check(status == 2 and report["reason"] == expected, f"verify: {label} store is {expected}")
link = SCRATCH / "store-link"
link.symlink_to(store_root())
status, result = O.ingest_command("REQ-0001", store_root=link, approval_root=directory,
                                  trusted_uid=UID, allow_own_uid_fixture=True)
check(status == 2 and result["reason"] == "store-untrusted", "ingest: a symlinked store is refused")
bare = fresh("bare-store", 0o700)
directory = approvals()
publish(raw, directory)
status, result = O.ingest_command("REQ-0001", store_root=bare, approval_root=directory,
                                  trusted_uid=UID, allow_own_uid_fixture=True)
check(status == 2 and result["reason"] == "store-untrusted" and os.listdir(bare) == [],
      "ingest never lays out a store: an empty root is refused and left empty")

# =============================================================================
print("--- the installed helpers")
HELPERS = {name: root / f"provisioning/health/{name}.py"
           for name in ("kyri-health-approve", "kyri-health-ingest", "kyri-health-verify")}
BEGIN, END = "# --- bootstrap: identical in all three Health helpers", "# --- end bootstrap"


def block(text):
    return text[text.index(BEGIN):text.index(END)]


sources = {name: path.read_text() for name, path in HELPERS.items()}
check(len({block(text) for text in sources.values()}) == 1,
      "the three helpers carry byte-identical bootstraps")
for name, text in sources.items():
    check(text.startswith("#!/usr/bin/python3 -IB\n"), f"{name}: isolated, no-bytecode interpreter")
    check(f'HELPER = "{name}"' in text, f"{name}: names itself")
    check('LIBRARY_ROOT = "/usr/lib/kyri/health"' in text and "LIBRARY_OWNER = 0" in text
          and 'ANCESTRY_ROOT = "/"' in text, f"{name}: compiled-in root-owned library")
    check("TRUSTED_UID = 0" in text, f"{name}: approvals are root's")
    check('APPROVAL_ROOT = "/var/lib/kyri/health-approvals"' in text,
          f"{name}: compiled-in approval directory")
    tree_ = ast.parse(text)
    imported = set()
    for node in ast.walk(tree_):
        if isinstance(node, ast.Import):
            imported |= {alias.name for alias in node.names}
        elif isinstance(node, ast.ImportFrom):
            imported.add(node.module)
    check(imported <= {"__future__", "dataclasses", "json", "os", "pwd", "stat", "sys",
                       "syslog", "typing", "tools.health.operator"},
          f"{name}: imports only the standard library and the operator module: {sorted(imported)}")
    top_level = [node for node in tree_.body if isinstance(node, (ast.Import, ast.ImportFrom))]
    check(not [node for node in top_level if "tools" in ast.dump(node)],
          f"{name}: nothing from the library is imported before the trust check")
    names = {node.id for node in ast.walk(tree_) if isinstance(node, ast.Name)}
    check(not names & {"eval", "exec", "compile", "__import__", "subprocess"},
          f"{name}: no dynamic execution")
for name in ("kyri-health-ingest", "kyri-health-verify"):
    check('SERVICE_USER = "kyri-health"' in sources[name]
          and 'STORE_ROOT = "/var/lib/kyri/health"' in sources[name]
          and "ALLOW_OWN_UID_FIXTURE = False" in sources[name],
          f"{name}: compiled-in service identity and store, fixture opt-in off")
check('TTY = "/dev/tty"' in sources["kyri-health-approve"], "approve: confirms on /dev/tty")

# A fixture "installed" library: the closure the installer installs, 0444/0755.
CLOSURE = ["tools/__init__.py", "tools/common/__init__.py",
           "tools/common/canonical_json.py", "tools/common/immutable_store.py",
           "tools/common/trusted_source.py"] + sorted(
    str(path.relative_to(root)) for path in (root / "tools/health").glob("*.py"))


def library():
    base = fresh("installed")
    lib = base / "lib"
    for relative in CLOSURE:
        target = lib / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / relative, target)
        target.chmod(0o444)
    for directory in sorted({p for p in lib.rglob("*") if p.is_dir()} | {lib}, reverse=True):
        directory.chmod(0o755)
    return base, lib


# The runner loads a helper file and calls its main() with production values
# overridden. It runs under `-E`, not the helpers' `-I`, only so that PyYAML
# installed in the user site (as on CI) stays importable; what is under test
# is the helper's own refusal to import from anywhere but its library.
RUNNER = SCRATCH / "runner.py"
RUNNER.write_text('''
import importlib.machinery, importlib.util, json, os, sys
sys.dont_write_bytecode = True
path, overrides = sys.argv[1], json.loads(sys.argv[2])
spec = importlib.util.spec_from_file_location("helper", path)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
own_groups = overrides.pop("_own_groups", False)
for key, value in overrides.items():
    setattr(helper, key, value)
helper._log = lambda message, refused=False: None
if own_groups:
    helper._groups = lambda: [os.getegid()]
sys.exit(helper.main([path, *sys.argv[3:]]))
''')
ME = __import__("pwd").getpwuid(UID).pw_name
BASE, LIB = library()


def overrides(**extra):
    return {"LIBRARY_ROOT": str(LIB), "LIBRARY_OWNER": UID, "ANCESTRY_ROOT": str(BASE),
            **extra}


def run(name, values, *arguments, stdin=None, new_session=False):
    ran = subprocess.run([sys.executable, "-E", str(RUNNER), str(HELPERS[name]),
                          json.dumps(values), *arguments], capture_output=True, text=True,
                         stdin=stdin, start_new_session=new_session, cwd=SCRATCH)
    lines = [line for line in ran.stdout.splitlines() if line.startswith("{")]
    return ran.returncode, json.loads(lines[-1]) if lines else None, ran


def service(**extra):
    values = overrides(SERVICE_USER=ME, STORE_ROOT=str(store), APPROVAL_ROOT=str(directory),
                       TRUSTED_UID=UID, ALLOW_OWN_UID_FIXTURE=True, _own_groups=True)
    values.update(extra)
    return values


directory = approvals()
publish(raw, directory)
store = store_root()
code, out, ran = run("kyri-health-ingest", service(), "REQ-0001")
check(code == 0 and out["status"] == "accepted" and out["envelope_id"] == "CHENV-0001",
      f"ingest helper: accepted from the installed library ({ran.stderr.strip()[:200]})")
code, out, _ = run("kyri-health-ingest", service(), "REQ-0001")
check(code == 0 and out["status"] == "replayed", "ingest helper: replayed")
code, out, _ = run("kyri-health-ingest", service(), "REQ-0404")
check(code == 1 and out["reason"] == "approval-unavailable", "ingest helper: refused exits 1")
code, out, _ = run("kyri-health-ingest", service(), "REQ-0001", "REQ-0002")
check(code == 2 and out["reason"] == "usage", "ingest helper: one argument only")
code, out, _ = run("kyri-health-ingest", service(), "--store")
check(code == 1 and out["reason"] == "approval-unavailable",
      "ingest helper: an option-shaped argument is a request id, not an option")
code, out, _ = run("kyri-health-verify", service())
check(code == 0 and out["status"] == "clean", "verify helper: clean exits 0")
code, out, _ = run("kyri-health-verify", service(), "extra")
check(code == 2 and out["reason"] == "usage", "verify helper: no arguments")
code, out, _ = run("kyri-health-ingest", service(SERVICE_USER="kyri-health-h18-absent"), "REQ-0001")
check(code == 2 and out["reason"] == "identity-absent", "a missing service account is refused")
if UID != 0:
    code, out, _ = run("kyri-health-verify", service(SERVICE_USER="root"))
    check(code == 2 and out["reason"] == "identity-mismatch",
          "verify helper: another identity is refused")
real_groups = service()
real_groups.pop("_own_groups")
code, out, _ = run("kyri-health-verify", real_groups)
if set(os.getgroups()) - {GID}:
    check(code == 2 and out["reason"] == "identity-has-supplementary-groups",
          "verify helper: a process holding other groups is refused")
else:
    check(code == 0, "verify helper: a process with no other group runs")
code, out, _ = run("kyri-health-verify", service(ALLOW_OWN_UID_FIXTURE=False))
check(code == 2 and out["reason"] == "trusted-uid-is-own-uid",
      "verify helper: the compiled-off opt-in is honoured")

# The library must be root's (here: this user's) all the way down and up.
def untrusted(label, mutate, expected="library-untrusted"):
    base, lib = library()
    mutate(base, lib)
    values = service(LIBRARY_ROOT=str(lib), ANCESTRY_ROOT=str(base))
    code, out, _ = run("kyri-health-verify", values)
    check(code == 2 and out and out["reason"] == expected, f"{label}: {expected}")


untrusted("a group-writable module", lambda b, l: (l / "tools/health/ingest.py").chmod(0o464))
untrusted("a world-writable directory", lambda b, l: (l / "tools/common").chmod(0o757))
untrusted("a group-writable ancestor", lambda b, l: b.chmod(0o775))
untrusted("a symlinked module", lambda b, l: ((l / "tools/health/errors.py").unlink(),
          (l / "tools/health/errors.py").symlink_to(root / "tools/health/errors.py")))
untrusted("a symlinked package directory", lambda b, l: (shutil.rmtree(l / "tools/common"),
          (l / "tools/common").symlink_to(root / "tools/common")))
untrusted("a foreign file type", lambda b, l: os.mkfifo(l / "tools/health/pipe"))
untrusted("a missing library", lambda b, l: shutil.rmtree(l))
untrusted("a library missing the operator", lambda b, l: (l / "tools/health/operator.py").unlink(),
          "library-unimportable")
code, out, _ = run("kyri-health-verify", service(LIBRARY_OWNER=UID + 1))
check(code == 2 and out["reason"] == "library-untrusted",
      "a library not owned by the compiled-in owner is refused")
check(not list(LIB.rglob("__pycache__")), "the helpers write no bytecode into the library")

# --- the approval helper: a real controlling terminal -------------------------
print("--- the approval helper")
candidate = SCRATCH / "candidate.json"
candidate.write_bytes(raw)


def approve(values, arguments, typed, *, redirect=True):
    pid, fd = pty.fork()
    if pid == 0:
        try:
            if redirect:
                os.dup2(os.open(candidate, os.O_RDONLY), 0)
            os.execv(sys.executable, [sys.executable, "-E", str(RUNNER),
                                      str(HELPERS["kyri-health-approve"]),
                                      json.dumps(values), *arguments])
        finally:
            os._exit(127)
    output, sent, deadline = b"", False, time.monotonic() + 60
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 1.0)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        output += chunk
        if not sent and b"to publish: " in output:
            os.write(fd, typed.encode() + b"\n")
            sent = True
    else:
        os.kill(pid, 9)
    os.close(fd)
    _, status = os.waitpid(pid, 0)
    text = output.decode("utf-8", "replace")
    found = re.findall(r"\{[^\r\n]*\}", text)
    return os.waitstatus_to_exitcode(status), json.loads(found[-1]) if found else None, text, sent


approver = overrides(APPROVAL_ROOT=str(approvals()), TRUSTED_UID=UID)
code, out, text, sent = approve(approver, ["REQ-0001", sha(raw)], sha(raw)[:12])
check(sent and code == 0 and out["status"] == "published",
      f"approve helper: published after confirmation on the terminal ({text[-300:]!r})")
check('"CINST-000007"' in text and "sha256:" + sha(raw) in text,
      "approve helper: the statement and digest were shown on the terminal")
check((Path(approver["APPROVAL_ROOT"]) / "REQ-0001.json").read_bytes() == raw,
      "approve helper: the published bytes are the candidate")
code, out, text, sent = approve(approver, ["REQ-0001", sha(raw)], "unused")
check(code == 0 and out["status"] == "already-published" and not sent,
      "approve helper: an identical republish asks nothing")
approver = overrides(APPROVAL_ROOT=str(approvals()), TRUSTED_UID=UID)
code, out, text, sent = approve(approver, ["REQ-0001", sha(raw)], "0" * 12)
check(sent and code == 1 and out["reason"] == "confirmation-refused"
      and not (Path(approver["APPROVAL_ROOT"]) / "REQ-0001.json").exists(),
      "approve helper: a wrong confirmation publishes nothing")
code, out, text, sent = approve(approver, ["REQ-0001", "0" * 64], "unused")
check(code == 1 and out["reason"] == "digest-mismatch" and not sent,
      "approve helper: a digest the operator did not compute is refused unasked")
code, out, text, sent = approve(approver, ["REQ-0001", sha(raw)], "unused", redirect=False)
check(code == 2 and out["reason"] == "candidate-not-redirected",
      "approve helper: a terminal on stdin is refused")
with open(candidate, "rb") as handle:
    code, out, _ = run("kyri-health-approve", approver, "REQ-0001", sha(raw),
                       stdin=handle, new_session=True)
check(code == 2 and out["reason"] == "no-controlling-terminal",
      "approve helper: no controlling terminal is refused")
with open(candidate, "rb") as handle:
    code, out, _ = run("kyri-health-approve", approver, "REQ-0001", stdin=handle)
check(code == 2 and out["reason"] == "usage", "approve helper: exactly two arguments")
if UID != 0:
    with open(candidate, "rb") as handle:
        code, out, _ = run("kyri-health-approve", overrides(APPROVAL_ROOT=approver["APPROVAL_ROOT"]),
                           "REQ-0001", sha(raw), stdin=handle)
    check(code == 2 and out["reason"] == "not-root",
          "approve helper: refused unless the effective UID is the compiled-in root")

# =============================================================================
print("--- the verification unit and timer")
unit = (root / "provisioning/health/kyri-health-verify.service").read_text()
timer = (root / "provisioning/health/kyri-health-verify.timer").read_text()
settings = [line.strip() for line in unit.splitlines()
            if line.strip() and not line.startswith("#") and not line.startswith("[")]
for required in ("Type=oneshot", "User=kyri-health", "Group=kyri-health",
                 "ExecStart=/usr/libexec/kyri-health-verify", "ProtectSystem=strict",
                 "ProtectHome=yes", "PrivateNetwork=yes", "PrivateTmp=yes",
                 "PrivateDevices=yes", "NoNewPrivileges=yes", "CapabilityBoundingSet=",
                 "AmbientCapabilities=", "RestrictSUIDSGID=yes",
                 "RestrictAddressFamilies=AF_UNIX"):
    check(required in settings, f"unit: {required}")
check(any(line.startswith("InaccessiblePaths=") and "/var/lib/kyri/fabric" in line
          and "/var/lib/kyri/trust" in line for line in settings),
      "unit: the Fabric and Trust stores are inaccessible")
check(not [line for line in settings if re.match(
    r"(Environment|EnvironmentFile|ReadWritePaths|SupplementaryGroups=\S|ExecStartPre|"
    r"ExecStartPost|PermissionsStartOnly|Restart=)", line)],
      "unit: no environment, no writable path, no extra group, no other command")
check([line for line in settings if line.startswith("ExecStart")]
      == ["ExecStart=/usr/libexec/kyri-health-verify"], "unit: exactly one command, no arguments")
for required in ("OnCalendar=", "Persistent=true", "Unit=kyri-health-verify.service",
                 "WantedBy=timers.target"):
    check(required in timer, f"timer: {required}")

# --- boundaries ------------------------------------------------------------
probe = subprocess.run(
    [sys.executable, "-c", "import sys; sys.path.insert(0, sys.argv[1]); "
     "import tools.health.operator; "
     "print(' '.join(sorted(m for m in sys.modules if m.startswith('tools.'))))",
     str(root)], capture_output=True, text=True, check=True)
loaded = probe.stdout.split()
check(not [m for m in loaded if m.split(".")[1] in
           ("trust", "fabric", "capability", "collectors", "observation")],
      f"importing the operator module loads no other plane: {loaded}")
check(set(loaded) <= {"tools.common", "tools.common.canonical_json",
                      "tools.common.immutable_store", "tools.common.trusted_source",
                      "tools.health"} | {f"tools.health.{p.stem}" for p in
                                         (root / "tools/health").glob("*.py")},
      "the operator module's closure is exactly what the installer installs")
installed = {f"tools.{Path(p).parent.name}.{Path(p).stem}".replace(".tools.", ".")
             for p in CLOSURE}
check({m for m in loaded if m.count(".") == 2} <= installed,
      "every loaded module is in the installed closure")

shutil.rmtree(SCRATCH, ignore_errors=True)
check(not SCRATCH.exists(), "the scratch fixture tree is removed")
print()
if failures:
    print(f"Health operator validation FAILED with {failures} error(s).", file=sys.stderr)
    raise SystemExit(1)
print("All health operator assertions passed.")
PY

if [[ -e "${PRODUCTION_HEALTH_ROOT}" ]]; then
  production_after="present"
else
  production_after="absent"
fi
if [[ "${production_before}" == "absent" && "${production_after}" == "absent" ]]; then
  printf 'PASS: %s is absent before and after\n' "${PRODUCTION_HEALTH_ROOT}"
else
  printf 'FAIL: %s was %s before and %s after\n' "${PRODUCTION_HEALTH_ROOT}" \
    "${production_before}" "${production_after}" >&2
  exit 1
fi
