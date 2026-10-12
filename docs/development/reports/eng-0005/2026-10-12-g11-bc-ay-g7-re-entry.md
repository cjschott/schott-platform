# G11-BC-AY — G7 re-entry after accepted Generation-24 installation

**Date:** 2026-10-12 · **Branch:** `arch/eng-0005-execution-transition`
**Checkpoint:** G7 re-entry only. No implementation, no architecture, no Fabric
writes, no capability execution, no production mutation.

**DECISION: READY_FOR_OPERATOR_CLOSURE.**

G7 was entered on 2026-10-09 and the reviewer ruled it **BLOCKED on F7**.
Generation 24 closed F7; it has been independently reviewed, installed, and
accepted. This report re-enters that gate against the installed production state
and records the result. The
[historical G7 report](2026-10-09-g7-eng-0005-closure-readiness.md) is **not
rewritten** — its §G-BIS already records the BLOCKING ruling above the decision
it did not change.

---

## A. F7 — CLOSED by Generation 24

F7 was: *the released runtime validator reports two findings against production.*
`capability validate` returned `result-without-execution-authority` for
`CINV-000002` and `CINV-000003` and exited 1, because the validator tested
execution authority with `adapter_identity` — which `coordinator.py` states is
always null on the released path — and never read the lifecycle journal that
`launch.py` names as the authority.

Verified at this re-entry, from the installed tree and against live production:

```
$ cd /usr/lib/kyri/python
$ python3 -m tools.capability.cli validate \
    --store-root /data/kyri/capability-runtime \
    --expected-uid 1000 --expected-gid 1000
{
  "findings": [],
  "status": "reported"
}
exit=0
```

`findings: []` · `status: reported` · `exit 0` — the three conditions the brief
requires. The module actually executed resolves to
`/usr/lib/kyri/python/tools/capability/cli.py`, not the repository copy; this is
the verification path corrected at [G11-BC-AX](2026-10-12-g11-bc-ax-ceremony-installed-path.md).

Cross-check from the same installed runtime: the released authority verifier
returns `supported=True reason=None eligibility_reasons=[]`, and
`state.launch_authorised()` reports `['CINV-000001', 'CINV-000002',
'CINV-000003']` — read from journal history, which is why `CONCLUDED` and
`ABANDONED` both still prove the authority that produced their results.

**F7 is CLOSED.** Reconciled in the audit record at
[§7-BIS](../../audits/2026-10-09-eng-0005-section-36-closure-audit.md) — appended,
not substituted, and including the fact that the §36 audit should have found F7
and did not.

---

## B. Generation 24 is installed, and its evidence is complete

All three matrix targets match the digests Generation 24 declares. Three rows,
**zero mismatches**:

| target | installed sha256 |
|---|---|
| `tools/capability/execution/state.py` | `87abff5bdde4ad29…` |
| `tools/capability/inspection.py` | `1c2d27d7f003e70e…` |
| `tools/capability/cli.py` | `211cf173e780d703…` |

**`--verify-installed` was not independently re-run at this checkpoint.** At my
privilege every assertion fails with
`sed: can't read /root/kyri-gen23-library-digests.txt: Permission denied` — a
privilege failure, not a finding. It is an operator-run check, and the ceremony
runs it under `sudo`. The evidence standing in its place is the operator's
recorded acceptance plus the direct digest comparison above, which reads the same
three objects the matrix governs. **This is a stated limitation of my evidence,
not a gap I am asserting away.**

**No Generation-24 transaction residue.** `/root/kyri-gen24-transaction` is not
accessible to me (`Permission denied`, so I cannot distinguish absent from
unreadable — the operator's `--verify-installed` run can); the library root holds
**zero** `*kyri-gen23*`/`*kyri-gen24*` residue files.

---

## C. Production state — unchanged

Measured at `2026-10-12T09:45:02-05:00` with the aggregate
`find <root> -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum`, paths
rewritten to absolute so a copy compares equal:

| store | aggregate | |
|---|---|---|
| `/var/lib/kyri/fabric` | `7e2a4ed0e9c11cf1f3790360542232649946a9bf31400e9dd442d8c2ad2f376b` | **MATCH** |
| `/data/kyri/capability-runtime` | `7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99` | **MATCH** |
| `/var/lib/kyri/trust` | `53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f` | **MATCH** |

The installed library aggregate **did** move, to
`93d48bf8df3b0ee785e65fa0304acf3bb9fd3c2e7e09ac90f1e9026e738fab7f`. That is
expected and is the point of the generation: `/usr/lib/kyri/python` is not one of
the three governed stores.

**Lifecycle and occupancy**, computed from the installed `capacity` module rather
than asserted:

```
CINV-000001 abandoned
CINV-000002 abandoned
CINV-000003 concluded
NON_SLOT_HOLDING_STATES = ['abandoned', 'concluded', 'released']
OCCUPANCY = 0/2
```

**Counts**, all unchanged: CINV **3** · CRES **2** · CADM **7** (counter
`000007`) · CMUT **12** (counter `000000000012`) · transition records **9** ·
quarantine **0** · staging **1**. Each CADM carries `intent` + `outcome`
(+ `abandonment` where applicable); each CMUT carries `intent` + `outcome`.

**Helper and sudoers authority unchanged.** All **8** declared helpers in
`HELPER_SOURCES` match their repository sources byte-for-byte, **0** mismatched.
Both drop-ins are `root:root 440`. **No** setuid bit and **no** file capability
on any `/usr/libexec/kyri-exec-*`.

---

## D. O3 — still CLOSED at this re-entry

The live Stage-3 22-case matrix was re-run against production at this checkpoint:

```
rc=0 · 94 PASS / 0 FAIL
22/22 cases present · 22/22 fail-closed · 22/22 intended refusal
0 masked · 0 tracebacks · 0 occurrences of admission-window-not-open
PASS: BLOCK B passes against an unmodified fixture
```

Fabric and runtime aggregates were captured either side of the run and are
unchanged. Every accepted baseline is explicitly named; no scratch Fabric, no
substituted window, no synthetic authority, no reordered gates.

**Wall-clock bound, stated plainly.** This evidence depends on live admission
authority. `CADV-000008.valid_until` and `CINST-000007.admitted_until` are both
**`2026-10-13T06:25:00-05:00`**, and that deadline is the durable fact here — the
margin is not. The matrix ran at `09:39` with 20.8 hours left; by the time
validation finished and this report was completed, `18:43`, the margin was
**11.7 hours**. O3 is closed *now*. If operator closure happens after that
instant, the matrix needs re-running against renewed authority — not because
anything regressed, but because the thing it proves expires.

---

## E. Obligations

| | obligation | disposition |
|---|---|---|
| **O1** | legacy provenance compatibility | **CLOSED** (unchanged) |
| **O2** | ADR-0018 compatibility wording | **CLOSED** (unchanged) |
| **O3** | Stage-3 matrix | **CLOSED** — re-confirmed above, wall-clock bounded |
| **O4** | ledger correction | **DONE at this checkpoint** — see below |
| **O5** | reviewer G7 gate | **RE-ENTERED and PASSED to the operator boundary** |
| **O6** | criterion-by-criterion audit | **CLOSED**, plus the F7 addendum at §7-BIS |
| **F7** | validator rejects production state | **CLOSED by Generation 24** |

**O4, reconciled.** Three statements the historical G7 report found false are now
corrected:

- ENG-0005 row: "live through Generation **22**" → **Generation 24**; "G7 is
  unentered" → entered, blocked, re-entered; "§36 criteria have no
  criterion-by-criterion audit" → the audit is linked; "three recorded
  obligations are open" → O1, O2, O3 closed.
- ENG-0004 row: "the tag is not yet created" → released as `v0.10.0` at
  `9ee4a6c`.
- The prose at line 245 — **its original tense is preserved** and a dated
  correction appended beneath it, because that paragraph says "at the moment this
  record is written" and is legitimate history.

The ENG-0005 row now states what remains: **awaiting operator closure, not
independently reviewed as a whole, not merged, not tagged.**

Also reconciled: the ENG-0005 narrative section's four now-stale statements — the
§36 audit's absence, three open obligations, unrenewed Fabric authority, and an
unentered G7 — each answered in a dated subsection beneath the original prose
rather than by editing it; and the generation table, extended to 23 and 24.

**Accepted findings F1–F5 remain open**, and the ledger now records them. The
historical G7 report's disposition table required ledger entries for F1, F2 and
F3; all five are listed, with F2 named as the ranked carry-forward Fabric defect.
F6 and F7 are recorded as closed. They were accepted, not resolved, and closure
does not silently absorb them.

---

## F. Validation

| run | result |
|---|---|
| `run-validation.sh --quick` | **142/142 steps**, 8364 assertions, **0 FAIL**, 0 host-only skips |
| `run-validation.sh` (full) | **167/167 steps**, 21350 assertions, **0 FAIL**, 0 host-only skips |
| clean clone of `a5117b5` | **167/167 steps**, 20263 assertions, **0 FAIL** |
| CI on `a5117b5` | **6/6 green** — CI, ShellCheck, CodeQL, Semgrep, Trivy, Gitleaks |

**Two things worth reading precisely rather than at a glance.**

The one `FAIL`-prefixed line in each run is `FAILURE_INVOKE_E2E=PASS` — a variable
name, not a failure. A naive `grep '^FAIL'` reports 1 and is wrong. *(The inverse
of this mistake was made earlier in this arc, when a grep for `no traceback`
assertions was reported as 22 tracebacks.)*

Both runs carry exactly one skip, `note: skipped (Stage 3 is spent)` — the
coordinator half, the refusal matrix and BLOCK B against a fixture. That is spent
mode, **not** a host-only skip, and the live Stage-3 matrix in §D is the evidence
that covers it.

**The clone's 1087 fewer assertions are accounted for, not waved past.** The step
lists are byte-identical, all 167 pass in both, and the difference is confined to
**18** installer and ceremony steps — generation-6, -7, -9 through -14, the helper
ceremony, G5 authority, governed artifact authority, Fabric evidence authority and
the rest. Those suites assert less inside a clone because the installers they
exercise hard-code `REPOSITORY="/opt/schott-platform"`, so their host-dependent
assertions do not run. Eighteen is the same count the previous two checkpoints
recorded.

Step 66, the Generation-20 installer step that aborted in two earlier checkpoints
— once for a working tree made dirty by an uncommitted report, once for being
launched inside a monitor whose lifetime it shared — passed in both full runs.

**Production after all three runs**, re-measured at `2026-10-12T18:27:56-05:00`:
Fabric `7e2a4ed0…f376b`, runtime `7dfb34e6…2e99`, Trust `53605e4e…b63f` — all
byte-identical to §C. Everything exercised at this checkpoint is read-only
against production; nothing here mutates a store.

---

## G. Decision

**READY_FOR_OPERATOR_CLOSURE.**

The gate's blocking finding is closed and verified from the installed runtime;
production is unchanged across the generation; O1–O3 and O6 are closed; O4 is
reconciled in this commit. Two qualifications, both stated above rather than
buried: `--verify-installed` rests on the operator's acceptance plus my digest
comparison, because it needs privilege I do not have; and O3's evidence expires
`2026-10-13T06:25:00-05:00`, which was 11.7 hours after this report was finished.
If the operator crosses the boundary after that instant, re-run the live Stage-3
matrix against renewed authority first.

**Remaining steps are the operator's**, in the order precedent sets
([§E of the historical report](2026-10-09-g7-eng-0005-closure-readiness.md#e-closure-sequence-grounded-in-precedent)):
independent review attested outside GitHub → merge to `main` via pull request
(merge commit, not fast-forward or squash) → **annotated, unsigned tag, which is
itself the release** (no GitHub Release object, no release-notes file — this
project has none) → ledger update recording reviewed commit, merge commit, PR
number, tag and date → branch **RETAINED**.

The version number is not decided here. Precedent is a minor bump per increment,
pointing at `v0.11.0`; that is an inference from two data points and the
operator's call.

**I STOP HERE.** The prepared ceremony is
`provisioning/closure/eng-0005-g7-closure-ceremony.txt`, unexecuted.
