#!/usr/bin/env bash
set -Eeuo pipefail

# Static validation for the ENG-0005 production execution image, increment T19.
#
# STATIC ONLY. Nothing here builds, pulls, loads, inspects, or admits an image.
# There is no podman invocation, no network access, and no CIMP. Building is
# gate G5 and admission is a governed operator step after it; this suite reads
# two files and asserts what they say.
#
# THE DEFINITION MUST NOT NAME A MUTABLE BASE. A floating tag in an
# authoritative definition means the image that was admitted and the image that
# was built are the same text and different bytes, so BASE_IMAGE carries no
# default and the procedure refuses anything that is not digest-pinned.
#
# THE FINAL IMAGE CARRIES NO TOOLING. §27 forbids a package manager, shell,
# compiler, pip, curl, wget, sudo, or SSH in the runtime image. It does not
# forbid a build stage from having them -- and for this image none is needed.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §9, §27
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md  T19

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

run_case() {
  local label="$1" script="$2" actual
  if actual="$(cd "${ROOT}" && python3 -c "${script}" 2>&1)"; then
    if [[ "${actual}" == "OK" ]]; then
      pass "${label}"
    else
      fail "${label} -- expected OK, got: ${actual}"
    fi
  else
    fail "${label} -- raised: ${actual}"
  fi
}

PRELUDE="
import re
from pathlib import Path

DEFINITION = Path('provisioning/image/Containerfile')
PROCEDURE = Path('provisioning/image/README.md')
assert DEFINITION.exists(), 'the Containerfile is absent'
assert PROCEDURE.exists(), 'the admission procedure is absent'

TEXT = DEFINITION.read_text(encoding='utf-8')
PROSE = PROCEDURE.read_text(encoding='utf-8')

# Instructions only: the comments explain what is forbidden, so scanning them
# as if they were instructions would fail the file for describing itself.
LINES = [line.strip() for line in TEXT.splitlines()
         if line.strip() and not line.strip().startswith('#')]
INSTRUCTIONS = ' '.join(LINES)
"

# --- the base is supplied, pinned, and has no fallback -----------------------

run_case "the base is a build argument with no default value" "${PRELUDE}
arguments = [line for line in LINES if line.startswith('ARG ')]
assert arguments == ['ARG BASE_IMAGE'], arguments
assert '=' not in arguments[0], 'the base argument carries a default'
print('OK')
"

run_case "the only FROM uses that argument and names no image itself" "${PRELUDE}
froms = [line for line in LINES if line.upper().startswith('FROM ')]
assert froms == ['FROM \${BASE_IMAGE}'], froms
print('OK')
"

run_case "no tag, digest, or registry is baked into the definition" "${PRELUDE}
for token in ('latest', 'cgr.dev', 'docker.io', 'gcr.io', 'quay.io',
              'python:3', 'alpine', 'debian', 'ubuntu', 'sha256:'):
    assert token not in INSTRUCTIONS, token
# A tag anywhere in an instruction would be a mutable reference.
assert not re.search(r'FROM\\s+\\S+:', INSTRUCTIONS), 'a tagged FROM is present'
print('OK')
"

run_case "the definition carries no second build stage and no image alias" "${PRELUDE}
assert ' AS ' not in INSTRUCTIONS.upper(), 'a build stage alias is present'
assert 'COPY --from' not in INSTRUCTIONS, 'a cross-stage copy is present'
print('OK')
"

# --- the final image carries no tooling --------------------------------------

run_case "the definition installs nothing and runs nothing" "${PRELUDE}
for instruction in ('RUN', 'ADD', 'COPY'):
    assert not any(line.upper().startswith(instruction + ' ') for line in LINES), \\
        instruction
for token in ('apk', 'apt', 'apt-get', 'dpkg', 'dnf', 'yum', 'pip', 'pip3',
              'curl', 'wget', 'sudo', 'ssh', 'gcc', 'make', 'shell',
              '/bin/sh', 'bash'):
    assert token not in INSTRUCTIONS, token
print('OK')
"

run_case "the Track-B Alpine digest is referenced nowhere" "${PRELUDE}
assert 'alpine' not in TEXT.lower(), 'the definition mentions Alpine'
for token in ('alpine', 'Alpine'):
    assert token not in PROSE, 'the procedure mentions Alpine'
print('OK')
"

# --- identity and paths match the accepted profile ---------------------------

run_case "the image declares a fixed non-root default user" "${PRELUDE}
users = [line for line in LINES if line.upper().startswith('USER ')]
assert users == ['USER 65532:65532'], users
assert 'USER 0' not in INSTRUCTIONS and 'USER root' not in INSTRUCTIONS
print('OK')
"

run_case "the inherited entrypoint is cleared so T12 owns the command" "${PRELUDE}
assert 'ENTRYPOINT []' in INSTRUCTIONS, 'the entrypoint is not cleared'
assert 'CMD []' in INSTRUCTIONS, 'the command is not cleared'
print('OK')
"

run_case "the mount destinations match the accepted profile exactly" "${PRELUDE}
from tools.capability.execution.worker import (
    PACKAGE_DESTINATION, PAYLOAD_DESTINATION, OUTPUT_DESTINATION)
for destination in (PACKAGE_DESTINATION, OUTPUT_DESTINATION):
    assert destination in INSTRUCTIONS, destination
# The payload is a file inside its parent, so the parent is what exists.
assert PAYLOAD_DESTINATION.rsplit('/', 1)[0] in INSTRUCTIONS, PAYLOAD_DESTINATION
print('OK')
"

run_case "the governed interpreter path is the one T12 executes" "${PRELUDE}
from tools.capability.execution.worker import CONTAINER_INTERPRETER
assert CONTAINER_INTERPRETER == '/usr/bin/python', CONTAINER_INTERPRETER
assert CONTAINER_INTERPRETER in PROSE, \\
    'the procedure does not state the interpreter path'
assert '/usr/bin/python3' not in PROSE.replace('/usr/bin/python3 ', 'X') \\
    or 'WORKER_INTERPRETER' in PROSE, \\
    'the procedure confuses the container and host interpreters'
print('OK')
"

# --- the admission procedure ------------------------------------------------

run_case "the procedure requires a digest-pinned base and refuses a tag" "${PRELUDE}
assert 'cgr.dev/chainguard/python@sha256:' in PROSE, \\
    'the required reference form is not stated'
assert 'no default' in PROSE, 'the absent default is not stated'
for phrase in ('discovery', 'float'):
    assert phrase in PROSE, phrase
print('OK')
"

run_case "the procedure pins Python 3.14.6 and verifies it three ways" "${PRELUDE}
assert PROSE.count('3.14.6') >= 3, PROSE.count('3.14.6')
for phrase in ('SBOM', 'OCI base digest', 'do not admit'):
    assert phrase.lower() in PROSE.lower(), phrase
print('OK')
"

run_case "the procedure allows a symlink and states what must be proven" "${PRELUDE}
assert 'symlink' in PROSE.lower(), 'symlink handling is unstated'
for phrase in ('inside', 'regular executable file',
               'SHA-256 of the resolved interpreter'):
    assert phrase.lower() in PROSE.lower(), phrase
print('OK')
"

run_case "the procedure lists the final-image absence checks" "${PRELUDE}
for token in ('apk', 'apt-get', 'dpkg', 'pip', 'bash', 'busybox', 'gcc',
              'sudo', 'sshd', 'curl', 'wget'):
    assert token in PROSE, token
print('OK')
"

run_case "admission is an operator procedure and never automated" "${PRELUDE}
for phrase in ('operator procedure, not an automated step',
               'execution_image_unavailable',
               'cannot modify the allowlist'):
    assert phrase in PROSE, phrase
assert 'CIMP' in PROSE
print('OK')
"

run_case "the unresolved output quota is carried forward, not claimed solved" "${PRELUDE}
assert 'quota' in PROSE.lower(), 'the open quota item is not carried forward'
for phrase in ('unresolved', 'does not solve it'):
    assert phrase.lower() in PROSE.lower(), phrase
print('OK')
"

# --- nothing here builds anything -------------------------------------------

run_case "neither artefact invokes a container runtime" "${PRELUDE}
# Assembled rather than written out, so this suite does not contain the very
# literals it is asserting are absent elsewhere.
for runtime in ('pod' + 'man', 'dock' + 'er', 'build' + 'ah'):
    for verb in ('build', 'pull', 'load', 'import', 'run'):
        token = runtime + ' ' + verb
        assert token not in TEXT, token
        assert token not in PROSE.replace('and admits this', ''), token
assert 'Nothing in this repository builds' in PROSE, \
    'the procedure does not disclaim building'
print('OK')
"

run_case "no image was built, pulled, loaded, or admitted" "${PRELUDE}
import os
# The rootless store and the provisioned runtime are both still absent, which
# is what G4 and G5 remaining closed looks like from here.
assert not Path('/run/kyri').exists(), 'a runtime directory exists'
assert not Path('/etc/sudoers.d/kyri-exec').exists(), 'a sudoers drop-in exists'
assert os.getuid() != 0
print('OK')
"

run_case "the image suite runs in local validation and in CI" "${PRELUDE}
validation = Path('tools/dev/run-validation.sh').read_text(encoding='utf-8')
ci = Path('.github/workflows/ci.yml').read_text(encoding='utf-8')
name = 'tests/test-capability-execution-image.sh'
assert name in validation, 'local validation does not run the image suite'
assert name in ci, 'ci does not run the image suite'
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution T19 image definition validation passed.\n'
else
  printf 'Capability execution T19 image definition validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
