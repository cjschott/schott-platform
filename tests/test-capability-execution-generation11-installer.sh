#!/usr/bin/env bash
set -Eeuo pipefail

# Empirical failure-injection tests for the Generation-11 installation ceremony.
#
# WHAT IS DIFFERENT FROM GENERATION 10. Generation 10 was four REPLACE
# operations at an unchanged object count. Generation 11 is NINE CREATE
# operations, 48 -> 57, and every interesting property follows from that:
#
#   * there is no predecessor byte to retain, so rollback is REMOVAL, and this
#     suite proves removal is fenced -- unknown bytes at a target are left
#     exactly as found rather than deleted;
#   * a new package DIRECTORY is created, so this suite proves it is removed on
#     rollback only when this transaction made it and nothing else moved in;
#   * the delta is not a source diff. The nine files are unchanged between the
#     Generation-10 and Generation-11 authorities; what changed is that the
#     installed runtime now needs them. So the ceremony recomputes the import
#     closure from the reviewed commit, and this suite proves that gate refuses
#     both a matrix that is too narrow and a matrix that is too wide.
#
# THE LAST ONE IS THE LOAD-BEARING CASE. Generation 10 proved its matrix closed
# with `git diff --name-only GEN9 GEN10 -- 'tools/*.py'`. Carried forward
# verbatim that gate would be wrong in BOTH directions: the source diff between
# the two authorities is 18 files, it MISSES seven of the nine the closure
# requires, and it INCLUDES admission.py, cli.py, selection.py, eligibility.py
# and the whole of tools/trust -- precisely the mutation and control-plane
# surfaces Generation 11 must not install. This suite asserts that too, so the
# reason the gate was re-derived cannot be lost.
#
# FIXTURE ONLY. Every case builds a throwaway Generation-10 host under a
# temporary root and runs the ceremony with --fixture against it. Nothing here
# touches /usr/lib/kyri/python, /usr/libexec, /etc/sudoers.d, the governance
# stores, or the authority namespace, and the production paths are snapshotted
# before and after to prove it.
#
# WHAT IT MUST NOT DO. This suite installs nothing outside its fixtures, writes
# no sudoers policy, invokes no privileged helper, allocates no identifier,
# creates no governance store, and contacts no container runtime.
#
# Governed by:
#   docs/development/reports/eng-0005/2026-08-26-g11-b-runtime-dependency-closure.md
#   docs/development/reports/eng-0005/2026-08-26-g11-d-transactional-installer.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "${SCRIPT_DIR}/.." && pwd)"
CEREMONY="${REPOSITORY}/provisioning/execution/install-generation-11.sh"
SURFACE="${REPOSITORY}/provisioning/execution/generation-11-surface.sh"
[[ -f "${CEREMONY}" ]] || { printf 'ceremony missing: %s\n' "${CEREMONY}" >&2; exit 1; }
[[ -f "${SURFACE}" ]] || { printf 'surface declaration missing: %s\n' "${SURFACE}" >&2; exit 1; }
PINNED_REPOSITORY="$(sed -n 's/^REPOSITORY="\(.*\)"$/\1/p' "${CEREMONY}" | head -1)"
[[ "${PINNED_REPOSITORY}" == "${REPOSITORY}" ]] || {
  printf 'this checkout is %s but the ceremony pins %s\n' "${REPOSITORY}" "${PINNED_REPOSITORY}" >&2
  exit 1
}

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" >/dev/null 2>&1 || true; rm -rf "${WORK}"' EXIT

PRODUCTION_PATHS=(
  /usr/lib/kyri/python
  /usr/lib/kyri/python/tools/fabric
  /usr/libexec/kyri-exec-transition
  /usr/libexec/kyri-exec-worker.py
  /usr/libexec/kyri-exec-quota
  /usr/libexec/kyri-exec-verify
  /usr/libexec/kyri-exec-verify-worker.py
  /etc/sudoers.d/kyri-exec
  /etc/sudoers.d/kyri-exec-verify
  /var/lib/kyri
  /run/kyri
  /data/kyri
  /mnt/kyri-root
)
snapshot_production() {
  python3 - "$@" <<'SNAPPY'
import hashlib, json, os, sys
state = {}
for path in sys.argv[1:]:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        state[path] = None
        continue
    except OSError:
        state[path] = "unreadable"
        continue
    entry = [info.st_mode, info.st_uid, info.st_gid, info.st_mtime_ns]
    if os.path.isdir(path) and not os.path.islink(path):
        manifest = hashlib.sha256()
        try:
            for base, directories, files in os.walk(path):
                directories.sort()
                for name in sorted(files):
                    full = os.path.join(base, name)
                    manifest.update(full.encode("utf-8"))
                    try:
                        with open(full, "rb") as handle:
                            manifest.update(hashlib.sha256(handle.read()).digest())
                    except OSError:
                        manifest.update(b"unreadable")
        except OSError:
            manifest.update(b"unwalkable")
        entry.append(manifest.hexdigest())
    state[path] = entry
print(json.dumps(state, sort_keys=True))
SNAPPY
}
PRODUCTION_BEFORE="$(snapshot_production "${PRODUCTION_PATHS[@]}")"

# ===========================================================================
# Everything pinned, read from the ceremony so the two can never disagree
# ===========================================================================
mapfile -t RAW_ROWS < <(sed -n '/^MATRIX=(/,/^)/p' "${CEREMONY}" | grep '^"' | tr -d '"')
[[ "${#RAW_ROWS[@]}" -eq 9 ]] || {
  printf 'expected exactly 9 matrix rows, found %s\n' "${#RAW_ROWS[@]}" >&2; exit 1; }
ROWS=()
for raw in "${RAW_ROWS[@]}"; do ROWS+=("${raw//\$\{LIBRARY_ROOT\}/%LIB%}"); done

read_pin() { sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "${CEREMONY}" | head -1; }
read_number() { sed -n "s/^$1=\\([0-9]*\\)\$/\\1/p" "${CEREMONY}" | head -1; }
COMMIT="$(read_pin COMMIT)"
GEN10_COMMIT="$(read_pin GEN10_COMMIT)"
SUDOERS_ABS="$(read_pin SUDOERS)"
VERIFY_SUDOERS_ABS="$(read_pin VERIFY_SUDOERS)"
PREPARED_SUFFIX="$(read_pin PREPARED_SUFFIX)"
BACKUP_SUFFIX="$(read_pin BACKUP_SUFFIX)"
EXPECTED_GEN10="$(read_number EXPECTED_LIBRARY_FILES_GEN10)"
EXPECTED_GEN11="$(read_number EXPECTED_LIBRARY_FILES_GEN11)"
for name in COMMIT GEN10_COMMIT; do
  [[ "${!name}" =~ ^[0-9a-f]{40}$ ]] || {
    printf 'no full 40-character %s available\n' "${name}" >&2; exit 1; }
done
# Nine CREATEs move the count by nine. If these ever stop differing by nine, the
# matrix grew or shrank without the counts being revisited.
[[ "${EXPECTED_GEN10}" == "48" && "${EXPECTED_GEN11}" == "57" ]] || {
  printf 'unexpected library counts: gen10=%s gen11=%s\n' "${EXPECTED_GEN10}" "${EXPECTED_GEN11}" >&2
  exit 1; }

field() { IFS='|' read -r -a _f <<<"$1"; printf '%s' "${_f[$2]}"; }
digest_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
bind_target() { local root="$1" t="$2"; printf '%s' "${t//%LIB%/${root}/usr/lib/kyri/python}"; }
materialise() {
  local commit="$1" source="$2" destination="$3"
  rm -f "${destination}"
  git -C "${REPOSITORY}" cat-file blob "${commit}:${source}" > "${destination}"
}

row_source() { field "${ROWS[$1]}" 0; }
row_gen10()  { field "${ROWS[$1]}" 4; }
row_gen11()  { field "${ROWS[$1]}" 5; }
row_target() { bind_target "$2" "$(field "${ROWS[$1]}" 1)"; }
row_at()     { digest_of "$(row_target "$1" "$2")"; }
INDICES=(0 1 2 3 4 5 6 7 8)
PACKAGE_REL="usr/lib/kyri/python/tools/fabric"

# The exact state of all nine targets, as a compact string: "-" absent (the
# Generation-10 state of a CREATE target), "11" published, "?" neither.
target_states() {
  local root="$1" i out="" d target
  for i in "${INDICES[@]}"; do
    target="$(row_target "${i}" "${root}")"
    d="$(row_at "${i}" "${root}")"
    if   [[ "${d}" == "$(row_gen11 "${i}")" ]]; then out+="11 "
    elif [[ ! -e "${target}" && ! -L "${target}" ]]; then out+="- "
    else out+="? "; fi
  done
  printf '%s' "${out% }"
}
ALL_ABSENT="- - - - - - - - -"
ALL_PRESENT="11 11 11 11 11 11 11 11 11"

# ===========================================================================
# A fixture Generation-10 host
# ===========================================================================
build_fixture() {
  local root="$1" file flattened
  [[ -d "${root}" ]] && chmod -R u+w "${root}" >/dev/null 2>&1
  mkdir -p "${root}/usr/lib/kyri/python/tools/capability/execution" \
           "${root}/usr/lib/kyri/python/tools/common" \
           "${root}/usr/libexec" "${root}/root" "${root}/etc/sudoers.d" \
           "${root}/var/lib/kyri"

  while IFS= read -r file; do
    mkdir -p "${root}/usr/lib/kyri/python/$(dirname "${file}")"
    materialise "${GEN10_COMMIT}" "${file}" "${root}/usr/lib/kyri/python/${file}"
    chmod 0444 "${root}/usr/lib/kyri/python/${file}"
  done < <(git -C "${REPOSITORY}" ls-tree -r --name-only "${GEN10_COMMIT}" \
             -- tools/__init__.py tools/capability tools/common \
           | grep '\.py$' | grep -v '__pycache__' | sort)

  for flattened in kyri-exec-quota:kyri_exec_quota.py \
                   kyri-exec-transition:kyri_exec_transition.py \
                   kyri-exec-transition-action:kyri_exec_transition_action.py \
                   kyri-exec-verify:kyri_exec_verify.py; do
    materialise "${GEN10_COMMIT}" "provisioning/execution/${flattened%%:*}.py" \
      "${root}/usr/lib/kyri/python/${flattened##*:}"
    chmod 0444 "${root}/usr/lib/kyri/python/${flattened##*:}"
  done

  ( cd "${root}/usr/lib/kyri/python" \
    && find . -type f -name '*.py' -print0 | sort -z | xargs -0 sha256sum ) \
    | sed 's#  \./#  /usr/lib/kyri/python/#' \
    > "${root}/root/kyri-gen10-library-digests.txt"
  {
    printf 'commit %s\n' "${GEN10_COMMIT}"
    printf 'predecessor generation 9\n'
    printf 'transaction gen10-fixture\n'
    printf 'state COMMITTED\n'
  } > "${root}/root/kyri-gen10-helper-digests.txt"
}

run_ceremony() {
  local root="$1" failat="$2"; shift 2
  local status=0
  if [[ -n "${failat}" ]]; then
    ( cd "${REPOSITORY}" && KYRI_GEN11_FAIL_AT="${failat}" \
        bash "${CEREMONY}" --fixture "${root}" "$@" ) > "${root}/last-run.log" 2>&1 || status=$?
  else
    ( cd "${REPOSITORY}" && bash "${CEREMONY}" --fixture "${root}" "$@" ) \
      > "${root}/last-run.log" 2>&1 || status=$?
  fi
  return "${status}"
}

# The same, against a mutated copy of the ceremony. Used for the cases that can
# only be reached by declaring something the reviewed ceremony does not: a matrix
# that is too wide, too narrow, or pinned to bytes the reviewed commit does not
# carry. The copy still pins the real repository, so only the matrix varies.
run_variant() {
  local variant="$1" root="$2"; shift 2
  local status=0
  ( cd "${REPOSITORY}" && bash "${variant}" --fixture "${root}" "$@" ) \
    > "${root}/last-run.log" 2>&1 || status=$?
  return "${status}"
}

library_count() { find "$1/usr/lib/kyri/python" -type f -name '*.py' | wc -l; }

# The installed surface with the Fabric package excluded, so "nothing else
# moved" is a statement about the 48 Generation-10 objects.
surface_digest() {
  local root="$1"
  ( cd "${root}/usr/lib/kyri/python" \
    && find . -type f -name '*.py' -not -path './tools/fabric/*' -print0 \
       | sort -z | xargs -0 sha256sum ) | sha256sum | cut -d' ' -f1
}

residue_count() {
  local root="$1" n=0 suffix i
  for i in "${INDICES[@]}"; do
    for suffix in "${PREPARED_SUFFIX}" "${BACKUP_SUFFIX}"; do
      [[ -e "$(row_target "${i}" "${root}")${suffix}" ]] && n=$((n + 1))
    done
  done
  printf '%s' "${n}"
}

JOURNAL_REL="root/kyri-gen11-transaction/journal"

# Build a genuine interrupted transaction: the package directory created, all
# nine staged, the first `published` targets already renamed into place, and a
# durable journal at COMMITTING. Constructed rather than simulated, so recovery
# is tested against the real on-disk shape.
stage_interrupted() {
  local root="$1" published="$2" i target
  build_fixture "${root}"
  mkdir -p "${root}/${PACKAGE_REL}"
  chmod 0755 "${root}/${PACKAGE_REL}"
  for i in "${INDICES[@]}"; do
    target="$(row_target "${i}" "${root}")"
    materialise "${COMMIT}" "$(row_source "${i}")" "${target}${PREPARED_SUFFIX}"
    chmod 0444 "${target}${PREPARED_SUFFIX}"
    if (( i < published )); then
      cp -p "${target}${PREPARED_SUFFIX}" "${target}.publishing"
      mv -f "${target}.publishing" "${target}"
      rm -f "${target}${PREPARED_SUFFIX}"
    fi
  done
  mkdir -p "${root}/root/kyri-gen11-transaction"
  {
    printf 'transaction=gen11-interrupted\n'
    printf 'commit=%s\n' "${COMMIT}"
    printf 'baseline_commit=%s\n' "${GEN10_COMMIT}"
    printf 'state=COMMITTING\n'
    printf 'package_dir_created=yes\n'
  } > "${root}/${JOURNAL_REL}"
}

# ===========================================================================
# 1. the matrix is exactly the reviewed dependency closure
# ===========================================================================
# Re-derived here independently of the ceremony, from the reviewed commit's own
# blobs, so the suite is not merely restating what the ceremony computes.
closure_report="$(
  staging="$(mktemp -d)"
  git -C "${REPOSITORY}" archive --format=tar "${COMMIT}" tools | tar -x -C "${staging}"
  python3 - "${staging}" <<'PY'
import ast, os, sys
root = sys.argv[1]

def module_path(module):
    candidate = os.path.join(root, module.replace(".", "/") + ".py")
    if os.path.isfile(candidate):
        return candidate
    package = os.path.join(root, module.replace(".", "/"), "__init__.py")
    return package if os.path.isfile(package) else None

def imported_by(module, path):
    package = module if path.endswith("__init__.py") else module.rsplit(".", 1)[0]
    names = set()
    for node in ast.walk(ast.parse(open(path, encoding="utf-8").read())):
        if isinstance(node, ast.Import):
            names.update(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            if node.level:
                parts = package.split(".")
                if node.level > 1:
                    parts = parts[: len(parts) - (node.level - 1)]
                target = ".".join(parts) + ("." + node.module if node.module else "")
            else:
                target = node.module or ""
            names.add(target)
            names.update(target + "." + alias.name for alias in node.names)
    return names

seen, pending = set(), ["tools.fabric.inspection"]
while pending:
    module = pending.pop()
    if module in seen:
        continue
    path = module_path(module)
    if path is None:
        continue
    seen.add(module)
    for name in imported_by(module, path):
        if name.startswith("tools.") and module_path(name):
            pending.append(name)
for module in list(seen):
    parts = module.split(".")
    for depth in range(1, len(parts)):
        parent = ".".join(parts[:depth])
        if module_path(parent):
            seen.add(parent)
for relative in sorted(os.path.relpath(module_path(m), root) for m in seen):
    print(relative)
PY
  rm -rf "${staging}"
)"
declared_sources="$(for i in "${INDICES[@]}"; do printf '%s\n' "$(row_source "${i}")"; done | sort)"
already_installed="$(printf '%s\n' tools/__init__.py tools/common/__init__.py tools/common/immutable_store.py | sort)"
expected_sources="$(comm -23 <(printf '%s\n' "${closure_report}" | sort) <(printf '%s\n' "${already_installed}"))"

if [[ "${declared_sources}" == "${expected_sources}" ]]; then
  pass "the matrix is exactly the reviewed import closure minus what Generation 10 already installs"
else
  fail "the matrix is not the closure: declared=[${declared_sources//$'\n'/,}] expected=[${expected_sources//$'\n'/,}]"
fi

if [[ "$(printf '%s\n' "${closure_report}" | wc -l)" -eq 12 ]]; then
  pass "the closure of tools.fabric.inspection is 12 modules, of which 9 are not yet installed"
else
  fail "the closure is $(printf '%s\n' "${closure_report}" | wc -l) modules, expected 12"
fi

# The excluded surfaces, proven absent from the closure rather than merely
# omitted from the matrix.
excluded_problems=""
for excluded in tools/fabric/admission.py tools/fabric/cli.py tools/fabric/selection.py \
                tools/fabric/eligibility.py tools/fabric/trust_adapter.py; do
  grep -qx "${excluded}" <<<"${closure_report}" && excluded_problems+=" in-closure:${excluded}"
  grep -qx "${excluded}" <<<"${declared_sources}" && excluded_problems+=" in-matrix:${excluded}"
done
if grep -q '^tools/trust/' <<<"${closure_report}"; then
  excluded_problems+=" trust-plane-in-closure"
fi
if [[ -z "${excluded_problems}" ]]; then
  pass "admission, cli, selection, eligibility, trust_adapter and the whole Trust plane are outside the closure and outside the matrix"
else
  fail "an excluded surface reached the closure or the matrix:${excluded_problems}"
fi

replace_n=0; create_n=0
for i in "${INDICES[@]}"; do
  case "$(field "${ROWS[$i]}" 3)" in
    REPLACE) replace_n=$((replace_n + 1)) ;;
    CREATE)  create_n=$((create_n + 1)) ;;
  esac
done
if [[ "${create_n}" -eq 9 && "${replace_n}" -eq 0 ]]; then
  pass "the matrix is nine CREATE operations and no REPLACE"
else
  fail "the matrix is ${create_n} CREATE and ${replace_n} REPLACE, expected 9 and 0"
fi

digest_problems=""
for i in "${INDICES[@]}"; do
  source="$(row_source "${i}")"
  actual="$(git -C "${REPOSITORY}" cat-file blob "${COMMIT}:${source}" | sha256sum | cut -d' ' -f1)"
  [[ "$(row_gen11 "${i}")" == "${actual}" ]] || digest_problems+=" ${source}:gen11"
  [[ "$(row_gen10 "${i}")" == "ABSENT" ]] || digest_problems+=" ${source}:predecessor-not-absent"
done
if [[ -z "${digest_problems}" ]]; then
  pass "every declared result digest is the reviewed commit object, and every predecessor is ABSENT"
else
  fail "declared digests disagree with the commit objects:${digest_problems}"
fi

# The ceremony's pinned digests and the reviewed surface declaration must agree.
surface_problems=""
for i in "${INDICES[@]}"; do
  grep -qF "$(row_source "${i}")|" "${SURFACE}" || surface_problems+=" not-declared:$(row_source "${i}")"
  grep -qF "$(row_gen11 "${i}")" "${SURFACE}" || surface_problems+=" digest-differs:$(row_source "${i}")"
done
if [[ -z "${surface_problems}" ]]; then
  pass "every ceremony row matches the reviewed generation-11-surface declaration"
else
  fail "the ceremony and the reviewed surface declaration disagree:${surface_problems}"
fi

# WHY THE GATE WAS RE-DERIVED. Asserted, so the reason cannot be lost.
diff_delta="$(git -C "${REPOSITORY}" diff --name-only "${GEN10_COMMIT}" "${COMMIT}" -- 'tools/*.py' | sort)"
if [[ "${diff_delta}" == "${declared_sources}" ]]; then
  fail "the source diff equals the closure, so this ceremony did not need to re-derive its delta gate"
else
  missed=0; overreached=0
  while IFS= read -r wanted; do
    [[ -n "${wanted}" ]] || continue
    grep -qx "${wanted}" <<<"${diff_delta}" || missed=$((missed + 1))
  done <<<"${declared_sources}"
  while IFS= read -r offered; do
    [[ -n "${offered}" ]] || continue
    grep -qx "${offered}" <<<"${declared_sources}" || overreached=$((overreached + 1))
  done <<<"${diff_delta}"
  if (( missed > 0 && overreached > 0 )) \
     && grep -q '^tools/fabric/admission\.py$' <<<"${diff_delta}" \
     && grep -q '^tools/trust/' <<<"${diff_delta}"; then
    pass "the Generation-10 source-diff gate would miss ${missed} required objects and admit ${overreached} it must not, including admission.py and the Trust plane"
  else
    fail "the source-diff gate comparison did not demonstrate the expected divergence (missed=${missed} overreached=${overreached})"
  fi
fi

if git -C "${REPOSITORY}" merge-base --is-ancestor "${GEN10_COMMIT}" "${COMMIT}"; then
  pass "the Generation-10 authority is an ancestor of the Generation-11 authority"
else
  fail "the pinned authorities are not in ancestry order"
fi

# ===========================================================================
# 2. --verify on a clean generation-10 host
# ===========================================================================
clean="${WORK}/clean"; build_fixture "${clean}"
if [[ "$(library_count "${clean}")" -eq "${EXPECTED_GEN10}" ]]; then
  pass "the fixture is a generation-10 host: ${EXPECTED_GEN10} library objects"
else
  fail "the fixture holds $(library_count "${clean}") objects, expected ${EXPECTED_GEN10}"
fi

if [[ ! -e "${clean}/${PACKAGE_REL}" ]]; then
  pass "the fixture has no installed Fabric package, exactly as production does not"
else
  fail "the fixture already carries an installed Fabric package"
fi

if [[ "$(target_states "${clean}")" == "${ALL_ABSENT}" ]]; then
  pass "the fixture starts with all nine target pathnames free"
else
  fail "the fixture target states are [$(target_states "${clean}")]"
fi

if run_ceremony "${clean}" "" --verify; then
  pass "--verify accepts a host at the accepted generation-10 baseline"
else
  fail "--verify rejected a valid generation-10 host: $(tail -14 "${clean}/last-run.log")"
fi

before_verify="$(snapshot_production "${clean}")"
run_ceremony "${clean}" "" --verify || true
if [[ "${before_verify}" == "$(snapshot_production "${clean}")" && "$(residue_count "${clean}")" == "0" ]]; then
  pass "--verify mutates nothing and creates no transaction material"
else
  fail "--verify changed the fixture or left transaction material"
fi

# Repeated verification is stable: a gate that drifted between two consecutive
# reads would make every other proof in this suite conditional.
run_ceremony "${clean}" "" --verify > /dev/null 2>&1 || true
third="$(snapshot_production "${clean}")"
if [[ "${third}" == "${before_verify}" ]]; then
  pass "a third --verify is byte-identical to the first: verification is idempotent"
else
  fail "repeated verification is not stable"
fi

# ===========================================================================
# 3. preflight refusals against the generation-10 baseline
# ===========================================================================
drift="${WORK}/drift"; build_fixture "${drift}"
chmod u+w "${drift}/usr/lib/kyri/python/tools/capability/store.py"
printf '\n# drift\n' >> "${drift}/usr/lib/kyri/python/tools/capability/store.py"
if run_ceremony "${drift}" "" --verify; then
  fail "--verify accepted a host whose generation-10 baseline had drifted"
else
  pass "unrelated generation-10 runtime drift refuses the transaction"
fi

missing="${WORK}/missingobject"; build_fixture "${missing}"
chmod u+w "${missing}/usr/lib/kyri/python/tools/capability"
rm -f "${missing}/usr/lib/kyri/python/tools/capability/store.py"
if run_ceremony "${missing}" "" --verify; then
  fail "--verify accepted a host missing a runtime object"
else
  pass "a runtime object the evidence records but the host lacks refuses"
fi

extra="${WORK}/extraobject"; build_fixture "${extra}"
printf '# unexpected\n' > "${extra}/usr/lib/kyri/python/tools/capability/intruder.py"
chmod 0444 "${extra}/usr/lib/kyri/python/tools/capability/intruder.py"
if run_ceremony "${extra}" "" --verify; then
  fail "--verify accepted a host carrying an unexpected runtime object"
else
  pass "an unexpected runtime object refuses"
fi

noevidence="${WORK}/noevidence"; build_fixture "${noevidence}"
rm -f "${noevidence}/root/kyri-gen10-library-digests.txt"
if run_ceremony "${noevidence}" "" --verify; then
  fail "--verify accepted a host with no generation-10 evidence"
else
  pass "missing generation-10 evidence refuses the transaction"
fi

for grant in "${SUDOERS_ABS}" "${VERIFY_SUDOERS_ABS}"; do
  guarded="${WORK}/grant$(basename "${grant}")"; build_fixture "${guarded}"
  mkdir -p "${guarded}$(dirname "${grant}")"
  printf 'cschott ALL=(root) NOPASSWD: /bin/false\n' > "${guarded}${grant}"
  if run_ceremony "${guarded}" "" --verify; then
    fail "--verify ran while ${grant} existed"
  else
    pass "an existing ${grant} refuses the transaction"
  fi
done

residue="${WORK}/residue"; build_fixture "${residue}"
mkdir -p "${residue}/${PACKAGE_REL}"
touch "$(row_target 2 "${residue}")${PREPARED_SUFFIX}"
if run_ceremony "${residue}" "" --verify; then
  fail "--verify accepted a host carrying transaction residue"
else
  pass "pre-existing transaction residue refuses"
fi

# ===========================================================================
# 4. the target pathnames must be genuinely free -- including of symlinks
# ===========================================================================
for i in 0 4 8; do
  occupied="${WORK}/occupied${i}"; build_fixture "${occupied}"
  mkdir -p "${occupied}/${PACKAGE_REL}"
  printf '# squatter\n' > "$(row_target "${i}" "${occupied}")"
  chmod 0444 "$(row_target "${i}" "${occupied}")"
  if run_ceremony "${occupied}" "" --verify; then
    fail "--verify accepted an occupied target pathname $(basename "$(row_source "${i}")")"
  else
    pass "an occupied $(basename "$(row_source "${i}")") pathname refuses: this transaction creates, it does not overwrite"
  fi
done

# A symlink at a target, pointed at the correct reviewed bytes. The digest
# behind it is right; publishing through it would still write somewhere nobody
# declared, and removing it on rollback would remove somebody else's link.
symlinked="${WORK}/symlinktarget"; build_fixture "${symlinked}"
mkdir -p "${symlinked}/${PACKAGE_REL}"
materialise "${COMMIT}" "$(row_source 8)" "${symlinked}/root/decoy.py"
ln -s "${symlinked}/root/decoy.py" "$(row_target 8 "${symlinked}")"
if run_ceremony "${symlinked}" "" --verify; then
  fail "--verify accepted a symlink standing in for a target"
else
  if [[ -L "$(row_target 8 "${symlinked}")" ]]; then
    pass "a symlink substituted for a target refuses, and is left in place for disposition"
  else
    fail "the ceremony removed a symlink it should have refused"
  fi
fi

# A symlinked package directory: the whole installation redirected in one step.
symdir="${WORK}/symlinkdir"; build_fixture "${symdir}"
mkdir -p "${symdir}/root/elsewhere"
ln -s "${symdir}/root/elsewhere" "${symdir}/${PACKAGE_REL}"
if run_ceremony "${symdir}" "" --verify; then
  fail "--verify accepted a symlinked Fabric package directory"
else
  pass "a symlinked Fabric package directory refuses: no installation through a redirect"
fi

# A foreign module already sitting in the package directory.
foreign="${WORK}/foreignmodule"; build_fixture "${foreign}"
mkdir -p "${foreign}/${PACKAGE_REL}"
materialise "${COMMIT}" tools/fabric/admission.py "${foreign}/${PACKAGE_REL}/admission.py"
chmod 0444 "${foreign}/${PACKAGE_REL}/admission.py"
if run_ceremony "${foreign}" "" --verify; then
  fail "--verify accepted an undeclared module in the Fabric package directory"
else
  if grep -q 'foreign object' "${foreign}/last-run.log"; then
    pass "an undeclared module in the Fabric package directory refuses by name"
  else
    fail "the foreign module refused for the wrong reason: $(tail -6 "${foreign}/last-run.log")"
  fi
fi

# ===========================================================================
# 5. source-side refusals: the reviewed matrix cannot be widened or drifted
# ===========================================================================
# These are reachable only by declaring something the reviewed ceremony does
# not, so each runs against a mutated copy. The copy still pins the real
# repository and the real reviewed commit: only the matrix varies.

# 5a. an unreviewed Fabric module added to the closure -- the case the brief
#     names explicitly, and the one the closure gate exists for.
widened="${WORK}/widened"; build_fixture "${widened}"
widened_ceremony="${WORK}/install-widened.sh"
admission_digest="$(git -C "${REPOSITORY}" cat-file blob "${COMMIT}:tools/fabric/admission.py" | sha256sum | cut -d' ' -f1)"
sed "s#^\"tools/fabric/inspection.py|#\"tools/fabric/admission.py|\${LIBRARY_ROOT}/tools/fabric/admission.py|0444|CREATE|ABSENT|${admission_digest}\"\n\"tools/fabric/inspection.py|#" \
  "${CEREMONY}" > "${widened_ceremony}"
if run_variant "${widened_ceremony}" "${widened}" --verify; then
  fail "the closure gate accepted admission.py entering the installation surface"
else
  if grep -qE 'EXCLUDED module tools/fabric/admission\.py appears in the matrix|closure does not require' \
       "${widened}/last-run.log"; then
    pass "an unreviewed Fabric module entering the closure refuses, naming the module"
  else
    fail "the widened matrix refused for the wrong reason: $(tail -8 "${widened}/last-run.log")"
  fi
fi

# 5b. the same, for a module that is not on the excluded list either -- so the
#     refusal is the closure computation, not the excluded-list lookup.
unrelated="${WORK}/unrelated"; build_fixture "${unrelated}"
unrelated_ceremony="${WORK}/install-unrelated.sh"
resources_digest="$(git -C "${REPOSITORY}" cat-file blob "${COMMIT}:tools/fabric/resources.py" | sha256sum | cut -d' ' -f1)"
sed "s#^\"tools/fabric/inspection.py|#\"tools/fabric/resources.py|\${LIBRARY_ROOT}/tools/fabric/resources.py|0444|CREATE|ABSENT|${resources_digest}\"\n\"tools/fabric/inspection.py|#" \
  "${CEREMONY}" > "${unrelated_ceremony}"
if run_variant "${unrelated_ceremony}" "${unrelated}" --verify; then
  fail "the closure gate accepted an unrelated module the closure does not require"
else
  if grep -q 'tools/fabric/resources.py, which the closure does not require' "${unrelated}/last-run.log"; then
    pass "a module the closure does not require refuses even when it is not on the excluded list"
  else
    fail "the unrelated module refused for the wrong reason: $(tail -8 "${unrelated}/last-run.log")"
  fi
fi

# 5c. a matrix that is too NARROW: a module the closure requires, dropped.
narrowed="${WORK}/narrowed"; build_fixture "${narrowed}"
narrowed_ceremony="${WORK}/install-narrowed.sh"
grep -v '^"tools/fabric/validator.py|' "${CEREMONY}" > "${narrowed_ceremony}"
if run_variant "${narrowed_ceremony}" "${narrowed}" --verify; then
  fail "the closure gate accepted a matrix missing a required module"
else
  if grep -q 'the closure requires tools/fabric/validator.py' "${narrowed}/last-run.log"; then
    pass "a matrix missing a module the closure requires refuses, naming the module"
  else
    fail "the narrowed matrix refused for the wrong reason: $(tail -8 "${narrowed}/last-run.log")"
  fi
fi

# 5d. changed source bytes: a pinned digest that the reviewed commit does not carry.
drifted="${WORK}/drifted"; build_fixture "${drifted}"
drifted_ceremony="${WORK}/install-drifted.sh"
sed "s#|$(row_gen11 3)\"#|$(printf '%064d' 0)\"#" "${CEREMONY}" > "${drifted_ceremony}"
if run_variant "${drifted_ceremony}" "${drifted}" --verify; then
  fail "--verify accepted a pinned digest the reviewed commit does not carry"
else
  if grep -q 'expected 0000' "${drifted}/last-run.log"; then
    pass "a pinned digest that is not the reviewed commit object refuses"
  else
    fail "the drifted digest refused for the wrong reason: $(tail -8 "${drifted}/last-run.log")"
  fi
fi

# 5e. a missing source object: a row naming a path the reviewed commit lacks.
absent="${WORK}/absentsource"; build_fixture "${absent}"
absent_ceremony="${WORK}/install-absent.sh"
sed 's#^"tools/fabric/errors.py|#"tools/fabric/nonexistent.py|#' "${CEREMONY}" > "${absent_ceremony}"
if run_variant "${absent_ceremony}" "${absent}" --verify; then
  fail "--verify accepted a matrix row whose source is absent from the reviewed commit"
else
  if grep -q 'tools/fabric/nonexistent.py is not present at the reviewed commit' \
       "${absent}/last-run.log"; then
    pass "a matrix row whose source the reviewed commit does not carry refuses"
  else
    fail "the absent source refused for the wrong reason: $(tail -8 "${absent}/last-run.log")"
  fi
fi

# ===========================================================================
# 6. a clean installation
# ===========================================================================
happy="${WORK}/happy"; build_fixture "${happy}"
surface_before="$(surface_digest "${happy}")"
if run_ceremony "${happy}" "" --install; then
  pass "--install completes on a clean generation-10 host"
else
  fail "--install failed on a clean host: $(tail -24 "${happy}/last-run.log")"
fi

if [[ "$(target_states "${happy}")" == "${ALL_PRESENT}" ]]; then
  pass "all nine CREATE operations published the exact generation-11 bytes"
else
  fail "target states after install are [$(target_states "${happy}")]"
fi
if [[ "$(surface_digest "${happy}")" == "${surface_before}" ]]; then
  pass "not one Generation-10 runtime object changed"
else
  fail "the installed Generation-10 surface changed"
fi
if [[ "$(library_count "${happy}")" -eq "${EXPECTED_GEN11}" ]]; then
  pass "nine CREATEs moved the object count ${EXPECTED_GEN10} -> ${EXPECTED_GEN11}"
else
  fail "the library holds $(library_count "${happy}") objects, expected ${EXPECTED_GEN11}"
fi
mode_problems=""
for i in "${INDICES[@]}"; do
  [[ "$(stat -c '%a' "$(row_target "${i}" "${happy}")")" == "444" ]] \
    || mode_problems+=" $(basename "$(row_source "${i}")")=$(stat -c '%a' "$(row_target "${i}" "${happy}")")"
done
[[ "$(stat -c '%a' "${happy}/${PACKAGE_REL}")" == "755" ]] \
  || mode_problems+=" package-dir=$(stat -c '%a' "${happy}/${PACKAGE_REL}")"
if [[ -z "${mode_problems}" ]]; then
  pass "all nine targets are published 0444 and the package directory is 0755"
else
  fail "published modes are wrong:${mode_problems}"
fi

# The installed closure must be exactly nine files. Not eight, not ten.
installed_fabric="$(find "${happy}/${PACKAGE_REL}" -type f | wc -l)"
if [[ "${installed_fabric}" -eq 9 ]]; then
  pass "the installed Fabric package is exactly the nine-file closure"
else
  fail "the installed Fabric package holds ${installed_fabric} files, expected 9"
fi

excluded_installed=""
for excluded in admission.py cli.py eligibility.py selection.py trust_adapter.py \
                evidence_authority.py resources.py; do
  [[ -e "${happy}/${PACKAGE_REL}/${excluded}" ]] && excluded_installed+=" ${excluded}"
done
[[ -e "${happy}/usr/lib/kyri/python/tools/trust" ]] && excluded_installed+=" tools/trust"
if [[ -z "${excluded_installed}" ]]; then
  pass "the governed write path, the operator input surface and the Trust plane are absent from the installed runtime"
else
  fail "an excluded surface was installed:${excluded_installed}"
fi

if [[ -f "${happy}/root/kyri-gen11-library-digests.txt" \
   && -f "${happy}/root/kyri-gen11-helper-digests.txt" \
   && -f "${happy}/root/kyri-gen10-library-digests.txt" \
   && -f "${happy}/root/kyri-gen10-helper-digests.txt" ]]; then
  pass "generation-11 evidence was written and generation-10 evidence preserved"
else
  fail "generation-11 evidence is missing or generation-10 evidence was consumed"
fi

gen10_evidence_before="$(digest_of "${clean}/root/kyri-gen10-library-digests.txt")"
if [[ "$(digest_of "${happy}/root/kyri-gen10-library-digests.txt")" == "${gen10_evidence_before}" ]]; then
  pass "the generation-10 evidence is byte-identical after installation"
else
  fail "the generation-10 evidence changed during installation"
fi

evidence_problems=""
for i in "${INDICES[@]}"; do
  grep -q "$(row_gen11 "${i}")" "${happy}/root/kyri-gen11-library-digests.txt" \
    || evidence_problems+=" missing-digest-$(basename "$(row_source "${i}")")"
  grep -qE "^delta CREATE .*$(basename "$(row_source "${i}")") ABSENT $(row_gen11 "${i}")\$" \
    "${happy}/root/kyri-gen11-helper-digests.txt" \
    || evidence_problems+=" missing-delta-$(basename "$(row_source "${i}")")"
done
grep -q "^commit ${COMMIT}\$" "${happy}/root/kyri-gen11-helper-digests.txt" \
  || evidence_problems+=" no-authority"
grep -q "^baseline_commit ${GEN10_COMMIT}\$" "${happy}/root/kyri-gen11-helper-digests.txt" \
  || evidence_problems+=" no-predecessor-authority"
grep -q "^predecessor generation 10\$" "${happy}/root/kyri-gen11-helper-digests.txt" \
  || evidence_problems+=" no-predecessor-generation"
grep -q "^library_objects ${EXPECTED_GEN11}\$" "${happy}/root/kyri-gen11-helper-digests.txt" \
  || evidence_problems+=" no-object-count"
grep -q "^state COMMITTED\$" "${happy}/root/kyri-gen11-helper-digests.txt" \
  || evidence_problems+=" no-durable-state"
grep -q "^transaction gen11-" "${happy}/root/kyri-gen11-helper-digests.txt" \
  || evidence_problems+=" no-transaction-identity"
[[ "$(grep -c '^excluded ' "${happy}/root/kyri-gen11-helper-digests.txt")" -eq 5 ]] \
  || evidence_problems+=" no-excluded-record"
if [[ -z "${evidence_problems}" ]]; then
  pass "the generation-11 evidence records the authority, predecessor, nine deltas, five exclusions, count and state"
else
  fail "the generation-11 evidence is incomplete:${evidence_problems}"
fi

if grep -q "^state=COMMITTED" "${happy}/${JOURNAL_REL}"; then
  pass "the journal records COMMITTED"
else
  fail "the journal is not COMMITTED: $(head -8 "${happy}/${JOURNAL_REL}" 2>&1)"
fi
if [[ "$(grep -c '^target[1-9]=' "${happy}/${JOURNAL_REL}")" -eq 9 ]]; then
  pass "the journal durably records all nine targets"
else
  fail "the journal records $(grep -c '^target[1-9]=' "${happy}/${JOURNAL_REL}") targets, expected 9"
fi
if grep -q '^package_dir_created=yes' "${happy}/${JOURNAL_REL}"; then
  pass "the journal durably records that this transaction created the package directory"
else
  fail "the journal does not record the package directory's provenance"
fi
if [[ "$(residue_count "${happy}")" == "0" ]]; then
  pass "prepared artefacts are removed after commit"
else
  fail "$(residue_count "${happy}") transaction artefact(s) survived the commit"
fi
if [[ ! -e "${happy}${SUDOERS_ABS}" && ! -e "${happy}${VERIFY_SUDOERS_ABS}" ]]; then
  pass "the ceremony installed no sudoers grant: G3 and G6.1B stay closed"
else
  fail "the ceremony wrote a sudoers grant"
fi

if run_ceremony "${happy}" "" --verify-installed; then
  pass "--verify-installed accepts the freshly installed generation 11"
else
  fail "--verify-installed rejected a good install: $(tail -24 "${happy}/last-run.log")"
fi

before_vi="$(snapshot_production "${happy}")"
run_ceremony "${happy}" "" --verify-installed || true
if [[ "${before_vi}" == "$(snapshot_production "${happy}")" ]]; then
  pass "--verify-installed mutates nothing"
else
  fail "--verify-installed changed the fixture"
fi

# ===========================================================================
# 7. the installed closure actually satisfies the runtime it was installed for
# ===========================================================================
# Nine correct files is a digest claim. This is the behavioural one: with the
# repository unreachable, does the installed Capability Runtime now resolve the
# Fabric dependency it could not resolve at Generation 10?
import_probe() {
  local root="$1" module="$2"
  ( unset PYTHONPATH
    cd /
    python3 -E -c "
import sys
sys.path = ['${root}/usr/lib/kyri/python'] + [
    p for p in sys.path
    if p and 'schott-platform' not in p and not p.startswith('/opt')]
import importlib
importlib.import_module('${module}')
print('IMPORT OK')
" ) 2>&1
}

gen10_probe="$(import_probe "${clean}" tools.capability.fabric_evidence || true)"
if grep -q "No module named 'tools.fabric'" <<<"${gen10_probe}"; then
  pass "at Generation 10 the installed runtime cannot resolve tools.fabric without the checkout"
else
  fail "the Generation-10 negative control did not reproduce: ${gen10_probe}"
fi

import_problems=""
for module in tools.capability.fabric_evidence tools.capability.coordinator \
              tools.capability.cli tools.fabric.inspection; do
  result="$(import_probe "${happy}" "${module}" || true)"
  grep -q 'IMPORT OK' <<<"${result}" || import_problems+=" ${module}:${result##*$'\n'}"
done
if [[ -z "${import_problems}" ]]; then
  pass "under the installed Generation 11 the runtime resolves Fabric with the repository unreachable"
else
  fail "the installed Generation 11 does not satisfy the runtime:${import_problems}"
fi

# And every resolved module comes from the installed root, not a stray path.
stray="$( unset PYTHONPATH
  cd /
  python3 -E -c "
import sys
sys.path = ['${happy}/usr/lib/kyri/python'] + [
    p for p in sys.path
    if p and 'schott-platform' not in p and not p.startswith('/opt')]
import tools.capability.coordinator
bad = [m for m, mod in sys.modules.items()
       if m.split('.')[0] == 'tools' and getattr(mod, '__file__', None)
       and not mod.__file__.startswith('${happy}')]
print('STRAY', bad)
" 2>&1 || true)"
if grep -q 'STRAY \[\]' <<<"${stray}"; then
  pass "no tools module resolved from outside the installed root"
else
  fail "a tools module resolved from outside the installed root: ${stray}"
fi

# ===========================================================================
# 8. reinstalling an already-established generation
# ===========================================================================
if run_ceremony "${happy}" "" --install \
   && grep -qi "already installed" "${happy}/last-run.log"; then
  pass "a rerun on an installed host is a no-op, not a second transaction"
else
  fail "a rerun did not recognise generation 11: $(tail -10 "${happy}/last-run.log")"
fi

reinstall_before="$(snapshot_production "${happy}")"
run_ceremony "${happy}" "" --install > /dev/null 2>&1 || true
if [[ "${reinstall_before}" == "$(snapshot_production "${happy}")" ]]; then
  pass "the no-op rerun published nothing and rewrote no evidence"
else
  fail "a rerun on an installed host mutated it"
fi

# --verify on an installed host must not report it as ready to install.
if run_ceremony "${happy}" "" --verify \
   && grep -q 'already at Generation 11' "${happy}/last-run.log"; then
  pass "--verify on an installed host reports Generation 11, not readiness to install"
else
  fail "--verify misreported an installed host: $(tail -10 "${happy}/last-run.log")"
fi

# --verify-installed must fail when a single G11 byte is wrong.
for i in 0 8; do
  tampered="${WORK}/tampered${i}"; build_fixture "${tampered}"
  run_ceremony "${tampered}" "" --install >/dev/null 2>&1 || true
  chmod u+w "$(row_target "${i}" "${tampered}")"
  printf '\n# tampered\n' >> "$(row_target "${i}" "${tampered}")"
  if run_ceremony "${tampered}" "" --verify-installed; then
    fail "--verify-installed accepted a tampered $(basename "$(row_source "${i}")")"
  else
    pass "--verify-installed refuses a tampered $(basename "$(row_source "${i}")")"
  fi
done

# and when a published object's mode is wrong.
modedrift="${WORK}/modedrift"; build_fixture "${modedrift}"
run_ceremony "${modedrift}" "" --install >/dev/null 2>&1 || true
chmod 0644 "$(row_target 5 "${modedrift}")"
if run_ceremony "${modedrift}" "" --verify-installed; then
  fail "--verify-installed accepted a published object at the wrong mode"
else
  pass "--verify-installed refuses a published object whose mode drifted"
fi

# and when the package directory's mode is wrong.
dirmode="${WORK}/dirmode"; build_fixture "${dirmode}"
run_ceremony "${dirmode}" "" --install >/dev/null 2>&1 || true
chmod 0777 "${dirmode}/${PACKAGE_REL}"
if run_ceremony "${dirmode}" "" --verify-installed; then
  fail "--verify-installed accepted a world-writable Fabric package directory"
else
  pass "--verify-installed refuses a Fabric package directory whose mode drifted"
fi

# and when an unreviewed module is dropped into an installed package.
smuggled="${WORK}/smuggled"; build_fixture "${smuggled}"
run_ceremony "${smuggled}" "" --install >/dev/null 2>&1 || true
chmod u+w "${smuggled}/${PACKAGE_REL}"
materialise "${COMMIT}" tools/fabric/admission.py "${smuggled}/${PACKAGE_REL}/admission.py"
if run_ceremony "${smuggled}" "" --verify-installed; then
  fail "--verify-installed accepted an unreviewed module smuggled into the installed package"
else
  pass "--verify-installed refuses an unreviewed module added to an installed package"
fi

# and when an unaffected Generation-10 object drifts.
surfacedrift="${WORK}/surfacedrift"; build_fixture "${surfacedrift}"
run_ceremony "${surfacedrift}" "" --install >/dev/null 2>&1 || true
chmod u+w "${surfacedrift}/usr/lib/kyri/python/tools/capability/store.py"
printf '\n# drift\n' >> "${surfacedrift}/usr/lib/kyri/python/tools/capability/store.py"
if run_ceremony "${surfacedrift}" "" --verify-installed; then
  fail "--verify-installed accepted drift in an unaffected object"
else
  pass "--verify-installed refuses drift in an object the transaction did not touch"
fi

# ===========================================================================
# 9. failure injection before the durable commit point
# ===========================================================================
# Every boundary the transaction can be interrupted at, injected rather than
# reasoned about. Positions 1..9 are the nine publications. All of these must
# leave the host at a whole Generation 10: no target present, and -- because
# this transaction created it -- no package directory either.
for boundary in directory created stage staged prepared committing publish verify precommit \
                1 2 3 4 5 6 7 8 9; do
  injected="${WORK}/fail-${boundary}"; build_fixture "${injected}"
  surface_before="$(surface_digest "${injected}")"
  if run_ceremony "${injected}" "${boundary}" --install; then
    fail "an injected failure at '${boundary}' still reported success"
    continue
  fi
  problems=""
  [[ "$(target_states "${injected}")" == "${ALL_ABSENT}" ]] \
    || problems+=" states=[$(target_states "${injected}")]"
  [[ "$(surface_digest "${injected}")" == "${surface_before}" ]] \
    || problems+=" surface-changed"
  [[ -f "${injected}/root/kyri-gen11-library-digests.txt" ]] \
    && problems+=" gen11-evidence-written"
  [[ -f "${injected}/root/kyri-gen10-library-digests.txt" ]] \
    || problems+=" gen10-evidence-lost"
  [[ "$(library_count "${injected}")" -eq "${EXPECTED_GEN10}" ]] \
    || problems+=" object-count=$(library_count "${injected}")"
  [[ -e "${injected}/${PACKAGE_REL}" ]] && problems+=" package-directory-survived"
  [[ "$(residue_count "${injected}")" == "0" ]] || problems+=" residue=$(residue_count "${injected}")"
  if [[ -z "${problems}" ]]; then
    pass "a failure at '${boundary}' leaves a whole Generation 10: no target, no package directory, no residue"
  else
    fail "rollback at '${boundary}' left:${problems}"
  fi
done

# Every intermediate state fails CLOSED. This is the Generation-11 analogue of
# Generation 10's coupled-pair argument, and it is measured rather than argued:
# at every publication position, the runtime that would consume the package must
# refuse rather than half-resolve.
partial="${WORK}/partial"
for published in 1 4 8; do
  stage_interrupted "${partial}" "${published}"
  probe="$(import_probe "${partial}" tools.capability.fabric_evidence || true)"
  if grep -qE "ModuleNotFoundError|ImportError" <<<"${probe}"; then
    pass "with ${published} of 9 published, the runtime refuses rather than importing a partial package"
  else
    fail "a partially published package did not fail closed at ${published}: ${probe}"
  fi
  chmod -R u+w "${partial}" 2>/dev/null || true
done

# ===========================================================================
# 10. after the durable commit point, generation 11 is authoritative
# ===========================================================================
for boundary in postcommit evidence cleanup; do
  after="${WORK}/after-${boundary}"; build_fixture "${after}"
  run_ceremony "${after}" "${boundary}" --install || true
  problems=""
  [[ "$(target_states "${after}")" == "${ALL_PRESENT}" ]] \
    || problems+=" reverted=[$(target_states "${after}")]"
  grep -q "^state=COMMITTED" "${after}/${JOURNAL_REL}" || problems+=" journal-not-committed"
  [[ -f "${after}/root/kyri-gen10-library-digests.txt" ]] || problems+=" gen10-evidence-lost"
  [[ "$(library_count "${after}")" -eq "${EXPECTED_GEN11}" ]] \
    || problems+=" object-count=$(library_count "${after}")"
  if [[ -z "${problems}" ]]; then
    pass "a failure at '${boundary}' leaves generation 11 installed and committed"
  else
    fail "a post-commit failure at '${boundary}' damaged the installation:${problems}"
  fi
done

recoverable="${WORK}/after-cleanup"
if run_ceremony "${recoverable}" "" --verify-installed; then
  pass "--verify-installed accepts generation 11 after a cleanup failure"
else
  fail "--verify-installed rejected a committed generation 11: $(tail -14 "${recoverable}/last-run.log")"
fi

# ===========================================================================
# 11. mixed states: interrupted publication, recovered both directions
# ===========================================================================
for published in 1 4 8; do
  mixed="${WORK}/mixed-forward-${published}"
  stage_interrupted "${mixed}" "${published}"
  expected_before=""
  for i in "${INDICES[@]}"; do
    if (( i < published )); then expected_before+="11 "; else expected_before+="- "; fi
  done
  expected_before="${expected_before% }"
  if [[ "$(target_states "${mixed}")" != "${expected_before}" ]]; then
    fail "the interrupted fixture is [$(target_states "${mixed}")], expected [${expected_before}]"
    continue
  fi
  if run_ceremony "${mixed}" "" --recover; then
    if [[ "$(target_states "${mixed}")" == "${ALL_PRESENT}" ]] \
       && grep -q "^state=COMMITTED" "${mixed}/${JOURNAL_REL}"; then
      pass "recovery from ${published}-of-9 published completes FORWARD to a whole Generation 11"
    else
      fail "recovery from ${published}-of-9 left [$(target_states "${mixed}")]"
    fi
  else
    fail "recovery from ${published}-of-9 failed: $(tail -14 "${mixed}/last-run.log")"
  fi
  if grep -q "FORWARD" "${mixed}/last-run.log"; then
    pass "recovery from ${published}-of-9 states its direction as FORWARD"
  else
    fail "recovery from ${published}-of-9 did not report a FORWARD direction"
  fi
done

# The same mixed shapes with prepared material incomplete: forward cannot be
# proven, so the transaction rolls back by REMOVING what landed.
for published in 1 4 8; do
  back="${WORK}/mixed-back-${published}"
  stage_interrupted "${back}" "${published}"
  rm -f "$(row_target 8 "${back}")${PREPARED_SUFFIX}"
  if run_ceremony "${back}" "" --recover; then
    fail "recovery claimed success with incomplete prepared material"
  else
    problems=""
    [[ "$(target_states "${back}")" == "${ALL_ABSENT}" ]] \
      || problems+=" states=[$(target_states "${back}")]"
    [[ "$(library_count "${back}")" -eq "${EXPECTED_GEN10}" ]] \
      || problems+=" object-count=$(library_count "${back}")"
    [[ -e "${back}/${PACKAGE_REL}" ]] && problems+=" package-directory-survived"
    if [[ -z "${problems}" ]]; then
      pass "recovery from ${published}-of-9 with missing prepared material rolls BACK to a whole Generation 10"
    else
      fail "rollback from a mixed state left:${problems}"
    fi
  fi
done

# A stale journal whose state is unreachable, and an incomplete one with no
# state line at all. Neither may be trusted over the bytes on disk.
staleold="${WORK}/stalejournal"; build_fixture "${staleold}"
mkdir -p "${staleold}/root/kyri-gen11-transaction"
printf 'transaction=gen11-stale\nstate=COMMITTED\n' > "${staleold}/${JOURNAL_REL}"
if run_ceremony "${staleold}" "" --install; then
  fail "--install trusted a COMMITTED journal over targets that do not exist"
else
  if grep -q 'journal says COMMITTED but the targets do not agree' "${staleold}/last-run.log"; then
    pass "a stale COMMITTED journal over absent targets halts for operator disposition"
  else
    fail "the stale journal refused for the wrong reason: $(tail -6 "${staleold}/last-run.log")"
  fi
fi

incomplete="${WORK}/incompletejournal"; stage_interrupted "${incomplete}" 3
printf 'transaction=gen11-incomplete\n' > "${incomplete}/${JOURNAL_REL}"
if run_ceremony "${incomplete}" "" --install; then
  if [[ "$(target_states "${incomplete}")" == "${ALL_PRESENT}" ]]; then
    pass "a journal with no state line recovers from the bytes on disk, not from the journal"
  else
    fail "a stateless journal left [$(target_states "${incomplete}")]"
  fi
else
  fail "a stateless journal was not recovered: $(tail -14 "${incomplete}/last-run.log")"
fi

# ===========================================================================
# 12. UNKNOWN bytes fail closed, and are never removed
# ===========================================================================
for published in 0 3 7; do
  unknown="${WORK}/unknown-${published}"
  if (( published == 0 )); then
    build_fixture "${unknown}"
    mkdir -p "${unknown}/${PACKAGE_REL}" "${unknown}/root/kyri-gen11-transaction"
    printf 'state=COMMITTING\npackage_dir_created=yes\n' > "${unknown}/${JOURNAL_REL}"
  else
    stage_interrupted "${unknown}" "${published}"
  fi
  victim=8
  chmod u+w "${unknown}/${PACKAGE_REL}"
  printf '# neither generation\n' > "$(row_target "${victim}" "${unknown}")"
  before_unknown="$(row_at "${victim}" "${unknown}")"
  if run_ceremony "${unknown}" "" --install; then
    fail "recovery accepted unknown bytes with ${published} published"
  else
    if [[ "$(row_at "${victim}" "${unknown}")" == "${before_unknown}" ]]; then
      pass "unknown bytes halt recovery with ${published} published, and are left exactly as found"
    else
      fail "recovery removed unknown bytes instead of refusing (${published} published)"
    fi
  fi
done

# A published target replaced by a symlink mid-transaction: rollback must refuse
# to unlink it, because the link is not the object this transaction created.
symrollback="${WORK}/symrollback"; stage_interrupted "${symrollback}" 4
chmod u+w "${symrollback}/${PACKAGE_REL}"
rm -f "$(row_target 0 "${symrollback}")"
ln -s /dev/null "$(row_target 0 "${symrollback}")"
rm -f "$(row_target 8 "${symrollback}")${PREPARED_SUFFIX}"
if run_ceremony "${symrollback}" "" --recover; then
  fail "recovery accepted a symlink standing in for a published target"
else
  if [[ -L "$(row_target 0 "${symrollback}")" ]]; then
    pass "a symlink substituted for a published target is refused and left in place, not unlinked"
  else
    fail "rollback removed a symlink it should have refused"
  fi
fi

# A package directory this transaction did NOT create must survive a rollback,
# even when every target it holds is removed.
notours="${WORK}/notourdirectory"; stage_interrupted "${notours}" 2
sed -i 's/^package_dir_created=yes/package_dir_created=no/' "${notours}/${JOURNAL_REL}"
rm -f "$(row_target 8 "${notours}")${PREPARED_SUFFIX}"
run_ceremony "${notours}" "" --recover || true
if [[ -d "${notours}/${PACKAGE_REL}" && "$(target_states "${notours}")" == "${ALL_ABSENT}" ]]; then
  pass "a package directory this transaction did not create survives rollback, while its targets are removed"
else
  fail "rollback removed a directory it did not create, or left a target behind"
fi

# ===========================================================================
# 13. the repository, and what publication actually consumes
# ===========================================================================
# The brief asks whether the reviewed objects can be published after the
# repository becomes unavailable. In this architecture they cannot, and that is
# deliberate rather than an omission: every mode re-verifies the pinned digests
# against the reviewed commit before it acts, so an unreachable repository is a
# refusal, not a degraded mode. What IS required -- and is proven here -- is the
# narrower property that publication consumes prepared bytes only: between
# COMMITTING and COMMITTED nothing reads the repository, so a repository that
# vanished mid-publication could not corrupt what lands.
commit_body="$(sed -n '/^commit_targets()/,/^}/p' "${CEREMONY}")"
if grep -qE 'git_as_owner|git -C|cat-file' <<<"${commit_body}"; then
  fail "the publication phase reads the repository"
else
  pass "the publication phase consumes prepared bytes only: no repository read between COMMITTING and COMMITTED"
fi

prepare_body="$(sed -n '/^prepare()/,/^}/p' "${CEREMONY}")"
if grep -q 'git_as_owner cat-file blob' <<<"${prepare_body}"; then
  pass "every reviewed byte is materialised in PREPARE, before any publication"
else
  fail "PREPARE does not materialise the reviewed objects"
fi

unreachable="${WORK}/unreachable"; stage_interrupted "${unreachable}" 3
badrepo="${WORK}/install-badrepo.sh"
sed 's#^REPOSITORY="/opt/schott-platform"$#REPOSITORY="/nonexistent-repository"#' \
  "${CEREMONY}" > "${badrepo}"
if run_variant "${badrepo}" "${unreachable}" --recover; then
  fail "recovery proceeded with the repository unreachable"
else
  if [[ "$(target_states "${unreachable}")" == "11 11 11 - - - - - -" ]]; then
    pass "an unreachable repository refuses recovery and changes nothing: a refusal, not a degraded mode"
  else
    fail "an unreachable repository left [$(target_states "${unreachable}")]"
  fi
fi

# ===========================================================================
# 14. ownership: enforced in production, unobservable unprivileged
# ===========================================================================
# This suite runs as an ordinary user and cannot chown, so a live wrong-owner
# case is not constructible here. What is constructible is proof that the check
# exists, that it is skipped ONLY in fixture mode, and that a production run
# therefore cannot reach publication without it.
owner_problems=""
# The patterns below are literal shell source being searched for, not
# expressions to expand -- single quotes are the point.
# shellcheck disable=SC2016
grep -q 'chown root:root "${prepared}"' <<<"${prepare_body}" \
  || owner_problems+=" prepared-not-chowned"
# shellcheck disable=SC2016
grep -q 'chown root:root "${PACKAGE_DIR}"' <<<"${prepare_body}" \
  || owner_problems+=" package-dir-not-chowned"
# shellcheck disable=SC2016
grep -q 'owner_now="$(stat -c .%U:%G. "${target}")"' <<<"${commit_body}" \
  || owner_problems+=" no-post-publication-owner-check"
grep -q 'OWNER_FAILED' <<<"${commit_body}" || owner_problems+=" no-owner-rollback"
# The only guard on those branches is fixture mode.
# shellcheck disable=SC2016
if ! grep -q 'if \[\[ -z "${FIXTURE}" \]\]; then' <<<"${commit_body}"; then
  owner_problems+=" owner-check-not-gated-on-fixture-mode"
fi
if [[ -z "${owner_problems}" ]]; then
  pass "ownership is set on every prepared object and verified after every publication, skipped only in fixture mode"
else
  fail "the ownership discipline is incomplete:${owner_problems}"
fi

if [[ "$(id -u)" != "0" ]]; then
  pass "this suite runs unprivileged, so it cannot and does not exercise a live chown"
else
  fail "this suite must not run as root"
fi

# ===========================================================================
# 15. security backstops, proven structurally
# ===========================================================================
body="$(grep -v '^[[:space:]]*#' "${CEREMONY}")"
forbidden=0
for token in "vi""sudo" "pod""man" "doc""ker" "xfs_""quota" "quot""actl" \
             "set""cap" "CINV""-" "CRES""-" "CADM""-" "authorise-launch" \
             "kyri-exec-verify " "kyri-exec-transition " "capability-handoff" \
             "kyri-root"; do
  if grep -qF "${token}" <<<"${body}"; then
    printf 'unexpected token in ceremony: %s\n' "${token}" >&2
    forbidden=$((forbidden + 1))
  fi
done
if (( forbidden == 0 )); then
  pass "the ceremony executes no helper, seeds no store, and grants no authority"
else
  fail "${forbidden} forbidden token(s) appear in the ceremony"
fi

if grep -qE '(printf|echo|cat|tee|cp |mv |install |chmod|chown|rm |mkdir|>|>>)[^|]*(AUTHORITY_ROOT|CONTROL_ROOT)' \
     <<<"${body}"; then
  fail "the ceremony carries a write verb aimed at the authority namespace"
else
  pass "the authority namespace is only ever read, never written"
fi

# CGEN is the governed implementation authority and is advanced by admission,
# never by a library installation. The two numbering schemes are independent.
if grep -qE 'current-generation|CGEN-' <<<"${body}"; then
  fail "the ceremony references the governed implementation-authority generation"
else
  pass "the ceremony does not touch current-generation: CGEN is advanced by admission, not by an install"
fi

for mode_branch in --verify --verify-installed; do
  if grep -qE '^\s*(chmod|chown|rm|mv|cp|install|mkdir)\b' \
       <<<"$(sed -n "/^${mode_branch})/,/^\s*;;/p" "${CEREMONY}")"; then
    fail "${mode_branch} carries a mutating command"
  else
    pass "the ${mode_branch} branch carries no mutating command"
  fi
done

authority_untouched=1
for probe in "${WORK}"/*/var/lib/kyri; do
  [[ -e "${probe}" ]] || continue
  find "${probe}" -mindepth 1 -print -quit | grep -q . && authority_untouched=0
done
if (( authority_untouched == 1 )); then
  pass "no fixture run wrote into the implementation-authority namespace"
else
  fail "a fixture run wrote authority state"
fi

# ===========================================================================
# 16. the ceremony describes the transaction it actually performs
# ===========================================================================
# Ceremony output is audit evidence. Generation 10's inverse failure mode was
# inheriting a one-object narrative; Generation 11's is inheriting a REPLACE
# narrative for a transaction that only creates.
STALE_CLAIMS='\bfour REPLACE\b|\bone REPLACE\b|single replacement|\b48\b *-> *\b48\b|unchanged at 48|Generation 10 is FOUR'
messages="$(grep -oE '\b(ok|note|bad|halt)[[:space:]]+"[^"]*"' "${CEREMONY}" || true)"
if grep -qiE "${STALE_CLAIMS}" <<<"${messages}"; then
  grep -oiE "${STALE_CLAIMS}" <<<"${messages}" | sort -u \
    | while IFS= read -r hit; do
        printf 'stale operator message contains %s\n' "${hit}" >&2
      done
  fail "an operator-visible message still describes the Generation-10 transaction"
else
  pass "no operator-visible message claims anything the nine-row CREATE matrix cannot support"
fi

header="$(sed -n '1,70p' "${CEREMONY}")"
problems=""
grep -qiE 'NINE CREATE' <<<"${header}" || problems+=" header-does-not-say-nine-create"
grep -qE '48 -> 57' <<<"${header}" || problems+=" header-does-not-state-the-count-change"
grep -qiE 'no REPLACE' <<<"${header}" || problems+=" header-does-not-say-no-replace"
if [[ -z "${problems}" ]]; then
  pass "the header describes nine CREATE operations and the 48 -> 57 count change"
else
  fail "the header misdescribes the transaction:${problems}"
fi

spoken="${WORK}/spoken"; build_fixture "${spoken}"
run_ceremony "${spoken}" "" --install || true
spoken_problems=""
grep -qE 'PREPARE complete: 9 objects' "${spoken}/last-run.log" || spoken_problems+=" prepare-line-does-not-say-9-objects"
grep -qE 'COMMIT complete: 9 objects' "${spoken}/last-run.log" || spoken_problems+=" commit-line-does-not-say-9-objects"
if grep -qiE "${STALE_CLAIMS}" "${spoken}/last-run.log"; then
  spoken_problems+=" said:$(grep -oiE "${STALE_CLAIMS}" "${spoken}/last-run.log" \
    | sort -u | tr '\n' ',' | tr ' ' '_')"
fi
for i in "${INDICES[@]}"; do
  grep -qF "$(basename "$(row_source "${i}")")" "${spoken}/last-run.log" \
    || spoken_problems+=" never-named-$(basename "$(row_source "${i}")")"
done
grep -qi 'Generation 11' "${spoken}/last-run.log" || spoken_problems+=" never-named-generation-11"
if [[ -z "${spoken_problems}" ]]; then
  pass "an actual --install run names all nine objects and describes only what it did"
else
  fail "an actual --install run misreported itself:${spoken_problems}"
fi

for mode in --verify --verify-installed; do
  spoken_mode="${WORK}/spoken${mode}"; build_fixture "${spoken_mode}"
  [[ "${mode}" == "--verify-installed" ]] && run_ceremony "${spoken_mode}" "" --install >/dev/null 2>&1
  run_ceremony "${spoken_mode}" "" "${mode}" || true
  mode_problems=""
  if grep -qiE "${STALE_CLAIMS}" "${spoken_mode}/last-run.log"; then
    mode_problems+=" said:$(grep -oiE "${STALE_CLAIMS}" "${spoken_mode}/last-run.log" \
      | sort -u | tr '\n' ',' | tr ' ' '_')"
  fi
  grep -qi 'Generation 11' "${spoken_mode}/last-run.log" || mode_problems+=" never-named-generation-11"
  if [[ -z "${mode_problems}" ]]; then
    pass "${mode} output describes only the Generation-11 transaction"
  else
    fail "${mode} output misdescribes the transaction:${mode_problems}"
  fi
done

# ===========================================================================
# 17. registration and isolation
# ===========================================================================
if grep -q "tests/test-capability-execution-generation11-installer.sh" \
     "${REPOSITORY}/tools/dev/run-validation.sh" \
   && grep -q "tests/test-capability-execution-generation11-installer.sh" \
     "${REPOSITORY}/.github/workflows/ci.yml"; then
  pass "the generation-11 installer suite runs in local validation and in CI"
else
  fail "the generation-11 installer suite is not registered"
fi

# The ceremony is invoked deliberately, never by accident.
if [[ ! -x "${CEREMONY}" ]]; then
  pass "the ceremony is not executable: it is invoked deliberately, never by accident"
else
  fail "the ceremony carries an execute bit"
fi

PRODUCTION_AFTER="$(snapshot_production "${PRODUCTION_PATHS[@]}")"
if [[ "${PRODUCTION_BEFORE}" == "${PRODUCTION_AFTER}" ]]; then
  pass "no production path changed while this suite ran"
else
  fail "a production path changed while this suite ran"
fi

# Whether Generation 11 is installed is a fact about the host at a moment, not
# an invariant of this suite. Asserting the pre-install state bound the suite to
# the day it was written: it passed until the operator installed Generation 11
# and failed from then on, while nothing about the suite or the ceremony had
# changed. What is invariant is that THIS SUITE installs nothing -- proven
# directly above by the production snapshot -- and that if a Fabric package is
# installed, it is exactly the reviewed closure and nothing more.
if [[ ! -e /usr/lib/kyri/python/tools/fabric ]]; then
  pass "production carries no installed Fabric package: Generation 11 is not installed here"
else
  installed_fabric="$(find /usr/lib/kyri/python/tools/fabric -type f -name '*.py' | wc -l)"
  smuggled=""
  for excluded in admission.py cli.py eligibility.py selection.py trust_adapter.py; do
    [[ -e "/usr/lib/kyri/python/tools/fabric/${excluded}" ]] && smuggled+=" ${excluded}"
  done
  if [[ "${installed_fabric}" -eq "${#ROWS[@]}" && -z "${smuggled}" ]]; then
    pass "production carries the installed Generation-11 closure: exactly ${#ROWS[@]} reviewed objects, no write-plane module"
  else
    fail "the installed Fabric package is ${installed_fabric} objects and carries:${smuggled:- nothing undeclared}"
  fi
fi

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution generation-11 installer validation passed.\n'
else
  printf 'Capability execution generation-11 installer validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
