# ENG-0005 G7 — final closure / release readiness gate

**Date:** 2026-10-09
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `8853d51`
**Engineer:** Claude (implementation)
**Status:** **READY_FOR_OPERATOR_CLOSURE** — every accepted state re-verified, O1–O6 disposed, F1–F6 reviewed, **one new finding (F7) raised**, closure sequence grounded in the project's own precedent and prepared but not crossed. No production mutation.

**Closure ceremony:** [`provisioning/closure/eng-0005-g7-closure-ceremony.txt`](../../../../provisioning/closure/eng-0005-g7-closure-ceremony.txt)

---

## A. State, re-verified read-only

### Repository

| | |
|---|---|
| branch | `arch/eng-0005-execution-transition` ✓ |
| HEAD | `8853d5193da1530c4ff0e5e2c87b22362fc99db0` |
| tree | **0 changes** |
| origin equality | **YES** — `origin/arch/eng-0005-execution-transition` is the same commit |
| vs `origin/main` | **452 ahead, 0 behind** — no rebase needed |

### Production Fabric — PASS

Aggregate `7e2a4ed0e9c11cf1f3790360542232649946a9bf31400e9dd442d8c2ad2f376b`,
**MATCH**. Sequences and record counts agree exactly: advertisement 8/8,
instance 7/7, route 7/7, selection 5/5. Heads by scan: `CADV-000008`,
`CINST-000007`, `CROUTE-0007`; current selection `CSEL-000005` at
`bc464efc…10f0`. `fabric validate`: **`findings: []`**.

### Execution runtime — PASS, with F7 disclosed

Aggregate `7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99`,
**MATCH**. Lifecycle read from the transition journal, last state per invocation:

```
CINV-000001  seq 3  abandoned
CINV-000002  seq 3  abandoned
CINV-000003  seq 3  concluded
```

Counters and sequences: invocation 3, result 2, `cmut-counter 000000000012`,
`cadm-counter 000007`. Immutable evidence intact: **CINV 3 · CRES 2 · CADM 7 ·
CMUT 12**. Quarantine store, reservations, releases and the state directory are
all empty.

**Occupancy 0/2, computed from the released rule rather than inferred.**
`capacity.py` states occupancy as an *exclusion* —
`NON_SLOT_HOLDING_STATES = {released, abandoned, concluded}` — so every other
lifecycle state holds a slot and a state added later holds one until somebody
decides otherwise. All three invocations are in excluded states:

```
MAXIMUM_SLOTS 2 · CINV-000001 abandoned · CINV-000002 abandoned · CINV-000003 concluded
OCCUPANCY = 0/2, held by nothing
```

### Trust — PASS

`53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f`, **MATCH**.

### Installed Generation — PASS

Generation 23. `provenance.py` installed at
`39141cd453d74c8cfb4fee7348f45fff4dfa68b5155edaff6886daf990387647`,
**byte-identical to the repository copy**, carrying the `LATER_SCHEMA_MEMBERS`
marker. `test-capability-execution-generation23-installer.sh` passes.

### Sudoers / helpers — PASS, and the operator evidence is corroborated

Both drop-ins exist, `root:root 0440`, and are **not readable at my privilege
level** — so F6's text comes from the operator's evidence, as the brief allows.
What I *could* check independently, I did, and it is the part that matters:

| the digest the grant pins | the installed binary | |
|---|---|---|
| `0d9c8d8c…51a1` (launch → `kyri-exec-transition`) | `0d9c8d8c…51a1` | **MATCH** |
| `2878fff0…98f77` (reconcile → `kyri-exec-reconcile`) | `2878fff0…98f77` | **MATCH** |

Both helpers `root:root 0555`, **no setuid bit, no file capabilities**. So the
operator's quoted grants pin exactly the binaries that are installed — a
cross-check of their evidence at its load-bearing point, not a restatement of it.

### Root Authority — unmounted

Nothing under `/mnt` or `/media` is mounted at all; no authority mount exists and
no `*root-authority*` mountpoint is present. The Operator Root Authority is an
**external** device per its deployment plan, and it is detached.

---

## B. Closure obligations

| | obligation | disposition | evidence |
|---|---|---|---|
| **O1** | legacy provenance compatibility | **CLOSED** | `test-capability-provenance-legacy-compatibility.sh` 13 PASS — *a legacy resume takes no slot, spends no mutation, moves no lifecycle*; Generation 23 installed and matching |
| **O2** | ADR-0018 compatibility wording | **CLOSED** | ADR-0018 §Compatibility, corrected at G11-BC-AL, now states four separate truths where the old wording ran them together, and names the old text as wrong |
| **O3** | Stage-3 matrix | **CLOSED** | live production run, 22/22 reached, **0 masked**, 0 tracebacks, `BLOCK B passes against an unmodified fixture` — re-run at this checkpoint, still 94 PASS / 0 FAIL |
| **O4** | ledger correction | **DONE at AK, and STALE AGAIN** | the correction AK made was right then; three statements are now false — see §E. Not a blocker; it is a closure step |
| **O5** | reviewer G7 gate | **THIS CHECKPOINT** | prepared to the operator boundary, not across it |
| **O6** | criterion-by-criterion audit | **CLOSED** | `docs/development/audits/2026-10-09-eng-0005-section-36-closure-audit.md`, committed at `61a8f1d` |

Also verified: Generation 23 installed and accepted · `CINV-000003` concluded
with `CADM-000003` · `CINV-000001`/`CINV-000002` abandonment evidence retained
(`CADM-000001`, `CADM-000004`) · four provenance corrections retained
(`CADM-000002`, `000005`, `000006`, `000007`) · production-test escape guards
active (4 assertions, 150 suites checked) · **no unresolved capacity
reservation** · no pending CRES/CINV identity · no unexplained mutation — all 12
CMUT carry intent and outcome · no Root Authority dependency open · Fabric
renewal complete · execution authority currently coherent (`supported=True
reason=None eligibility_reasons=[]`).

---

## C. Findings F1–F7

| | status | severity | blocking | follow-up owner | ledger / release notes? |
|---|---|---|---|---|---|
| **F1** `create-route` accepts impossible `recorded_at` | ACCEPTED, open | medium — depth of enforcement, not authority | **No** | Fabric-engine increment + ADR on cross-record temporal ordering | **Ledger yes** — it is a standing engine limitation |
| **F2** `select` accepts while resolving null | ACCEPTED, open | **high — highest carry-forward Fabric defect** | **No** | same increment, **ranked first** | **Ledger yes**, named as the priority |
| **F3** `request_digest` excludes `request_id` | ACCEPTED, open | low — correctly scoped | **No** | documentation increment defining digest coverage | **Ledger brief mention** |
| **F4** kind-specific assumptions in suites | ACCEPTED, repaired | low-medium — test quality, all mine | **No** | test-quality sweep (**not performed**) | Ledger optional |
| **F5** two plan-named suites absent | ACCEPTED, open | low — traceability debt | **No** | plan reconciliation: create them or amend §8 | Ledger optional |
| **F6** installed sudoers unread | **CLOSED** | — | **No** | — | Record as closed by operator evidence |
| **F7** runtime validator reports two findings | **NEW, ACCEPTED** | medium — see below | **No**, with a reviewer call named | Fabric/runtime increment, with F1–F3 | **Ledger yes** |

None was silently converted to PASS. F1–F5 remain accepted findings with owners.

### F7 — the released runtime validator reports two findings against production

**This is new at G7, and my §36 audit should have found it.** I ran `fabric
validate` against production and never ran `capability validate` against the
production *runtime* store. It reports:

```
CINV-000002: result-without-execution-authority
CINV-000003: result-without-execution-authority
```

**What the finding means and why it fires.** The check is
`linked and adapter_identity is None and not legacy` — a terminal result exists,
the invocation carries no `adapter_identity`, and the record is not legacy. All
three production invocations are `schema_version: 2` with
`adapter_identity: null`, and `INVOCATION_SCHEMA_VERSION` is 2, so the `legacy`
suppression no longer applies and any invocation with a result is flagged.

**Why `adapter_identity` is null.** The released source says so at the point of
cause, in `coordinator.py`:

> "No released caller reaches here — `command_invoke` supplies neither an adapter
> nor a binding, **which is why `adapter_identity` is always null** — so this is
> latent rather than live."

So this is **structural for the released configuration**: the CINV is the
immutable pre-execution record, written before anything binds, and the executing
path is the supervised one that runs afterwards. Every successful production
execution will produce this finding.

**The cause confirmed by experiment, not inference.** On a throwaway copy of the
production runtime store, setting `adapter_identity` on `CINV-000003` alone —
changing nothing else — clears exactly that one finding and leaves the other:

```
before:  CINV-000002: result-without-execution-authority
         CINV-000003: result-without-execution-authority
after:   CINV-000002: result-without-execution-authority
```

So the finding is caused solely by the null field. Production was untouched and
re-measured at `7dfb34e6…2e99` afterwards.

**Is it a real authority problem? No.** `CINV-000003`'s execution authority is
separately and durably proven — the launch-authorisation record on disk, the
transition journal (`reserved → launch_authorized → concluded`), `CRES-000002`
`completed`, and the real-kernel ownership evidence in the §36 audit. The finding
reports a **missing discriminator, not a missing authority**.

**Is it already known? Yes, and accepted.** G11-AN (2026-08-31) recorded it as
one of two deliberate stops: *"§14 names the field that would separate them —
`adapter_identity` on the invocation record… The implementation has never carried
it"*, and *"None is blocked by the stops; all are bounded."* G11-BB-S lists the
finding among those `validate_store` reports. Two helper-ceremony suites carry
the comment that the validator reports it **correctly**.

**One nuance that is genuinely new.** G11-AN concluded *"prepared with a terminal
result → sound, the ordinary successful shape"* and deliberately left the schema
at version 1. The schema is now version 2, which is what switches this check on
— while `adapter_identity` is still never populated. So the accepted stop was
reasoned about at v1; at v2 the check is live. That is a **writer/validator
mismatch**, and it is why I am raising it rather than filing it under G11-AN and
moving on.

**Disposition: PASS_WITH_ACCEPTED_FINDING, not blocking.** Documented at the
point of cause, accepted as bounded, and masking nothing — the two flagged
invocations both have complete authority evidence on disk.

**The call that is not mine.** If the reviewer holds that ENG-0005 cannot close
while the released runtime validator reports a non-empty finding list against
production, then this is a **blocker** and my decision below flips. I have given
my assessment; I am naming the judgement rather than assuming it.

---

## D. Validation

| run | result |
|---|---|
| `run-validation.sh --quick` | **140/140**, 0 FAIL, 0 skips |
| `run-validation.sh` (full) | **165/165**, 0 FAIL, 0 FAILED, **0 host-only skips** |
| clean clone of `4b088ce` | **165/165**, 0 FAIL, **18 pinned-checkout skips** |
| GitHub CI on `8853d51` | **6/6 green** |
| `fabric validate` (production) | `findings: []` |
| `capability validate` (production runtime) | **2 findings — F7** |

Closure-safe suites, with the governed stores measured around the whole group:

| suite | result |
|---|---|
| `test-no-production-escape` | 4 / 0 FAIL |
| `test-capability-execution-lifecycle` | 45 / 0 |
| `test-capability-execution-capacity` | 31 / 0 |
| `test-capability-execution-capacity-race` | 5 / 0 |
| `test-capability-execution-conclusion` | 33 / 0 |
| `test-capability-execution-abandonment` | 26 / 0 |
| `test-capability-execution-provenance-correction` | 22 / 0 |
| `test-capability-provenance-legacy-compatibility` | 13 / 0 |
| `test-capability-cinv-000003-stage-3-gate-matrix` | **94 / 0 — live, 22/22, 0 masked** |
| `test-fabric-renewal-chain-rehearsal` | 37 / 0 |
| `test-fabric-renewal-freeze-artifacts` | 90 / 0 |
| `test-static` (incl. ShellCheck conformance) | 867 / 0 |

**Fabric, runtime and Trust all UNCHANGED** across the group.

### Two process mistakes, both repeats

**The full validator was killed twice at step 66** because I launched it from
inside a `Monitor` command, so it shared the monitor's 30-minute lifetime. I had
already hit this earlier in ENG-0005 and recorded it; I did it again. Re-run from
a detached driver whose monitor only watches a sentinel file.

**The first clean-clone run failed at step 66**, correctly:

```
FAIL: --verify-source refused: STOP: the working tree is not clean;
      a ceremony runs from reviewed bytes only
FAILED: Capability execution generation 20 installer (exit 1)
Validation stopped at step 66. Nothing after it ran.
```

`install-generation-20.sh` hard-codes `REPOSITORY="/opt/schott-platform"`, so a
clone-run suite inspects the **host** checkout — and this report and the ceremony
artifact were sitting there untracked. **This is the identical mistake I made and
wrote down at an earlier ENG-0005 checkpoint.** The suite behaved correctly in
both cases. Re-run after committing, with the host tree clean.

Neither mistake touched production or changed a result; both cost a full
validator run.

### CI, stated precisely

**`8853d51` is 6/6 green — Semgrep succeeded.** The previous commit `61a8f1d`
had Semgrep fail twice on `Docker pull failed with exit code 1`, which I reported
as 5/6 and declined to call green. That has now resolved: `61a8f1d` is an
ancestor of `8853d51`, so **its content is covered by the successful scan at
`8853d51`**, which scans that tree. The `61a8f1d` check-run itself still shows
failure and will not retroactively change; the content it introduced has been
scanned.

---

## E. Closure sequence, grounded in precedent

Taken from what the ledger records about ENG-0001 and ENG-0002 — the only two
increments that have completed a full closure — and independently verified:

1. **Closure report commit** — this report and the prepared ceremony.
2. **Ledger update.** Three statements are now false:
   - ENG-0005 row: "reviewer gate G7 is unentered, the design's §36 criteria have
     no criterion-by-criterion audit, and three recorded obligations are open".
   - ENG-0005 row: "the adapter is live through Generation **22**" — Generation
     23 is installed and accepted.
   - **ENG-0004 row and the prose at line 245**: "Release `v0.10.0` is
     authorised; the release record is integrating and **the tag is not yet
     created**". **`v0.10.0` exists** — an annotated tag at `9ee4a6c`, an ancestor
     of `origin/main`. Stale in two places. Whether ENG-0004's correction belongs
     in ENG-0005's closure is the reviewer's call; it is listed because G7 found
     it.
3. **Independent review** — conducted and attested **outside GitHub**; the
   operator's attestation is the provenance, not a repository artefact. **Operator
   boundary.**
4. **Merge to `main` via pull request** — a merge commit, not a fast-forward or
   squash. **Operator boundary.**
5. **Annotated, UNSIGNED tag** on the merge commit. *The tag alone is the
   release*: no GitHub Release object, no release branch, no release commit, no
   release PR, **and no release-notes file — this project has none.** **Operator
   boundary.**
6. **Ledger update** recording reviewed commit, merge commit, PR number, tag, date.
7. **Branch: RETAIN.** No prior increment's branch is recorded as deleted.

**Verified rather than remembered:** all 21 tags are annotated tag objects and
`git cat-file tag` shows **no PGP signature block** on v0.9.7, v0.9.8, v0.9.9 or
v0.10.0 — so "annotated, unsigned" is measured. *(My first check for this was
wrong: `git tag -v` prints "no signature found" for an unsigned tag, and grepping
for the word reported all 21 as signed. Corrected by looking for the PGP block.)*

**The version number is not decided here.** Latest is `v0.10.0`; precedent is a
minor bump per increment (ENG-0002 → v0.9.8, ENG-0004 → v0.10.0), pointing at
`v0.11.0`. That is an inference from two data points and the operator's call.

---

## F. Evidence inventory

### KEEP — everything in the governed stores

| item | why |
|---|---|
| `CINV-000001..3`, `CRES-000001..2`, `CADM-000001..7`, `CMUT-000000000001..12` | immutable production record evidence |
| `execution/transitions/CINV-00000{1,2,3}.*` | the lifecycle journal; the only durable record of state order |
| `execution/CINV-000003/launch-authorisation` | the authority under which production executed |
| `/data/kyri/capability-handoff/CINV-000003/` **including `out/`** | `CADM-000003` records `handoff_retained: true`; `out/` is also the real-kernel §13 transfer evidence |
| `capability-runtime/staging/tree-sha256-6f2282…` | referenced by `CINV-000003.staged_path`; removing it would orphan a record field |
| `/data/kyri/work/g11bb`, `g11bb2`, `g11bcn`, and the four stage witnesses | **six suites depend on them** for spent-mode branching |
| `/data/kyri/nothing-here` | **not residue** — `test-capability-mutation-target-explicit.sh:361` uses it as an empty store to prove a mutator names its target |
| all frozen inputs in `/etc/kyri/fabric` | the reviewed inputs every production record was written from |
| superseded freeze artifacts (AM/AN/AO/AP/AR/AS) | historical evidence; each is marked DO-NOT-RUN with its original pins |
| ADRs, the §36 audit, all checkpoint reports, the two incident records | accepted decisions and incident evidence |

### CLEAN — nothing in scope

Nothing in the governed stores, the repository or `/etc` is authorised for
removal, and **nothing is proposed**. Two clarifications, since I checked:

- **No rehearsal scratch survived.** Every `mktemp -d -p /data/kyri` directory
  this session created was removed at the end of its step; none remains.
- **`/data/kyri/scratch` is not mine** — an empty platform directory created
  2026-08-03 alongside `artifacts`, `backups`, `datasets` and `exports`. My first
  glob matched it by name and I nearly reported it as leftover.
- `/data/kyri/trackb-test` (2026-08-11 fixture) is the only item whose removal
  might be defensible. **I am not proposing it**: no governance text authorises
  it, and §F's rule is not to remove evidence merely because it is superseded.
- No temporary OCI archive or throwaway fixture tree is present anywhere under
  `/data/kyri`.

My own scratchpad (206 MB) is outside the repository and the governed stores.

---

## G-BIS. Reviewer disposition, recorded 2026-10-10 — THIS GATE DID NOT PASS

**F7 reviewer ruling: BLOCKING. G7 operator closure: NOT AUTHORISED.**

The reviewer ruled that ENG-0005 may not close while the released runtime
validator rejects the production state the released execution path produced, and
`capability validate` returns `EXIT_DENIED` on any finding. §C below offered my
assessment that F7 was non-blocking and named this as the reviewer's call; the
call went the other way.

**Nothing in this report has been rewritten.** The decision in §G stands as what
I concluded on 2026-10-09, with the information and the judgement I had. It is
historical evidence of the finding and of the recommendation that was not
accepted, which is more useful than a document edited to look right afterwards.

The remediation is [G11-BC-AV](2026-10-10-g11-bc-av-f7-remediation.md), which
leaves this gate re-enterable once Generation 24 is installed.

---

## G. Decision

**`READY_FOR_OPERATOR_CLOSURE`.**

No §36 blockers (11 PASS, 4 accepted findings, 0 BLOCKED). O1–O6 disposed. No
unexplained production mutation — all four Fabric writes reconstructed to exactly
their predecessor baseline, and all 12 CMUT carry intent and outcome. Final
baselines accepted and re-measured. Occupancy 0/2 from the released rule. F1–F7
reviewed with owners. Validation acceptable. Closure sequence identified from
precedent and prepared to the operator boundary.

**Three things the reviewer should decide, not me:**

1. **F7** — whether a non-empty `capability validate` report against production
   blocks closure. My assessment is no, for the reasons in §C; if the answer is
   yes, this is BLOCKED.
2. **Whether ENG-0004's two stale ledger statements** are corrected in this
   closure or separately.
3. **The version number**, and whether the independent review of a 452-commit
   branch is one review or staged.

**One honest limit carried forward:** real quota application is still unproven
(§36 audit §6), and O3's live-matrix evidence expires `2026-10-13T06:25:00-05:00`
— after which the matrix masks again with nothing regressed, and a live re-run
would need the renewal ceremony first.
