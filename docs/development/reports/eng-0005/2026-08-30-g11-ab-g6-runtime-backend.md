# ENG-0005 G11-AB — G6 runtime backend, coordinator authority, and invoke rehearsal

**Date:** 2026-08-30
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `523a64668a1e87e4466e6f00ba7d230fe77a2030`
**Implementation commits:** `298ea2a`, `c1dd001`

Three workstreams were asked for. One is delivered, one is blocked by a missing
governed artefact, and one is designed but deliberately not shipped.

**`invoke --preflight` exists and is proved.** The rehearsal every other governed
write in this platform already had.

**The G6 backend is blocked, and not on effort.** The OCI image CIMP-000001
admitted cannot be reproduced or imported from committed authority — the digest
it names appears nowhere in the repository, the only image identity the
repository does record is a *different* value, and the base it was built from is
unreachable from this host. Phase F says stop there rather than invent an image
that happens to run `main.py`, and that is what this checkpoint does.

**A new, harder scheduling dependency surfaced.** Renewing the expiring binding
requires a new route, and route writes are blocked pending head hardening. That
now sits on the critical path to first invoke.

---

## 1. Starting authority

Verified at `2026-08-30T07:19:53-05:00`.

| Check | Observed |
| --- | --- |
| HEAD / origin | `523a6466…`, clean, synchronized |
| G11-AA report | present, ancestor of HEAD |
| Installed runtime | 70 objects, `9cbfd043…33830` |
| Chain | CADV-000003 → CINST-000002 → CROUTE-0002 → CSEL-000001, unchanged |
| `/etc/sudoers.d/` | `README` only |

## 2. G6 architecture, reconstructed from source

The execution path is complete and stops in three independent places.

| Layer | State |
| --- | --- |
| `invoke` | Prepares and stops. `command_invoke` always returns `EXIT_DENIED`. |
| `prepare_invocation` | Executes only when **both** `adapter` and `execution_binding` are supplied; the CLI supplies neither. |
| `GovernedAdapter` | Exists, installed, **zero call sites**. |
| `authorise-launch` | Publishes a handoff and stops. No `execve`. |
| `kyri-exec-transition` | Drops privilege and execs the worker. Requires a sudoers grant that is not installed. |
| `worker.py` / `kyri-exec-worker.py` | *"This module names Podman and invokes nothing."* Terminal statement: `no governed runtime backend is bound; container execution is gated at G6`. Zero matches for `subprocess`, `os.exec`, `os.fork`, `os.system`. |
| OCI image | Absent. `podman images` empty; no `overlay-images/images.json` under the graphroot the code reads. |

The intended backend is Podman, and that is established from committed
architecture rather than inferred from the name `python-podman-v1`:
`provisioning/image/Containerfile` and its README define an OCI image;
`worker.py` compiles in `PODMAN = "/usr/bin/podman"`, `XDG_RUNTIME_DIR=/run/user/999`
and `PAYLOAD_DESTINATION=/run/kyri/input/payload`; `image_store.py` reads the
rootless graphroot index; `profile.py` pins `ARGV_CONTRACT_IDENTITY =
"fixed-python-entrypoint-v1"`. Podman 4.9.3 is installed and `/data/kyri` is XFS
mounted `prjquota`, so the surrounding infrastructure is real.

**`G6_BACKEND = PODMAN`.**

## 3. Phase F — the image authority is missing

This is the finding that stops the backend.

| Evidence | Result |
| --- | --- |
| CIMP-000001 admitted `oci_image_id` | `5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190` |
| That digest in the repository | **absent** — it appears only in the live admission record and in the G11-AA report |
| CIMP `provisioning_evidence_digest` `86762793…` | resolves to nothing, in the repository or in host evidence |
| Only image identity the repository records | `a3ef70eee8c906c4604f53bb1874ab5bf4922bab9c5f0ba6b6d9ce126f589b69`, in `tests/test-capability-execution-g5-authority.sh`, commented *"the live facts this pass was given"* — **a different value** |
| `provisioning/image/Containerfile` | present, and matches the digest the G5 suite pins (`f543c458…`) |
| `BASE_IMAGE` | no default, deliberately: *"a floating tag baked into an authoritative definition would mean the image Kyri admitted and the image Kyri later built were the same text and different bytes"* |
| Base reference | `cgr.dev/chainguard/python@sha256:84e1f28d…`, recorded only in a test constant and truncated in the operator README |
| Base reachable from this host | **no** — `podman manifest inspect` fails |

So the build recipe is governed and intact, and the *identity of what was built
from it* is not. The repository cannot reproduce `5cee2b53…`, cannot import it,
and cannot even validate a rebuild against committed authority, because the one
image id it records is a different one.

Per Phase F this stops backend publication. Per Phase G, a reviewer ruling is
requested rather than rewriting CIMP-000001. **`OCI_IMAGE_AUTHORITY = MISSING`.**

Phases G through M and S are therefore not implemented. Building a Podman
backend and proving it end-to-end requires an image; substituting a different
one would make the proof about an artefact nobody admitted, which is exactly
what "do not invent an image that happens to run main.py" forbids.

## 4. `invoke --preflight` — implemented

### What it cost not to have

G11-AA proved it rather than argued it: a staging-root permission mistake in a
fixture rehearsal returned `refused`/`staging-root-unusable` **and had already
spent CINV-000001 and CRES-000001**. The invoke path writes before it can
report — the store constructor creates directories, staging publishes a tree,
and `record_invocation` allocates and writes, all before the adapter is reached.

That behaviour is now pinned as PART 1 of the new suite, so the reason the
rehearsal exists cannot quietly stop being true.

### Shared logic, not a second decision

The reviewer required that real invoke and rehearsal share logic. They do: the
rehearsal calls the real `prepare_invocation` under `rehearsing()`. Same
selected-evidence verification, same current Fabric eligibility, same operation
and scope gates, same manifest validation, and the same full source-tree
traversal with every symlink, size, depth and race refusal it carries.

It stops at exactly the two points where preparation stops being reversible:

| Stop | Where | What still ran |
| --- | --- | --- |
| Staging | `package_resolution.py`, immediately before `tempfile.mkdtemp` | manifest validated, destination known, source tree walked in full |
| Allocation | `evidence.py`, immediately before `invocation_critical_section` | identity validated, digests shaped, prior-record lookup, both conclusions computed |

The mechanism is `tools/capability/rehearsal.py` — one contextvar and two
functions — modelled directly on `tools.fabric.admission.rehearsing()`. The
store gains a read-only `peek_next_id`, restated in the capability store for the
reason the Fabric store restated its own: `tools/common/immutable_store.py` is an
installed Generation-10 object, and reaching into it to add a read-only helper
would open a generation for a plane that does not need one.

### What it predicts

Proved against the live production chain, in fixture copies:

```json
{"outcome": "preflight", "would_accept": true, "would_refuse_reason": null,
 "predicted_invocation_record_id": "CINV-000001",
 "selection_id": "CSEL-000001", "instance_id": "CINST-000002",
 "capability_package_id": "CPKG-0001", "operation": "execute",
 "binding_digest": "sha256:835e8042…", "payload_digest": "sha256:df70d3db…",
 "package_tree_sha256": "sha256:6f2282c5…", "would_stage_at": "…/tree-sha256-6f2282c5…",
 "current_eligibility": true, "scope_permits_operation": true,
 "implementation_id": "CIMP-000001", "execution_backend": "python-podman-v1",
 "argv_contract": "fixed-python-entrypoint-v1",
 "execution_image_id": "5cee2b53…", "execution_image_available": false,
 "adapter_authorised": false, "privileged_helper_required": true}
```

The two gates are reported apart, because "would it be accepted" does not tell
an operator *which* one moved.

### Proof of non-mutation

`PREFLIGHT_MUTATES = NO`, established four ways: a byte-level manifest of the
whole fixture tree — names, types, modes, sizes and contents — is identical
before and after; no invocation record is written; the invocation sequence is
never created or advanced; nothing is staged. Refused rehearsals allocate
nothing either.

And it stays a prediction, not a lease: repeated rehearsals return
`CINV-000001` having spent none, the real write then takes it, and a rehearsal
afterwards predicts `CINV-000002`. Re-rehearsing a *consumed* caller identity
reports `invocation_identity_consumed` and points at the record that identity
already has, rather than predicting one the write would never allocate.

**33/33 assertions, and no production path changed.**

### Phase O — real invoke still rechecks everything

Nothing is cached and nothing is handed forward. The rehearsal returns a report;
the write re-runs `prepare_invocation` from the beginning, re-verifies selected
evidence, re-evaluates current eligibility at its own `requested_at`, re-resolves
the package, and allocates for itself. A preflight is a rehearsal, not a lease —
which is stated in `rehearsal.py` and enforced by there being no plan object to
carry.

### Two invariants made stronger

Both were textual bans that the rehearsal's *reporting* tripped, and neither was
loosened:

- The adapter suite banned the word `adapter` in `cli.py`. It could not tell a
  CLI that constructs an adapter from one that reports whether an adapter is
  authorised. It now checks the parse tree: no adapter import, no adapter
  construction, and no call to `execute`, `create` or `start`. Strictly
  stronger.
- The launch-CLI suite bans `sudo` in `cli.py`. Rather than weaken it, the
  preflight no longer probes whether the grant is installed. It reports
  `privileged_helper_required`, which is what the brief asked for; whether the
  grant *exists* is not this surface's business, and reading the elevation
  namespace to answer it would be a second opinion about authority the helper
  already enforces.

## 5. Coordinator authority — designed, deliberately not shipped

The reviewer ruled that coordinator identity is deployment-specific authority,
that the hard-coded `1000` must not become `$UID`, and that an existing trusted
deployment surface should be reused rather than duplicated.

That surface exists. `/etc/kyri` is root-owned `0711` and already carries
`backing-store.json`, a root-authored configuration the runtime opens
`O_NOFOLLOW` by descriptor and hands to a governed verifier
(`verify_backing_store`) that parses canonical JSON and refuses every malformed
or unexpected field. The coordinator identity belongs there, in exactly that
shape:

- `/etc/kyri/coordinator-identity.json`, root-owned, canonical JSON, single
  field `coordinator_uid`;
- read by `kyri-exec-transition.py` in place of the compiled-in constant, through
  the same descriptor-first, no-follow, bounded-read discipline;
- read by provisioning to derive the sudoers principal, so the grant and the
  helper cannot disagree about who the coordinator is;
- absent, malformed, or writable by anyone but root ⇒ **refuse**, never a
  fallback to a default.

**It is not implemented here, and that is a judgement I want visible rather than
quiet.** The change alters the bytes of a privileged helper. Privileged helpers
were deliberately excluded from Generation 12 and cannot be installed without
their own ceremony; the sudoers rule that names the same principal is installed
in that same ceremony; and the backend those helpers exist to reach is blocked
on §3. Landing new privileged bytes now would put a security boundary in the
checkout that nothing can install, exercise, or verify end-to-end, months ahead
of the ceremony that closes it. The right checkpoint for this is the one that
runs that ceremony, where the helper digest, the sudoers rule and the authority
file are installed and verified together.

`COORDINATOR_AUTHORITY = UNRESOLVED`, `COORDINATOR_UID_HARDCODE_REMOVED = NO`.
The finding from G11-AA stands unchanged: `COORDINATOR_UID = 1000` is enforced
twice in the privileged action helper, the sudoers example names `cschott`
literally, and nothing derives or guarantees either.

## 6. Generation impact

Six installed-runtime objects change. Derived by digest, not assumed.

| Object | Operation | From | To |
| --- | --- | --- | --- |
| `tools/capability/rehearsal.py` | CREATE | ABSENT | `ed847939…` |
| `tools/capability/store.py` | REPLACE | `581901bf…` | `a476c5ec…` |
| `tools/capability/evidence.py` | REPLACE | `d2429646…` | `ba3b3fc7…` |
| `tools/capability/package_resolution.py` | REPLACE | `0c5c9487…` | `2124005c…` |
| `tools/capability/coordinator.py` | REPLACE | `1df5e494…` | `d2db378d…` |
| `tools/capability/cli.py` | REPLACE | `b45f5332…` | `b5628bfd…` |

Installed count would go 70 → 71. The capability package moves from twelve
modules to thirteen, and its dependency surface gains `contextvars` — both
asserted as exact values in `test-capability-runtime.sh`, so adding a module to
that package stays a decision somebody makes on purpose.

Declared as pending in `provisioning/execution/g5-preflight.sh`'s
`GENERATION_DELTA`, which is what makes local validation coherent while the
checkout runs ahead of the installed runtime. **`NEXT_GENERATION = 13`.
Nothing was installed.**

## 7. Privileged helper and sudoers

No helper source changed, so no helper digest changed, and no sudoers change is
required by this checkpoint. `PRIVILEGED_HELPER_CHANGE_REQUIRED = NO` and
`SUDOERS_CHANGE_REQUIRED = NO` **for what was implemented**; both become YES
when the coordinator authority of §5 is implemented, which is the reason to do
those together.

The rule remains as audited at G11-AA — digest-pinned command, one argument
constrained to `^CINV-[0-9]{6}$`, no shell, no wildcard — and is not installed.

## 8. The expiring chain, and the renewal dependency

Per Phase U the chain was left to expire. Observed at `2026-08-30T08:22:41-05:00`:
**7h 56m remaining** against `2026-08-30T16:19:19-05:00`. No operational failure
follows, because production invocation is disabled at three independent points.

What renewal requires is derived from source, not assumed:

| Record | Required | Why |
| --- | --- | --- |
| CADV-000004 | **YES** | advertisement freshness is ELIG-6 |
| CINST-000003 | **YES** | the admission window is ELIG-7 |
| CROUTE-0003 | **YES** | `selection.py` iterates `route["candidate_instances"]`, and CROUTE-0002 names only CINST-000002. A new instance the route does not name can never be selected. |
| CSEL-000002 | **YES** | selection binds an instance; CSEL-000001 selects the instance that will have expired |

The route conclusion is the consequential one, and it is not in tension with
G11-Y. G11-Y says a route that has *moved on* does not invalidate a historical
selection at invoke time. It says nothing about creating a *new* binding, and
creating one requires a route that names it.

**`ROUTE_HEAD_HARDENING_BLOCKS_RENEWAL = YES`.** `NEXT_ROUTE_WRITE_BLOCKED_PENDING_HEAD_HARDENING`
has been carried forward for several checkpoints as a deferred item. It is now on
the critical path: no route write means no CROUTE-0003, which means no CSEL-000002,
which means no first invoke. It was not solved here, as instructed, but it has
stopped being optional.

## 9. Validation

| Suite | Result |
| --- | --- |
| Invoke preflight (new) | 33/33 |
| Capability runtime | pass |
| Invocation operation authority (G11-X) | 55 |
| Invoke current eligibility (G11-Y) | 49 |
| Capability fabric | 538 |
| Generation-12 packaging / installer | pass |
| Fabric install closure | pass |
| Execution adapter, launch CLI, G5 preflight | pass |

| Mode | Steps | Result |
| --- | --- | --- |
| Quick | **79/79** | passed, exit 0 |
| Full | **102/102** | passed, exit 0 |

Both totals rose by one and were re-measured against a real run rather than
incremented, as `run-validation.sh` requires of itself. The new suite is
registered in the validator and in `ci.yml`.

`pre-commit run --all-files`: all five hooks. ShellCheck 0.9.0: pass.

**GitHub, commit `c1dd001`:** CI `33313704774` success, ShellCheck `33313704810`
success, Semgrep `33313704802` success, plus CodeQL, Gitleaks and Trivy.

The Semgrep result is worth recording, because the G11-Z6 mechanism did its job
unprompted. Changing `package_resolution.py` moved the reviewed finding from line
466 to 476 and changed the file digest, and the checker **refused**: an exception
is pinned to rule, path, line and current sha256 together, so any edit forces the
finding to be looked at again. It was: same call site, same `_STAGING_MODE =
0o700`, same reasoning. The registry records the re-review rather than silently
absorbing it.

## 10. Production non-mutation

| Surface | Value, before and after |
| --- | --- |
| Installed `.py` objects | 70 |
| Runtime digest | `9cbfd043af106c42bf024a07314b19de362d9a0cb10a9aca81b1ee608ce33830` |
| Fabric store | `bcb2559bdbc13ad760b5cb19e40d9327fc3c5e94b1988ae1e690159dcdcff15e` |
| `/data/kyri/capability-runtime` | still no `capability-invocations` directory |
| `/etc/sudoers.d/` | `README` only |

No production stage, CINV, CRES, sequence advance, helper call, adapter, image
import, runtime install, CADV/CINST renewal, route, selection, Fabric, Trust,
Evidence or Root Authority change.

## 11. Blockers and reviewer decisions

**Blocking first invoke, in dependency order:**

1. **Route-head hardening** — blocks CROUTE-0003, which blocks CSEL-000002 (§8).
2. **The OCI image authority** (§3) — a governed artefact is missing, and no
   backend can be proved without it.
3. **G6 backend binding** — implementable once an image exists.
4. **Coordinator authority** (§5) — deployment-bound identity, to land with the
   privileged-helper ceremony.
5. **Generation 13** — publishes the preflight.
6. **Sudoers ceremony** — separately authorised.

**Decisions requested:**

- **The image.** Reproduce it from a re-recorded base digest and re-admit the
  result as a new CIMP; or import the existing artefact from wherever it still
  exists and record its provenance; or retire CIMP-000001 and admit a fresh
  image built under the governed procedure. Rewriting CIMP-000001 to match
  whatever gets built is the one option this checkpoint refuses to take on its
  own.
- **Whether the `a3ef70ee…`/`5cee2b53…` discrepancy** is a stale test constant or
  evidence that the admitted image was built outside the recorded procedure.
- **Scheduling route-head hardening**, now that it gates renewal.
- **Whether the coordinator authority ships with the helper ceremony** (§5) or
  sooner.

Carried forward unchanged: `NEXT_ROUTE_WRITE_BLOCKED_PENDING_HEAD_HARDENING=YES`,
`ADMISSION_DEPENDENCY_BOUND_STRUCTURAL_HARDENING_PENDING=YES`,
`ELIG6_ADVERTISEMENT_HEAD_POLICY=UNRESOLVED`, `SEMGREP_RULESET_POLICY=DYNAMIC`.
