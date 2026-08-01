# ADR-0003: Provider-Agnostic AI Architecture

- **Status:** Accepted
- **Date:** 2026-08-01
- **Decision Makers:** Schott Platform Engineering

## Context

AI provider choice is unusually volatile: models are deprecated, pricing changes, quotas are exhausted mid-workload, and capability leadership moves between vendors on a timescale shorter than most application lifecycles.

An application that imports a provider SDK and hardcodes a model name has made all of that its own problem. Every such application must then be edited to change providers, and the platform loses the ability to make routing decisions — about privacy, cost, or availability — on behalf of workloads that should not need to care.

There is a second, quieter risk. Once an application can reach an external provider directly, sensitive data can leave the platform without any policy layer noticing. The decision to send a prompt off-site should be a platform decision, not an accident of which library an application imported.

## Decision

Applications depend on a **stable internal AI gateway interface**, never on a provider.

- Applications do **not** depend directly on Ollama, Claude, OpenAI, Gemini, OpenRouter, Azure OpenAI, or any other provider.
- **LiteLLM is the current application-facing gateway**, reachable at `http://schai:4000/v1`.
- **Kyri may later add policy-based routing** above or beside LiteLLM. That is an implementation change behind the same interface, not a new application contract.
- **Providers are adapters behind a shared contract.** Adding, removing, or replacing one must not require an application change.
- **Provider-specific model names must not become application contracts.** Applications use stable aliases such as `local-fast`, `local-general`, and `local-embed`. An application that names `gpt-4o` or `qwen3:8b` directly has recreated the coupling this decision exists to prevent.

### Privacy posture

- **Local processing is preferred for sensitive workloads.** The default destination for platform data is the local inference backend.
- **External processing requires policy authorization.** Sending a sensitive workload to an external provider is an explicit, recorded policy decision, not a runtime convenience.
- **No commercial or cloud fallback is silently enabled.** If local capacity is unavailable, the honest outcome is a failure the caller can see — not a quiet redirection of data off the platform. Silent fallback converts an availability problem into a data-exposure problem, and does it invisibly.

### Routing dimensions

Routing policy may consider:

- `capability` — can the target actually do this task
- `privacy` — is this workload permitted to leave the platform
- `cost` — price per unit of work
- `quota` — remaining allowance
- `latency` — responsiveness requirements
- `availability` — is the target reachable and healthy
- `context size` — does the input fit
- `tool support` — are the required tool-calling features present

**Exhausted quota may trigger an approved fallback chain.** The chain is declared policy with an explicit ordering; it is not an automatic escalation to whatever provider still has capacity.

### Observability and secrets

- **Routing decisions must be observable and explainable.** For any request the platform should be able to say which target was chosen and which policy inputs led there. A router that cannot explain itself cannot be audited or debugged.
- **Provider health and quota evidence must not expose credentials.** Health and quota are legitimate evidence subjects; API keys are not. Evidence records may state that a credential is present and name its source, never its value.
- **Prompt and response logging must remain redacted and policy-controlled.** The platform currently disables full prompt and response persistence, retaining request metadata only. Any change to that is a policy decision with privacy consequences.

## OmniRoute-Inspired Concepts

Several ideas from OmniRoute-style routers are adopted as **concepts**: capability-aware target selection, policy-driven fallback ordering, quota and cost awareness, and explainable routing decisions.

The platform does **not** depend on OmniRoute as a service, nor route production traffic through an external proxy. Doing so would place a third party in the path of every prompt — reintroducing exactly the data-exposure and availability coupling this decision removes. The concepts are implemented inside the platform boundary, behind the same gateway interface.

## Consequences

### Positive

- Provider changes become a gateway configuration change rather than a fleet-wide code change.
- Privacy policy has a single enforcement point instead of being distributed across applications.
- Routing can improve — better fallback, cost awareness, capability matching — without touching application code.

### Trade-offs

- The gateway is a single point of failure for AI access, and its availability becomes a platform concern.
- A stable alias layer hides provider-specific features; applications needing a genuinely provider-unique capability will need an explicit, reviewed exception.
- Policy-based routing adds a decision layer that must itself be observable, or it becomes a source of unexplained behaviour.

## Rejected Alternatives

- **Direct provider integrations in every application.** Distributes provider churn across the entire estate and removes any central privacy control.
- **Hardcoded model names throughout application code.** Makes model deprecation a coordinated multi-repository migration, and guarantees drift between what applications request and what exists.
- **Sending all prompts through an external routing service.** Places a third party in the path of every request, adding a data-exposure surface and an availability dependency outside platform control.
- **Silent cloud fallback.** Trades a visible availability failure for an invisible data-exposure event. The failure mode is worse precisely because nobody is told.
- **Routing solely by lowest price.** Ignores privacy, capability, and latency. The cheapest target for a sensitive workload may be the one that must never receive it.

## Relationship to Other Standards

- [ADR-0001](ADR-0001-schai-reference-host.md) establishes `schai` as the reference host running the gateway.
- [Service Exposure Standard](../standards/service-exposure-standard.md) classifies LiteLLM as the only application-facing AI endpoint and Ollama as private.
- [Capability Model Standard](../standards/capability-model-standard.md) records LLM routing as `CAP-0006`.
