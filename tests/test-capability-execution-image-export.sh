#!/usr/bin/env bash
set -Eeuo pipefail

# Validation for the ENG-0005 G11-AI authorised image export ceremony.
#
# STATIC AND UNPRIVILEGED. Nothing here invokes Podman, opens a container
# store, reads production storage, or exports anything. It sources the
# ceremony's identity functions and feeds them fixtures.
#
# WHY THIS SUITE EXISTS
# =====================
# The first ceremony run aborted with "the governed image ... is not in the
# store" against a store that demonstrably held it. `podman images --no-trunc`
# renders `{{.ID}}` as `sha256:<64hex>`, and the check compared that rendering
# against the bare 64-hex identity CIMP resolution produced. The check was
# written against an assumed rendering rather than an observed one.
#
# The fixtures below use the rendering actually captured from the host during
# that run, so the shape under test is the shape Podman emits rather than the
# shape the ceremony hoped for.
#
# The interesting cases are not "does it find the image". They are the four
# ways a looser fix -- a substring match, a prefix strip without validation --
# would have quietly started saying yes to the wrong thing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CEREMONY="${ROOT}/provisioning/execution/g11-ai-image-export.sh"

GOVERNED="5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190"
OTHER="89247302a1401d7f17e9850577840ad13feae663e277b6806ca7f4fba3808f5f"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# FOUND, ABSENT, or REFUSED. Absence and unreadability are deliberately
# different verdicts: "I could not read the inventory" must never be delivered
# as "the image is not there", which is the rule RootlessImageStore already
# applies to the image index it reads.
verdict() {
  local fixture="$1" wanted="$2" output
  if output=$( ( # shellcheck source=/dev/null
                 source "${CEREMONY}"
                 store_holds_image "${fixture}" "${wanted}" ) 2>&1 ); then
    printf 'FOUND'
  elif [[ "${output}" == *ABORT* ]]; then
    printf 'REFUSED'
  else
    printf 'ABSENT'
  fi
}

expect() {
  local label="$1" fixture="$2" wanted="$3" want="$4" got
  got="$(verdict "${fixture}" "${wanted}")"
  if [[ "${got}" == "${want}" ]]; then
    pass "${label}"
  else
    fail "${label} -- expected ${want}, got ${got}"
  fi
}

# --- fixtures, in the rendering the host actually produced --------------------

# Trimmed from the real capture: `{{.ID}} {{.Repository}}:{{.Tag}}` under
# --no-trunc, which prefixes the algorithm.
cat >"${WORK}/present.txt" <<EOF
sha256:${OTHER} <none>:<none>
sha256:${GOVERNED} localhost/kyri-capability-execution:g5
sha256:a3ef70eee8c906c4604f53bb1874ab5bf4922bab9c5f0ba6b6d9ce126f589b69 <none>:<none>
EOF

cat >"${WORK}/absent.txt" <<EOF
sha256:${OTHER} <none>:<none>
sha256:a3ef70eee8c906c4604f53bb1874ab5bf4922bab9c5f0ba6b6d9ce126f589b69 <none>:<none>
EOF

# The governed value present only as a tag. A substring match would say yes.
cat >"${WORK}/tag-only.txt" <<EOF
sha256:${OTHER} localhost/kyri-capability-execution:${GOVERNED}
EOF

# An identity that contains the governed value and is not it. A prefix match,
# or a strip without a length check, would say yes.
cat >"${WORK}/superstring.txt" <<EOF
sha256:${GOVERNED}deadbeef <none>:<none>
EOF

# What the inventory looks like if --no-trunc is ever dropped. Twelve hex
# characters are not an identity, and treating them as absence would report a
# present image as missing -- the very failure this suite was written for.
printf '%s <none>:<none>\n' "${GOVERNED:0:12}" >"${WORK}/truncated.txt"

cat >"${WORK}/unreadable.txt" <<EOF
sha256:${OTHER} <none>:<none>
<none> <none>:<none>
EOF

# Uppercase is not the canonical rendering and is not silently folded.
cat >"${WORK}/uppercase.txt" <<EOF
sha256:$(printf '%s' "${GOVERNED}" | tr 'a-f' 'A-F') <none>:<none>
EOF

# --- the root cause -----------------------------------------------------------

expect "the governed image is found in the rendering Podman actually emits" \
  "${WORK}/present.txt" "${GOVERNED}" FOUND

expect "an inventory without the governed image reports absence" \
  "${WORK}/absent.txt" "${GOVERNED}" ABSENT

# --- the four ways a looser fix would have gone wrong -------------------------

# A well-formed identity that is simply not in this inventory. Paired with the
# next case so "ABSENT" is shown to mean absence rather than a check that never
# matches anything.
expect "another SHA-256 image is not mistaken for the governed one" \
  "${WORK}/present.txt" "0ffb354f0d2060fda4bf688e41addb15b92a88fbcc4c7a392fd41f28933cb769" ABSENT

expect "a second image that is present is also found" \
  "${WORK}/present.txt" "${OTHER}" FOUND

expect "the governed value appearing only as a tag is not a match" \
  "${WORK}/tag-only.txt" "${GOVERNED}" ABSENT

expect "an identity containing the governed value is not a match" \
  "${WORK}/superstring.txt" "${GOVERNED}" REFUSED

expect "a truncated inventory is refused, not reported as absence" \
  "${WORK}/truncated.txt" "${GOVERNED}" REFUSED

expect "an unreadable identity is refused, not skipped past" \
  "${WORK}/unreadable.txt" "${GOVERNED}" REFUSED

expect "an uppercase identity is refused rather than folded" \
  "${WORK}/uppercase.txt" "${GOVERNED}" REFUSED

# --- the rendering the ceremony asks for --------------------------------------

run_static() {
  local label="$1" script="$2" actual
  if actual="$(cd "${ROOT}" && python3 -c "${script}" 2>&1)"; then
    if [[ "${actual}" == "OK" ]]; then pass "${label}"; else
      fail "${label} -- expected OK, got: ${actual}"; fi
  else
    fail "${label} -- raised: ${actual}"
  fi
}

run_static "the inventory is requested untruncated, so identities are complete" "
from pathlib import Path
text = Path('provisioning/execution/g11-ai-image-export.sh').read_text(encoding='utf-8')
# Without --no-trunc Podman emits a 12-character short ID, which is not an
# identity and which this ceremony must never compare against.
assert text.count('--no-trunc') >= 2, text.count('--no-trunc')
assert '{{.ID}}' in text, 'the inventory does not select the image ID'
print('OK')
"

run_static "the archive identity comparison stays bare-to-bare" "
from pathlib import Path
text = Path('provisioning/execution/g11-ai-image-export.sh').read_text(encoding='utf-8')
# The OCI config digest is split on ':' before comparison, so it is already the
# bare form the governed constant is written in. This pairing is correct and is
# pinned so a later sweep for 'sha256:' handling does not 'fix' it.
assert 'split(\":\", 1)[1]' in text, 'the config digest is no longer normalised'
assert '\"\$config_digest\" = \"\$GOVERNED_IMAGE\"' in text, \
    'the archive identity comparison changed shape'
print('OK')
"

run_static "the ceremony still reaches no mutating Podman verb" "
import re
from pathlib import Path
text = Path('provisioning/execution/g11-ai-image-export.sh').read_text(encoding='utf-8')
for verb in ('podman pull', 'podman build', 'podman load', 'podman import',
             'podman tag', 'podman rmi', 'podman rm ', 'podman prune',
             'podman run', 'podman create', 'podman start'):
    assert verb not in text, verb
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution G11-AI image export validation passed.\n'
else
  printf 'Capability execution G11-AI image export validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
