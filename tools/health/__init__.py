"""The Capability Health Plane — ENG-0006-H1.

**Record representation only.** This package holds immutable, schema-conformant
models for the six Health record families and the controlled refusals that guard
them. It computes nothing: no condition is evaluated, no freshness is judged, no
hysteresis is decided, no state is derived, nothing is stored, and nothing is
read from or written to any other plane.

That emptiness is the point. The Health Plane's entire specification is about
what it must not be able to do, so its foundation is built and reviewed before
the platform gains any Health evaluation, persistence or operational authority.
"""

from .errors import HealthRecordError
from .records import HealthRecord, KINDS, parse

__all__ = ["HealthRecord", "HealthRecordError", "KINDS", "parse"]
