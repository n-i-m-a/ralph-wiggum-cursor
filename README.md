# Ralph Wiggum Cursor Skill

A Cursor Skill implementing [Geoffrey Huntley's Ralph Wiggum technique](https://ghuntley.com/ralph/) for autonomous AI development with deliberate context management.

> "That's the beauty of Ralph - the technique is deterministically bad in an undeterministic world."

## What is Ralph?

Ralph is a technique for autonomous AI development. In its purest form, it's a loop:

```bash
while :; do cat PROMPT.md | npx --yes @sourcegraph/amp ; done
```

The same prompt is fed repeatedly to an AI agent. Progress persists in **files and git**, not in the LLM's context window. Each iteration starts fresh, reads the current state from files, and continues the work.

## The malloc/free Problem

> "When data is `malloc()`'ed into the LLM's context window, it cannot be `free()`'d unless you create a brand new context window."

This is the core insight. LLM context is like memory:
- Reading files, tool outputs, conversation history = `malloc()`
- **There is no `free()`** - you cannot selectively clear context
- The only way to free context is to **start a new conversation**

Most implementations (including the Claude Code plugin) miss this. They keep the same context running, just blocking exit. Context accumulates, gets polluted, and performance degrades.

## Two Modes: True Ralph vs Assisted Ralph

This skill supports two modes based on your setup:

### 🌩️ Cloud Mode (True Ralph)

**Automatic malloc/free via Cloud Agent API**

When context fills up:
1. Stop hook detects critical context level
2. Commits current progress to git
3. **Automatically spawns a Cloud Agent** with fresh context
4. Cloud Agent reads state from files and continues
5. True malloc/free cycle - fully autonomous

**Requirements:**
- Cursor API key ([get one here](https://cursor.com/dashboard?tab=integrations))
- GitHub repository (Cloud Agents work on GitHub repos)

### 💻 Local Mode (Assisted Ralph)

**Human-in-the-loop malloc/free**

When context fills up:
1. Stop hook detects critical context level
2. **Instructs you** to start a new conversation
3. You start a new conversation (this frees context)
4. New conversation reads state from files and continues
5. Human-triggered malloc/free cycle

**Requirements:**
- None - works with any project

## Installation

```bash
# Clone the skill
gh repo clone agrimsingh/ralph-wiggum-cursor

# In your project directory, run the init script
/path/to/ralph-wiggum-cursor/scripts/init-ralph.sh
```

The init script will:
- Ask if you want to enable Cloud Mode
- Set up the `.ralph/` state directory
- Install hooks to `.cursor/`
- Create a `RALPH_TASK.md` template

## Configuration

### Cloud Mode Setup

**Option 1: Environment Variable**
```bash
export CURSOR_API_KEY='your-key-here'
```

**Option 2: Project Config** (`.cursor/ralph-config.json` - gitignored)
```json
{
  "cursor_api_key": "your-key-here",
  "cloud_agent_enabled": true
}
```

**Option 3: Global Config** (`~/.cursor/ralph-config.json`)
```json
{
  "cursor_api_key": "your-key-here"
}
```

## Usage

### 1. Define Your Task

Create `RALPH_TASK.md` in your project root:

```markdown
---
task: Build a REST API for task management
completion_criteria:
  - All CRUD endpoints working
  - Tests passing with >80% coverage
  - API documentation complete
max_iterations: 50
---

## Requirements

Build a task management API with CRUD operations...

## Success Criteria

The task is complete when ALL of the following are true:
1. [ ] All endpoints implemented
2. [ ] Tests passing
3. [ ] Documentation complete
```

### 2. Start a Ralph Loop

Open a new Cursor conversation and say:

> "Start working on the Ralph task defined in RALPH_TASK.md"

### 3. Let Ralph Iterate

Ralph will:
- Read the task and current progress from files
- Work on the next incomplete item
- Update `.ralph/progress.md`
- Commit checkpoints
- Continue until completion or context limit

### 4. When Context Fills Up

**Cloud Mode:** Automatically spawns Cloud Agent, continues autonomously

**Local Mode:** You'll see:
```
═══════════════════════════════════════════════════════════════════
⚠️  RALPH: CONTEXT LIMIT REACHED (malloc full)
═══════════════════════════════════════════════════════════════════

To continue with fresh context (complete the malloc/free cycle):

  1. Your progress is saved in .ralph/progress.md
  2. START A NEW CONVERSATION in Cursor
  3. Tell Cursor: 'Continue the Ralph task from iteration N'

The new conversation = fresh context = malloc freed
```

## How It Works

### State Files

Ralph tracks everything in `.ralph/`:

| File | Purpose |
|------|---------|
| `state.md` | Current iteration, status, mode |
| `progress.md` | What's been accomplished (survives context reset) |
| `guardrails.md` | "Signs" - lessons learned from failures |
| `context-log.md` | What's been loaded into context (malloc tracking) |
| `failures.md` | Failure patterns for gutter detection |

### Hooks

| Hook | Purpose |
|------|---------|
| `beforeSubmitPrompt` | Inject guardrails, track iteration |
| `beforeReadFile` | Track context allocations (malloc) |
| `afterFileEdit` | Log progress, detect thrashing |
| `stop` | Evaluate completion, trigger malloc/free cycle |

### The malloc/free Cycle

```
┌─────────────────────────────────────────────────────────────────┐
│                    ITERATION N                                   │
│  Context: [prompt] [file1] [file2] [errors] [attempts]          │
│  Status: Getting full...                                         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    stop-hook detects critical
                              │
              ┌───────────────┴───────────────┐
              │                               │
              ▼                               ▼
      ┌──────────────┐               ┌──────────────┐
      │ CLOUD MODE   │               │ LOCAL MODE   │
      │              │               │              │
      │ Spawn Cloud  │               │ Tell human   │
      │ Agent auto-  │               │ to start new │
      │ matically    │               │ conversation │
      └──────────────┘               └──────────────┘
              │                               │
              └───────────────┬───────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    ITERATION N+1                                 │
│  Context: [prompt] ← FRESH! Only loads what's needed            │
│  Reads: .ralph/progress.md to know what's done                  │
│  Status: Healthy, continues work                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Guardrails ("Signs")

When Ralph makes a mistake, a "sign" is added:

```markdown
### Sign: Validate Before Trust
- **Trigger**: When receiving external input
- **Instruction**: Always validate and sanitize
- **Added after**: Iteration 3 - SQL injection found
```

Signs accumulate and are injected into future iterations.

### Gutter Detection

Ralph detects when it's stuck:
- Same file edited 5+ times without progress
- Same error repeated 3+ times
- Context approaching limits

When detected, Ralph triggers the malloc/free cycle.

## Completion Signals

Tell Ralph you're done or stuck:

- `RALPH_COMPLETE: All criteria satisfied` - Task finished
- `RALPH_GUTTER: Need fresh context` - Stuck, need fresh start

## Best Practices

### Do

- Define clear, verifiable completion criteria
- Let Ralph fail and learn (add signs)
- Trust the files, not the context
- Start fresh when stuck (or let Cloud Mode do it)

### Don't

- Mix multiple unrelated tasks
- Push context to limits
- Ignore gutter warnings
- Fight the malloc/free cycle

## File Structure

```
ralph-wiggum-cursor/
├── SKILL.md                    # Main skill definition
├── README.md                   # This file
├── hooks.json                  # Cursor hooks configuration
├── scripts/
│   ├── init-ralph.sh          # Initialize Ralph in a project
│   ├── before-prompt.sh       # Inject guardrails
│   ├── before-read.sh         # Track context allocations
│   ├── after-edit.sh          # Log progress
│   ├── stop-hook.sh           # Manage iterations + malloc/free
│   └── spawn-cloud-agent.sh   # Cloud Agent integration
├── references/
│   ├── CONTEXT_ENGINEERING.md # malloc/free deep dive
│   └── GUARDRAILS.md          # How to write signs
└── assets/
    ├── RALPH_TASK_TEMPLATE.md # Task file template
    └── RALPH_TASK_EXAMPLE.md  # Example task
```

## Learn More

- [Original Ralph technique](https://ghuntley.com/ralph/) - Geoffrey Huntley
- [Context engineering](https://ghuntley.com/gutter/) - Autoregressive failure
- [malloc/free metaphor](https://ghuntley.com/allocations/) - Context as memory
- [Deliberate practice](https://ghuntley.com/play/) - Tuning Ralph

## Credits

Based on Geoffrey Huntley's Ralph Wiggum technique. This implementation adapts the methodology for Cursor using Skills and Hooks, with Cloud Agent integration for true autonomous operation.

## License

MIT
