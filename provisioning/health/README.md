# Health runtime — operator runbook (ENG-0006-H18)

This directory holds the Health runtime as it is installed on the production
host, plus the ceremony that installs it. **Nothing here has been run against
production.** Everything below is the procedure for doing that.

| File | Installed as | Runs as |
|---|---|---|
| `install-health-runtime.sh` | not installed; copied to `/root/kyri-health-install/` and checked against its reviewed digest | root, once per ceremony |
| `kyri-health-approve.py` | `/usr/libexec/kyri-health-approve` `root:root 0555` | root, through the operator's own password `sudo` |
| `kyri-health-ingest.py` | `/usr/libexec/kyri-health-ingest` `root:root 0555` | `kyri-health` (`sudo -u kyri-health`) |
| `kyri-health-verify.py` | `/usr/libexec/kyri-health-verify` `root:root 0555` | `kyri-health`, from the timer or by hand |
| `kyri-health-verify.service`, `.timer` | `/etc/systemd/system/` `root:root 0644` | systemd |
| `draft-health-approval.py` | not installed | the operator, unprivileged, from the checkout |
| `tools/health`, `tools/common` (the closure of `tools.health.operator`) | `/usr/lib/kyri/health/tools/...` `root:root 0444`, directories `0755` | imported by the helpers only |

The ceremony also creates:

| Path or principal | Shape |
|---|---|
| `kyri-health` | system user with its own group and no other group (no `sudo`, `docker`, `lxd` or `adm`), shell `/usr/sbin/nologin`, home `/nonexistent`, password locked, named in no sudoers rule |
| `/var/lib/kyri/health-approvals` | `root:root 0755`; statements `root:root 0444`, one link each |
| `/var/lib/kyri/health-approvals/.staging` | `root:root 0700` |
| `/var/lib/kyri/health` | `kyri-health:kyri-health 0700`, laid out as the Health store (six record directories and `sequences/`, all `0700`; `sequences/request_identity.lock` `0600`) |

It writes **no sudoers rule**. Approval uses the operator's general password
`sudo`; ingestion uses `sudo -u kyri-health`.

## What is enforced, and what is procedure

| Property | How |
|---|---|
| Only root can create an approval | the approval directory is `root:root 0755`, and ingestion opens statements through `trusted_source` with trusted UID 0, refusing any other owner, any second link and any group- or world-writable file |
| `kyri-health` cannot create or change an approval | it is not root and has no group with a path to root |
| The approved bytes are the reviewed bytes | the operator computes `sha256sum` with coreutils; the approve helper refuses any other digest |
| Someone at a terminal saw the statement | the approve helper renders it on `/dev/tty`, ASCII-escaped, and requires the digest's first 12 hex digits to be typed there. It refuses without a controlling terminal, and when stdin is a terminal |
| Only `kyri-health` writes the store | the store is `kyri-health 0700`; the ingest and verify helpers refuse any other effective UID or GID and any supplementary group |
| No privileged helper runs agent-writable code | each helper is `python3 -IB`, and before importing anything it checks that `/usr/lib/kyri/health`, every ancestor of it and everything in it is root-owned and writable by no one else, with no symlink anywhere. It then imports only from there and checks where each module came from |
| Only reviewed bytes are installed | the ceremony reads every payload as a git blob of the pinned commit, as the repository owner, and installs nothing whose SHA-256 is not pinned in it |
| `verify` changes nothing | it takes no lock and writes nothing, and the unit runs it on a read-only file system with no network, no capabilities and no access to the Fabric or Trust stores |
| **Procedure only:** the person at the terminal is the operator | it is a password and a terminal, not identity authentication and not a signature |
| **Procedure only:** no agent shares the session | check with `ps -u "$(id -un)" -o pid,comm` before every ceremony |
| **Not prevented:** root, or `cschott` through Docker, rewriting anything | detection only, by `verify` and `--verify-installed`, and only against a non-root forger |

## Before the ceremony

1. Log in on `schai` in a session that hosts no agent, and check that it
   doesn't: `ps -u "$(id -un)" -o pid,comm`.
2. Bring `/opt/schott-platform` to a revision that contains the reviewed
   installer commit, on `arch/eng-0006-health-runtime`:
   `git -C /opt/schott-platform fetch` and `git -C /opt/schott-platform checkout arch/eng-0006-health-runtime`, then `git -C /opt/schott-platform merge --ff-only`.
3. Ensure the system interpreter can import PyYAML in isolated mode:
   `/usr/bin/python3 -I -c 'import yaml'`. If it cannot, run
   `sudo apt-get install python3-yaml`.
4. Take from the H18 review record, which is kept off this host:
   `REVIEWED`, the installer commit (40 hex), and `EXPECTED`, the SHA-256 of
   `provisioning/health/install-health-runtime.sh` at that commit.

## Installation

```bash
REVIEWED=<installer commit from the review record>
EXPECTED=<installer sha256 from the review record>

sudo install -d -o root -g root -m 0700 /root/kyri-health-install
git -C /opt/schott-platform cat-file blob "${REVIEWED}:provisioning/health/install-health-runtime.sh" \
  | sudo tee /root/kyri-health-install/install-health-runtime.sh >/dev/null
sudo sha256sum /root/kyri-health-install/install-health-runtime.sh   # must print ${EXPECTED}; otherwise stop

sudo bash /root/kyri-health-install/install-health-runtime.sh --verify             # READY
sudo bash /root/kyri-health-install/install-health-runtime.sh --install            # DONE
sudo bash /root/kyri-health-install/install-health-runtime.sh --verify-installed   # VERIFIED
```

`git` runs as you, the repository owner, and only the verified copy runs as
root. `--install` is idempotent: it creates what is absent, accepts what is
exactly right, and refuses (changing nothing) when anything that exists is
not as ruled. It enables and starts `kyri-health-verify.timer`.

## Acceptance

Every command is read-only except the explicit one-off verify run. Record the
output in the next report.

```bash
sudo bash /root/kyri-health-install/install-health-runtime.sh --verify-installed   # VERIFIED

getent passwd kyri-health          # ...:/nonexistent:/usr/sbin/nologin
id kyri-health                     # groups=<gid>(kyri-health) and nothing else
sudo passwd -S kyri-health         # second field L
sudo -l -U kyri-health             # "is not allowed to run sudo"

namei -l /var/lib/kyri/health-approvals/.staging /var/lib/kyri/health/sequences \
         /usr/lib/kyri/health/tools/health/operator.py /usr/libexec/kyri-health-approve

# kyri-health cannot create an approval; cschott cannot read the store
sudo -u kyri-health touch /var/lib/kyri/health-approvals/probe     # Permission denied
ls /var/lib/kyri/health                                            # Permission denied
# nobody but root can change the installed runtime
test -w /usr/lib/kyri/health/tools/health/ingest.py && echo WRONG || echo ok

sudo -u kyri-health /usr/libexec/kyri-health-verify; echo "exit $?"   # {"status": "clean", ...} exit 0

systemctl list-timers kyri-health-verify.timer
sudo systemctl start kyri-health-verify.service
systemctl status kyri-health-verify.service --no-pager   # inactive (dead), status=0/SUCCESS
journalctl -u kyri-health-verify -n 5 --no-pager
systemd-analyze security kyri-health-verify.service      # informational
```

## Approving and ingesting an envelope

```bash
# 1. Draft (unprivileged; the output is not the review)
python3 /opt/schott-platform/provisioning/health/draft-health-approval.py \
  --envelope envelope.json --request-id REQ-0001 --operation initial \
  --actor <name> --approving-authority <name> \
  --approved-at 2026-11-20T09:00:00-06:00 > candidate.json

# 2. Review the exact bytes with root-owned tools only, and take the digest yourself
python3 -I -m json.tool < candidate.json
sha256sum candidate.json

# 3. Publish: refused unless the digest matches and you type its first 12 hex digits
sudo /usr/libexec/kyri-health-approve REQ-0001 <sha256> < candidate.json

# 4. Ingest as the service identity, then verify
sudo -u kyri-health /usr/libexec/kyri-health-ingest REQ-0001
sudo -u kyri-health /usr/libexec/kyri-health-verify
```

A replacement is the same, with `--operation replacement`, and an envelope
whose `supersedes` names the subject's current head and whose
`envelope_version` is the head's plus one.

**Exit codes:**

- approve: 0 published (or already published, byte-identical), 1 refused, 2 the helper refused.
- ingest: 0 accepted or replayed, 1 refused, 2 the helper or the store refused, 3 committed-unverified.
- verify: 0 clean, 1 findings, 2 refused.

Every helper prints one JSON line and logs one line to the journal.

A subject that `verify` reports as frozen has no recovery in this release
(ruling O-5). It needs an operator ruling.

## Rollback

```bash
sudo bash /root/kyri-health-install/install-health-runtime.sh --uninstall   # ROLLED BACK
```

It removes the runtime: it stops and disables the timer, removes the units,
the three helpers and the library, and clears interrupted-ceremony residue. It
first checks that every installed object is byte-for-byte the reviewed one,
and if any is not it removes nothing.

It **keeps** `kyri-health`, `/var/lib/kyri/health` and
`/var/lib/kyri/health-approvals`. They are the identity and the evidence, and
removing them is not part of any ceremony. Running `--install` again
reinstalls the runtime over them unchanged.

**A later release** ships its own installer, pinned to its own commit. Because
`--install` never replaces a differing object, an upgrade runs this
installer's `--uninstall`, then the new installer's `--install`.

## Not done here

- No sudoers rule: no `NOPASSWD` for ingestion, and no `timestamp_timeout=0`
  for the approve helper. Each needs its own ruling.
- No recovery for frozen subjects.
- No CHSTATE, collector, daemon or alerting beyond a failed unit.
