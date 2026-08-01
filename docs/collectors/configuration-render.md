# Configuration Render Collector

Renders declared Docker Compose configuration and reports its shape.

- **Plugin ID:** `configuration-render`
- **Source type:** `configuration-render`
- **Permissions:** `read-repository-files`
- **Network access:** false · **Subprocess:** true (docker compose config only) · **Filesystem:** read-only

## Purpose

Reports what Compose *would* deploy, so verification can compare declared service configuration against the model. This is **declared configuration, not running state** — a rendered port mapping is what Compose would publish, not what is listening.

## Required inputs

| Option | Meaning |
|---|---|
| `compose_file` | Compose file path, inside the repository root |
| `env_file` | Environment file; must end in `.example` |
| `repository_root` | Containment boundary (defaults to `.`) |

## Commands executed

Exactly one form:

```text
docker compose --env-file <approved>.env.example -f <compose-file> config
```

Approved environment files in this repository:

```text
ai/.env.example
ai/ollama/.env.example
ai/litellm/.env.example
```

## Collected facts

`compose_file`, `service_names`, `images`, `published_ports`, `volumes`, `named_volumes`, `networks`, `restart_policies`, `healthcheck_services`, `environment_variable_names`, `collection_scope`.

## Not collected

- **Environment values.** Never, under any condition.
- **Running containers, container IDs, image IDs, or health status.** Nothing inspects the runtime.
- **Build contexts or Dockerfile contents.**
- **Anything from a registry.** No image is pulled or resolved remotely.

## Secret handling

For each environment variable the collector emits the **name** and how the value would be supplied:

| Classification | Meaning |
|---|---|
| `literal` | The compose file hard-codes a value |
| `defaulted` | Interpolation with a default, `${VAR:-default}` |
| `externally-supplied` | Interpolation with no default, or empty after rendering |
| `redacted-literal` | A literal that matched a secret shape |

The value itself is never emitted, so the useful operational fact — the shape of the configuration — survives while the liability does not. An empty rendered value is reported as `externally-supplied` rather than `literal`, because calling it literal would imply the compose file hard-codes a value it does not.

`ai/.env` is refused twice over: by name, and by the `.example` suffix rule. Either check alone would suffice; both mean a rename cannot defeat the guard.

Redaction runs before fingerprinting.

## Failure modes

| Condition | Result |
|---|---|
| `compose_file` or `env_file` missing | `failed` |
| Environment file is `.env` or lacks `.example` | `failed` |
| Path escapes the repository root | `failed` |
| Symlink resolving outside the root | `failed` — `resolve()` follows links, so the containment check catches it |
| Compose file invalid | `failed` |
| Command exceeds 120s | `failed` — timeout |

## Validation

```bash
bash tests/test-initial-collectors.sh
docker compose --env-file ai/.env.example -f ai/compose.yaml config >/dev/null
```

## Example output

Synthetic values:

```json
{
  "collector_id": "configuration-render",
  "target": "SVC-0002",
  "status": "success",
  "observations": [
    {"fact": "service_names", "value": ["litellm", "ollama"]},
    {"fact": "published_ports", "value": ["4000:4000/tcp"]},
    {"fact": "networks", "value": ["ai-backend"]},
    {"fact": "environment_variable_names",
     "value": {"EXAMPLE_KEY": "externally-supplied", "TZ": "defaulted"}},
    {"fact": "collection_scope", "value": "declared-configuration-only"}
  ]
}
```

## Boundaries

- **No container is created, started, stopped, or inspected.** `config` renders and exits.
- **No persistence.** Returns a `CollectorResult`; writes no file.
- **No EVID assignment.**
- **No remediation.**
