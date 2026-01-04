#!/bin/bash
# Ralph Wiggum: Before Prompt Hook
# - Uses EXTERNAL state (agent cannot tamper)
# - Turn-based context tracking (more reliable than file reads)
# - Hard termination check (blocks if terminated flag set)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ralph-common.sh"

# =============================================================================
# MAIN
# =============================================================================

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Extract workspace root
WORKSPACE_ROOT=$(echo "$HOOK_INPUT" | jq -r '.workspace_roots[0] // .cwd // "."')

if [[ "$WORKSPACE_ROOT" == "." ]] || [[ -z "$WORKSPACE_ROOT" ]]; then
  # Try to find RALPH_TASK.md
  if [[ -f "./RALPH_TASK.md" ]]; then
    WORKSPACE_ROOT="$(pwd)"
  else
    # No Ralph task - allow prompt to continue
    echo '{"continue": true}'
    exit 0
  fi
fi

TASK_FILE="$WORKSPACE_ROOT/RALPH_TASK.md"

# Check if Ralph is active (task file exists)
if [[ ! -f "$TASK_FILE" ]]; then
  # No Ralph task - allow prompt to continue
  echo '{"continue": true}'
  exit 0
fi

# =============================================================================
# EXTERNAL STATE INITIALIZATION
# =============================================================================

EXT_DIR=$(init_external_state "$WORKSPACE_ROOT")

# =============================================================================
# HARD TERMINATION CHECK
# =============================================================================

if is_terminated "$EXT_DIR"; then
  REASON=$(cat "$EXT_DIR/.terminated" 2>/dev/null || echo "unknown")
  CURRENT_ITER=$(get_iteration "$EXT_DIR")
  
  jq -n \
    --argjson iter "$CURRENT_ITER" \
    --arg reason "$REASON" \
    '{
      "continue": false,
      "user_message": ("🛑 Ralph: Conversation terminated (" + $reason + "). Start a NEW conversation: \"Continue Ralph from iteration " + ($iter|tostring) + "\"")
    }'
  exit 0
fi

# =============================================================================
# INCREMENT TURN AND CHECK CONTEXT
# =============================================================================

CURRENT_ITER=$(get_iteration "$EXT_DIR")
ESTIMATED_TOKENS=$(increment_turn "$EXT_DIR")
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Log the turn
echo "| $(($(get_turn_count "$EXT_DIR"))) | $ESTIMATED_TOKENS | $TIMESTAMP |" >> "$EXT_DIR/context-log.md"

# =============================================================================
# BLOCK IF CONTEXT LIMIT REACHED
# =============================================================================

if [[ "$ESTIMATED_TOKENS" -ge "$THRESHOLD" ]]; then
  # Set terminated flag BEFORE responding
  set_terminated "$EXT_DIR" "context_limit_$ESTIMATED_TOKENS"
  
  NEXT_ITER=$((CURRENT_ITER + 1))
  
  jq -n \
    --argjson tokens "$ESTIMATED_TOKENS" \
    --argjson threshold "$THRESHOLD" \
    --argjson iter "$NEXT_ITER" \
    '{
      "continue": false,
      "user_message": ("🛑 Ralph: Context limit reached (" + ($tokens|tostring) + "/" + ($threshold|tostring) + " tokens). Cloud Agent will be spawned. If not, start NEW conversation: \"Continue Ralph from iteration " + ($iter|tostring) + "\"")
    }'
  exit 0
fi

# =============================================================================
# INCREMENT ITERATION ON FIRST TURN OF SESSION
# =============================================================================

TURN_COUNT=$(get_turn_count "$EXT_DIR")
if [[ "$TURN_COUNT" -eq 1 ]]; then
  # First turn of this session - increment iteration
  CURRENT_ITER=$(increment_iteration "$EXT_DIR")
  
  # Log to progress
  cat >> "$EXT_DIR/progress.md" <<EOF

---

### 🔄 Iteration $CURRENT_ITER Started
**Time:** $TIMESTAMP
**Workspace:** $WORKSPACE_ROOT

EOF
fi

# =============================================================================
# BUILD AGENT MESSAGE
# =============================================================================

# Get test command from task file
TEST_COMMAND=""
if grep -q "^test_command:" "$TASK_FILE" 2>/dev/null; then
  TEST_COMMAND=$(grep "^test_command:" "$TASK_FILE" | sed 's/test_command: *//' | sed 's/^["'"'"']//' | sed 's/["'"'"']$//' | xargs)
fi

# Get guardrails
GUARDRAILS=""
if [[ -f "$EXT_DIR/guardrails.md" ]]; then
  GUARDRAILS=$(sed -n '/## Learned Signs/,$ p' "$EXT_DIR/guardrails.md" | tail -n +3)
fi

# Get last test output
LAST_TEST_OUTPUT=""
if [[ -f "$EXT_DIR/.last_test_output" ]]; then
  LAST_TEST_OUTPUT=$(head -30 "$EXT_DIR/.last_test_output")
fi

# Build context warning if needed
CONTEXT_WARNING=""
if [[ "$ESTIMATED_TOKENS" -ge "$WARN_THRESHOLD" ]]; then
  REMAINING=$((THRESHOLD - ESTIMATED_TOKENS))
  PERCENT=$((ESTIMATED_TOKENS * 100 / THRESHOLD))
  CONTEXT_WARNING="⚠️ **CONTEXT WARNING**: ${PERCENT}% used (~${ESTIMATED_TOKENS}/${THRESHOLD} tokens). Work efficiently - context limit approaching!"
fi

# Build the message
AGENT_MSG="🔄 **Ralph Iteration $CURRENT_ITER** (Turn $TURN_COUNT)

$CONTEXT_WARNING

## Your Task
Read RALPH_TASK.md for the task description and completion criteria.

## Key Files
- \`RALPH_TASK.md\` - Task definition and checklist
- Check off completed criteria with [x]"

if [[ -n "$TEST_COMMAND" ]]; then
  AGENT_MSG="$AGENT_MSG

## ⚠️ Test-Driven Completion
**Test command:** \`$TEST_COMMAND\`

Run tests after changes. Task is NOT complete until tests pass."

  if [[ -n "$LAST_TEST_OUTPUT" ]]; then
    AGENT_MSG="$AGENT_MSG

### Last Test Output:
\`\`\`
$LAST_TEST_OUTPUT
\`\`\`"
  fi
fi

AGENT_MSG="$AGENT_MSG

## Ralph Protocol
1. Work on the next unchecked criterion
2. Run tests after changes
3. Check off completed criteria [x]
4. Commit frequently
5. When ALL criteria pass tests: say \`RALPH_COMPLETE\`

$GUARDRAILS"

# Output: continue=true + agent_message (undocumented but works for injecting context)
jq -n \
  --arg msg "$AGENT_MSG" \
  '{
    "continue": true,
    "agent_message": $msg
  }'

exit 0
