#!/usr/bin/env bash
set -Eeuo pipefail

# Freeze and install the COORDINATOR identity authority for this deployment.
#
# This is one half of the G11-AW ceremony. The other half --
# `g11-aw-freeze-execution-identity.sh` -- installs a different file naming a
# different principal, and the two are deliberately separate programs.
#
# WHY TWO SCRIPTS AND NOT ONE WITH A ROLE ARGUMENT
# ================================================
# The duplication below is intentional. These install root-owned authority that
# decides who a privileged boundary trusts, and the reviewer's question is "what
# exactly will land at this pathname" -- a question that must be answerable by
# reading one file top to bottom. A shared implementation would mean reviewing
# one program to authorise two irreversible writes, and would make a partial
# ceremony ambiguous: with two scripts, "A succeeded and B did not" is a state
# the operator can see, name, and stop in.
#
# WHY THE BODY IS DERIVED AND NOT TYPED
# =====================================
# G11-AH removed `COORDINATOR_UID = 1000` from the privileged helper because it
# was true of `schai` only by coincidence. A ceremony that installed a body
# somebody typed would reintroduce that defect one directory further out. So
# the account name is the single input, every number comes from the account
# database, and the reviewed digest below is what makes the result reviewable:
# if this deployment no longer renders the reviewed bytes, the ceremony refuses
# rather than installing something nobody approved.
#
# The reviewed digest is a REVIEW artifact, not a deployment fact. It is the
# G11-AV accepted candidate, independently re-derived in G11-AW from live
# account facts and the encoding convention `/etc/kyri` already demonstrates.
#
# READ-ONLY UNTIL THE INSTALL. Everything before `install` is derivation and
# comparison. It invokes no helper, executes no capability workload, creates no
# record, and touches no pathname other than its own temporary file and the one
# destination named below.
#
# Rehearsal:  KYRI_IDENTITY_FIXTURE=/some/disposable/root bash "$0"
# Production: bash "$0"

# Derived from this script's own location rather than written out. The reader
# this ceremony validates against must be the one that shipped beside it: a
# ceremony reviewed in one tree and validating against another is not the
# ceremony that was reviewed.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ACCOUNT="${1:-cschott}"
AUTHORITY="/etc/kyri/coordinator-identity.json"
REVIEWED_SHA256="3dec888c9efa4214d9cbc8a943818fbe21cd41fbf81ee252a1e38d5d25fd2811"
REVIEWED_BYTES=76

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

printf '=== A1 destination state ===\n'
# First, and before anything is rendered. An authority that is already there was
# installed by a decision this ceremony did not make, and overwriting it would
# silently replace whoever the boundary currently trusts.
if [[ -e "${DESTINATION}" ]]; then
  refuse "${DESTINATION} already exists; this ceremony never overwrites an authority"
fi
printf '%s absent\n' "${DESTINATION}"

printf '\n=== A2 observed account facts ===\n'
python3 - "${ACCOUNT}" <<'PY'
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
PY

printf '\n=== A3 reconstruct the reviewed bytes ===\n'
TEMPORARY="$(mktemp)"
trap 'rm -f "${TEMPORARY}"' EXIT
python3 - "${ACCOUNT}" > "${TEMPORARY}" <<'PY'
import json
import pwd
import sys

entry = pwd.getpwnam(sys.argv[1])
# Canonical: sorted keys, no insignificant whitespace, one trailing newline --
# the convention `g11-as-execution-identity-candidate.sh` states and the
# execution authority is provisioned in, so an operator comparing the two files
# in /etc/kyri sees one convention rather than two.
#
# `coordinator_uid` is the authority and `coordinator_account` is documentation:
# the privileged helper checks `st_uid` on descriptors it already holds, which
# is a kernel fact needing no lookup, and the name is carried because the
# sudoers grant is written in names.
document = {
    "coordinator_account": entry.pw_name,
    "coordinator_uid": entry.pw_uid,
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

printf '\n=== A4 install ===\n'
"${PRIV[@]}" install "${OWNERSHIP[@]}" -m 0444 "${TEMPORARY}" "${DESTINATION}"
rm -f "${TEMPORARY}"
trap - EXIT
printf 'installed       %s\n' "${DESTINATION}"

printf '\n=== A5 installed state, read back ===\n'
"${PRIV[@]}" sha256sum "${DESTINATION}"
"${PRIV[@]}" stat -c '%n  %U:%G  %a  %s bytes' "${DESTINATION}"

printf '\n=== A6 accepted parser ===\n'
python3 - "${DESTINATION}" "${REVIEWED_SHA256}" "${FIXTURE}" <<'PY'
import hashlib
import importlib.util
import os
import stat
import sys

destination, reviewed, fixture = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, ".")

# The accepted reader, loaded from the reviewed source. There is deliberately no
# second parser here: a ceremony that validated with its own copy of the grammar
# would be checking that the ceremony agrees with itself.
spec = importlib.util.spec_from_file_location(
    "kyri_exec_transition", "provisioning/execution/kyri-exec-transition.py")
policy = importlib.util.module_from_spec(spec)
sys.modules["kyri_exec_transition"] = policy
spec.loader.exec_module(policy)

with open(destination, "rb") as handle:
    raw = handle.read()
observed = os.stat(destination)

digest = hashlib.sha256(raw).hexdigest()
if digest != reviewed:
    raise SystemExit(f"REFUSE: the installed bytes hash to {digest}")
print(f"bytes           byte-identical to the reviewed candidate")

if fixture:
    # A fixture cannot be root-owned without privilege, so the ownership rule is
    # proven the only way that is honest here: by requiring the reader to REFUSE
    # the file as installed, and then accepting the same bytes under a
    # root-owned status. The gate is exercised in both directions rather than
    # branched around.
    try:
        policy.load_coordinator_authority(raw, observed)
    except policy.TransitionRefused as error:
        print(f"ownership gate  REFUSES the unprivileged fixture: {error}")
    else:
        raise SystemExit("REFUSE: the reader accepted a file root does not own")

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
    print(f"ownership       root:root 0444")

authority = policy.load_coordinator_authority(raw, observed)
print(f"parsed by       kyri_exec_transition.load_coordinator_authority  PASS")
print(f"coordinator     {authority.coordinator_account} uid {authority.coordinator_uid}")

# The account the authority names must still be the account it was derived from.
import pwd  # noqa: E402
entry = pwd.getpwnam(authority.coordinator_account)
if entry.pw_uid != authority.coordinator_uid:
    raise SystemExit(
        f"REFUSE: the account database resolves {authority.coordinator_account!r} "
        f"to uid {entry.pw_uid}, and the authority names {authority.coordinator_uid}")
print(f"account binding {authority.coordinator_account} -> {entry.pw_uid}  PASS")
PY

printf '\nCOORDINATOR_IDENTITY_INSTALLED=YES\n'
printf 'COORDINATOR_IDENTITY_SHA256=%s\n' "${REVIEWED_SHA256}"
