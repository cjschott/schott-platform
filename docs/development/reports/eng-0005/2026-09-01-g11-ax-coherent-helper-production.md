# ENG-0005 G11-AX — Coherent privileged helper production ceremony

**Status: STOPPED before any production ceremony, on the stop condition Phase 9
defines.** No production byte was written. The ten-object helper set was
independently reconstructed and confirmed correct; the mandatory
partial-deployment matrix then found that the installed Generation-13
compatibility check accepts **seven** dangerous mixed states, which is the
G11-AI split-generation defect surviving inside the check written to prevent it.

Phase 9 is explicit about what happens next: *"If compatibility accepts a
dangerous mixed state: STOP and fix the compatibility invariant before any
production ceremony."* The invariant is fixed in this checkpoint, with tests
first. It cannot take effect on production inside G11-AX, and §10 explains why
that is a scope question for the operator rather than something to work around.

Branch `arch/eng-0005-execution-transition`, starting HEAD
`6365f125a5f960bdebe3ca2d0a1bcda35c5de0e5`, all six workflows green.
Implementation commit `946be55`.

---

## 1. Predecessor state

Re-derived from production, not carried from the brief.

| | |
| --- | --- |
| runtime objects | 78 |
| runtime aggregate | `bc985098f8774e44dab3d4d5291bca1654a2002a3edf94a794b57987b5c745c2` — **as accepted** |
| coordinator authority | 76 bytes, `3dec888c…2811`, `root:root 0444` — **as accepted** |
| execution authority | 99 bytes, `891beeeb…e373`, `root:root 0444` — **as accepted** |
| Fabric | 21 files, `bcb2559b…ff15e` — unchanged |
| Trust | 26 files, `cffd362c…fbbc39` — unchanged |
| artifact authority | 2 files, `30732e2c…6257f` — unchanged |
| implementation authority | 6 files, `8162164a…3250`; `CIMP-000001` admission `ecb38d80…9991b` — unchanged |
| CINV / CRES | 0 / 0 |
| sudoers non-`README` drop-ins | 0 |
| Root Authority | not mounted |
| helper compatibility | `incompatible` |

`CIMP-000001` was located rather than assumed: it lives at
`/var/lib/kyri/implementation-authority/implementations/CIMP-000001/admission`,
and its digest reproduces the G11-AV value exactly.

## 2. The ten-object matrix, independently reconstructed

Derived by classifying every privileged helper object the deployment carries,
not by trusting the supplied list.

| # | source | target | op | mode | installed | reviewed |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `kyri-exec-transition.py` | `/usr/lib/kyri/python/kyri_exec_transition.py` | REPLACE | 0444 | `6488044bc824` | `de264c6490e0` |
| 2 | `kyri-exec-transition-action.py` | `/usr/lib/kyri/python/kyri_exec_transition_action.py` | REPLACE | 0444 | `bd32af5de4f3` | `7703231318f7` |
| 3 | `kyri-exec-verify.py` | `/usr/lib/kyri/python/kyri_exec_verify.py` | REPLACE | 0444 | `3d70707d19c3` | `f49c29571a4e` |
| 4 | `kyri-exec-reconcile.py` | `/usr/lib/kyri/python/kyri_exec_reconcile.py` | CREATE | 0444 | absent | `29175d5a7175` |
| 5 | `kyri-exec-transition-entrypoint.py` | `/usr/libexec/kyri-exec-transition` | REPLACE | 0555 | `bd31bcbf6342` | `0d9c8d8c9181` |
| 6 | `kyri-exec-verify-entrypoint.py` | `/usr/libexec/kyri-exec-verify` | REPLACE | 0555 | `fad96924adbb` | `1c87788c6559` |
| 7 | `kyri-exec-worker.py` | `/usr/libexec/kyri-exec-worker.py` | REPLACE | 0444 | `64260190330b` | `6d06695f4335` |
| 8 | `kyri-exec-verify-worker.py` | `/usr/libexec/kyri-exec-verify-worker.py` | REPLACE | 0444 | `5a614ff73c0d` | `c747c6d0c306` |
| 9 | `kyri-exec-reconcile-entrypoint.py` | `/usr/libexec/kyri-exec-reconcile` | CREATE | 0555 | absent | `2878fff04bb2` |
| 10 | `kyri-exec-reconcile-worker.py` | `/usr/libexec/kyri-exec-reconcile-worker.py` | CREATE | 0444 | absent | `b0e3c047f689` |

**7 REPLACE, 3 CREATE, 0 already-current.** All sources under
`provisioning/execution/`. All final objects `root:root`.

The derived set **agrees with the brief exactly**, including the operation and
mode of every row.

### The set is complete, and correctly bounded

Every privileged helper object the deployment carries was classified, not just
the ten named. Twelve exist; ten need mutation and two do not:

```
already current   /usr/libexec/kyri-exec-quota
already current   /usr/lib/kyri/python/kyri_exec_quota.py
```

Both are byte-identical to their reviewed sources, so they are correctly outside
the transaction. Phase 2 warned against assuming all ten require mutation; here
all ten do, and the check that establishes it also proves nothing was left out.

## 3. Target authority

Every target byte set is already present at the Generation-13 reviewed authority
`7709cf0443ab11f2b84c94eefbbb60f1eb95c98c`. No post-`7709cf0` helper material is
required, so the question of proving later commits are ancestors does not arise —
but each byte set was still traced to the earliest reviewed commit carrying it:

| commit | subject | ancestor of `6365f12` | ancestor of `7709cf0` |
| --- | --- | --- | --- |
| `44591beee3f5` | add deployment execution identity authority | yes | yes |
| `03a2e90747de` | derive helper identity from deployment authority | yes | yes |
| `a7c5e738794b` | add governed container reconciliation | yes | yes |
| `67f30a98f9ea` | report what a governed execution established | yes | yes |
| `2e3a39d7766c` | add privileged reconciliation entrypoint | yes | yes |

Nothing was accepted because it was newer: each row was pinned to the commit
whose bytes hash to the declared target digest.

## 4. Coherence contract, derived from the sources

The edges are read from each object's own `*_MODULE` constants. Root loads these
**by name, after it has already elevated**, so the name in the source *is* the
dependency.

```
/usr/libexec/kyri-exec-transition        -> kyri_exec_transition
                                            kyri_exec_transition_action
                                            kyri_exec_quota
/usr/libexec/kyri-exec-verify            -> kyri_exec_verify
                                            kyri_exec_transition_action
                                            kyri_exec_quota
/usr/libexec/kyri-exec-reconcile         -> kyri_exec_transition
                                            kyri_exec_transition_action
/usr/libexec/kyri-exec-reconcile-worker.py -> kyri_exec_transition
                                            kyri_exec_transition_action
                                            kyri_exec_reconcile
                                            kyri_exec_podman
/usr/libexec/kyri-exec-worker.py         -> tools.capability.execution.*
                                            kyri_exec_podman
/usr/libexec/kyri-exec-verify-worker.py  -> tools.capability.execution.*
```

Two consequences matter.

**`kyri_exec_transition_action` is loaded by all three entrypoints, including
verify.** That is why the verification pair is inside the deployment set even
though it is outside supervision: replacing the action layer while leaving a
stale verify entrypoint gives that entrypoint a newer action layer than it was
reviewed against. Ten objects move together because of this edge.

**`kyri_exec_podman` is a Generation-13 runtime object**, governed by the
generation ceremony and already installed at its reviewed bytes. It is correctly
outside the helper set, and that is read from the Generation-13 matrix rather
than assumed.

## 5. The defect: the compatibility check under-covers the surface it protects

`tools/capability/execution/helpers.py` exists, by its own docstring, because
*"Generation 13 must not be able to report execution-ready against a stale
helper"*, citing G11-AI — a host that carried half of one commit, *"and the
consequence was live"*.

It declared **four** objects:

```
/usr/libexec/kyri-exec-transition
/usr/libexec/kyri-exec-worker.py
/usr/libexec/kyri-exec-reconcile
/usr/libexec/kyri-exec-reconcile-worker.py
```

Those are the four privileged **executables**. None of the privileged
**modules** they load were declared — and those modules are where the policy
decisions and the credential drop actually live.

### Phase 9, run against the installed Generation-13 logic

Each state built in a disposable fixture; the verdict is the installed
`compatibility()` aimed at that fixture.

| partial state | verdict | |
| --- | --- | --- |
| old entrypoint + new library | `incompatible` | refused |
| **new entrypoint + old library** | `compatible` | **ACCEPTED** |
| **new transition + old action** | `compatible` | **ACCEPTED** |
| **new reconcile entrypoint without reconcile module** | `compatible` | **ACCEPTED** |
| reconcile module without entrypoint | `incompatible` | refused |
| new worker with stale transition | `incompatible` | refused |
| all REPLACE new, CREATE targets absent | `incompatible` | refused |
| **nine of ten (verify entrypoint stale)** | `compatible` | **ACCEPTED** |
| **nine of ten (policy module stale)** | `compatible` | **ACCEPTED** |
| **nine of ten (action module stale)** | `compatible` | **ACCEPTED** |
| **nine of ten (reconcile module absent)** | `compatible` | **ACCEPTED** |
| all ten (the intended target) | `compatible` | correct |

**Seven dangerous mixed states accepted.** Two deserve naming:

- *New entrypoints beside a stale `kyri_exec_transition.py`* is the G11-AI
  split-generation defect exactly, reported as compatible by the check written
  to prevent it.
- *A reconcile entrypoint installed without `kyri_exec_reconcile.py`* is worse
  than a stale mismatch. `kyri-exec-reconcile-worker.py` declares
  `RECONCILE_MODULE = "kyri_exec_reconcile"`; root elevates, drops privilege,
  `execve`s the worker, and only then does the import fail. The runtime would
  have reported that host ready.

This is why Phase 9 makes the matrix mandatory, and it found what it was written
to find.

## 6. The correction

Tests first, as Phase 9 requires.

**The failing test.** A new case in
`tests/test-capability-execution-supervision.sh` states the closure invariant:
*every module a required helper loads is itself a required helper*. It derives
the closure — parsing each helper source's `*_MODULE` constants, and reading the
Generation-13 matrix to exclude modules the generation governs — rather than
comparing against a remembered list. It failed, naming all four uncovered
modules and every helper that loads each.

**The fix.** `REQUIRED_HELPERS` and `HELPER_SOURCES` grow from four objects to
eight:

| added | loaded by | purpose |
| --- | --- | --- |
| `kyri_exec_transition.py` | transition, reconcile, reconcile-worker | the policy module |
| `kyri_exec_transition_action.py` | transition, reconcile, reconcile-worker | the layer performing the credential drop |
| `kyri_exec_reconcile.py` | reconcile-worker | the reconciliation implementation |
| `kyri_exec_quota.py` | transition | the quota module |

The verification surface stays out, and the suite now asserts that it stays out:
`PERMITTED_HELPERS` in `kyri-exec-launcher.py` is exactly
`{kyri-exec-transition, kyri-exec-reconcile}`, so supervision genuinely cannot
reach the verify entrypoint. That was checked, not assumed.

The pre-existing case that hardcoded the four-object set now asserts the two
*shapes* — the executables root runs, and the modules those executables load —
so it proves nothing crept in while the new case proves nothing is missing.

**The matrix, re-run against the corrected declaration:**

| partial state | before | after |
| --- | --- | --- |
| new entrypoint + old library | `compatible` | **refused** |
| new transition + old action | `compatible` | **refused** |
| new reconcile entrypoint without reconcile module | `compatible` | **refused** |
| nine of ten (policy module stale) | `compatible` | **refused** |
| nine of ten (action module stale) | `compatible` | **refused** |
| nine of ten (reconcile module absent) | `compatible` | **refused** |
| nine of ten (reconcile worker absent) | refused | refused |
| all ten (intended target) | `compatible` | `compatible` |

One case remains `compatible` and is **correct**: *nine of ten with the verify
entrypoint stale*. Supervision does not reach that object, so supervision
compatibility is the wrong instrument for it. Its coherence is a **deployment**
property — enforced by the ceremony transaction moving all ten atomically — not
a readiness property. Recorded here rather than forced, because widening
`compatibility()` to cover objects supervision never touches would make the
verdict mean something other than its name.

### The live verdict is unchanged either way

| declaration | verdict | blocking |
| --- | --- | --- |
| installed, 4 objects | `incompatible` | 4 |
| corrected, 8 objects | `incompatible` | 7 |

`HELPER_COMPATIBILITY_BEFORE = incompatible` under both. The correction does not
move the current answer; it removes the states in which the answer would have
been wrong.

## 7. Declaration of the runtime change

`helpers.py` is an installed Generation-13 runtime object, so changing its bytes
requires a `GENERATION_DELTA` declaration in `provisioning/execution/g5-preflight.sh`.
The G5 preflight caught the undeclared change immediately — five failures naming
the object and both digests — which is the mechanism working.

The row moves from `CREATE|ABSENT` to a `REPLACE` off its own installed bytes,
matching the `launch.py` precedent:

```
tools/capability/execution/helpers.py|REPLACE|ABSENT,eff6c4fd…cbb|74b84015…874
```

Declared **pending, NOT INSTALLED**. Generation 13's own installer is unaffected:
it materialises sources from the pinned commit `7709cf0`, where `helpers.py` is
still `eff6c4fd…`, so that declaration remains truthful about what Generation 13
is.

## 8. Privilege boundary

Reviewed against the target sources; nothing in this checkpoint broadens either
boundary, and no privileged helper was invoked.

| requirement | launch | reconcile |
| --- | --- | --- |
| root validates authority before acting | yes | yes |
| target account from deployment authority, not a constant | yes | yes |
| no hardcoded `999:987` fallback | yes — removed in G11-AS | yes |
| close unapproved descriptors | yes | yes |
| permanent `setgroups`/`setgid`/`setuid` drop, then verified | yes | yes |
| `no_new_privs` before execution | yes | yes |
| fixed worker module, no caller-controlled executable | yes | yes |
| no caller-selected uid/gid/`HOME`/`XDG_RUNTIME_DIR` | yes | yes |
| environment derived and closed | yes | yes |
| fails closed on malformed authority | yes | yes |
| FD topology | inherited protocol 0/1 + sealed profile 3, unchanged | narrower `(0,1,2)` contract, unchanged |

## 9. What was not built, and why

Phases 10 to 14 — the transaction design, the crash-recovery rehearsal, the
installer, and the operator `--verify` command — were **not** produced.

Phase 9 gates them: *"STOP and fix the compatibility invariant before any
production ceremony."* Building ceremony tooling against a runtime whose
coherence invariant is known-broken, and whose correction changes what "coherent"
means, would be tooling that needs rewriting before it is ever run. The ten-object
matrix, the coherence graph and the boundary review above are the durable inputs
to that ceremony and carry forward unchanged.

## 10. The scope conflict the operator has to resolve

The correction is committed to the repository. **It does not change production.**

`helpers.py` is one of the twenty-one Generation-13 runtime objects. The live
host still runs `eff6c4fd…`, the four-object check, and will keep accepting the
seven mixed states above until different bytes are installed there. Installing
them is a **runtime generation ceremony**, which G11-AX's out-of-scope list
forbids: *"modify Generation-13 governed runtime objects outside this helper
set."*

So the two requirements cannot both be met inside this checkpoint:

- Phase 9 requires the invariant fixed **before any production ceremony**;
- the scope list forbids the runtime change that would fix it on production.

Two ways forward, and the choice is the operator's:

**(a) A Generation-14 runtime ceremony first, then G11-AX's helper ceremony.**
One object changes (`helpers.py`), by the established generation transaction,
with its own journal and verification. The helper ceremony then runs against a
runtime that can actually refuse a partial deployment. This is the
recommendation: it keeps each ceremony to one authority, and it means the
ten-object transaction is protected by the invariant while it runs rather than
after it.

**(b) Authorise G11-AX to carry `helpers.py` as an eleventh object.** Fewer
ceremonies, but it mixes a runtime object into a helper transaction, changes the
accepted runtime aggregate `bc985098…` inside a checkpoint whose brief says the
runtime must not change, and would need the ten-object matrix re-derived as
eleven.

Either way the helper ceremony itself is unchanged from §2.

## 11. Production state at STOP

**No production byte was written by this checkpoint.**

| | |
| --- | --- |
| runtime aggregate | `bc985098…c745c2` — unchanged |
| identity authorities | both unchanged, `root:root 0444` |
| helper surface | unchanged: 7 stale, 3 absent, 2 current |
| `/usr/libexec` aggregate | `731dde46…d584ac` — unchanged |
| Fabric / Trust / artifacts / implementation authority | all unchanged |
| sudoers | closed |
| CINV / CRES | 0 / 0 |
| Fabric chain | expired |
| production invoke | **not authorised** |

## 12. Validation

| | before | after |
| --- | --- | --- |
| quick | 99/99 | **99/99** |
| full | 124/124 | **124/124** |

No suite was added, so the totals are unchanged. Focused suites re-run:
supervision (with the new invariant case), the G5 preflight (with the new
declaration), and the Generation-13 installer and packaging suites, which are
unaffected because they read the pinned commit.

## 13. Next

The immediate next step is **not** G11-AY. It is whichever of §10's two options
the operator authorises, followed by the ten-object helper ceremony designed
from §2, §4 and §8.

`CADV-000004` and `CINST-000003` remain blocked behind that, and behind sudoers,
which stays closed.
