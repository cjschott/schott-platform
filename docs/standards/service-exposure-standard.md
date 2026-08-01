# Service Exposure Standard

## Purpose

This standard defines how Schott Platform services are classified, approved, exposed, validated, and automated. The goal is to make service access intentional and policy-driven rather than the accidental result of a firewall or Docker port-publishing decision.

## Scope

This standard applies to services running on Schott Platform infrastructure, including host services, containers, virtual machines, management interfaces, APIs, databases, monitoring endpoints, and internal platform components.

## Exposure Classes

### Administrative

Administrative services are used to manage infrastructure or platform components.

Requirements:

- Reachable only from the Management Network: `192.168.86.2-99`.
- Protected by strong authentication.
- Not exposed to the general DHCP range.
- Documented with an owner, purpose, ports, validation method, and rollback method.

Examples:

- SSH
- Proxmox VE
- Proxmox Backup Server
- TrueNAS administration
- Grafana administration
- Kyri administration

### Application

Application services are intentionally consumed by approved users, clients, or systems.

Requirements:

- Reachable only from the smallest approved client range.
- Authentication enabled when supported and appropriate.
- Internet exposure requires an explicit architecture and security decision.
- Source ranges and expected consumers must be documented.

Current example:

- LiteLLM on `4000/tcp`, reachable from `192.168.86.0/24`.

### Infrastructure

Infrastructure services support platform-to-platform communication and are not intended for normal end users.

Requirements:

- Restricted to the specific hosts, collectors, or infrastructure ranges that require access.
- Not broadly exposed to the full LAN unless justified and documented.
- Monitoring, backup, logging, orchestration, and synchronization endpoints belong here when they are not administrative interfaces.

Examples may include:

- Metrics exporters
- Prometheus scrape endpoints
- Syslog receivers
- Backup transport services
- Configuration-management endpoints

### Private

Private services are implementation details that do not require direct remote access.

Requirements:

- Bound to localhost, a Unix socket, or a private container network.
- Not published to a remote host interface.
- Accessed only through an approved dependent service.
- Any change from private to remotely reachable requires a documented design review.

Current example:

- Ollama on `11434/tcp`, private to Docker networking.

## Required Service Record

Every remotely reachable service must have a documented service record containing:

| Field | Requirement |
|---|---|
| Service name | Human-readable service identifier |
| Owner | Person or platform component responsible for the service |
| Purpose | Why the service exists and who consumes it |
| Exposure class | Administrative, Application, Infrastructure, or Private |
| Protocol and ports | TCP/UDP and port numbers |
| Listening address | Host interface, localhost, or container network |
| Allowed sources | Exact host, range, or approved zone |
| Authentication | Authentication and authorization method |
| Encryption | TLS, SSH, VPN, or documented exception |
| Validation | How allowed and denied access are tested |
| Rollback | How exposure is safely reverted |
| Automation source | Ansible variable, role, Compose file, or temporary manual exception |

## Current Service Classification

| Service | Class | Port | Approved source |
|---|---|---:|---|
| SSH | Administrative | `22/tcp` | `192.168.86.2-99` |
| LiteLLM | Application | `4000/tcp` | `192.168.86.0/24` |
| Ollama | Private | `11434/tcp` | Docker-private only |
| Proxmox VE | Administrative | Platform-defined | `192.168.86.2-99` |
| Proxmox Backup Server | Administrative | Platform-defined | `192.168.86.2-99` |
| TrueNAS administration | Administrative | Platform-defined | `192.168.86.2-99` |
| Grafana administration | Administrative | Deployment-defined | `192.168.86.2-99` |
| Kyri administration | Administrative | Deployment-defined | `192.168.86.2-99` |

Ports marked as platform-defined or deployment-defined must be recorded in the applicable host or service documentation before enforcement.

## Firewall and Docker Requirements

- Host firewall policy must align with the service's exposure class.
- Docker-published ports must be evaluated in the Docker packet-filtering path and must not rely on UFW assumptions alone.
- `DOCKER-USER` or an equivalent enforcement point must be used where required to restrict published container services.
- Established and related return traffic must remain functional.
- Private services must not be published with a wildcard bind such as `0.0.0.0`.
- Binding to localhost is preferred when a host-local dependency requires access.

## Validation Requirements

Before an exposure change is accepted:

1. Verify the service is reachable from an approved source.
2. Verify the service is not reachable from a denied source.
3. Confirm the effective listening address with host tools such as `ss`.
4. Confirm the effective firewall path and rule ordering.
5. For containers, test actual remote reachability rather than relying only on configuration inspection.
6. Confirm authentication still functions.
7. Confirm dependent services still function.
8. Confirm the documented rollback restores the previous state.

## Change Control

A service exposure change must include:

- The requested exposure class
- The exact source range
- The affected host and service
- The reason for the change
- Risk and compensating controls
- Validation steps
- Rollback steps

Broadening access is a security-relevant change and must not be treated as a routine port-opening request.

## Automation Model

Service exposure should be represented as structured policy data and enforced through Ansible or another approved infrastructure-as-code mechanism.

Illustrative model:

```yaml
service_exposure:
  ssh:
    class: administrative
    protocol: tcp
    port: 22
    allowed_sources:
      - 192.168.86.2-99

  litellm:
    class: application
    protocol: tcp
    port: 4000
    allowed_sources:
      - 192.168.86.0/24

  ollama:
    class: private
    protocol: tcp
    port: 11434
    publish: false
```

The example is a policy direction, not yet a committed Ansible schema. The final data model must be validated against the reference implementation before broader use.

## Exceptions

Exceptions must document:

- Service and host
- Requested deviation
- Business or technical reason
- Risk
- Compensating control
- Owner
- Review or expiration date
