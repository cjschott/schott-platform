# Worked Examples

**Architecture only.** Nothing here is implemented; these are the combinations
a future runtime must render correctly. Governed by
[ADR-0013](../decisions/ADR-0013-capability-health-plane.md).

Each example is a case where reading one layer as another gives the wrong
answer.

## 1. Trusted, Fabric-eligible, Health unknown

```yaml
trust_state:        trusted
availability_intent: in-service
health_state:       unknown
health_freshness:   unknown
eligible_by_fabric: true
health_effect:      none
health_warning:     no fresh health evidence
```

**Selection proceeds.** Trust granted eligibility and the Fabric's declared
order chose this instance. Health is inert.

**And it says so.** The warning is required — without it this is
indistinguishable from a selection health actively agreed with.

## 2. Trusted, manually drained, Health healthy

```yaml
trust_state:        trusted
availability_intent: draining        # operator decision, Fabric-local
health_state:       healthy
health_freshness:   current
eligible_by_fabric: false            # the drain removed it, not health
health_effect:      none
```

**A fresh `healthy` does not override a manual drain.** The capability is
working and is deliberately not being offered. Those are compatible facts.

Health may have recommended `consider-manual-drain`; a human decided. Health
did not perform it and cannot reverse it.

## 3. Quarantined, Health healthy

```yaml
trust_state:        quarantined
health_state:       healthy
health_freshness:   current
eligible_by_fabric: false            # trust decided
health_effect:      none
```

**A quarantined subject with a perfect health record is quarantined.**

This is the example the whole layer exists to get right. A compromised
capability's most likely behaviour is to look well, so excellent health is not
an argument against quarantine — and health cannot make one, because it cannot
recommend trust changes at all.

## 4. Fabric withheld for maintenance, Health withheld

```yaml
availability_intent: withheld        # Fabric: do not offer this
health_state:       withheld         # Health: not asserting a conclusion
eligible_by_fabric: false            # availability_intent removed it
health_effect:      none             # withheld removes nothing on its own
```

The two coincide, and they are still different facts. The Fabric's intent is
what removed eligibility. The health state records that **conclusions are
intentionally not being published** for a subject nobody expects to be serving.

If these ever diverge — a published health finding on a node nobody withdrew,
or a withdrawn node still reporting `healthy` — the distinction is what makes
that visible.

## 5. Stale degraded observation

```yaml
health_state:       degraded         # the finding stands
health_freshness:   stale
last_observed_at:   "2026-08-01T09:14:00-05:00"
health_effect:      none             # stale evidence does not subtract
health_warning:     degraded finding is stale; no fresh evidence since
```

**A stale `degraded` never silently becomes `healthy`.** Ageing out of a
problem is not the same as fixing it.

It also does not remove eligibility, because
[removal requires fresh positive evidence](unknown-and-freshness.md). The
finding is carried forward, visibly stale, until something fresh contradicts or
confirms it.

## 6. Missing threshold for one metric

```yaml
envelope_id:      CHENV-0004
dimensions:
  latency:        { entry_condition: "p95 > 2000ms", ... }
  queue_depth:    { entry_condition: "> 32", ... }
  gpu_utilization: null              # no declared threshold
health_state:     insufficient-policy
health_effect:    none
reason:           no declared threshold for gpu-utilization
```

The envelope covers three dimensions and declares two. The third is **not
reported as satisfied**.

This is the **Null Policy Rule applied per metric**: the absence of a policy
produces an explicit "not defined", never a favourable default. The subject is
`insufficient-policy`, which is visible, inert, and creates pressure to finish
the envelope.

## 7. The same observation under two envelope versions

```yaml
# Evaluation made on 2 August, against the envelope in force then
CHSTATE-000411:
  derived_from_observation_ids: [CHOBS-002190]
  envelope_id: CHENV-0004
  envelope_version: 1               # latency entry: p95 > 2000ms
  state: healthy
  evaluated_at: "2026-08-02T14:00:00-05:00"

# Re-evaluation after the envelope was tightened
CHSTATE-000587:
  derived_from_observation_ids: [CHOBS-002190]   # the same observation
  envelope_id: CHENV-0004
  envelope_version: 2               # latency entry: p95 > 900ms
  state: degraded
  evaluated_at: "2026-08-03T10:30:00-05:00"
```

One observation, two envelope versions, two different and both correct results.

**Superseding an envelope never rewrites prior evaluations.** `CHSTATE-000411`
stands exactly as written: it is what was believed on 2 August, and an incident
review of that day needs it to stay that way. `CHSTATE-000587` is a new record,
not a correction.

Both remain auditable, and each names the envelope version that produced it.

## Related

- [Unknown health and freshness](unknown-and-freshness.md)
- [Health states](health-states.md)
- [Operational envelope](operational-envelope.md)
- [Selection visibility](selection-visibility.md)
