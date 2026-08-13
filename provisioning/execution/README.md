# G4 host provisioning — runbook

**This document executes nothing.** Every step below is performed by an operator
at a terminal. Nothing in this repository installs, mounts, or provisions any of
it, and no test may.

Gates: **G4 is what this runbook prepares.** G1, G3, G5, G6, and G7 stay closed
throughout — no sudoers policy, no image build or admission, no transition
invocation, and no capability execution.

---

## G4 execution record — executed and accepted on 2026-08-12

Executed against source checkpoint `34c18a7` on `schai`, in two stages: a
maintenance window for steps 1–4, then host provisioning for steps 5–10. The
procedure below is retained unchanged as the record of what was performed; this
section records the outcome so a later reader does not mistake the runbook's
preconditions for current host state.

**Backing store.** `/data` is `/dev/sdb1`, XFS, UUID
`c5ea4a36-fc61-4978-8d9e-3a83c29f9a00`, mounted `prjquota`. Project quota
accounting **ON** and enforcement **ON**.

**Backing-store identity.** `/etc/kyri/backing-store.json` exists `root:root`
`0444`, populated only from independently observed live facts. Verification
through the normal `verify_backing_store` path reproduced the observed identity
**twice** — once from the repository source, and again from the installed
runtime authority at `/usr/lib/kyri/python`, with the module asserted to have
resolved from that root. The runtime did not and cannot self-enrol.

**Quota enforcement, proven rather than configured.** Default project limits are
32 MiB / 512 inodes. Disposable project `999000` — outside the reserved runtime
range `1_000_001`–`1_999_999`, so it can never collide with a derived per-`CINV`
project — proved byte hard-limit enforcement and inode hard-limit enforcement by
actual filesystem refusal, not by command success. The fixture, its directory,
its project assignment, and its project-specific limits were fully removed and
the removal verified. No real `CINV` was used.

**Installed authority.** `/usr/lib/kyri/python` is the runtime execution
authority: `root:root`, read-only, no symlinks, no `.pyc`, no `__pycache__`.
`/usr/libexec/kyri-exec-transition` and `/usr/libexec/kyri-exec-quota` are
`root:root` `0555`; `/usr/libexec/kyri-exec-worker.py` is `root:root` `0444` and
carries no executable bit. `/usr/libexec/kyri-exec-transition-action` does not
exist and must never be created. No installed path resolves through
`/opt/schott-platform`. None of the three helpers was executed.

**Digests.** SHA-256 commitments for the three helpers and the complete
installed library manifest were captured on the host at
`/root/kyri-g4-library-digests.txt`. **The digest values are deliberately not
transcribed into this repository**, because a digest copied into a tree that can
drift from the installed artefacts is a claim nobody re-checks. The on-host
capture is the evidence; see the re-provisioning item below.

**Gates.** G4 is **closed**. G1, G3, G5, G6, and G7 remain closed:
`/etc/sudoers.d/kyri-exec` is absent, no production image was built or admitted,
and neither the transition nor the worker was invoked.

**Track-B residue.** The `kyri-capability` rootless Podman store is not empty. It
holds pre-existing Track-B test artefacts created roughly 29–30 hours before
G4 — an untagged Alpine image and the containers `trackb-exit0`,
`trackb-exit42`, `trackb-timeout`, `trackb-badcmd`, `trackb-kill`,
`trackb-pids`, and `trackb-pids-v2`. These predate G4 and are **not** evidence
that G5 or G6 opened during it: G5 is closed because no production execution
image was built or admitted, and G6 is closed because the ENG-0005
transition/worker path was never invoked. Physical emptiness of the historical
rootless store is not a G5 or G6 requirement. Removing this residue is **G7**
work and is deferred; it was deliberately not removed in this increment.

Governed by [the first adapter design](../../docs/superpowers/specs/2026-08-11-first-adapter-design.md)
§13, §22, §34 and the
[execution transition boundary](../../docs/superpowers/specs/2026-08-11-execution-transition-boundary.md)
§3.2, §3.3.

---

## 0. Blocking precondition — `/data` is mounted `noquota`

> **Resolved on 2026-08-12.** `/data` now mounts `prjquota` with project quota
> accounting and enforcement ON. The section is kept as written because it
> records why a remount was refused as a fix; read it as history, not as a
> description of the host.

As observed on `schai`:

```
/dev/sdb1 /data xfs rw,noatime,attr2,inode64,logbufs=8,logbsize=32k,noquota
/etc/fstab:18  UUID=<live> /data xfs defaults,noatime 0 2
```

Project quota accounting and enforcement are **off**. Until they are on, G4
cannot complete: installing default project limits onto a `noquota` filesystem
writes limits that enforce nothing and leaves the host *looking* provisioned.

**A remount will not fix it.** XFS quota is a mount-time feature.

```
mount -o remount,prjquota /data      # NOT sufficient — do not accept this
```

Enabling it requires an fstab change plus a full **unmount and mount**, or a
reboot. `/data` carries `capability-runtime`, `capability`, `artifacts`,
`backups`, `datasets`, `exports`, `scratch`, `trackb-test`, and `work`, so this
is a **maintenance window** on the platform's data volume, not an in-place
tweak.

The filesystem itself is capable — `projid32bit=1`, `crc=1`. Only the mount
option is missing.

---

## 1. Pre-maintenance checks

Before touching the mount:

```bash
# What is currently using /data? Nothing may hold it open at unmount.
sudo lsof +f -- /data | head -50
sudo fuser -vm /data

# Platform services that write under /data.
docker ps --format '{{.Names}}'
systemctl list-units --type=service --state=running | grep -Ei 'kyri|ollama|litellm'
```

**Backup prerequisite.** Take a verified backup of `/data/kyri` before the
window and confirm it restores. The mount change itself does not touch data, but
an unmount of a busy volume is the point at which an unrelated problem becomes
visible, and this is the last moment to have a way back.

Record the current state so rollback has a target:

```bash
findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS /data | tee /root/kyri-g4-mount-before.txt
sudo cp -a /etc/fstab /root/fstab.pre-kyri-g4
```

---

## 2. The `/etc/fstab` change

Exactly one option is added. Nothing else on the line changes.

```
# before
UUID=<live-uuid> /data xfs defaults,noatime 0 2

# after
UUID=<live-uuid> /data xfs defaults,noatime,prjquota 0 2
```

`prjquota` enables project quota accounting **and** enforcement. Do not add
`pquota` as well — they are the same control under two names — and do not add
`gquota`.

---

## 3. Clean shutdown, unmount, remount

```bash
# Stop the consumers found in step 1 before unmounting.
sudo systemctl stop <units>
docker compose -f <file> down          # for each compose stack on /data

sudo umount /data
sudo mount /data                        # picks up the new fstab line
```

If `umount` reports the volume busy, resolve the holder rather than forcing it.
A reboot is the supported alternative and is preferable to `umount -l`, which
leaves the old mount alive for existing users and would make the verification in
step 4 report on the wrong thing.

---

## 4. Verify quota accounting and enforcement

```bash
findmnt -no OPTIONS /data | tr ',' '\n' | grep -x prjquota
sudo xfs_quota -x -c 'state -p' /data
```

Required: the mount options contain `prjquota`, and `state -p` reports project
quota **accounting: ON** and **enforcement: ON**. Anything else stops G4 here.

---

## 5. Backing-store identity bootstrap

The runtime verifies every authority root against a provisioned backing-store
identity, and on a fresh host that identity does not exist yet. It is created
**here, from independently observed facts**, and then immediately verified — the
runtime never enrols itself and never adopts a changed filesystem identity.

**5.1 Observe the live filesystem independently.**

```bash
findmnt -no SOURCE,TARGET,FSTYPE /data
sudo blkid -s UUID -o value /dev/sdb1
```

Require: target `/data`, fstype `xfs`, and the source device the platform
expects. Record the UUID; it is the only value that becomes configuration.

**5.2 Write the immutable configuration** — root-owned, mode `0444`, canonical
JSON with exactly the three accepted fields and no others. The shape is
[`backing-store.json.example`](backing-store.json.example); substitute the
observed UUID and nothing else.

```bash
sudo install -o root -g root -m 0444 /dev/null /etc/kyri/backing-store.json
printf '{"filesystem_type":"xfs","filesystem_uuid":"%s","mount_point":"/data"}\n' \
  "<observed-uuid>" | sudo tee /etc/kyri/backing-store.json >/dev/null
sudo chmod 0444 /etc/kyri/backing-store.json
```

`/etc/kyri` must be `root:root` and non-writable by `cschott` or
`kyri-capability`.

**5.3 Read the installed configuration back** and run the normal verification
path against `/data` — the same `verify_backing_store` the runtime uses, not a
special provisioning shortcut.

**5.4 Refuse to continue** if verification does not reproduce the identity
observed in 5.1. A mismatch means the configuration and the filesystem disagree,
and every root descriptor derived afterwards would be anchored to a claim
nobody checked.

Only after 5.4 passes may step 6 run.

---

## 6. Default project quota limits

```bash
sudo xfs_quota -x -c 'limit -p -d bhard=32m ihard=512' /data
sudo xfs_quota -x -c 'report -p' /data | head
```

These are the **defaults** every per-`CINV` project inherits, which is what
keeps `quotactl` out of the runtime path: the transition only assigns a project
ID, and the filesystem already knows what a project may have.

Do not install these before step 4 has proven enforcement is on.

---

## 7. Canonical runtime roots

From design §13. Create with these owners and modes exactly; none of them
inherits a mode by convention.

| Path | Owner | Mode |
|---|---|---|
| `/data/kyri/capability-runtime/` | `cschott:cschott` | `0700` |
| `…/staging/` | `cschott:cschott` | `0700` |
| `…/execution/` | `cschott:cschott` | `0700` |
| `…/execution/admin-records/` | `cschott:cschott` | `0700` |
| `…/execution/inspection-audit/` | `cschott:cschott` | `0700` |
| `…/execution/cadm-counter` | `cschott:cschott` | `0600` |
| `…/quarantine/` | `cschott:cschott` | `0700` |
| `/data/kyri/capability-handoff/` | `cschott:cschott` | `0711` |

`0711` on the handoff parent is deliberate: the worker must traverse to a named
child without being able to enumerate the directory.

These additional directories under `…/execution/` are required by the
implementation and carry the same `0700 cschott:cschott`: `mutations/`,
`state/`, `transitions/`, `locks/`, `quarantine-reservations/`,
`quarantine-releases/`. The `cmut-counter` file is `0600` alongside
`cadm-counter`.

Both counters are **provisioned, never bootstrapped at runtime**. Initialise
`cmut-counter` with twelve ASCII digits and a newline, and `cadm-counter` with
six:

```bash
printf '000000000000\n' | sudo -u cschott tee …/execution/cmut-counter >/dev/null
printf '000000\n'       | sudo -u cschott tee …/execution/cadm-counter >/dev/null
```

---

## 8. Install the runtime library and the helpers — without executing them

**The repository checkout is source material, not production execution
authority.** `/opt/schott-platform` is owned by `cschott`; the worker runs as
`kyri-capability`, which holds rootless Podman authority `cschott` must never
have. Production execution must therefore never import from the checkout — an
import from a coordinator-writable tree would hand the coordinator arbitrary
execution as the execution identity. The operator installs **root-owned copies**
and those copies are the runtime authority.

### 8.1 The canonical installed library root

```
/usr/lib/kyri/python
```

Compiled into both entrypoints and configurable nowhere. Neither entrypoint
takes a library root, module name, interpreter, or action name from argv, the
environment, the working directory, package data, or the protocol, and neither
adds an inherited `PYTHONPATH`. Each refuses when the expected module is not
present under this root, **before** attempting any import, so a search can never
fall through to another tree and run its module-level code.

### 8.2 Canonical source → installed path

| Repository source (canonical) | Installed path | Owner | Mode |
|---|---|---|---|
| `provisioning/execution/kyri-exec-transition-entrypoint.py` | `/usr/libexec/kyri-exec-transition` | `root:root` | `0555` |
| `provisioning/execution/kyri-exec-transition.py` | `/usr/lib/kyri/python/kyri_exec_transition.py` | `root:root` | `0444` |
| `provisioning/execution/kyri-exec-transition-action.py` | `/usr/lib/kyri/python/kyri_exec_transition_action.py` | `root:root` | `0444` |
| `provisioning/execution/kyri-exec-worker.py` | `/usr/libexec/kyri-exec-worker.py` | `root:root` | `0444` |
| `tools/__init__.py` | `/usr/lib/kyri/python/tools/__init__.py` | `root:root` | `0444` |
| `tools/capability/execution/*.py` | `/usr/lib/kyri/python/tools/capability/execution/*.py` | `root:root` | `0444` |
| `tools/capability/*.py`, `tools/common/*.py` | `/usr/lib/kyri/python/tools/...` (same relative layout) | `root:root` | `0444` |
| `provisioning/execution/kyri-exec-quota.py` | `/usr/libexec/kyri-exec-quota` | `root:root` | `0555` |
| `provisioning/execution/kyri-exec-quota.py` | `/usr/lib/kyri/python/kyri_exec_quota.py` | `root:root` | `0444` |

`tools/__init__.py` is in the matrix for a security reason, not a packaging
one. Without it `tools` installs as a *namespace* package, and a namespace
portion does not terminate the import search — so a regular `tools` package
found later on `sys.path` wins even though both entrypoints insert the
canonical root at position 0, and its module-level code runs before the
post-import `realpath` check can refuse. Installing it makes the canonical root
a regular package, so the first match is the only match. Omitting it from a
future re-provisioning would silently reopen the gap.

The quota source has **two destinations and one implementation**: the standalone
executable specified earlier, and the internal module the transition imports.
They are copies of the same canonical file — not a fork, and not a second
implementation. No artifact in this table is a divergent duplicate of another.

The transition's **action is an internal library component**, never a second
privileged executable. There is no `/usr/libexec/kyri-exec-transition-action`,
and there must never be one: the public privileged interface is exactly

```
/usr/libexec/kyri-exec-transition CINV-nnnnnn
```

### 8.3 Directory and file modes

| Object | Owner | Mode |
|---|---|---|
| `/usr/lib/kyri` and every directory beneath it | `root:root` | `0755` |
| every installed Python source file beneath `/usr/lib/kyri/python` | `root:root` | `0444` |
| `/usr/libexec/kyri-exec-transition` | `root:root` | `0555` |
| `/usr/libexec/kyri-exec-quota` | `root:root` | `0555` |
| `/usr/libexec/kyri-exec-worker.py` | `root:root` | `0444` |

The worker is `0444` and carries no executable bit, because it is never directly
executed: the transition names the interpreter explicitly and passes the script
to it, which keeps the shebang line out of the trust chain.

```
execve("/usr/bin/python3",
       ("/usr/bin/python3", "/usr/libexec/kyri-exec-worker.py",
        "CINV-nnnnnn", "CIMP-nnnnnn", "<64 lowercase hex profile_digest>"),
       CLOSED_ENVIRONMENT)
```

The `CIMP` and the profile digest come from the launch record the transition
authenticated, and the governed profile itself crosses as a sealed anonymous
object on **descriptor 3** — so the inherited set is `(0, 1, 2, 3)`. Neither
value and no descriptor number is supplied by the caller.

**Do not generate or ship `.pyc` artifacts.** Installed sources are read-only and
the container environment sets `PYTHONDONTWRITEBYTECODE=1`; a writable
`__pycache__` beside a root-owned module would be the one mutable thing in the
tree. Copy `.py` files only, and never a `__pycache__` directory.

```bash
sudo install -d -o root -g root -m 0755 /usr/lib/kyri /usr/lib/kyri/python
# ... mirror the tools/ tree with directories 0755 and files 0444,
#     excluding every __pycache__ directory and every .pyc file.
sudo find /usr/lib/kyri -type d -exec chmod 0755 {} +
sudo find /usr/lib/kyri -type f -exec chmod 0444 {} +
sudo chown -R root:root /usr/lib/kyri
```

**Do not invoke any of them.** Installation is G4; execution is G6.

## 9. Verify what was installed

```bash
for p in /usr/libexec/kyri-exec-transition \
         /usr/libexec/kyri-exec-worker.py \
         /usr/libexec/kyri-exec-quota; do
  stat -c '%n %U:%G %a' "$p"
  sha256sum "$p"
done

# Ancestry: no component writable by anyone but root.
namei -l /usr/libexec/kyri-exec-transition
```

Record every digest with the provisioning evidence. `/usr/libexec/kyri-exec-worker.py`
must read `root:root 444`, and the other two `root:root 555`.

**Digest-capture the installed library too**, not only the three helpers — the
installed copies are the runtime authority, so they are what evidence must
describe:

```bash
sudo find /usr/lib/kyri/python -type f -name '*.py' -print0 \
  | sort -z | xargs -0 sha256sum | sudo tee /root/kyri-g4-library-digests.txt

# No .pyc anywhere, and nothing writable by anyone but root.
sudo find /usr/lib/kyri -name '__pycache__' -o -name '*.pyc' | grep . && echo "FAIL: bytecode present"
sudo find /usr/lib/kyri ! -user root -o ! -group root | grep . && echo "FAIL: wrong owner"
sudo find /usr/lib/kyri -perm /022 | grep . && echo "FAIL: group or world writable"
```

**Verify ancestry all the way to each installed file.** Every component of every
installed path must be `root:root` and non-writable by `cschott`,
`kyri-capability`, or any unprivileged user or group:

```bash
namei -l /usr/libexec/kyri-exec-transition
namei -l /usr/libexec/kyri-exec-worker.py
namei -l /usr/libexec/kyri-exec-quota
namei -l /usr/lib/kyri/python/tools/capability/execution/worker.py
```

A single writable component voids the grant, and a digest cannot repair it.

---

## 10. Prove enforcement, on a disposable fixture

Configuration is not evidence. Prove an over-limit write actually fails,
without touching a real `CINV` or opening G6. Project **999000** is outside the
reserved runtime range (`1_000_001`–`1_999_999`), so it can never collide with a
derived per-`CINV` project.

```bash
sudo mkdir -p /data/kyri-quota-fixture
sudo xfs_quota -x -c 'project -s -p /data/kyri-quota-fixture 999000' /data
sudo xfs_quota -x -c 'limit -p bhard=1m ihard=4 999000' /data

# Expected: this FAILS with a disk-quota error well before 8 MiB.
sudo dd if=/dev/zero of=/data/kyri-quota-fixture/blob bs=1M count=8; echo "exit=$?"

# Expected: this FAILS once four inodes exist.
sudo sh -c 'for i in 1 2 3 4 5 6; do touch /data/kyri-quota-fixture/f$i; done'

sudo xfs_quota -x -c 'report -p' /data | grep 999000
```

A byte limit that does not refuse, or an inode limit that does not refuse,
**fails G4**. Do not proceed on a configured-but-unenforced filesystem.

**Fixture cleanup — mandatory:**

```bash
sudo rm -rf /data/kyri-quota-fixture
sudo xfs_quota -x -c 'limit -p bhard=0 ihard=0 999000' /data
sudo xfs_quota -x -c 'report -p' /data | grep 999000 || echo "fixture project cleared"
```

---

## 11. Rollback

| Step reached | Rollback |
|---|---|
| fstab edited, not yet remounted | restore `/root/fstab.pre-kyri-g4` |
| remounted with `prjquota` | restore fstab, unmount, mount; `/data` returns to `noquota` and nothing else changes |
| default limits installed | `xfs_quota -x -c 'limit -p -d bhard=0 ihard=0' /data` |
| runtime roots created | remove only the directories this runbook created, and only while they are empty |
| helpers installed | `rm` the three installed paths; nothing references them until G3 grants sudoers |
| fixture left behind | step 10 cleanup |

The backing-store configuration may be removed while no runtime state depends on
it. Once invocations exist, **replacing it is not a rollback** — a changed
filesystem identity is a fail-closed condition by design, not something to
edit back into agreement.

---

## 12. What must remain untouched

Confirm at the end of the window:

- **No sudoers policy.** `/etc/sudoers.d/kyri-exec` does not exist. The example
  in `sudoers.d/` is text, and installing it is G3.
- **No image build, and no image admission.** `podman images` shows no admitted
  execution image; no `CIMP` was minted and no authority set was written. Image
  admission is G5.
- **No transition invoked, no container started, no capability executed.** G6.
- **No Track-B evidence promoted**, and no merge, tag, or release. G7.

---

## Decisions that blocked G4 — all resolved

1. **`/data` maintenance window** — steps 2–4. Executed 2026-08-12; `/data`
   mounts `prjquota` with accounting and enforcement ON.
2. **Worker library location and ownership** — step 8. Ruled: the canonical
   installed root `/usr/lib/kyri/python` is compiled into both entrypoints and
   is configurable nowhere. The checkout is source material only.
3. **Installed helper form** — ruled by the §8.2 matrix: one privileged public
   entrypoint, with the policy and action installed as internal library
   modules rather than as a second privileged command.

## Follow-up items — recorded here, not actioned

Neither item invalidates G4. Both need source review in a later increment and
neither authorises a host change on its own.

**1. Installed dependency closure is wider than the import closure.** The §8.2
matrix installs all of `tools/capability/*.py`, which includes
`fabric_evidence.py`; that module imports `tools.fabric.inspection`, and
`tools/fabric/` is not in the matrix. The installed module therefore cannot be
imported. This is a package-hygiene and dependency-closure defect in the
source→destination matrix, not a runtime authority defect: the accepted
worker and transition execution closure never reaches the module, and it is
installed `root:root` `0444` like everything else, so it grants nothing. The
fix belongs in a review of the matrix — either narrow it to the real closure or
extend it to cover `tools/fabric/` — and must not be applied by widening the
installed tree without that review.

> **Re-evaluated after `tools/__init__.py` was added.** The failure mode changed
> and the severity dropped. While `tools` was a namespace package this was not
> a failure at all: with the checkout anywhere on `sys.path`, `tools.__path__`
> resolved to `/opt/schott-platform/tools` and the module loaded from the
> coordinator-writable tree. Now that the installed root is a regular package,
> `tools.__path__` is pinned to `/usr/lib/kyri/python/tools` and the same import
> is a clean `ModuleNotFoundError: No module named 'tools.fabric'` —
> fail-closed, and confined to the uninstalled subpackage. The worker closure
> (`worker`, `types`, `package_contract`) resolves entirely from the canonical
> root and is unaffected. The module stays outside the sanctioned execution
> closure, so this remains a packaging-hygiene follow-up and **`tools/fabric` is
> deliberately not installed.**

**2. `tools` installed as a namespace package, so a regular `tools` package
elsewhere on the path won.** Found while validating after G4, and confirmed
directly. **Corrected in source; the installed tree carries the fix only after
the re-provisioning described below.** At the time of G4 neither the repository
nor the §8.2 matrix carried `tools/__init__.py`,
so `/usr/lib/kyri/python/tools` was a *namespace* portion. A namespace portion
does not terminate the import search, so a **regular** package named `tools`
found later on `sys.path` takes precedence over the installed one — even though
both entrypoints insert `/usr/lib/kyri/python` at position 0. Demonstrated: with
a decoy `tools/` package on `PYTHONPATH`, the decoy's `worker.py` module-level
code executed and `tools.capability.execution.worker` resolved to the decoy.

The post-import `realpath` check in both entrypoints does then refuse — but
only *after* the foreign module-level code has run, which is precisely the
sequence the entrypoints' own pre-import existence check exists to prevent.

**Not reachable through the sanctioned path**, which is why this did not
invalidate G4: the transition execs the worker with a closed environment that
carries no `PYTHONPATH`, and the installed tree is root-owned and read-only.

A second measurement made the severity clearer. With the checkout on
`sys.path` at all, the namespace `tools.__path__` resolved to
`/opt/schott-platform/tools` outright — so it was not only a decoy on
`PYTHONPATH` that could win, but the coordinator-writable checkout itself.

**Corrected by `tools/__init__.py`**, now in the repository and in the §8.2
matrix, which makes the canonical root a regular package so the first match is
the only match. Both the pre-import existence check and the post-import
`realpath` check are unchanged — this closes the window between them. The
alternative, resolving by explicit file path, was not taken: it was not needed
once the regular-package property held. **The installed tree does not carry the
fix until it is re-provisioned; do not patch it in place.**

**3. The validation suite encoded "G4 has not been executed" as an invariant.**
**Corrected.** Five suites — `helper-policy`, `lifecycle`, `provisioning`,
`quota`, and `transition-action` — proved they had not provisioned anything by
asserting that production paths do **not exist**. The intent was sound but the
assertion conflated *"this suite did not create it"* with *"it does not
exist"*, and only the first is a property of a test. Each now snapshots
`(mode, uid, gid, size, mtime_ns, ctime_ns)` for the paths it must not touch
before the first case, and compares after the last — so a write, a `chmod`, or
a `chown` all fail the check, on a clean host and a provisioned one alike. This
matches the validator's own long-standing production-path backstop.

Gate state is treated differently from provisioned state: `/etc/sudoers.d/kyri-exec`
and `/run/kyri` must be absent on *every* host until G3 opens, so those keep an
absolute absence assertion rather than a snapshot comparison.

The import-boundary cases were rebuilt the same way. They previously ran the
worker against the real `/usr/lib/kyri/python`, which meant that on a clean host
they passed because nothing was installed to redirect — the property was never
actually exercised. They now build a canonical root from the install matrix in
a temporary directory and run the real resolution logic against it, so the
property is tested on every host and CI included.

## Implementation-authority namespace — ruled, NOT YET PROVISIONED

**Nothing below exists on the host, and this runbook does not create it.**
Provisioning it is part of G5 and has not been authorised. The contracts are
recorded here so the eventual ceremony has one authoritative source; the model
itself is in [design §5.1–§5.7](../../docs/superpowers/specs/2026-08-11-first-adapter-design.md).

Published authority — the coordinator reads it, nothing else touches it:

| Path | Owner | Mode |
|---|---|---|
| `/var/lib/kyri` | `root:root` | `0711` (already exists, unchanged) |
| `/var/lib/kyri/implementation-authority` | `root:cschott` | `0750` |
| `…/implementations/`, `…/generations/`, `…/generations/<CGEN>/` | `root:cschott` | `0750` |
| `…/current-generation` | `root:cschott` | `0440` |
| admission, retirement, `authority-set`, `generation` records | `root:cschott` | `0440` |

Operator-only control state, deliberately **outside** the published namespace so
that coordinator-invisibility is structural rather than incidental:

| Path | Owner | Mode |
|---|---|---|
| `/var/lib/kyri/implementation-authority-control` | `root:root` | `0700` |
| `…/cimp-counter`, `…/cgen-counter` | `root:root` | `0600` |
| `…/implementation-lifecycle` (lock) | `root:root` | `0600` |
| `…/staging/` | `root:root` | `0700` |

`0750` on the authority directories is required rather than generous: the reader
enumerates `implementations/`, which needs the read bit and not merely traverse.
The coordinator needs no access to the control namespace, and
`kyri-capability` needs none to either. Every ancestor is root-owned and
non-writable by `cschott` and `kyri-capability`, so neither can rename, replace,
or shadow the namespace — which is why this lives under `/var/lib/kyri` and not
beneath the coordinator-owned `/data/kyri/capability-runtime/execution`.

The lock is named `implementation-lifecycle` to match existing convention —
`capacity`, `quarantine-capacity`, `cadm-counter`, `cmut-counter` are all
unprefixed and lowercase. It is acquired only by offline root tooling and never
by a runtime reader, so it needs no ordering against the coordinator's
`capacity` and `quarantine-capacity` locks; the two sets are never held by the
same process, and keeping them in separate roots means no cross-root
acquisition can arise.

Records are create-once and immutable. `current-generation` is the single
exception and is **not** an immutable record: it is a regular canonical-JSON
file, never a symlink, replaced only by durable atomic rename.

**Publication renames staged material into the published namespace**, so the
control root and the authority root must sit on **one filesystem** — which they
do beneath `/var/lib/kyri`. This is the same assumption the per-invocation
handoff makes beneath `/data`.

**The bootstrap primitives are operator tooling and are not installed.**
`tools/provisioning/authority_bootstrap.py` implements the counters, the
`implementation-lifecycle` lock, and the genesis ceremony, and it is
deliberately outside the §8.2 install matrix — which covers `tools/__init__.py`,
`tools/capability/**`, and `tools/common/*` only. It must never be added: the
coordinator reads published authority and never writes it, and keeping the
writer out of `/usr/lib/kyri/python` makes that a property of the host rather
than a rule. It carries no absolute path, so the operator supplies both roots
as open descriptors when the eventual provisioning ceremony runs.

**Generation 3 — installed and accepted 2026-08-12**, from the `oci_image_id`
correction. The execution-authority field was renamed from `oci_digest` and its
syntax corrected to bare `^[0-9a-f]{64}$`, and the observation path was moved
from Podman's `.ImageDigest` to `.Image`. Seven installed objects differed from
source and were reinstalled **together**, because the profile canonical form,
the `VERIFIED_PROFILE` message, and the launch authorisation record all commit
the same field and a partial install would leave them disagreeing:

| Repository source | Installed path |
|---|---|
| `tools/capability/execution/implementation_authority.py` | `/usr/lib/kyri/python/tools/capability/execution/implementation_authority.py` |
| `tools/capability/execution/lifecycle.py` | `…/tools/capability/execution/lifecycle.py` |
| `tools/capability/execution/profile.py` | `…/tools/capability/execution/profile.py` |
| `tools/capability/execution/protocol.py` | `…/tools/capability/execution/protocol.py` |
| `tools/capability/execution/types.py` | `…/tools/capability/execution/types.py` |
| `tools/capability/execution/worker.py` | `…/tools/capability/execution/worker.py` |
| `provisioning/execution/kyri-exec-transition.py` | `/usr/lib/kyri/python/kyri_exec_transition.py` |

All installed `root:root 0444` at the reviewed digests. The three
`/usr/libexec` entrypoints were byte-identical and were **not** reinstalled;
the remaining 38 matrix artefacts were unchanged.

Verified after installation: the import boundary still holds, the installed
tree carries the bare-64-hex `oci_image_id` contract and the `.Image`
observation mapping, no bytecode is present, project quota accounting and
enforcement remain ON, and `/etc/kyri/backing-store.json` is unchanged at
`root:root 0444`. The generation-3 library manifest holds **42** Python files
with manifest digest
`93adb7a760b7f438db344c155fd8607f15a95588d09547c54689bf45f4cc5b38`; evidence is
at `/root/kyri-gen3-library-digests.txt` and `/root/kyri-gen3-helper-digests.txt`,
with the G4 and G4c evidence preserved separately. `/etc/sudoers.d/kyri-exec`
and `/var/lib/kyri/implementation-authority` remain absent and no CIMP/CGEN
state exists, so **generation 3 changes no gate**.

The Podman inventory probe emitted `cannot chdir to /opt/schott-platform:
Permission denied` because `runuser` inherited the coordinator checkout as its
working directory. That is informational — `kyri-capability` legitimately
cannot traverse the coordinator's tree, which is the authority split working —
and it did not affect the installation or its verification. Run that probe from
a directory the execution identity can traverse, such as `/tmp`.

**Generation 4 — installed and accepted 2026-08-13**, from Passes 2A, 2C, and
3A. **Three** installed objects differed from source — two changed and one new;
Passes 2B and 2D added no runtime file:

| Repository source | Installed path | SHA-256 |
|---|---|---|
| `tools/capability/execution/implementation_authority.py` | `…/tools/capability/execution/implementation_authority.py` | `ddd5b9134d5f4e0906ebfdb4cabd61a7d63639fd8c55a20523e872055c6234e4` |
| `tools/capability/execution/payload.py` | `…/tools/capability/execution/payload.py` | `cde8f95b307d4f45bf0e79efca54cf3fa2ec0f6d043282f2ebe4310e6b67d4bb` |
| `tools/capability/execution/authorisation.py` **(new)** | `…/tools/capability/execution/authorisation.py` | `191bb7b8e1553e96c27d8a29cedd5be1d30d2fdb55777fa53cf50581d58f799c` |

All `root:root 0444`. The other 43 matrix artefacts are byte-identical and the
three `/usr/libexec` entrypoints are unchanged.

**Nothing from Passes 2B, 2C, or 2D is installed, and none of it may be.** Pass
3A's `authorisation.py` is runtime and *is* installed; the whole
`tools/provisioning/` package — bootstrap, evidence, admission, and
disposition — is offline
operator tooling and sits outside the matrix by design. Installing it would put
identifier allocation and authority publication inside the runtime library the
coordinator imports from.

Accepted evidence: 43 installed runtime library files, manifest digest
`179449810b1da3ac7bf55107c1723f5030ca29958ea8b94b04b7c40ec1b29c4c`, recorded at
`/root/kyri-gen4-library-digests.txt` and `/root/kyri-gen4-helper-digests.txt`
with all prior G4, G4c, and generation-3 evidence intact. The import boundary,
the reader's three states, the two pending subtypes, the authorisation seam, and
the bare-hex `oci_image_id` contract were each verified in the installed tree;
`tools/provisioning` is absent from it, as it must remain.

**Generation 5 is required and is not installed.** Both passes are now
implemented in source, and they install **together as one generation** — the
coordinator publisher and the privilege-boundary change must agree about what
authorises execution, and a host carrying one without the other has a
coordinator publishing bytes nothing authenticates, or a helper authenticating
bytes nobody published. Generation 5 changes the launch-record schema, the root
helper, the inherited-descriptor set (`0,1,2,3`), and the worker exec tuple
(five elements). Ruled in design §14.1.

**The exact generation-5 delta versus accepted generation 4 is seven installed
objects.** No file is added or removed, so the library manifest stays at 43
Python files and the three `/usr/libexec` entrypoints keep their paths, owners,
and modes:

| Repository source | Installed path | Pass |
|---|---|---|
| `tools/capability/execution/handoff.py` | `…/tools/capability/execution/handoff.py` | 3B-i |
| `tools/capability/execution/profile.py` | `…/tools/capability/execution/profile.py` | 3B-ii |
| `tools/capability/execution/worker.py` | `…/tools/capability/execution/worker.py` | 3B-ii |
| `provisioning/execution/kyri-exec-transition.py` | `/usr/lib/kyri/python/kyri_exec_transition.py` | 3B-ii |
| `provisioning/execution/kyri-exec-transition-action.py` | `/usr/lib/kyri/python/kyri_exec_transition_action.py` | 3B-ii |
| `provisioning/execution/kyri-exec-transition-entrypoint.py` | `/usr/libexec/kyri-exec-transition` | 3B-ii |
| `provisioning/execution/kyri-exec-worker.py` | `/usr/libexec/kyri-exec-worker.py` | 3B-ii |

All seven are **privilege-boundary objects and must be installed as one
generation.** They are three sides of one agreement: the coordinator publishes
canonical profile bytes, root authenticates and seals them, and the worker
consumes the sealed copy against a digest root took from the launch record.
A partial install breaks it in a way nothing detects at install time — an old
worker receives a five-element argv it refuses, an old helper builds a
three-element one the new worker refuses, and an old policy module reads a
record schema the coordinator no longer writes.

**Everything else in the pass is source-only or operator-only and installs
nowhere**: the test suites, `tools/dev/run-validation.sh`, the CI workflow, the
design and plan documents, and this runbook. `tools/provisioning/` remains
outside the matrix, as it must.

#### Deployment semantics — transactional, crash-recoverable, not atomic

**The seven objects do not become visible together, and no installer should
claim they do.** Linux provides atomic replacement of *one* pathname —
`rename(2)` within a filesystem — and no primitive that publishes seven
independent pathnames as a unit. During the replacement window some targets are
generation 5 while others are still generation 4. True all-or-nothing
visibility would need a different runtime layout: a versioned generation
directory plus a single atomic pointer swap, with both entrypoints resolving
through the pointer. That is a change to a privilege boundary rather than to an
installer, and it is not authorised here.

What is achievable on this layout, and what the generation-5 installer must
therefore implement, is **transactional crash-recoverable installation**:

| Phase | Guarantee |
|---|---|
| PREPARE | each new object is staged beside its target on the target's own filesystem with final bytes and mode, fsynced; the current generation-4 object is retained the same way, so rollback has material rather than intentions |
| JOURNAL | a durable root-only record of intent, both pinned digests per target, and per-target progress, fsynced before every irreversible step |
| COMMIT | one `rename(2)` per target — atomic *per pathname* — each followed by a directory fsync and an immediate bytes/owner/mode verification |
| ROLLBACK | any commit-phase failure restores every already-replaced target from its retained copy and re-verifies the complete generation-4 set |
| RECOVER | a rerun inspects **actual bytes**, classifies each target `GEN4`/`GEN5`/`UNKNOWN`, and drives the host to one complete generation; `UNKNOWN` fails closed for operator disposition |

Recovery completes **forward** to generation 5 when every remaining target's
prepared object verifies against its pinned digest, and rolls **back** to
generation 4 otherwise. It never guesses, and a rollback is reported as a
rollback — a complete, verified generation 4 — rather than as a failed
generation 5.

**No mixed set is ever accepted as a generation.** Evidence is written only
after all seven installed objects verify by digest, owner, and mode, the
unchanged runtime surface still matches the generation-4 evidence, no eighth
delta exists, the import boundary holds, and the gates are unchanged.

**Why the commit window is operationally safe at this gate:** there is no live
caller able to enter the privilege boundary. `/etc/sudoers.d/kyri-exec` does not
exist, so the coordinator cannot invoke the helper at all; no systemd unit,
timer, or cron entry references any `kyri-exec` path. That makes sequential
pathname visibility acceptable *here* — it does not make it atomic, and it
stops being an argument the moment G3 opens.

#### The installer, and the ceremony for using it

The transactional installer is `provisioning/execution/install-generation-5.sh`
in this repository. It is **operator tooling, not runtime authority**: it is
mode `0644`, is never executed directly, installs neither itself nor its test
suite, and appears nowhere in the install matrix above. Nothing under
`/usr/lib/kyri/python` or `/usr/libexec` is or becomes a copy of it — a host
that carried the installer inside the runtime library would have put the thing
that replaces the privilege boundary inside the privilege boundary.

Its failure-injection suite is `tests/test-capability-execution-generation5-installer.sh`,
which runs in local validation and CI against throwaway fixture trees only.

The ceremony is seven steps, and steps 3 and 5 are where an operator decides
rather than a script:

```
1.  read the script                sed -n '1,60p' provisioning/execution/install-generation-5.sh
2.  read-only preflight            sudo bash provisioning/execution/install-generation-5.sh --verify
3.  INSPECT THE OUTPUT             confirm: generation-4 baseline verified, seven
                                   source digests match, no transaction in progress,
                                   gates closed. Stop here if anything reads wrong.
4.  install                        sudo bash provisioning/execution/install-generation-5.sh --install
5.  INSPECT THE RESULT             confirm COMMIT completed, or that a rollback
                                   restored a complete generation 4. A rollback is a
                                   correct outcome, not a partial state to repair by hand.
6.  read-only confirmation         sudo bash provisioning/execution/install-generation-5.sh --verify-installed
7.  capture evidence               record /root/kyri-gen5-library-digests.txt and
                                   /root/kyri-gen5-helper-digests.txt with the prior
                                   G4/G4c evidence, which stays untouched
```

**Do not chain step 4 to step 2.** `--verify` succeeding means the host is a
valid generation-4 baseline and the transaction is ready; it does not mean the
change has been reviewed. If a run is interrupted, rerun `--install` (or
`--recover`): it will inspect actual bytes, never start a fresh transaction over
unknown state, and drive the host to one complete generation or stop for
disposition.

#### Carried forward to G6, unresolved

Two questions the sealed-transport ruling deliberately does not answer, both
recorded so they are not lost:

- **Governed profile and security controls.** The worker verifies the profile's
  *identity* — digest, `CINV`, `CIMP` — but not that its *values* are the
  governed ones. `create_argv` will consume `network`, `pids_limit`, `cpus`,
  `hostname`, `tmpfs_options`, and `oci_image_id` from coordinator-authored
  bytes. Nothing consumes them today, because `create_argv` has no caller.
  **Requires a ruling before G6.**
- **Payload and package replacement exposure.** Unchanged by this pass and
  still replaceable through the same directory-ownership route.

Two earlier handoff models were accepted and then disproved empirically — a
root-owned path freeze and descriptor anchoring to the coordinator's inode.
Both are recorded in §14.1 with their disproofs. The accepted model has root
authenticate the coordinator's bytes and copy them into a sealed `memfd`, so
the published profile file stops being authority the moment the copy verifies.
`payload` and `package/` are unaffected and their mutation exposure remains an
open hardening follow-up.

Both disproofs are now regression tests rather than prose. A retained writable
descriptor is used to rewrite, shorten, and then replace the published profile
*after* root authenticated it, and the worker still reads the original bytes
and digest; and the `dup2(3, 3)` trap is demonstrated across a real
`fork`/`execve`, where the governed placement arrives sealed and intact while a
control arm relying on `dup2` alone leaves `FD_CLOEXEC` set and the child finds
`EBADF`. Neither is provable by inspection, which is why neither is asserted by
inspection.

**4. Repository source and installed runtime may legitimately drift.** The
installed tree is the authority for the active deployment generation, and its
digests — not the checkout — describe what runs. A later commit to
`provisioning/execution/` or `tools/capability/` does **not** change the
installed artefacts, and nothing should make it. Replacing the installed tree is
an explicit, reviewed re-provisioning event that re-runs this runbook and
re-captures digests. **No automatic synchronisation between the checkout and
`/usr/lib/kyri/python` is authorised**, and a drift check that silently
reinstalls would defeat the authority split the installed tree exists to create.
