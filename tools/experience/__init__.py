"""Experience Engine: operational memory.

Summarizes observed history so the platform can answer "what is normal?" —
a different question from "what is true?", which evidence already answers.

The engine never predicts. It holds no model, learns nothing online, and
contains no randomness. Every number it reports is a deterministic summary of
observations that already happened.

See docs/decisions/ADR-0008-experience-engine.md.
"""
