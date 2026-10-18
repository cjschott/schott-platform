"""The Capability Health Plane — ENG-0006-H1 through H3.

**Records and one pure evaluator, in separate modules.** `records` holds
immutable, schema-conformant models for the six Health record families and the
subject-binding rules over them; `errors` holds the controlled refusal
vocabulary that guards both; `conditions` holds the ADR-0019 condition grammar
evaluator. The dependency runs one way — `conditions` imports `records`, never
the reverse — so a record model never depends on an evaluator.

It still concludes nothing. No freshness is judged, no hysteresis is decided,
no state is derived, nothing is stored, no clock is read, and nothing is read
from or written to any other plane. `evaluate_condition` returns `satisfied`,
`not-satisfied` or `unknown`; turning any of those into a health state needs
hysteresis and the worst-dimension-wins combination, which are later
increments' authority.

That restraint is the point. The Health Plane's entire specification is about
what it must not be able to do, so each layer is built and reviewed before the
platform gains any further Health evaluation, persistence or operational
authority.
"""

from .conditions import (CONDITION_OUTCOMES, UNKNOWN_REASONS, ConditionResult,
                         evaluate_condition)
from .errors import HealthRecordError
from .records import (HealthRecord, KINDS, citations_of, parse,
                      validate_citations)

__all__ = ["CONDITION_OUTCOMES", "ConditionResult", "HealthRecord",
           "HealthRecordError", "KINDS", "UNKNOWN_REASONS", "citations_of",
           "evaluate_condition", "parse", "validate_citations"]
