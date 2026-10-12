# ENG-0005 G11-AX.2 — Coherent ten-object helper ceremony, resumed on Generation 14

**Status: prepared, awaiting operator `--verify`.** No production byte was
written. The ten-object privileged helper transaction is built and proved in
fixture against the **installed** Generation-14 readiness rule.

Chronology, preserved rather than rewritten:

| | |
| --- | --- |
| **G11-AX** | STOPPED — the Generation-13 readiness rule accepted dangerous mixed states (`c928e10`) |
| **G11-AX.1** | Generation 14 — the rule hardened and installed on its own (`b708d70`, `3ffee7f`) |
| **G11-AX.2** | this report — the helper transaction, judged by that installed rule |

Branch `arch/eng-0005-execution-transition`, starting HEAD
`b708d70067891ff09f63ae7128c339272f3ec8d0`, all six workflows green.
Helper authority `7709cf0443ab11f2b84c94eefbbb60f1eb95c98c`; ceremony
implementation commit `3c67986`.

---

## 1. Live baseline, re-derived

Generation 14 is confirmed installed from bytes, not from the operator summary:

| | |
| --- | --- |
| installed readiness rule | `74b84015…125874` — the Generation-14 bytes, `root:root 0444` |
| runtime objects | 78 |
| runtime aggregate | `b9b0a119aa98029daa82c65afaec2445e3335e953cd600e1083aac73080583dd` |
| coordinator / execution identity | `3dec888c…2811` / `891beeeb…e373` — as accepted |
| Fabric / Trust | `bcb2559b…ff15e` / `cffd362c…fbbc39` — unchanged |
| implementation authority | `8162164a…3250` — unchanged |
| sudoers non-`README` | 0 |
| CINV / CRES | 0 / 0 |
| Root Authority | unmounted |
| helper transaction residue | none |

**Exactly one object separates Generation 14 from Generation 13.** Proven by
substituting the declared predecessor back into the aggregate: reverting
`helpers.py` to its `7709cf0` bytes reproduces `bc985098…c745c2` exactly. The
other 77 objects are untouched.

## 2. The ten targets, reconstructed

Derived by classifying the live surface against the reviewed authority, then
compared with the brief:

| # | target | op | mode | predecessor | target |
| --- | --- | --- | --- | --- | --- |
| 1 | `/usr/lib/kyri/python/kyri_exec_verify.py` | REPLACE | 0444 | `3d70707d19c3` | `f49c29571a4e` |
| 2 | `/usr/libexec/kyri-exec-verify` | REPLACE | 0555 | `fad96924adbb` | `1c87788c6559` |
| 3 | `/usr/libexec/kyri-exec-verify-worker.py` | REPLACE | 0444 | `5a614ff73c0d` | `c747c6d0c306` |
| 4 | `/usr/lib/kyri/python/kyri_exec_transition.py` | REPLACE | 0444 | `6488044bc824` | `de264c6490e0` |
| 5 | `/usr/lib/kyri/python/kyri_exec_transition_action.py` | REPLACE | 0444 | `bd32af5de4f3` | `7703231318f7` |
| 6 | `/usr/lib/kyri/python/kyri_exec_reconcile.py` | CREATE | 0444 | absent | `29175d5a7175` |
| 7 | `/usr/libexec/kyri-exec-transition` | REPLACE | 0555 | `bd31bcbf6342` | `0d9c8d8c9181` |
| 8 | `/usr/libexec/kyri-exec-worker.py` | REPLACE | 0444 | `64260190330b` | `6d06695f4335` |
| 9 | `/usr/libexec/kyri-exec-reconcile` | CREATE | 0555 | absent | `2878fff04bb2` |
| 10 | `/usr/libexec/kyri-exec-reconcile-worker.py` | CREATE | 0444 | absent | `b0e3c047f689` |

**7 REPLACE, 3 CREATE.** All `root:root`. All ten target byte sets are at the
reviewed authority `7709cf0443ab11f2b84c94eefbbb60f1eb95c98c`, which is an
ancestor of the Generation-14 authority that judges them — checked, not assumed.

The order above is the **publication order**, and it is not cosmetic. See §4.

## 3. Two closures, and why the ceremony moves ten

| | objects | what it means |
| --- | --- | --- |
| **runtime readiness closure** | 8 | what `helpers.compatibility()` judges — what a supervised execution reaches |
| **helper ceremony coherence closure** | 10 | what must move together for the privileged surface to be internally consistent |

Seven of the ten are inside the readiness closure. Three are not:
`kyri_exec_verify.py`, `kyri-exec-verify`, `kyri-exec-verify-worker.py`.
`PERMITTED_HELPERS` in the launcher is exactly the transition and reconcile
entrypoints, so supervision provably cannot reach the verification surface.

They are still in the ceremony, because `kyri-exec-verify` loads
`kyri_exec_transition_action`. Replacing that module while leaving the verify
entrypoint stale hands it a newer action layer than it was reviewed against —
a deployment split, even though it is not a readiness one.

One object is inside the readiness closure but outside the ten:
`kyri_exec_quota.py`, already at its reviewed bytes and therefore not this
ceremony's to move.

## 4. Publication order is a safety property

Compatibility depends only on the seven objects inside the readiness closure. So
the three outside it publish **first**, and the verdict can only become
`compatible` as the **tenth** object lands.

That makes Phase 15 hold by construction rather than by relying on sudoers being
closed. The suite proves it empirically: it publishes position by position and
asks the installed rule after each one, asserting the first `compatible` appears
at **position 10**.

Rollback runs in reverse order, tearing the readiness closure down before the
objects outside it — the mirror of why it was built up last.

## 5. Live Generation-14 security property

Driven through the **installed** bytes, with the repository off `sys.path` and
`helpers.__file__` asserted to resolve inside the installed tree.

Current production: **`incompatible`**, 7 blocking —
`kyri-exec-transition` (stale), `kyri-exec-worker.py` (stale),
`kyri-exec-reconcile` (absent), `kyri-exec-reconcile-worker.py` (absent),
`kyri_exec_transition.py` (stale), `kyri_exec_transition_action.py` (stale),
`kyri_exec_reconcile.py` (absent).

The partial-deployment matrix, re-run against the live rule:

| partial state | verdict |
| --- | --- |
| new transition entrypoint / stale transition module | **refused** |
| stale entrypoint / new module | **refused** |
| transition/action split | **refused** |
| new reconcile entrypoint / absent reconcile module | **refused** |
| reconcile module / absent entrypoint | **refused** |
| new worker / stale dependencies | **refused** |
| all seven REPLACE complete / CREATEs absent | **refused** |
| nine of ten: policy module stale | **refused** |
| nine of ten: action module stale | **refused** |
| nine of ten: reconcile module absent | **refused** |
| nine of ten: reconcile worker absent | **refused** |
| **the complete ten** | `compatible` |
| stale verify-only | `compatible` — *and correct* |

**11/11 execution-dangerous states refused.** The stale verify-only case is
runtime-ready and **ceremony-incoherent**, which is the distinction §3 exists to
make: the suite asserts its surface state is `MIXED` in the same case that
asserts its verdict is `compatible`.

## 6. The transaction

`provisioning/execution/install-g11-ax-helpers.sh` —
`--verify-source`, `--verify`, `--install`, `--verify-installed`, `--recover`.

Its own namespace, asserted rather than assumed: transaction root
`/root/kyri-g11-ax-helper-transaction`, suffixes `.kyri-axhelper.new` and
`.kyri-axhelper.pre`. `require_namespace_isolation` refuses if it ever collides
with a `gen12`, `gen13` or `gen14` root, and the suite checks no runtime
generation's journal or suffix appears anywhere in the ceremony.

**The behavioural gate is inside COMMIT.** Ten objects at their target digests is
not the same claim as *the installed runtime will now supervise through them*,
and only the second one matters. After all ten publish and before the commit
point, the ceremony asks the installed Generation-14 rule; anything other than
`compatible` rolls back.

## 7. What the fixture proves

`tests/test-capability-execution-helper-ceremony.sh` — **102 assertions**, all
passing, host-only. Every case builds a throwaway host and drives the ceremony
with `--fixture`; nothing writes to `/usr`, `/etc`, `/root` or `/var`, no sudo,
no helper invoked, no container started.

The suite reads the ceremony's matrix **as data**. It carries no copy of the ten
objects — a suite with its own list would agree with itself rather than with the
ceremony.

**`--verify` is read-only**: byte-identical fixture before and after, and zero
`__pycache__` — the Generation-14 lesson, carried forward and asserted.

**Unknown bytes refuse, never repair.** Unknown bytes at a REPLACE target and an
unexpected object at a CREATE target are both refused by `--verify` and
`--install`, and both are left *exactly as found* — asserted by content, not just
by exit status.

**The ceremony refuses hosts it must not run on**: a host still on the
Generation-13 rule, a host missing an identity authority, a host with a sudoers
grant already installed.

**Interruption — fourteen injection points:**

| injection | outcome |
| --- | --- |
| before staging, during staging, after all staging | pre-ceremony surface |
| after `COMMITTING`, before publication | pre-ceremony surface |
| after the first OUTSIDE publication (2), during the REPLACE set (5) | pre-ceremony surface |
| before the first CREATE (6), after nine publications (10) | pre-ceremony surface |
| after ten publications before the behavioural check | pre-ceremony surface |
| after the behavioural check before `COMMITTED` | pre-ceremony surface |
| after `COMMITTED`, during evidence, during cleanup | **complete set** |

Every crash case asserts **two** things: the surface is whole, and the installed
rule's verdict is *consistent with* that surface — `compatible` only when
complete. An interrupted preparation unwinds and a rerun installs cleanly; an
evidence failure settles forward under `--recover`.

## 8. Carried forward from G11-AX unchanged

The privilege boundary review, identity architecture, launch/reconcile
separation, descriptor policies, no-root-Podman rule, permanent privilege drop
and helper source lineage were accepted in G11-AX and the sources have not
changed. They are not re-derived here. What **was** re-run is everything that
depends on the installed compatibility checker, because production now runs
Generation 14.

## 9. One consequence worth stating plainly

**The library root gains a file.** `/usr/lib/kyri/python` holds the 78
Generation-14 runtime objects *and*, beside them, the flattened privileged helper
modules. One of the ten is a CREATE into that directory
(`kyri_exec_reconcile.py`), so the file count there goes **78 → 79** while every
runtime object stays byte-identical.

This ceremony states its expectation that way rather than as a flat count, and
its before/after fingerprint excludes its own targets so that *"a runtime object
changed"* means what it says. Both were found by the fixture failing: the naive
count and the naive fingerprint were each wrong in a way that would have blocked
a correct ceremony.

**A follow-up this creates.** `install-generation-13.sh --verify-installed` and
`install-generation-14.sh --verify-installed` both count `*.py` under the library
root and expect 78. After this ceremony they will see 79 and report a failure
that is not a failure. Neither is needed to install anything now, and changing a
ceremony that has already performed a production install is not this checkpoint's
to do — but it should be corrected before either is next relied on, and it is
recorded here so it is not discovered as a surprise.

## 10. A live-state failure this checkpoint surfaced

Full validation failed at step 75 — **not** on new code. The Generation-13
packaging suite pins the live host to *Gen12 or Gen13*, and the operator's
Generation-14 install moved `helpers.py` to a third state the suite read as
drift.

It could only appear after the install: full validation passed 126/126 during
G11-AX.1, when the host was still Generation 13. The fix is the one the
Generation-12 packaging suite already learned — read the successor's matrix and
treat a superseded row as superseded rather than as drift — and it is derived
from that matrix rather than naming `helpers.py`.

Three of my own bugs surfaced while making that fix, all in the same quoting
hazard family this programme has hit before: a `'"'` literal that terminated the
bash string, a `${LIBRARY_ROOT}` that bash expanded before Python saw it, and a
mis-indented comment. Each was caught by the suite failing, not by review.

## 11. Production state

**Nothing was written.**

| | |
| --- | --- |
| host generation | 14 |
| runtime aggregate | `b9b0a119…0583dd` — unchanged |
| helper surface | unchanged: 7 stale, 3 absent |
| identity authorities | both unchanged |
| Fabric / Trust / implementation authority | all unchanged |
| sudoers | closed |
| CINV / CRES | 0 / 0 |
| helper compatibility | `incompatible` (7 blocking) |
| production invoke | **not authorised** |

## 12. Validation

| | before | after |
| --- | --- | --- |
| quick | 101/101 | **102/102** |
| full | 126/126 | **127/127** |

One always-on suite added. ShellCheck, Semgrep, both static suites and the G5
preflight are clean.

## 13. Operator command

Verify only. It reads production and mutates nothing:

```bash
sudo bash /opt/schott-platform/provisioning/execution/install-g11-ax-helpers.sh --verify
```

Expect it to establish Generation 14, both identity authorities, closed gates, no
CINV/CRES, all ten targets in a declared predecessor state, no residue, and to
report current readiness `incompatible` alongside a target-fixture readiness of
`compatible`.

`--install` is deliberately not offered. Verify does not authorise install.

## 14. Next

1. Operator returns complete `--verify` output; it is reviewed.
2. If clean, install is separately authorised: `--install`, then
   `--verify-installed`.
3. Production independently confirmed: ten targets exact, transaction
   `COMMITTED`, ceremony coherence PASS, live readiness **`compatible`** — while
   sudoers stays closed and Fabric stays expired, so supervision is still not
   execution-ready.
4. Then **G11-AY**: fresh `CADV-000004` and `CINST-000003`. Sudoers is not
   installed before the Fabric chain is renewed.
