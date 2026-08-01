# Network Hardening v0.2.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `schai` the reference implementation for the Kyri Infrastructure Security Standard, then capture the proven configuration as reusable Ansible automation.

**Architecture:** `schai` is hardened and validated first as the golden host. Administrative access is restricted to the exact management range `192.168.86.2-99`, LiteLLM remains available to `192.168.86.0/24`, and Ollama remains private to Docker networking. Once runtime behavior is verified, the settings are encoded in focused Ansible roles for controlled rollout to other servers.

**Tech Stack:** Ubuntu, OpenSSH, UFW, iptables/DOCKER-USER, Docker Compose, Bash validation, Ansible, GitHub Actions.

## Global Constraints

- SSH source range is exactly `192.168.86.2-99`; do not widen it to `/25`.
- LiteLLM remains reachable from `192.168.86.0/24` on `4000/tcp`.
- Ollama remains private to Docker and must not be remotely reachable on `11434/tcp`.
- SSH must be key-only after key and console recovery access are verified.
- Root SSH login is disabled.
- `schai` is the first implementation; other servers are changed later through Ansible.
- Firewall changes must preserve the active SSH session and include a tested rollback.
- No secrets, private keys, or live credentials are committed.
- Server examples use timezone `America/Chicago`.

---

## File Structure

- `docs/architecture/network-architecture.md`: logical zones, trust boundaries, and future VLAN mapping.
- `docs/standards/linux-server-security-standard.md`: reusable Linux and SSH baseline.
- `docs/standards/service-exposure-standard.md`: administrative, internal, and private service classifications.
- `docs/decisions/0001-sch-ai-reference-host.md`: ADR for using `schai` as the golden host.
- `docs/security/network-policy.md`: executable operator policy for `schai`.
- `docs/runbooks/schai-network-hardening.md`: ordered deployment, verification, and rollback procedure.
- `ansible/roles/kyri_security/`: reusable SSH and firewall role created only after the manual reference implementation passes.
- `ansible/playbooks/compliance.yml`: read-only compliance checks for managed hosts.
- `tests/test-static.sh`: repository assertions for required documents and automation files.
- `docs/releases/v0.2.0-acceptance.md`: signed-off runtime results and known limitations.

### Task 1: Architecture and Standards Documentation

**Files:**
- Create: `docs/architecture/network-architecture.md`
- Create: `docs/standards/linux-server-security-standard.md`
- Create: `docs/standards/service-exposure-standard.md`
- Create: `docs/decisions/0001-sch-ai-reference-host.md`
- Modify: `docs/security/network-policy.md`

**Interfaces:**
- Consumes: approved management and application ranges from the design discussion.
- Produces: canonical terms used by the runbook, tests, and later Ansible variables.

- [ ] **Step 1: Add failing static assertions**

Add `assert_file` and `assert_contains` checks to `tests/test-static.sh` for the four new documents and the exact ranges.

- [ ] **Step 2: Run the static test and verify failure**

Run: `bash tests/test-static.sh`

Expected: FAIL for missing architecture, standard, and ADR files.

- [ ] **Step 3: Create the architecture and standards documents**

Document the exact ranges, service classes, future VLAN abstraction, key-only SSH, disabled root login, and `schai` reference-host decision.

- [ ] **Step 4: Update the current network policy**

Change SSH from `192.168.86.0/24` to the exact `192.168.86.2-99` range using valid CIDR fragments. Keep LiteLLM at `192.168.86.0/24` and Ollama private.

- [ ] **Step 5: Run static tests**

Run: `bash tests/test-static.sh`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add docs tests/test-static.sh
git commit -m "docs: define network hardening architecture"
```

### Task 2: schai Hardening Runbook

**Files:**
- Create: `docs/runbooks/schai-network-hardening.md`
- Modify: `tests/test-static.sh`

**Interfaces:**
- Consumes: architecture and standards from Task 1.
- Produces: exact operator commands and rollback steps for the live host.

- [ ] **Step 1: Add failing runbook assertions**

Require the runbook to contain preflight, key verification, console recovery, firewall staging, DOCKER-USER verification, rollback, and acceptance sections.

- [ ] **Step 2: Verify the test fails**

Run: `bash tests/test-static.sh`

Expected: FAIL because the runbook does not exist.

- [ ] **Step 3: Write the runbook**

Include commands to back up SSH and firewall configuration, validate authorized keys, keep a second session open, test `sshd -t`, stage exact UFW rules, verify Docker-published ports empirically, and revert from console.

- [ ] **Step 4: Run static tests**

Run: `bash tests/test-static.sh`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add docs/runbooks/schai-network-hardening.md tests/test-static.sh
git commit -m "docs: add schai hardening runbook"
```

### Task 3: Live schai SSH Hardening

**Files:**
- Runtime: `/etc/ssh/sshd_config.d/90-kyri-security.conf`
- Runtime backup: `/root/kyri-backups/<timestamp>/ssh/`
- Record: `docs/releases/v0.2.0-acceptance.md`

**Interfaces:**
- Consumes: Task 2 runbook.
- Produces: verified key-only SSH baseline on `schai`.

- [ ] **Step 1: Record pre-change state**

Run `sshd -T`, `ufw status numbered`, `iptables -S DOCKER-USER`, `docker ps`, and the platform health check. Save sanitized output outside Git if it contains host-specific data.

- [ ] **Step 2: Verify recovery access**

Confirm an administrative public key works in a second SSH session and confirm Proxmox console access before changing authentication.

- [ ] **Step 3: Install the SSH drop-in**

Set `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin no`, `PubkeyAuthentication yes`, and an approved `AllowUsers` entry.

- [ ] **Step 4: Validate configuration**

Run: `sudo sshd -t`

Expected: no output and exit code 0.

- [ ] **Step 5: Reload SSH and test**

Reload the SSH service, open a new key-authenticated session, and verify password authentication is rejected.

- [ ] **Step 6: Record acceptance result**

Add date, operator, tests, and rollback status to `docs/releases/v0.2.0-acceptance.md`.

### Task 4: Live schai Firewall and Docker Enforcement

**Files:**
- Runtime: UFW rules
- Runtime: persistent DOCKER-USER rules managed using the distribution-supported persistence mechanism
- Record: `docs/releases/v0.2.0-acceptance.md`

**Interfaces:**
- Consumes: Task 3 working SSH access.
- Produces: packet-level enforcement for SSH and Docker-published LiteLLM.

- [ ] **Step 1: Stage exact management CIDRs**

Represent `192.168.86.2-99` with exact CIDR fragments and add all SSH allow rules before deleting the old `/24` rule.

- [ ] **Step 2: Preserve LiteLLM LAN access**

Allow `192.168.86.0/24` to `4000/tcp`.

- [ ] **Step 3: Enforce Docker ingress**

Add DOCKER-USER rules that accept established traffic, allow the LAN to the LiteLLM published port, and reject other ingress to that published port without breaking container egress.

- [ ] **Step 4: Verify from multiple sources**

Confirm SSH succeeds from a management address, LiteLLM succeeds from an approved LAN address, Ollama fails remotely, and unauthorized source simulation or routed test fails where available.

- [ ] **Step 5: Reboot and verify persistence**

Reboot during an approved window, then repeat SSH, LiteLLM, Ollama, Docker health, UFW, and DOCKER-USER checks.

- [ ] **Step 6: Record acceptance result**

Update `docs/releases/v0.2.0-acceptance.md` with observed results and any limitations.

### Task 5: Encode the Proven Baseline in Ansible

**Files:**
- Create: `ansible/ansible.cfg`
- Create: `ansible/inventories/homelab/hosts.yml`
- Create: `ansible/group_vars/all.yml`
- Create: `ansible/roles/kyri_security/defaults/main.yml`
- Create: `ansible/roles/kyri_security/tasks/main.yml`
- Create: `ansible/roles/kyri_security/handlers/main.yml`
- Create: `ansible/roles/kyri_security/templates/90-kyri-security.conf.j2`
- Create: `ansible/roles/kyri_security/templates/kyri-docker-user.rules.j2`
- Create: `ansible/roles/kyri_security/tasks/compliance.yml`
- Create: `ansible/playbooks/security.yml`
- Create: `ansible/playbooks/compliance.yml`
- Modify: `tests/test-static.sh`

**Interfaces:**
- Consumes: exact live configuration proven by Tasks 3 and 4.
- Produces: idempotent `kyri_security` role and read-only compliance playbook.

- [ ] **Step 1: Add failing static assertions**

Require all Ansible files and exact default variables for management CIDRs, LiteLLM subnet, SSH settings, and timezone.

- [ ] **Step 2: Verify test failure**

Run: `bash tests/test-static.sh`

Expected: FAIL for missing Ansible files.

- [ ] **Step 3: Implement the role**

Template the SSH drop-in and firewall policy, validate SSH before reload, provide handlers, and keep defaults conservative. Do not include live keys or passwords.

- [ ] **Step 4: Implement compliance mode**

Use read-only commands and Ansible assertions to report whether SSH, firewall, Docker isolation, and required services match the standard.

- [ ] **Step 5: Run local validation**

Run:

```bash
bash tests/test-static.sh
ansible-playbook --syntax-check -i ansible/inventories/homelab/hosts.yml ansible/playbooks/security.yml
ansible-playbook --syntax-check -i ansible/inventories/homelab/hosts.yml ansible/playbooks/compliance.yml
```

Expected: PASS.

- [ ] **Step 6: Check idempotence on schai**

Run the security playbook twice with `--check --diff` first, then approved live mode. The second live run must report no unexpected changes.

- [ ] **Step 7: Commit**

```bash
git add ansible tests/test-static.sh
git commit -m "feat: automate Kyri security baseline"
```

### Task 6: Release Acceptance

**Files:**
- Create or finalize: `docs/releases/v0.2.0-acceptance.md`
- Modify: `CHANGELOG.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: all previous task results.
- Produces: release evidence and rollout gate for additional servers.

- [ ] **Step 1: Complete acceptance checklist**

Record SSH key-only behavior, source restrictions, LiteLLM access, Ollama isolation, Docker health, persistence after reboot, Ansible syntax, and idempotence.

- [ ] **Step 2: Run complete repository validation**

Run all local checks documented in `docs/development/local-validation.md`.

Expected: PASS.

- [ ] **Step 3: Update release documentation**

Add v0.2.0 scope and note that rollout to other servers is performed later through Ansible.

- [ ] **Step 4: Commit**

```bash
git add README.md CHANGELOG.md docs/releases/v0.2.0-acceptance.md
git commit -m "test: record network hardening acceptance"
```

- [ ] **Step 5: Create pull request**

Open a PR from the implementation branch to `main`, require CI success, and review runtime evidence before merge.
