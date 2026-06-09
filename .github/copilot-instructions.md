# Memex Copilot Instructions

`AGENTS.md` is the canonical instruction file for this repository. Read it
before suggesting or editing code.

Key testing rule: behavior changes require test evidence in the same PR. Add or
update unit tests for non-UI behavior, widget tests for UI/user interaction
changes, and integration or full-chain tests for cross-layer golden-path
changes. If tests are not applicable, the PR test plan must explain why.
