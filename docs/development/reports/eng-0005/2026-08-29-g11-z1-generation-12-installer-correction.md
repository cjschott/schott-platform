# ENG-0005 G11-Z1 — Generation-12 installer: real-host failure, root cause, and RED-first correction

**Date:** 2026-08-29
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `279d6c2b70e64f7e32bc0e0f920b57065c094c56`
**Predecessor report:** `docs/development/reports/eng-0005/2026-08-29-g11-z-generation-12-preinstall.md`
**Implementation commit:** `013fac1`

The reviewed Generation-12 ceremony failed on the production host. Nothing was
installed and nothing was damaged. Three defects were in the reviewed installer,
and all three came from the same mistake: it was derived from the Generation-11
installer without re-deriving what its gates asserted. A fourth was introduced
while correcting the third, and was caught by the fixture before it was
committed.

The host is a whole, unmodified Generation 11. Generation 12 is not installed
and was not installed by this checkpoint.

---

## 1. The operator incident

Two privileged commands were run against the host. Both halted. Neither
published anything.

**Command 1 — `sudo bash provisioning/execution/install-generation-12.sh --verify`**

Passed: repository authority; 19 source objects; the 59-module import closure;
the Generation-11 installed baseline; absence of transaction residue at the 19
target pathnames; sudoers gates closed. Then:

```
STOP: /usr/lib/kyri/python/tools/capability/cli.py is not inside the declared Fabric package directory
```

**Command 2 — `sudo bash provisioning/execution/install-generation-12.sh --install`**

Passed: source checks; closure; sudoers gates closed. Then:

```
STOP: the journal says COMMITTED but the targets do not agree; operator disposition required
```

**`--verify-installed`** then reported the six REPLACE targets still carrying
their Generation-11 digests, e.g. for `tools/capability/cli.py`:

```
installed:    c10bf11e8382face3d8020ea6be971c359f8a4bcd0b5fe9e862a460c0d7c4305
G12 expected: b45f5332dcd98f38c2479c13cca17e1e61c535b6a6b4b6e2c89beaebfc7c3d98
```

with the equivalent disagreement for `coordinator.py`, `evidence.py`,
`fabric_evidence.py`, `invocation_identity.py` and `records.py`.

That last output is the ceremony working. The installer refused to publish, and
then told the operator the host was still the predecessor generation. It is
evidence of a halt, not of damage.

No operator cleanup, recovery, journal deletion or manual runtime modification
was performed afterwards, which is what made the forensic proof below possible.

## 2. Forensic proof of the actual host state

Taken read-only, before any repair was written. Nothing in this checkpoint
wrote to `/usr/lib/kyri/python` or `/root`.

| Property | Observed | Meaning |
| --- | --- | --- |
| Installed `.py` objects | 57 | Exactly the Generation-11 surface |
| Content digest of all 57 | `80f9dee23a3e7934ee779c90284d152c1f13508ed1bcecc100fa7de5b0107f5b` | Matches the accepted Generation-11 evidence |
| Six REPLACE targets | present, at declared Generation-11 baseline digests | Not replaced |
| Thirteen CREATE targets | absent | Not created |
| `tools/trust/` | absent | The Trust plane was never published |
| `*.prepared` staged material | none | PREPARE never published anything |
| `*.kyri-gen12.gen11` backups | none | No REPLACE was ever begun |
| REPLACE target mtimes | 2026-08-12 … 2026-08-19 | All predate the 2026-08-29 ceremony |

The mtimes are the decisive part. Every one of them predates the failed
ceremony, so no target was written and restored — they were never touched at
all.

The count basis matters and is stated because it is easy to get wrong: 57 is
`.py` files. The same tree also holds 12 `__pycache__` artefacts, which are
interpreter output, not installed objects, and are excluded from both the count
and the digest.

**Host generation: 11. Whole, not mixed, not partially published.**

Journal state at `/root/kyri-gen11-transaction` is COMMITTED, from the accepted
Generation-11 install. `/root` is not readable by the working account and `sudo`
requires a password, so that value is carried from operator evidence and from
the Generation-11 acceptance record rather than re-read here. It is also exactly
what defect A predicts.

## 3. Root cause A — transaction namespace collision

The reviewed Generation-12 installer declared:

```bash
TRANSACTION_ROOT="/root/kyri-gen11-transaction"
```

along with a `gen11-` transaction id and a `KYRI_GEN11_FAIL_AT` fault-injection
variable. Generation 12 therefore opened the *predecessor's* journal as its own.

The install path reads that journal, sees `COMMITTED`, and classifies the
targets to decide whether it is looking at its own finished work:

- all targets Generation 12 → already installed, exit cleanly;
- otherwise → `halt "the journal says COMMITTED but the targets do not agree"`.

The host is Generation 11, so the targets could not agree, and the halt is
forced. This is the observed `--install` failure exactly, and it would recur on
every attempt: the retained Generation-11 journal is permanent historical
authority and is never going to stop saying COMMITTED.

The generation-11 journal is not the problem. Reading it is. It must be
preserved untouched, and Generation 12 must have its own namespace.

**CONFIRMED.**

## 4. Root cause B — invalid mixed-directory assertion

`require_same_filesystem()` looped the whole matrix and required each target's
directory to equal `PACKAGE_DIR` (`/usr/lib/kyri/python/tools/trust`).

That is true of Generation 11 by accident of its content: all nine of its rows
were CREATEs into a single package directory. It is false by construction for
Generation 12, whose matrix deliberately spans `tools/capability`,
`tools/fabric` and `tools/trust`. The first REPLACE row —
`/usr/lib/kyri/python/tools/capability/cli.py` — could never pass, which is the
observed `--verify` failure.

The property the check exists to guarantee is *atomic publication*: prepared
material must be staged on the same filesystem as the target it will replace, so
that publication is a `rename(2)` and never a cross-device copy. "Everything
lives in one directory" was a coincidence of Generation 11 that happened to
imply it.

**CONFIRMED.**

## 5. Initial RED evidence

`tests/test-capability-execution-generation12-installer.sh` was written first
and run against the uncorrected installer. It builds a fixture host that
reproduces the real one (§10) and drives the whole ceremony.

Against the uncorrected installer:

| Failing assertion | Observed |
| --- | --- |
| Generation 12 opens its own transaction root | `TRANSACTION_ROOT` resolved to `/root/kyri-gen11-transaction` |
| A retained COMMITTED Generation-11 journal does not halt Generation 12 | `STOP: the journal says COMMITTED but the targets do not agree` |
| `--verify` accepts the mixed target matrix | `STOP: …/tools/capability/cli.py is not inside the declared Fabric package directory` |
| `--install` publishes 19 objects | never reached |

Both halts reproduced mechanically, with the operator's messages verbatim,
before a line of the fix was written. That is what made defect C findable at
all.

## 6. Stale-generation-reference audit

Every generation-bearing identifier in the reviewed installer was audited, not
just the two that had already failed. Findings:

| Reference | Was | Now |
| --- | --- | --- |
| Transaction root | `/root/kyri-gen11-transaction` | `/root/kyri-gen12-transaction` |
| Transaction id prefix | `gen11-` | `gen12-` |
| Fault injection variable | `KYRI_GEN11_FAIL_AT` | `KYRI_GEN12_FAIL_AT` |
| Internal digest variables | `gen10_*` / `gen11_*` | `baseline_*` / `wanted_*` |
| Target classification tokens | `GEN10` / `GEN11` | `BASELINE` / `TARGET` |

The internal naming mattered more than it looks. A Generation-12 installer whose
variables say `gen10` and `gen11` names the wrong generations throughout its own
reasoning, and that is precisely the confusion that produced defect A. The
corrected names are relational — baseline and target — so they stay true in the
next generation without editing.

The predecessor path `/root/kyri-gen11-transaction` still appears in the
installer, in prose only, documenting evidence that is deliberately left alone.
The test asserts it appears on no executable line.

## 7. The exact implementation correction

### 7.1 Namespace (defect A)

Generation 12 owns `/root/kyri-gen12-transaction`, a `gen12-` transaction id and
`KYRI_GEN12_FAIL_AT`. It neither reads, writes, nor removes the predecessor's
journal.

### 7.2 Same-filesystem (defect B)

`require_same_filesystem()` was replaced, not deleted. It now proves the
property that was intended, per row:

- the staging location for a row is the row's *own* target directory, not a
  single package directory;
- that directory must be on the same device as the library root, so publication
  is a rename;
- for a CREATE into a directory this transaction has not made yet, the check
  walks to the nearest existing ancestor and judges that, so a not-yet-created
  directory is still checked rather than skipped.

The weaker reading — deleting the failing check — was rejected. The atomicity
guarantee is the reason the transaction is safe to interrupt.

### 7.3 REPLACE (defect C, surfaced by the fixture)

Driving the full ceremony revealed a third defect that neither operator command
reached, because both halted earlier:

```
STOP: /usr/lib/kyri/python/tools/capability/cli.py is declared REPLACE,
      which this transaction does not implement
```

`prepare()` refused REPLACE outright, under a comment claiming it retained the
predecessor. Generation 11 had nine CREATEs and never needed it. Generation 12
has six REPLACEs and cannot install without it.

REPLACE is now implemented: the target is proved to hold the declared baseline
digest; a pre-existing backup is refused rather than overwritten, because it
means an unfinished transaction; the predecessor is retained beside the target
with `cp -p` at `${target}.kyri-gen12.gen11`; and the retained copy's digest is
verified before anything is staged. `rollback()` restores from it, verifying the
baseline digest first.

### 7.4 The backup deletion (defect D, mine)

The REPLACE implementation was inserted immediately above a pre-existing
`rm -f "${target}${BACKUP_SUFFIX}"` — correct in Generation 11, which never made
a backup, and fatal in Generation 12, which does. It deleted each backup
moments after creating it, leaving rollback of an already-published REPLACE with
nothing to restore from.

The fixture caught it: rollback after an injected mid-commit failure could not
reconstitute a whole generation. The deletion is gone, and the reasoning is
recorded at the site so it is not reintroduced. A stale backup is refused above,
which is the safe direction; it is never silently discarded.

### 7.5 Exclusion gate narrowed

`verify_excluded_absent()` asserted the entire Trust plane absent from the
installed runtime — Generation 11's reasoning, when the runtime consumed
inspection and nothing else. G11-Y made that false: the invocation boundary now
reads the Trust store. The gate now names and refuses every Trust *decision*
surface, and additionally refuses any installed `tools/trust/*.py` this
generation does not declare — which is strictly stronger against drift than the
blanket assertion it replaces.

## 8. Journal and evidence isolation proof

Fixture, part 6 — a Generation-11 host carrying a retained COMMITTED
Generation-11 journal:

- an install proceeds despite that journal (exit 0);
- the predecessor's journal never produces the cross-generation disposition
  halt;
- the predecessor's journal survives byte-identical;
- the Generation-11 baseline evidence at `/root/kyri-gen11-*-digests.txt`
  survives the install, which is what any later rollback is checked against.

**PASS.**

## 9. Same-filesystem atomic-publication proof

The fixture drives the real mixed matrix — six REPLACEs in `tools/capability`,
three CREATEs in `tools/fabric`, ten CREATEs in `tools/trust` — through
`--verify` and `--install`. Every row stages beside its own target and publishes
by rename; no row is skipped, and the CREATE rows into the not-yet-existing
`tools/trust` are judged against their nearest existing ancestor.

**PASS.**

## 10. Fixture reproduction of the real host state

`build_host()` materialises the Generation-11 surface from `GEN11_COMMIT`,
excluding the seven Fabric modules Generation 12 creates, plus
`contract_outcome.py` and `result_content.py` — which exist in that commit but
were never installed. Getting this exactly right took two attempts; the first
built 59 objects rather than 57 by assuming the commit and the installed set
were the same thing. They are not, and a fixture that is not the real host
proves nothing.

`retain_gen11_journal()` writes the COMMITTED predecessor journal, which is what
made defect A reproducible rather than merely argued.

The fixture host is therefore 57 objects, six REPLACE targets at their declared
baseline digests, thirteen CREATE targets absent, no `tools/trust`, and a
retained COMMITTED Generation-11 journal — the real host, as proved in §2.

## 11. Fixture verify / install / verify-installed

| Stage | Result |
| --- | --- |
| `--verify-source` | PASS — 19 objects would change |
| `--verify` | PASS — accepts the intact Generation-11 baseline and the mixed matrix |
| `--install` | PASS — publishes 19 objects, exit 0 |
| `--verify-installed` | PASS — 70 objects, all at Generation-12 digests |

The `--verify` line is objective 4 of the brief, and it is the one the operator
could not get past.

## 12. Interruption and recovery regression

Failure injected at each of four stages — `prepare`, `directory`, `3`,
`precommit` — via `KYRI_GEN12_FAIL_AT`. For every stage:

- the Generation-11 journal is untouched;
- the Generation-11 evidence is in place;
- the host is left a *whole* generation, never a mixture;
- `--recover` settles on a whole generation.

This is the check that caught defect D, and it is the reason the correction is
trustworthy rather than merely passing.

**PASS.**

## 13. Closure and package regression

| Check | Result |
| --- | --- |
| Import closure over the declared roots | 59 modules, external `['yaml']` — unchanged from G11-Z |
| `--verify-source` | PASS, 19 objects would change |
| Generation-12 packaging suite | PASS |
| Generation-11 installer suite | PASS |
| Provisioning suite | PASS |
| G5 preflight | PASS |
| Fabric runtime install closure | PASS |
| G11-X operation authority (isolated) | PASS |
| G11-Y current eligibility (isolated) | PASS |
| Capability runtime / fabric / platform model | PASS |
| ShellCheck at repository-pinned severity (0.9.0, via pre-commit) | PASS |
| `pre-commit run --all-files` | PASS — all five hooks |

The closure count deserves a note. Computed naively over the repository root it
comes out at 55, because the four privileged helpers are only reachable under
their flattened names. Computed the way the installer computes it — over an
exported staging tree with the helpers flattened — it is 59, matching G11-Z
exactly. No runtime Python changed in this checkpoint, so an actual change in
that number would itself have been a defect.

## 14. Validator results

Both modes run from the committed bytes, with a captured PID and the validator's
own exit code — no self-matching process polling.

| Mode | Steps | Failures | Result |
| --- | --- | --- | --- |
| Quick | 78/78 | 0 | `Validation passed (quick mode), started 2026-08-29T06:43:47-05:00, 78/78 steps.` |
| Full | 101/101 | 0 | `Validation passed (full mode), started 2026-08-29T06:50:02-05:00, 101/101 steps.` |

Both totals were re-measured against a real run rather than incremented, as
`tools/dev/run-validation.sh` requires of itself. The new suite is registered in
both `tools/dev/run-validation.sh` and `.github/workflows/ci.yml`, so it is
always-on and raises both totals by one.

## 15. Production no-mutation proof

Re-taken at the end of this checkpoint, after all work:

| Property | Value |
| --- | --- |
| Installed `.py` objects | 57 |
| Content digest | `80f9dee23a3e7934ee779c90284d152c1f13508ed1bcecc100fa7de5b0107f5b` |
| `tools/trust/` | absent |
| Staged or backup residue | none |

Byte-identical to §2. No `--install`, no `--recover`, no journal edit, no manual
runtime replacement, no `/root/kyri-gen12-transaction` created by hand, no
stage, no invoke, no sudoers installation, no Fabric, Trust, artifact-authority
or platform-evidence mutation.

**The production installed runtime is exactly the proven starting generation.**

## 16. Corrected operator installation ceremony

Not authorised in this checkpoint. When it is:

```bash
cd /opt/schott-platform
git pull --ff-only            # requires 013fac1 or later

# 1. package soundness — no privilege, touches no installed path
bash provisioning/execution/install-generation-12.sh --verify-source

# 2. host readiness — needs root, reads /root/kyri-gen11-*-digests.txt
sudo bash provisioning/execution/install-generation-12.sh --verify

# 3. the transaction
sudo bash provisioning/execution/install-generation-12.sh --install

# 4. audit the result
sudo bash provisioning/execution/install-generation-12.sh --verify-installed
```

Step 1 must be run from a clean working tree; the ceremony refuses to run from
unreviewed bytes.

Step 2 is the command that failed before and is the gate on step 3. It must
pass. If it does not, stop and report — do not proceed to `--install`.

Expected after step 3: 70 objects; `tools/trust/` created `0755 root:root`; ten
Trust modules and three Fabric modules at `0444`; six replaced capability
modules; `/root/kyri-gen12-*-digests.txt` written `0400`; and
`/root/kyri-gen11-transaction` and `/root/kyri-gen11-*-digests.txt` unchanged.

If step 3 is interrupted, run
`sudo bash provisioning/execution/install-generation-12.sh --recover` and nothing
else. Do not edit a journal or replace a runtime file by hand.

## 17. Readiness determination

The three reviewed defects and the one introduced during repair are corrected,
each with a test that failed first. The ceremony now completes end to end
against a fixture reproduction of the real host, and every injected interruption
leaves a whole generation.

What has been proved: the installer is correct against a fixture that matches
the production host in object count, digests, matrix disposition and retained
journal state.

What has not: the real host. `/root` is unreadable from the working account, so
`--verify` against production remains an operator step, and it is the gate. The
fixture is a faithful reproduction, not the thing itself.

**INSTALL_READY = YES**, conditional in the ordinary way — step 2 of §16 must
pass on the host before step 3 is run.

Carried forward unchanged:

- `NEXT_ROUTE_WRITE_BLOCKED_PENDING_HEAD_HARDENING=YES`
- `ADMISSION_DEPENDENCY_BOUND_STRUCTURAL_HARDENING_PENDING=YES`
- `ELIG6_ADVERTISEMENT_HEAD_POLICY=UNRESOLVED`

Staging and invocation remain unauthorised.
