# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

# Schott Platform — Claude Instructions

## Project

This repository contains the reusable Schott Platform infrastructure.

The current release is the AI Platform Baseline for the `schai` Ubuntu 24.04 VM.

Read these documents before making changes:

1. `docs/superpowers/specs/2026-07-27-ai-platform-baseline-design.md`
2. `docs/superpowers/plans/2026-07-27-ai-platform-baseline.md`

The design defines the architecture.  
The implementation plan defines the required tasks and exact acceptance criteria.

Do not redesign or expand the approved scope.

## Architecture Rules

- LiteLLM is the only supported application-facing AI endpoint.
- Applications connect to `http://schai:4000/v1`.
- Ollama is an internal inference backend.
- Do not document Ollama port `11434` as the application endpoint.
- Do not add automatic commercial-provider fallback.
- Every service must remain independently replaceable behind a stable interface.

## Required Model Aliases

Preserve these names and mappings exactly:

- `local-fast` → `ollama/qwen3:8b`
- `local-general` → `ollama/qwen3:30b`
- `local-embed` → `ollama/nomic-embed-text`

## Environment

- Production host: `schai`
- Operating system: Ubuntu 24.04
- Deployment path: `/opt/schott-platform`
- Timezone: `America/Chicago`
- Container orchestration: Docker Compose v2
- GPU: NVIDIA Tesla P4

## Security Rules

- Never commit production secrets.
- Never commit `.env` files other than `.env.example`.
- Never commit model blobs, logs, backups, tokens, or passwords.
- LiteLLM authentication must fail closed.
- Load the LiteLLM master key from a local environment file.
- Do not log full prompts or responses by default.
- Docker logs must use rotation limits.
- Do not automatically modify host firewall rules.
- Document firewall commands for an operator to apply manually.

## Development Workflow

- Never work directly on `main`.
- Create a feature branch before implementation.
- Implement only the requested task.
- Do not begin the next task without explicit instruction.
- Follow the exact file paths and values in the implementation plan.
- Keep commits narrowly scoped.
- Run all tests required by the task before committing.
- Do not claim tests passed unless they were actually executed.
- Report assumptions, deviations, unresolved issues, and commands run.

## Shell Standards

Every repository shell script must:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

=== REVIEW PACKAGE ===

Task:
Files Changed:
Tests Executed:
Commands Run:
Known Risks:
Architecture Decisions:
Questions for Reviewer: