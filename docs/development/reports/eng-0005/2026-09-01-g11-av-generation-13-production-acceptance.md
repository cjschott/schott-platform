# ENG-0005 G11-AV — Generation 13 is live, and what it still needs

**Date:** 2026-09-01
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `1374e12f308e35b9542c3b96886df153d9dfa0fb`
**Implementation:** `a27b3fc` (test fixtures only — no runtime change)

Generation 13 is installed on production and is accepted here **from installed
bytes**, not from the installer's own report: 78 objects, all `0444 root:root`,
13/13 replaced and 8/8 created at their reviewed targets, all three coherence
groups whole, and no undeclared object anywhere in the tree.

**One thing is not closed.** The transaction journal and both generations'
evidence live under `/root`, which the coordinator may not read — correctly. I
could not read them, so `GEN13_JOURNAL_STATE` and `GEN12_EVIDENCE_PRESERVED` are
reported **UNKNOWN** rather than inferred from the operator's `--verify-installed`
PASS. §8 gives the exact commands that close it.

Nothing was installed, renewed or invoked. Quick **97/97**, full **122/122**.

---

## 1. Operator install evidence

Supplied and taken as given: `--verify`, `--install` and `--verify-installed`
each PASS, reviewed authority `7709cf0…`, 21 changed objects, 73-module closure,
13 REPLACE, 8 CREATE, groups whole, Generation-13 evidence written,
Generation-12 evidence preserved, no grants, no residue.

Everything below re-derives that independently. Where the derivation needs a
path the coordinator may not read, it says so instead of borrowing the
installer's sentence.

## 2. Live object proof

Read directly from `/usr/lib/kyri/python`.

| | |
| --- | --- |
| `HOST_GENERATION` | **13** |
| installed runtime objects | **78** |
| `GEN13_DIGEST` | `bc985098f8774e44dab3d4d5291bca1654a2002a3edf94a794b57987b5c745c2` |
| modes | `0444` — **all 78** |
| ownership | `root:root` — **all 78** |

The digest is a per-object hash over relative path and content:

```
sha256( for each object, sorted by path: relpath || 0x00 || sha256(bytes) )
```

Stated because G11-AU spent effort on an aggregate whose formula no artefact
recorded. The repository's own convention for store manifests —
`cd <root> && find . -type f | sort | xargs sha256sum | sha256sum` — was
recovered this checkpoint (§9) and reproduces every recorded governance value
exactly; it is **not** used for the library root, because it includes
`__pycache__`, which the interpreter rewrites and which therefore cannot be part
of an identity.

## 3. Matrix proof

| Class | Result |
| --- | --- |
| REPLACE at the reviewed Generation-13 target | **13/13** |
| CREATE at the reviewed Generation-13 target | **8/8** |
| every row's target equals the reviewed authority's blob | **21/21** |
| carried-over objects accounted for | **57/57** |
| undeclared runtime objects | **0** |

The 57 carried-over objects are the installed set less the 21 declared rows.
Fifty-five are byte-identical to the Generation-12 authority `1313df01…`. Two
are not, and both are explained:

| Object | Bytes from | Why |
| --- | --- | --- |
| `kyri_exec_transition.py` | `cfb0edd` | the stale helper pair G11-AI documented |
| `kyri_exec_transition_action.py` | `cfb0edd` | Generation 12 deliberately excluded both |

So every one of the 78 installed objects is reviewed material with a named
origin. **Nothing on this host is unaccounted for.**

G11-AU reported `GEN13_CARRYOVER=47`, which counted carried-over objects *inside
the closure*. This reports 57, which counts them across the whole installed set —
the difference is the six installed objects outside the closure plus the four
flattened helper-library modules. Both numbers are right about different sets;
the installed-set number is the one that matters for acceptance.

## 4. Coherence groups

Derived by hashing the installed objects, not read from the installer.

| Group | | At target |
| --- | --- | --- |
| **A** | execution and supervision | **10/10** — whole Generation 13 |
| **B** | result and lifecycle | **7/7** — whole Generation 13 |
| **C** | identity, recovery and readiness | **4/4** — whole Generation 13 |

The pairings checked individually rather than by group total, because a group
total can be whole while the pair that matters is not:

- **PASS** the new worker beside the Podman backend it imports
- **PASS** the new supervisor beside the new result writer
- **PASS** execution beside its recovery enumeration
- **PASS** the released CLI beside the launcher it imports

`RESULT_SCHEMA_VERSION=2`, `INVOCATION_SCHEMA_VERSION=2`, and
`adapter_identity` is on the invocation record — so the result plane is the one
the supervisor was built against, which is what "new supervisor with the old
result writer" would have broken.

## 5. Installed import proof

Twenty-three modules imported with `/opt/schott-platform` removed from
`sys.path` and the working directory moved off it. Every `__file__` asserted to
be under `/usr/lib/kyri/python`.

```
tools.capability.cli, coordinator, records, evidence, inspection, store
tools.capability.execution.{adapter, helpers, identity, launch, lifecycle,
                            profile, protocol, recovery, supervision, worker}
tools.capability.fabric_evidence
tools.fabric.{eligibility, trust_adapter}
tools.trust.{query, store}
kyri_exec_podman, kyri_exec_launcher
```

**Repository leakage: 0.** `GEN13_INSTALLED_IMPORT = PASS`.

The released interface reports its six verbs from installed bytes:
`authorise-launch, execute, inspect, invoke, recover, validate`.

## 6. G11-X and G11-Y, enforced live

Not a declaration check. The **installed** verifier was driven against a
read-only copy of the production Fabric and Trust stores.

**G11-X** — the same governed claim is supported inside the window, and each of
these is refused with its governed reason:

| Claim | Refusal |
| --- | --- |
| an operation the scope does not permit | `operation-not-permitted-by-scope` |
| no operation supplied | `operation-not-supplied` |
| an operation that is not a string | `operation-not-supplied` |
| a package the selection did not name | `claimed-package-not-bound` |
| an instance the selection did not name | `claimed-instance-not-selected` |
| a selection that does not exist | `selection-not-found` |

**G11-Y** — the identical governed claim, evaluated *now*:
`admission-window-not-open`. Inside the window it was supported; the refusal is
the instant and not the claim, which is exactly what G11-Y added — and it is an
independent confirmation that the chain has lapsed.

`G11_X_LIVE = PASS`, `G11_Y_LIVE = PASS`. No production CINV or CRES was
created; the fixture was a copy and was removed.

## 7. Supervision present in the installed runtime

Static and import proof only. **No helper was invoked.**

| | |
| --- | --- |
| coordinator supervisor, supervised binding | present |
| disposal proven before an outcome | present on the trace |
| protocol state machine, eight kinds, duplex channel | present |
| end of stream distinct from a violation | `ProtocolEnded` present |
| the worker reports T13's outcome class | on the terminal schema |
| recovery enumeration and the execution-safety gate | present |
| helper compatibility checker | present |
| the coordinator's supervised entry | present |
| the worker's identity comes from authority | required argument |
| the Podman backend has no compiled-in environment | required argument |

## 8. Journal and evidence — the one open item

`/root` is not readable by the coordinator, and that is the correct permission
rather than an obstacle to work around. The operator's `--verify-installed` PASS
is consistent with a COMMITTED journal and both evidence files present, because
that mode asserts exactly those — but I did not read them, so they are reported
UNKNOWN.

The unprivileged half of `--verify-installed` did run here and passed:

```
ok  repository at the branch, reviewed authority 7709cf0… an ancestor of HEAD
ok  all 21 Generation-13 changed objects correspond to the reviewed commit
ok  the governed write path and every Trust decision surface are absent
```

It then halted on `Permission denied` reading the Generation-12 evidence.

**Operator reads that close this, all read-only:**

```bash
sudo cat /root/kyri-gen13-transaction/journal
sudo ls -la /root/kyri-gen1[23]-*.txt
sudo sha256sum /root/kyri-gen12-library-digests.txt \
               /root/kyri-gen12-helper-digests.txt \
               /root/kyri-gen13-library-digests.txt \
               /root/kyri-gen13-helper-digests.txt
sudo grep -E '^(commit|baseline_commit|state|predecessor|library_objects|expects_)' \
     /root/kyri-gen13-helper-digests.txt
sudo bash /opt/schott-platform/provisioning/execution/install-generation-13.sh \
     --verify-installed
```

Expected: `state=COMMITTED`, `commit=7709cf0…`, `baseline_commit=1313df01…`,
`library_objects 78`, four `expects_helper` lines, and both Generation-12 files
still present.

## 9. Governance non-mutation

Measured with the repository's own store-manifest formula, recovered by
reproducing a recorded value exactly.

| Store | Files | Aggregate | Recorded baseline |
| --- | --- | --- | --- |
| Fabric | 21 | `bcb2559b…ff15e` | **identical** |
| Trust | 26 | `cffd362c…bbc39` | **identical** |
| Artifacts | 2 | `30732e2c…6257f` | **identical** |
| Platform evidence | 1 | `227abde8…0984b` | **identical** |

`CIMP-000001` admission: `ecb38d80dd0e9ee444b182811fd556184b085e5e0cec236bf012228f0dc9991b`
— **identical**. Two `CGEN` generations, unchanged.

| | |
| --- | --- |
| CADV / CINST / CROUTE / CSEL | 3 / 2 / 2 / 1 — **no new record** |
| sequences | 3, 2, 2, 1 — **unadvanced** |
| `PRODUCTION_CINV_COUNT` | **0** — the record directory does not exist |
| `PRODUCTION_CRES_COUNT` | **0** — likewise |
| handoff root | **0 entries** |

`FABRIC_UNCHANGED = YES`, `TRUST_UNCHANGED = YES`,
`CIMP_000001_UNCHANGED = YES`. The runtime install changed no governance
authority.

## 10. Helper state

`INSTALLED_HELPER_STILL_STALE = YES` — expected, not tampering. The helper
ceremony has not run.

| Object | Installed | Target | State | Mode |
| --- | --- | --- | --- | --- |
| `/usr/libexec/kyri-exec-transition` | `bd31bcbf6342` | `0d9c8d8c9181` | **stale** | 0555 |
| `/usr/libexec/kyri-exec-worker.py` | `64260190330b` | `6d06695f4335` | **stale** | 0444 |
| `/usr/libexec/kyri-exec-verify` | `fad96924adbb` | `1c87788c6559` | **stale** | 0555 |
| `/usr/libexec/kyri-exec-verify-worker.py` | `5a614ff73c0d` | `c747c6d0c306` | **stale** | 0444 |
| `/usr/libexec/kyri-exec-quota` | `4886d5b323c9` | `4886d5b323c9` | current | 0555 |
| `/usr/libexec/kyri-exec-reconcile` | — | `2878fff04bb2` | **ABSENT** | — |
| `/usr/libexec/kyri-exec-reconcile-worker.py` | — | `b0e3c047f689` | **ABSENT** | — |
| `kyri_exec_transition.py` | `6488044bc824` | `de264c6490e0` | **stale** | 0444 |
| `kyri_exec_transition_action.py` | `bd32af5de4f3` | `7703231318f7` | **stale** | 0444 |
| `kyri_exec_verify.py` | `3d70707d19c3` | `f49c29571a4e` | **stale** | 0444 |
| `kyri_exec_quota.py` | `4886d5b323c9` | `4886d5b323c9` | current | 0444 |
| `kyri_exec_reconcile.py` | — | `29175d5a7175` | **ABSENT** | — |

Seven stale, three absent, two current. `RECONCILE_HELPER_INSTALLED = NO`.

**A finding worth recording.** The installed `kyri_exec_transition.py` is the
pre-G11-AH module: it has **no coordinator-authority parser and no
execution-authority parser at all**. So nothing on this host reads either
identity file today — which means installing them changes no behaviour until the
helper ceremony runs, and it is why they are inert rather than dangerous in
between.

## 11. Sudoers state

`/etc/sudoers.d` holds the distribution `README` and nothing else. The launch,
verification and reconcile grants are each **absent**. `SUDOERS_CLOSED = YES`.
No production execution authority has been granted.

## 12. Identity candidates

Both re-derived from live account facts and rehearsed through parsers, not
trusted from earlier reports.

| | Coordinator | Execution |
| --- | --- | --- |
| resolved | `cschott` uid 1000 | `kyri-capability` uid 999 gid 987 |
| bytes | 76 | 99 |
| SHA-256 | `3dec888c…2811` | `891beeeb…e373` |
| destination | `/etc/kyri/coordinator-identity.json` | `/etc/kyri/execution-identity.json` |
| owner / mode | `root:root` `0444` | `root:root` `0444` |
| present | **absent** | **absent** |

Both byte-identical to their accepted values, so nothing was regenerated
casually.

**Coordinator** — accepted by the *target* helper policy (`cschott`, principal
`cschott`); the installed policy cannot read one at all (§10). It refuses an
authority owned by the coordinator and one that is group-writable.

**Execution** — accepted by the **installed** runtime's reader, resolving the
account through the live database; derived environment
`HOME=/data/kyri/capability`, `XDG_RUNTIME_DIR=/run/user/999`. It refuses a
recycled uid and an authority the execution principal could write. The installed
runtime and the target helper policy agree on the path and the schema.

Both `READY`. Each ceremony must refuse if its destination already exists.

## 13. Helper ceremony candidate

Ten objects, moving together. `HELPER_CEREMONY_CANDIDATE = READY`.

| Target | Operation | Mode |
| --- | --- | --- |
| `kyri_exec_transition.py` | REPLACE | 0444 |
| `kyri_exec_transition_action.py` | REPLACE | 0444 |
| `kyri_exec_verify.py` | REPLACE | 0444 |
| `kyri_exec_reconcile.py` | CREATE | 0444 |
| `/usr/libexec/kyri-exec-transition` | REPLACE | 0555 |
| `/usr/libexec/kyri-exec-verify` | REPLACE | 0555 |
| `/usr/libexec/kyri-exec-worker.py` | REPLACE | 0444 |
| `/usr/libexec/kyri-exec-verify-worker.py` | REPLACE | 0444 |
| `/usr/libexec/kyri-exec-reconcile` | CREATE | 0555 |
| `/usr/libexec/kyri-exec-reconcile-worker.py` | CREATE | 0444 |

All `root:root`. Modes taken from the installed precedent for each class —
library modules 0444, `libexec` entrypoints 0555, `libexec` worker scripts 0444
— rather than assumed.

**No partial installation.** A host carrying half of one commit is the G11-AI
defect, where a verification guard was defeated by the older module beneath it.

## 14. Helper compatibility with the live runtime

The installed Generation-13 runtime was asked its own question.

**Against the live deployment:** `incompatible`, 4 of 4 blocking —
`kyri-exec-transition` stale, `kyri-exec-worker.py` stale, `kyri-exec-reconcile`
absent, `kyri-exec-reconcile-worker.py` absent.

**Against a tree holding the target bytes:** `compatible`, all four current.

The supervised preflight agrees: `supervision_ready: false`, both identity
authorities false, both grants `unobservable` — the coordinator may not read the
elevation namespace and does not claim to have.

So the runtime **refuses the stale deployment surface and accepts the intended
one**, which is the property the compatibility checker exists for.

## 15. Fabric state and expiry

| Kind | Count | Head | Window |
| --- | --- | --- | --- |
| CADV | 3 | `CADV-000003` | `valid_until 2026-08-30T16:19:19-05:00` |
| CINST | 2 | `CINST-000002` | `admitted_until 2026-08-30T16:19:19-05:00` |
| CROUTE | 2 | `CROUTE-0002` | supersedes `CROUTE-0001` |
| CSEL | 1 | `CSEL-000001` | routes through `CROUTE-0002` |

**Expired by 1 day, 19 hours.** `FABRIC_CHAIN_EXPIRED = YES` — confirmed twice,
once by reading the window and once by the installed verifier refusing a
governed claim with `admission-window-not-open`.

The structural invariant holds on the current head:
`CINST-000002.admitted_until` **equals** `CADV-000003.valid_until` exactly. The
renewal must carry it forward.

## 16. Renewal plan

Next identities read from the allocators, with widths taken from the existing
heads rather than assumed:

| | Sequence | Next |
| --- | --- | --- |
| advertisement | 3 | **`CADV-000004`** |
| instance | 2 | **`CINST-000003`** |
| route | 2 | **`CROUTE-0003`** |
| selection | 1 | **`CSEL-000002`** |

Dependency order and the invariants each step must carry:

1. **`CADV-000004`** — supersedes `CADV-000003`, a fresh `valid_until`.
2. **`CINST-000003`** — supersedes `CINST-000002`, advertises `CADV-000004`,
   and `admitted_until <= CADV-000004.valid_until`. G11-AG made this a bound
   rather than a coincidence.
3. **`CROUTE-0003`** — supersedes `CROUTE-0002`, targets `CINST-000003`.
4. **`CSEL-000002`** — routes through `CROUTE-0003`.

## 17. First-invoke readiness graph

| Gate | State |
| --- | --- |
| Generation 13 runtime | **PASS** — installed, verified from bytes |
| Coordinator identity authority | **NOT INSTALLED** |
| Execution identity authority | **NOT INSTALLED** |
| Launch helper | **STALE** |
| Reconcile helper | **ABSENT** |
| Launch sudoers grant | **ABSENT** |
| Reconcile sudoers grant | **ABSENT** |
| Fabric chain | **EXPIRED** |
| Supervised preflight | **not ready** |

`PRODUCTION_INVOKE_AUTHORISED = NO`. Every remaining gate is a deliberate
ceremony, and none of them was opened here.

## 18. Deployment order

G11-AU's ruling stands, with one clarification this checkpoint can now make from
evidence rather than argument.

The runtime came **first**, and did — because the new helper set imports objects
Generation 13 installs. The two identity authorities can go before the helpers
because **nothing on this host reads them yet** (§10): the installed helper
policy has no parser for either. Installing them is inert until the helper that
reads them arrives, and installing the helper *before* them would leave a helper
that would refuse on its first invocation.

1. ~~Generation 13~~ — **done**.
2. **Coordinator identity authority** — 76 bytes, `3dec888c…`, `root:root 0444`.
3. **Execution identity authority** — 99 bytes, `891beeeb…`, `root:root 0444`.
4. **The coherent helper set** — all ten objects, one ceremony.
5. **Verify compatibility** — `helpers.compatibility()` must report
   `compatible`; today it reports `incompatible` and names all four.
6. **Supervised invoke preflight, read-only.**
7. **`CADV-000004`**, then **`CINST-000003`**, then **`CROUTE-0003`**, then
   **`CSEL-000002`**.
8. **Both sudoers grants** — last, because until here nothing safe existed for
   them to authorise.
9. `capability invoke --preflight`, `invoke`, `authorise-launch`.
10. **One controlled `capability execute`.**
11. Verify `CINV`, `CRES` and the result digest.
12. `capability recover` — expect `ready`, zero unresolved.

**Fabric may be renewed before or after the helper ceremony**, and the reason is
worth stating: renewal writes Fabric records and touches no execution surface,
while the helper ceremony touches only execution surfaces. They are independent.
The order above puts renewal after the helpers so that the last thing before the
grants is the shortest-lived: an advertisement window that expires again while
waiting for a helper ceremony would have to be renewed twice.

## 19. Next ceremonies, kept separate

Each is its own authorisation. Bundling them would mean approving a production
mutation whose predecessor had not been verified.

| | Scope |
| --- | --- |
| **G11-AW** | freeze and install both identity authorities; verify neither changes behaviour yet |
| **G11-AX** | the coherent ten-object helper ceremony; compatibility must flip to `compatible` |
| **G11-AY** | `CADV-000004` and `CINST-000003`, carrying the admission bound |
| **G11-AZ** | `CROUTE-0003` and `CSEL-000002` |
| **G11-BA** | both sudoers grants and the final supervised preflight |
| **G11-BB** | one controlled production invoke, and the recovery health proof after it |

Planning notes, not authority.

## 20. Validation

| Gate | Result |
| --- | --- |
| `run-validation.sh --quick` | **PASS**, 97/97 |
| `run-validation.sh` (full) | **PASS**, 122/122 |
| Generation-13 installer | **PASS**, 45 cases |
| Generation-13 packaging | **PASS**, 21 cases |
| Generation-12 packaging | **PASS** |
| ShellCheck, Semgrep, pre-commit | clean |
| GitHub workflows | see handoff |

### Three suites broke, and the reason is the same one

Installing the generation on production made three suites false, because each
built its "Generation-12 host" by copying the live library root. The moment the
host advanced, the fixture advanced with it: `--verify` reported
already-installed, `--install` became a no-op that wrote no evidence, and the
ordering demonstration compared Generation 13 against itself and would have
proved nothing while passing.

The Generation-12 packaging suite failed loudly and *said so* — its own header
predicted "on Generation 13 this fails saying so, rather than reporting a
mystifying object count", and that is exactly what happened. That is the failure
mode a test should have.

All three now reconstruct the baseline from **reviewed data**: carried-over
objects from the host, REPLACE targets restored to the baseline bytes the matrix
pins, CREATE targets removed, and the baseline bytes found at the Generation-12
authority or by walking the history of that path. A row whose baseline is in
neither fails rather than being worked around. Two assertions were restated
rather than relaxed: the host is at one of the two declared generations and
never between them.

`a27b3fc` is test fixtures only. **No runtime object changed**, which is what
lets the installed Generation 13 remain the reviewed `7709cf0…` surface.

## 21. Production safety

Nothing was installed, written, renewed or invoked by this checkpoint.

- No identity authority, no helper, no sudoers grant, no generation.
- No Fabric renewal; no new CADV, CINST, CROUTE or CSEL; no sequence advanced.
- No production CINV or CRES — the record directories do not exist.
- No container, no privileged helper invocation, no sudo.
- Fabric, Trust, artifacts, platform evidence and `CIMP-000001` byte-identical
  to their recorded baselines.

The only production mutation in this chain is the Generation-13 runtime install
the operator performed before this checkpoint began.

`PRODUCTION_MUTATION = GEN13_INSTALL_ONLY`.
`PRODUCTION_INVOKE_AUTHORISED = NO`.

## 22. Next

Two operator actions, in this order:

1. **Close §8** — the five read-only `sudo` commands, so the journal state and
   both generations' evidence are read rather than inferred.
2. **G11-AW** — freeze and install the two identity authorities, which are
   prepared, byte-identical to their accepted values, and inert on this host
   until the helper ceremony follows them.
