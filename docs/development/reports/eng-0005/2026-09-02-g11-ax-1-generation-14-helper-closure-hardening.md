# ENG-0005 G11-AX.1 — Generation 14, helper-closure readiness hardening

**Status: prepared, awaiting operator `--verify`.** No production byte was
written. Generation 14 is one runtime object — the readiness rule itself — and
it lands before the privileged deployment that rule judges.

Branch `arch/eng-0005-execution-transition`, starting HEAD
`c928e103cb2d58c10a03457dcb91262ab6872a00`, all six workflows green.
Source authority `946be553ab9f25542590eb908c42ce14a81d6ec3` (landed in G11-AX);
ceremony implementation commit `3ffee7f`.

---

## 1. The ruling, and why the order matters

G11-AX stopped because the installed Generation-13 compatibility check accepted
seven dangerous mixed helper states. The obvious repair — carry the corrected
`helpers.py` along with the ten privileged objects — was refused, and the reason
is the whole shape of this checkpoint.

`helpers.py` **is** the security rule. The ten G11-AX objects are the privileged
deployment that rule evaluates. Changing both in one production transaction
leaves no moment at which either can be checked against a fixed other: a
mid-transaction host would have a new rule judging an old surface, or an old rule
judging a new one, and no verification could say which. So the rule lands alone,
is independently proved to leave production execution-closed, and only then does
the helper ceremony run — against a rule that was already installed and already
verified.

## 2. Source authority, and the minimal delta

`946be553ab9f25542590eb908c42ce14a81d6ec3` changes three files. Classified
against the installed runtime and the Generation-13 matrix rather than by
inspection:

| file | class | installed? |
| --- | --- | --- |
| `tools/capability/execution/helpers.py` | **runtime** | yes |
| `tests/test-capability-execution-supervision.sh` | test | no |
| `provisioning/execution/g5-preflight.sh` | ceremony tooling | no |

**Semantic production runtime delta: exactly one object.** The other two are the
test that states the invariant and the `GENERATION_DELTA` declaration that any
runtime byte change requires; neither is ever installed. The installer re-derives
this at run time (`require_minimal_delta`) and refuses if the reviewed commit
ever grows a second runtime object.

| | |
| --- | --- |
| predecessor (`7709cf0`, installed) | `eff6c4fd6f7420ba86491b7923e14cb2951a9c078decacc09dc20f38cefd5cbb` |
| target (`946be55`) | `74b84015b18a6f38e88633e068cb9c4bdf2753804f3c336ca45aa9a577125874` |

## 3. Coherence: why one object is enough

Replacing `helpers.py` alone can only be safe if nothing else in the runtime
depends on its shape. Checked, not assumed:

- **`cli.py` is the only runtime consumer.** It is the sole module that imports
  `helpers`, and the only attribute it touches is `helpers.compatibility`.
  (`identity.py` contains the word "helpers" once, in prose.)
- **The API is identical.** No public name added, removed or re-signatured; the
  parameter shape and return annotation of `compatibility` are unchanged. The
  only difference is the *default argument*, which **is** the declaration —
  4 objects becoming 8.
- **No new imports.** The closure is `__future__, dataclasses, hashlib, os,
  typing` before and after, so the runtime dependency graph does not move.

`supervision.py`, `recovery.py`, `launch.py` and `coordinator.py` reference
`helpers` not at all. **No second runtime object is required, so the generation
was not broadened.**

## 4. The Generation-14 matrix

| source | target | mode | op | predecessor | target | group |
| --- | --- | --- | --- | --- | --- | --- |
| `tools/capability/execution/helpers.py` | `/usr/lib/kyri/python/tools/capability/execution/helpers.py` | 0444 | REPLACE | `eff6c4fd…cbb` | `74b84015…874` | C |

**REPLACE 1, CREATE 0.** Object count unchanged at **78**. Group C is the same
coherence group Generation 13 placed this object in — identity, recovery and
readiness — so the two ceremonies' reports remain comparable.

Both ends are pinned to reviewed history: the installer checks the predecessor
digest against `7709cf0` and the target against `946be55`, so a REPLACE is
anchored to reviewed bytes at both ends rather than to whatever is on disk.

**No `/usr/libexec` object and no flattened helper module appears in the matrix**
— asserted by the readiness suite, which greps the matrix block for both.

## 5. The defect, preserved as RED/GREEN

`tests/test-capability-generation14-readiness.sh` loads **both** rules from their
own reviewed git objects and drives every state through each. Keeping the RED
half is deliberate: a suite that only asserted the new behaviour would pass just
as well against a rule that had never been broken.

| partial state | Gen 13 | Gen 14 |
| --- | --- | --- |
| old entrypoint + new library | incompatible | incompatible |
| **new entrypoint + old library** | **compatible** | **incompatible** |
| **new transition + old action** | **compatible** | **incompatible** |
| **new reconcile entrypoint without reconcile module** | **compatible** | **incompatible** |
| reconcile module without entrypoint | incompatible | incompatible |
| new worker with stale transition | incompatible | incompatible |
| all REPLACE new, CREATE absent | incompatible | incompatible |
| **nine of ten: policy module stale** | **compatible** | **incompatible** |
| **nine of ten: action module stale** | **compatible** | **incompatible** |
| **nine of ten: reconcile module absent** | **compatible** | **incompatible** |
| nine of ten: reconcile worker absent | incompatible | incompatible |
| nine of ten: verify entrypoint stale | compatible | **compatible** *(intended)* |
| the complete ten-object target | compatible | compatible |

The count of dangerous states Generation 13 accepted is asserted as **6** in the
suite (the seventh in G11-AX's tally is the verify case, now classified
separately and correctly), so the RED half cannot quietly erode.

## 6. The closure, derived rather than listed

`REQUIRED_HELPERS` goes 4 → 8. The four added are not a remembered list: the
suite parses each helper source's own `*_MODULE` constants — root loads these
**by name, after it has already elevated** — and reads the Generation-13 matrix
to exclude modules the runtime generation governs.

| added | loaded by | purpose |
| --- | --- | --- |
| `kyri_exec_transition.py` | transition, reconcile, reconcile-worker | the policy module |
| `kyri_exec_transition_action.py` | transition, reconcile, reconcile-worker | the layer performing the credential drop |
| `kyri_exec_reconcile.py` | reconcile-worker | the reconciliation implementation |
| `kyri_exec_quota.py` | transition | the quota module |

`kyri_exec_podman` is excluded because the Generation-13 matrix governs it —
read from that matrix, not assumed. The same derivation run against Generation 13
is asserted to find **exactly four** uncovered modules, so the test proves the
gap existed as well as that it is closed.

### Runtime readiness closure ≠ helper ceremony coherence

One case stays `compatible` under Generation 14, and that is correct.

`PERMITTED_HELPERS` in `kyri-exec-launcher.py` is exactly
`{kyri-exec-transition, kyri-exec-reconcile}`. Supervised execution **cannot
reach the verification entrypoint**, so supervision compatibility is the wrong
instrument for it. Its coherence is a **G11-AX transaction invariant** — the ten
objects move atomically because `kyri-exec-verify` loads
`kyri_exec_transition_action`, so replacing that module while leaving the verify
entrypoint stale would give it a newer action layer than it was reviewed against.

The suite asserts this in both directions: the rule declares no object containing
`verify`, the launcher names none, and removing an object supervision *does*
reach flips the same fixture to `incompatible`. Broadening readiness to cover
unreachable surfaces would make the verdict mean something other than its name.

## 7. Transaction

`provisioning/execution/install-generation-14.sh`, following the Generation-13
architecture rather than an ad-hoc one-object copy: journal
(`NONE → PREPARING → PREPARED → COMMITTING → COMMITTED`, with `ROLLING_BACK` /
`ROLLED_BACK`), predecessor retention, staged publication by `rename(2)`,
post-publication digest/mode/owner verification, a durable commit point, evidence,
cleanup, and `--recover`.

A one-object generation still gets all of it. `mv -f` is atomic; everything
around it is not — staging can fail, the predecessor can fail to be retained, the
process can die between the journal write and publication, and evidence can fail
after the commit point. Each leaves a different obligation.

### Preconditions `--verify` establishes

Host is exactly the accepted Generation-13 baseline (all 78 objects against the
Generation-13 evidence); predecessor digest exact; target digest exact from
reviewed `946be55` bytes; the reviewed commit's runtime delta is exactly the
declared one object; both identity authorities byte-exact; sudoers closed; no
transaction residue; Root Authority unmounted; source authority an ancestor of
HEAD; the privileged helper surface reported and untouched. Fabric and Trust are
fingerprinted before and after but **freshness is not required** — this is a
runtime hardening ceremony, and the Fabric chain is expired by design.

## 8. Fixture proof

Two suites, **76 assertions**, all passing.

| suite | assertions | where |
| --- | --- | --- |
| `test-capability-generation14-readiness.sh` | 9 | everywhere, including CI |
| `test-capability-execution-generation14-installer.sh` | 67 | host-only |

The security property is in the portable suite by design — it is proved from
reviewed git objects alone, so CI proves the thing that matters most. The
host-only suite proves the transaction, which needs a runtime to install over.

**Phase 6, the installed-import fixture.** The rule that decides must be the
installed one, so the check runs with the repository removed from `sys.path` and
asserts `helpers.__file__` resolves inside the fixture library root:

| surface | verdict | rule |
| --- | --- | --- |
| A — current stale/absent production helpers | `incompatible` | 8 objects |
| B — the complete ten-object AX target | `compatible` | 8 objects |
| C — AX target with the policy module left stale | `incompatible` | 8 objects |
| C, decided by the Generation-13 rule instead | **`compatible`** | 4 objects |

The last row is the generation's whole purpose, measured rather than argued.

**Phase 11, interruption.** Eleven injection points, each asserted to leave the
object at exactly one of its two declared digests and never anything else:

| injection | outcome |
| --- | --- |
| before staging, after staging, before `PREPARED` | Generation 13 |
| after `COMMITTING`, before publication, during verification | Generation 13 |
| at commit position 1, before the commit point | Generation 13 |
| after `COMMITTED`, during evidence, during cleanup | **Generation 14** |

Past the commit point the generation stands: a failure in bookkeeping must not
revert a published generation. An interrupted preparation unwinds and a rerun
installs cleanly; an evidence failure is settled forward by `--recover`, which
writes the evidence and preserves Generation 13's.

## 9. Two defects the suites found in this checkpoint

Recorded because both would have reached production.

**`--verify` wrote into the tree it inspects.** The readiness report imports from
the library root, and CPython wrote `__pycache__` there — as **root**, on
production, into the runtime the ceremony exists to verify. Caught by asserting
`--verify` writes nothing. Fixed with `PYTHONDONTWRITEBYTECODE=1`.

**A missing file exited silently instead of refusing.** `digest_of` piped
`sha256sum | cut`; under `set -o pipefail` an absent file fails the pipeline, and
in a plain assignment that ends the script through `errexit` — before the check
about to refuse could print why. A host with no execution identity authority got
no message at all. Caught by asserting the refusal *names* the missing authority.

## 10. Production state

**Nothing was written.**

| | |
| --- | --- |
| host generation | 13 |
| runtime aggregate | `bc985098…c745c2` — unchanged |
| identity authorities | both unchanged, `root:root 0444` |
| helper surface | unchanged: 7 stale, 3 absent, 2 current |
| Fabric / Trust | `bcb2559b…ff15e` / `cffd362c…fbbc39` — unchanged |
| implementation authority | `CIMP-000001` `ecb38d80…9991b` — unchanged |
| sudoers | closed |
| CINV / CRES | 0 / 0 |
| helper compatibility | `incompatible` |
| production invoke | **not authorised** |

`helpers.py` on the host is still `eff6c4fd…`, the four-object rule.

## 11. Validation

| | before | after |
| --- | --- | --- |
| quick | 99/99 | **101/101** |
| full | 124/124 | **126/126** |

Both suites are always-on, so both totals rose by two; the host-only one runs in
full here and reports `HOST_ONLY_SKIP` on a runner, which is a skip and not a
pass. ShellCheck, Semgrep, both static suites and the G5 preflight are clean.

## 12. Operator command

Verify only. It reads production and mutates nothing:

```bash
sudo bash /opt/schott-platform/provisioning/execution/install-generation-14.sh --verify
```

Expect it to establish the accepted Generation-13 baseline, both identity
authorities, closed gates, no residue, the one-object delta, and to report the
**installed** rule as declaring 4 required objects — the state this generation
changes.

`--install` is deliberately not offered yet. Verify does not authorise install.

## 13. Next

1. Operator returns complete `--verify` output; it is reviewed.
2. If clean, install is separately authorised: `--install`, then
   `--verify-installed`.
3. Production independently confirmed at Generation 14, still execution-closed:
   helper compatibility `incompatible`, sudoers closed, Fabric expired, no
   CINV/CRES.
4. **Then** G11-AX resumes from its Phase 8, with Generation 14 as the runtime
   baseline. Its ten-object matrix, coherence graph and privilege-boundary review
   carry forward unchanged; every compatibility and transaction test is re-run
   against the installed Generation-14 rule.
