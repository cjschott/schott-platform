"""The Capability Health Plane — ENG-0006-H1 through H6.

**Records, three pure evaluators, and the store, in separate modules.**

- `records` — immutable, schema-conformant models for the six Health record
  families, the subject-binding rules over them, and `select_observations`,
  which selects records for one dimension of one subject and refuses a
  cross-subject set.
- `errors` — the controlled refusal vocabulary that guards all of them.
- `conditions` — the ADR-0019 condition grammar evaluator. `evaluate_condition`
  returns `satisfied`, `not-satisfied` or `unknown`.
- `freshness` — the per-dimension freshness evaluator. `evaluate_freshness`
  returns `current`, `aging`, `stale` or `unknown`, and
  `evaluate_envelope_freshness` returns one of those per declared dimension,
  never a collapsed score.
- `hysteresis` — the ADR-0019 duration and continuity evaluator.
  `evaluate_hysteresis` returns `satisfied`, `unsatisfied` or `unprovable`,
  and carries the CHDEG proof fields for a transition it finds provable.
- `store` — the append-only record store, built on the platform's shared
  write-once storage base, and the identifier allocation behind it. The only
  module here that touches a filesystem, and the only one authorised to name a
  store class, an allocator, a production path or a serialiser.

The dependency runs one way: the evaluators and the store import `records`,
`records` imports none of them, and they do not import each other. A record
model never depends on an evaluation.

It still concludes nothing. No state is derived, no clock is read, and the
only thing imported from outside this package is the shared storage base that
`store` subclasses. A condition outcome, a freshness label and a hysteresis
proof are all advisory: turning them into a health state needs the
worst-dimension-wins combination, which is a later increment's authority.
`aging` is reported only when a caller supplies a threshold, because no
warning threshold is declared anywhere in Health authority and defaulting one
would be the mistake the Null Policy Rule exists to prevent.

Storage is not conclusion. The store persists a record a caller has already
built and refuses to persist anything else; it decides nothing about what
should be written, and it creates no production root.

That restraint is the point. The Health Plane's entire specification is about
what it must not be able to do, so each layer is built and reviewed before the
platform gains any further Health evaluation, persistence or operational
authority.
"""

from .conditions import (CONDITION_OUTCOMES, UNKNOWN_REASONS, ConditionResult,
                         evaluate_condition)
from .errors import HealthRecordError
from .freshness import (FRESHNESS_STATES, FRESHNESS_UNKNOWN_REASONS,
                        FreshnessResult, evaluate_envelope_freshness,
                        evaluate_freshness)
from .hysteresis import (HYSTERESIS_OUTCOMES, UNPROVABLE_REASONS,
                         UNSATISFIED_REASONS, HysteresisProof,
                         HysteresisResult, evaluate_hysteresis)
from .records import (HealthRecord, KINDS, citations_of, parse,
                      select_observations, validate_citations)
from .store import HealthStore, HealthStoreError

__all__ = ["CONDITION_OUTCOMES", "ConditionResult", "FRESHNESS_STATES",
           "FRESHNESS_UNKNOWN_REASONS", "FreshnessResult",
           "HYSTERESIS_OUTCOMES", "HealthRecord", "HealthRecordError",
           "HealthStore", "HealthStoreError",
           "HysteresisProof", "HysteresisResult", "KINDS",
           "UNKNOWN_REASONS", "UNPROVABLE_REASONS", "UNSATISFIED_REASONS",
           "citations_of", "evaluate_condition",
           "evaluate_envelope_freshness", "evaluate_freshness",
           "evaluate_hysteresis", "parse", "select_observations",
           "validate_citations"]
