#!/usr/bin/env bash
set -Eeuo pipefail

# Derive the execution identity authority candidate for THIS deployment.
#
# READ-ONLY. It resolves an account, renders a document, rehearses the accepted
# parser against it in a fixture, and prints what an operator would install. It
# creates nothing under /etc, invokes no helper, and uses no sudo.
#
# WHY THE BODY IS DERIVED AND NOT WRITTEN OUT
# ===========================================
# The whole defect this authority closes is a deployment's account numbers being
# carried in source as if they were properties of Kyri. A ceremony that printed
# a body somebody typed would reproduce that defect one directory further out:
# the candidate would be right about `schai` for the same reason the constants
# were -- coincidence -- and wrong the first time it met another host.
#
# So the account name is the only input, and every number comes from the system
# account database. If the account does not exist, there is no candidate.
#
# WHAT THE OPERATOR STILL DECIDES
# ===============================
# Everything. This prints a candidate and a freeze block; it does not install,
# and it refuses to suggest installing over an authority that already exists.

REPOSITORY="/opt/schott-platform"
ACCOUNT="${1:-kyri-capability}"
DESTINATION="/etc/kyri/execution-identity.json"
EXPECTED_OWNER="root:root"
EXPECTED_MODE="0444"

cd "${REPOSITORY}"

die() { printf 'ABORT: %s\n' "$1" >&2; exit 1; }

printf '=== M0 observed account facts ===\n'
python3 - "${ACCOUNT}" <<'PY' || die "the account could not be resolved"
import grp
import pwd
import sys

account = sys.argv[1]
try:
    entry = pwd.getpwnam(account)
except KeyError:
    raise SystemExit(f"ABORT: the account database does not know {account!r}")
print(f"account        {entry.pw_name}")
print(f"uid            {entry.pw_uid}")
print(f"primary gid    {entry.pw_gid}")
try:
    print(f"group name     {grp.getgrgid(entry.pw_gid).gr_name}")
except KeyError:
    print("group name     <unresolvable>")
print(f"shell          {entry.pw_shell}")
PY

printf '\n=== M1 candidate, rehearsed through the accepted parser ===\n'
python3 - "${ACCOUNT}" "${DESTINATION}" <<'PY' || die "the candidate was refused by its own parser"
import hashlib
import importlib.util
import json
import os
import pwd
import stat
import sys
import tempfile

sys.path.insert(0, ".")
account, destination = sys.argv[1], sys.argv[2]
entry = pwd.getpwnam(account)

# Canonical: sorted keys, no insignificant whitespace, one trailing newline.
# The same shape the coordinator authority is provisioned in, so an operator
# comparing the two files sees one convention rather than two.
document = {
    "execution_account": entry.pw_name,
    "execution_gid": entry.pw_gid,
    "execution_uid": entry.pw_uid,
    "schema_version": 1,
}
body = json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n"
raw = body.encode("utf-8")

# Both accepted parsers, driven over the same bytes. A candidate the privileged
# helper would take and the runtime would refuse -- or the reverse -- is not a
# candidate, and there is no point discovering that after installation.
spec = importlib.util.spec_from_file_location(
    "kyri_exec_transition", "provisioning/execution/kyri-exec-transition.py")
policy = importlib.util.module_from_spec(spec)
sys.modules["kyri_exec_transition"] = policy
spec.loader.exec_module(policy)
from tools.capability.execution import identity as runtime  # noqa: E402

with tempfile.TemporaryDirectory() as work:
    path = os.path.join(work, "execution-identity.json")
    with open(path, "wb") as handle:
        handle.write(raw)
    os.chmod(path, 0o444)
    # The fixture cannot be root-owned without privilege, so the mode and shape
    # are rehearsed here and the ownership rule is rehearsed against a status
    # the parser is handed directly.
    observed = os.stat(path)
    if stat.S_IMODE(observed.st_mode) != 0o444:
        raise SystemExit("ABORT: the rehearsal file did not take mode 0444")

    class Status:
        st_mode = stat.S_IFREG | 0o444
        st_uid = 0
        st_gid = 0

    resolved = policy.load_execution_identity(
        raw, Status(), resolve=lambda name: (entry.pw_uid, entry.pw_gid))
    runtime_identity = runtime.load_execution_identity(
        raw, Status(), resolve=lambda name: (entry.pw_uid, entry.pw_gid))

if (resolved.account, resolved.uid, resolved.gid) != (
        runtime_identity.account, runtime_identity.uid, runtime_identity.gid):
    raise SystemExit("ABORT: the two accepted parsers disagree on the candidate")
if (resolved.account, resolved.uid, resolved.gid) != (
        entry.pw_name, entry.pw_uid, entry.pw_gid):
    raise SystemExit("ABORT: the parsed identity is not the observed account")

print("candidate body:")
print(f"  {body.rstrip()}")
print(f"bytes           {len(raw)}")
print(f"sha256          {hashlib.sha256(raw).hexdigest()}")
print(f"destination     {destination}")
print(f"parsed by       kyri_exec_transition.load_execution_identity  PASS")
print(f"parsed by       tools.capability.execution.identity           PASS")
print(f"environment     {policy.execution_environment(resolved)}")
PY

printf '\n=== M2 destination state ===\n'
if [[ -e "${DESTINATION}" ]]; then
  printf '%s EXISTS -- this ceremony proposes nothing over an existing authority\n' \
    "${DESTINATION}"
  exit 0
fi
printf '%s absent\n' "${DESTINATION}"
printf 'expected owner  %s\n' "${EXPECTED_OWNER}"
printf 'expected mode   %s\n' "${EXPECTED_MODE}"

printf '\n=== M3 operator freeze block (NOT EXECUTED HERE) ===\n'
cat <<'BLOCK'
# Run as root, after reviewing the candidate above. Refuses if the destination
# exists: an authority that is already there was installed by a decision this
# ceremony did not make.
test ! -e /etc/kyri/execution-identity.json || {
  echo "REFUSE: the execution identity authority already exists"; exit 1; }
install -o root -g root -m 0444 /dev/stdin /etc/kyri/execution-identity.json <<'BODY'
<the exact candidate body printed above>
BODY
stat -c '%U:%G %a %n' /etc/kyri/execution-identity.json
sha256sum /etc/kyri/execution-identity.json
BLOCK

printf '\nEXECUTION_IDENTITY_CANDIDATE=READY\n'
printf 'INSTALLED=NO\n'
