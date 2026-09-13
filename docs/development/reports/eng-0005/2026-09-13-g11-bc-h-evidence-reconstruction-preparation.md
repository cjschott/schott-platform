# ENG-0005 G11-BC-H — evidence reconstruction, prepared and unexecuted

**Checkpoint:** G11-BC-H (preparation only)
**Date:** 2026-09-13
**Branch:** `arch/eng-0005-execution-transition`
**Reviewer decision carried in:** `EVIDENCE_REMEDIATION_OPTION=1`,
`RECONSTRUCT_AND_RECORD=APPROVED_IN_PRINCIPLE`

Nothing under `/root` was written. CINV-000002 was not executed, `recover` was
not run, CRES-000001 was not created, and no runtime, helper, Fabric, Trust,
sudoers, handoff or invocation state was touched. This checkpoint produced a
ceremony, a test suite, and this report.

The object of the exercise is not to recover the lost evidence. It cannot be
recovered. The object is to produce **truthful evidence that says plainly it is
a reconstruction**, so that the record is honest in both directions: about what
the ceremonies did, and about the fact that nobody watched them do it.

---

## 0. What was lost, restated precisely

At G11-BC-E the helper ceremony carried `HELPER_EVIDENCE` over verbatim from the
ceremony it was derived from. The constant named
`/root/kyri-g11-bb-helper-digests.txt`. A **successful** G11-BC-E run therefore
wrote its own evidence over G11-BB's artifact, and the content it wrote also
self-identified as `ceremony g11-bb-helpers` at `runtime_generation 14`.

Two artifacts are wrong as a result, in different ways:

| artifact | what is wrong |
| --- | --- |
| `/root/kyri-g11-bb-helper-digests.txt` | contains BC-E's evidence; G11-BB's original bytes are gone |
| `/root/kyri-g11-bc-e-helper-digests.txt` | does not exist; BC-E's evidence was never written here |

The defective file is simultaneously the only surviving record of the BC-E run's
transaction identifier. That is why it is archived rather than deleted.

---

## 1. G11-BB, reconstructed from reviewed sources only

The constraint governing this section was explicit: do not derive historical
values from today's installed helper bytes unless the historical report says
they were identical. **They are not identical**, and this matters concretely —
`kyri_exec_transition_action.py` moved `b11a2f19…` → `d40f5121…` at G11-BC-E.
Reading today's host would have produced a G11-BB artifact stating a digest
G11-BB never saw.

Every reconstructed field is therefore taken from one of exactly two durable,
reviewed sources, and each field in the written artifact names its own source:

| field group | source |
| --- | --- |
| `delta` rows (3 objects, predecessor → target, closure) | the committed matrix of `install-g11-bb-helpers.sh` at `ef4f7446200b668f8dcbf34d180c5102270f19f6` |
| `installed` rows (measured digests) | `2026-09-06-g11-bb-r-helper-deployment-acceptance.md` §1, measured on the host immediately after the ceremony |
| `runtime_readiness compatible` | that same report, §2, measured |
| `commit`, `runtime_commit` | `ef4f7446…` |

The reconstruction carries `installed_note` recording that these are the digests
**as of G11-BB, not as of today**, and naming the object that has since moved.

### 1.1 A replica would have been dishonest

The lost artifact stated `runtime_generation 14`. That was false when it was
written: G11-BB required the Generation-15 readiness rule
`6dd936064f1c6d3813cbdbd9fb175b03902b18623493638cded55e3e930b8b07`, so it ran
against Generation 15. The `14` was itself an inherited constant, carried from
`install-g11-ax-helpers.sh` — where `14` *was* correct. This is the same
inherited-constant defect class as the `HELPER_EVIDENCE` bug, one ceremony
earlier and previously unnoticed.

A bug-for-bug replica of the lost file would have re-recorded a known-false
field into fresh evidence. It is refused. The reconstruction states:

```
runtime_generation 15
runtime_generation_in_lost_artifact 14
runtime_generation_correction the lost artifact inherited 14 from
  install-g11-ax-helpers.sh; G11-BB required the Generation-15 rule 6dd93606…
```

Both the truth and what the lost artifact said are on the record.

### 1.2 What is NOT recoverable is marked so

The original carried `transaction <id>` built from a timestamp and a pid. No
reviewed source records it. The reconstruction writes:

```
transaction UNRECOVERABLE
transaction_note the original carried a runtime-generated identifier; it is not
  derivable from any reviewed source and is not invented here
```

An invented plausible identifier would have been the single most damaging thing
this ceremony could write.

---

## 2. G11-BC-E, recorded at its correct path

BC-E's evidence is a different problem: it is not lost, it is misfiled. Its
values come from the committed matrix at
`15a8c738f97394a4f114070c011db22562466ed6` and from **current measurement of the
installed host**, which is legitimate here because BC-E is the deployment
currently installed. `installed` and `runtime_readiness` are both stamped
`measured on this host at remediation time`.

Its transaction identifier is likewise not reinvented; the artifact points at
the archive, which preserves the only copy that ever existed:

```
transaction UNRECOVERABLE
transaction_note … the artifact that recorded it was the one written to the
  wrong path, and its value is preserved in
  /root/kyri-g11-bb-helper-digests.defective-bc-e.txt
```

---

## 3. Namespaces, derived rather than chosen

Two evidence families already exist in the tree and they use different
conventions:

| family | pattern | keyed by |
| --- | --- | --- |
| generation | `/root/kyri-gen<N>-{library,helper}-digests.txt` | generation number |
| helper ceremony | `/root/kyri-g11-<tag>-helper-digests.txt` | ceremony tag |

The helper-ceremony family is already namespaced **by ceremony tag** — `g11-ax`,
`g11-bb`. The defect was not a missing convention; it was a ceremony failing to
follow the one that existed. So `g11-bc-e` takes its own tag in the established
pattern rather than any new scheme:

```
/root/kyri-g11-bc-e-helper-digests.txt
```

The corrected `install-g11-bc-e-helpers.sh` now also refuses at runtime if its
`HELPER_EVIDENCE` resolves to any `g11-ax` or `g11-bb` path
(`require_namespace_isolation`), so the class cannot recur silently in that
script.

The reconstruction and the archive take suffixes on the G11-BB stem, so that
`ls /root` sorts them adjacent and the relationship is legible:

```
kyri-g11-bb-helper-digests.defective-bc-e.txt    the preserved defective bytes
kyri-g11-bb-helper-digests.reconstructed.txt     the reconstruction
```

### 3.1 The canonical G11-BB pathname is left ABSENT

`/root/kyri-g11-bb-helper-digests.txt` is **not** recreated. A reconstruction
written there would be indistinguishable from an original to anything that only
checks existence, and the original is gone. Absence is the honest state. The
reconstruction gets a name that says what it is.

---

## 4. The defective artifact is preserved, not deleted

`cp -a` to the archive, digest-verified against the source, and only then is the
original removed. The archive is the same bytes, same mode, same owner.

**`DEFECTIVE_ARTIFACT_SHA256` is not stateable in advance.** The artifact
contains a runtime-generated `transaction` line, so no reviewed source predicts
its digest; and `/root` is unreadable from this session (sudo is
password-gated), so it cannot be measured now. The design accounts for this
rather than working around it:

- the gate on the artifact is **structural**, not a digest pin;
- the digest is **computed at remediation time**, printed by `--verify`, written
  into the journal, and embedded in both reconstructions as
  `overwriting_artifact_sha256` / `as_written_artifact_sha256`.

The reviewer therefore receives the true digest from the `--verify` output,
before `--apply` is authorised.

### 4.1 The structural gate

Three facts must hold together before anything is archived, and no other file in
this deployment satisfies all three:

```bash
grep -q "^ceremony g11-bb-helpers$"   # claims to be G11-BB
grep -q "^commit ${BCE_COMMIT}$"      # but carries BC-E's commit
grep -q "${BCE_TARGET}"               # and BC-E's target digest
```

plus an explicit refusal: if the file carries `commit ${BB_COMMIT}`, it **is**
genuine G11-BB evidence and the ceremony halts rather than archiving it. Policy
permits moving root evidence, so no alternative preservation scheme was needed;
the bytes are preserved either way, because the removal happens only after a
verified copy exists.

---

## 5. Provenance is in the content, not just in this report

Both artifacts open with a provenance block before any `ceremony` line:

```
evidence_status reconstructed
evidence_of ceremony g11-bb-helpers
reconstructed_at <stamp>
reconstructed_by docs/development/reports/eng-0005/2026-09-13-g11-bc-h-…
reconstruction_reason …
defect_report docs/development/reports/eng-0005/2026-09-13-g11-bc-g-…
overwriting_artifact_archived_at /root/kyri-g11-bb-helper-digests.defective-bc-e.txt
overwriting_artifact_sha256 <computed>
not_original_ceremony_output true
installed_state_unchanged_by_reconstruction true
```

Nothing in either file claims to be original ceremony output. A reader who opens
either one learns it is a reconstruction in the first line.

---

## 6. Readers — swept, and none exist

Every reference to a `kyri-g11-*-helper-digests` path in the tree was
enumerated. Each is one of:

- an assignment inside the ceremony script that *writes* that path, or
- a fixture path inside a test root.

No installer, verifier, operator block, succession reader or capability record
consults one in production. The generation-evidence family
(`kyri-gen*-{library,helper}-digests.txt`) is a separate namespace and is not
touched by this remediation.

```
EVIDENCE_READERS_SAFE_AFTER_REMEDIATION=YES
CODE_CHANGE_REQUIRED=NO
```

This is also why the installed deployment remains sound despite the defect: the
deployment was verified correct at G11-BC-G §1 **without reading any evidence
file**, from installed bytes directly.

---

## 7. History is not rewritten

No committed report, ceremony script, capability record or invocation entry was
edited to make the past look different. The G11-BC-G report continues to say the
evidence was destroyed. This report is additive. The archived artifact keeps the
defective bytes exactly as the defective run produced them.

---

## 8. The operator ceremony — prepared, NOT RUN

**Script:** `provisioning/execution/remediate-g11-bc-g-evidence.sh`
**Operator block:** `provisioning/execution/g11-bc-g-evidence-remediation-ceremony.txt`

`set -Eeuo pipefail`, shellcheck clean, root-only, `--verify` / `--apply` /
`--recover`. It installs no object, reads no capability record, and touches
nothing outside three files and one journal directory under `/root`.

Fail-closed properties, each proven by the suite in §10:

1. `--verify` is read-only and must pass before `--apply`; the operator block
   chains them so a refusal stops the run.
2. The artifact is identified structurally, and genuine G11-BB evidence is
   refused explicitly.
3. **No destination is ever overwritten** — three collisions, three refusals.
   Overwriting an evidence file is the defect being repaired.
4. The archive copy is digest-verified before the original is removed.
5. The installed deployment is verified against the evidence being written: if
   the action module is not `d40f5121…`, the readiness rule is not the
   Generation-17 `78da8519…`, or any still-observable G11-BB object has drifted
   from what G11-BB-R measured, `--apply` halts **before writing anything**
   rather than record a claim the host does not support.
6. Every write is `0400 root:root`, `.writing` → `mv -f`.
7. A journal records each boundary: `ARCHIVING` → `ARCHIVED` → `BB_PUBLISHED` →
   `BCE_PUBLISHED` → `COMPLETE`.
8. A completed remediation refuses to run again, and says *why* — that the
   journal is `COMPLETE`, not the misleading "there is nothing to archive".
9. Unrecoverable fields are written as `UNRECOVERABLE`, never invented.
10. `--fixture` rebases every path, so the suite never reads or writes the host.

The exact operator block is in §13.

---

## 9. Interruption and recovery

The archive is the hinge. Before the defective bytes are durable, rollback is
total; after, the run must not silently redo itself.

| journal state | `--recover` behaviour |
| --- | --- |
| `NONE` | halts: nothing to recover |
| `ARCHIVING` | rolls back completely — partial archive removed, source intact, rerunnable |
| `ARCHIVED` | **halts: operator disposition required** |
| `BB_PUBLISHED` | **halts: operator disposition required** |
| `BCE_PUBLISHED` | **halts: operator disposition required** |
| `COMPLETE` | reports completion |

Past `ARCHIVING`, automatic resumption would mean a program deciding on its own
what a partially-written evidence record should say. That decision is the
operator's.

---

## 10. Test suite

**`tests/test-capability-execution-evidence-remediation.sh`** — 62 assertions,
all passing, unprivileged, entirely fixture-bound. Host-only: the fixture copies
the installed helper objects, because the ceremony verifies its evidence against
the deployment actually installed.

| section | covers |
| --- | --- |
| A | clean remediation: verify is inert, apply archives byte-for-byte, canonical path left absent, both outputs `0400` |
| B | honesty: `evidence_status`, `not_original_ceremony_output`, `transaction UNRECOVERABLE`, generation corrected **and** the lost value disclosed, every fact carries a `*_source` |
| C | ten refusals: genuine-BB artifact, foreign artifact, missing target, absent artifact, wrong action module, wrong runtime rule, drifted BB object, and three destination collisions. Each asserts the **named reason** and that the refusal wrote nothing |
| D | rerun after completion refuses, naming the completed journal; the archive is untouched |
| E | interruption at `ARCHIVING` (rolls back, then reruns clean), `ARCHIVED` and `BB_PUBLISHED` (operator disposition) |
| F | isolation: production paths unread and unwritten |
| G | the operator block is committed, sets `-Eeuo pipefail`, runs `--verify` before `--apply`, and names the ceremony script |

### 10.1 A defect the suite caught

The refusal cases originally asserted only a non-zero exit. Requiring each to
name its reason — and to leave the destination set byte-identical — exposed a
real fault: `require_source_authorities` reports drift non-fatally so `--verify`
can show every problem at once, and `--apply` was inheriting that leniency. On a
drifted host it wrote both evidence files and *then* reported failure. `--apply`
now halts on any failed authority check before the first write.

"It exited non-zero" is a weak assertion. A refusal for an incidental reason
satisfies it while proving nothing about the gate under test.

Registered in `tools/dev/run-validation.sh` (`TOTAL_STEPS` 112→113 quick,
137→138 full), `.github/workflows/ci.yml`, and `tests/host-only.manifest`.

---

## 11. Production non-mutation

Measured directly this checkpoint, unprivileged, from installed bytes:

| item | value |
| --- | --- |
| `tools/capability/execution/helpers.py` | `78da8519db99fa06e809755808397fe36bb8c83872deab142987c98308b38a4f` |
| `kyri_exec_transition_action.py` | `d40f5121a3a358ee4351ac760c2bcc7f259b229c4190635e832814672c0c21de` |
| `kyri_exec_launcher.py` | `152038b198c112c3f5f042114eb6e7f4ffa3a9caeb431908bfe7f208b136447d` |
| `kyri_exec_podman.py` | `04205c53ec0e10bef13099dd3a84c483e43ed9441335805665f957a5bbdd896b` |
| `helpers.compatibility()` | verdict `compatible`, `compatible True`, blocking 0 |

All match Generation 17 as accepted at G11-BC-G.

**Carried forward from G11-BC-G, NOT re-measured here.** `/var/lib/kyri` is
`drwx--x--x root:root` and `/root` is unreadable, so this session cannot read
the capability store without privilege — and acquiring privilege to read it was
outside this checkpoint's authority:

| item | last measured value | last measured |
| --- | --- | --- |
| CINV-000002 | `923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa`, `launch_authorized` | G11-BC-G |
| `INVOCATION_SEQ` / `CRES_COUNT` | 2 / 0 | G11-BC-G |
| Fabric / Trust | `3fa32b83…` / `53605e4e…` | G11-BC-G |
| handoff `out/` | `cschott:cschott 0700` | G11-BC-G |

Nothing this checkpoint could have changed them: no privileged command was run,
and every test is fixture-bound. The §9 pre-resume operator block in the
G11-BC-G report remains the read-only way to confirm them before any resume.

Nothing under `/root` was written. Stage 3 remains unauthorised.

---

## 12. Defect classes

This is the **third** recurrence of the inherited-constant class
(`ACCEPTED_INVOCATION_HISTORY`; `HELPER_EVIDENCE` at G11-BC-E; and
`runtime_generation` at G11-BB, found only while reconstructing it here). The
pattern is consistent: a ceremony is derived from its predecessor, and a
constant that was correct for the predecessor is carried forward unexamined.

`require_namespace_isolation` addresses the path constant in one script. It does
not address the class. A generic guard — every ceremony asserting that its own
evidence path and generation number are derived from its own identity rather
than inherited — is the obvious next correction and is **not** in this
checkpoint's scope.

---

## 13. Return

```
EVIDENCE_REMEDIATION_READY=YES
EVIDENCE_REMEDIATION_EXECUTED=NO
BB_EVIDENCE_RECONSTRUCTED=PREPARED
BCE_EVIDENCE_PREPARED=YES
DEFECTIVE_ARTIFACT_PRESERVED=PREPARED
DEFECTIVE_ARTIFACT_SHA256=NOT_COMPUTABLE_IN_ADVANCE (runtime transaction id;
  computed and printed by --verify, recorded in both reconstructions)
EVIDENCE_NAMESPACE=/root/kyri-g11-<ceremony-tag>-helper-digests.txt
EVIDENCE_READERS_SAFE_AFTER_REMEDIATION=YES
CODE_CHANGE_REQUIRED=NO
HISTORY_REWRITTEN=NO
PRODUCTION_MUTATED=NO
TESTS_ADDED=tests/test-capability-execution-evidence-remediation.sh (62 assertions)
```

```
EVIDENCE_REMEDIATION_COMMAND:
set -Eeuo pipefail
cd /opt/schott-platform

# STEP 1 -- read-only. Return this output for review BEFORE step 2.
sudo bash /opt/schott-platform/provisioning/execution/remediate-g11-bc-g-evidence.sh --verify

# STEP 2 -- only after step 1 is reviewed and accepted.
sudo bash /opt/schott-platform/provisioning/execution/remediate-g11-bc-g-evidence.sh --verify \
  && sudo bash /opt/schott-platform/provisioning/execution/remediate-g11-bc-g-evidence.sh --apply
```

Expected after step 2:

```
/root/kyri-g11-bb-helper-digests.txt                  ABSENT
/root/kyri-g11-bb-helper-digests.defective-bc-e.txt   preserved bytes
/root/kyri-g11-bb-helper-digests.reconstructed.txt    0400 root:root
/root/kyri-g11-bc-e-helper-digests.txt                0400 root:root
```

If interrupted, do **not** rerun `--apply`. Run `--recover` and return its
output.

---

## Questions for reviewer

1. **Authorise `--apply`?** Step 1 is read-only and safe to run now; it returns
   the true `DEFECTIVE_ARTIFACT_SHA256`. Step 2 needs your word.
2. **Is `runtime_generation 15` for G11-BB accepted?** It contradicts what the
   lost artifact said. The reconstruction discloses both, but the correction is
   a judgement about the historical record and is yours to confirm.
3. **The generic inherited-constant guard** (§12) — separate checkpoint, or
   fold it in before Stage 3?
4. **Stage 3 remains unauthorised.** This remediation is independent of it; it
   does not block resume and resume does not block it.
