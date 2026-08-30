# ENG-0005 G11-AA — First production stage/invoke preflight

**Date:** 2026-08-30
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `6d08cea47c7fe3d1d0ae9c9ca82a86b37341f0ed`
**Implementation commit:** none — audit only

The question this checkpoint had to answer is what Kyri would actually do if one
production invocation of CSEL-000001 with `operation=execute` were authorised
today.

**Nothing would run.** Not because authority is missing, and not because the
sudoers grant is absent, though it is. The installed worker builds an argv,
verifies the handoff, and then refuses by construction:

```
kyri-exec-worker: no governed runtime backend is bound;
container execution is gated at G6
```

That refusal is the last statement in `/usr/libexec/kyri-exec-worker.py`. There
is no `subprocess` in it, no `os.exec`, no `os.fork`. The OCI image the
implementation authority names does not exist on this host either. First
production invoke is blocked on a development increment, not on a ceremony.

---

## 1. Starting authority and the clock

Verified at `2026-08-30T06:41:43-05:00`, read from the host, not from memory.

| Check | Observed |
| --- | --- |
| HEAD / origin | `6d08cea4…`, clean, synchronized |
| Installed `.py` objects | 70 |
| Runtime digest | `9cbfd043af106c42bf024a07314b19de362d9a0cb10a9aca81b1ee608ce33830` |
| Fabric / Trust / Evidence+Artifacts | `bcb2559b…` / `cffd362c…` / `1f58bad3…` |
| Chain records | CADV-000003 `f2b48c2e…`, CINST-000002 `5cfcf01e…`, CROUTE-0002 `1a7ed018…`, CSEL-000001 `e08a4df4…` |
| `/etc/sudoers.d/` | `README` only — both grants absent |
| Privileged helpers | unchanged |
| Root Authority | `/var/lib/kyri` not a separate mount |
| Fabric sequences | adv=3, contract=1, definition=1, host=1, instance=2, package=1, route=2, selection=1 |

**Remaining validity:** 9h 37m at start; **9h 31m** measured again at
`06:48:12-05:00`, against `2026-08-30T16:19:19-05:00`.

## 2. The call graph, as released

| # | Step | File | Durable? | Privilege |
| --- | --- | --- | --- | --- |
| 1 | `build_parser` → `invoke` | `tools/capability/cli.py:419` | no | coordinator |
| 2 | `_payload` — open approved payload no-follow | `cli.py:180` | no | coordinator |
| 3 | `_instant` — `--requested-at`, tz required | `cli.py:182` | no | coordinator |
| 4 | `_runtime_store` → `CapabilityStore(...)` | `cli.py:170` | **YES — creates directories** | coordinator |
| 5 | `prepare_invocation` | `coordinator.py:34` | — | coordinator |
| 6 | `verify_selected_evidence` | `fabric_evidence.py` | no | coordinator |
| 7 | → `evaluate_eligibility` (12 ELIG conditions) | `fabric/eligibility.py` | no | coordinator |
| 8 | `resolve_and_stage_package` | `package_resolution.py:320` | **YES — publishes a tree** | coordinator |
| 9 | `bind` — binding digest over 6 fields + payload | `invocation_identity.py:76` | no | coordinator |
| 10 | `record_invocation` | `evidence.py:186` | **YES — allocates and writes CINV, and CRES on refusal** | coordinator |
| 11 | adapter branch — `adapter is not None and execution_binding is not None` | `coordinator.py:86` | — | **never taken from the CLI** |
| 12 | return `EXIT_DENIED` | `cli.py:208` | — | — |

Step 4 is worth naming on its own: `ImmutableStore.__init__` runs
`_create_directories()` when `initialize=True`, which is the default. Merely
constructing the store creates `capability-invocations/`,
`capability-results/` and `sequences/` under the store root — **before any
evidence is read**.

Step 11 is the whole answer to "does it execute". `prepare_invocation` accepts
`adapter` and `execution_binding`, both defaulting to `None`, and executes only
when **both** are supplied. `command_invoke` supplies neither. The docstring is
explicit: *"One governed invocation, prepared and then stopped."*

The second surface, `authorise-launch`, carries a prepared invocation to a
lifecycle transition and publishes a handoff under
`/data/kyri/capability-handoff`. It returns `EXIT_SUCCESS`. **It does not
execve.** Nothing in the installed Python tree shells out to `sudo`.

## 3. The exact command

Derived from the installed parser, not invented. Every argument below is
`required=True`.

```bash
python3 -m tools.capability.cli invoke \
  --store-root            /data/kyri/capability-runtime \
  --expected-uid 1000 --expected-gid 1000 \
  --fabric-root           /var/lib/kyri/fabric \
  --fabric-expected-uid 1000 --fabric-expected-gid 1000 \
  --approved-artifact-root /var/lib/kyri/artifacts \
  --trusted-source-uid 0 \
  --staging-root          /data/kyri/capability-runtime/staging \
  --coordinator-uid 1000 \
  --approved-payload-root <coordinator-owned, not group/other writable> \
  --payload-source-uid 1000 \
  --payload-file          <name inside that directory> \
  --invocation-id         <opaque caller identity> \
  --selection-id CSEL-000001 \
  --instance-id  CINST-000002 \
  --package-id   CPKG-0001 \
  --operation    execute \
  --trust-store-root /var/lib/kyri/trust \
  --actor        primary-platform-operator \
  --request-id   <frozen request identity> \
  --requested-at <RFC3339 with offset>
```

**Not executed.**

| Class | Arguments |
| --- | --- |
| A — operator chooses | `--invocation-id`, `--actor`, `--request-id`, `--requested-at`, `--payload-file`, `--operation` |
| B — derived from CSEL | `--selection-id`, and `--instance-id` which the selection must confirm |
| C — derived from CINST | scope, contract, package binding — read, never passed |
| D — derived from CPKG/CCON | `--package-id`; the artifact tree and its digest |
| E — fixed deployment authority | `--store-root`, `--fabric-root`, `--trust-store-root`, `--approved-artifact-root`, `--staging-root`, all uid/gid arguments, `--trusted-source-uid` |
| F — internal | the binding digest, the CINV record id, the staged pathname |

`--operation` is `required=True` with no `default=`. Omitting it is an argparse
error; supplying an unusable value reaches `_usable()`, which repairs nothing
and returns `None`, and the boundary refuses `operation-not-supplied`. It is one
of the six fields in `BINDING_FIELDS`, so it is covered by the binding digest
and appears in the durable record. Proved live below.

## 4. What `execute` actually means — and what would run

The chain resolves completely, and then stops.

| Layer | Value |
| --- | --- |
| Selection | CSEL-000001 → CINST-000002 |
| Package | CPKG-0001 → `tree:kyri-execution-boundary-verification/1.0.0` |
| Package tree digest | `sha256:6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e` |
| Package content | one file, `main.py`, 208 lines |
| Implementation | CIMP-000001 |
| Adapter identity | `python-podman-v1` |
| argv contract | `fixed-python-entrypoint-v1` |
| OCI image id | `5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190` |
| Intended runtime | rootless Podman as `kyri-capability`, uid 999 / gid 987 |
| Intended env | `XDG_RUNTIME_DIR=/run/user/999`; payload mounted at `/run/kyri/input/payload` |

`main.py` describes itself as a deterministic entrypoint that reads the governed
payload, reads one field from it — `operation` — and returns a bounded
verification result. It *"carries no production workload"*.

**What would run today: nothing.** Two independent stops:

1. **The worker executes nothing.** `tools/capability/execution/worker.py` opens
   with *"This module names Podman and invokes nothing… no subprocess exists
   here at all. Binding a real process to `/usr/bin/podman` is a later increment
   behind gate G6."* Mechanically confirmed: zero matches for `subprocess`,
   `os.exec`, `os.fork`, `os.system` in either the module or the installed
   `/usr/libexec/kyri-exec-worker.py`. That helper's final statement is the G6
   refusal quoted at the head of this report.
2. **The image is absent.** `podman images` is empty, and no
   `overlay-images/images.json` exists under the graphroot the code reads
   (`~/.local/share/containers/storage`), nor at any other candidate. The image
   CIMP-000001 names is not on this host.

Podman 4.9.3 is installed and `/data/kyri` is XFS mounted `prjquota`, so the
surrounding infrastructure is real. The workload is not.

## 5. Adapter and execution binding

| Question | Answer |
| --- | --- |
| Is there an adapter the invoke path can select? | A `GovernedAdapter` class exists at `tools/capability/execution/adapter.py` and is installed |
| Does anything construct it? | **No — zero call sites** in the installed runtime |
| Who authorises it? | CIMP-000001, under the implementation authority at `/var/lib/kyri/implementation-authority` |
| Governed by CPKG/CCON/evidence? | Yes — CIMP admission carries `provisioning_evidence_digest` |
| Is its image digest pinned? | Yes — `oci_image_id 5cee2b53…` |
| Does the image exist installed? | **No** |
| Is it executable? | Not reachable: the worker is gated at G6 |
| What side effect would it perform? | None reachable today |

`tools/capability/__init__.py` still states the property directly: *"Nothing here
executes a capability. There is no adapter, and the absence is a property this
package is tested for rather than a stage it has not reached."*

**`ADAPTER_AUTHORISED = NO`.** The smallest next checkpoint is the G6 increment
that binds a runtime backend to the worker and publishes the admitted OCI image
into the store the image module reads. That is a development increment with its
own RED-first evidence, not a ceremony.

## 6. Package staging

`resolve_and_stage_package` requires a staging root that is a directory, not a
symlink, owned by `--coordinator-uid`, and not group- or other-writable. It
materialises the tree under a private staging directory at `_STAGING_MODE =
0o700` — the Semgrep-reviewed constant, unchanged — verifies the tree digest
through its own descriptor, and publishes by rename to:

```
<staging-root>/tree-sha256-<64 hex>
```

For CPKG-0001 that pathname would be:

```
/data/kyri/capability-runtime/staging/tree-sha256-6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e
```

containing `main.py`. Observed mode on the published tree in rehearsal: **0500,
coordinator-owned**. A staging tree that is prepared but not published is left
in place under a name no consumer resolves, deliberately, so an operator can see
that two coordinators raced.

**Staging is durable and survives a later failure.** It happens at step 8,
before the invocation record exists.

## 7. CINV identity and mutation timing

Two identities, easy to conflate:

- `--invocation-id` is an **opaque caller identity** — `validate_invocation_id`
  is documented as *"Opaque by contract… reads nothing into its shape."* It is
  the idempotency key: a repeat with the same binding returns `consumed`, a
  repeat with a different binding returns `conflict`.
- The **CINV record id** is allocated by the store from
  `sequences/capability-invocation.seq`, width 6, starting at 0. The production
  runtime store has no `capability-invocations` directory and no sequence file,
  so the first allocation is **`CINV-000001`**.

Ordering, from the source and confirmed by rehearsal:

```
store construction (creates directories)   ← durable, before any check
  → verify_selected_evidence               ← read-only
  → resolve_and_stage_package              ← durable
  → bind
  → record_invocation                      ← allocates CINV, writes record
                                             (+ CRES on refusal)
  → adapter branch                         ← never reached from the CLI
```

**`CINV_ALLOCATED_BEFORE_STAGE = NO`.** Staging is durable first.

### Mutation table

| Case | Store dirs | Staged tree | CINV allocated | CINV persisted | CRES | Sequence advanced |
| --- | --- | --- | --- | --- | --- | --- |
| A — authority failure (evidence unsupported) | yes | no | yes | yes, `outcome=execution-refused` | yes | yes |
| B — staging failure | yes | no (or an abandoned private tree) | yes | yes, refused | yes | yes |
| C — no adapter (the reachable success) | yes | **yes** | yes | yes, `outcome=execution-prepared` | no | yes |
| D — launch/sudo refusal | as C | yes | already spent at C | yes | no | yes |
| E — worker execution failure | as C | yes | already spent | yes | no | yes |
| F — successful invocation | unreachable today | — | — | — | — | — |

Cases A and B are the important ones: **a refused first invocation still spends
CINV-000001 and CRES-000001.** Proved, not inferred — see §10.

## 8. Current eligibility

Evaluated read-only against the installed Generation-12 engine
(`/usr/lib/kyri/python/tools/fabric/eligibility.py`), using the bridge's own
reader adapters and request shape.

| Instant | Bridge | ELIG |
| --- | --- | --- |
| `2026-08-30T06:45:29-05:00` (now) | `supported=True` | **12/12 met**, eligible |
| now + 2h | `supported=True` | 12/12 met, eligible |
| `2026-08-30T16:19:19-05:00` (expiry) | refused `admission-window-not-open` | 10/12 — ELIG-6 `advertisement-not-fresh`, ELIG-7 `admission-window-expired` |
| expiry + 1s | refused `admission-window-not-open` | 10/12, same two |

The window is **half-open**: the expiry instant itself is already closed.

G11-X scope, live: `operation=execute` → `supported=True`;
`operation=delete` → `operation-not-permitted-by-scope`. CAPDEF-0001,
`internal` and HOST-0001 are all inside the admitted `effective_scope`.

No selection was created and no record renewed.

## 9. Expiry and renewal

**`RENEW_BEFORE_FIRST_INVOKE = YES`** — and the reason is not a short window.

At completion roughly nine hours remain, which would be ample for an operator
review, a sudoers ceremony, a staging and invoke ceremony, and post-invoke
verification. That is not the binding constraint. The binding constraint is that
the first invoke **cannot happen in this window at all**: it waits on the G6
increment that binds a runtime backend and publishes the admitted image, which
is development work with its own review, not something to be compressed into an
afternoon before an advertisement lapses.

CADV-000003 and CINST-000002 will therefore expire before any first invoke is
possible, and the chain will need renewal when G6 is ready.

What would need renewing, derived from current semantics rather than assumed:

- **CADV** — yes. Freshness is ELIG-6 and it is the head the instance depends on.
- **CINST** — yes. `admitted_until` is ELIG-7, and admission is bounded by the
  advertisement it was admitted under.
- **CROUTE** — **no**. `verify_selected_evidence` states the route is
  deliberately not consulted: *"a route that has moved on says the plane would
  choose differently now; it does not say this binding stopped being eligible."*
  This is the G11-Y property.
- **CSEL** — **no**, on the same reasoning. CSEL-000001 remains historical
  evidence of a selection that happened. It is not re-derived at invoke, and a
  new selection is not required merely because the binding was renewed.

Not authored here.

## 10. Fixture rehearsal

No `--preflight` or dry-run exists on the invoke path, so the path was exercised
against isolated temporary roots: copies of the production Fabric, Trust and
artifact stores, a temporary capability store, staging root and payload.
Production was read, never written.

**Run 1 — staging root rejected** (mode too permissive):

```json
{"status": "refused", "reason": "staging-root-unusable",
 "invocation_record_id": "CINV-000001", "result_record_id": "CRES-000001",
 "binding_digest": "sha256:835e8042…", "payload_digest": "sha256:df70d3db…",
 "artifact_digest": null, "staged_path": null}
```

CINV-000001 and CRES-000001 were **spent by a refusal**. This is case B of the
mutation table, observed rather than argued.

**Run 2 — the full reachable path**, fresh store, staging root at 0700:

```json
{"status": "prepared", "reason": "no_authorised_adapter",
 "invocation_record_id": "CINV-000001", "result_record_id": null,
 "artifact_digest": "sha256:6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e",
 "staged_path": ".../staging/tree-sha256-6f2282c5…"}
```

Exit status 1 (`EXIT_DENIED`) on both. The durable record carries
`operation: execute`, `outcome: execution-prepared`, the selection, instance,
package, contract, `effect_class: computational`, both digests and the staged
path. The store held exactly `capability-invocations/CINV-000001.yaml`,
`sequences/capability-invocation.seq` (value `1`) and the identity lock.

`DRY_RUN = PASS` for everything up to the adapter boundary. There is no
observability past it, because there is nothing past it yet.

## 11. Privileged helper and sudoers

The privileged step is a single command, run by the operator — nothing in the
Python tree invokes it:

```
sudo /usr/libexec/kyri-exec-transition CINV-000001
```

| Property | Value |
| --- | --- |
| Helper | `/usr/libexec/kyri-exec-transition`, `0555 root:root` |
| SHA-256 | `bd31bcbf63423a9e9e418a28c974233ecb73d0d67f4b54837f8bbed2b8d5c932` |
| Invoking uid | 1000 (`cschott`) |
| Target uid/gid | 999 / 987 (`kyri-capability`) |
| execve target | `/usr/bin/python3 /usr/libexec/kyri-exec-worker.py <cinv> <cimp> <profile-digest>` |

The proposed rule, from `provisioning/execution/sudoers.d/kyri-exec.example`:

```
Cmnd_Alias KYRI_EXEC_TRANSITION = sha256:<installed helper digest> \
    /usr/libexec/kyri-exec-transition ^CINV-[0-9]{6}$
cschott ALL=(root) NOPASSWD: KYRI_EXEC_TRANSITION
```

**Least-privilege audit: the rule is tight.** It is digest-pinned, so a replaced
helper is not covered. It admits exactly one command with exactly one argument,
constrained by regex to a canonical CINV. There is no wildcard, no shell, no
directory, no environment passthrough. `NOPASSWD` is justified in the file
itself by the coordinator being non-interactive. The helper takes no option
parser *"on purpose: an option parser is a place for flags to be added later."*

No broad or unsafe grant is required. **Not installed, and not installed here.**

## 12. Coordinator identity — uid 1000

`kyri-exec-transition.py` hardcodes `COORDINATOR_UID = 1000` and
`kyri-exec-transition-action.py` enforces it twice, on the launch record and on
the profile: `check(os.fstat(handle), expected_uid=module.COORDINATOR_UID)`. A
launch record owned by anything else is refused with *"the launch record is
owned by the wrong identity"*. The sudoers rule names `cschott` literally.

On this host `id -u` is 1000 and the account is `cschott`, so it holds. Nothing
derives it and no provisioning step guarantees it: `kyri-capability` is created
explicitly at uid 999, but the coordinator identity is inherited from whoever
happens to own the deployment.

**Classification: D and A together** — it is a genuine security boundary that
must stay fixed in the privileged helper, *and* it is an undocumented deployment
invariant. G11-Z6 found three test suites resting on the same coincidence; this
shows the live privileged path rests on it too.

The first invoke's safety depends on it, so
**`COORDINATOR_IDENTITY_RULING_REQUIRED_BEFORE_INVOKE = YES`**. Nothing was
changed here. The reviewer should decide whether the deployment *guarantees*
uid 1000, or whether the constant should be provisioned and asserted rather than
assumed.

## 13. Quota and the privilege transition

`/data/kyri` is `/dev/sdb1`, XFS, mounted with `prjquota` — the boundary's
infrastructure is present. Default project limits are established once at G4 by
an operator, so the runtime only says which project a tree belongs to: *"One
ioctl, and nothing else… Nothing is supplied by a caller. Not a path, not a
project ID, not a limit."*

The transition documents order as the security property: *"`setgroups` must
precede `setgid`, which precedes `setuid`, because each step spends privilege
the next one needs… `no_new_privs` comes after the drop."* The released order
matches the accepted invariant — quota, close descriptors, setgroups, setgid,
setuid, verify the permanent drop, `no_new_privs`, execve — and `quota` is a
required argument rather than an optional one.

`QUOTA_BOUNDARY_READY = YES` for the boundary itself. It was not executed.

## 14. Side-effect map, if authorised today

**PERSISTENT**

- `/data/kyri/capability-runtime/{capability-invocations,capability-results,sequences}/`
  — created by store construction, before any check;
- `sequences/capability-invocation.seq` → `1`; `sequences/invocation_identity.lock`;
- `capability-invocations/CINV-000001.yaml`;
- `capability-results/CRES-000001.yaml` — refusal cases only;
- `staging/tree-sha256-6f2282c5…/main.py`, mode 0500, coordinator-owned;
- with `authorise-launch`: a lifecycle transition record and a per-CINV handoff
  under `/data/kyri/capability-handoff`.

**TEMPORARY**

- the private staging directory at 0700 before the publishing rename;
- an abandoned staging tree if preparation fails after it was created —
  deliberately left for an operator to find.

**PROCESS-ONLY**

- with the sudoers grant: one root `kyri-exec-transition`, dropping to 999/987
  and exec'ing `/usr/bin/python3 /usr/libexec/kyri-exec-worker.py`, which exits
  non-zero with the G6 refusal. No container is created, no image is pulled, no
  network is used.

**UNKNOWN** — none. There is no reachable path whose effects are unclear,
because the reachable path stops before anything ambiguous.

**Not reachable today:** container creation, workload execution, result
collection, artifact output, quota allocation against a running tree.

## 15. Failure containment

| Boundary | CINV | Staged tree | Lifecycle | Retry |
| --- | --- | --- | --- | --- |
| CSEL invalid / instance mismatch | allocated + persisted refused | none | CRES written | new request id needed |
| CINST ineligible (any ELIG) | allocated + persisted refused | none | CRES | after renewal |
| Scope denied (wrong operation) | allocated + persisted refused | none | CRES | with a permitted operation |
| Package digest mismatch | allocated + persisted refused | none | CRES | after authority repair |
| Staging write failure | allocated + persisted refused | possibly an abandoned private tree | CRES | operator removes residue |
| Staging verification failure | as above | abandoned tree left deliberately | CRES | as above |
| Adapter absent (today's terminus) | allocated + persisted **prepared** | published | no CRES | same caller identity replays as `consumed` |
| Helper unauthorised (no sudoers) | already spent | published | unchanged | after the grant |
| Quota / uid-gid drop / `no_new_privs` failure | already spent | published | transition refuses before execve | — |
| execve failure | already spent | published | refused | — |
| Worker non-zero exit (the G6 refusal) | already spent | published | no result admitted | — |

Replay is governed by `compare_binding`: the same `--invocation-id` with the
same binding returns `consumed`; with a different binding, `conflict`. Neither
allocates a second CINV.

**`AMBIGUOUS_FAILURE_STATE = NO` for every reachable boundary.** The one place
the design explicitly refuses to resolve ambiguity is beyond the G6 gate: the
adapter has no `transition_failed_before_execution` and *"if the workload cannot
be excluded from having run, nothing here says it did not"*. That is the correct
direction, and it is unreachable today.

The one thing worth flagging is not ambiguity but cost: **the first refused
attempt permanently consumes CINV-000001**, because the record is written before
the adapter is reached, deliberately, *"so a crash during execution leaves a
decision that was durably made rather than one nobody can account for."* The
first production CINV will therefore very likely record a refusal, and that is
by design rather than a defect.

## 16. Proposed ceremony

Not runnable today; recorded so the shape is agreed before it is.

| Gate | Content | Supported by the architecture? |
| --- | --- | --- |
| 1 | Frozen invoke request: every argument in §3 fixed and reviewed, including `--invocation-id`, `--request-id`, `--requested-at` | Yes |
| 2 | Read-only evidence and current eligibility at the ceremony instant | Yes — §8, repeatable |
| 3 | Package and staging preflight | **Partially.** No `--preflight` on the invoke path; the fixture rehearsal of §10 is the closest available, and it cannot use the production store root without mutating it |
| 4 | Sudoers/helper installation, separately authorised | Yes — the rule is written and digest-pinned |
| 5 | One intentional CINV/stage/invoke mutation | Yes, but it will terminate at the G6 refusal |
| 6 | Post-execution verification | Yes for records and staging; nothing to verify past the gate |
| 7 | Sudoers removal | The example does not describe the grant as temporary; whether it is removed after the ceremony is a reviewer decision |

**Gate 3 is the real gap.** Every other governed write in this platform has a
rehearsal — `declare-package --preflight` predicts its record id and writes
nothing. The invoke path has no equivalent, so the first production invoke
cannot be rehearsed against its own store root without spending CINV-000001.
Adding one is a small, well-precedented increment, and it would be worth having
before the first invoke rather than after.

## 17. Actions not performed

No stage, no invoke, no CINV allocated in production, no invocation sequence
advanced, no sudoers installed, no privileged helper called, no adapter created,
no CADV/CINST renewal, no route, no selection, no Fabric, Trust, artifact or
evidence mutation, no runtime reinstall, no Root Authority mount. No source
changed. None of the carried-forward hardening items touched.

The `/data/kyri/capability-runtime` store still has no `capability-invocations`
directory, confirmed after all work.

## 18. Production no-mutation

| Surface | Before and after |
| --- | --- |
| Installed `.py` objects | 70 |
| Runtime digest | `9cbfd043af106c42bf024a07314b19de362d9a0cb10a9aca81b1ee608ce33830` |
| Fabric store | `bcb2559bdbc13ad760b5cb19e40d9327fc3c5e94b1988ae1e690159dcdcff15e` |
| Trust store | `cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39` |
| Evidence + Artifacts | `1f58bad398bf141e3956e28d6210e7a333461e89d10051e197154e8d514f9c07` |
| Privileged helpers | unchanged |
| `/etc/sudoers.d/` | `README` only |

## 19. Blockers and reviewer decisions

**Blocking the first production invoke:**

1. **G6 — no runtime backend is bound.** The worker executes nothing and says
   so. This is the blocker; everything else is downstream of it.
2. **The admitted OCI image is absent** from this host's image store.
3. **Coordinator identity (§12)** — the privileged helper's uid-1000 boundary is
   an undocumented deployment invariant.
4. **Sudoers grant not installed** — correctly, and its installation is a
   separate authorised ceremony.

**Decisions for the reviewer:**

- Whether the deployment should guarantee and assert `COORDINATOR_UID`, rather
  than inherit it from whoever owns the deployment.
- Whether an invoke-path rehearsal (`--preflight`) should exist before the first
  invocation, given every other governed write has one.
- Whether the sudoers grant is intended to be permanent or removed after each
  ceremony.
- That the first production CINV will most likely record a refusal, by design.

Carried forward unchanged:

- `NEXT_ROUTE_WRITE_BLOCKED_PENDING_HEAD_HARDENING=YES`
- `ADMISSION_DEPENDENCY_BOUND_STRUCTURAL_HARDENING_PENDING=YES`
- `ELIG6_ADVERTISEMENT_HEAD_POLICY=UNRESOLVED`
- `SEMGREP_RULESET_POLICY=DYNAMIC`, pinning still recommended separately.

**`FIRST_PRODUCTION_INVOKE_READY = NO`.**
