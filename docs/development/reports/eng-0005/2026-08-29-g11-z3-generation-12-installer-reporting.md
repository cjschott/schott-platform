# ENG-0005 G11-Z3 — Generation-12 installer reporting integrity and journal evidence closure

**Date:** 2026-08-29
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `fc4e6d2ca7ee021cf2937a1e61e34df215e35eec`
**Implementation commit:** `b6accf11142e6b284fa7b3d5f2ad8f12de579fe0`
**Report written:** during G11-Z5, after the operator's live verification

The Generation-12 ceremony installed Generation 12 and announced Generation 11
throughout. The transaction was correct; the operator-facing strings were the
predecessor's. This checkpoint corrected the strings, changed no behaviour, and
closed the privileged journal and evidence observations G11-Z2 could not make.

This report was deferred: G11-Z3's own Phase 8 gated it on a live read-only
`--verify-installed`, which the operator ran after the correction was committed
and before G11-Z4. It is recorded here rather than backdated into history.

---

## 1. Privileged journal and evidence closure

G11-Z2 could not read `/root`. The operator ran the read-only commands. Note
that the journal file is **`journal`**, not `state` — derived from the installer
(`JOURNAL="${TRANSACTION_ROOT}/journal"`, and `journal_state()` reads it with
`sed -n 's/^state=//p' | tail -1`) rather than guessed.

Observed:

| Property | Value |
| --- | --- |
| G12 journal state | `COMMITTED` |
| transaction | `gen12-20260829T133528Z-157483` |
| commit | `1313df019472a73e139cfc294ee8e016ad1355c0` |
| baseline_commit | `6016d4f0b8cfea9bfc8f60166b7cba5a2fa82a75` |
| package_dir_created | `yes` |
| target1–target6 | REPLACE |
| target7–target19 | CREATE |
| progress | all 19 `TARGET` |
| `/root/kyri-gen11-transaction` | exists |
| `/root/kyri-gen12-transaction` | exists |
| `/root/kyri-gen11-{library,helper}-digests.txt` | exist |
| `/root/kyri-gen12-{library,helper}-digests.txt` | exist |

This closes the three items G11-Z2 left open:

- `G11_JOURNAL_PRESERVED = YES` — the predecessor's transaction directory is
  intact beside Generation 12's own.
- `G12_JOURNAL_STATE = COMMITTED` — read directly, no longer inferred from the
  installer's own gate.
- `G12_EVIDENCE_PRESENT = YES`.

The journal's own contents corroborate the G11-Z2 forensics independently: six
REPLACE rows, thirteen CREATE rows, all nineteen at `TARGET`, against the same
reviewed commit the repository pins.

## 2. Reporting defect — RED

Twenty assertions were added to `tests/test-capability-execution-generation12-installer.sh`
as PART 7 and failed first against the uncorrected installer. They assert both
directions — the corrected phrase present **and** the stale phrase absent — so no
assertion can pass while a stale line survives beside it. Counts derive from the
parsed matrix, never typed in.

RED: **20 FAIL / 55 PASS**, exit 1. Parts 1–6 unchanged and passing throughout.

Three PART 7 assertions passed from the start, by design, as overcorrection
guards: `--verify` still describing the pre-install host as Generation 11,
`--verify` on an installed host already saying "already at Generation 12", and
the CREATE count already deriving from `matrix_count_of`.

## 3. Matrix reporting and vocabulary correction

Twenty-four sites changed. Counts derive from `matrix_count_of REPLACE` and
`matrix_count_of CREATE`, so a future matrix change cannot leave the operator
output lying.

| Before | After |
| --- | --- |
| `19 CREATE operations` | `6 REPLACE, 13 CREATE, 19 changed objects` |
| `19 objects created and verified` | `19 objects published and verified (6 replaced, 13 created)` |
| PREPARE, silent on retained predecessors | `… 13 pathnames reserved, 6 predecessors retained` |
| `Generation-11 evidence written; Generation-11 evidence preserved` | `Generation-12 evidence written; Generation-11 evidence preserved` |
| `all 19 installed Generation-11 objects correspond…` | `all 19 Generation-12 changed objects correspond…` |
| `every Generation-11 runtime object is exactly its accepted baseline` | `every carried-over runtime object is exactly its accepted Generation-11 baseline` |
| `Generation 11 / … install: all checks passed` | `Generation 12 / … install: all checks passed` |
| `Generation 11 / … verify-installed: all checks passed` | `Generation 12 / … verify-installed: all checks passed` |

Also corrected: the recovery outcomes, the post-COMMITTED injection messages,
the `GEN10=`/`GEN11=` classification labels (the counters are
`BASELINE_COUNT`/`TARGET_COUNT`), and the `UNKNOWN bytes` message, which now
names both dispositions rather than only the predecessor.

**Two sites found during implementation that the audit had under-classified:**
the `--verify-installed` guards test `GEN12_LIBRARY_EVIDENCE` and
`GEN12_HELPER_EVIDENCE` but reported them as Generation-11. Corrected, and both
pinned in the test.

Predecessor references that are correct were deliberately left alone — the
pre-install host really is at Generation 11, rollback really does return to it,
and the carry-over objects really are its baseline. Comments were corrected at
the atomicity note ("nine" → "nineteen") and the rollback header, which claimed
the matrix was all CREATEs and that the REPLACE branch was never taken.

GREEN: **77 PASS / 0 FAIL**, exit 0.

## 4. Behavioural non-change proof

The installer from `fc4e6d2` and the corrected one were driven through identical
scenarios against identical fixtures, comparing everything except stdout and
stderr: exit status, installed bytes, modes, journal contents and evidence
contents.

Scenarios: `verify`, `install`, `verify-installed`, already-installed,
`recover`, injected failure at `prepare`, `directory`, `publish`, `precommit`
and `verify`, recover-after-failure, and the unknown-bytes refusal.

**35/35 identical.** Two normalisations were required and both are forced by the
harness rather than the installer: the transaction id embeds `date -u` and `$$`,
and the fixture root necessarily differs per side. My first two harness attempts
were wrong on exactly those points and reported differences that were mine.

## 5. Live corrected verification

The operator ran, read-only, after the correction was committed:

```
sudo bash provisioning/execution/install-generation-12.sh --verify-installed
```

Observed, as supplied by the operator:

- all 19 Generation-12 changed objects correspond to reviewed commit
- Trust read path exactly as declared
- every carry-over runtime object matches the accepted Generation-11 baseline
- Trust package contains only declared objects
- both sudoers grants remain absent
- no transaction artefacts remain
- `Generation 12 / installed Fabric dependency closure verify-installed: all checks passed.`

The final banner is the line this checkpoint existed to correct, and it now names
the generation that is actually installed. This is the operator's reported
summary of the run, recorded as such; it is not a verbatim transcript.

No `--install` was run. No runtime was written.

## 6. Generation-12 digest unchanged

| Property | Value |
| --- | --- |
| Installed `.py` objects | 70, before and after |
| Aggregate digest | `9cbfd043af106c42bf024a07314b19de362d9a0cb10a9aca81b1ee608ce33830`, before and after |

A reporting correction must not move the runtime, and it did not.

## 7. What this checkpoint discovered and did not fix

Quick and full validation were run and **failed** — at the same step, with the
same message, at the pre-Z3 HEAD. Three suites encoded a Generation-11 live host
and went red the moment G11-Z2 installed Generation 12:

- `test-capability-execution-generation12-packaging.sh` — asserted a 57-object
  installed baseline;
- `test-capability-execution-generation11-installer.sh` — asserted the installed
  Fabric package lacked modules Generation 12 legitimately adds;
- `test-fabric-runtime-install-closure.sh` — called
  `verify_selected_evidence()` with the pre-G11-X signature, which the installed
  runtime correctly refused. That suite failed *because G11-X works*.

None was caused by the reporting correction, proved by stashing it and observing
the identical failure. They were not fixed here, because deciding what those
suites should assert about a post-Generation-12 host is a change to host-state
expectations rather than vocabulary.

**They were resolved in G11-Z4** (`a2e4bee`), which returned quick to 78/78 and
full to 101/101.

## 8. Actions not performed

No install, reinstall or recover. No stage, no invoke, no CINV, no adapter, no
execve. No sudoers installed. No journal or evidence file written or modified —
the only `/root` access in this checkpoint was the operator's read-only
observation in §1. No Fabric, Trust, Artifact or Platform Evidence mutation. No
transaction state machine, classification, matrix, digest, publication order,
rollback, recovery, journal format or evidence content changed.

One item was deliberately left: the Generation-12 evidence header records
`predecessor generation 10`, which is stale — Generation 12's predecessor is
Generation 11. Evidence contents were explicitly out of scope for a
reporting-only correction, and changing them would alter what a future install
writes. Recorded for a reviewer to rule on.

## 9. Disposition

`INSTALLER_REPORTING_DEFECT` is closed. `INSTALLER_STATE_LOGIC_DEFECT` was and
remains NO. The installed runtime was never in question and never moved.

Carried forward unchanged:

- `NEXT_ROUTE_WRITE_BLOCKED_PENDING_HEAD_HARDENING=YES`
- `ADMISSION_DEPENDENCY_BOUND_STRUCTURAL_HARDENING_PENDING=YES`
- `ELIG6_ADVERTISEMENT_HEAD_POLICY=UNRESOLVED`
