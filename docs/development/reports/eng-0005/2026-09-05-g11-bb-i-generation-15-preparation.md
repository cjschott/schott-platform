# ENG-0005 G11-BB-I — Generation 15, derivation and STOP

**Status: STOPPED at step 1, as the ruling requires.** The mechanically derived
Generation-15 object set **differs** from the carried-forward expectation, and
the difference collides with a standing ruling. No installer was built.
Production untouched. `CINV-000001` byte-identical, `CINV-000002` unspent.

Branch `arch/eng-0005-execution-transition`, HEAD `8d9160b`.

---

## 1. What the ruling asked, and what happened

> *"Do not carry forward the BB-G four-object list without proof… If the
> mechanically derived set differs: STOP and explain why before building the
> installer."*

It differs. BB-G said four REPLACE, zero CREATE. **The derived set is five
REPLACE**, and the fifth is an object the reviewer has separately ruled must not
be touched in this line of work.

## 2. The accounting, done the way the ruling requires

```
installed .py under /usr/lib/kyri/python      79
minus the helper-ceremony-published module     1   kyri_exec_reconcile.py
                                              ──
governed Generation-14 runtime objects         78
```

The helper-published module is identified mechanically, not assumed: it is the
only `CREATE` into `${LIBRARY_ROOT}` in `install-g11-ax-helpers.sh`'s matrix,
which is exactly how `install-generation-14.sh` itself computes
`helper_ceremony_library_creates`. **Flat directory count is not generation
count**, and the difference is that one module.

## 3. The derived delta

Every governed Generation-14 object whose bytes differ from reviewed source at
`8d9160b`:

| # | path | Gen-14 accepted | Gen-15 reviewed | op | source commit | group |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `tools/capability/cli.py` | `752951f7…3e3d295` | `7b4fac3e…54c6b1` | REPLACE | `d11e141` | recovery |
| 2 | `tools/capability/execution/recovery.py` | `a93819d1…0e59ab8f` | `f44ada7f…c0222a03` | REPLACE | `d11e141` | recovery |
| 3 | `tools/capability/execution/helpers.py` | `74b84015…125874` | `6dd93606…930b8b07` | REPLACE | `b74f2fb` | helper-declaration |
| 4 | `kyri_exec_launcher.py` | `269258f3…` | `78c6de90…` | REPLACE | `b74f2fb` | reconcile-diagnostic |
| **5** | **`tools/capability/execution/verification.py`** | **`ed5b49ed…88bd2e73`** | **`7a792aaf…9e1efa952`** | **REPLACE** | **pre-existing** | **verification surface** |

Rows 1–4 are BB-G's four and they hold. **Row 5 is new and is the reason for
this stop.**

All four correction commits are ancestors of `8d9160b`, so a
`GEN15_SOURCE_AUTHORITY` of `8d9160b` would satisfy the ancestry requirement.

### 3.1 Correctly excluded

**Privileged helpers stay outside Generation 15**, as ruled. Two differ and both
belong to Phase 8:

```
kyri_exec_transition_action.py   7703231318f7… -> b11a2f19bc46…
kyri_exec_quota.py               4886d5b323c9… -> 54a9b15c6c6e…
```

**Not CREATEs.** A naive `tools/` diff produces ~100 apparent CREATEs
(collectors, observation, occurrence, trust CLI, provisioning). They are
repository files that were never in the runtime closure. The governed closure at
`8d9160b`, computed with `runtime_closure.py` over the Generation-13
`CLOSURE_ROOTS`, is **74 objects** and contains none of them.

`result_content.py` and `contract_outcome.py` are absent from both the installed
tree and the closure, so they are not CREATEs either — they are the *other two*
objects of the deferred verification surface.

## 4. Why row 5 stops this

`verification.py` is a **governed Generation-14 runtime object**: it is installed
under the library root and it is not the helper-published module, so it is one of
the 78. Deriving Generation 15 as *accepted installed Generation-14 → reviewed
source at HEAD* — which is precisely what the ruling instructs — **necessarily
includes it**.

But BA §0.1 ruled the opposite, and that ruling still stands:

> *"`verification.py`, `result_content.py` and `contract_outcome.py` are not to
> be repaired inside G11-BA. Remediation belongs to a separate runtime-generation
> checkpoint, opened **after** the first controlled invoke and **before**
> `kyri-exec-verify` is ever granted or relied upon."*

So the two instructions disagree about a single object, and I am not going to
resolve that by choosing one silently.

### 4.1 What installing row 5 would actually do

Stated precisely, because "deferred" does not mean "unknown":

- The **installed** `verification.py` cannot be imported at all —
  `ImportError: cannot import name 'WORKER_GID'`. It predates `03a2e90`, which
  removed those constants in favour of the identity authority.
- The **reviewed** `verification.py` at HEAD imports cleanly.
- So Generation 15 including row 5 would **fix** a currently broken governed
  object. It is a repair, not a regression.
- It would be a **partial** repair of the surface: `result_content.py` and
  `contract_outcome.py` would still be absent. Nothing imports them, so the
  verify entrypoint would become importable — but the surface would not be whole.
- It changes nothing reachable today: `/etc/sudoers.d/kyri-exec-verify` is
  absent, so `kyri-exec-verify` cannot run either way.

### 4.2 Excluding row 5 is not free either

Leaving it out means Generation 15 knowingly installs a runtime in which one
governed object is a stale, non-importable predecessor while its neighbours move
forward. That is the split-generation shape the whole helper-coherence apparatus
exists to prevent, and it would have to be declared as a deliberate carryover
with its own justification rather than passing silently.

## 5. The three ways forward

I have no preference to press; this is a scope ruling.

| option | Generation 15 contains | consequence |
| --- | --- | --- |
| **A** — include row 5 | 5 REPLACE | the deferred surface is repaired as a side effect of a runtime generation; BA §0.1's sequencing is overtaken. `result_content.py`/`contract_outcome.py` remain absent, so the surface is importable but not whole |
| **B** — exclude row 5 | 4 REPLACE + a declared carryover | matches BB-G exactly and honours BA §0.1, at the cost of shipping a generation with one knowingly stale non-importable object, declared as such |
| **C** — widen to the whole surface | 5 REPLACE + 2 CREATE | repairs the verification surface completely in this generation, and is the largest departure from the ruled scope |

Option C's two CREATEs would be `result_content.py` (`139b77b7…`) and
`contract_outcome.py` (`b1c5a89f…`), which would also give this generation a
CREATE row and so make the CREATE side of the recovery and unknown-byte matrices
testable rather than "not applicable".

## 6. What was not done

No installer, no matrix file, no coherence-group declaration, no fixture, no
recovery matrix, no unknown-byte injection, no installed-import run. All of that
depends on the object set, and the object set is the open question.

The G5 preflight succession work from Phase 5B is unaffected and remains green;
it will classify whichever set is chosen, because the mechanism is the point
rather than the digits.

## 7. Production precheck

Read-only, and unchanged:

```
HOST_GENERATION              14
installed runtime            5bf50db23f086364e594f15c8390e9aff198b2825e681ee2aca2a40b7c133b84
governed object count        78 (+1 helper-published)
identity authorities         3dec888c… / 891beeeb…                unchanged
helper production bytes      489f108dfd93854023817a7339e34cc8ebc9c29b810223381d2b2343952bea86
                             still the accepted predecessor set
sudoers                      f837d5923a719af50944c990569a7475c21628674184d8599b262150495da1a9
fabric                       7c53efcdffdee337fe3ca94b71a3085bf53b4474f19482a523d263feaa6c8e96
CINV-000001                  1dcef40d…d6cfaaa                      unchanged, UNRESOLVED
CRES                         0
```

Production would be eligible for a Generation-15 install on every count except
the undecided object set. The Fabric window is irrelevant to that and was not
renewed.

## 8. Next

A reviewer ruling on §5. Once the object set is fixed I can build the installer,
the coherence groups, the fixture, the recovery matrix and the unknown-byte
proofs against it in one pass — none of that work is blocked by anything else.
