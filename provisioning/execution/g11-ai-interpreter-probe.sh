#!/usr/bin/env bash
set -Eeuo pipefail

# Close the three CIMP-000001 build-input fields that image metadata cannot
# answer: interpreter_link, interpreter_target, interpreter_sha256.
#
# G11-AF marked these UNVERIFIABLE because they are facts about the image's
# *filesystem*, and `podman image inspect` reports configuration rather than
# content. They are the last three of the fifteen build-input fields, and the
# brief requires them closed before CIMP-000001 may become a production backend.
#
# ISOLATED, AND NOT THE PRODUCTION STORE. This takes the exported OCI archive
# and loads it into a disposable root/runroot of its own. It never reads
# /data/kyri/capability, and the production graphroot is not reachable from any
# code path here.
#
# NO CONTAINER RUNS. The image filesystem is mounted and read; nothing in the
# image executes. Container execution was permitted for this step, but mounting
# is strictly less capable and answers the question completely, so the stronger
# permission is left unused. Phase 21's end-to-end exercises real execution
# later, where it is the actual subject.
#
# THE EXPECTED VALUES ARE PINNED HERE. This probe is owned by the harness and
# compares against constants; it does not accept expected values from a caller,
# print what it found and let a human decide, or read them from the package
# under test. A probe whose expectations come from its subject proves nothing.
#
# Usage:
#   bash provisioning/execution/g11-ai-interpreter-probe.sh ARCHIVE [WORKDIR]

GOVERNED_IMAGE="5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190"

# CIMP-000001 build-input fields 5, 7 and 8.
EXPECT_LINK="python3"
EXPECT_TARGET="/usr/bin/python3.14"
EXPECT_SHA256="041b9331ce282a8ffeb8e36c662a3a2991f692c8d90633e921e37a1bdafb0de0"

# The container-side interpreter the governed argv contract names. It is the
# symlink, not the target: `tools/capability/execution/worker.py` sets
# CONTAINER_INTERPRETER to this exact path.
INTERPRETER_LINK_PATH="/usr/bin/python"

die() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }
note() { printf '\n=== %s ===\n' "$*"; }

ARCHIVE="${1:-}"
# Podman refuses a runroot longer than 50 characters, so the default is short
# rather than descriptive. Discovered the hard way while rehearsing this.
WORKDIR="${2:-/tmp/kai-probe}"

[ -n "$ARCHIVE" ] || die "usage: $0 ARCHIVE [WORKDIR]"
[ -f "$ARCHIVE" ] || die "the archive ${ARCHIVE} is not a file"
[ "${#WORKDIR}" -le 40 ] || die "WORKDIR must be short: podman caps runroot at 50 characters"
case "$WORKDIR" in
    /data/kyri/capability*) die "the probe must not run against production storage" ;;
esac

rm -rf "$WORKDIR"
mkdir -p "${WORKDIR}/r" "${WORKDIR}/rr"
PODMAN=(podman --root "${WORKDIR}/r" --runroot "${WORKDIR}/rr")

note "archive"
sha256sum "$ARCHIVE"

note "isolated store, empty before load"
"${PODMAN[@]}" images --all --no-trunc --format '{{.ID}}' | sed 's/^/  /'

note "load"
"${PODMAN[@]}" load -i "$ARCHIVE" 2>&1 | tail -2

# The identity must survive the export/import round trip exactly. A tag is not
# accepted as evidence and is not consulted: the archive is untagged on purpose.
note "identity gate"
observed="$("${PODMAN[@]}" images --all --no-trunc --format '{{.ID}}' \
    | sed 's/^sha256://')"
printf '  imported: %s\n  governed: %s\n' "$observed" "$GOVERNED_IMAGE"
[ "$observed" = "$GOVERNED_IMAGE" ] || die \
    "the imported identity is ${observed}, not the governed image"
printf '  ISOLATED_IMAGE_ID=EXACT\n'

# Everything below runs inside the user namespace, because mounting an image in
# a rootless store requires it. `podman unshare` maps this user to root inside
# that namespace only; it grants nothing on the host.
cat >"${WORKDIR}/inside.sh" <<INSIDE
set -Eeuo pipefail
mount="\$(podman --root "${WORKDIR}/r" --runroot "${WORKDIR}/rr" image mount "${GOVERNED_IMAGE}")"
[ -n "\$mount" ] || { echo "MOUNT_FAILED"; exit 1; }
trap 'podman --root "${WORKDIR}/r" --runroot "${WORKDIR}/rr" image unmount "${GOVERNED_IMAGE}" >/dev/null 2>&1 || true' EXIT

link_path="\${mount}${INTERPRETER_LINK_PATH}"
[ -L "\$link_path" ] || { echo "NOT_A_SYMLINK"; exit 1; }

printf 'LINK=%s\n' "\$(readlink "\$link_path")"
resolved="\$(readlink -f "\$link_path")"
printf 'TARGET=%s\n' "\${resolved#\$mount}"
[ -f "\$resolved" ] || { echo "TARGET_NOT_REGULAR"; exit 1; }
printf 'SHA256=%s\n' "\$(sha256sum <"\$resolved" | cut -d' ' -f1)"
INSIDE

note "filesystem facts (mounted, nothing executed)"
observed_facts="$("${PODMAN[@]}" unshare bash "${WORKDIR}/inside.sh")"
printf '%s\n' "$observed_facts" | sed 's/^/  /'

value_of() { printf '%s\n' "$observed_facts" | sed -n "s/^$1=//p"; }

note "verdict"
failures=0
check() {
    local field="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        printf '  %-18s PASS  %s\n' "$field" "$actual"
    else
        printf '  %-18s FAIL  expected %s, got %s\n' "$field" "$expected" "$actual"
        failures=$((failures + 1))
    fi
}

check interpreter_link   "$EXPECT_LINK"   "$(value_of LINK)"
check interpreter_target "$EXPECT_TARGET" "$(value_of TARGET)"
check interpreter_sha256 "$EXPECT_SHA256" "$(value_of SHA256)"

if [ "$failures" -ne 0 ]; then
    die "interpreter evidence does not match CIMP-000001; this image must not become a production backend"
fi

printf '\nINTERPRETER_LINK=PASS\nINTERPRETER_TARGET=PASS\nINTERPRETER_SHA256=PASS\n'
printf 'CIMP_000001_BUILD_INPUTS=15/15 MATCH\n'
