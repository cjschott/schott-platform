#!/usr/bin/env bash
set -Eeuo pipefail

# One command that runs everything CI runs, in a deterministic order.
#
# Stops at the first failure and preserves that command's exit code, so the
# status this script returns is the status of the thing that actually broke.
#
# It contacts no host, installs nothing, starts no platform container, writes
# nothing into the repository, persists no evidence, and never reads ai/.env.
# The only container it may start is the pinned ShellCheck image, which is
# ephemeral, network-isolated, and mounts the repository read-only.
#
# Usage:
#   tools/dev/run-validation.sh           # everything (33 steps)
#   tools/dev/run-validation.sh --quick   # skip the slowest suites
#   tools/dev/run-validation.sh --strict  # toolchain warnings become errors
#
# What --quick omits, and nothing else:
#
#   - tests/test-platform-model.sh      (848 assertions, the slowest suite)
#   - tests/test-initial-collectors.sh  (builds temporary git repositories)
#   - tests/test-knowledge-orchestrator.sh (builds temporary evidence stores)
#   - tests/test-operational-integrity.sh  (builds temporary integrity stores)
#   - tests/test-experience-engine.sh      (builds temporary experience stores)
#   - tests/test-occurrence-timeline.sh    (builds temporary occurrence stores)
#   - tests/test-remote-collectors.sh      (drives a fake transport; spawns the CLI)
#   - tests/test-trust-runtime.sh          (builds synthetic trust stores; spawns the CLI)
#   - tests/test-fabric-runtime.sh         (builds synthetic fabric records; spawns Python)
#   - tests/test-capability-runtime.sh     (builds temporary capability stores; spawns Python)
#   - the three Docker Compose renders  (each spawns the compose binary)
#
# Quick mode still runs syntax checking, ShellCheck, both static suites, both
# Python validators, the CLI checks, the bytecode check, and the whitespace
# check. It is for a tight edit loop; it is never sufficient before pushing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${ROOT}"

QUICK=0
STRICT=0
for argument in "$@"; do
  case "${argument}" in
    --quick) QUICK=1 ;;
    --strict) STRICT=1 ;;
    --help|-h)
      sed -n '3,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) printf 'ERROR unknown argument: %s\n' "${argument}" >&2; exit 2 ;;
  esac
done

STEP=0
STARTED_AT="$(date -Is)"

# Existence of the two approved production paths, sampled before any step runs.
# Reports existence only: reading a root-owned trust store is not this script's
# business, and it does not have permission to try.
production_path_state() {
  local path state=''
  for path in /var/lib/kyri /etc/kyri; do   # prod-path-reference
    if [[ -e "${path}" ]]; then state+="${path}:present "; else state+="${path}:absent "; fi
  done
  printf '%s' "${state}"
}
PRODUCTION_PATH_STATE_AT_START="$(production_path_state)"

section() {
  STEP=$((STEP + 1))
  printf '\n[%02d/%s] %s\n' "${STEP}" "${TOTAL_STEPS}" "$1"
}

# run <description> <command...>
# Preserves the failing command's exit code rather than collapsing everything
# to 1, so a caller can tell a validation failure from an invocation error.
#
# The status is captured immediately after the command, not inside an
# `if ! "$@"` test: there $? is the status of the negation, which is 0 when the
# command failed. That mistake makes a validation script report a failure and
# then exit 0, which is the worst possible outcome for a tool whose entire job
# is to be believed.
run() {
  local description="$1"; shift
  local status=0
  section "${description}"
  set +e
  "$@"
  status=$?
  set -e
  if (( status != 0 )); then
    printf '\nFAILED: %s (exit %d)\n' "${description}" "${status}" >&2
    printf 'Validation stopped at step %d. Nothing after it ran.\n' "${STEP}" >&2
    exit "${status}"
  fi
}

skipped_note() {
  printf '\n[--] %s — omitted by --quick\n' "$1"
}

# Counted, not guessed: every check plus the closing summary. A validation tool
# that miscounts its own steps invites doubt about everything else it reports.
# The ENG-0005 execution suites are all always-on, so each one added raises
# both totals.
#
# The quick total had drifted six steps below what quick mode actually runs
# and was corrected here from measurement rather than from arithmetic. Full mode
# was already correct. Both are now read off a real run, which is the only way
# this number stays true.
if (( QUICK == 1 )); then
  TOTAL_STEPS=66
  printf '── Validation (quick mode) — %s\n' "${STARTED_AT}"
else
  TOTAL_STEPS=77
  printf '── Validation (full) — %s\n' "${STARTED_AT}"
fi

# --- 1. toolchain ----------------------------------------------------------
if (( STRICT == 1 )); then
  run "Toolchain check (strict)" "${SCRIPT_DIR}/check-toolchain.sh" --strict
else
  run "Toolchain check" "${SCRIPT_DIR}/check-toolchain.sh"
fi

# --- 2. shell syntax -------------------------------------------------------
# Mirrors the CI "Shell syntax check" step.
syntax_check() {
  bash -n scripts/*.sh
  bash -n tests/*.sh
  bash -n tools/dev/*.sh
  # Operator tooling ships beside the runbook it belongs to, so it is syntax
  # checked here rather than being the one shell script nothing reads.
  bash -n provisioning/execution/*.sh
}
run "Shell syntax (bash -n)" syntax_check

# --- 3. shellcheck ---------------------------------------------------------
run "ShellCheck" "${SCRIPT_DIR}/run-shellcheck.sh"

# --- 4-5. static suites ----------------------------------------------------
run "Static repository assertions" bash tests/test-static.sh
run "Static documentation assertions" bash tests/test-docs-static.sh

# --- 6. platform model -----------------------------------------------------
if (( QUICK == 0 )); then
  run "Platform model validation" bash tests/test-platform-model.sh
else
  skipped_note "Platform model validation"
fi

# --- 7-9. remaining suites -------------------------------------------------
run "Evidence validator behaviour" bash tests/test-evidence-validator.sh
run "Collector framework" bash tests/test-collector-framework.sh

if (( QUICK == 0 )); then
  run "Initial read-only collectors" bash tests/test-initial-collectors.sh
  run "Knowledge orchestrator" bash tests/test-knowledge-orchestrator.sh
  # Builds temporary evidence and integrity stores, so it belongs with the
  # other store-building suites rather than in the quick path.
  run "Operational integrity" bash tests/test-operational-integrity.sh
  # After integrity: the experience engine consumes integrity's vocabulary for
  # the combined EXPECTED/MATCH assessment, so it is validated downstream of it.
  run "Experience engine" bash tests/test-experience-engine.sh
  # After experience: the occurrence layer reads both integrity and experience
  # vocabulary, so it is validated downstream of both.
  run "Occurrence timeline" bash tests/test-occurrence-timeline.sh
  # After the reasoning layers: remote collection is the only suite that
  # exercises code able to reach another machine. It drives a fake transport
  # exclusively and contacts no host, but it spawns the CLI, so it sits with
  # the other subprocess-driving suites rather than in the quick path.
  run "Remote collectors" bash tests/test-remote-collectors.sh
  # After the trust architecture suite: the runtime enforces what ADR-0011
  # specifies, so it is validated downstream of the specification. It builds
  # synthetic stores in temp directories and spawns the CLI, so it sits with
  # the other subprocess-driving suites rather than in the quick path.
  run "Trust runtime" bash tests/test-trust-runtime.sh
  # After the fabric architecture suite: ENG-0004 implements what ADR-0012
  # specifies, so the runtime is validated downstream of the specification. It
  # builds synthetic records in memory and spawns Python, so it sits with the
  # other subprocess-driving suites rather than in the quick path.
  run "Fabric runtime" bash tests/test-fabric-runtime.sh

  # ENG-0005 Track A. The Capability Runtime's persistence foundation, plus the
  # permanent backstop asserting the package still executes nothing. It builds
  # temporary stores and spawns Python, so it sits with the other
  # subprocess-driving suites rather than in the quick path.
  run "Capability runtime" bash tests/test-capability-runtime.sh
else
  skipped_note "Initial read-only collectors"
  skipped_note "Knowledge orchestrator"
  skipped_note "Operational integrity"
  skipped_note "Experience engine"
  skipped_note "Capability runtime"
  skipped_note "Occurrence timeline"
  skipped_note "Remote collectors"
  skipped_note "Trust runtime"
  skipped_note "Fabric runtime"
fi

# Static and documentation only: the trust plane is architecture in this
# release, so there is no engine to exercise. Builds no store, spawns no
# subprocess, contacts nothing — it runs in quick mode as well.
run "Trust plane" bash tests/test-trust-plane.sh

# Static and behavioural, but it builds no store of its own and spawns no
# subprocess: the migration suite drives the gateway directly, so it runs in
# quick mode alongside the architecture suite it depends on.
run "Trust migration" bash tests/test-trust-migration.sh

# Static and documentation only: the fabric is architecture in this release, so
# there is no engine to exercise. Builds no store, spawns no subprocess,
# contacts nothing — it runs in quick mode as well.
run "Capability fabric" bash tests/test-capability-fabric.sh

# ENG-0005 first adapter, increments T1-T5. One suite per increment, each
# carrying the purity or authority backstop for the modules that increment
# added. They are pure or descriptor-scoped and need no host state, so they run
# in the always-on path rather than behind the subprocess gate.
run "Capability execution types" bash tests/test-capability-execution.sh
run "Capability execution canonical JSON" \
  bash tests/test-capability-execution-canonical-json.sh
run "Capability execution payload" bash tests/test-capability-execution-payload.sh
run "Capability execution implementation authority" \
  bash tests/test-capability-execution-implementation-authority.sh
run "Capability execution mutation" bash tests/test-capability-execution-mutation.sh
run "Capability execution capacity" bash tests/test-capability-execution-capacity.sh
run "Capability execution capacity race" \
  bash tests/test-capability-execution-capacity-race.sh
run "Capability execution handoff" bash tests/test-capability-execution-handoff.sh
run "Capability execution profile" bash tests/test-capability-execution-profile.sh
run "Capability execution protocol" bash tests/test-capability-execution-protocol.sh

# ENG-0005 T10. The transition helper POLICY only: this suite runs entirely
# unprivileged and installs nothing. Helper installation is gate G2.
run "Capability execution helper policy" \
  bash tests/test-capability-execution-helper-policy.sh

# ENG-0005 T11. The privileged action layer, exercised through an injected
# backend: no root, no sudo, no credential change. Real transition is gate G6.
run "Capability execution transition action" \
  bash tests/test-capability-execution-transition-action.sh

# ENG-0005 Pass 3B-ii. The sealed profile transport across the privilege
# boundary. Real memfds, real seals, and one real execve into a controlled
# child -- but no privilege: credentials and the worker exec are injected.
run "Capability execution profile transport" \
  bash tests/test-capability-execution-profile-transport.sh

# ENG-0005 Pass 4A. The create_argv authority gate: policy re-derivation,
# runtime contracts, image presence through an injected seam, and the payload
# and package commitments. Builds an argv tuple and executes nothing.
run "Capability execution authority gate" \
  bash tests/test-capability-execution-authority-gate.sh

# ENG-0005 Pass 4B. The worker-owned invocation snapshot: the copy that closes
# the race a second verification could not. Real filesystem mutation against
# fixture trees; no privilege, no container, no Podman.
run "Capability execution snapshot" \
  bash tests/test-capability-execution-snapshot.sh

# ENG-0005 generation-5 installer. Drives the operator installer against
# throwaway fixture trees only: failure is injected at every commit position
# and every interrupted transaction is replayed. Installs nothing, needs no
# privilege, and snapshots the production paths to prove it touched none.
run "Capability execution generation-5 installer" \
  bash tests/test-capability-execution-generation5-installer.sh

# ENG-0005 generation-6 installer. The same model with one runtime object that
# is NEW, so rollback has to REMOVE rather than restore. Failure is injected at
# every commit position, every interrupted transaction is replayed, and the
# create pathname is attacked directly. Fixture trees only: it installs no
# tmpfiles fragment, creates no snapshot root, and never runs systemd-tmpfiles.
run "Capability execution generation-6 installer" \
  bash tests/test-capability-execution-generation6-installer.sh

# ENG-0005 G5 preparation. The read-only ceremony preflight: it proves the host
# is at the ruled G5 starting position and reports the three outstanding
# rulings. Read-only in every mode, asserted against its own source as well as
# by fixtures. Builds no image, creates no authority state, invokes no Podman.
run "Capability execution G5 preflight" \
  bash tests/test-capability-execution-g5-preflight.sh

# ENG-0005 G5 ceremony. The operator artifact and, above all, the trust
# boundary it rests on: root materialises the pinned commit from git objects
# into a root-owned tree and imports nothing else. Each isolation property is
# proven by attacking it. Builds no image, creates no authority state.
run "Capability execution G5 ceremony" \
  bash tests/test-capability-execution-g5-ceremony.sh

# ENG-0005 G5 supply chain. Cosign trust, the Chainguard SPDX attestation, and
# the candidate/approval separation. Synthetic DSSE envelopes only: no network,
# no cosign install, no image pull, and no approval is ever written.
run "Capability execution G5 supply chain" \
  bash tests/test-capability-execution-g5-supply-chain.sh

# ENG-0005 G5 base discovery. Selection of a base-image candidate by the
# governed Python version rather than by whatever :latest points at today.
# Recorded history and recorded SPDX only: no network, no pull, no approval.
run "Capability execution G5 discovery" \
  bash tests/test-capability-execution-g5-discovery.sh

# ENG-0005 G5 build context. The execution identity cannot traverse the
# coordinator's checkout, so the reviewed image context is materialised from
# pinned git objects onto root-owned ancestry. Fixture trees only: no image is
# built, no base pulled, and no container runtime invoked.
run "Capability execution G5 build context" \
  bash tests/test-capability-execution-g5-build-context.sh

# ENG-0005 G5 authority phases. Mutation eligibility derived from the ruled
# provisioning evidence, and the bootstrap/genesis/admission chain driven
# against fixture namespaces with an injected image observation. Touches no
# production namespace, invokes no Podman, admits nothing real.
run "Capability execution G5 authority" \
  bash tests/test-capability-execution-g5-authority.sh

# ENG-0005 T12. The unprivileged worker, driven through a fake Podman backend:
# no subprocess, no container, no Podman. Real execution is gate G6.
run "Capability execution lifecycle" \
  bash tests/test-capability-execution-lifecycle.sh

# ENG-0005 T13. Terminal classification and timeout, decided from immutable
# observations with an injected clock and termination backend.
run "Capability execution terminal" \
  bash tests/test-capability-execution-terminal.sh

# ENG-0005 T14. Result and output-tree collection from a descriptor, over trees
# this suite builds in a temporary directory. Reads and hashes; creates,
# deletes, and executes nothing.
run "Capability execution collector" \
  bash tests/test-capability-execution-collector.sh

# ENG-0005 T15. Forensic quarantine over a temporary store: reserves, copies,
# and seals inside the suite's own directory. Deletes nothing and, being v1,
# has no deletion path at all.
run "Capability execution quarantine" \
  bash tests/test-capability-execution-quarantine.sh

# ENG-0005 T16. Cleanup over handoff trees the suite builds in a temporary
# directory, and recovery classification over supplied observations. Deletes
# only inside its own fixture; contacts no runtime.
run "Capability execution cleanup" \
  bash tests/test-capability-execution-cleanup.sh

# ENG-0005 T17. Administrative dispatch and CADM over a temporary namespace,
# with an injected destruction backend. Installs no helper, touches no sudoers,
# and authenticates nothing. Gates G2 and G3 stay closed.
run "Capability execution administrative" \
  bash tests/test-capability-execution-admin.sh

# ENG-0005 T18. The adapter driven through an injected backend: no Podman, no
# subprocess, no container, and no provisioned runtime. Gates G4-G6 stay closed.
run "Capability execution adapter" \
  bash tests/test-capability-execution-adapter.sh

# ENG-0005 T19. Static validation of the production image definition and its
# admission procedure. Builds nothing, pulls nothing, and admits nothing:
# building is gate G5 and admission is a governed operator step after it.
run "Capability execution image definition" \
  bash tests/test-capability-execution-image.sh

# ENG-0005 G4 increment. Per-invocation output containment policy and the
# privileged quota source. Sets no quota, opens no device, needs no XFS, and
# installs nothing: the privileged operation is source only behind G2/G3.
run "Capability execution output quota" \
  bash tests/test-capability-execution-quota.sh

# ENG-0005 G5 increment. Offline implementation-authority bootstrap: the CIMP
# and CGEN counters, the lifecycle mutation lock, and the genesis ceremony.
# Hermetic against temporary roots -- creates no production authority path,
# admits no implementation, and opens no gate.
run "Capability implementation-authority bootstrap" \
  bash tests/test-capability-authority-bootstrap.sh

# ENG-0005 G5 increment. Ordinary implementation-admission transaction and the
# canonical provisioning-evidence manifest. Hermetic against temporary roots --
# builds no image, runs no Podman, and creates no production authority path.
run "Capability implementation admission" \
  bash tests/test-capability-authority-admission.sh

# ENG-0005 G5 increment. Pending-disposition ceremonies: COMPLETE and RETIRE,
# settled in one successor generation. Hermetic against temporary roots.
run "Capability pending disposition" \
  bash tests/test-capability-authority-disposition.sh

# ENG-0005 G5 increment. Coordinator authority resolution: a requested CIMP
# becomes a governed ExecutionProfile. Read-only and hermetic.
run "Capability authority resolution" \
  bash tests/test-capability-authority-resolution.sh

# ENG-0005 G4 artifacts. Static validation of the installed worker entrypoint,
# the backing-store and sudoers examples, and the provisioning runbook.
# Installs nothing, mounts nothing, and creates no sudoers policy.
run "Capability execution provisioning artifacts" \
  bash tests/test-capability-execution-provisioning.sh

# ENG-0005 G6.1A. The trusted-runtime installation ceremony for the
# verification-only artifacts: transactional create-once publication of five
# new objects onto a verified generation-6 baseline, with failure injected at
# every commit position and every interrupted transaction replayed. Fixture
# trees only -- it installs nothing, writes no sudoers, invokes no transition
# or worker, and contacts no container runtime.
run "Capability execution generation-7 (G6.1A) ceremony" \
  bash tests/test-capability-execution-generation7-installer.sh

# ENG-0005 G6.1. The whole privileged chain up to, and deliberately short of,
# container execution: the transition selects a verification-only worker that
# runs the SAME shared gate production runs and then emits a proof instead of
# creating a container. Structural non-execution is asserted rather than
# assumed. Installs no sudoers, invokes no sudo, performs no transition,
# executes no worker, and invokes no container runtime.
run "Capability execution G6.1 verification" \
  bash tests/test-capability-execution-g61-verification.sh

# The coordinator execution-authorization bridge: execution-prepared to a
# handoff a privileged boundary may later verify, and no further. The lifecycle
# transition is the authority, the launch-authorisation is its journalled
# projection, and the handoff is materialisation. Elevates nothing, executes
# nothing, and contacts no container runtime.
run "Capability execution launch bridge" \
  bash tests/test-capability-execution-launch-bridge.sh

# The Generation-8 installation ceremony: one REPLACE and one CREATE, so the
# accepted Generation-7 mutation.py must survive until the transaction commits
# and must be restorable exactly. Fixture-only: installs nothing on this host,
# writes no sudoers, invokes no helper, and contacts no container runtime.
run "Capability execution generation-8 installer" \
  bash tests/test-capability-execution-generation8-installer.sh

# The governed S5 operator surface: `capability authorise-launch`, a thin
# adapter over the Generation-8 bridge. Fixture-only; elevates nothing, seeds
# no governance store, and contacts no container runtime.
run "Capability execution launch CLI" \
  bash tests/test-capability-execution-launch-cli.sh

# Static and documentation only: the health plane is architecture in this
# release, so there is no engine, collector, or probe to exercise. Builds no
# store, spawns no subprocess, contacts nothing — it runs in quick mode too.
run "Capability health" bash tests/test-capability-health.sh

run "Developer experience" bash tests/test-developer-experience.sh

# --- 10-11. python validators ---------------------------------------------
run "Evidence and drift definitions" \
  python3 tools/platform_model/validate_evidence.py --root platform-model

# A standard YAML loader keeps only the last value for a repeated key, so an
# earlier ontology definition disappears during parsing and nothing notices.
# Fails closed, and names the file, key, and line.
ontology_duplicate_check() {
  python3 tools/platform_model/validate_ontology.py --root platform-model
  python3 tools/platform_model/validate_ontology.py --root . --all-tracked
}
run "Ontology duplicate-key validation" ontology_duplicate_check
run "Collector plugin manifests" \
  python3 tools/collectors/validate_plugins.py --root .

# --- 12-14. command line interfaces ---------------------------------------
cli_collectors_list() { python3 -m tools.collectors.cli list >/dev/null; }
cli_collectors_validate() { python3 -m tools.collectors.cli validate >/dev/null; }
cli_observation_help() { python3 -m tools.observation.cli --help >/dev/null; }
run "Collector CLI (list)" cli_collectors_list
run "Collector CLI (validate)" cli_collectors_validate
run "Observation CLI (help)" cli_observation_help

# --- 15. compose renders ---------------------------------------------------
# `config` only. This renders declared configuration and starts nothing.
compose_renders() {
  docker compose --env-file ai/.env.example -f ai/compose.yaml config >/dev/null
  docker compose --env-file ai/ollama/.env.example -f ai/ollama/compose.yaml config >/dev/null
  docker compose --env-file ai/litellm/.env.example -f ai/litellm/compose.yaml config >/dev/null
}
if (( QUICK == 0 )); then
  run "Docker Compose configuration renders" compose_renders
else
  skipped_note "Docker Compose configuration renders"
fi

# --- 16. whitespace --------------------------------------------------------
run "Whitespace (git diff --check)" git diff --check

# --- 17. tracked bytecode --------------------------------------------------
bytecode_check() {
  local tracked
  tracked="$(git ls-files '*__pycache__*' '*.pyc')"
  if [[ -n "${tracked}" ]]; then
    printf 'Tracked Python bytecode found:\n%s\n' "${tracked}" >&2
    return 1
  fi
  printf '  ok       no tracked Python bytecode\n'
}
run "Tracked bytecode" bytecode_check

# --- 18. runtime evidence backstop -----------------------------------------
# Generated records belong in an observation store outside the repository.
runtime_evidence_check() {
  local committed
  committed="$(git ls-files \
    'platform-model/evidence/EVID-*' \
    'platform-model/verifications/VER-*' \
    'platform-model/knowledge-events/MEM-*' \
    'platform-model/observations/OBS-*' \
    '*TAUTH-[0-9][0-9][0-9][0-9][0-9][0-9]*' \
    '*TREC-[0-9][0-9][0-9][0-9][0-9][0-9]*' \
    '*TDEC-[0-9][0-9][0-9][0-9][0-9][0-9]*' \
    '*TSCOPE-[0-9][0-9][0-9][0-9][0-9][0-9]*' \
    '*TEVID-[0-9][0-9][0-9][0-9][0-9][0-9]*' \
    '*TAUDIT-[0-9][0-9][0-9][0-9][0-9][0-9]*')"
  if [[ -n "${committed}" ]]; then
    printf 'Generated runtime records must not be committed:\n%s\n' "${committed}" >&2
    return 1
  fi
  local stray
  stray="$(find . -path ./.git -prune -o -name '*.tmp' -print 2>/dev/null)"
  if [[ -n "${stray}" ]]; then
    printf 'Partial store writes left behind:\n%s\n' "${stray}" >&2
    return 1
  fi
  printf '  ok       no committed runtime evidence, no partial writes\n'
}
run "Runtime evidence backstop" runtime_evidence_check

# --- 19. production-path backstop ------------------------------------------
# Validation may name the approved production paths; it may never create or
# change one. Sampled before the first step and compared here, so this reports
# what the run did rather than what the machine already contained. On a host
# where an operator has completed the deployment procedure both paths exist,
# and that is not a finding.
production_path_check() {
  local now
  now="$(production_path_state)"
  if [[ "${now}" != "${PRODUCTION_PATH_STATE_AT_START}" ]]; then
    printf 'Validation changed a production path:\n  before: %s\n  after:  %s\n' \
      "${PRODUCTION_PATH_STATE_AT_START}" "${now}" >&2
    return 1
  fi
  printf '  ok       production paths unchanged (%s)\n' "${now}"
}
run "Production path backstop" production_path_check

# --- 20. platform-model mutation backstop ----------------------------------
# The suites must be read-only with respect to the declared model. This runs
# last so it observes the state the suites left behind.
model_mutation_check() {
  local dirty
  dirty="$(git status --porcelain platform-model)"
  if [[ -n "${dirty}" ]]; then
    printf 'Validation modified platform-model; it must be read-only to tests:\n%s\n' "${dirty}" >&2
    return 1
  fi
  printf '  ok       platform-model unmodified\n'
}
run "Platform model mutation backstop" model_mutation_check

# --- 21. summary -----------------------------------------------------------
section "Summary"
if (( QUICK == 1 )); then
  cat <<EOF
  quick mode omitted:
    - tests/test-platform-model.sh
    - tests/test-initial-collectors.sh
    - tests/test-knowledge-orchestrator.sh
    - tests/test-operational-integrity.sh
    - tests/test-experience-engine.sh
    - tests/test-occurrence-timeline.sh
    - tests/test-remote-collectors.sh
    - tests/test-trust-runtime.sh
    - tests/test-fabric-runtime.sh
    - tests/test-capability-runtime.sh
    - the three Docker Compose renders

  Run without --quick before pushing.
EOF
else
  printf '  all checks ran\n'
fi

# The declared total drifted from the executed count twice during integration,
# each time because a suite added to full mode is skipped in quick mode. A
# hardcoded number cannot notice that, so the script checks its own step count
# and fails rather than printing a total it did not meet.
if (( STEP != TOTAL_STEPS )); then
  printf '\nFAILED: step count mismatch — declared %d, executed %d.\n' \
    "${TOTAL_STEPS}" "${STEP}" >&2
  printf 'Every check ran, but the declared total is wrong. Fix TOTAL_STEPS.\n' >&2
  exit 1
fi

printf '\nValidation passed (%s mode), started %s, %d/%d steps.\n' \
  "$( ((QUICK == 1)) && printf 'quick' || printf 'full')" "${STARTED_AT}" \
  "${STEP}" "${TOTAL_STEPS}"
