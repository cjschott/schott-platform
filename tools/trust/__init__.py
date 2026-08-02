"""Trust Plane runtime.

ADR-0011 defined the Trust Plane and deliberately built nothing, because a
partially built trust engine reads as a control while behaving as a suggestion.
This package is that engine.

Everything here fails closed. Where a state is unknown, missing, malformed, or
unreadable, the answer is denial with a written reason -- never a default,
never a guess, and never a score.

Reasoning may consume trust. Trust never consumes reasoning: nothing in this
package imports a reasoning layer or a model client, and no inference can
produce, raise, or restore a trust state.

See docs/decisions/ADR-0011-trust-plane.md.
"""
