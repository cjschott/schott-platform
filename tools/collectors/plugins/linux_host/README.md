# Linux Host Collector

Remote and read-only. Observes identity: name, operating system, kernel, architecture, and uptime.

- **Collector id:** `linux-host`
- **Permission:** `read-remote-host`
- **Manifest:** [manifest.yaml](manifest.yaml)

Full documentation, including what this collector deliberately does not
collect, lives in [docs/collectors/linux-host.md](../../../../docs/collectors/linux-host.md).

The rules that govern every remote collector — transport, host keys,
authentication references, limits, and failure semantics — are in
[docs/collectors/remote-collection.md](../../../../docs/collectors/remote-collection.md)
and [ADR-0010](../../../../docs/decisions/ADR-0010-remote-read-only-collection.md).

This collector observes. It never administers: it changes nothing on the
target, persists no evidence, assigns no EVID identifier, and performs no
remediation.
