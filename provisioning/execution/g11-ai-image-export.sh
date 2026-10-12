#!/usr/bin/env bash
set -Eeuo pipefail

# The ENG-0005 G11-AI authorised export of the governed CIMP-000001 image.
#
# WHAT THE REVIEWER AUTHORISED, AND NOTHING ELSE
# ==============================================
# One semantic operation:
#
#   READ the exact image 5cee2b53... from the kyri-capability rootless store
#   -> WRITE one OCI archive OUTSIDE that store
#   -> checksum and inspect the archive
#   -> leave the production store byte/metadata-equivalent.
#
# The four Podman verbs this script may reach are `images`, `image inspect`,
# `ps` and `save`. It runs no container, and pulls, builds, loads, imports,
# tags, removes and prunes are absent rather than merely unused. Grep for them:
# the only mutation any code path here can cause outside the export directory is
# whatever `podman save` itself does to open its own store, which is precisely
# what the M1/M2 manifest pair exists to measure.
#
# The image is addressed by its immutable ID. No tag is ever passed to Podman as
# a reference, because a tag is a mutable pointer and the thing under test is an
# identity.
#
# WHY oci-archive IS SAFE HERE, AND WOULD NOT ALWAYS BE
# ====================================================
# A local image ID in containers-storage *is* the digest of the image config
# blob. `podman save --format oci-archive` copies the manifest and config
# verbatim when the stored manifest is already OCI, so the config digest -- and
# therefore the image ID -- survives the round trip.
#
# It would NOT survive if the stored manifest were Docker v2s2: the save would
# convert the manifest, rewriting the config, and the reloaded image would carry
# a different ID. G11-AF recorded this image as
# `application/vnd.oci.image.manifest.v1+json`, but a report is not a fact about
# the store right now, so `require_oci_manifest` re-checks it and aborts before
# the save rather than discovering the mismatch after an import.
#
# Nothing under provisioning/execution carries an executable bit, and this does
# not either: the interpreter is named explicitly so a script that cannot be
# executed cannot be executed by the wrong one.
#
# Usage:
#   sudo bash provisioning/execution/g11-ai-image-export.sh --run DIR
#   bash provisioning/execution/g11-ai-image-export.sh --plan   (no privilege)
#
# DIR must not already exist. It is created owned by the execution identity so
# that identity can write the archive, and group-readable by the coordinator so
# the isolated-store tests can read it without production storage becoming
# writable to anyone new.

GOVERNED_IMAGE="5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190"
HISTORICAL_IMAGE="a3ef70eee8c906c4604f53bb1874ab5bf4922bab9c5f0ba6b6d9ce126f589b69"
GOVERNED_TAG="kyri-capability-execution:g5"
OCI_MANIFEST_TYPE="application/vnd.oci.image.manifest.v1+json"

EXECUTION_USER="kyri-capability"
EXECUTION_UID=999
EXECUTION_HOME="/data/kyri/capability"
EXECUTION_RUNTIME_DIR="/run/user/999"
COORDINATOR="cschott"

# Derived in tools/capability/execution/image_store.py, not guessed here: with
# XDG_DATA_HOME unset, containers/storage resolves the rootless graphroot to
# $HOME/.local/share/containers/storage.
STORE="${EXECUTION_HOME}/.local/share/containers/storage"

ARCHIVE_NAME="cimp-000001-5cee2b53.oci-archive.tar"

# Small enough that a metadata file which has grown pathological is reported
# rather than hashed into a manifest nobody will read.
METADATA_MAX_BYTES=1048576

die() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }
note() { printf '\n=== %s ===\n' "$*"; }

# --- image identity, normalised where it is parsed ---------------------------
#
# Podman renders `{{.ID}}` as `sha256:<64hex>` under --no-trunc, and as a
# 12-character short ID without it. Neither is the bare 64-hex identity that
# CIMP resolution produced and that this ceremony is written in terms of.
#
# The first run of this ceremony aborted with "not in the store" against a store
# that demonstrably held the image, because the check compared an assumed
# rendering against the real one. The correction is to normalise the rendering
# at the boundary where it is read, not to loosen the comparison: a substring or
# prefix match would have made that run succeed and would also have started
# accepting identities that are not the governed one.
canonical_image_id() {
    local rendered="${1#sha256:}"
    [ "${#rendered}" -eq 64 ] || return 1
    case "$rendered" in
        *[!0-9a-f]*) return 1 ;;
    esac
    printf '%s' "$rendered"
}

# Whether the inventory records exactly this identity.
#
# A line whose identity cannot be parsed is a refusal, not a line to skip past.
# Skipping looks harmless -- "that entry cannot have been the image I was asked
# about" -- but it is a guess about a rendering this script does not understand,
# and the answer being guessed at decides whether a privileged export proceeds.
# "I could not read the inventory" and "the image is not there" are different
# facts, and only one of them is safe to act on. `RootlessImageStore` applies
# exactly this rule to `overlay-images/images.json`.
store_holds_image() {
    local inventory="$1" wanted="$2" rendered canonical found=1
    while read -r rendered _ || [ -n "${rendered:-}" ]; do
        [ -n "$rendered" ] || continue
        canonical="$(canonical_image_id "$rendered")" || die \
            "the image inventory holds an unreadable identity: ${rendered}"
        if [ "$canonical" = "$wanted" ]; then found=0; fi
    done <"$inventory"
    return "$found"
}

# --- the read-only production-store manifest --------------------------------
#
# Two files per capture, because they answer different questions. The structural
# manifest catches an object appearing, vanishing, or changing size, mode or
# owner. The content manifest catches an authoritative record being rewritten in
# place at the same size, which is exactly how a tag or image-ID mutation would
# look. Layer blobs are deliberately not hashed: gigabytes of content-addressed
# data cannot change without changing the metadata that names it, so hashing
# them would cost minutes to re-prove something the cheap manifest already
# proves.
# The capture label names the file and is printed as progress. It is
# deliberately NOT written into the body.
#
# The first successful export reported EXPORT_STORE_FOOTPRINT=PRESENT against a
# store that had not changed at all: each manifest carried its own label as a
# header line, so M1 and M2 differed on that line and on nothing else. A
# measurement that cannot distinguish its own label from the thing it measures
# manufactures findings, and a footprint warning nobody can trust is worse than
# no warning -- the next real one gets waved through.
store_manifest() {
    local label="$1" dir="$2"

    find "$STORE" -xdev -printf '%y %#m %U:%G %10s %P\n' | LC_ALL=C sort \
        >"${dir}/store-structure-${label}.txt"

    find "$STORE" -xdev -type f -name '*.json' \
        -size "-${METADATA_MAX_BYTES}c" -printf '%P\n' \
    | LC_ALL=C sort \
    | while IFS= read -r relative; do
        printf '%s  %s\n' \
            "$(sha256sum <"${STORE}/${relative}" | cut -d' ' -f1)" \
            "$relative"
    done >"${dir}/store-content-${label}.txt"

    printf '%-4s structure=%s content=%s\n' "$label" \
        "$(sha256sum <"${dir}/store-structure-${label}.txt" | cut -c1-16)" \
        "$(sha256sum <"${dir}/store-content-${label}.txt" | cut -c1-16)"
}

# Comment lines are ignored on both sides, so a header reintroduced by a later
# edit still cannot manufacture a difference. Belt and braces: the bodies no
# longer carry one, and if they ever do again it will not be reported as store
# mutation.
manifests_identical() {
    diff -q <(grep -v '^#' "$1") <(grep -v '^#' "$2") >/dev/null
}

# Every Podman call in this script goes through here, so the environment the
# execution identity gets is stated once and is exactly the transition's:
# HOME and XDG_RUNTIME_DIR, nothing inherited.
as_execution_identity() {
    runuser -u "$EXECUTION_USER" -- env -i \
        HOME="$EXECUTION_HOME" \
        XDG_RUNTIME_DIR="$EXECUTION_RUNTIME_DIR" \
        PATH="/usr/bin:/bin" \
        "$@"
}

require_oci_manifest() {
    local observed="$1"
    [ "$observed" = "$OCI_MANIFEST_TYPE" ] || die \
"the stored manifest is '${observed}', not '${OCI_MANIFEST_TYPE}'.
An oci-archive save would convert it, rewriting the config blob whose digest is
the image ID, and the archive would carry a different identity than
${GOVERNED_IMAGE}. Stop for a reviewer ruling rather than exporting an image
that cannot round-trip."
}

plan() {
    note "derived facts"
    cat <<PLAN
governed image     ${GOVERNED_IMAGE}
governed tag       ${GOVERNED_TAG}  (corroboration only; never used as a reference)
historical image   ${HISTORICAL_IMAGE}  (expected untagged, inert)
execution identity ${EXECUTION_USER} uid ${EXECUTION_UID}
production store   ${STORE}
required manifest  ${OCI_MANIFEST_TYPE}
podman            $(podman --version 2>/dev/null || echo 'not found')
save format        oci-archive  (podman 4.9.3 spells it exactly this way)
PLAN
}

run() {
    local dir="$1"

    [ "$(id -u)" -eq 0 ] || die "this must run as root; re-run under sudo"
    [ -n "$dir" ] || die "an export directory is required"
    case "$dir" in
        /tmp/*) : ;;
        *) die "the export directory must live under /tmp, outside the store" ;;
    esac
    case "$dir" in
        "${EXECUTION_HOME}"*) die "the export must not be written inside the production store" ;;
    esac
    [ ! -e "$dir" ] || die "${dir} already exists; the destination must be new"

    [ "$(id -u "$EXECUTION_USER")" -eq "$EXECUTION_UID" ] \
        || die "${EXECUTION_USER} is not uid ${EXECUTION_UID}"
    [ -d "$STORE" ] || die "the production store is not at ${STORE}"

    # Owned by the execution identity so it can write the archive; group the
    # coordinator so the isolated-store work can read it. Production storage
    # gains no new writer.
    install -d -o "$EXECUTION_USER" -g "$COORDINATOR" -m 0750 "$dir"
    local archive="${dir}/${ARCHIVE_NAME}"

    # Never let the store be the working directory of anything below, and never
    # the repository either.
    cd /tmp

    note "M0 -- pristine, before any Podman process touches the store"
    store_manifest M0 "$dir"

    note "read-only Podman inspection"
    as_execution_identity podman images --all --no-trunc \
        --format '{{.ID}} {{.Repository}}:{{.Tag}}' \
        | tee "${dir}/images-before.txt"
    as_execution_identity podman ps --all --no-trunc \
        --format '{{.ID}} {{.Names}} {{.Status}}' \
        | tee "${dir}/containers-before.txt"

    store_holds_image "${dir}/images-before.txt" "$GOVERNED_IMAGE" \
        || die "the governed image ${GOVERNED_IMAGE} is not in the store"

    as_execution_identity podman image inspect "$GOVERNED_IMAGE" \
        >"${dir}/image-inspect-before.json"

    local manifest_type
    manifest_type=$(as_execution_identity podman image inspect \
        --format '{{.ManifestType}}' "$GOVERNED_IMAGE")
    printf 'stored manifest type: %s\n' "$manifest_type"
    require_oci_manifest "$manifest_type"

    note "M1 -- after Podman initialisation, before the export"
    store_manifest M1 "$dir"

    note "the authorised export"
    as_execution_identity podman save \
        --format oci-archive \
        -o "$archive" \
        "$GOVERNED_IMAGE"

    note "M2 -- after the export"
    store_manifest M2 "$dir"

    note "archive identity"
    sha256sum "$archive" | tee "${dir}/archive.sha256"
    stat -c '%n  %s bytes  %U:%G  %#a' "$archive"

    # The decisive identity proof, and it needs no import to make it. The OCI
    # manifest names its config blob by digest, and for a containers-storage
    # image that digest IS the local image ID. If these agree, the archive
    # carries the governed identity; if they do not, no amount of loading it
    # will fix that.
    note "archive structure"
    tar -tvf "$archive" | tee "${dir}/archive-listing.txt"
    tar -xOf "$archive" index.json >"${dir}/archive-index.json"

    local manifest_digest config_digest
    manifest_digest=$(python3 -c '
import json, sys
index = json.load(open(sys.argv[1]))
manifests = index["manifests"]
if len(manifests) != 1:
    raise SystemExit("the archive holds %d manifests, expected 1" % len(manifests))
print(manifests[0]["digest"].split(":", 1)[1])
' "${dir}/archive-index.json")

    tar -xOf "$archive" "blobs/sha256/${manifest_digest}" \
        >"${dir}/archive-manifest.json"
    config_digest=$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["config"]["digest"].split(":", 1)[1])
' "${dir}/archive-manifest.json")

    printf 'archive manifest digest: %s\n' "$manifest_digest"
    printf 'archive config digest:   %s\n' "$config_digest"
    [ "$config_digest" = "$GOVERNED_IMAGE" ] || die \
"the archive's config digest is ${config_digest}, not ${GOVERNED_IMAGE}.
The exported identity differs from the governed identity. Stop."
    printf 'ARCHIVE_IDENTITY=EXACT (config digest == governed image ID)\n'

    note "production store non-mutation"
    as_execution_identity podman images --all --no-trunc \
        --format '{{.ID}} {{.Repository}}:{{.Tag}}' \
        | tee "${dir}/images-after.txt"
    as_execution_identity podman ps --all --no-trunc \
        --format '{{.ID}} {{.Names}} {{.Status}}' \
        | tee "${dir}/containers-after.txt"

    diff -u "${dir}/images-before.txt" "${dir}/images-after.txt" \
        && printf 'IMAGE_INVENTORY_UNCHANGED=YES\n' \
        || printf 'IMAGE_INVENTORY_UNCHANGED=NO\n'
    diff -u "${dir}/containers-before.txt" "${dir}/containers-after.txt" \
        && printf 'CONTAINER_INVENTORY_UNCHANGED=YES\n' \
        || printf 'CONTAINER_INVENTORY_UNCHANGED=NO\n'

    # M1 -> M2 is the export's own footprint, which is the number that matters.
    # M0 -> M1 is separated out because Podman opening its database is not the
    # export changing image authority, and a single before/after pair would have
    # conflated the two and made a benign write look like a finding.
    note "M0 -> M1 (Podman initialisation footprint)"
    if manifests_identical "${dir}/store-structure-M0.txt" \
                           "${dir}/store-structure-M1.txt" \
        && manifests_identical "${dir}/store-content-M0.txt" \
                               "${dir}/store-content-M1.txt"; then
        printf 'PODMAN_INIT_FOOTPRINT=NONE\n'
    else
        printf 'PODMAN_INIT_FOOTPRINT=PRESENT\n'
        diff -u "${dir}/store-structure-M0.txt" "${dir}/store-structure-M1.txt" || true
        diff -u "${dir}/store-content-M0.txt" "${dir}/store-content-M1.txt" || true
    fi

    note "M1 -> M2 (the export's footprint)"
    if manifests_identical "${dir}/store-structure-M1.txt" \
                           "${dir}/store-structure-M2.txt" \
        && manifests_identical "${dir}/store-content-M1.txt" \
                               "${dir}/store-content-M2.txt"; then
        printf 'EXPORT_STORE_FOOTPRINT=NONE\n'
    else
        printf 'EXPORT_STORE_FOOTPRINT=PRESENT -- review the diff below before proceeding\n'
        diff -u "${dir}/store-structure-M1.txt" "${dir}/store-structure-M2.txt" || true
        diff -u "${dir}/store-content-M1.txt" "${dir}/store-content-M2.txt" || true
    fi

    # Through the same normalisation, so this report cannot disagree with the
    # gate above. The previous form matched the rendering as a raw prefix and
    # would have silently printed nothing at all.
    note "authoritative image records"
    local identity
    for identity in "$GOVERNED_IMAGE" "$HISTORICAL_IMAGE"; do
        if store_holds_image "${dir}/images-after.txt" "$identity"; then
            printf '  present  %s\n' "$identity"
        else
            printf '  ABSENT   %s\n' "$identity"
        fi
    done
    grep -F "$GOVERNED_IMAGE" "${dir}/images-after.txt" || true
    grep -E 'overlay-images/images\.json' "${dir}/store-content-M0.txt" \
        "${dir}/store-content-M2.txt" || true

    chgrp -R "$COORDINATOR" "$dir"
    chmod -R g+rX "$dir"

    note "done"
    printf 'OCI_ARCHIVE_PATH=%s\n' "$archive"
    printf 'OCI_ARCHIVE_SHA256=%s\n' "$(cut -d' ' -f1 <"${dir}/archive.sha256")"
}

# Sourceable, so the identity functions can be exercised by the suite without
# privilege, without Podman, and without running any part of the ceremony. The
# dispatch happens only on direct execution.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-}" in
        --plan) plan ;;
        --run) run "${2:-}" ;;
        *) die "usage: bash $0 --plan | --run DIR" ;;
    esac
fi
