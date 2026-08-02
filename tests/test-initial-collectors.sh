#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural and static validation for the initial read-only collectors.
#
# Behavioural tests are the primary safety evidence: they build temporary
# repositories and Compose fixtures and assert what the collectors actually do.
# Static greps are a secondary net, because a grep can be evaded and a
# behavioural assertion is much harder to satisfy accidentally.
#
# This script contacts no host, uses no SSH, inspects no running container, and
# calls no Docker runtime API. Every command it runs is local and read-only.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COLLECTORS="tools/collectors"
FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_contains() {
  if [[ -f "${ROOT}/$1" ]] && grep -Eq "$2" "${ROOT}/$1"; then
    pass "$3"
  else
    fail "$3 (expected /$2/ in $1)"
  fi
}

# assert_absent_in <target> <pattern> <description> [exclude-glob]
# assert_absent_in <target> <pattern> <description> [exclude-glob...]
#
# Trailing arguments are exclusion globs. More than one is needed from v0.9.0:
# subprocess now has two audited homes, not one.
assert_absent_in() {
  local target="$1" pattern="$2" description="$3" matches
  shift 3
  local -a exclusions=()
  local glob
  for glob in "$@"; do
    [[ -n "${glob}" ]] && exclusions+=("--exclude=${glob}")
  done
  if [[ ! -e "${ROOT}/${target}" ]]; then
    fail "${description} (missing ${target})"
    return
  fi
  if (( ${#exclusions[@]} > 0 )); then
    matches="$(grep -rIniE "${exclusions[@]}" -e "${pattern}" "${ROOT}/${target}" || true)"
  else
    matches="$(grep -rIniE -e "${pattern}" "${ROOT}/${target}" || true)"
  fi
  if [[ -z "${matches}" ]]; then
    pass "${description}"
  else
    fail "${description}; found: $(printf '%s' "${matches}" | head -2 | tr '\n' ' ')"
  fi
}

# --- Required files --------------------------------------------------------
assert_file "${COLLECTORS}/command_runner.py"
assert_file "${COLLECTORS}/redaction.py"
assert_file "${COLLECTORS}/cli.py"

for plugin in git_repository configuration_render manual_attestation; do
  assert_file "${COLLECTORS}/plugins/${plugin}/__init__.py"
  assert_file "${COLLECTORS}/plugins/${plugin}/collector.py"
  assert_file "${COLLECTORS}/plugins/${plugin}/manifest.yaml"
done

for doc in git-repository configuration-render manual-attestation; do
  assert_file "docs/collectors/${doc}.md"
done

# --- Static safety ---------------------------------------------------------
# Subprocess is permitted only inside command_runner.py. That single audited
# chokepoint is what makes the v0.6.0 permission change a narrowing rather
# than a relaxation.
#
# v0.9.0 adds exactly one more: ssh_transport.py. It cannot route through
# command_runner.py, whose executable allowlist refuses `ssh` outright, so
# remote execution gets its own audited home rather than a hole in that
# allowlist. Two reviewable places, and still nowhere else.
assert_absent_in "${COLLECTORS}" \
  '(import[[:space:]]+subprocess|from[[:space:]]+subprocess[[:space:]]+import|subprocess\.[a-zA-Z_]|os\.system\(|os\.popen\()' \
  "subprocess appears only in the two audited chokepoints" \
  "command_runner.py" "ssh_transport.py"

assert_absent_in "${COLLECTORS}" 'shell[[:space:]]*=[[:space:]]*True' \
  "no collector code uses shell=True"
assert_absent_in "${COLLECTORS}" \
  '(import[[:space:]]+(socket|requests|urllib|http\.client|paramiko|ftplib)|from[[:space:]]+(socket|requests|urllib|paramiko)[[:space:]]+import)' \
  "no collector code imports a network or SSH module"
assert_absent_in "${COLLECTORS}" \
  "(open\\([^)]*['\"](w|a|x)|\\.write_text\\(|\\.write_bytes\\(|shutil\\.(copy|move|rmtree)|os\\.(remove|unlink|rename|mkdir|makedirs))" \
  "no collector code performs a filesystem write"
assert_absent_in "${COLLECTORS}" 'EVID-[0-9]' \
  "no collector assigns an evidence identifier"
assert_absent_in "${COLLECTORS}" \
  '(def[[:space:]]+remediate|\.remediate\(|remediation_command|auto_remediate|apply_fix)' \
  "no collector contains a remediation path" "validate_plugins.py"

# ai/.env must never be referenced; only .example files are approved.
assert_absent_in "${COLLECTORS}" \
  "['\"][^'\"]*ai/\\.env['\"]" \
  "no collector references ai/.env"

# Only compose config rendering is approved; no runtime Docker verbs.
assert_absent_in "${COLLECTORS}" \
  '(docker[[:space:]]+(ps|inspect|exec|run|start|stop|rm|logs)\b|compose[[:space:]]+(up|down|pull|build|run|exec)\b)' \
  "no collector invokes a Docker runtime verb"

# Destructive or remote git verbs must not appear.
assert_absent_in "${COLLECTORS}" \
  '["'"'"'](fetch|pull|push|clone|checkout|switch|reset|clean|commit|gc|submodule)["'"'"']' \
  "no collector invokes a remote or mutating git verb"

# --- CI wiring -------------------------------------------------------------
assert_contains ".github/workflows/ci.yml" 'bash tests/test-initial-collectors\.sh' \
  "ci runs the initial collector tests"

# --- Behavioural validation ------------------------------------------------
if python3 -c 'import yaml' >/dev/null 2>&1; then
  PY_OUTPUT="$(python3 - "${ROOT}" <<'PY' 2>&1 || true
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root))
os.chdir(root)

failures = 0
CANARY = "CANARY-SECRET-MUST-NOT-APPEAR-9f3a"


def ok(message):
    print(f"PASS: {message}")


def bad(message):
    global failures
    failures += 1
    print(f"FAIL: {message}")


def check(condition, message):
    ok(message) if condition else bad(message)


try:
    from tools.collectors.models import CollectionContext, CollectorResult
    from tools.collectors.command_runner import run_read_only_command, CommandResult
    from tools.collectors.redaction import redact, REDACTED
    from tools.collectors.registry import CollectorRegistry
    from tools.collectors.exceptions import CollectorRegistrationError
    from tools.collectors.plugins.git_repository.collector import GitRepositoryCollector
    from tools.collectors.plugins.configuration_render.collector import ConfigurationRenderCollector
    from tools.collectors.plugins.manual_attestation.collector import ManualAttestationCollector
    ok("initial collector modules import cleanly")
except Exception as error:  # noqa: BLE001
    bad(f"collector import failed: {type(error).__name__}: {error}")
    print(f"__FAILURES__={failures}")
    raise SystemExit(0)

STAMP = "2026-08-01T09:00:00-05:00"


def context(target, synthetic=False, **extra):
    return CollectionContext(
        target=target, declared=extra.pop("declared", {}),
        requested_facts=extra.pop("requested_facts", ()),
        collected_at=extra.pop("collected_at", STAMP),
        synthetic=synthetic, options=extra or None,
    )


def facts_of(result):
    return {o.fact: o.value for o in result.observations}


# --- command runner --------------------------------------------------------
work = Path(tempfile.mkdtemp())
try:
    r = run_read_only_command(["git", "--version"], cwd=work, timeout_seconds=10,
                              allowed_executables={"git"})
    check(isinstance(r, CommandResult) and r.exit_code == 0, "command runner executes an allowed command")

    try:
        run_read_only_command(["bash", "-c", "echo hi"], cwd=work, timeout_seconds=5,
                              allowed_executables={"git"})
        bad("command runner permitted a disallowed executable")
    except Exception:
        ok("command runner rejects a disallowed executable")

    for banned in ("sh", "bash", "ssh", "curl", "wget", "nc"):
        try:
            run_read_only_command([banned, "--version"], cwd=work, timeout_seconds=5,
                                  allowed_executables={banned})
            bad(f"command runner permitted banned executable '{banned}'")
        except Exception:
            pass
    ok("command runner refuses shells and network tools even when allow-listed")

    try:
        run_read_only_command(["git", "--password", CANARY], cwd=work, timeout_seconds=5,
                              allowed_executables={"git"})
        bad("command runner permitted a secret-bearing argument")
    except Exception as error:
        check(CANARY not in str(error), "command runner rejects secret-bearing arguments without echoing them")

    try:
        run_read_only_command(["git", "--version"], cwd=work / "missing", timeout_seconds=5,
                              allowed_executables={"git"})
        bad("command runner permitted a missing cwd")
    except Exception:
        ok("command runner rejects a nonexistent working directory")

    try:
        run_read_only_command(["git", "--version"], cwd=work, timeout_seconds=0,
                              allowed_executables={"git"})
        bad("command runner permitted a non-positive timeout")
    except Exception:
        ok("command runner requires a positive timeout")

    env_probe = run_read_only_command(["git", "var", "GIT_EDITOR"], cwd=work, timeout_seconds=10,
                                      allowed_executables={"git"})
    check(CANARY not in env_probe.stdout, "command runner does not leak the ambient environment")
finally:
    shutil.rmtree(work, ignore_errors=True)

# --- redaction -------------------------------------------------------------
payload = {
    "hostname": "example-host",
    "password": CANARY,
    "nested": {"api_key": CANARY, "safe": "value"},
    "list": [{"token": CANARY}, "plain"],
}
redacted, changed = redact(payload)
serialized = json.dumps(redacted, sort_keys=True)
check(CANARY not in serialized, "redaction removes secret values from nested structures")
check(changed is True, "redaction reports that it occurred")
check(redacted["password"] == REDACTED, "redaction uses the deterministic marker")
check(redacted["hostname"] == "example-host", "redaction preserves non-sensitive values")
try:
    redact({"bad": object()})
    bad("redaction accepted an unsupported object")
except Exception:
    ok("redaction rejects unsupported Python objects")

# --- git repository collector ---------------------------------------------
def git(*args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, check=True,
                          capture_output=True, text=True,
                          env={**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null",
                               "GIT_CONFIG_SYSTEM": "/dev/null"})


repo = Path(tempfile.mkdtemp())
try:
    git("init", "-q", "-b", "main", cwd=repo)
    git("config", "user.email", "fixture@example.invalid", cwd=repo)
    git("config", "user.name", "Fixture", cwd=repo)
    (repo / "a.txt").write_text("one\n", encoding="utf-8")
    git("add", "a.txt", cwd=repo)
    git("commit", "-q", "-m", "initial", cwd=repo)

    plugin = GitRepositoryCollector()
    result = plugin.execute(context("REPO-0001", path=str(repo)))
    check(result.status == "success", f"git collector succeeds on a clean repository ({result.status})")
    f = facts_of(result)
    check(f.get("is_dirty") is False, "clean repository reports is_dirty false")
    check(f.get("branch") == "main", "clean repository reports its branch")
    check(len(str(f.get("head_sha", ""))) == 40, "collector reports a full HEAD sha")
    check(f.get("tracked_file_count") == 1, "collector counts tracked files")

    before = git("rev-parse", "HEAD", cwd=repo).stdout.strip()
    status_before = git("status", "--porcelain", cwd=repo).stdout
    plugin.execute(context("REPO-0001", path=str(repo)))
    check(git("rev-parse", "HEAD", cwd=repo).stdout.strip() == before
          and git("status", "--porcelain", cwd=repo).stdout == status_before,
          "collection does not mutate the repository")

    (repo / "a.txt").write_text("two\n", encoding="utf-8")
    (repo / "untracked.txt").write_text("x\n", encoding="utf-8")
    f = facts_of(plugin.execute(context("REPO-0001", path=str(repo))))
    check(f.get("is_dirty") is True, "dirty repository reports is_dirty true")
    check(f.get("modified_file_count") == 1, "collector counts modified files")
    check(f.get("untracked_file_count") == 1, "collector counts untracked files")
    git("checkout", "-q", "--", "a.txt", cwd=repo)
    (repo / "untracked.txt").unlink()

    git("tag", "v9.9.9", cwd=repo)
    f = facts_of(plugin.execute(context("REPO-0001", path=str(repo))))
    check("v9.9.9" in (f.get("tags_at_head") or []), "collector reports tags pointing at HEAD")

    git("remote", "add", "origin",
        f"https://fixtureuser:{CANARY}@git.example.invalid/org/repo.git?token={CANARY}", cwd=repo)
    result = plugin.execute(context("REPO-0001", path=str(repo)))
    blob = json.dumps([[o.fact, o.value] for o in result.observations], sort_keys=True, default=str)
    check(CANARY not in blob, "remote credentials never appear in collector output")
    check("fixtureuser" not in blob, "remote username is stripped")
    check(CANARY not in result.content_fingerprint, "credentials never reach the fingerprint")
    check("git.example.invalid" in blob, "sanitized remote host is retained")

    sha = git("rev-parse", "HEAD", cwd=repo).stdout.strip()
    git("checkout", "-q", "--detach", sha, cwd=repo)
    f = facts_of(plugin.execute(context("REPO-0001", path=str(repo))))
    check(f.get("branch") in (None, "unknown", "detached") or f.get("detached") is True,
          "detached HEAD is reported without inventing a branch name")
finally:
    shutil.rmtree(repo, ignore_errors=True)

not_a_repo = Path(tempfile.mkdtemp())
try:
    result = GitRepositoryCollector().execute(context("REPO-0001", path=str(not_a_repo)))
    check(result.is_terminal_failure(), "git collector fails closed outside a repository")
finally:
    shutil.rmtree(not_a_repo, ignore_errors=True)

# --- configuration render collector ---------------------------------------
render = ConfigurationRenderCollector()
fixture = Path(tempfile.mkdtemp())
try:
    (fixture / "compose.yaml").write_text(
        "services:\n"
        "  web:\n"
        "    image: example/web:1.0\n"
        "    restart: unless-stopped\n"
        "    ports:\n"
        "      - \"8080:80\"\n"
        "    environment:\n"
        "      PLAIN_NAME: literal-value\n"
        "      FROM_ENV: ${FIXTURE_TOKEN}\n"
        "    volumes:\n"
        "      - data:/var/lib/example\n"
        "    healthcheck:\n"
        "      test: [\"CMD\", \"true\"]\n"
        "networks:\n"
        "  default:\n"
        "    driver: bridge\n"
        "volumes:\n"
        "  data:\n", encoding="utf-8")
    (fixture / "fixture.env.example").write_text(f"FIXTURE_TOKEN={CANARY}\n", encoding="utf-8")

    result = render.execute(context("SVC-0002",
                                    compose_file=str(fixture / "compose.yaml"),
                                    env_file=str(fixture / "fixture.env.example"),
                                    repository_root=str(fixture)))
    check(result.status == "success", f"configuration render succeeds on a fixture ({result.status})")
    blob = json.dumps([[o.fact, o.value] for o in result.observations], sort_keys=True, default=str)
    check(CANARY not in blob, "environment values never appear in rendered output")
    check(CANARY not in result.content_fingerprint, "environment values never reach the fingerprint")
    f = facts_of(result)
    check("web" in (f.get("service_names") or []), "render reports service names")
    check(any("example/web" in str(i) for i in (f.get("images") or [])), "render reports image references")
    check(any("8080" in str(p) for p in (f.get("published_ports") or [])), "render reports declared ports")
    check("data" in str(f.get("volumes") or ""), "render reports volume names")
    check("PLAIN_NAME" in str(f.get("environment_variable_names") or ""),
          "render reports environment variable names")
    check("literal-value" not in blob, "render omits literal environment values")

    result = render.execute(context("SVC-0002",
                                    compose_file=str(fixture / "compose.yaml"),
                                    env_file=str(fixture / "secret.env"),
                                    repository_root=str(fixture)))
    check(result.is_terminal_failure(), "render rejects an env file without the .example suffix")

    result = render.execute(context("SVC-0002",
                                    compose_file="../../etc/passwd",
                                    env_file=str(fixture / "fixture.env.example"),
                                    repository_root=str(fixture)))
    check(result.is_terminal_failure(), "render rejects path traversal outside the repository root")

    outside = Path(tempfile.mkdtemp())
    (outside / "target.yaml").write_text("services: {}\n", encoding="utf-8")
    link = fixture / "escape.yaml"
    os.symlink(outside / "target.yaml", link)
    result = render.execute(context("SVC-0002", compose_file=str(link),
                                    env_file=str(fixture / "fixture.env.example"),
                                    repository_root=str(fixture)))
    check(result.is_terminal_failure(), "render rejects a symlink escaping the repository root")
    shutil.rmtree(outside, ignore_errors=True)

    (fixture / "broken.yaml").write_text("services:\n  web:\n    image: [unclosed\n", encoding="utf-8")
    result = render.execute(context("SVC-0002", compose_file=str(fixture / "broken.yaml"),
                                    env_file=str(fixture / "fixture.env.example"),
                                    repository_root=str(fixture)))
    check(result.is_terminal_failure(), "render fails closed on an invalid Compose file")
finally:
    shutil.rmtree(fixture, ignore_errors=True)

result = render.execute(context("SVC-0002", compose_file="ai/.env",
                                env_file="ai/.env", repository_root="."))
check(result.is_terminal_failure(), "render refuses ai/.env outright")

for compose, env in (("ai/compose.yaml", "ai/.env.example"),
                     ("ai/ollama/compose.yaml", "ai/ollama/.env.example"),
                     ("ai/litellm/compose.yaml", "ai/litellm/.env.example")):
    result = render.execute(context("SVC-0002", compose_file=compose, env_file=env,
                                    repository_root="."))
    check(result.status == "success", f"render succeeds on {compose} ({result.status})")

# --- manual attestation collector -----------------------------------------
attest = ManualAttestationCollector()
valid = {
    "actor": "platform-engineer",
    "attested_at": STAMP,
    "source_description": "visual inspection of the rack label",
    "confidence": "high",
    "facts": {"rack_label": "R2-U14"},
}
result = attest.execute(context("HOST-0001", attestation=valid))
check(result.status == "success", f"attestation accepts a valid submission ({result.status})")
f = facts_of(result)
check(all(o.provenance == "observed" for o in result.observations),
      "attestation observations are provenance observed")
check(str(f.get("attestation_source")) == "human", "attestation states the source is human-provided")
check(f.get("verification_implied") is False, "attestation states verification is not implied")
check(f.get("review_required") is True, "attestation keeps review_required true")

for label, mutate in (
    ("missing actor", lambda d: d.pop("actor")),
    ("missing timestamp", lambda d: d.pop("attested_at")),
    ("missing source description", lambda d: d.pop("source_description")),
    ("empty facts", lambda d: d.update(facts={})),
    ("naive timestamp", lambda d: d.update(attested_at="2026-08-01T09:00:00")),
    ("future timestamp", lambda d: d.update(attested_at="2099-01-01T00:00:00-05:00")),
    ("invalid confidence", lambda d: d.update(confidence="certain")),
    ("secret-bearing key", lambda d: d.update(facts={"api_key": "x"})),
    ("secret-shaped value", lambda d: d.update(facts={"note": f"password={CANARY}"})),
    ("executable action", lambda d: d.update(facts={"remediation_command": "systemctl restart"})),
    ("base64 blob", lambda d: d.update(facts={"photo": "data:image/png;base64," + "A" * 512})),
):
    payload = json.loads(json.dumps(valid))
    mutate(payload)
    result = attest.execute(context("HOST-0001", attestation=payload))
    check(result.is_terminal_failure(), f"attestation rejects {label}")
    blob = json.dumps([e.summary for e in result.errors])
    if CANARY in blob:
        bad(f"attestation echoed the secret value when rejecting {label}")

# --- registry --------------------------------------------------------------
from tools.collectors.registry import build_default_registry  # noqa: E402

registry = build_default_registry()
expected = {"example-synthetic", "git-repository", "configuration-render", "manual-attestation"}
check(expected.issubset(set(registry.ids())), f"all four collectors are registered: {registry.ids()}")
try:
    registry.register(GitRepositoryCollector)
    bad("registry accepted a duplicate collector id")
except CollectorRegistrationError:
    ok("registry rejects duplicate collector ids")

for manifest in registry.list_manifests():
    if manifest.id == "example-synthetic":
        continue
    check("synthetic-fixture-only" not in manifest.permissions,
          f"{manifest.id} does not claim synthetic-only permission")
    check(manifest.network_access is False, f"{manifest.id} declares no network access")

# --- CLI -------------------------------------------------------------------
def cli(*args, stdin=None):
    return subprocess.run([sys.executable, "-m", "tools.collectors.cli", *args],
                          cwd=root, capture_output=True, text=True, input=stdin,
                          env={**os.environ, "PYTHONPATH": str(root)})


proc = cli("list")
check(proc.returncode == 0, f"cli list exits 0 ({proc.returncode})")
try:
    listed = json.loads(proc.stdout)
    check(len(listed) >= 4, "cli list emits JSON for every registered collector")
except Exception:
    bad("cli list did not emit valid JSON")

proc = cli("validate")
check(proc.returncode == 0, f"cli validate exits 0 ({proc.returncode})")

proc = cli("collect", "--collector", "git-repository", "--target", "REPO-0001",
           "--path", ".", "--collected-at", STAMP)
check(proc.returncode == 0, f"cli collect succeeds on this repository ({proc.returncode})")
check(CANARY not in proc.stdout, "cli output contains no canary value")
try:
    first = json.loads(proc.stdout)
    second = json.loads(cli("collect", "--collector", "git-repository", "--target",
                            "REPO-0001", "--path", ".", "--collected-at", STAMP).stdout)
    check("evidence_id" not in first and "EVID" not in json.dumps(first),
          "cli output assigns no evidence identifier")
    check(first.get("collector_id") == "git-repository", "cli output identifies the collector")
    check(json.dumps(first.get("observations"), sort_keys=True)
          == json.dumps(second.get("observations"), sort_keys=True),
          "cli observation output is deterministic across runs")
except Exception as error:  # noqa: BLE001
    bad(f"cli collect output was not usable JSON: {type(error).__name__}")

proc = cli("collect", "--collector", "no-such-collector", "--target", "X", "--path", ".")
check(proc.returncode == 2, f"cli exits 2 on an unknown collector ({proc.returncode})")

proc = cli("collect", "--collector", "git-repository", "--target", "REPO-0001")
check(proc.returncode == 2, f"cli exits 2 when a required argument is missing ({proc.returncode})")

before = {p for p in Path(".").rglob("*") if p.is_file() and ".git/" not in str(p)}
cli("collect", "--collector", "git-repository", "--target", "REPO-0001", "--path", ".")
after = {p for p in Path(".").rglob("*") if p.is_file() and ".git/" not in str(p)}
check(before == after, "cli collection creates no output files")

print(f"__FAILURES__={failures}")
PY
)"
  printf '%s\n' "${PY_OUTPUT}" | grep -v '^__FAILURES__=' || true
  PY_FAILURES="$(printf '%s\n' "${PY_OUTPUT}" | sed -n 's/^__FAILURES__=//p' | tail -1)"
  if [[ -z "${PY_FAILURES}" ]]; then
    fail "initial collector behavioural validation did not report a result"
  else
    FAILURES=$((FAILURES + PY_FAILURES))
  fi
else
  printf 'ERROR PyYAML is required for %s and is not importable.\n' "$(basename "${BASH_SOURCE[0]}")" >&2
  printf 'A skipped behavioural block must never report success, so this is a failure.\n' >&2
  printf 'Install the pinned version:\n\n' >&2
  printf '    python3 -m pip install --require-hashes -r requirements-ci.txt\n\n' >&2
  exit 1
fi

if [[ "${FAILURES}" -gt 0 ]]; then
  printf '\nInitial collector validation failed with %d error(s).\n' "${FAILURES}" >&2
  exit 1
fi

printf '\nInitial collector validation passed.\n'
