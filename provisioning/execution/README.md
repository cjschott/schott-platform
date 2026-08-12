# G4 host provisioning — runbook

**This document executes nothing.** Every step below is performed by an operator
at a terminal. Nothing in this repository installs, mounts, or provisions any of
it, and no test may.

Gates: **G4 is what this runbook prepares.** G1, G3, G5, G6, and G7 stay closed
throughout — no sudoers policy, no image build or admission, no transition
invocation, and no capability execution.

Governed by [the first adapter design](../../docs/superpowers/specs/2026-08-11-first-adapter-design.md)
§13, §22, §34 and the
[execution transition boundary](../../docs/superpowers/specs/2026-08-11-execution-transition-boundary.md)
§3.2, §3.3.

---

## 0. Blocking precondition — `/data` is mounted `noquota`

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
| `tools/capability/execution/*.py` | `/usr/lib/kyri/python/tools/capability/execution/*.py` | `root:root` | `0444` |
| `tools/capability/*.py`, `tools/common/*.py` | `/usr/lib/kyri/python/tools/...` (same relative layout) | `root:root` | `0444` |
| `provisioning/execution/kyri-exec-quota.py` | `/usr/libexec/kyri-exec-quota` | `root:root` | `0555` |
| `provisioning/execution/kyri-exec-quota.py` | `/usr/lib/kyri/python/kyri_exec_quota.py` | `root:root` | `0444` |

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
       ("/usr/bin/python3", "/usr/libexec/kyri-exec-worker.py", "CINV-nnnnnn"),
       CLOSED_ENVIRONMENT)
```

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

## Remaining decisions before G4 can be executed

1. **`/data` maintenance window** — steps 2–4. The blocking item.
2. **Worker library location and ownership** — step 8. Needs a ruling: the
   installed worker must import governed code from a root-owned tree, not from
   the coordinator-writable checkout.
3. **Installed helper form** — `kyri-exec-transition.py` and its action module
   are two files in the repository and one installed path; how they are combined
   is a G2 packaging decision that this runbook records but does not choose.
