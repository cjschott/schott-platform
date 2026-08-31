# ENG-0005 G11-AI.1 — export ceremony identity defect, corrected

**Date:** 2026-08-31
**Branch:** `arch/eng-0005-execution-transition`
**Amends:** `2026-08-31-g11-ai-g6-podman-backend.md` (report commit `f1c49af`)
**Starting authority:** `f1c49af54984163c474ddc3d81187af493ef8d4d`
**Implementation commit:** `81848be`

A checkpoint note, not a rewrite. The G11-AI report is pushed history and stays
as written; this records what its ceremony got wrong, what that cost, and what
was corrected.

The operator ran the reviewed export and it aborted:

```
ABORT: the governed image 5cee2b53… is not in the store
```

against a store that demonstrably held it. **The defect is mine**, and it is the
specific mistake the ceremony's own header argues against: the check was written
against an *assumed* Podman rendering rather than an observed one, in a script
whose stated design principle is that facts come from the host.

No production authority was harmed. `podman save` never ran, no archive exists,
and the abort happened three steps before anything could have been written. But
the failure mode is worth recording precisely, because the obvious fix — match
on a substring — would have made the run succeed *and* would have made the
ceremony start accepting images that are not the governed one.

---

## 1. Root cause

`podman images --all --no-trunc --format '{{.ID}} …'` renders the identity with
its algorithm prefix. From the failed run's own captured inventory:

```
sha256:5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190 localhost/kyri-capability-execution:g5
```

The ceremony compared that against the bare 64-hex identity CIMP resolution
produced:

```bash
grep -q "^${GOVERNED_IMAGE} " "${dir}/images-before.txt"
```

Reproduced mechanically against the preserved evidence file:

| | |
| --- | --- |
| rendered first field | `sha256:5cee…5190`, **71 characters** |
| `GOVERNED_IMAGE` | `5cee…5190`, **64 characters** |
| committed check | **no match** — this is the abort |
| governed image actually present | **yes**, line 2 of 17 |

A line beginning `sha256:` cannot match a pattern anchored at `^5cee`. That is
the complete and only cause of this refusal.

### Confirming it was the *only* cause

Fixing the grep and re-running into a second abort would have been a poor
outcome, so the rest of the data flow was established rather than assumed. An
isolated, offline store — built with `podman import` from a locally created tar,
touching no production path and no network — gave the answers on this exact
Podman 4.9.3:

| Question | Observed |
| --- | --- |
| `images --no-trunc` `{{.ID}}` | `sha256:<64hex>` |
| `images` without `--no-trunc` | `04ab762b2381` — 12-char short ID, no prefix |
| `image inspect <bare hex>` | **accepted** |
| `image inspect sha256:<hex>` | **accepted** |
| `save --format oci-archive <bare hex>` | **works** |
| archive config digest vs image ID | equal, bare-to-bare |

So Podman accepts a bare hex *reference* everywhere the ceremony passes one. The
mismatch exists only where the ceremony *parses* Podman's rendered output.

One incidental finding, relevant to the isolated store in Phase 6: Podman
refuses a `--runroot` longer than 50 characters. The disposable store must use a
short path.

## 2. Audit of every comparison

| Site | Compares | Verdict |
| --- | --- | --- |
| inventory presence gate | rendered `{{.ID}}` vs bare | **BROKEN** — fixed |
| after-export authoritative record report | rendered `{{.ID}}` vs bare | **BROKEN** — fixed |
| `podman image inspect "$GOVERNED_IMAGE"` | bare hex as a *reference* | correct, unchanged |
| `--format '{{.ManifestType}}'` inspect | bare hex as a *reference* | correct, unchanged |
| `podman save … "$GOVERNED_IMAGE"` | bare hex as a *reference* | correct, unchanged |
| archive config digest vs `GOVERNED_IMAGE` | bare vs bare (`split(":", 1)[1]`) | **correct — deliberately left alone** |
| `images-before` vs `images-after` diff | rendering vs same rendering | correct, unchanged |
| container inventory | container IDs render bare | correct, unchanged |

The second broken site is the one that would have gone unnoticed. It was:

```bash
grep -E "^${GOVERNED_IMAGE}|^${HISTORICAL_IMAGE}" "${dir}/images-after.txt" || true
```

The `|| true` means a check that can never match prints nothing and reads as a
clean result. A silently empty "authoritative image records" section directly
under a passing export is worse than a loud failure, because it is the evidence
a reviewer would have used to conclude the image survived.

The archive config-digest comparison is correct and is now **pinned by a test**,
so a later sweep for `sha256:` handling cannot "fix" the one comparison that was
already right.

## 3. The correction

Normalisation at the parsing boundary, not a looser comparison:

```bash
canonical_image_id() {
    local rendered="${1#sha256:}"
    [ "${#rendered}" -eq 64 ] || return 1
    case "$rendered" in
        *[!0-9a-f]*) return 1 ;;
    esac
    printf '%s' "$rendered"
}
```

Strip the algorithm prefix, then **require** exactly 64 lowercase hex
characters. The length and character checks are what stop the prefix strip from
becoming a widening.

An identity that cannot be parsed is a **refusal**, not a line to skip:

```bash
canonical="$(canonical_image_id "$rendered")" || die \
    "the image inventory holds an unreadable identity: ${rendered}"
```

Skipping looks harmless — *"that entry cannot have been the image I was asked
about"* — but it is a guess about a rendering this script does not understand,
and the answer being guessed at decides whether a privileged export proceeds.
"I could not read the inventory" and "the image is not there" are different
facts and only one is safe to act on. `RootlessImageStore` already applies
exactly this rule to `overlay-images/images.json` in the same store; the
ceremony now matches the module it is reading alongside.

The ceremony is also sourceable now — the dispatch runs only under
`[ "${BASH_SOURCE[0]}" = "${0}" ]` — so the identity functions can be tested
with no privilege, no Podman, and no part of the export running.

## 4. RED first

The suite is `tests/test-capability-execution-image-export.sh`, and its fixtures
use the rendering captured from the host during the failed run rather than a
rendering I invented a second time.

RED against `f1c49af` — 5 failures, including the root cause:

```
FAIL: the governed image is found in the rendering Podman actually emits -- expected FOUND, got REFUSED
FAIL: an inventory without the governed image reports absence -- expected ABSENT, got REFUSED
FAIL: another SHA-256 image is not mistaken for the governed one -- expected ABSENT, got REFUSED
FAIL: a second image that is present is also found -- expected FOUND, got REFUSED
FAIL: the governed value appearing only as a tag is not a match -- expected ABSENT, got REFUSED
```

GREEN after `81848be` — 12/12. The cases that matter are not "does it find the
image"; they are the four ways a looser fix would have quietly started saying
yes:

| Case | Verdict required |
| --- | --- |
| another SHA-256 image | ABSENT |
| a second image that *is* present | FOUND — so ABSENT means absence, not a check that never matches |
| governed value present only as a **tag** | ABSENT |
| identity **containing** the governed value (`sha256:5cee…5190deadbeef`) | REFUSED |
| **truncated** inventory (`--no-trunc` dropped) | REFUSED, not absence |
| unreadable identity (`<none>`) | REFUSED, not skipped |
| uppercase identity | REFUSED, not folded |

Plus three static cases: the inventory is requested untruncated, the archive
comparison stays bare-to-bare, and the ceremony still reaches no mutating Podman
verb.

Verified last against the real preserved capture, which is the proof that
matters:

```
FOUND   5cee2b53…5190   (governed)
FOUND   a3ef70ee…9b69   (historical)
ABSENT  0000…0000       (fabricated)
```

## 5. What the aborted ceremony did, and what cannot be proven

The directory `/tmp/kyri-g11-ai-oci-3c9f2cfb9c03` holds exactly four files:

```
containers-before.txt   700 bytes
images-before.txt      1543 bytes
store-content-M0.txt    12357 bytes
store-structure-M0.txt 794833 bytes
```

**No OCI archive exists**, and no `image-inspect-before.json` exists — which
places the abort precisely: it happened at the presence gate, *after* `podman
images` and `podman ps`, and *before* `podman image inspect`. So of the four
Podman verbs the ceremony can reach, exactly two ran, and both are read-only
listings.

| Question | Answer | Basis |
| --- | --- | --- |
| Archive created? | **NO** | directory listing |
| `podman save` ran? | **NO** | no archive; abort precedes the save by four steps |
| `podman image inspect` ran? | **NO** | its output file is absent |
| Image inventory intact? | **YES** — 17 images, `5cee…` present and tagged `localhost/kyri-capability-execution:g5`, `a3ef70ee…` present and untagged | `images-before.txt`, captured by the run itself |
| Container inventory | 7 pre-existing Track B containers, exited weeks ago; **none created by this run** | `containers-before.txt`, and the ceremony cannot create containers |
| Any image added, removed, retagged? | **NO** | the ceremony reaches no mutating verb; pinned by test |

**What cannot be proven from here, and I will not claim it.** The run captured
M0 but aborted before M1, so the footprint of the two read-only Podman verbs on
the graphroot was never measured. Podman opens its store — and on this host its
sqlite database, `db.sql`, 233472 bytes at M0 — read-write on any invocation,
so lock-file and database writes are *expected*. The store is `0750
kyri-capability` and the coordinator cannot read it, so I cannot take a fresh
manifest to compare without privilege.

Concretely: **image authority is proven intact** (the inventory is the run's own
output and shows the governed image present and correctly tagged), while
**byte-level graphroot equivalence is unproven** and would require root to
establish.

M0 is a complete pre-Podman baseline — 5704 objects, 68 content-hashed metadata
records — with the three authoritative records pinned:

| Record | SHA-256 at M0 |
| --- | --- |
| `overlay-images/images.json` | `523046a80a861e4cd376e3088fb79795c316a1433b8933a9cee695b490f40460` |
| `overlay-layers/layers.json` | `a22d3c0615fbf8a684f0f08197fb7817aa05d65acdc16eb1a35c16ca24be637e` |
| `overlay-containers/containers.json` | `ae44df8b86ff3ce394ef111fd19cbb187fb72790f36afae7c19cd5024fb29cf0` |

That is why the incident directory is preserved. **The corrected run captures
its own M0, and diffing the two answers the open question exactly** — any
difference is the failed run's footprint, and `overlay-images/images.json`
holding the same digest in both proves image authority never moved:

```bash
diff -u /tmp/kyri-g11-ai-oci-3c9f2cfb9c03/store-content-M0.txt \
        /tmp/kyri-g11-ai-oci-a999e0e2c2bd/store-content-M0.txt
```

`FAILED_EXPORT_PRODUCTION_STORE_MUTATED = UNKNOWN` — honestly unknown at
metadata level, with image authority separately proven intact and a concrete
plan to close it.

## 6. Incident evidence

`/tmp/kyri-g11-ai-oci-3c9f2cfb9c03` is **preserved, not deleted**, per the
reviewer's instruction. It is the only pre-Podman baseline of the governed store
in existence and it is the other half of the comparison above. It must survive
until the corrected run's M0 is captured and diffed.

Note `/tmp`'s 30-day sweep, already flagged in G11-AI §5: this evidence is not
durable by default.

## 7. Validation

| Gate | Result |
| --- | --- |
| `test-capability-execution-image-export.sh` | RED 5 failures → **GREEN 12/12** |
| `test-capability-execution-provisioning.sh` | **PASS** — non-executable invariant still holds |
| `test-developer-experience.sh` | **PASS** — new suite paired in validation and CI |
| ShellCheck | clean |
| pre-commit | all five hooks passed |
| `run-validation.sh --quick` | **PASS**, 81/81 |
| `run-validation.sh` (full) | **PASS**, 106/106 |
| GitHub workflows | see handoff |

Both totals were re-measured, not incremented on assumption — the suite runs in
both modes, so both rose by one.

## 8. Corrected operator command

A **new** directory; `3c9f2cfb9c03` is preserved as evidence and is not reused.
Verified absent at derivation time, and the ceremony refuses a destination that
exists.

```bash
cd /tmp
sudo bash /opt/schott-platform/provisioning/execution/g11-ai-image-export.sh \
  --run /tmp/kyri-g11-ai-oci-a999e0e2c2bd
```

Everything else in G11-AI §6 stands: the export addresses the image by immutable
ID, writes the archive outside the production store, re-checks the manifest type
before saving, and proves the archive's identity from its config digest without
importing anything.

## 9. Carried forward unchanged

`SUDOERS_INSTALL_BLOCKED_PENDING_HELPER_COHERENCE = YES`. The split-`16f285e`
finding in G11-AI §9 — the installed `kyri-exec-verify` entrypoint would exec
the *production* worker, because its guard sits above a `cfb0edd` action module
that ignores `policy.worker_script` — is untouched here. No helper or sudoers
change was made: no dependency between it and this export-script defect was
found, and the reviewer's instruction was not to couple them.

No backend implementation until the corrected export succeeds.
