#!/bin/bash
# Ralph Wiggum: Common utilities and loop logic
#
# Shared functions for ralph-loop.sh and ralph-setup.sh
# All state lives in .ralph/ within the project.

# =============================================================================
# SOURCE DEPENDENCIES
# =============================================================================

# Get the directory where this script lives
_RALPH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the task parser for YAML backend support
if [[ -f "$_RALPH_SCRIPT_DIR/task-parser.sh" ]]; then
  # shellcheck source=scripts/task-parser.sh
  source "$_RALPH_SCRIPT_DIR/task-parser.sh"
  _TASK_PARSER_AVAILABLE=1
else
  _TASK_PARSER_AVAILABLE=0
fi

# =============================================================================
# CONFIGURATION (can be overridden before sourcing)
# =============================================================================

# Token thresholds
WARN_THRESHOLD="${WARN_THRESHOLD:-70000}"
ROTATE_THRESHOLD="${ROTATE_THRESHOLD:-80000}"

# Iteration limits
MAX_ITERATIONS="${MAX_ITERATIONS:-20}"
ITERATION_TIMEOUT_SECONDS="${ITERATION_TIMEOUT_SECONDS:-600}"

# Model selection
DEFAULT_MODEL="opus-4.6-thinking"
MODEL="${RALPH_MODEL:-$DEFAULT_MODEL}"
REVIEW_MODEL="${RALPH_REVIEW_MODEL:-}"
MAX_REVIEW_ATTEMPTS="${MAX_REVIEW_ATTEMPTS:-2}"

# Feature flags (set by caller)
USE_BRANCH="${USE_BRANCH:-}"
OPEN_PR="${OPEN_PR:-false}"
SKIP_CONFIRM="${SKIP_CONFIRM:-false}"
MIN_DISK_MB="${MIN_DISK_MB:-100}"
MIN_MEMORY_MB="${MIN_MEMORY_MB:-500}"

# =============================================================================
# SOURCE RETRY UTILITIES
# =============================================================================

# Source retry logic utilities
SCRIPT_DIR="${SCRIPT_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
if [[ -f "$SCRIPT_DIR/ralph-retry.sh" ]]; then
  # shellcheck source=scripts/ralph-retry.sh
  source "$SCRIPT_DIR/ralph-retry.sh"
fi

# =============================================================================
# BASIC HELPERS
# =============================================================================

# Cross-platform sed -i
sedi() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Get the .ralph directory for a workspace
get_ralph_dir() {
  local workspace="${1:-.}"
  echo "$workspace/.ralph"
}

# Get current iteration from .ralph/.iteration
get_iteration() {
  local workspace="${1:-.}"
  local state_file="$workspace/.ralph/.iteration"
  
  if [[ -f "$state_file" ]]; then
    cat "$state_file"
  else
    echo "0"
  fi
}

# Set iteration number
set_iteration() {
  local workspace="${1:-.}"
  local iteration="$2"
  local ralph_dir="$workspace/.ralph"
  
  mkdir -p "$ralph_dir"
  echo "$iteration" > "$ralph_dir/.iteration"
}

# Increment iteration and return new value
increment_iteration() {
  local workspace="${1:-.}"
  local current
  current=$(get_iteration "$workspace")
  local next=$((current + 1))
  set_iteration "$workspace" "$next"
  echo "$next"
}

# Get context health emoji based on token count
get_health_emoji() {
  local tokens="$1"
  local pct=$((tokens * 100 / ROTATE_THRESHOLD))
  
  if [[ $pct -lt 60 ]]; then
    echo "🟢"
  elif [[ $pct -lt 80 ]]; then
    echo "🟡"
  else
    echo "🔴"
  fi
}

# =============================================================================
# LOGGING
# =============================================================================

# Log a message to activity.log
log_activity() {
  local workspace="${1:-.}"
  local message="$2"
  local ralph_dir="$workspace/.ralph"
  local timestamp
  timestamp=$(date '+%H:%M:%S')
  
  mkdir -p "$ralph_dir"
  echo "[$timestamp] $message" >> "$ralph_dir/activity.log"
}

# Log an error to errors.log
log_error() {
  local workspace="${1:-.}"
  local message="$2"
  local ralph_dir="$workspace/.ralph"
  local timestamp
  timestamp=$(date '+%H:%M:%S')
  
  mkdir -p "$ralph_dir"
  echo "[$timestamp] $message" >> "$ralph_dir/errors.log"
}

# Log to progress.md (called by the loop, not the agent)
log_progress() {
  local workspace="$1"
  local message="$2"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local progress_file="$workspace/.ralph/progress.md"
  
  {
    echo ""
    echo "### $timestamp"
    echo "$message"
  } >> "$progress_file"
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Initialize .ralph directory with default files
init_ralph_dir() {
  local workspace="$1"
  local ralph_dir="$workspace/.ralph"
  
  mkdir -p "$ralph_dir"
  
  # Initialize progress.md if it doesn't exist
  if [[ ! -f "$ralph_dir/progress.md" ]]; then
    cat > "$ralph_dir/progress.md" << 'EOF'
# Progress Log

> Updated by the agent after significant work.

---

## Session History

EOF
  fi
  
  # Initialize guardrails.md if it doesn't exist
  if [[ ! -f "$ralph_dir/guardrails.md" ]]; then
    cat > "$ralph_dir/guardrails.md" << 'EOF'
# Ralph Guardrails (Signs)

> Lessons learned from past failures. READ THESE BEFORE ACTING.

## Core Signs

### Sign: Read Before Writing
- **Trigger**: Before modifying any file
- **Instruction**: Always read the existing file first
- **Added after**: Core principle

### Sign: Test After Changes
- **Trigger**: After any code change
- **Instruction**: Run tests to verify nothing broke
- **Added after**: Core principle

### Sign: Commit Checkpoints
- **Trigger**: Before risky changes
- **Instruction**: Commit current working state first
- **Added after**: Core principle

---

## Learned Signs

EOF
  fi
  
  # Initialize errors.log if it doesn't exist
  if [[ ! -f "$ralph_dir/errors.log" ]]; then
    cat > "$ralph_dir/errors.log" << 'EOF'
# Error Log

> Failures detected by stream-parser. Use to update guardrails.

EOF
  fi
  
  # Initialize activity.log if it doesn't exist
  if [[ ! -f "$ralph_dir/activity.log" ]]; then
    cat > "$ralph_dir/activity.log" << 'EOF'
# Activity Log

> Real-time tool call logging from stream-parser.

EOF
  fi
}

# =============================================================================
# TASK MANAGEMENT
# =============================================================================

# Check if task is complete
# Uses task-parser.sh when available for cached/YAML support
check_task_complete() {
  local workspace="$1"
  local task_file="$workspace/RALPH_TASK.md"
  
  if [[ ! -f "$task_file" ]]; then
    echo "NO_TASK_FILE"
    return
  fi
  
  # Use task parser if available (provides caching)
  if [[ "${_TASK_PARSER_AVAILABLE:-0}" -eq 1 ]]; then
    local remaining
    remaining=$(count_remaining "$workspace" 2>/dev/null) || remaining=-1
    
    if [[ "$remaining" -eq 0 ]]; then
      echo "COMPLETE"
    elif [[ "$remaining" -gt 0 ]]; then
      echo "INCOMPLETE:$remaining"
    else
      # Fallback to direct grep if parser fails
      _check_task_complete_direct "$workspace"
    fi
  else
    _check_task_complete_direct "$workspace"
  fi
}

# Direct task completion check (fallback)
_check_task_complete_direct() {
  local workspace="$1"
  local task_file="$workspace/RALPH_TASK.md"
  
  # Only count actual checkbox list items, not [ ] in prose/examples
  # Matches: "- [ ]", "* [ ]", "1. [ ]", etc.
  local unchecked
  unchecked=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[ \]' "$task_file" 2>/dev/null) || unchecked=0
  
  if [[ "$unchecked" -eq 0 ]]; then
    echo "COMPLETE"
  else
    echo "INCOMPLETE:$unchecked"
  fi
}

# Count task criteria (returns done:total)
# Uses task-parser.sh when available for cached/YAML support
count_criteria() {
  local workspace="${1:-.}"
  local task_file="$workspace/RALPH_TASK.md"
  
  if [[ ! -f "$task_file" ]]; then
    echo "0:0"
    return
  fi
  
  # Use task parser if available (provides caching)
  if [[ "${_TASK_PARSER_AVAILABLE:-0}" -eq 1 ]]; then
    local progress
    progress=$(get_progress "$workspace" 2>/dev/null) || progress=""
    
    if [[ -n "$progress" ]] && [[ "$progress" =~ ^[0-9]+:[0-9]+$ ]]; then
      echo "$progress"
    else
      # Fallback to direct grep if parser fails
      _count_criteria_direct "$workspace"
    fi
  else
    _count_criteria_direct "$workspace"
  fi
}

# Direct criteria counting (fallback)
_count_criteria_direct() {
  local workspace="${1:-.}"
  local task_file="$workspace/RALPH_TASK.md"
  
  # Only count actual checkbox list items, not [x] or [ ] in prose/examples
  # Matches: "- [ ]", "* [x]", "1. [ ]", etc.
  local total done_count
  total=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x| )\]' "$task_file" 2>/dev/null) || total=0
  done_count=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$task_file" 2>/dev/null) || done_count=0
  
  echo "$done_count:$total"
}

# =============================================================================
# TASK PARSER CONVENIENCE WRAPPERS
# =============================================================================

# Get the next task to work on (wrapper for task-parser.sh)
# Returns: task_id|status|description or empty
get_next_task_info() {
  local workspace="${1:-.}"
  
  if [[ "${_TASK_PARSER_AVAILABLE:-0}" -eq 1 ]]; then
    get_next_task "$workspace"
  else
    echo ""
  fi
}

# Mark a specific task complete by line-based ID
# Usage: complete_task "$workspace" "line_15"
complete_task() {
  local workspace="${1:-.}"
  local task_id="$2"
  
  if [[ "${_TASK_PARSER_AVAILABLE:-0}" -eq 1 ]]; then
    mark_task_complete "$workspace" "$task_id"
  else
    echo "ERROR: Task parser not available" >&2
    return 1
  fi
}

# List all tasks with their status
# Usage: list_all_tasks "$workspace"
list_all_tasks() {
  local workspace="${1:-.}"
  
  if [[ "${_TASK_PARSER_AVAILABLE:-0}" -eq 1 ]]; then
    get_all_tasks "$workspace"
  else
    echo "ERROR: Task parser not available" >&2
    return 1
  fi
}

# List unique non-empty step-level models from RALPH_TASK.md
list_task_models() {
  local workspace="${1:-.}"

  if [[ "${_TASK_PARSER_AVAILABLE:-0}" -eq 1 ]]; then
    get_all_tasks_with_group "$workspace" 2>/dev/null | while IFS='|' read -r task_id task_status task_group task_model task_desc; do
      if [[ -n "$task_model" ]]; then
        echo "$task_model"
      fi
    done | awk 'NF' | sort -u
  else
    local task_file="$workspace/RALPH_TASK.md"
    if [[ -f "$task_file" ]]; then
      sed -nE 's/.*<!--[[:space:]]*model:[[:space:]]*([^>]+)[[:space:]]*-->.*/\1/p' "$task_file" | awk 'NF' | sort -u
    fi
  fi
}

# Check if a model exists in cursor-agent --list-models output.
# Matches either exact line or first column ("id - Display Name" format).
is_model_in_list() {
  local model_list="$1"
  local model_name="$2"

  printf "%s\n" "$model_list" | awk -v m="$model_name" '
    { sub(/^[ \t]+/, ""); }
    $1 == m || $0 == m { found = 1 }
    END { exit !found }
  '
}

# Track once-per-run warnings for invalid step model annotations.
has_warned_step_model() {
  local model_name="$1"
  [[ "${RALPH_WARNED_STEP_MODELS:-}" == *$'\n'"$model_name"$'\n'* ]]
}

mark_warned_step_model() {
  local model_name="$1"
  RALPH_WARNED_STEP_MODELS="${RALPH_WARNED_STEP_MODELS:-$'\n'}${model_name}"$'\n'
}

# Resolve model for current iteration:
# step-level annotation (next pending task) > global MODEL
resolve_model() {
  local workspace="${1:-.}"
  local resolved_model="$MODEL"
  local next_task task_id step_model

  if [[ "${_TASK_PARSER_AVAILABLE:-0}" -ne 1 ]]; then
    echo "$resolved_model"
    return
  fi

  next_task=$(get_next_task_info "$workspace" 2>/dev/null || true)
  task_id="${next_task%%|*}"
  if [[ -z "$task_id" ]] || [[ "$task_id" == "$next_task" ]]; then
    echo "$resolved_model"
    return
  fi

  step_model=$(get_task_model "$workspace" "$task_id" 2>/dev/null || true)
  if [[ -z "$step_model" ]]; then
    echo "$resolved_model"
    return
  fi

  # If prerequisites captured model list, validate step model dynamically.
  # Unknown step model falls back to global MODEL.
  if [[ -n "${RALPH_MODEL_LIST_CACHE:-}" ]] && ! is_model_in_list "$RALPH_MODEL_LIST_CACHE" "$step_model"; then
    if ! has_warned_step_model "$step_model"; then
      echo "⚠️  Step model '$step_model' on task '$task_id' not found; using '$resolved_model'." >&2
      mark_warned_step_model "$step_model"
    else
      # Debug-level trace in activity log without repeating stderr warnings.
      log_activity "$workspace" "DEBUG MODEL_FALLBACK: task=$task_id step_model=$step_model fallback=$resolved_model"
    fi
    echo "$resolved_model"
    return
  fi

  echo "$step_model"
}

# Refresh task cache (useful after external edits)
refresh_task_cache() {
  local workspace="${1:-.}"
  
  if [[ "${_TASK_PARSER_AVAILABLE:-0}" -eq 1 ]]; then
    # Invalidate and re-parse
    rm -f "$workspace/.ralph/$TASK_MTIME_FILE" 2>/dev/null
    parse_tasks "$workspace"
  fi
}

# =============================================================================
# PROMPT BUILDING
# =============================================================================

# Build the Ralph prompt for an iteration
build_prompt() {
  local workspace="$1"
  local iteration="$2"
  local active_model="${3:-$MODEL}"
  
  cat << EOF
# Ralph Iteration $iteration
Model: $active_model

You are an autonomous development agent using the Ralph methodology.

## FIRST: Read State Files

Before doing anything:
1. Read \`RALPH_TASK.md\` - your task and completion criteria
2. Read \`.ralph/guardrails.md\` - lessons from past failures (FOLLOW THESE)
3. Read \`.ralph/progress.md\` - what's been accomplished
4. Read \`.ralph/errors.log\` - recent failures to avoid
5. Read \`.ralph/review.md\` - review feedback from the review model (if present)

## Working Directory (Critical)

You are already in a git repository. Work HERE, not in a subdirectory:

- Do NOT run \`git init\` - the repo already exists
- Do NOT run scaffolding commands that create nested directories (\`npx create-*\`, \`pnpm init\`, etc.)
- If you need to scaffold, use flags like \`--no-git\` or scaffold into the current directory (\`.\`)
- All code should live at the repo root or in subdirectories you create manually

## Git Protocol (Critical)

Ralph's strength is state-in-git, not LLM memory. Commit early and often:

1. After completing each criterion, commit your changes:
   \`git add -A && git commit -m 'ralph: implement state tracker'\`
   \`git add -A && git commit -m 'ralph: fix async race condition'\`
   \`git add -A && git commit -m 'ralph: add CLI adapter with commander'\`
   Always describe what you actually did - never use placeholders like '<description>'
2. After any significant code change (even partial): commit with descriptive message
3. Before any risky refactor: commit current state as checkpoint
4. Push after every 2-3 commits: \`git push\`

If you get rotated, the next agent picks up from your last commit. Your commits ARE your memory.

## Task Execution

1. Work on the next unchecked criterion in RALPH_TASK.md (look for \`[ ]\`)
2. Run tests after changes (check RALPH_TASK.md for test_command)
3. **Mark completed criteria**: Edit RALPH_TASK.md and change \`[ ]\` to \`[x]\`
   - Example: \`- [ ] Implement parser\` becomes \`- [x] Implement parser\`
   - This is how progress is tracked - YOU MUST update the file
4. Update \`.ralph/progress.md\` with what you accomplished
5. When ALL criteria show \`[x]\`: output \`<ralph>COMPLETE</ralph>\`
6. If stuck 3+ times on same issue: output \`<ralph>GUTTER</ralph>\`

## Learning from Failures

When something fails:
1. Check \`.ralph/errors.log\` for failure history
2. Figure out the root cause
3. Add a Sign to \`.ralph/guardrails.md\` using this format:

\`\`\`
### Sign: [Descriptive Name]
- **Trigger**: When this situation occurs
- **Instruction**: What to do instead
- **Added after**: Iteration $iteration - what happened
\`\`\`

## Context Rotation Warning

You may receive a warning that context is running low. When you see it:
1. Finish your current file edit
2. Commit and push your changes
3. Update .ralph/progress.md with what you accomplished and what's next
4. You will be rotated to a fresh agent that continues your work

Begin by reading the state files.
EOF
}

# Build prompt for optional review model pass
build_review_prompt() {
  local workspace="$1"
  local iteration="$2"
  local execution_model="$3"
  local review_model="$4"
  local checkpoint_file="$workspace/.ralph/last_checkpoint"
  local base_ref=""

  if [[ -f "$checkpoint_file" ]]; then
    base_ref=$(cat "$checkpoint_file" 2>/dev/null || true)
  fi
  if [[ -z "$base_ref" ]]; then
    base_ref=$(git -C "$workspace" rev-parse HEAD~1 2>/dev/null || echo "HEAD")
  fi

  local diff_cmd=(git -C "$workspace" diff --no-color "$base_ref"..HEAD)
  local stat_cmd=(git -C "$workspace" diff --no-color --stat "$base_ref"..HEAD)
  local diff_content
  local diff_stat
  diff_content="$("${diff_cmd[@]}" 2>/dev/null || true)"
  diff_stat="$("${stat_cmd[@]}" 2>/dev/null || true)"
  # Cap diff to keep review prompt bounded.
  local max_chars=18000
  if [[ ${#diff_content} -gt $max_chars ]]; then
    diff_content="${diff_content:0:$max_chars}

[TRUNCATED: diff exceeded ${max_chars} chars]"
  fi

  cat << EOF
# Ralph Review Iteration $iteration
Execution model: $execution_model
Review model: $review_model

You are the independent reviewer for a completed Ralph iteration.

Review goals:
1. Verify changes satisfy \`RALPH_TASK.md\` success criteria.
2. Identify correctness, safety, testing, or maintainability issues.
3. Flag critical misses, regressions, or unchecked assumptions.
4. Keep feedback concise and actionable.

Required files to read:
- \`RALPH_TASK.md\`
- Relevant changed files from the diff
- \`.ralph/progress.md\`
- \`.ralph/guardrails.md\`

Git diff base: $base_ref

## Diff summary
$diff_stat

## Diff content
\`\`\`
$diff_content
\`\`\`

Output format requirements:
- Start with one sigil line:
  - \`<ralph>REVIEW_PASS</ralph>\` if ready to ship
  - \`<ralph>REVIEW_FAIL</ralph>\` if more work is needed
- Then provide:
  - \`## Findings\` with bullet points (or "No blocking issues.")
  - \`## Recommended next actions\` with concrete steps

Be strict on correctness and tests. Do not rewrite code; review only.
EOF
}

# =============================================================================
# SPINNER
# =============================================================================

# Spinner to show the loop is alive (not frozen)
# Outputs to stderr so it's not captured by $()
spinner() {
  local workspace="$1"
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  while true; do
    printf "\r  🐛 Agent working... %s  (watch: tail -f %s/.ralph/activity.log)" "${spin:i++%${#spin}:1}" "$workspace" >&2
    sleep 0.1
  done
}

# =============================================================================
# ITERATION RUNNER
# =============================================================================

# Run a single agent iteration
# Returns: signal (ROTATE, GUTTER, COMPLETE, or empty)
run_iteration() {
  local workspace="$1"
  local iteration="$2"
  local session_id="${3:-}"
  local script_dir="${4:-$(dirname "${BASH_SOURCE[0]}")}"
  local iteration_model
  iteration_model=$(resolve_model "$workspace")
  
  local prompt
  prompt=$(build_prompt "$workspace" "$iteration" "$iteration_model")
  local fifo="$workspace/.ralph/.parser_fifo_${iteration}_$$"
  local stream_fifo="$workspace/.ralph/.agent_stream_fifo_${iteration}_$$"
  local spinner_pid=""
  local agent_pid=""
  local agent_pgid=""
  local parser_pid=""
  local signal=""
  local cleaned_up=0
  
  # Cleanup must run on normal return and on signals.
  _cleanup_iteration() {
    if [[ "$cleaned_up" -eq 1 ]]; then
      return
    fi
    cleaned_up=1
    if [[ -n "$spinner_pid" ]]; then
      kill "$spinner_pid" 2>/dev/null || true
      wait "$spinner_pid" 2>/dev/null || true
    fi
    if [[ -n "$agent_pid" ]]; then
      if [[ -n "$agent_pgid" ]] && [[ "$agent_pgid" =~ ^[0-9]+$ ]]; then
        local shell_pgid
        shell_pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ' || echo "")
        # Guard against accidentally targeting our own process group.
        if [[ "$agent_pgid" != "$shell_pgid" ]]; then
          kill -TERM -- "-$agent_pgid" 2>/dev/null || true
          sleep 0.2
          kill -KILL -- "-$agent_pgid" 2>/dev/null || true
        fi
      fi
      kill "$agent_pid" 2>/dev/null || true
      local child_pids
      child_pids=$(pgrep -P "$agent_pid" 2>/dev/null || true)
      if [[ -n "$child_pids" ]]; then
        while IFS= read -r child; do
          kill "$child" 2>/dev/null || true
        done <<< "$child_pids"
      fi
      wait "$agent_pid" 2>/dev/null || true
    fi
    if [[ -n "$parser_pid" ]]; then
      kill "$parser_pid" 2>/dev/null || true
      wait "$parser_pid" 2>/dev/null || true
    fi
    rm -f "$fifo" "$stream_fifo"
    printf "\r\033[K" >&2
  }
  trap '_cleanup_iteration' INT TERM HUP EXIT
  
  # Create named pipe for parser signals (unique per iteration to avoid race).
  rm -f "$fifo" "$stream_fifo"
  mkfifo "$fifo"
  mkfifo "$stream_fifo"
  
  # Use stderr for display (stdout is captured for signal)
  echo "" >&2
  echo "═══════════════════════════════════════════════════════════════════" >&2
  echo "🐛 Ralph Iteration $iteration" >&2
  echo "═══════════════════════════════════════════════════════════════════" >&2
  echo "" >&2
  echo "Workspace: $workspace" >&2
  echo "Model:     $iteration_model" >&2
  echo "Monitor:   tail -f $workspace/.ralph/activity.log" >&2
  echo "" >&2
  
  # Log session start to progress.md
  log_progress "$workspace" "**Session $iteration started** (model: $iteration_model)"
  
  # Build cursor-agent command
  local cmd=(cursor-agent -p --force --output-format stream-json --model "$iteration_model")
  if [[ -n "$session_id" ]]; then
    echo "Resuming session: $session_id" >&2
    cmd+=(--resume "$session_id")
  fi
  
  # Change to workspace
  cd "$workspace" || return 1
  
  # Start spinner to show we're alive
  spinner "$workspace" &
  local spinner_pid=$!
  
  # Start parser first so cursor-agent has an active consumer for streamed output.
  "$script_dir/stream-parser.sh" "$workspace" < "$stream_fifo" > "$fifo" &
  parser_pid=$!

  # Launch cursor-agent writer. Prefer setsid so the agent gets a dedicated
  # process group that can be terminated as a unit.
  if command -v setsid >/dev/null 2>&1; then
    setsid "${cmd[@]}" "$prompt" > "$stream_fifo" 2>&1 &
  else
    "${cmd[@]}" "$prompt" > "$stream_fifo" 2>&1 &
  fi
  agent_pid=$!
  agent_pgid=$(ps -o pgid= -p "$agent_pid" 2>/dev/null | tr -d ' ' || echo "")
  
  # Read signals from parser
  local last_activity_ts now
  last_activity_ts=$(date +%s)
  while true; do
    if IFS= read -r -t 1 line < "$fifo"; then
      last_activity_ts=$(date +%s)
      case "$line" in
        "ROTATE")
          printf "\r\033[K" >&2  # Clear spinner line
          echo "🔄 Context rotation triggered - stopping agent..." >&2
          kill "$agent_pid" 2>/dev/null || true
          signal="ROTATE"
          break
          ;;
        "WARN")
          printf "\r\033[K" >&2  # Clear spinner line
          echo "⚠️  Context warning - agent should wrap up soon..." >&2
          # Send interrupt to encourage wrap-up (agent continues but is notified)
          ;;
        "GUTTER")
          printf "\r\033[K" >&2  # Clear spinner line
          echo "🚨 Gutter detected - agent may be stuck..." >&2
          signal="GUTTER"
          # Don't kill yet, let agent try to recover
          ;;
        "COMPLETE")
          printf "\r\033[K" >&2  # Clear spinner line
          echo "✅ Agent signaled completion!" >&2
          signal="COMPLETE"
          # Let agent finish gracefully
          ;;
        "DEFER")
          printf "\r\033[K" >&2  # Clear spinner line
          echo "⏸️  Rate limit or transient error - deferring for retry..." >&2
          signal="DEFER"
          # Stop the agent, will retry with backoff
          kill "$agent_pid" 2>/dev/null || true
          break
          ;;
        "NO_ACTIVITY")
          printf "\r\033[K" >&2
          echo "🚨 No activity detected (zero tool calls)." >&2
          signal="NO_ACTIVITY"
          break
          ;;
      esac
    else
      # read timed out or stream ended
      if ! kill -0 "$agent_pid" 2>/dev/null; then
        break
      fi
      now=$(date +%s)
      if [[ "$ITERATION_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] && [[ "$ITERATION_TIMEOUT_SECONDS" -gt 0 ]] && [[ $((now - last_activity_ts)) -ge "$ITERATION_TIMEOUT_SECONDS" ]]; then
        printf "\r\033[K" >&2
        echo "⏱️  Iteration timeout (${ITERATION_TIMEOUT_SECONDS}s inactivity) - rotating context..." >&2
        signal="TIMEOUT"
        kill "$agent_pid" 2>/dev/null || true
        break
      fi
    fi
  done
  
  # Wait for agent to finish
  wait "$agent_pid" 2>/dev/null || true
  
  _cleanup_iteration
  trap - INT TERM HUP EXIT
  echo "$signal"
}

# Run an optional review pass with REVIEW_MODEL.
# Returns: PASS or FAIL
run_review() {
  local workspace="$1"
  local iteration="$2"
  local execution_model="$3"
  local script_dir="${4:-$(dirname "${BASH_SOURCE[0]}")}"
  local review_file="$workspace/.ralph/review.md"
  local review_model="${REVIEW_MODEL:-}"

  if [[ -z "$review_model" ]]; then
    echo "PASS"
    return 0
  fi

  mkdir -p "$workspace/.ralph"
  : > "$review_file"

  local prompt
  prompt=$(build_review_prompt "$workspace" "$iteration" "$execution_model" "$review_model")

  echo "" >&2
  echo "🔍 Running review pass with model: $review_model" >&2

  local review_json
  local review_text=""
  local cmd=(cursor-agent -p --force --output-format stream-json --model "$review_model")
  review_json=$(
    cd "$workspace" && "${cmd[@]}" "$prompt" 2>&1
  ) || true

  if [[ -n "$review_json" ]]; then
    review_text=$(printf "%s\n" "$review_json" | jq -r '
      select(.type == "assistant")
      | .message.content[]?.text // empty
    ' 2>/dev/null || true)
  fi

  if [[ -z "$review_text" ]]; then
    review_text="Review model produced no structured assistant output.
<ralph>REVIEW_FAIL</ralph>
## Findings
- Review output could not be parsed.
## Recommended next actions
- Re-run review or inspect recent commits manually."
  fi

  {
    echo "# Review Feedback (Iteration $iteration)"
    echo ""
    echo "Execution model: \`$execution_model\`"
    echo "Review model: \`$review_model\`"
    echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "$review_text"
  } > "$review_file"

  if [[ "$review_text" == *"<ralph>REVIEW_PASS</ralph>"* ]]; then
    log_progress "$workspace" "**Review pass** - ✅ REVIEW_PASS ($review_model)"
    echo "PASS"
  else
    log_progress "$workspace" "**Review pass** - ❌ REVIEW_FAIL ($review_model)"
    echo "FAIL"
  fi
}

# =============================================================================
# MAIN LOOP
# =============================================================================

# Run the main Ralph loop
# Args: workspace
# Uses global: MAX_ITERATIONS, MODEL, USE_BRANCH, OPEN_PR
run_ralph_loop() {
  local workspace="$1"
  local script_dir="${2:-$(dirname "${BASH_SOURCE[0]}")}"
  local review_attempt_count=0
  
  # Commit any uncommitted work first
  cd "$workspace" || return 1
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "📦 Committing uncommitted changes..."
    git add -A
    git commit -m "ralph: initial commit before loop" || true
  fi
  
  # Record a rollback checkpoint so users can safely undo loop changes.
  mkdir -p "$workspace/.ralph"
  git rev-parse HEAD > "$workspace/.ralph/last_checkpoint" 2>/dev/null || true
  echo "🛟 Rollback checkpoint: $(cat "$workspace/.ralph/last_checkpoint" 2>/dev/null || echo "unknown")"
  echo "   To roll back later: git reset --hard \$(cat .ralph/last_checkpoint)"
  
  # Create branch if requested
  if [[ -n "$USE_BRANCH" ]]; then
    echo "🌿 Creating branch: $USE_BRANCH"
    git checkout -b "$USE_BRANCH" 2>/dev/null || git checkout "$USE_BRANCH"
  fi
  
  echo ""
  echo "🚀 Starting Ralph loop..."
  echo ""
  
  # Main loop
  local iteration=1
  local session_id=""
  
  while [[ $iteration -le $MAX_ITERATIONS ]]; do
    # Run iteration
    local signal
    local iteration_model
    iteration_model=$(resolve_model "$workspace")
    signal=$(run_iteration "$workspace" "$iteration" "$session_id" "$script_dir")
    
    # Check task completion
    local task_status
    task_status=$(check_task_complete "$workspace")
    
    if [[ "$task_status" == "COMPLETE" ]]; then
      if [[ -n "$REVIEW_MODEL" ]]; then
        local review_result
        review_result=$(run_review "$workspace" "$iteration" "$iteration_model" "$script_dir")
        if [[ "$review_result" != "PASS" ]]; then
          review_attempt_count=$((review_attempt_count + 1))
          if [[ $review_attempt_count -ge $MAX_REVIEW_ATTEMPTS ]]; then
            log_progress "$workspace" "**Session $iteration ended** - ⚠️ REVIEW_FAIL max attempts reached"
            echo ""
            echo "⚠️  Review failed $review_attempt_count time(s)."
            echo "   Max review attempts reached ($MAX_REVIEW_ATTEMPTS)."
            echo "   Inspect .ralph/review.md and resolve manually."
            return 1
          fi
          log_progress "$workspace" "**Session $iteration ended** - 🔁 REVIEW_FAIL, continuing iteration"
          echo ""
          echo "🔁 Review failed. Feedback written to .ralph/review.md."
          echo "   Continuing with next iteration..."
          continue
        fi
      fi
      review_attempt_count=0
      log_progress "$workspace" "**Session $iteration ended** - ✅ TASK COMPLETE"
      echo ""
      echo "═══════════════════════════════════════════════════════════════════"
      echo "🎉 RALPH COMPLETE! All criteria satisfied."
      echo "═══════════════════════════════════════════════════════════════════"
      echo ""
      echo "Completed in $iteration iteration(s)."
      echo "Check git log for detailed history."
      
      # Open PR if requested
      if [[ "$OPEN_PR" == "true" ]] && [[ -n "$USE_BRANCH" ]]; then
        echo ""
        echo "📝 Opening pull request..."
        git push -u origin "$USE_BRANCH" 2>/dev/null || git push
        if command -v gh &> /dev/null; then
          gh pr create --fill || echo "⚠️  Could not create PR automatically. Create manually."
        else
          echo "⚠️  gh CLI not found. Push complete, create PR manually."
        fi
      fi
      
      return 0
    fi
    
    # Handle signals
    case "$signal" in
      "COMPLETE")
        # Agent signaled completion - verify with checkbox check
        if [[ "$task_status" == "COMPLETE" ]]; then
          if [[ -n "$REVIEW_MODEL" ]]; then
            local review_result
            review_result=$(run_review "$workspace" "$iteration" "$iteration_model" "$script_dir")
            if [[ "$review_result" != "PASS" ]]; then
              review_attempt_count=$((review_attempt_count + 1))
              if [[ $review_attempt_count -ge $MAX_REVIEW_ATTEMPTS ]]; then
                log_progress "$workspace" "**Session $iteration ended** - ⚠️ REVIEW_FAIL max attempts reached"
                echo ""
                echo "⚠️  Review failed $review_attempt_count time(s)."
                echo "   Max review attempts reached ($MAX_REVIEW_ATTEMPTS)."
                echo "   Inspect .ralph/review.md and resolve manually."
                return 1
              fi
              log_progress "$workspace" "**Session $iteration ended** - 🔁 REVIEW_FAIL, continuing iteration"
              echo ""
              echo "🔁 Review failed. Feedback written to .ralph/review.md."
              echo "   Continuing with next iteration..."
              continue
            fi
          fi
          review_attempt_count=0
          log_progress "$workspace" "**Session $iteration ended** - ✅ TASK COMPLETE (agent signaled)"
          echo ""
          echo "═══════════════════════════════════════════════════════════════════"
          echo "🎉 RALPH COMPLETE! Agent signaled completion and all criteria verified."
          echo "═══════════════════════════════════════════════════════════════════"
          echo ""
          echo "Completed in $iteration iteration(s)."
          echo "Check git log for detailed history."
          
          # Open PR if requested
          if [[ "$OPEN_PR" == "true" ]] && [[ -n "$USE_BRANCH" ]]; then
            echo ""
            echo "📝 Opening pull request..."
            git push -u origin "$USE_BRANCH" 2>/dev/null || git push
            if command -v gh &> /dev/null; then
              gh pr create --fill || echo "⚠️  Could not create PR automatically. Create manually."
            else
              echo "⚠️  gh CLI not found. Push complete, create PR manually."
            fi
          fi
          
          return 0
        else
          # Agent said complete but checkboxes say otherwise - continue
          log_progress "$workspace" "**Session $iteration ended** - Agent signaled complete but criteria remain"
          echo ""
          echo "⚠️  Agent signaled completion but unchecked criteria remain."
          echo "   Continuing with next iteration..."
          iteration=$((iteration + 1))
        fi
        ;;
      "ROTATE")
        log_progress "$workspace" "**Session $iteration ended** - 🔄 Context rotation (token limit reached)"
        echo ""
        echo "🔄 Rotating to fresh context..."
        iteration=$((iteration + 1))
        session_id=""
        ;;
      "TIMEOUT")
        log_progress "$workspace" "**Session $iteration ended** - ⏱️ TIMEOUT (${ITERATION_TIMEOUT_SECONDS}s inactivity)"
        echo ""
        echo "⏱️  Iteration timed out due to inactivity."
        echo "   Rotating to a fresh context..."
        iteration=$((iteration + 1))
        session_id=""
        ;;
      "GUTTER")
        log_progress "$workspace" "**Session $iteration ended** - 🚨 GUTTER (agent stuck)"
        echo ""
        echo "🚨 Gutter detected. Check .ralph/errors.log for details."
        echo "   The agent may be stuck. Consider:"
        echo "   1. Check .ralph/guardrails.md for lessons"
        echo "   2. Manually fix the blocking issue"
        echo "   3. Re-run the loop"
        return 1
        ;;
      "DEFER")
        # Rate limit or transient error - wait with exponential backoff then retry
        log_progress "$workspace" "**Session $iteration ended** - ⏸️ DEFERRED (rate limit/transient error)"
        
        # Calculate backoff delay (uses ralph-retry.sh functions if available)
        local defer_delay=30
        if type calculate_backoff_delay &>/dev/null; then
          local defer_attempt=${DEFER_COUNT:-1}
          DEFER_COUNT=$((defer_attempt + 1))
          defer_delay=$(($(calculate_backoff_delay "$defer_attempt" 15 120 true) / 1000))
        fi
        
        echo ""
        echo "⏸️  Rate limit or transient error detected."
        echo "   Waiting ${defer_delay}s before retrying (attempt ${DEFER_COUNT:-1})..."
        sleep "$defer_delay"
        
        # Don't increment iteration - retry the same task
        echo "   Resuming..."
        review_attempt_count=0
        ;;
      "NO_ACTIVITY")
        log_progress "$workspace" "**Session $iteration ended** - 🚨 NO_ACTIVITY (zero tool calls)"
        echo ""
        echo "🚨 No-op iteration detected (zero tool calls)."
        echo "   Failing fast to avoid silent loops."
        return 1
        ;;
      *)
        # Agent finished naturally, check if more work needed
        if [[ "$task_status" == INCOMPLETE:* ]]; then
          local remaining_count=${task_status#INCOMPLETE:}
          log_progress "$workspace" "**Session $iteration ended** - Agent finished naturally ($remaining_count criteria remaining)"
          echo ""
          echo "📋 Agent finished but $remaining_count criteria remaining."
          echo "   Starting next iteration..."
          iteration=$((iteration + 1))
          review_attempt_count=0
        fi
        ;;
    esac
    
    # Brief pause between iterations
    sleep 2
  done
  
  log_progress "$workspace" "**Loop ended** - ⚠️ Max iterations ($MAX_ITERATIONS) reached"
  echo ""
  echo "⚠️  Max iterations ($MAX_ITERATIONS) reached."
  echo "   Task may not be complete. Check progress manually."
  return 1
}

# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================

# Check all prerequisites, exit with error message if any fail
check_prerequisites() {
  local workspace="$1"
  local task_file="$workspace/RALPH_TASK.md"
  
  # Check for task file
  if [[ ! -f "$task_file" ]]; then
    echo "❌ No RALPH_TASK.md found in $workspace"
    echo ""
    echo "Create a task file first:"
    echo "  cat > RALPH_TASK.md << 'EOF'"
    echo "  ---"
    echo "  task: Your task description"
    echo "  test_command: \"pnpm test\""
    echo "  ---"
    echo "  # Task"
    echo "  ## Success Criteria"
    echo "  1. [ ] First thing to do"
    echo "  2. [ ] Second thing to do"
    echo "  EOF"
    return 1
  fi
  
  # Check for cursor-agent CLI
  if ! command -v cursor-agent &> /dev/null; then
    echo "❌ cursor-agent CLI not found"
    echo ""
    echo "Install via:"
    echo "  curl https://cursor.com/install -fsS | bash"
    return 1
  fi
  
  # Check for git repo
  if ! git -C "$workspace" rev-parse --git-dir > /dev/null 2>&1; then
    echo "❌ Not a git repository"
    echo "   Ralph requires git for state persistence."
    return 1
  fi

  # Check available disk space (in MB, portable with POSIX df -Pm output).
  local available_mb
  available_mb=$(df -Pm "$workspace" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
  if [[ "$available_mb" =~ ^[0-9]+$ ]] && [[ "$available_mb" -lt "$MIN_DISK_MB" ]]; then
    echo "❌ Not enough free disk space (${available_mb}MB available, need ${MIN_DISK_MB}MB+)."
    return 1
  fi

  # Check available memory (best effort, Darwin + Linux).
  local available_mem_mb=0
  if [[ "$OSTYPE" == "darwin"* ]]; then
    local page_size free_pages
    page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo "4096")
    free_pages=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub("\\.","",$3); print $3}' || echo "0")
    available_mem_mb=$(( (page_size * free_pages) / 1024 / 1024 ))
  else
    available_mem_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "0")
  fi
  if [[ "$available_mem_mb" =~ ^[0-9]+$ ]] && [[ "$available_mem_mb" -lt "$MIN_MEMORY_MB" ]]; then
    echo "⚠️  Low available memory (${available_mem_mb}MB). Recommended ${MIN_MEMORY_MB}MB+."
  fi

  # Validate selected models when model listing is available.
  # cursor-agent outputs "id - Display Name" (or "id" only); match first column or whole line.
  local model_list
  model_list=$(cursor-agent --list-models 2>&1 || true)
  RALPH_MODEL_LIST_CACHE="$model_list"
  if [[ -n "$model_list" ]]; then
    if ! is_model_in_list "$model_list" "$MODEL"; then
      echo "❌ Model '$MODEL' not found in cursor-agent --list-models output."
      return 1
    fi
    if [[ -n "$REVIEW_MODEL" ]] && ! is_model_in_list "$model_list" "$REVIEW_MODEL"; then
      echo "❌ Review model '$REVIEW_MODEL' not found in cursor-agent --list-models output."
      return 1
    fi

    # Validate step-level models from task annotations.
    local step_model
    while IFS= read -r step_model; do
      [[ -z "$step_model" ]] && continue
      if ! is_model_in_list "$model_list" "$step_model"; then
        echo "⚠️  Step model '$step_model' not found; those tasks will fall back to '$MODEL'."
      fi
    done < <(list_task_models "$workspace")
  fi
  
  return 0
}

# =============================================================================
# DISPLAY HELPERS
# =============================================================================

# Show task summary
show_task_summary() {
  local workspace="$1"
  local task_file="$workspace/RALPH_TASK.md"
  
  echo "📋 Task Summary:"
  echo "─────────────────────────────────────────────────────────────────"
  head -30 "$task_file"
  echo "─────────────────────────────────────────────────────────────────"
  echo ""
  
  # Count criteria - only actual checkbox list items (- [ ], * [x], 1. [ ], etc.)
  local total_criteria done_criteria remaining
  total_criteria=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x| )\]' "$task_file" 2>/dev/null) || total_criteria=0
  done_criteria=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$task_file" 2>/dev/null) || done_criteria=0
  remaining=$((total_criteria - done_criteria))
  
  echo "Progress: $done_criteria / $total_criteria criteria complete ($remaining remaining)"
  echo "Model:    $MODEL"
  echo ""
  
  # Return remaining count for caller to check
  echo "$remaining"
}

# Show Ralph banner
show_banner() {
  echo "═══════════════════════════════════════════════════════════════════"
  echo "🐛 Ralph Wiggum: Autonomous Development Loop"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  echo "  \"That's the beauty of Ralph - the technique is deterministically"
  echo "   bad in an undeterministic world.\""
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
}
