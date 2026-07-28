# Linux Server Security Standard

## Purpose

This standard defines the minimum security baseline for Linux servers managed as part of the Schott Platform. It is designed to be implemented first on `schai`, validated there, and then automated through Ansible for broader rollout.

## Scope

This standard applies to supported Linux servers that are:

- Managed by the Schott Platform
- Reachable on the homelab network
- Intended to run infrastructure, platform, or application workloads

## Operating System

- Use a supported Ubuntu LTS release unless an approved exception is documented.
- Configure the timezone as `America/Chicago`.
- Apply security updates regularly.
- Remove or disable unused packages and services when practical.

## Administrative Access

- SSH administrative access is allowed only from the Management Network: `192.168.86.2-99`.
- SSH must use public-key authentication.
- Password authentication must be disabled after key access and console recovery are verified.
- Keyboard-interactive authentication must be disabled.
- Direct root SSH login must be disabled.
- Administrative access must use named user accounts.
- Any `AllowUsers` or `AllowGroups` restriction must be documented and tested before enforcement.

## SSH Configuration Requirements

The effective SSH configuration must include:

```text
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
```

Before reloading SSH:

1. Back up the current configuration.
2. Confirm a working administrative public key.
3. Keep a second authenticated session open.
4. Confirm console or hypervisor recovery access.
5. Run `sshd -t` and require exit code 0.

## Host Firewall

- A host firewall must be enabled.
- Default inbound behavior must be deny unless a documented service requires access.
- Administrative services must be restricted to the Management Network.
- Application services must be limited to their approved source ranges.
- Rules must be documented and empirically tested.

## Docker Hosts

- Docker-published ports must not be considered protected by UFW alone.
- Required restrictions must be enforced in the appropriate Docker packet-filtering path, including `DOCKER-USER` where applicable.
- Container egress and established traffic must not be broken by ingress controls.
- Private backend services must not be published to remote interfaces.
- Runtime reachability must be tested from a remote client.

## Service Exposure

Services must be classified according to the Service Exposure Standard:

- Administrative
- Application
- Private

Each exposed port must have:

- A documented owner
- A documented purpose
- An approved source range
- A validation method
- A rollback method

## Accounts and Privilege

- Use least privilege.
- Avoid shared administrative accounts.
- Use `sudo` for privileged actions.
- Do not store private keys, passwords, tokens, or live credentials in Git.
- Disable stale accounts when they are no longer required.

## Logging and Auditability

- Retain system and authentication logs according to available platform capacity.
- Security-relevant configuration changes must be committed to the repository when they are represented as code or documentation.
- Manual runtime changes must be recorded in release acceptance documentation until automated.

## Backups and Recovery

Before a security change:

- Back up the affected configuration.
- Document the rollback command or restoration path.
- Verify console or equivalent out-of-band recovery access for changes that could interrupt SSH or networking.

## Automation

- A configuration is not considered reusable until encoded in Ansible.
- Ansible roles must be idempotent.
- Defaults must be conservative and must not contain live secrets.
- Compliance checks should be read-only wherever possible.
- The reference host must pass manual validation before the automation is applied to additional systems.

## Compliance

A server is compliant with this standard when:

- It uses the approved operating system and timezone.
- SSH is key-only and root login is disabled.
- Administrative access is restricted to `192.168.86.2-99`.
- Required firewall controls are active.
- Docker-published services are restricted correctly.
- Private services are not remotely reachable.
- Recovery and rollback procedures are documented.
- The configuration is represented in Ansible or has a documented temporary exception.

## Exceptions

Exceptions must include:

- The affected host or service
- The requirement being waived
- The reason
- The risk
- The compensating control
- The owner
- The review or expiration date
