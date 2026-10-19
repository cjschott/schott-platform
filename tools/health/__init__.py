"""The Capability Health Plane — ENG-0006-H1 through H4.

**Records and two pure evaluators, in separate modules.**

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

The dependency runs one way: both evaluators import `records`, `records`
imports neither, and the evaluators do not import each other. A record model
never depends on an evaluation.

It still concludes nothing. No hysteresis is decided, no state is derived,
nothing is stored, no clock is read, and nothing is imported from any other
plane. A condition outcome and a freshness label are both advisory: turning
either into a health state needs hysteresis and the worst-dimension-wins
combination, which are later increments' authority. `aging` is reported only
when a caller supplies a threshold, because no warning threshold is declared
anywhere in Health authority and defaulting one would be the mistake the Null
Policy Rule exists to prevent.

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
from .records import (HealthRecord, KINDS, citations_of, parse,
                      select_observations, validate_citations)

__all__ = ["CONDITION_OUTCOMES", "ConditionResult", "FRESHNESS_STATES",
           "FRESHNESS_UNKNOWN_REASONS", "FreshnessResult", "HealthRecord",
           "HealthRecordError", "KINDS", "UNKNOWN_REASONS", "citations_of",
           "evaluate_condition", "evaluate_envelope_freshness",
           "evaluate_freshness", "parse", "select_observations",
           "validate_citations"]
