---
name: backlog
description: Use when creating, updating, reviewing, or completing tasks in a repository that uses the backlog/todo, backlog/review, backlog/done workflow. Covers task file format, status sync, Definition of Done, testing tags, and the rule that only the user approves moves to done.
---

# Backlog workflow

Use this workflow for every piece of work in a repository that keeps a
`backlog/` directory:

```
backlog/
  todo/      new + in-progress tasks
  review/    implemented, awaiting approval
  done/      approved
```

## Rules

- All new work is a task file in `backlog/todo/`.
- File format: `NNN-TASK-short-name.md` (zero-padded, sequential).
- Flow: `todo/` → implement → move to `review/` → user approves → move to `done/`.
- **Never move a task to `done/` yourself** — only the user approves that.
- When implementing a task, keep its `Status` field in sync with its folder.
- Only the user approves the final move to `done/`.

## Task template

```md
# NNN — Short name

- **Status:** todo
- **Phase:** P0–P5
- **Priority:** high | medium | low
- **Depends on:** NNN, ...

## Goal
## Acceptance criteria
- [ ] ...
## Test cases
- [ ] [unit] ...
## Notes
```

## Definition of Done (before `review/` → `done/`)

A task may move to `done/` only when **all** of the following hold:

- Every `## Acceptance criteria` checkbox is `[x]`.
- Every `## Test cases` checkbox is `[x]`.
- The project's build, lint, and test commands pass. Read the project's
  `AGENTS.md` / `README.md` for the exact commands; do not assume them.

If any item cannot be completed now, **move that item to a follow-up task**
(or the task it belongs to) and remove it from this task before approval —
do not leave it unchecked. When the user asks to mark a task done, verify these
checks first; if they fail, report what is still open instead of moving the
task, and only move it once the user confirms.

## Testing tags

- `[unit]` — JVM/JUnit, Jest, or the project's unit test runner.
- `[component]` — UI/component tests.
- `[e2e]` — emulator, UI Automator, Maestro, or equivalent.
- `[device]` — manual checks (animations, sound, touch feel, performance).

Every task must add the test cases listed in its `## Test cases` section.
Unit/component tests must not require a real device, emulator, or hardware
output unless the tag says otherwise.

## Notes

- After any change, run the project's build + lint (and tests when present).
- Do not commit unless the user explicitly asks.