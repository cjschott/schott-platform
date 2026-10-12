# ENG-0005 G11-AL — the backend reachable from the released entrypoint

**Date:** 2026-08-31
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `8bf2eef5df2b0e7e97c2d0d876b91ca1e660d5c4`
**Implementation commit:** `e40866a`

The primary objective is met. The worker entrypoint binds the governed Podman
backend, and the Generation closure reaches it **naturally through the released
worker** — the stated acceptance criterion — with nothing whitelisted.

**Done.** The binding, with privilege ordering, snapshot precedence and the
closed registry pinned structurally. Closure 61 → 68 objects. The Generation-13
delta is now complete and honest. Quick **86/86**, full **111/111**.

**Not done, and the reason is scope rather than an obstacle.** The full invoke
E2E through CINV/CRES (Phases 9–13), the preflight extension (14–16) and the
Generation-13 installer (21–22) were not built. Each needs a substantial
fixture harness; none is blocked by anything discovered here. §12 says what
remains and in what order.

**One finding worth reading before the next ceremony:** the deployment now has
**four** install surfaces, not three, and two of them must move together or
execution breaks. §10.

`SUDOERS_INSTALL_BLOCKED_PENDING_HELPER_COHERENCE = YES`. Production mutation:
none.

---

## 1. Starting authority

HEAD = `origin` = `8bf2eef`, working tree clean, all four G11-AK commits
ancestors. The exported OCI archive is preserved and was reused; no production
Podman storage was opened. Baseline quick 85/85, full 110/110.

## 2. The G11-AK stop

The backend existed and was proven at the adapter seam, but nothing reached it
from the released entrypoint. `kyri-exec-worker.py` still ended at *"no
governed runtime backend is bound; container execution is gated at G6"*. So the
invoke path had no route to a container, preflight had nothing to report, and
the closure could not see `kyri_exec_podman.py` at all — which is why
Generation 13 could not be packaged honestly.

## 3. The worker call graph

Established mechanically before any code moved.

**Before:**

```
main(argv)
 ├ _library()                      → tools.capability.execution.worker
 ├ require_worker_identity(uid,gid)
 ├ require_launch_context(cinv,cimp,digest)
 ├ profile_from_descriptor(ctx, fd=3)   → ExecutionProfile  (result discarded)
 └ SystemExit("no governed runtime backend is bound")
```

**The gap**, and it was exactly one span: between an authenticated profile and
`create_argv`, the library already had `verify_execution` → `VerifiedExecution`
→ `snapshot.materialise` → `SnapshotBinding` → `create_argv`, and the adapter
already took its backend by injection. Nothing had to be invented; the
entrypoint had to call it.

**After:**

```
main(argv)
 ├ _library()
 ├ require_worker_identity(uid,gid)          ← the gate
 ├ require_launch_context(...)
 ├ profile_from_descriptor(...)              → profile
 └ run_execution(...)
     ├ verify_execution(ctx, profile, handoff_fd, images)  → verified
     ├ snapshot.materialise(verified, ...)                 → binding
     ├ backend_for(profile.adapter_identity, ...)          → PodmanBackend
     ├ worker.create_argv(binding)                         → argv
     └ PythonPodmanAdapter(backend, session, clock).execute(...)
```

`run_execution` is factored out of `main` so it can be exercised without being
the execution identity, which `main` requires before it reaches there. That is
a testing seam and not a widening: nothing else calls it, every collaborator is
passed in rather than discovered, and the ordering is pinned by AST.

## 4. The RED, and its limits

The honest form of the RED here is not what the brief anticipated, and it is
worth stating why.

`main` calls `require_worker_identity(uid=os.getuid(), gid=os.getgid())`, which
refuses anything but 999:987. **No unprivileged test can drive `main` past step
one**, so a RED that ran the real entrypoint through to a backend call was
never available — before or after this change. The pre-existing suite reflects
that: it proves the entrypoint *fails closed* as the wrong identity and nothing
further.

What was available, and is what the suite now asserts:

- the governed refusal string is **gone** (`no governed runtime backend is
  bound`, `gated at G6`), which is the whole of the change stated as an
  absence;
- the real entrypoint **loads** through the established root-rewriting seam and
  exposes `run_execution`, `_backend_module` and `main`;
- the backend registry resolves `python-podman-v1` and refuses everything else.

Recorded rather than glossed, because "RED through the real entrypoint" reads
as achievable and is not.

## 5. The binding

**Resolved like the library, and for the same reason.** `_backend_module`
checks the canonical root holds the file *before* importing, inserts the root
at the front of the path, then asks the module where it actually came from — a
search path is a preference and this needs a fact. Resolution from anywhere
else is a refusal, because a backend arriving from a stale path entry would be
a different program holding this identity's Podman authority.

**Selected by the authenticated profile.** `backend_for(profile.adapter_identity)`
through the closed registry: not from argv, not from the environment, not from
the package. An identity with no implementation has no backend rather than a
default one.

**Imported, never constructed by name.** No `importlib`, no `__import__`, no
`spec_from_file_location`, no getattr-by-string — asserted over the AST.

## 6. Privilege ordering

Unchanged, and now pinned structurally rather than by reading.

The transition's order is untouched: quota → close descriptors → setgroups →
setgid → setuid → verify permanent drop → `no_new_privs` → `execve` worker. By
the time this process exists, that has already happened.

**So Podman runs from a permanently unprivileged context by construction, not
by convention.** There is no privileged step left in the entrypoint to perform
and none is performed: `setuid`, `setgid`, `setgroups`, `prctl`, `FS_IOC`,
`projid`, `ioctl`, `chown`, `chmod`, `fork`, `execve` and `subprocess` are all
asserted absent from its code.

Within the entrypoint, the identity gate precedes every execution step —
`require_launch_context`, `profile_from_descriptor`, `_backend_module` and
`run_execution` all appear after `require_worker_identity` in source order,
asserted from the AST because an ordering true only by reading is one refactor
from not being true.

The only module in the platform that starts a process remains
`kyri_exec_podman`, and the entrypoint imports it rather than running anything
itself.

## 7. Snapshot precedence

Preserved and pinned. `verify_execution` runs first and produces the gate
result; `materialise` consumes **that result** rather than the profile, which is
what stops the snapshot being a way around the gate; `create_argv` takes the
resulting binding and nothing else.

So the container's bind sources are the worker's own copy, and there is no seam
through which a coordinator-owned handoff path could reach Podman. The output
descriptor is opened `O_NOFOLLOW|O_DIRECTORY|O_CLOEXEC`.

## 8. The exit contract

`main` returns `0 if outcome.succeeded else 1`, and `succeeded` is true only
where T14 admitted a trusted result. A capability that failed, timed out, or
produced nothing collectable exits non-zero.

The eight bits carry **admission, not completion** — a parent cannot read "the
worker exited" as "the capability succeeded". The richer classification
(`completed`, `provider-error`, `timeout`, `adapter-error`, `interrupted`)
travels in the evidence, where it can carry a reason.

## 9. Generation-13 closure

This is the acceptance criterion, and it is met.

| | Objects |
| --- | --- |
| closure from the previous six entry roots | 61 |
| closure with the released worker entrypoint added | **68** |

The seven that arrive are `kyri_exec_worker.py`, `kyri_exec_podman.py`,
`adapter.py`, `collector.py`, `lifecycle.py`, `mount_evidence.py`,
`protocol.py` — the execution path, reachable at last.

**Nothing was whitelisted.** The backend was *not* added to the closure tool.
The worker entrypoint was added as an entry root because it is a production
execution entry point, and the backend arrives through its import. That
distinction is the criterion, and it is asserted in the suite.

`FLATTENED` is a closure-resolution device — it tells the tool where to find
the source for a module name — and carries no install destination. The
generation installer installs `tools/`; where the library-root and libexec
objects go is §10's business.

### The Gen12 → Gen13 matrix

| Operation | Count | Objects |
| --- | --- | --- |
| **REPLACE** (generation, `tools/`) | 8 | `capability/cli.py`, `coordinator.py`, `evidence.py`, `package_resolution.py`, `store.py`, `execution/lifecycle.py`, `execution/profile.py`, `execution/worker.py` |
| **CREATE** (generation, `tools/`) | 2 | `capability/execution/mount_evidence.py`, `capability/rehearsal.py` |
| carry-over, identical | 54 | — |

**Generation-13 runtime delta: 10 objects, mixed CREATE and REPLACE.** Not all
CREATE, which the installer must handle.

## 10. Four install surfaces, and a pair that must move together

The delta above is only the generation. The full picture:

| # | Surface | Objects | State |
| --- | --- | --- | --- |
| 1 | coordinator authority | `/etc/kyri/coordinator-identity.json` | absent → CREATE |
| 2 | privileged helper (`/usr/lib/kyri/python/`) | `kyri_exec_transition.py`, `kyri_exec_transition_action.py` | REPLACE ×2 |
| 3 | **worker entrypoint + backend** | `/usr/libexec/kyri-exec-worker.py`, `/usr/lib/kyri/python/kyri_exec_podman.py` | REPLACE + CREATE |
| 4 | Generation 13 (`tools/`) | 10 objects | REPLACE ×8, CREATE ×2 |

Surface 3 is new with this checkpoint, and **its two objects must be installed
together.** The new entrypoint refuses if the backend module is absent
(*"the governed runtime backend is not installed at …"*), and the backend
without the entrypoint is inert. Installing one without the other is a broken
deployment — fail-closed, but broken.

That is the same shape as the split-`16f285e` defect: two halves of one change,
where installing a subset produces a runtime whose halves disagree. It is
recorded here so the ceremony treats them as one unit rather than discovering
it at the first invoke.

### The full installed → proposed matrix

| Object | Installed | Proposed | State |
| --- | --- | --- | --- |
| `kyri_exec_transition.py` | `6488044b…` | `aba0d1f7…` | **REPLACE** |
| `kyri_exec_transition_action.py` | `bd32af5d…` | `201148ea…` | **REPLACE** |
| `kyri_exec_verify.py` | `3d70707d…` | `3d70707d…` | current |
| `/usr/libexec/kyri-exec-transition` | `bd31bcbf…` | `bd31bcbf…` | current |
| `/usr/libexec/kyri-exec-verify` | `fad96924…` | `fad96924…` | current |
| `/usr/libexec/kyri-exec-verify-worker.py` | `5a614ff7…` | `5a614ff7…` | current |
| `/usr/libexec/kyri-exec-worker.py` | `64260190…` | `18d4a6d1…` | **REPLACE** |
| `kyri_exec_podman.py` | absent | `c0e84a89…` | **CREATE** |

The transition **entrypoint** — the only object sudo names — is unchanged, so
the sudoers digest pin does not move (§11).

## 11. Candidates

**Coordinator authority.** Revalidated against current source: 76 bytes,
`3dec888c…2811`, accepted through the real `load_coordinator_authority` with
the ownership facts the ceremony will create, principal `cschott`. Schema
unchanged at three fields. `READY`, not installed; `/etc/kyri` untouched.

**Privileged helper.** The cumulative ceremony is unchanged in content: both
transition modules move from `cfb0edd`-era to HEAD in one step, carrying the
uninstalled `16f285e` change and the coordinator-authority change. Source
coherence is now pinned — the argv builder requires `worker_script` and the
exec site passes it from the policy, so a mixed helper is detectable from the
two halves alone. `READY`, not installed.

**Sudoers.** sudo `1.9.15p5`. The grant pins
`/usr/libexec/kyri-exec-transition` by digest, and that object is **unchanged**
by the helper ceremony — so the rule already binds the final helper entrypoint
rather than a stale one. Five regex-semantics assertions still pass: anchored
so sudoers reads it as a regex, a too-old sudo denies every CINV rather than
admitting a malformed one, the pattern and `validate_cinv` agree over a corpus,
and `noexec` is absent. `READY`, not installed; `/etc/sudoers.d` holds only the
distribution `README`.

`SUDOERS_INSTALL_BLOCKED_PENDING_HELPER_COHERENCE = YES` — and it stays that
way because source tests passing is not an installed helper being coherent.

## 12. What remains, in order

1. **Full isolated invoke E2E** (Phases 9–13). Needs fixture Fabric, Trust,
   CSEL, CINST, coordinator authority, a published handoff, a snapshot root and
   a protocol session. Every piece exists; assembling the harness is the work.
   The backend half is already proven by `g11-ak-backend-e2e.sh`.
2. **Failure matrix through CINV/CRES**, and the mutation-ordering table
   (Phase 16), which needs (1).
3. **Preflight backend readiness** (Phases 14–15), sharing readiness planning
   with the real path.
4. **Generation-13 installer and fixture ceremony** (Phases 21–22), now that
   the closure and the mixed CREATE/REPLACE matrix are known.

Nothing in this list is blocked by a discovery; each is bounded work.

## 13. Validation

| Gate | Result |
| --- | --- |
| `run-validation.sh --quick` | **PASS**, 86/86 |
| `run-validation.sh` (full) | **PASS**, 111/111 |
| worker binding (new) | **PASS**, 11 cases |
| provisioning, authority-gate, authority-resolution | **PASS** after sharpening |
| ShellCheck, pre-commit | clean |
| GitHub workflows | see handoff |

**Four existing assertions moved, and each was sharpened rather than loosened.**
Two forbade tokens the entrypoint now legitimately contains — `create_argv` is
delegation to the library rather than a second copy of it, and an
`environment=` keyword argument is not a read of the process environment — so
both became AST assertions about what the code *does*. Two asserted G6 was
closed, which is the thing this checkpoint changed; they now assert the
properties that string stood for: the entrypoint defines no argv builder or
gate of its own, resolves its library from the one compiled-in root, and takes
exactly the governed argv.

Recurring lesson, now three checkpoints running: every one of these was a text
scan reading a file's own explanation as the thing it forbids. The suites that
strip docstrings before scanning do not have this problem.

## 14. Production non-mutation

No production Podman storage opened; the coordinator remains refused at `0750`.
No container was created by this checkpoint — the binding is proven statically
and the runtime behaviour by the existing G11-AK probe.

Not installed: worker entrypoint, backend, helper, sudoers, coordinator
authority, Generation 13. Not created: CADV, CINST, CROUTE, CSEL, CINV, CRES.
Nothing staged, invoked or renewed. CIMP-000001 unchanged and immutable.

`PRODUCTION_MUTATION = NONE`. `PRODUCTION_INVOKE_AUTHORISED = NO`.

## 15. Next operator gate

Unchanged in shape, with surface 3 inserted:

1. `/etc/kyri/coordinator-identity.json` — must precede the helper, because the
   new `authenticate_launch` depends on it and the old one ignores it.
2. The **full cumulative helper**, atomically across both transition modules.
3. **The worker entrypoint and the backend, together** (§10).
4. Generation 13, once its installer exists.
5. Then the Fabric sequence: CADV, CINST bounded by it, CROUTE-0003,
   CSEL-000002, the narrow sudoers grant, `invoke --preflight`, and the first
   controlled invoke.

No operator action is required by this checkpoint. The next gate is engineering
work, not a ceremony.
