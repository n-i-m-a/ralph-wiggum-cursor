---
task: [Brief description of the task]
completion_criteria:
  - [Criterion 1 - must be objectively verifiable]
  - [Criterion 2]
  - [Criterion 3]
max_iterations: 50
---

# Task: [Task Name]

## Overview

[Describe what needs to be built/fixed/improved]

## Requirements

### Functional Requirements

1. [Requirement 1]
2. [Requirement 2]
3. [Requirement 3]

### Non-Functional Requirements

- [Performance, security, etc.]

## Constraints

- [Technology constraints]
- [Time constraints]
- [Other limitations]

## Success Criteria

The task is complete when ALL of the following are true:

1. [ ] [Verifiable criterion 1] <!-- group: 1 --> <!-- model: sonnet-4.6-thinking -->
2. [ ] [Verifiable criterion 2] <!-- group: 1 -->
3. [ ] [Verifiable criterion 3] <!-- group: 2 --> <!-- model: opus-4.6-thinking -->

### Parallel Group Syntax (optional)

Use `<!-- group: N -->` to control execution order in parallel mode:
- Tasks with lower group numbers run first
- Tasks with the same group run in parallel
- Unannotated tasks run LAST (after all annotated groups)

Example:
```
- [ ] Create user model <!-- group: 1 -->
- [ ] Create post model <!-- group: 1 -->
- [ ] Add relationships <!-- group: 2 -->
- [ ] Update README  # runs last (no annotation)
```

### Per-Step Model Syntax (optional)

Use `<!-- model: MODEL_ID -->` to override the model for a specific checkbox item:
- If present, that step runs with the annotated model
- If missing, Ralph falls back to the global model (`-m/--model` or `RALPH_MODEL`)
- If the model is unknown, Ralph warns and falls back to global model

Example:
```
- [ ] Scaffold project <!-- model: sonnet-4.6-thinking -->
- [ ] Implement core logic <!-- model: opus-4.6-thinking -->
- [ ] Add tests  # uses global model (no annotation)
```

## Notes

[Any additional context, links to documentation, etc.]

---

## Ralph Instructions

When working on this task:

1. Read `.ralph/progress.md` to see what's been done
2. Check `.ralph/guardrails.md` for signs to follow
3. If present, read `.ralph/review.md` and address review findings
4. Work on the next incomplete criterion
5. Update `.ralph/progress.md` with your progress
6. Commit your changes with descriptive messages
7. When ALL criteria are met (all `[ ]` → `[x]`), output: `<ralph>COMPLETE</ralph>`
8. If stuck on the same issue 3+ times, output: `<ralph>GUTTER</ralph>`
