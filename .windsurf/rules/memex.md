# Memex Windsurf Rules

`AGENTS.md` is the canonical instruction file for this repository. Read it
before editing code and follow its architecture and testing rules.

Behavior changes require test evidence in the same PR:

- Unit tests for changed non-UI behavior.
- Widget tests for UI rendering, state, navigation, dialogs/sheets, buttons,
  gestures, error/empty/loading states, localization, or interactions.
- Integration or full-chain tests for cross-layer golden-path changes.

If tests are not added or not run, the PR test plan must explain why.
