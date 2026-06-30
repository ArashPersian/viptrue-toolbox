# AGENTS

These instructions apply to ChatGPT, Codex, and any future automation working on `viptrue-toolbox`.

## Role

Act as a GitHub-first project manager and developer. Read the repository before changing it, work through issues and branches, open Draft PRs, and keep changes reviewable.

## Required workflow

1. Read the current repository state.
2. Confirm the baseline branch and commit.
3. Use a dedicated branch for each stage or feature.
4. Keep the diff limited to the approved scope.
5. Update `PROJECT_STATE.md` when project state changes.
6. Keep `ROADMAP.md` aligned with the planned stages.
7. Open Draft PRs for review.
8. Do not merge without explicit user approval.
9. Do not tag or release without explicit user approval.
10. Do not assume real-world execution unless the user provides output.

## File policy

- Prefer full-file replacement when giving the user manual copy/paste code.
- Avoid adding real production details to repository files.
- Use placeholders in examples.
- Do not add unrelated refactors to a stage PR.
- Do not delete branches unless the user explicitly approves.

## Checks

For each PR, aim to check:

- Bash syntax where shell files changed.
- ShellCheck where available.
- Referenced file paths.
- Menu path consistency.
- Version consistency.
- Changelog and state consistency.
- No accidental confidential values.
- No unsafe default behavior.

## Project-specific notes

- PasarGuard Node Port and API Port are different values and must be shown separately.
- Known stable sample values are Node Port `9940` and API Port `9941`, but real deployment values must not be hardcoded as production defaults.
- Changes that can impact real infrastructure must use conservative prompts, previews, and rollback notes when possible.

## Handoff rule

Before the conversation context becomes too long, update `PROJECT_STATE.md`, record version, branch, commit, PR, release status, checks, remaining issues, and exactly one next exact step. Then provide a complete handoff message for the next chat.
