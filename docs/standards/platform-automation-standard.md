# Platform Automation Standard

## Purpose

This standard defines how infrastructure automation is designed, stored, tested, approved, executed, and maintained across the Schott Platform.

The goal is to make platform changes repeatable, reviewable, idempotent, recoverable, and understandable without hiding operational knowledge inside automation.

## Scope

This standard applies to:

- Ansible inventories
- Ansible roles and playbooks
- Host bootstrap automation
- Platform configuration management
- Service deployment automation
- Compliance and validation automation
- Supporting scripts invoked by automation

## Core Principles

1. Manual once, automate forever.
2. Standards and documentation precede automation.
3. Automation targets platform roles wherever practical rather than individual hostnames.
4. Every automation change must be reviewable and repeatable.
5. Idempotency is required for managed configuration.
6. Secrets must remain outside source control.
7. Automation must expose, not conceal, operational behavior.
8. `schai` is the reference implementation for the initial platform automation pattern.

## Documentation-First Workflow

Platform automation follows this sequence:

1. Brainstorm
2. Design or specification
3. Commit documentation
4. Self-review
5. User approval
6. Manual reference implementation
7. Automation implementation
8. Validation
9. Rollout
10. Post-change review

Implementation must not begin before the applicable standard or design has been approved.

## Repository Layout

The canonical automation layout is:

```text
ansible/
├── ansible.cfg
├── requirements.yml
├── inventories/
│   ├── production/
│   │   ├── hosts.yml
│   │   ├── group_vars/
│   │   └── host_vars/
│   ├── development/
│   │   ├── hosts.yml
│   │   ├── group_vars/
│   │   └── host_vars/
│   └── lab/
│       ├── hosts.yml
│       ├── group_vars/
│       └── host_vars/
├── playbooks/
│   ├── bootstrap.yml
│   ├── site.yml
│   ├── validate.yml
│   ├── compliance.yml
│   └── recover.yml
├── roles/
│   ├── common/
│   ├── security/
│   ├── firewall/
│   ├── docker/
│   ├── observability/
│   ├── ai-platform/
│   ├── web-platform/
│   ├── management-platform/
│   ├── monitoring-platform/
│   └── backup-platform/
├── collections/
├── scripts/
└── tests/
```

Directories may be introduced incrementally, but new automation should conform to this structure.

## Inventory Design

Inventories must represent environment, platform role, and host identity separately.

Hosts should be grouped by role, such as:

```yaml
all:
  children:
    ai_platform:
      hosts:
        schai:
    management_platform:
      hosts:
        schmgmt:
    web_platform:
      hosts:
        schweb1:
    backup_platform:
      hosts:
        schpbs:
```

A host may belong to supporting groups such as:

- `linux`
- `docker_hosts`
- `gpu_hosts`
- `tier_0`
- `tier_1`
- `production`
- `development`

Host groups must reflect actual operational characteristics and must not be created only to work around poorly designed roles.

## Environment Separation

Production, development, and lab inventories must remain distinct.

Automation must require an explicit inventory selection.

Commands that could affect production should not silently fall back to a default inventory.

Example:

```bash
ansible-playbook -i inventories/production/hosts.yml playbooks/site.yml
```

## Variable Precedence

Variables should be defined at the broadest correct scope.

Preferred order:

1. Role defaults for safe baseline values
2. Environment group variables
3. Platform-role group variables
4. Capability group variables
5. Host variables for genuine host-specific differences
6. Extra variables only for deliberate runtime overrides

Host variables must not become a dumping ground for configuration that belongs in a role or group.

Role defaults must be safe and non-destructive.

## Role Design

Each role should manage one coherent responsibility.

Examples:

- `common` manages baseline operating-system configuration
- `security` manages host security controls
- `firewall` manages host firewall policy
- `docker` manages Docker Engine and Compose
- `observability` manages collectors and exporters
- `ai-platform` manages AI-host prerequisites and approved AI services

Roles must not become large collections of unrelated tasks.

Each role should contain, where applicable:

```text
roles/<role-name>/
├── defaults/main.yml
├── vars/main.yml
├── tasks/main.yml
├── handlers/main.yml
├── templates/
├── files/
├── meta/main.yml
├── README.md
└── tests/
```

## Role README Requirements

Each role README must document:

- Purpose
- Managed resources
- Supported operating systems
- Required variables
- Optional variables
- Defaults
- Dependencies
- Tags
- Example usage
- Validation commands
- Rollback considerations
- Known limitations

## Idempotency

Managed playbooks and roles must be idempotent.

A second run against an already compliant host should report no unexpected changes.

Tasks must use purpose-built Ansible modules instead of shell commands when practical.

Shell or command tasks must:

- Have a documented reason
- Define change detection with `changed_when` when needed
- Define failure behavior with `failed_when` when needed
- Avoid uncontrolled side effects
- Be safe to re-run or explicitly guarded

## Desired State

Automation declares desired state rather than replaying a sequence of manual keystrokes.

Examples:

- A package is present
- A service is enabled and running
- A directory exists with defined ownership
- A firewall rule permits an approved source
- A configuration file matches an approved template

Automation must not depend on undocumented pre-existing state.

## Bootstrap Boundary

Bootstrap automation prepares a host so that normal configuration management can begin.

The bootstrap process may include:

- Initial automation account creation
- SSH key placement
- Python installation
- Privilege configuration
- Base package installation
- Initial hostname and time configuration

Bootstrap tasks should be isolated from routine configuration because they may require different credentials or access assumptions.

## Secrets Management

Secrets must never be committed to Git in plaintext.

Approved mechanisms may include:

- Ansible Vault
- Environment-provided secrets
- Root-owned files deployed outside the repository
- A future approved secrets-management platform

Vault passwords and decryption keys must not be stored in the repository.

Secret variables should use recognizable names without exposing the value, for example:

```yaml
litellm_api_key: "{{ vault_litellm_api_key }}"
```

Automation output must use `no_log: true` where a task may expose sensitive values.

`no_log` must not be used so broadly that ordinary failures become impossible to diagnose.

## Configuration Files and Templates

Managed configuration files should use templates when values vary by environment, role, or host.

Templates must:

- Include a managed-by notice when supported by the file format
- Avoid embedding secrets when a separate secret file is possible
- Trigger handlers only when content changes
- Preserve ownership and permissions
- Be validated before replacement when the application supports syntax checking

## Handlers

Service restarts and reloads should be implemented through handlers.

Handlers should run only when a relevant change occurs.

A role must prefer reload over restart when reload safely applies the change.

Disruptive handlers must be documented.

## Tags

Tags may support targeted operations, but they must not be required to make a normal playbook safe.

Recommended tags include:

- `common`
- `security`
- `firewall`
- `docker`
- `observability`
- `backup`
- `validate`
- `compliance`

Tags must describe responsibilities rather than individual task numbers or temporary implementation details.

## Playbook Standard

### `bootstrap.yml`

Establishes the minimum state required for normal automation.

### `site.yml`

Applies the full approved desired state for the selected inventory.

### `validate.yml`

Performs non-destructive checks of configuration, health, reachability, and service state.

### `compliance.yml`

Evaluates hosts against platform standards and reports drift.

### `recover.yml`

Supports documented recovery procedures. It must not assume that destructive restoration is safe without operator confirmation.

## Platform-Role Targeting

Playbooks should target platform roles.

Example:

```yaml
- name: Configure AI platform hosts
  hosts: ai_platform
  become: true
  roles:
    - common
    - security
    - firewall
    - docker
    - observability
    - ai-platform
```

Host-specific plays require a documented reason.

## Change Safety

Potentially disruptive playbooks should use controls such as:

- `serial`
- Preflight checks
- Maintenance-state variables
- Explicit confirmation variables
- Backup verification
- Health validation before proceeding
- Post-change validation

Tier 0 changes must be serialized unless a reviewed design proves parallel execution is safe.

## Check Mode and Diff Mode

Roles should support Ansible check mode where practical.

Before an approved production change, operators should use:

```bash
ansible-playbook --check --diff ...
```

Check mode is advisory and does not replace testing because some modules cannot fully predict changes.

Diff output containing secrets must be suppressed.

## Validation

Automation validation should include:

- YAML syntax checks
- `ansible-playbook --syntax-check`
- Linting
- Inventory parsing
- Role dependency validation
- Check-mode testing where supported
- Idempotency testing
- Functional health checks
- Security and exposure checks

The minimum local validation sequence should be documented in the repository.

## Testing Strategy

Automation should be tested in this order:

1. Static validation
2. Development or disposable target
3. Reference host
4. Limited production scope
5. Wider rollout

For initial platform implementation, `schai` is the reference host.

A successful first run is not sufficient. The second run must be reviewed for idempotency.

## Compliance and Drift

Compliance automation should verify standards such as:

- SSH policy
- Firewall policy
- Directory structure
- Docker configuration
- Log rotation
- Required monitoring agents
- Time synchronization
- Backup configuration
- Service health
- Approved exposure

Compliance checks should report drift before automatically correcting high-risk settings unless auto-remediation has been explicitly approved.

## Logging and Auditability

Automation runs must be understandable after execution.

Run output should identify:

- Inventory
- Target hosts
- Playbook
- Commit or version when available
- Changed resources
- Failed resources
- Validation result

Sensitive values must be redacted.

Future centralized automation should preserve execution records in the platform observability system or an approved job runner.

## Failure Handling

Tasks must fail clearly when required conditions are not met.

Automation must not ignore failures merely to complete a playbook.

Use `ignore_errors` only when:

- Failure is expected and non-fatal
- The result is captured
- Follow-up logic handles the outcome
- The reason is documented

Rescue blocks may be used for controlled recovery, cleanup, or evidence collection.

## Rollback

Every disruptive automation change must define rollback considerations.

Rollback may include:

- Restoring a previous template
- Reinstalling a previous package version
- Reverting a Compose image
- Restoring configuration from backup
- Disabling a newly introduced service
- Reverting the Git commit and reapplying the prior desired state

Automation rollback must account for irreversible data or schema changes.

## Dependency Management

External Ansible collections and roles must be declared in `requirements.yml`.

Dependencies should be version constrained.

Unreviewed remote roles must not be executed directly in production.

Vendored or external code must have a known source and license.

## Manual Changes

Manual changes to managed resources create drift.

Emergency manual changes are permitted when necessary to restore service, but they must be:

1. Documented
2. Reflected in the source repository if they remain required
3. Reconciled through automation
4. Reviewed after the incident

Automation must not overwrite an emergency fix before the desired state has been reviewed.

## Operational Commands

The repository should document canonical commands for:

- Inventory validation
- Host reachability
- Syntax validation
- Check mode
- Full deployment
- Role-limited deployment
- Compliance checks
- Service validation

Example:

```bash
ansible-inventory -i inventories/lab/hosts.yml --graph
ansible all -i inventories/lab/hosts.yml -m ping
ansible-playbook -i inventories/lab/hosts.yml playbooks/site.yml --syntax-check
ansible-playbook -i inventories/lab/hosts.yml playbooks/site.yml --check --diff
ansible-playbook -i inventories/lab/hosts.yml playbooks/validate.yml
```

## Initial Implementation Phases

### Phase 1 - Foundation

- `bootstrap`
- `common`
- `security`
- `firewall`
- `docker`
- `observability`

### Phase 2 - Platform Services

- AI Platform
- Monitoring Platform
- Management Platform
- Backup Platform

### Phase 3 - Applications

- Kyri
- Jenn Experience
- StudyForge
- Future managed applications

Each phase must inherit the standards established in the previous phase.

## Exceptions

Exceptions require documentation that includes:

- Requirement
- Risk
- Scope
- Compensating control
- Owner
- Review date

Undocumented local customization is platform drift.

## Compliance Checklist

Platform automation is compliant when:

- Inventories separate environments and platform roles
- Roles have one coherent responsibility
- Secrets are excluded from Git
- Managed tasks are idempotent
- Shell usage is justified and controlled
- Templates validate before disruptive replacement where possible
- Handlers run only when needed
- Validation and compliance playbooks exist
- Check mode is supported where practical
- Second-run idempotency is tested
- Rollback considerations are documented
- Manual emergency changes are reconciled into source control
