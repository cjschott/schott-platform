#!/usr/bin/env bash
set -Eeuo pipefail

# Freeze and install the EXECUTION identity authority for this deployment.
#
# This is one half of the G11-AW ceremony. The other half --
# `g11-aw-freeze-coordinator-identity.sh` -- installs a different file naming a
# different principal, and the two are deliberately separate programs. The
# reasoning for the duplication is written out there and applies here unchanged.
#
# THE TWO AUTHORITIES ARE NOT THE SAME KIND OF THING
# ==================================================
# The coordinator authority names a publisher to RECOGNISE: the helper checks
# `st_uid` on descriptors it already holds, so the uid is the authority and the
# name is documentation. This one names an identity to BECOME, and the failure
# it must survive is a stale authority naming an account whose uid was later
# reassigned. A number alone cannot detect that and a name alone would put NSS
# in charge of who root becomes, so this record carries the account, the uid AND
# the primary gid, and `load_execution_identity` requires all three to still
# agree with the account database.
#
# That is why this file has one more field than the coordinator's, and why the
# two must never be merged: they are two security roles, and one document naming
# both would make them editable together.
#
# WHY THE BODY IS DERIVED AND NOT TYPED
# =====================================
# `WORKER_USER`, `WORKER_UID` and `WORKER_GID` were compiled into the privileged
# helper and were true of `schai` because `useradd` happened to assign those
# numbers. G11-AS removed them. A ceremony that installed a typed body would put
# them back one directory further out, so the account name is the single input,
# every number comes from the account database, and the reviewed digest is what
# makes the result reviewable: if this deployment no longer renders the reviewed
# bytes, the ceremony refuses rather than installing something nobody approved.
#
# READ-ONLY UNTIL THE INSTALL. Everything before `install` is derivation and
# comparison. It invokes no helper, executes no capability workload, creates no
# record, and touches no pathname other than its own temporary file and the one
# destination named below.
#
# Rehearsal:  KYRI_IDENTITY_FIXTURE=/some/disposable/root bash "$0"
# Production: bash "$0"

# Derived from this script's own location rather than written out. The readers
# this ceremony validates against must be the ones that shipped beside it: a
# ceremony reviewed in one tree and validating against another is not the
# ceremony that was reviewed.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ACCOUNT="${1:-kyri-capability}"
AUTHORITY="/etc/kyri/execution-identity.json"
REVIEWED_SHA256="891beeeb35bbf0e70dad9351825f34595875e8090f831c5db83ed8f66466e373"
REVIEWED_BYTES=99

# Fixture mode redirects the destination under a disposable root and drops the
# elevation. It changes WHERE the ceremony writes and nothing about WHAT it
# writes: the bytes, the digest comparison and the refusals are the same code.
FIXTURE="${KYRI_IDENTITY_FIXTURE:-}"
if [[ -n "${FIXTURE}" ]]; then
  DESTINATION="${FIXTURE}${AUTHORITY}"
  PRIV=()
  OWNERSHIP=()
  mkdir -p "$(dirname "${DESTINATION}")"
else
  DESTINATION="${AUTHORITY}"
  PRIV=(sudo)
  OWNERSHIP=(-o root -g root)
fi

cd "${REPOSITORY}"

refuse() { printf 'REFUSE: %s\n' "$1" >&2; exit 1; }

printf '=== B1 destination state ===\n'
# First, and before anything is rendered. An authority that is already there was
# installed by a decision this ceremony did not make, and overwriting it would
# silently change which kernel identity root permanently becomes.
if [[ -e "${DESTINATION}" ]]; then
  refuse "${DESTINATION} already exists; this ceremony never overwrites an authority"
fi
printf '%s absent\n' "${DESTINATION}"

printf '\n=== B2 observed account facts ===\n'
python3 - "${ACCOUNT}" <<'PY'
import grp
import pwd
import sys

account = sys.argv[1]
try:
    entry = pwd.getpwnam(account)
except KeyError:
    raise SystemExit(f"REFUSE: the account database does not know {account!r}")
print(f"account        {entry.pw_name}")
print(f"uid            {entry.pw_uid}")
print(f"primary gid    {entry.pw_gid}")
try:
    print(f"group name     {grp.getgrgid(entry.pw_gid).gr_name}")
except KeyError:
    print("group name     <unresolvable>")
print(f"shell          {entry.pw_shell}")
PY

printf '\n=== B3 reconstruct the reviewed bytes ===\n'
TEMPORARY="$(mktemp)"
trap 'rm -f "${TEMPORARY}"' EXIT
python3 - "${ACCOUNT}" > "${TEMPORARY}" <<'PY'
import json
import pwd
import sys

entry = pwd.getpwnam(sys.argv[1])
# Canonical: sorted keys, no insignificant whitespace, one trailing newline --
# the convention `g11-as-execution-identity-candidate.sh` states, and the same
# shape the coordinator authority is provisioned in.
#
# The record answers exactly one question: which local kernel identity is
# authorised to execute capability workloads on this deployment. Not where
# storage lives, not what the container runs as, not what the coordinator is.
document = {
    "execution_account": entry.pw_name,
    "execution_gid": entry.pw_gid,
    "execution_uid": entry.pw_uid,
    "schema_version": 1,
}
sys.stdout.write(json.dumps(document, sort_keys=True, separators=(",", ":")))
sys.stdout.write("\n")
PY

ACTUAL_SHA256="$(sha256sum "${TEMPORARY}" | cut -d' ' -f1)"
ACTUAL_BYTES="$(stat -c '%s' "${TEMPORARY}")"
printf 'body            %s\n' "$(cat "${TEMPORARY}")"
printf 'bytes           %s (reviewed %s)\n' "${ACTUAL_BYTES}" "${REVIEWED_BYTES}"
printf 'sha256          %s\n' "${ACTUAL_SHA256}"
printf 'reviewed        %s\n' "${REVIEWED_SHA256}"

# The FULL digest, not a prefix. An abbreviated comparison is not a comparison.
if [[ "${ACTUAL_SHA256}" != "${REVIEWED_SHA256}" ]]; then
  refuse "this deployment renders ${ACTUAL_SHA256}, and the reviewed candidate is ${REVIEWED_SHA256}"
fi
if [[ "${ACTUAL_BYTES}" != "${REVIEWED_BYTES}" ]]; then
  refuse "this deployment renders ${ACTUAL_BYTES} bytes, and the reviewed candidate is ${REVIEWED_BYTES}"
fi
printf 'digest          MATCHES the reviewed candidate\n'

printf '\n=== B4 install ===\n'
"${PRIV[@]}" install "${OWNERSHIP[@]}" -m 0444 "${TEMPORARY}" "${DESTINATION}"
rm -f "${TEMPORARY}"
trap - EXIT
printf 'installed       %s\n' "${DESTINATION}"

printf '\n=== B5 installed state, read back ===\n'
"${PRIV[@]}" sha256sum "${DESTINATION}"
"${PRIV[@]}" stat -c '%n  %U:%G  %a  %s bytes' "${DESTINATION}"

printf '\n=== B6 accepted parsers ===\n'
python3 - "${DESTINATION}" "${REVIEWED_SHA256}" "${FIXTURE}" <<'PY'
import hashlib
import importlib.util
import os
import pwd
import stat
import sys

destination, reviewed, fixture = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, ".")

# BOTH accepted readers, over the same bytes. The privileged helpers cannot
# import the runtime package, so this grammar exists twice; an authority the
# helper would take and the runtime would refuse -- or the reverse -- is not an
# authority, and there is no point discovering that after installation.
spec = importlib.util.spec_from_file_location(
    "kyri_exec_transition", "provisioning/execution/kyri-exec-transition.py")
policy = importlib.util.module_from_spec(spec)
sys.modules["kyri_exec_transition"] = policy
spec.loader.exec_module(policy)
from tools.capability.execution import identity as runtime  # noqa: E402

with open(destination, "rb") as handle:
    raw = handle.read()
observed = os.stat(destination)

digest = hashlib.sha256(raw).hexdigest()
if digest != reviewed:
    raise SystemExit(f"REFUSE: the installed bytes hash to {digest}")
print("bytes           byte-identical to the reviewed candidate")

if fixture:
    # A fixture cannot be root-owned without privilege, so the ownership rule is
    # proven the only way that is honest here: by requiring the readers to
    # REFUSE the file as installed, and then accepting the same bytes under a
    # root-owned status. The gate is exercised in both directions rather than
    # branched around.
    for name, refused in (("policy", policy.TransitionRefused),
                          ("runtime", runtime.ExecutionIdentityError)):
        loader = (policy.load_execution_identity if name == "policy"
                  else runtime.load_execution_identity)
        try:
            loader(raw, observed, resolve=runtime.resolve_account)
        except refused as error:
            print(f"ownership gate  {name} REFUSES the unprivileged fixture: {error}")
        else:
            raise SystemExit(
                f"REFUSE: the {name} reader accepted a file root does not own")

    class Status:
        st_mode = stat.S_IFREG | 0o444
        st_uid = 0
        st_gid = 0

    observed = Status()
else:
    if observed.st_uid != 0 or observed.st_gid != 0:
        raise SystemExit("REFUSE: the installed authority is not owned by root:root")
    if stat.S_IMODE(observed.st_mode) != 0o444:
        raise SystemExit("REFUSE: the installed authority is not mode 0444")
    print("ownership       root:root 0444")

# `resolve_account` is the released resolver, not one written here. The binding
# it performs -- account -> (uid, gid) -- happens INSIDE each parser, where a
# caller cannot skip it.
by_policy = policy.load_execution_identity(
    raw, observed, resolve=runtime.resolve_account)
by_runtime = runtime.load_execution_identity(
    raw, observed, resolve=runtime.resolve_account)
print("parsed by       kyri_exec_transition.load_execution_identity   PASS")
print("parsed by       tools.capability.execution.identity            PASS")

if (by_policy.account, by_policy.uid, by_policy.gid) != (
        by_runtime.account, by_runtime.uid, by_runtime.gid):
    raise SystemExit("REFUSE: the two accepted parsers disagree on the installed authority")
print("parser agreement  both readers derive the same identity  PASS")

entry = pwd.getpwnam(by_policy.account)
if (entry.pw_uid, entry.pw_gid) != (by_policy.uid, by_policy.gid):
    raise SystemExit(
        f"REFUSE: the account database resolves {by_policy.account!r} to "
        f"{entry.pw_uid}:{entry.pw_gid}, and the authority names "
        f"{by_policy.uid}:{by_policy.gid}")
print(f"execution       {by_policy.account} {by_policy.uid}:{by_policy.gid}")
print(f"account binding {by_policy.account} -> {entry.pw_uid}:{entry.pw_gid}  PASS")
print(f"environment     {policy.execution_environment(by_policy)}")
PY

printf '\nEXECUTION_IDENTITY_INSTALLED=YES\n'
printf 'EXECUTION_IDENTITY_SHA256=%s\n' "${REVIEWED_SHA256}"
