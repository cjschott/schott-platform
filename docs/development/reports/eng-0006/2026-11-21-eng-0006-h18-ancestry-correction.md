# ENG-0006-H18 — Correction: post-install ancestry verification

**Status:** corrected and tested on schmain. **Not deployed, not merged.**
schai was not contacted. This report supersedes the H18 report's review
record (installer `a1df520`) for every ceremony from now on.
**Host / account:** `schmain` / `kyri-dev`. **Branch:** `arch/eng-0006-health-runtime`.
**Baseline:** `9641469` (H18).

**Review record values for the ceremony.** Keep these off the production host,
and check them against this report as published, not against a checkout on
schai:

| Value | |
|---|---|
| runtime commit (pinned inside the installer, unchanged) | `5131dfcff560295d5d2c83d411255c0310de9911` |
| installer commit (`REVIEWED`) | `c79da5b24af842485cb02c285d894416c66435d5` |
| installer SHA-256 (`EXPECTED`) | `27f00b8d85ab40e8529d057a80c1a92b68a2b038163b91dad8fe58adcdfecb7a` |
| superseded installer | `a1df5200d4eefb9e5bde6e7e130144bc35c51312`, SHA-256 `85a12d07ed63361a939dbf747e95318e2ae11e5a669beb22b5fd8ecaefb9a41b` |

## 1. What happened on schai

The operator ran the `a1df520` ceremony at repository HEAD `9641469`.
`--install` did the following, in order:

1. created `kyri-health` (996:986, locked, nologin);
2. created the approval and store roots;
3. installed the library, the three helpers and the units;
4. enabled the timer.

It then halted in its own final `verify_installed` step. A later
`--verify-installed` failed the same way:

```
FAIL     /var/lib/kyri/health is not owned by uid 0      (seven times)
```

## 2. Root cause

`check_ancestry()` holds every existing ancestor of a checked path to root's
uid. `state_report()` runs that check on each state directory. Seven of those
directories are children of the store: the six record directories and
`sequences`. Each of the seven therefore reached `/var/lib/kyri/health` as an
ancestor. That directory is, correctly, `kyri-health`'s, so each check failed.

The defect had nothing to do with permissions. It came from a check that does
not know who should own which directory.

The suite missed it for the reason recorded in H18 §7 L-k. In fixture mode,
the fixture account takes the invoking user's uid, the same uid that stands
for root. A check that confused the two owners could not fail there.

## 3. The correction

`provisioning/health/install-health-runtime.sh`, `check_ancestry()` only:

- **Owner of each ancestor.** The rule now names the ruled owner of each
  ancestor. That is the service identity for `/var/lib/kyri/health` and
  anything under it, and root for everything else.
- **Prefix match.** The store test is the exact path or the path followed by a
  slash. `/var/lib/kyri/health-approvals` is therefore still held to root.
- **No account.** If a store ancestor exists but the account does not, the
  check fails.
- **Unchanged checks.** The real-directory, no-symlink and
  writable-by-no-one-else checks apply as before.

Nothing else changed: the ownership model, the 19 pinned digests and the
pinned runtime commit are all as before.

This is not a bypass. Each ancestor is checked against exactly one uid, and
`check_dir` still holds every store directory to `kyri-health:kyri-health 0700`.

## 4. Tests

`tests/test-health-install.sh` gains a section in which root and the service
identity are distinct owners. The suite went from 172 to 223 assertions.

It runs the ceremony with an exported `stat` override that does two things:

- reports the store with the production ids `996:986`;
- reports any listed path with the ids the case gives it.

Modes, links, file types and symlinks remain real.

**Reproduction with the shipped installer.** The `a1df520` blob is first
checked against its SHA-256. Then, on a fixture whose account is exactly
`996:986`, locked and nologin:

- `--install` installs everything, then fails with exactly seven identical
  `/var/lib/kyri/health is not owned by uid N` lines and no other failure.
- `--verify-installed` then fails the same way.

**The corrected installer, on that partial installation:**

| Mode | Result |
|---|---|
| `--verify` | READY, 6/6 runtime objects present |
| `--verify-installed` | VERIFIED |
| `--install` | DONE, with the fixture byte-for-byte unchanged |
| `--uninstall` | ROLLED BACK; account, store and approvals kept |
| `--install` again | DONE, then VERIFIED |

**Rollback with the shipped installer.** `a1df520 --uninstall` rolls back the
same partial state. The corrected installer then installs and verifies.

**Fresh host.** `--verify`, `--install` and `--verify-installed` on a fresh
fixture: READY, DONE, VERIFIED.

**Fail-closed cases.** 16 cases; for each, `--verify-installed` fails and
`--verify` refuses with no change:

- **Store ownership:**
  - a store child, or the store root, owned by root;
  - a store child, or the store root, owned by a third account;
  - a root-owned request lock;
  - a store that exists after its account was removed.
- **Store permissions:**
  - a group-readable store child (0750);
  - a group-writable store root (0770).
- **Store symlinks:**
  - a symlinked store child;
  - a symlinked store root.
- **Root-owned paths with the service identity as owner:**
  - `/var/lib/kyri`;
  - the approval root;
  - approval `.staging`;
  - `/usr/lib/kyri`;
  - the library;
  - a helper.

**Mutation of the correction.** Five mutants were run:

| Mutant | Result |
|---|---|
| accept the service uid anywhere | killed, 4 failures |
| store prefix without the slash, which would capture `health-approvals` | killed, 10 failures |
| always expect root (the shipped defect) | killed, 14 failures |
| skip store ancestors entirely | killed, 6 failures |
| drop the explicit no-account branch | survived |

The surviving mutant is equivalent: with no account the owner is empty, the
uid comparison still fails, and only the message differs.

**Validation.** `tools/dev/run-validation.sh` passed on schmain: 178/178 steps in full mode and 153/153 in quick mode, with ShellCheck 0.9.0 on `PATH`. The changed files are ShellCheck-clean. The test's `stat` override carries one `disable=SC2317` directive, because it is reached only through `export -f`.

## 5. Effect on the other modes

| Mode | Effect |
|---|---|
| `--verify`, `--install` preflight | the same `state_report`, so it is fixed in the same way. On a fresh host nothing changes, because no store ancestor exists before creation |
| `--install` over existing state | idempotent; tested over the partial installation |
| interrupted install | residue handling is untouched (runtime paths only), and the existing residue cases still pass |
| `--uninstall` | does not call `state_report`, so neither installer's rollback was affected by the defect |
| `--verify-installed` | fixed. It needs no repository |

## 6. Recovery of the existing partial installation on schai (not executed)

The installed runtime is already the reviewed `5131dfc` bytes. The corrected
installer pins the same commit and the same 19 digests, so it verifies the
installation in place. **No uninstall or reinstall is needed.**

The `a1df520` copy in `/root/kyri-health-install/` is left untouched. The new
installer goes into its own directory.

From a session on schai that you have checked hosts no agent
(`ps -u "$(id -un)" -o pid,comm`):

```bash
REVIEWED=<installer commit from this report, as published>
EXPECTED=<installer sha256 from this report, as published>

git -C /opt/schott-platform fetch
git -C /opt/schott-platform checkout arch/eng-0006-health-runtime
git -C /opt/schott-platform merge --ff-only
git -C /opt/schott-platform merge-base --is-ancestor "${REVIEWED}" HEAD && echo ok

sudo install -d -o root -g root -m 0700 "/root/kyri-health-install/${REVIEWED}"
git -C /opt/schott-platform cat-file blob "${REVIEWED}:provisioning/health/install-health-runtime.sh" \
  | sudo tee "/root/kyri-health-install/${REVIEWED}/install-health-runtime.sh" >/dev/null
sudo sha256sum "/root/kyri-health-install/${REVIEWED}/install-health-runtime.sh"    # == EXPECTED, or stop

sudo bash "/root/kyri-health-install/${REVIEWED}/install-health-runtime.sh" --verify            # READY, 6/6 present
sudo bash "/root/kyri-health-install/${REVIEWED}/install-health-runtime.sh" --verify-installed  # VERIFIED
```

Then run the acceptance block in `provisioning/health/README.md`, using this
path in place of `/root/kyri-health-install/install-health-runtime.sh`.

| `--verify` result | What to do |
|---|---|
| READY | continue with `--verify-installed` |
| any other result | **stop**. Nothing has been changed. Record the FAIL lines and do not repair by hand |

To take the runtime back, either installer's `--uninstall` works on this
state. It removes the runtime and keeps `kyri-health`, the store and the
approvals. The corrected installer's `--install` then reinstalls.

## REVIEW PACKAGE

```
Task:                   ENG-0006-H18 correction: post-install ancestry verification held
                        the service-owned store to root's uid
Files Changed:          provisioning/health/install-health-runtime.sh (check_ancestry);
                        tests/test-health-install.sh (distinct-owner section);
                        this report; H18 report (review record superseded)
Tests Executed:         §4
Commands Run:           test-health-install.sh; 5 mutants; shellcheck 0.9.0;
                        tools/dev/run-validation.sh (quick and full)
Known Risks:            distinct ownership is simulated by an exported stat override, not by
                        real chown (no privilege on schmain); the root-only production steps
                        were exercised only by the real schai run, where everything other than the seven store failures passed (identity, sudo, NSS and systemd checks)
Architecture Decisions: ownership model unchanged; the ancestor owner is the ruled owner of
                        that path, not a bypass
Questions for Reviewer: none
```
