#!/usr/bin/env bash
set -Eeuo pipefail

# The ENG-0006-H18 Health runtime ceremony, driven against fixture trees.
#
# provisioning/health/install-health-runtime.sh creates the kyri-health
# identity and the approval and store roots, and installs the reviewed runtime
# root-owned from a pinned commit. This suite runs it with --fixture against
# throwaway trees (ownership is this user's, the account database is the
# fixture's /etc, systemd is not touched) and attacks each property: the
# pinned bytes, idempotence, refusal without repair, the identity contract,
# rollback that keeps evidence, and finally the INSTALLED helpers performing a
# real approve -> ingest -> verify against the installed library.
#
# It needs no privilege, writes nothing outside a temporary directory, and
# checks the production Health roots only for absence.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CEREMONY="${ROOT}/provisioning/health/install-health-runtime.sh"

PRODUCTION_PATHS=(/var/lib/kyri/health /var/lib/kyri/health-approvals   # prod-path-reference
                  /usr/lib/kyri/health /usr/libexec/kyri-health-verify)
production_state() {
  local path state=''
  for path in "${PRODUCTION_PATHS[@]}"; do
    if [[ -e "${path}" ]]; then state+="present "; else state+="absent "; fi
  done
  printf '%s' "${state}"
}
PRODUCTION_BEFORE="$(production_state)"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

SCRATCH="$(mktemp -d)"
chmod 0755 "${SCRATCH}"
trap 'rm -rf "${SCRATCH}"' EXIT

# A fixture host: the directories production already has, all 0755 and this
# user's, and an empty account database.
new_fixture() {
  local base dir
  base="$(mktemp -d -p "${SCRATCH}")"
  chmod 0755 "${base}"
  for dir in etc etc/sudoers.d etc/systemd etc/systemd/system usr usr/lib usr/libexec var var/lib; do
    mkdir -p "${base}/${dir}"
    chmod 0755 "${base}/${dir}"
  done
  : > "${base}/etc/passwd"
  : > "${base}/etc/group"
  : > "${base}/etc/shadow"
  : > "${base}/etc/sudoers"
  # Production has /root; the ceremony stages there and removes its stage.
  mkdir -m 0700 "${base}/root"
  printf '%s' "${base}"
}

ceremony() {
  local fixture="$1"; shift
  bash "${CEREMONY}" "$@" --fixture "${fixture}" --repository "${ROOT}" 2>&1
}

# Everything under a fixture except the scratch stage, with modes, owners and
# content digests, so "nothing changed" is a comparison and not a belief.
snapshot() {
  (cd "$1" && find . -path ./root -prune -o -printf '%p|%y|%m|%U|%n\n' | sort
   find . -path ./root -prune -o -type f -print0 | sort -z | xargs -0 -r sha256sum)
}

expect() {
  local description="$1" pattern="$2" output="$3"
  if grep -qE -- "${pattern}" <<<"${output}"; then
    pass "${description}"
  else
    fail "${description}: $(tail -3 <<<"${output}" | tr '\n' ' ')"
  fi
}

refused_unchanged() {
  local description="$1" fixture="$2" pattern="$3"; shift 3
  local before after output
  before="$(snapshot "${fixture}")"
  if output="$(ceremony "${fixture}" "$@")"; then
    fail "${description}: the ceremony did not refuse: $(tail -2 <<<"${output}" | tr '\n' ' ')"
    return
  fi
  after="$(snapshot "${fixture}")"
  expect "${description}: refused" "${pattern}" "${output}"
  if [[ "${before}" == "${after}" ]]; then
    pass "${description}: nothing changed"
  else
    fail "${description}: the fixture changed"
  fi
}

# --- static properties of the ceremony -------------------------------------
STATIC="$(python3 - "${ROOT}" "${CEREMONY}" <<'PY'
import hashlib
import re
import subprocess
import sys
from pathlib import Path

root, ceremony = Path(sys.argv[1]), Path(sys.argv[2])
text = ceremony.read_text()
sys.path.insert(0, str(root))
commit = re.search(r'^COMMIT="([0-9a-f]{40})"$', text, re.M).group(1)
rows = re.findall(r'^"([^|"]+)\|([^|"]+)\|(0[0-7]{3})\|([0-9a-f]{64})"$', text, re.M)


def blob(path):
    return subprocess.run(["git", "-C", str(root), "cat-file", "blob", f"{commit}:{path}"],
                          capture_output=True, check=True).stdout


def say(ok, description):
    print(("PASS" if ok else "FAIL") + "\t" + description)


say(subprocess.run(["git", "-C", str(root), "merge-base", "--is-ancestor", commit, "HEAD"]).returncode == 0,
    f"the pinned commit {commit[:12]} is an ancestor of HEAD")
say(all(hashlib.sha256(blob(source)).hexdigest() == digest for source, _, _, digest in rows),
    f"all {len(rows)} pinned digests are the blobs at the pinned commit, recomputed here")
say(all(blob(source) == (root / source).read_bytes() for source, _, _, _ in rows),
    "the pinned blobs are what HEAD carries, so the pin is current")

library = sorted(source for source, target, _, _ in rows if target.startswith("/usr/lib/kyri/health/"))
say(all(target == "/usr/lib/kyri/health/" + source and mode == "0444"
        for source, target, mode, _ in rows if source in library),
    "every library module is installed at its own path, 0444")
probe = subprocess.run(
    [sys.executable, "-c", "import sys; sys.path.insert(0, sys.argv[1]); "
     "import tools.health.operator; print('\\n'.join(sorted("
     "m.__file__ for n, m in sys.modules.items() if n.startswith('tools'))))", str(root)],
    capture_output=True, text=True, check=True)
closure = sorted(str(Path(p).relative_to(root)) for p in probe.stdout.split())
say(library == closure, f"the installed library is exactly the operator module's import closure ({len(closure)})")
say(not [s for s in library if s.split("/")[1] in ("trust", "fabric", "capability", "collectors")],
    "no Trust, Fabric or Capability module is installed")
helpers = {source: (target, mode) for source, target, mode, _ in rows if source not in library}
expected = {f"provisioning/health/kyri-health-{h}.py": (f"/usr/libexec/kyri-health-{h}", "0555")
            for h in ("approve", "ingest", "verify")}
expected.update({f"provisioning/health/kyri-health-verify.{u}": (f"/etc/systemd/system/kyri-health-verify.{u}", "0644")
                 for u in ("service", "timer")})
say(helpers == expected, "the helpers and units, and nothing else, are installed beside the library")
say("provisioning/health/install-health-runtime.sh" not in helpers
    and "provisioning/health/draft-health-approval.py" not in helpers,
    "neither the ceremony nor the drafting CLI is installed")

import tempfile
from tools.health.store import HealthStore
with tempfile.TemporaryDirectory() as scratch:
    HealthStore(Path(scratch) / "s")
    made = sorted(str(p.relative_to(Path(scratch) / "s")) for p in (Path(scratch) / "s").rglob("*"))
layout = re.search(r"^STORE_LAYOUT=\(\n(.*?)\n\)", text, re.M | re.S).group(1).split()
lock = re.search(r'^STORE_LOCK="([^"]+)"$', text, re.M).group(1)
say(sorted(layout + [lock]) == made, "the store layout is exactly what HealthStore lays out")

code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
say(not re.search(r"^\s*(source|\.)\s", code, re.M), "the ceremony sources nothing")
say('export PATH="/usr/sbin:/usr/bin:/sbin:/bin"' in code and "\numask 077\ncd /\n" in code,
    "the ceremony sets PATH, umask and the working directory itself")
commands = re.sub(r"<<EOF.*?^EOF", "", code, flags=re.M | re.S)
say(not re.search(r"(^|[;&|(]|\$\(|\|\||&&)\s*(git|runuser|useradd|systemctl|sudo|id)\s", commands, re.M),
    "git, runuser, useradd, systemctl and sudo are always named absolutely")
say(not re.search(r"(python3?|bash|sh|source)\s+[^|\n]*\$\{REPOSITORY\}", commands)
    and "cat-file blob" in code and "runuser -u" in code,
    "nothing from the repository is executed; bytes are read as git blobs, as the owner")
say(not re.search(r"(>|\btee\b|\binstall\b|\bcp\b|\bmv\b|\bchmod\b|\bchown\b)[^\n]*sudoers", commands),
    "the ceremony writes no sudoers policy")
for name in ("chmod", "chown"):
    lines = [l for l in code.splitlines() if re.search(rf"\b{name}\b", l)]
    say(all(re.search(r"staging|STAGE|\$\{path\}|destination|LIBRARY_PARENT", l) for l in lines),
        f"every {name} targets an object this ceremony just created")
PY
)"
while IFS=$'\t' read -r verdict description; do
  if [[ "${verdict}" == "PASS" ]]; then pass "${description}"; else fail "${description}"; fi
done <<<"${STATIC}"

output="$(bash "${CEREMONY}" --bootstrap-instructions 2>&1)"
expect "bootstrap: the script is copied into root-only space" \
  'install -d -o root -g root -m 0700 /root/kyri-health-install' "${output}"
expect "bootstrap: git reads the blob as the operator, not root" \
  '^  git -C /opt/schott-platform cat-file blob' "${output}"
expect "bootstrap: the digest is checked before anything runs as root" 'must print' "${output}"
if grep -qE 'sudo (bash|sh|python3?) +/opt' <<<"${output}"; then
  fail "bootstrap: a repository path is executed as root"
else
  pass "bootstrap: no repository path is ever executed as root"
fi
output="$(bash "${CEREMONY}" --verify --repository "${ROOT}" 2>&1)" && rc=0 || rc=$?
if [[ "${rc}" == "2" ]]; then
  pass "--repository is refused without --fixture"
else
  fail "--repository without --fixture: rc=${rc}"
fi
if [[ "$(id -u)" != "0" ]]; then
  output="$(bash "${CEREMONY}" --verify 2>&1)" && rc=0 || rc=$?
  if [[ "${rc}" == "1" ]]; then
    expect "production modes refuse a non-root caller" 'must run as root' "${output}"
  else
    fail "--verify as non-root: rc=${rc}"
  fi
fi
output="$(bash "${CEREMONY}" --install --uninstall --fixture "${SCRATCH}" 2>&1)" && rc=0 || rc=$?
if [[ "${rc}" == "2" ]]; then
  pass "one mode only"
else
  fail "two modes: rc=${rc}"
fi

# --- the accepted path -------------------------------------------------------
F="$(new_fixture)"
if output="$(ceremony "${F}" --verify)"; then
  expect "an empty host is READY" '^READY$' "${output}"
else
  fail "--verify on an empty fixture: ${output}"
fi
if [[ -z "$(find "${F}" -mindepth 1 -newer "${F}/etc/sudoers" -not -path "${F}/root*" -not -path "${F}/etc/sudoers")" ]]; then
  pass "--verify creates nothing"
else
  fail "--verify created something"
fi
if output="$(ceremony "${F}" --install)"; then
  expect "installation succeeds and verifies itself" '^DONE$' "${output}"
else
  fail "--install: ${output}"
fi
if output="$(bash "${CEREMONY}" --verify-installed --fixture "${F}" 2>&1)"; then
  expect "the installation verifies independently, without the repository" '^VERIFIED$' "${output}"
else
  fail "--verify-installed: ${output}"
fi
if [[ -z "$(ls -A "${F}/root" 2>/dev/null)" ]]; then
  pass "the root-only stage is removed"
else
  fail "the stage was left behind"
fi

me="$(id -u):$(id -g)"
shape() { stat -c '%u:%g %a %h' "${F}$1"; }
if [[ "$(shape /var/lib/kyri/health)" == "${me} 700 "* ]]; then
  pass "the store root is the service identity's, 0700"
else
  fail "store root: $(shape /var/lib/kyri/health)"
fi
if [[ "$(shape /var/lib/kyri/health-approvals)" == "${me} 755 "* ]]; then
  pass "the approval root is 0755"
else
  fail "approval root: $(shape /var/lib/kyri/health-approvals)"
fi
if [[ "$(shape /var/lib/kyri/health-approvals/.staging)" == "${me} 700 "* ]]; then
  pass "approval staging is 0700"
else
  fail "staging: $(shape /var/lib/kyri/health-approvals/.staging)"
fi
if [[ "$(shape /var/lib/kyri)" == "${me} 711 "* ]]; then
  pass "a created /var/lib/kyri is 0711"
else
  fail "/var/lib/kyri: $(shape /var/lib/kyri)"
fi
if [[ "$(shape /var/lib/kyri/health/sequences/request_identity.lock)" == "${me} 600 1" ]]; then
  pass "the store lock is 0600, single-linked"
else
  fail "lock: $(shape /var/lib/kyri/health/sequences/request_identity.lock)"
fi
for helper in approve ingest verify; do
  if [[ "$(shape "/usr/libexec/kyri-health-${helper}")" == "${me} 555 1" ]]; then
    pass "kyri-health-${helper} is 0555, single-linked"
  else
    fail "kyri-health-${helper}: $(shape "/usr/libexec/kyri-health-${helper}")"
  fi
done
if [[ -z "$(find "${F}/usr/lib/kyri/health" -perm /0222 -type f)" && -z "$(find "${F}/usr/lib/kyri/health" -perm /022 -type d)" ]]; then
  pass "the library is 0444 files under 0755 directories"
else
  fail "library modes"
fi
if grep -qx 'kyri-health:x:[0-9]*:[0-9]*:Kyri Health runtime:/nonexistent:/usr/sbin/nologin' "${F}/etc/passwd"; then
  pass "the account has /usr/sbin/nologin and /nonexistent"
else
  fail "passwd entry: $(cat "${F}/etc/passwd")"
fi
if grep -q '^kyri-health:!' "${F}/etc/shadow"; then
  pass "the account's password is locked"
else
  fail "shadow entry"
fi
if [[ "$(grep -c . "${F}/etc/sudoers")" == "0" && -z "$(ls -A "${F}/etc/sudoers.d")" ]]; then
  pass "no sudoers rule is written"
else
  fail "sudoers changed"
fi

before="$(snapshot "${F}")"
if output="$(ceremony "${F}" --install)"; then
  expect "a second installation is DONE" '^DONE$' "${output}"
else
  fail "second --install: ${output}"
fi
if [[ "$(snapshot "${F}")" == "${before}" ]]; then
  pass "a second installation changes nothing"
else
  fail "a second installation changed the fixture"
fi
expect "a second installation creates nothing" 'state directories in place \(0 created\)' "${output}"
if output="$(ceremony "${F}" --verify)"; then
  expect "an installed host is READY (nothing to do)" '6/6 runtime objects present' "${output}"
else
  fail "--verify after install: ${output}"
fi

# --- the installed helpers, end to end ----------------------------------------
E2E="$(python3 - "${ROOT}" "${F}" <<'PY'
import hashlib
import importlib.util
import json
import os
import pty
import re
import select
import subprocess
import sys
import tempfile
import time
from pathlib import Path

root, fixture = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(root))
from tools.health.operator import draft_statement

UID = os.geteuid()
libexec = fixture / "usr/libexec"
values = {"LIBRARY_ROOT": str(fixture / "usr/lib/kyri/health"), "LIBRARY_OWNER": UID,
          "ANCESTRY_ROOT": str(fixture), "APPROVAL_ROOT": str(fixture / "var/lib/kyri/health-approvals"),
          "TRUSTED_UID": UID}
service = {**values, "SERVICE_USER": __import__("pwd").getpwuid(UID).pw_name,
           "STORE_ROOT": str(fixture / "var/lib/kyri/health"), "ALLOW_OWN_UID_FIXTURE": True,
           "_own_groups": True}
scratch = Path(tempfile.mkdtemp())
runner = scratch / "runner.py"
runner.write_text('''
import importlib.machinery, importlib.util, json, os, sys
sys.dont_write_bytecode = True
path, overrides = sys.argv[1], json.loads(sys.argv[2])
spec = importlib.util.spec_from_loader("helper", importlib.machinery.SourceFileLoader("helper", path))
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


def say(ok, description):
    print(("PASS" if ok else "FAIL") + "\t" + description)


def run(helper, overrides, *arguments):
    ran = subprocess.run([sys.executable, "-E", str(runner), str(libexec / helper),
                          json.dumps(overrides), *arguments], capture_output=True, text=True)
    lines = [l for l in ran.stdout.splitlines() if l.startswith("{")]
    return ran.returncode, json.loads(lines[-1]) if lines else {"stderr": ran.stderr[-300:]}


envelope = {
    "envelope_version": 1, "subject_type": "capability-instance", "subject_id": "CINST-000007",
    "dimensions": {"latency": {
        "dimension": "latency", "unit": "milliseconds", "aggregation": {"kind": "instant"},
        "entry_condition": {"operator": "gt", "value": "2000"},
        "exit_condition": {"operator": "le", "value": "1500"},
        "hysteresis": {"kind": "duration", "seconds": 120, "max_gap_seconds": 30, "min_samples": 3},
        "freshness_policy_seconds": 60}},
    "evaluation": "worst-dimension-wins",
    "provenance": {"class": "declared", "reviewed_in": "H18 fixture", "notes": "end to end"}}
raw = draft_statement(envelope, request_id="REQ-0001", operation="initial", actor="operator",
                      approving_authority="operator-review", approved_at="2026-11-20T09:00:00-06:00")
candidate = scratch / "candidate.json"
candidate.write_bytes(raw)
digest = hashlib.sha256(raw).hexdigest()

pid, fd = pty.fork()
if pid == 0:
    os.dup2(os.open(candidate, os.O_RDONLY), 0)
    os.execv(sys.executable, [sys.executable, "-E", str(runner), str(libexec / "kyri-health-approve"),
                              json.dumps(values), "REQ-0001", digest])
output, sent, deadline = b"", False, time.monotonic() + 60
while time.monotonic() < deadline:
    if not select.select([fd], [], [], 1.0)[0]:
        continue
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    output += chunk
    if not sent and b"to publish: " in output:
        os.write(fd, digest[:12].encode() + b"\n")
        sent = True
os.close(fd)
status = os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1])
found = re.findall(r"\{[^\r\n]*\}", output.decode("utf-8", "replace"))
published = json.loads(found[-1]) if found else {}
say(sent and status == 0 and published.get("status") == "published",
    f"the installed approve helper publishes after a typed confirmation ({published})")
statement = Path(values["APPROVAL_ROOT"]) / "REQ-0001.json"
say(statement.read_bytes() == raw and (statement.stat().st_mode & 0o777) == 0o444,
    "the published statement is the candidate, 0444")

code, result = run("kyri-health-ingest", service, "REQ-0001")
say(code == 0 and result.get("status") == "accepted" and result.get("envelope_id") == "CHENV-0001",
    f"the installed ingest helper admits it into the installed store ({result})")
code, result = run("kyri-health-ingest", service, "REQ-0001")
say(code == 0 and result.get("status") == "replayed", "a second ingestion is a replay")
code, report = run("kyri-health-verify", service)
say(code == 0 and report.get("status") == "clean"
    and report.get("heads") == [{"subject": ["capability-instance", "CINST-000007"], "head": "CHENV-0001"}],
    f"the installed verify helper reports the store clean ({report})")
statement.chmod(0o664)
code, report = run("kyri-health-verify", service)
say(code == 1 and [f["code"] for f in report.get("findings", [])] == ["approval-statement-unavailable"],
    "a statement made writable is a verify finding")
statement.chmod(0o444)
say(not list((fixture / "usr/lib/kyri/health").rglob("__pycache__")),
    "running the installed helpers wrote no bytecode into the library")
PY
)"
while IFS=$'\t' read -r verdict description; do
  if [[ "${verdict}" == "PASS" ]]; then pass "${description}"; else fail "${description}"; fi
done <<<"${E2E}"
if output="$(bash "${CEREMONY}" --verify-installed --fixture "${F}" 2>&1)"; then
  expect "the installation still verifies after the helpers ran" '^VERIFIED$' "${output}"
else
  fail "--verify-installed after use: ${output}"
fi

# --- rollback keeps identity and evidence ----------------------------------------
evidence() { (cd "${F}" && find etc/passwd etc/group etc/shadow etc/sudoers etc/sudoers.d var -type f -print0 | sort -z | xargs -0 sha256sum); }
evidence_before="$(evidence)"
if output="$(bash "${CEREMONY}" --uninstall --fixture "${F}" 2>&1)"; then
  expect "rollback succeeds" '^ROLLED BACK$' "${output}"
else
  fail "--uninstall: ${output}"
fi
if [[ ! -e "${F}/usr/lib/kyri/health" && -z "$(ls -A "${F}/usr/libexec")" && -z "$(ls -A "${F}/etc/systemd/system")" ]]; then
  pass "rollback removes the library, the helpers and the units"
else
  fail "rollback left runtime objects"
fi
evidence_after="$(evidence)"
if [[ "${evidence_before}" == "${evidence_after}" ]]; then
  pass "rollback leaves the account, every approval and every store record byte-identical"
else
  fail "rollback changed the identity or the evidence"
fi
if [[ -f "${F}/var/lib/kyri/health/capability-health-envelopes/CHENV-0001.yaml" ]]; then
  pass "the ingested record survives rollback"
else
  fail "the record is gone"
fi
if output="$(bash "${CEREMONY}" --uninstall --fixture "${F}" 2>&1)"; then
  expect "a second rollback is a no-op" '^ROLLED BACK$' "${output}"
else
  fail "second --uninstall: ${output}"
fi
if output="$(bash "${CEREMONY}" --verify-installed --fixture "${F}" 2>&1)"; then
  fail "--verify-installed passed with nothing installed"
else
  expect "verification fails once the runtime is removed" '0/6 runtime objects are installed' "${output}"
fi
if output="$(ceremony "${F}" --install)"; then
  expect "reinstallation over the kept evidence is DONE" '^DONE$' "${output}"
else
  fail "reinstall: ${output}"
fi
expect "reinstallation adopts the existing identity" 'kyri-health exists and is the ruled identity' "${output}"
if [[ "$(evidence)" == "${evidence_after}" ]]; then
  pass "reinstallation does not touch the identity or the evidence"
else
  fail "reinstall changed evidence"
fi

# --- installed objects that are not the reviewed ones -------------------------
tampered() {
  local description="$1" mutate="$2" pattern="$3"
  local fixture output
  fixture="$(new_fixture)"
  ceremony "${fixture}" --install >/dev/null || { fail "${description}: setup install failed"; return; }
  ( cd "${fixture}" && eval "${mutate}" )
  if output="$(bash "${CEREMONY}" --verify-installed --fixture "${fixture}" 2>&1)"; then
    fail "${description}: --verify-installed passed"
  else
    expect "${description}: --verify-installed fails" "${pattern}" "${output}"
  fi
  refused_unchanged "${description}: --install" "${fixture}" "${pattern}" --install
  before="$(snapshot "${fixture}")"
  if output="$(bash "${CEREMONY}" --uninstall --fixture "${fixture}" 2>&1)"; then
    fail "${description}: --uninstall removed a non-reviewed object"
  else
    if [[ "$(snapshot "${fixture}")" == "${before}" ]]; then
      pass "${description}: --uninstall refuses and removes nothing"
    else
      fail "${description}: --uninstall changed the fixture"
    fi
  fi
}
tampered "an edited helper" 'chmod u+w usr/libexec/kyri-health-ingest; printf "#\n" >> usr/libexec/kyri-health-ingest; chmod 0555 usr/libexec/kyri-health-ingest' \
  'kyri-health-ingest is not the reviewed bytes'
tampered "a writable helper" 'chmod 0755 usr/libexec/kyri-health-verify' 'kyri-health-verify is mode 755'
tampered "a second link to a helper" 'ln usr/libexec/kyri-health-approve usr/lib/approve-link' 'more than one link'
tampered "an extra library module" 'chmod u+w usr/lib/kyri/health/tools/health; : > usr/lib/kyri/health/tools/health/trust.py; chmod 0444 usr/lib/kyri/health/tools/health/trust.py; chmod 0755 usr/lib/kyri/health/tools/health' \
  'does not hold exactly the reviewed closure'
tampered "a bytecode cache in the library" 'chmod u+w usr/lib/kyri/health/tools; mkdir usr/lib/kyri/health/tools/__pycache__; chmod 0755 usr/lib/kyri/health/tools/__pycache__ usr/lib/kyri/health/tools' \
  'does not hold exactly the reviewed closure'
tampered "an edited library module" 'chmod u+w usr/lib/kyri/health/tools/health/ingest.py; printf "#\n" >> usr/lib/kyri/health/tools/health/ingest.py; chmod 0444 usr/lib/kyri/health/tools/health/ingest.py' \
  'ingest.py is not the reviewed bytes'
tampered "a group-writable library directory" 'chmod 0775 usr/lib/kyri/health/tools/common' 'does not hold exactly the reviewed closure'
tampered "a symlinked library module" 'chmod u+w usr/lib/kyri/health/tools/health; rm usr/lib/kyri/health/tools/health/errors.py; ln -s "'"${ROOT}"'/tools/health/errors.py" usr/lib/kyri/health/tools/health/errors.py; chmod 0755 usr/lib/kyri/health/tools/health' \
  'does not hold exactly the reviewed closure'
tampered "an edited unit" 'chmod u+w etc/systemd/system/kyri-health-verify.service; printf "ExecStartPre=/bin/true\n" >> etc/systemd/system/kyri-health-verify.service; chmod 0644 etc/systemd/system/kyri-health-verify.service' \
  'kyri-health-verify.service is not the reviewed bytes'

# --- state that is not as ruled is refused, before and after installation ----------
prepared() {
  local description="$1" mutate="$2" pattern="$3"
  local fixture
  fixture="$(new_fixture)"
  ( cd "${fixture}" && eval "${mutate}" )
  refused_unchanged "${description}: --verify" "${fixture}" "${pattern}" --verify
  refused_unchanged "${description}: --install" "${fixture}" "${pattern}" --install
}
uid="$(id -u)"; gid="$(id -g)"
account="kyri-health:x:${uid}:${gid}:Kyri Health runtime:/nonexistent:/usr/sbin/nologin"
prepared "a service account in the docker group" \
  "printf '%s\n' '${account}' >> etc/passwd; printf 'kyri-health:x:${gid}:\ndocker:x:988:kyri-health\n' >> etc/group; printf 'kyri-health:!:1::::::\n' >> etc/shadow" \
  'kyri-health is a member of: docker'
prepared "a service account in the sudo group" \
  "printf '%s\n' '${account}' >> etc/passwd; printf 'kyri-health:x:${gid}:\nsudo:x:27:cschott,kyri-health\n' >> etc/group; printf 'kyri-health:!:1::::::\n' >> etc/shadow" \
  'kyri-health is a member of: sudo'
prepared "a service account with a login shell" \
  "printf '%s\n' '${account/nologin/bash}' >> etc/passwd; printf 'kyri-health:x:${gid}:\n' >> etc/group; printf 'kyri-health:!:1::::::\n' >> etc/shadow" \
  'kyri-health shell is /usr/sbin/bash'
prepared "a service account with a password" \
  "printf '%s\n' '${account}' >> etc/passwd; printf 'kyri-health:x:${gid}:\n' >> etc/group; printf 'kyri-health:\$6\$salt\$hash:1::::::\n' >> etc/shadow" \
  'kyri-health has a usable password'
prepared "a service account named in sudoers" \
  "printf '%s\n' '${account}' >> etc/passwd; printf 'kyri-health:x:${gid}:\n' >> etc/group; printf 'kyri-health:!:1::::::\n' >> etc/shadow; printf 'kyri-health ALL=(ALL) NOPASSWD: ALL\n' > etc/sudoers.d/90-health" \
  'the sudoers policy names kyri-health'
prepared "a service account with a real home" \
  "printf '%s\n' '${account}' >> etc/passwd; printf 'kyri-health:x:${gid}:\n' >> etc/group; printf 'kyri-health:!:1::::::\n' >> etc/shadow; mkdir nonexistent" \
  '/nonexistent exists'
prepared "a group without its account" "printf 'kyri-health:x:4242:\n' >> etc/group" 'the account is ambiguous'
prepared "a group-writable approval root" \
  "mkdir -p var/lib/kyri/health-approvals; chmod 0711 var/lib/kyri; chmod 0775 var/lib/kyri/health-approvals" \
  'health-approvals is mode 775'
prepared "a group-readable approval staging directory" \
  "mkdir -p var/lib/kyri/health-approvals/.staging; chmod 0711 var/lib/kyri; chmod 0755 var/lib/kyri/health-approvals; chmod 0750 var/lib/kyri/health-approvals/.staging" \
  'staging is mode 750'
prepared "a store without its service account" "mkdir -p var/lib/kyri/health; chmod 0711 var/lib/kyri; chmod 0700 var/lib/kyri/health" \
  'exists but kyri-health does not'
prepared "a symlinked store root" "mkdir -p var/lib/kyri elsewhere; chmod 0711 var/lib/kyri; ln -s ../../elsewhere var/lib/kyri/health" \
  'health is not a directory'
prepared "an untraversable /var/lib/kyri" "mkdir -p var/lib/kyri; chmod 0700 var/lib/kyri" 'not traversable'
prepared "a group-writable /usr/lib" "chmod 0775 usr/lib" 'usr/lib is writable beyond its owner'
prepared "a symlinked libexec" "rmdir usr/libexec; mkdir libexec-real; chmod 0755 libexec-real; ln -s ../libexec-real usr/libexec" \
  'libexec is not a directory'
prepared "a missing unit directory" "rmdir etc/systemd/system" 'systemd/system does not exist'
prepared "interrupted library staging" "mkdir -p usr/lib/kyri/.health-staging; chmod 0755 usr/lib/kyri" 'residue is not adopted'
prepared "interrupted helper staging" ": > usr/libexec/.kyri-health-verify.kyri-health-staging" 'residue is not adopted'

F="$(new_fixture)"
( cd "${F}" && mkdir -p usr/lib/kyri/.health-staging && chmod 0755 usr/lib/kyri )
if output="$(bash "${CEREMONY}" --uninstall --fixture "${F}" 2>&1)" && [[ ! -e "${F}/usr/lib/kyri/.health-staging" ]]; then
  pass "rollback clears interrupted-ceremony residue"
else
  fail "rollback did not clear residue: ${output}"
fi
if output="$(ceremony "${F}" --install)"; then
  expect "and installation then proceeds" '^DONE$' "${output}"
else
  fail "install after residue clean-up: ${output}"
fi

# --- the pin itself ------------------------------------------------------------------
pinned_copy() {
  local copy="${SCRATCH}/pinned-$1.sh"
  sed "$2" "${CEREMONY}" > "${copy}"
  printf '%s' "${copy}"
}
F="$(new_fixture)"
before="$(snapshot "${F}")"
copy="$(pinned_copy commit 's/^COMMIT="[0-9a-f]*"$/COMMIT="0000000000000000000000000000000000000000"/')"
output="$(bash "${copy}" --install --fixture "${F}" --repository "${ROOT}" 2>&1)" && rc=0 || rc=$?
if [[ "${rc}" != "0" ]]; then
  expect "an unknown pinned commit is refused" 'does not exist' "${output}"
else
  fail "unknown commit accepted"
fi
copy="$(pinned_copy digest '0,/|0444|04d746ac/s/|0444|04d746ac/|0444|14d746ac/')"
output="$(bash "${copy}" --install --fixture "${F}" --repository "${ROOT}" 2>&1)" && rc=0 || rc=$?
if [[ "${rc}" != "0" ]]; then
  expect "a payload whose digest is not pinned installs nothing" 'is not the reviewed bytes; nothing was installed' "${output}"
else
  fail "mismatched digest accepted"
fi
copy="$(pinned_copy path 's#^"tools/health/store.py|#"tools/health/records.py|#')"
output="$(bash "${copy}" --install --fixture "${F}" --repository "${ROOT}" 2>&1)" && rc=0 || rc=$?
if [[ "${rc}" != "0" ]]; then
  expect "a substituted source path installs nothing" 'nothing was installed' "${output}"
else
  fail "substituted path accepted"
fi
if [[ "$(snapshot "${F}")" == "${before}" ]]; then
  pass "refused pins change nothing"
else
  fail "a refused pin changed the fixture"
fi

if [[ "$(production_state)" == "${PRODUCTION_BEFORE}" && "${PRODUCTION_BEFORE}" == "absent absent absent absent " ]]; then
  pass "no production Health path exists before or after"
else
  fail "production Health paths: before '${PRODUCTION_BEFORE}', after '$(production_state)'"
fi

printf '\n'
if (( FAILURES > 0 )); then
  printf 'Health install validation FAILED with %d error(s).\n' "${FAILURES}" >&2
  exit 1
fi
printf 'All health install assertions passed.\n'
