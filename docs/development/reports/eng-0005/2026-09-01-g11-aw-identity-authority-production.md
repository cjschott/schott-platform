# ENG-0005 G11-AW — Coordinator and execution identity authority, production ceremony

**Status: prepared, awaiting operator action.** Sections 1–7 and 16 are complete
and independently derived. Sections 8–15 are the post-write verification and are
filled in from operator evidence; they are marked as pending below rather than
predicted. Section numbering follows the checkpoint's report contract.

Branch `arch/eng-0005-execution-transition`. Preparation implementation commits
`e2b9755` (the two ceremonies, the rehearsal suite, and the validation and CI
wiring), `02e90a7` (file-mode precedent) and the split recorded in §7 and §16.

---

## 1. G11-AV closure

The brief supplies the operator evidence that closed G11-AV §8, and it is
carried rather than reopened:

| | |
| --- | --- |
| Generation-13 journal state | `COMMITTED` |
| transaction | `gen13-20260901T163444Z-2483060` |
| commit | `7709cf0443ab11f2b84c94eefbbb60f1eb95c98c` |
| baseline commit | `1313df019472a73e139cfc294ee8e016ad1355c0` |
| progress rows at TARGET | 21 / 21 |
| Generation-12 evidence preserved | YES |
| Generation-13 evidence present | YES |
| `--verify-installed` | PASS |

`GEN13_JOURNAL_STATE = COMMITTED`. `GEN12_EVIDENCE_PRESERVED = YES`.

Nothing found in this checkpoint contradicts it, so it is not reopened. Two
G11-AV values were re-derived here as a side effect of the preconditions and
both reproduced exactly: the installed runtime is **78 objects** aggregating to
`bc985098f8774e44dab3d4d5291bca1654a2002a3edf94a794b57987b5c745c2`, and the
Fabric and Trust stores are **21** and **26** files at `bcb2559b…ff15e` and
`cffd362c…fbbc39`.

One bookkeeping note. The brief names `cb3d958` as the G11-AV report commit. That
commit is an ancestor of the current HEAD; `b978982` is the later commit that
closed §8 with the operator evidence above. Both are ancestors, and the starting
authority is satisfied.

## 2. Live identity derivation

Read from the account database, not copied from the prior report.

| | coordinator | execution |
| --- | --- | --- |
| account | `cschott` | `kyri-capability` |
| uid | **1000** | **999** |
| primary gid | 1000 | **987** |
| group name | — | `kyri-capability` |
| shell | `/bin/bash` | `/usr/sbin/nologin` |

```
cschott:x:1000:1000:Christopher Schott:/home/cschott:/bin/bash
kyri-capability:x:999:987::/data/kyri/capability:/usr/sbin/nologin
kyri-capability:x:987:
```

Phase 3 required the execution facts to match the accepted deployment shape
`999:987`. They do. There is no source fallback to those numbers anywhere in
this ceremony: the account name is the single input and every number is
resolved.

The coordinator's primary gid is read and reported because Phase 2 asks for it
if the schema requires it. **It does not** — `COORDINATOR_AUTHORITY_SCHEMA` is
`(coordinator_account, coordinator_uid, schema_version)` and carries no gid. It
is recorded here as an observation, not as an input.

## 3. Coordinator candidate

```
{"coordinator_account":"cschott","coordinator_uid":1000,"schema_version":1}
```

| | |
| --- | --- |
| destination | `/etc/kyri/coordinator-identity.json` |
| bytes | **76** |
| SHA-256 | `3dec888c9efa4214d9cbc8a943818fbe21cd41fbf81ee252a1e38d5d25fd2811` |
| G11-AV accepted | 76 bytes, `3dec888c…2811` — **reproduced exactly** |

## 4. Execution candidate

```
{"execution_account":"kyri-capability","execution_gid":987,"execution_uid":999,"schema_version":1}
```

| | |
| --- | --- |
| destination | `/etc/kyri/execution-identity.json` |
| bytes | **99** |
| SHA-256 | `891beeeb35bbf0e70dad9351825f34595875e8090f831c5db83ed8f66466e373` |
| G11-AV accepted | 99 bytes, `891beeeb…e373` — **reproduced exactly** |

### How the encoding was recovered

The accepted digests were abbreviated, so the exact bytes had to be re-derived
rather than looked up. The first attempt — compact, sorted keys, UTF-8, no
trailing newline — produced **75** and **98** bytes: one short in both cases,
which is the signature of a trailing newline rather than of a different
document. Adding it reproduced both accepted digests exactly, and the reviewed
source says so independently:
`provisioning/execution/g11-as-execution-identity-candidate.sh` states the
convention as *"sorted keys, no insignificant whitespace, one trailing newline …
the same shape the coordinator authority is provisioned in."*

Worth recording because it is a genuine inconsistency in the deployment, not a
tidy story: `/etc/kyri/backing-store.json` — the one authority already
provisioned in that directory — is 104 bytes of compact sorted JSON with **no**
trailing newline. So `/etc/kyri` will hold two encodings that differ by one
byte of trailing whitespace.

Both are canonical to the repository's own strictest parser
(`tools/capability/execution/canonical_json`), which was checked directly rather
than assumed, and both identity readers accept either. The difference is
therefore cosmetic. The reviewed candidate is installed as accepted: Phase 5
forbids regenerating a different-but-valid authority silently, and a one-byte
cosmetic preference is not grounds to invalidate a digest two checkpoints have
carried.

## 5. Parser and security proof

No parser was written for this ceremony. Both candidates are driven through the
released readers.

**Coordinator** — `kyri_exec_transition.load_coordinator_authority`, the
privileged helper's policy layer. There is no runtime-side coordinator reader:
`tools/capability/cli.py` only tests the pathname's existence, by design.

**Execution** — two readers, because the privileged helpers cannot import the
runtime package and so the grammar exists twice:
`kyri_exec_transition.load_execution_identity` and
`tools.capability.execution.identity.load_execution_identity`. Both are driven
over the same bytes and required to derive the same identity. An authority the
helper would take and the runtime would refuse is not an authority.

| rule | coordinator | execution |
| --- | --- | --- |
| closed schema, no unknown field, none missing | yes | yes |
| duplicate keys refused rather than collapsed | yes | yes |
| bounded before parsing (4096 bytes) | yes | yes |
| exactly one JSON object | yes | yes |
| `schema_version` must be `1`, `bool` refused | yes | yes |
| identity numbers: `int`, not `bool`, `0 < n < 2³¹` | yes | yes |
| account name: non-empty, ≤32 chars, closed alphabet | yes | yes |
| owner must be `root`, group `root` | yes | yes |
| refuses group- or world-writable | yes | yes |
| must be a regular file | yes | yes |
| account ↔ uid binding through the account database | — | yes |
| account ↔ primary gid binding | — | yes |

The asymmetry in the last two rows is deliberate and is written out in the
source. The coordinator record names a publisher to **recognise**: the helper
checks `st_uid` on descriptors it already holds, which is a kernel fact needing
no lookup, so the uid is the authority and the name is documentation carried
because the sudoers grant is written in names. The execution record names an
identity to **become**, and the failure it must survive is a stale authority
naming an account whose uid was later reassigned — which a number alone cannot
detect and a name alone would put NSS in charge of. So it carries both and
requires them to still agree.

**One asymmetry found and left as it is.** The policy layer's
`CoordinatorAuthority` and `ExecutionIdentity` are token-guarded: they cannot be
constructed at all, only produced by their loader, so *"was this read from
root-owned authority?"* is answerable from the type. The runtime's
`ExecutionIdentity` is a frozen dataclass — immutable, but constructible. That
was found by asserting the stronger property and being wrong, and it is left
alone because the two values are not the same kind of thing: the policy value
authorises a privileged credential drop, and the runtime one is a read-only
record on the unprivileged observation surface. Both suites now assert what is
actually true of each, so the difference stays visible rather than being
rediscovered later.

**Why root ownership is the whole protection.** Each authority names the
principal it protects against. A coordinator-writable coordinator authority
names whoever the coordinator likes; an execution-writable execution authority
would let one compromised worker choose what the next transition becomes. That
is why both are `root:root` and why the write bits, not the read bits, are what
the readers constrain — `0400` and `0444` are both root's decision and neither
weakens anything.

## 6. Fixture rehearsal

Two committed programs, and two suites — **46 assertions**, all passing. Every
install lands in a disposable root; neither suite reads anything under `/etc`,
uses sudo, or installs a pathname a production host has.

| suite | assertions | where it runs |
| --- | --- | --- |
| `test-capability-identity-authority-schema.sh` | 21 | everywhere, including CI |
| `test-capability-identity-authority-ceremony.sh` | 25 | host-only |

### Why that split exists, and what it cost to find

The first version was one suite that called `pwd.getpwnam('cschott')`. It passed
here and **failed CI**, because a GitHub runner has never heard of that account.

The failure was the correct outcome and the defect was mine, but it is worth
recording precisely, because it is the same defect these two authorities exist
to close, one directory further out. `COORDINATOR_UID = 1000` and
`WORKER_UID = 999` were true of `schai` because that is how the accounts
happened to be created, and three suites passed on that coincidence. A suite
that resolves the host's own account database is testing the host — and would
pass just as happily against a compiled-in constant.

So the assertions are split by what they actually depend on:

- **The grammar and the boundary between the two roles are deployment-neutral**,
  and are proven with injected resolvers and two unrelated fixture deployments
  (`4100`/`4101:4102` and `7700`/`7701:7702`) that share no number with each
  other or with `schai`. This runs in CI, which is where it needs to run.
- **The reviewed digests are facts about this deployment.** Only the ceremony
  rehearsal depends on them, so only it is host-only, declaring
  `host_only_requires_account cschott kyri-capability` and reporting
  `HOST_ONLY_SKIP` elsewhere. The skip path was exercised directly rather than
  assumed.

`host_only_requires_account` was added to `tests/lib/host-only.sh` for this;
`tests/host-only.manifest` records the suite and its reason, and
`test-static.sh` enforces that pairing in both directions.

`provisioning/execution/g11-aw-freeze-coordinator-identity.sh` and
`provisioning/execution/g11-aw-freeze-execution-identity.sh` are deliberately
two separate programs rather than one with a role argument. They install
root-owned authority that decides who a privileged boundary trusts, and the
reviewer's question — *what exactly will land at this pathname* — has to be
answerable by reading one file top to bottom. Two programs also make a partial
ceremony a state the operator can see and name.

Neither carries a typed identity number. Each resolves the account, renders the
canonical document, and compares the **full** SHA-256 against the reviewed
digest before installing anything. If this deployment no longer renders the
reviewed bytes, the ceremony refuses.

What the rehearsal proves, per candidate and then jointly:

| | |
| --- | --- |
| installs the reviewed bytes into a disposable root | both |
| installed mode `0444` | both |
| creates **exactly one** file | both |
| does not install the other role's record | both |
| refuses a destination that already exists | both |
| a refused ceremony leaves the existing authority byte-identical | both |
| refuses an account the database does not know, installing nothing | proven |
| refuses bytes that are not the reviewed candidate, installing nothing | proven |

And, deployment-neutrally, across both fixture deployments:

| | |
| --- | --- |
| malformed bodies refused (empty, truncated, non-object, duplicate key, trailing document) | both |
| unknown field refused | both |
| unsupported `schema_version` refused, including `True` and `"1"` | both |
| identity numbers refused unless usable and non-root (`0`, `-1`, `True`, `"999"`, `2³¹`) | both |
| numbers disagreeing with the account database refused, uid and gid | execution |
| not root-owned / not root-group / group- or world-writable / not a regular file | both |
| `0400` accepted — the read bits are root's decision | both |
| oversized authority refused before parsing | execution |
| the privileged identities cannot be constructed without their loader token | both |
| the rootless environment is derived from the uid and carries nothing else | execution |

The ownership rule is exercised in **both** directions rather than branched
around: a fixture cannot be root-owned without privilege, so each ceremony
requires its reader to *refuse* the file as installed and then accepts the same
bytes under a root-owned status.

### Combined fixture and cross-role refusal

With both files present in one authority root:

| | |
| --- | --- |
| coordinator reader yields the coordinator identity only | PASS |
| execution reader yields the execution identity only | PASS |
| the two identities are not the same identity | PASS |
| coordinator record refused as an execution authority | PASS (both readers) |
| execution record refused as a coordinator authority | PASS |
| the two files swapped — refused in both directions | PASS |
| the schemas share no field but `schema_version` | PASS |

The last row is why the others hold. Cross-role refusal works because the
schemas are closed **and** disjoint; if they ever came to share a field, a
record could satisfy both readers and the refusals above would start passing for
the wrong reason. Asserting the disjointness makes that a protected property
instead of a coincidence.

### Identity installation alone cannot open execution

Proven structurally so it holds in CI as well as on the host:

- `tools/capability/execution/helpers.py` contains neither authority pathname in
  any string literal, and every required helper is a `/usr/...` object. The
  compatibility verdict cannot move when these two files appear.
- `_supervision_outlook`'s `supervision_ready` is a boolean **and** whose
  conjuncts include helper compatibility alongside the two authorities. Two
  installed authorities cannot, on their own, make it true.

## 7. Exact operator commands

Two blocks, run consecutively only after both candidates above have been
independently reviewed. Each is a subshell, so a refusal ends the block rather
than the operator's session, and each captures its own privileged `/etc/kyri`
manifest before and after — so a delta is attributable to one block rather than
to the pair.

Neither block writes to `/etc/sudoers.d`, installs a helper, renews Fabric,
creates a record, or invokes anything. The only write either performs is the one
`install` naming its own destination.

**BLOCK A — coordinator authority**

```bash
bash <<'BLOCK_A'
set -Eeuo pipefail
cd /opt/schott-platform
printf '\n########## /etc/kyri BEFORE block A ##########\n'
sudo find /etc/kyri -mindepth 1 -printf '%p  %u:%g  %m  %s\n' | sort
bash provisioning/execution/g11-aw-freeze-coordinator-identity.sh
printf '\n########## /etc/kyri AFTER block A ##########\n'
sudo find /etc/kyri -mindepth 1 -printf '%p  %u:%g  %m  %s\n' | sort
BLOCK_A
```

**BLOCK B — execution authority**

```bash
bash <<'BLOCK_B'
set -Eeuo pipefail
cd /opt/schott-platform
printf '\n########## /etc/kyri BEFORE block B ##########\n'
sudo find /etc/kyri -mindepth 1 -printf '%p  %u:%g  %m  %s\n' | sort
bash provisioning/execution/g11-aw-freeze-execution-identity.sh
printf '\n########## /etc/kyri AFTER block B ##########\n'
sudo find /etc/kyri -mindepth 1 -printf '%p  %u:%g  %m  %s\n' | sort
BLOCK_B
```

Each ceremony performs, in order and refusing at the first failure:

1. `set -Eeuo pipefail`, and a destination-exists check **before** anything is
   rendered — so a refusal leaves an existing authority untouched;
2. resolves the account and renders the canonical document into `mktemp`;
3. computes SHA-256 and byte count, and compares the **full** digest against the
   reviewed value — not a prefix;
4. `sudo install -o root -g root -m 0444` to the destination;
5. removes the temporary file;
6. `sudo sha256sum` and `sudo stat` on what actually landed;
7. re-reads the installed bytes through the accepted reader — both readers for
   the execution authority — and re-checks the account binding against the
   account database.

The two blocks are separate programs on purpose: the operator can see exactly
which authority succeeded, and a partial ceremony is a state that can be named
and stopped in.

## 8. Operator evidence

*Pending — filled in from the operator's output of the two blocks in §7a.*

## 9. Byte identity

*Pending.*

## 10. Ownership and mode

Precedent re-derived from the live host, not taken from the brief:

```
/etc/kyri                      root:root  711
/etc/kyri/backing-store.json   root:root  444  104 bytes
```

`root:root 0444` for both new files, matching the one authority already
provisioned in that directory. The directory stays `0711`: the coordinator can
traverse to a named file it is allowed to read and cannot enumerate the
directory, which is why this report states the two destinations by name and
defers a full `/etc/kyri` listing to the operator.

*As-installed reading pending operator evidence.*

## 11. Two-path mutation accounting

Expected, and nothing else:

```
CREATE  /etc/kyri/coordinator-identity.json
CREATE  /etc/kyri/execution-identity.json
```

Two additions, zero replacements, zero removals, zero unrelated modifications.
Each block captures a privileged `/etc/kyri` manifest before and after its own
install, so the delta is attributable to one block rather than to the pair.

Pre-ceremony state, as far as an unprivileged coordinator can observe it:

```
/etc/kyri                             root:root  711
/etc/kyri/backing-store.json          root:root  444  104
/etc/kyri/coordinator-identity.json   ABSENT
/etc/kyri/execution-identity.json     ABSENT
```

The directory is `0711`, so this is a read of named paths and not an
enumeration. The operator's BEFORE manifest closes that gap.

*Post-write accounting pending.*

## 12. Runtime unchanged

Baseline captured before the ceremony:

| | |
| --- | --- |
| installed runtime objects | 78 |
| runtime aggregate | `bc985098f8774e44dab3d4d5291bca1654a2002a3edf94a794b57987b5c745c2` |
| `/usr/libexec` aggregate | `731dde469eaa6ad6b163fe8c285e43033e7f87f7833d95690300d11d1ad584ac` |

*Post-write comparison pending.*

## 13. Helper compatibility remains closed

Baseline, read from the **installed** runtime:

```
helper_compatibility        incompatible
supervision_ready           false
coordinator_identity_authority   false
execution_identity_authority     false
launch_grant                unobservable
reconcile_grant             unobservable
```

Blocking:

| helper | state |
| --- | --- |
| `/usr/libexec/kyri-exec-transition` | stale |
| `/usr/libexec/kyri-exec-worker.py` | stale |
| `/usr/libexec/kyri-exec-reconcile` | absent |
| `/usr/libexec/kyri-exec-reconcile-worker.py` | absent |

The sharpest evidence for behavioural inertness is not a verdict string. The
installed helper policy module `/usr/lib/kyri/python/kyri_exec_transition.py`
(`6488044b…`, against `de264c64…` in the reviewed source) contains **zero**
references to either authority pathname and still carries the compiled-in
constants the reviewed source deleted:

```
61:WORKER_USER = "kyri-capability"
62:WORKER_UID = 999
63:WORKER_GID = 987
```

The installed privileged surface cannot read either file. It will keep using its
constants until the G11-AX helper ceremony replaces it. Installing these two
authorities therefore changes nothing on the privileged path — it is not that
the files are ignored by policy, it is that the code that would read them is not
installed.

The one field that will move is `execution_identity_authority`, because
`tools/capability/execution/identity.py` **is** installed and current
(`f7a01f2f…`, byte-identical to the reviewed source). That is the coordinator's
read-only observation surface, not an execution path.

*Post-write confirmation pending.*

## 14. Sudoers

`/etc/sudoers.d` holds zero non-`README` drop-ins before the ceremony. Neither
block writes to `/etc/sudoers.d`, and neither invokes a helper.

*Post-write confirmation pending.*

## 15. Fabric unchanged and expired

| store | files | aggregate | recorded baseline |
| --- | --- | --- | --- |
| Fabric `/var/lib/kyri/fabric` | 21 | `bcb2559bdbc13ad760b5cb19e40d9327fc3c5e94b1988ae1e690159dcdcff15e` | **identical** |
| Trust `/var/lib/kyri/trust` | 26 | `cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39` | **identical** |

Production CINV: **0**. Production CRES: **0**. The Fabric chain remains
expired; no CADV, CINST, CROUTE or CSEL is created by this checkpoint.

*Post-write confirmation pending.*

## 16. Validation

Re-measured, not incremented.

| | before | after |
| --- | --- | --- |
| quick | 97/97 | **99/99** |
| full | 122/122 | **124/124** |

Both new suites are always-on, so both totals rose by two. Both are wired into
`tools/dev/run-validation.sh` and `.github/workflows/ci.yml`; the
developer-experience backstop that fails on a suite local validation never runs
is satisfied. The host-only suite runs in full here and reports
`HOST_ONLY_SKIP` on a runner, which is a skip and not a pass — `test-static.sh`
holds it to its manifest entry in both directions.

Focused authority suites, all passing:

| suite | |
| --- | --- |
| `test-capability-execution-coordinator-authority.sh` | coordinator grammar |
| `test-capability-execution-identity-authority.sh` | execution grammar, account/uid/gid binding |
| `test-capability-identity-authority-schema.sh` | cross-role refusal, closed helper compatibility, not-ready preflight |
| `test-capability-identity-authority-ceremony.sh` | the ceremony against this deployment |

All 28 generated case scripts across the two suites were mechanically extracted
as bash passes them and compiled, then checked for the shared prelude and the
terminating `print('OK')`. This guards the failure mode that produced a silently
truncated, silently passing case earlier in this programme: a stray quote ending
a double-quoted string early, leaving a fragment that runs and reports PASS.

### CI on the preparation commits

The first push (`f7e9940`) went green on Gitleaks, Trivy, CodeQL, ShellCheck and
Semgrep, and **failed CI** on the host-dependency defect described in §7. It is
recorded here rather than amended away: the suite was wrong, CI was right, and
the fix was to split the assertions by what they depend on rather than to make
CI tolerate the suite.

## 17. Handoff

*Pending operator evidence; the G11-AX handoff is stated once the write is
verified.*

Next checkpoint is **G11-AX — the coherent helper ceremony**, which must move
the full accepted helper set together and flip helper compatibility from
`incompatible` to `compatible`. No helper object is installed by G11-AW.
