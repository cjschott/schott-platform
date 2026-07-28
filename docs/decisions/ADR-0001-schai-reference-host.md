# ADR-0001: schai as the Reference Host

- **Status:** Accepted
- **Date:** 2026-07-28
- **Decision Makers:** Schott Platform Engineering

## Context

The Schott Platform is intended to be operated as a product rather than a collection of individually managed servers. To ensure consistency, reduce operational risk, and enable repeatable automation, infrastructure changes require a single authoritative implementation target.

Historically, ad hoc configuration changes across multiple systems increase configuration drift, complicate troubleshooting, and make automation more difficult.

## Decision

The host **schai** is designated as the Reference (Golden) Host for the Schott Platform.

All platform-level changes will follow this lifecycle:

1. Design and document the proposed change.
2. Implement the change manually on schai.
3. Validate functionality, security, and operational behavior.
4. Update standards, runbooks, and architecture documentation.
5. Convert the validated implementation into reusable Ansible automation.
6. Roll out the automated change to additional systems.

No platform-wide deployment should occur before successful validation on schai unless an emergency change process explicitly requires otherwise.

## Rationale

Using a single reference host provides:

- A known-good implementation for troubleshooting.
- Reduced configuration drift.
- Safer experimentation.
- Better documentation quality.
- Higher confidence before automation.
- Reusable Ansible roles based on validated behavior rather than assumptions.

## Consequences

### Positive

- Consistent platform standards.
- Easier rollback and recovery.
- Faster deployment after initial validation.
- Improved onboarding for future contributors.
- Reduced operational risk.

### Trade-offs

- Initial implementation work may take longer.
- Documentation is required before broad deployment.
- Emergency changes may require retrospective documentation.

## Exceptions

Exceptions must document:

- Reason for bypassing the reference host.
- Risk assessment.
- Validation performed.
- Rollback plan.
- Timeline for bringing schai back into alignment.

## Relationship to Other Standards

This ADR complements:

- Network Architecture
- Linux Server Security Standard
- Service Exposure Standard

Together, these documents establish the governance model for future platform engineering work.

## Future Direction

As the platform matures, CI/CD validation, compliance testing, and Ansible automation will treat schai as the canonical implementation. Platform standards and automation should evolve together so that validated manual changes become repeatable infrastructure as code.