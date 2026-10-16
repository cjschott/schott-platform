"""The Capability Health Plane — ENG-0006-H1 through H3.

**Records and one pure evaluator.** This package holds immutable,
schema-conformant models for the six Health record families, the controlled
refusals that guard them, and — from ENG-0006-H3 — the condition grammar
evaluator that compares one declared condition against supplied observations.

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

from .errors import HealthRecordError
from .records import (CONDITION_OUTCOMES, ConditionResult, HealthRecord, KINDS,
                      UNKNOWN_REASONS, citations_of, evaluate_condition, parse,
                      validate_citations)

__all__ = ["CONDITION_OUTCOMES", "ConditionResult", "HealthRecord",
           "HealthRecordError", "KINDS", "UNKNOWN_REASONS", "citations_of",
           "evaluate_condition", "parse", "validate_citations"]
