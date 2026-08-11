"""ENG-0005 first adapter — bounded local Python execution.

This package will eventually hold the adapter that executes one governed
Python entrypoint inside a rootless container. **It does not execute anything
yet.** Increment T1 contributes the execution-domain vocabulary and nothing
else: immutable value types and one closed classification set.

The vocabulary comes first deliberately. A classification set that is closed
before behaviour depends on it makes an omission visible as a missing member,
which a reviewer can see, rather than as a free-form reason string invented at
the call site months later, which nobody can.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md``.
"""
