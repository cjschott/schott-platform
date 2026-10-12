#!/usr/bin/env bash
set -Eeuo pipefail

# G11-AH: the coordinator is a DEPLOYMENT identity, not the number 1000.
#
# THE DEFECT. `kyri-exec-transition.py` compiled in `COORDINATOR_UID = 1000`,
# and the privileged action read it to decide whether the launch record and the
# handoff directory were published by the coordinator. Three suites passed on
# `schai` because `cschott` happens to be uid 1000. Nothing derived it, nothing
# provisioned it, and no deployment could state a different one -- so the
# privileged boundary's notion of "the coordinator" was a coincidence of this
# host, compiled into source that is meant to be deployment-independent.
#
# THE AUTHORITY. `/etc/kyri/coordinator-identity.json`, `root:root 0444`, in the
# `/etc/kyri` directory the backing-store descriptor already uses. Read at the
# privileged boundary, never generated, never defaulted, and never overridden by
# the environment. Absent, malformed, wrongly owned, or writable by anyone but
# root is a refusal -- there is no repair path and no fallback constant to fall
# back TO, which is the point.
#
# WHY THE NUMERIC UID IS AUTHORITATIVE AND THE NAME IS NOT. The kernel fact the
# helper can actually check is `st_uid` on a descriptor it already holds. A name
# would have to be resolved through NSS at the privileged boundary, which is a
# lookup the helper must not depend on and an indirection an attacker could aim.
# The account name is carried because the sudoers grant is written in names, and
# it is carried as DERIVED material -- §6 proves it cannot disagree with the uid.
#
# WHAT IS NOT ADDED, AND WHY. Neither the launch record nor the execution
# profile gains a `coordinator_uid` field. Coordinator identity is deployment
# authority, not per-invocation authority, and a caller-supplied field would be
# an assertion the caller controls. Ownership of the published objects is a
# kernel fact the caller cannot forge, and it is already what the helper checks.
# Adding the field would weaken the boundary while appearing to strengthen it.
#
# POLICY ONLY. No sudo, no root, no installation, no identity change, no
# execution. Fixtures are temporary files owned by the running user; the cases
# that need root ownership or foreign uids supply a synthetic `os.stat_result`
# rather than pretending this suite can create one.
#
# Governed by:
#   docs/development/reports/eng-0005/2026-08-30-g11-aa-first-invoke-preflight.md
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md §6

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"

PRODUCTION_ETC=/etc/kyri                            # prod-path-reference
BEFORE="$(ls -ldn "${PRODUCTION_ETC}" 2>/dev/null || printf 'absent')"

python3 - <<'PY'
import importlib.util, json, os, stat, sys, tempfile
from pathlib import Path

sys.path.insert(0, ".")
sys.dont_write_bytecode = True

failures = 0
def check(condition, description):
    global failures
    if condition:
        print(f"PASS: {description}")
    else:
        failures += 1
        print(f"FAIL: {description}", file=sys.stderr)


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, Path(relative))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module

policy = load("kyri_exec_transition",
              "provisioning/execution/kyri-exec-transition.py")
Refused = policy.TransitionRefused


def refuses(thunk, fragment, description):
    try:
        thunk()
    except Refused as error:
        if fragment in str(error):
            print(f"PASS: {description}")
            return 0
        print(f"FAIL: {description} -- refused for {str(error)!r}, "
              f"expected {fragment!r}", file=sys.stderr)
        return 1
    except Exception as error:  # noqa: BLE001
        print(f"FAIL: {description} -- raised {type(error).__name__}: {error}",
              file=sys.stderr)
        return 1
    print(f"FAIL: {description} -- accepted", file=sys.stderr)
    return 1


def status(*, uid=0, gid=0, mode=0o100444, size=128):
    """A synthetic stat result. The suite cannot chown, so it states facts."""
    return os.stat_result((mode, 1, 1, 1, uid, gid, size, 0, 0, 0))


BODY = {"schema_version": 1, "coordinator_uid": 1000,
        "coordinator_account": "cschott"}
def encoded(**overrides):
    document = dict(BODY)
    for name, value in overrides.items():
        if value is _ABSENT:
            document.pop(name, None)
        else:
            document[name] = value
    return json.dumps(document, sort_keys=True,
                      separators=(",", ":")).encode("utf-8")
_ABSENT = object()

print("== the authority is declared, and 1000 is not ==\n")

source = Path("provisioning/execution/kyri-exec-transition.py").read_text(
    encoding="utf-8")
check("COORDINATOR_UID = 1000" not in source,
      "no universal coordinator uid remains compiled into the helper policy")
check(getattr(policy, "COORDINATOR_UID", None) is None,
      "the policy module exports no COORDINATOR_UID constant")
check(getattr(policy, "COORDINATOR_AUTHORITY_PATH", None)
      == "/etc/kyri/coordinator-identity.json",
      "the deployment authority has one compiled-in location")

action_source = Path(
    "provisioning/execution/kyri-exec-transition-action.py").read_text(
    encoding="utf-8")
check("module.COORDINATOR_UID" not in action_source,
      "the privileged action no longer reads a compiled-in coordinator uid")

print("\n== 1/2. any approved deployment identity is honoured ==\n")

# The reviewer's cases 1 and 2: the authority decides, and 1000 has no special
# standing. Both are ordinary acceptances of whatever the deployment approved.
for uid in (1000, 1001, 65534):
    authority = policy.load_coordinator_authority(
        encoded(coordinator_uid=uid), status())
    check(authority.coordinator_uid == uid,
          f"a deployment approving uid {uid} yields uid {uid}")

authority = policy.load_coordinator_authority(encoded(), status())
check(authority.coordinator_account == "cschott",
      "the account name is carried for sudoers derivation")
check(type(authority).__name__ == "CoordinatorAuthority",
      "the result is a closed type, not the caller's dictionary")
try:
    object.__setattr__  # noqa: B018
    authority.coordinator_uid = 0
    check(False, "the authority is immutable")
except Exception:  # noqa: BLE001
    check(True, "the authority is immutable once built")

print("\n== 3. a caller whose uid is not the approved one is refused ==\n")

# The comparison the privileged boundary actually makes. Ownership of the
# published objects is a kernel fact; this is the check that consumes it.
authority = policy.load_coordinator_authority(
    encoded(coordinator_uid=1000), status())
failures += refuses(
    lambda: policy.check_evidence_object(
        status(uid=1001, mode=0o100600),
        expected_uid=authority.coordinator_uid),
    "owned by the wrong identity",
    "a launch record published by uid 1001 under an authority naming 1000 refuses")
try:
    policy.check_evidence_object(status(uid=1000, mode=0o100600),
                                 expected_uid=authority.coordinator_uid)
    check(True, "and the same record published by the approved uid is accepted")
except Refused as error:
    check(False, f"and the same record published by the approved uid is accepted ({error})")

# Symmetrically, a deployment approving 1001 accepts 1001 and refuses 1000 --
# which is what proves the rule follows the authority rather than the number.
other = policy.load_coordinator_authority(encoded(coordinator_uid=1001), status())
try:
    policy.check_evidence_object(status(uid=1001, mode=0o100600),
                                 expected_uid=other.coordinator_uid)
    check(True, "a deployment approving 1001 accepts a record published by 1001")
except Refused as error:
    check(False, f"a deployment approving 1001 accepts 1001 ({error})")
failures += refuses(
    lambda: policy.check_evidence_object(
        status(uid=1000, mode=0o100600), expected_uid=other.coordinator_uid),
    "owned by the wrong identity",
    "and refuses uid 1000, which has no standing of its own")

print("\n== 4/5. absent and malformed authority fail closed ==\n")

failures += refuses(lambda: policy.load_coordinator_authority(None, status()),
                    "must be bytes",
                    "an absent authority body refuses")
failures += refuses(lambda: policy.load_coordinator_authority(b"", status()),
                    "not one JSON document",
                    "an empty authority refuses")
failures += refuses(lambda: policy.load_coordinator_authority(b"{", status()),
                    "not one JSON document",
                    "a truncated authority refuses")
failures += refuses(lambda: policy.load_coordinator_authority(b"[]", status()),
                    "not a JSON object",
                    "a non-object authority refuses")
failures += refuses(
    lambda: policy.load_coordinator_authority(
        b'{"coordinator_uid":1000,"coordinator_uid":1001,'
        b'"schema_version":1,"coordinator_account":"x"}', status()),
    "repeats the field",
    "a duplicated field refuses rather than collapsing to a last-wins value")
failures += refuses(
    lambda: policy.load_coordinator_authority(encoded(coordinator_uid=_ABSENT),
                                              status()),
    "missing", "a missing coordinator_uid refuses")
failures += refuses(
    lambda: policy.load_coordinator_authority(encoded(extra="x"), status()),
    "unknown field", "an unknown field refuses rather than being carried")
failures += refuses(
    lambda: policy.load_coordinator_authority(encoded(schema_version=2), status()),
    "unsupported", "an unsupported schema version refuses")
failures += refuses(
    lambda: policy.load_coordinator_authority(
        encoded(coordinator_uid="1000"), status()),
    "does not name a uid", "a string uid refuses rather than being coerced")
failures += refuses(
    lambda: policy.load_coordinator_authority(
        encoded(coordinator_uid=True), status()),
    "does not name a uid", "a boolean uid refuses -- True is not 1")
failures += refuses(
    lambda: policy.load_coordinator_authority(encoded(coordinator_uid=0), status()),
    "does not name a uid", "uid 0 refuses: root is not the coordinator")
failures += refuses(
    lambda: policy.load_coordinator_authority(encoded(coordinator_uid=-1), status()),
    "does not name a uid", "a negative uid refuses")
failures += refuses(
    lambda: policy.load_coordinator_authority(
        encoded(coordinator_account=""), status()),
    "account", "an empty account name refuses")
failures += refuses(
    lambda: policy.load_coordinator_authority(
        b"x" * (policy.MAXIMUM_COORDINATOR_AUTHORITY_BYTES + 1), status()),
    "exceeds", "an oversized authority refuses on its bytes, before parsing")

print("\n== 6/7. ownership and mode are part of the authority ==\n")

failures += refuses(
    lambda: policy.load_coordinator_authority(encoded(), status(uid=1000)),
    "owned by", "an authority owned by the coordinator refuses -- it could edit it")
failures += refuses(
    lambda: policy.load_coordinator_authority(encoded(), status(gid=1000)),
    "owned by", "an authority in a non-root group refuses")
failures += refuses(
    lambda: policy.load_coordinator_authority(encoded(), status(mode=0o100664)),
    "writable", "a group-writable authority refuses")
failures += refuses(
    lambda: policy.load_coordinator_authority(encoded(), status(mode=0o100446)),
    "writable", "a world-writable authority refuses")
failures += refuses(
    lambda: policy.load_coordinator_authority(encoded(), status(mode=0o040755)),
    "regular file", "a directory refuses")
failures += refuses(
    lambda: policy.load_coordinator_authority(encoded(), status(mode=0o120777)),
    "regular file", "a symlink refuses")

# Root may keep it 0400 or 0444; both are non-writable by anyone but root.
for mode in (0o100400, 0o100440, 0o100444):
    try:
        policy.load_coordinator_authority(encoded(), status(mode=mode))
        check(True, f"mode {mode & 0o777:04o} is accepted")
    except Refused as error:
        check(False, f"mode {mode & 0o777:04o} is accepted ({error})")

print("\n== no environment fallback exists ==\n")

for variable in ("KYRI_COORDINATOR_UID", "COORDINATOR_UID", "KYRI_COORDINATOR"):
    check(variable not in source and variable not in action_source,
          f"no {variable} escape hatch in the helper")
check("os.environ" not in source,
      "the policy module never reads the environment")

print("\n== 8. sudoers derivation cannot disagree with the helper ==\n")

# The grant is written in names and the boundary checks numbers. The one place
# that could drift is a principal derived from something other than the record
# the helper reads, so derivation takes the authority object itself.
principal = policy.sudoers_principal(authority)
check(principal == "cschott",
      f"the sudoers principal is derived from the authority ({principal})")
failures += refuses(
    lambda: policy.sudoers_principal({"coordinator_account": "cschott"}),
    "authority", "a look-alike mapping cannot stand in for the checked authority")

print(f"\n{failures} assertion(s) failed." if failures
      else "\nAll G11-AH coordinator authority assertions passed.")
sys.exit(1 if failures else 0)
PY
STATUS=$?

printf '\n'
AFTER="$(ls -ldn "${PRODUCTION_ETC}" 2>/dev/null || printf 'absent')"
if [[ "${BEFORE}" != "${AFTER}" ]]; then
  printf 'FAIL: %s changed while this suite ran\n' "${PRODUCTION_ETC}" >&2
  STATUS=1
else
  printf 'PASS: %s is unchanged\n' "${PRODUCTION_ETC}"
fi

exit "${STATUS}"
