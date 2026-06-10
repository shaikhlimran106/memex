# Memex Gemini Instructions

`AGENTS.md` is the canonical instruction file for coding agents in this
repository. Read it before editing code.

Behavior changes require tests in the same PR: unit tests for non-UI behavior,
widget tests for UI/user interaction changes, and integration or full-chain
tests for cross-layer golden-path changes. If tests are not applicable, explain
the concrete reason in the PR test plan.
