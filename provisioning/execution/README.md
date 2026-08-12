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

## 8. Install the helpers — without executing them

| Repository source | Installed path | Owner | Mode |
|---|---|---|---|
| `kyri-exec-transition.py` + `kyri-exec-transition-action.py` | `/usr/libexec/kyri-exec-transition` | `root:root` | `0555` |
| `kyri-exec-worker.py` | `/usr/libexec/kyri-exec-worker.py` | `root:root` | `0444` |
| `kyri-exec-quota.py` | `/usr/libexec/kyri-exec-quota` | `root:root` | `0555` |

`/usr/libexec` is already `root:root` on this host. Every writable ancestor of
each installed path must be `root:root` and non-writable by `cschott`,
`kyri-capability`, or any unprivileged user or group.

**The worker is `0444` and carries no executable bit**, because it is never
directly executed: the transition names the interpreter explicitly and passes
the script to it, which removes the shebang line from the trust chain.

```
execve("/usr/bin/python3",
       ("/usr/bin/python3", "/usr/libexec/kyri-exec-worker.py", "CINV-nnnnnn"),
       CLOSED_ENVIRONMENT)
```

**Do not invoke any of them.** Installation is G4; execution is G6.

**Open question before this step can be completed:** the installed worker
imports `tools.capability.execution.worker`, and the worker environment carries
no `PYTHONPATH` by design. Where that library lives on the host — and, more
importantly, **who owns it** — is not yet fixed by the accepted design. It must
not be the `cschott`-owned repository checkout: the worker runs as
`kyri-capability`, which holds rootless Podman authority that `cschott` must
never have, so importing coordinator-writable code would hand `cschott`
arbitrary execution as `kyri-capability` and break the §3 authority split. See
"Remaining decisions" below.

---

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
