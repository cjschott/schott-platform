# ENG-0005 G11-BB-J — helper ceremony, prepared

**Status: prepared and proven in fixture. Not installed.** Production untouched.
`CINV-000001` byte-identical, `CINV-000002` unspent. No sudoers change, no
Fabric change, no identity change.

Branch `arch/eng-0005-execution-transition`, HEAD `1a56f38`.

---

## 1. The delta, re-derived

Not carried from BB-G. Derived from the **governed `HELPER_SOURCES` mapping** —
the declaration that says which repository source installs to which privileged
path — against reviewed source at `ef4f744`.

```
HELPER_TARGETS 3    HELPER_REPLACE 3    HELPER_CREATE 0    HELPER_REMOVE 0
HELPER_SOURCE_AUTHORITY = ef4f7446200b668f8dcbf34d180c5102270f19f6
```

| path | installed predecessor | reviewed target | op | loaded by | closure |
| --- | --- | --- | --- | --- | --- |
| `/usr/lib/kyri/python/kyri_exec_transition_action.py` | `7703231318f7…` | `b11a2f19bc46…` | REPLACE | both entrypoints, as `ACTION_MODULE` | INSIDE |
| `/usr/lib/kyri/python/kyri_exec_quota.py` | `4886d5b323c9…` | `54a9b15c6c6e…` | REPLACE | launch entrypoint, as `QUOTA_MODULE` | INSIDE |
| `/usr/libexec/kyri-exec-worker.py` | `6d06695f4335…` | `2d320630aca5…` | REPLACE | exec'd by the transition after the drop | INSIDE |

It matches BB-G's expectation, so no stop was required — but it was proved, and
the proof mattered, because a naive path-guessing sweep produces four extra
false positives by mapping `/usr/libexec/kyri-exec-transition` to
`kyri-exec-transition.py` (the module) instead of
`kyri-exec-transition-entrypoint.py` (its actual source). The governed mapping
is the authority; filename similarity is not.

### 1.1 A legacy artefact, reported not swept in

`/usr/libexec/kyri-exec-quota` exists on the host, is `root:root 0555`, and
carries the **same predecessor bytes** as the library-root quota module
(`4886d5b3…`). It is:

- **not** in `HELPER_SOURCES`, **not** in `REQUIRED_HELPERS`, **not** in the AX
  ceremony's ten, **not** in Generation 14's declared privileged surface;
- referenced only by Generation-7 and Generation-10 installer tests;
- loaded by nothing — the launch entrypoint loads `kyri_exec_quota` as a
  **module** from the library root, never this path.

So it is a legacy duplicate from an older layout, not a transitive dependency,
and it is outside the declared surface this ceremony governs. It is **not**
included. It does carry the latent read-mode anchor, inert because nothing execs
it and no grant names it — the same category as the verify entrypoint. Recorded
for a separate disposition (removal or adoption); widening this ceremony to
reach it unilaterally would be the scope creep the derivation exists to prevent.

## 2. Sudoers pins — unchanged

```
LAUNCH_ENTRYPOINT_SHA256    0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1
RECONCILE_ENTRYPOINT_SHA256 2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77
SUDOERS_PINS_MATCH          YES
SUDOERS_CHANGE_REQUIRED     NO
```

Both digests were read from the installed bytes and compared against what the
**sudo policy parser** reports, not against the file text. Both entrypoints are
absent from the delta: their reviewed source at `ef4f744` is byte-identical to
what is installed. The suite asserts they do not move.

## 3. The privileged graph

Derived from source, not assumed.

```
sudo /usr/libexec/kyri-exec-transition        pinned, UNCHANGED
  -> kyri_exec_transition            POLICY_MODULE      unchanged
  -> kyri_exec_transition_action     ACTION_MODULE      CHANGED
  -> kyri_exec_quota                 QUOTA_MODULE       CHANGED     (runs as root, pre-drop)
  -> credential drop to 999:987
  -> execs /usr/libexec/kyri-exec-worker.py             CHANGED

sudo /usr/libexec/kyri-exec-reconcile         pinned, UNCHANGED
  -> kyri_exec_transition                                unchanged
  -> kyri_exec_transition_action                         CHANGED    (shared with launch)
  -> credential drop to 999:987
  -> execs kyri-exec-reconcile-worker.py                 unchanged
       -> kyri_exec_reconcile, kyri_exec_podman          unchanged
```

`HELPER_DEPENDENCY_GRAPH = PASS`. Every changed object is reachable on the
launch path; `kyri_exec_transition_action.py` is on **both**. No changed
privileged dependency exists outside the three.

## 4. Cross-surface coherence — the answer, and why

```
REQUIRED_PRODUCTION_ORDER = GEN15_THEN_HELPERS
```

**`helpers.py` is a runtime object that carries the digests the readiness rule
checks helpers against.** Generation 14's copy declares the predecessors;
Generation 15's declares these targets. So the installed runtime generation
decides what "current" means for a helper, and the ceremony is judged by
whichever copy is installed.

Every state was run through the **real `compatibility()`**, using each fixture's
own `helpers.py` as the declaration and only redirecting paths — `compatibility()`
takes its required tuple as a parameter, so no rule was reimplemented.

| | runtime | helpers | verdict | |
| --- | --- | --- | --- | --- |
| A | Gen 14 | predecessor | **compatible** | current production |
| B | Gen 15 | predecessor | **incompatible** | fails closed |
| C | Gen 14 | successor | **incompatible** | fails closed |
| D | Gen 15 | partial (6 of 7 subsets) | **incompatible** | fails closed |
| E | Gen 15 | complete | **compatible** | the target |

**Neither intermediate is dangerous, and that is the point.** `incompatible`
means `supervision_ready` is false and the coordinator refuses before crossing
the privilege boundary. An intermediate state cannot execute anything wrongly;
it simply refuses. So no cross-surface atomic transaction is needed — what is
needed is that no partial state ever reports compatible, which §5 proves
exhaustively.

The order follows from the coupling rather than from preference, and **the
ceremony enforces it**: `require_runtime_generation` halts unless the installed
`helpers.py` is the Generation-15 one. Run against production today it says so:

```
STOP: the installed readiness rule is 74b84015…, not the Generation-15
6dd93606…: install Generation 15 before this ceremony
```

## 5. The partial-deployment matrix

All 2³ subsets, against the Generation-15 declaration, using the installed rule
rather than a filename count:

```
000 refuses   001 refuses   010 refuses   011 refuses
100 refuses   101 refuses   110 refuses   111 COMPATIBLE
```

`HELPER_PARTIAL_DEPLOYMENT_REFUSAL = PASS`. Only the complete set is compatible,
and only paired with the Generation-15 runtime.

## 6. Results

```
HELPER_CEREMONY_PREINSTALL     READY
HELPER_VERIFY_NON_MUTATING     PASS   library and libexec manifests identical
HELPER_FIXTURE_INSTALL         PASS
HELPER_FIXTURE_VERIFY_INSTALLED PASS
HELPER_UNKNOWN_BYTES           PASS   unknown bytes at a REPLACE predecessor refused
HELPER_RECOVERY                PASS   all ten publication boundaries
WORKER_ANCHOR_FIX              PASS
QUOTA_ANCHOR_FIX               PASS
ABSENT_RECONCILE_E2E           PASS
FULL_SUPERVISED_E2E            PASS
RECOVERY_E2E                   PASS
```

**Recovery** at `stage`, `staged`, `prepared`, `precommit`, `committing`,
`publish`, `verify`, `postcommit`, `evidence`, `cleanup` — each leaves a **whole
helper set**, three predecessors or three targets, never a mixture.

**Anchor proofs.** The production-shape RED fixtures were re-run as regressions:
a traverse-only parent refuses the read-mode open, an `O_PATH` anchor reaches
the named child, and the parent still cannot be enumerated. The quota correction
changes only the anchor flags — quota still runs **before** `drop_privilege`, no
ordering moved, and no broader directory authority was introduced.

**E2E regressions** all pass, including supervised orphan discovery with
`CINV.adapter_identity` null, governed reconciliation of a real orphan, and
readiness staying closed until disposal is proven.

## 7. One correction to the ported ceremony

The AX ceremony's target fixture staged the matrix rows plus **one hardcoded
carry-over** (`kyri_exec_quota.py`), because AX moved ten objects covering the
whole declared closure and quota was the exception.

This ceremony moves three of eight, so that shape was wrong twice over: five
declared objects would have been judged **absent**, and the hardcoded carry-over
would have overwritten quota — which this ceremony *does* move — with its
predecessor.

It now derives the carry-over set from the installed declaration: stage the
matrix rows, carry every other declared helper as the host holds it. A helper
added to `REQUIRED_HELPERS` later cannot silently fall out of the simulation.

## 8. Validation

```
focused helper suite  PASS
LOCAL_QUICK           PASS   108/108
LOCAL_FULL            PASS   133/133
GITHUB_CI             PASS   6/6 at 1a56f38
CLEAN_CLONE_VERIFY    PASS   full clone of the pushed commit, focused suite green
working tree          clean; HEAD == pushed branch head
```

## 9. Production precheck

```
HOST_GENERATION        14
runtime                5bf50db23f086364e594f15c8390e9aff198b2825e681ee2aca2a40b7c133b84
libexec                489f108dfd93854023817a7339e34cc8ebc9c29b810223381d2b2343952bea86
helper compatibility   compatible, 8 declared, 0 blocking
identity authorities   bf825c7c380082dd21b574ba82d4e507392485ef1ba1b19c1fd7dc1f5fa09f61
sudoers                f837d5923a719af50944c990569a7475c21628674184d8599b262150495da1a9
CINV-000001            1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa
CRES                   0
fabric window          21h 20m remaining
```

The predecessor helper set is coherent and production is a valid starting
position for the ruled order. **The Fabric window may expire during this work
and that does not block anything here** — it was not renewed.

## 10. Next

Reviewer acceptance, then a deployment decision. The order is settled and
mechanically enforced: **Generation 15, then the helper ceremony**, with the
intermediate state fail-closed by design rather than by timing.
