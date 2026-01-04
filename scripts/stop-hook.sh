#!/bin/bash
# Ralph Wiggum: Stop Hook
# Manages iteration completion and context lifecycle (malloc/free)
#
# TWO MODES:
# - Cloud Mode (True Ralph): Automatically spawns Cloud Agent with fresh context
# - Local Mode (Assisted Ralph): Instructs human to start new conversation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Extract workspace root
WORKSPACE_ROOT=$(echo "$HOOK_INPUT" | jq -r '.workspace_roots[0] // "."')
RALPH_DIR="$WORKSPACE_ROOT/.ralph"
STATE_FILE="$RALPH_DIR/state.md"
TASK_FILE="$WORKSPACE_ROOT/RALPH_TASK.md"
PROGRESS_FILE="$RALPH_DIR/progress.md"
FAILURES_FILE="$RALPH_DIR/failures.md"
GUARDRAILS_FILE="$RALPH_DIR/guardrails.md"
CONTEXT_LOG="$RALPH_DIR/context-log.md"
CONFIG_FILE="$WORKSPACE_ROOT/.cursor/ralph-config.json"

# If Ralph isn't active, allow exit
if [[ ! -f "$TASK_FILE" ]] || [[ ! -d "$RALPH_DIR" ]]; then
  exit 0
fi

# Check if Cloud Agent mode is enabled
is_cloud_enabled() {
  # Check environment variable
  if [[ -n "${CURSOR_API_KEY:-}" ]]; then
    return 0
  fi
  
  # Check project config
  if [[ -f "$CONFIG_FILE" ]]; then
    ENABLED=$(jq -r '.cloud_agent_enabled // false' "$CONFIG_FILE" 2>/dev/null)
    KEY=$(jq -r '.cursor_api_key // empty' "$CONFIG_FILE" 2>/dev/null)
    if [[ "$ENABLED" == "true" ]] && [[ -n "$KEY" ]]; then
      return 0
    fi
  fi
  
  # Check global config
  GLOBAL_CONFIG="$HOME/.cursor/ralph-config.json"
  if [[ -f "$GLOBAL_CONFIG" ]]; then
    KEY=$(jq -r '.cursor_api_key // empty' "$GLOBAL_CONFIG" 2>/dev/null)
    if [[ -n "$KEY" ]]; then
      return 0
    fi
  fi
  
  return 1
}

# Get transcript path and read last output
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // ""')

LAST_OUTPUT=""
if [[ -n "$TRANSCRIPT_PATH" ]] && [[ -f "$TRANSCRIPT_PATH" ]]; then
  if grep -q '"role":"assistant"' "$TRANSCRIPT_PATH"; then
    LAST_LINE=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -1)
    LAST_OUTPUT=$(echo "$LAST_LINE" | jq -r '
      .message.content |
      map(select(.type == "text")) |
      map(.text) |
      join("\n")
    ' 2>/dev/null || echo "")
  fi
fi

# Get current state
CURRENT_ITERATION=$(grep '^iteration:' "$STATE_FILE" | sed 's/iteration: *//' || echo "0")

# Extract max iterations from task file
MAX_ITERATIONS=$(grep '^max_iterations:' "$TASK_FILE" | sed 's/max_iterations: *//' || echo "0")

# =============================================================================
# CHECK FOR COMPLETION SIGNALS
# =============================================================================

# Check for completion signal
if echo "$LAST_OUTPUT" | grep -q "RALPH_COMPLETE"; then
  echo "✅ Ralph: Task completed after $CURRENT_ITERATION iterations!"
  
  sed -i "s/^status: .*/status: completed/" "$STATE_FILE"
  
  cat >> "$PROGRESS_FILE" <<EOF

---

## 🎉 TASK COMPLETED

- Total iterations: $CURRENT_ITERATION
- Completed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Mode: $(is_cloud_enabled && echo "Cloud" || echo "Local")

EOF

  exit 0
fi

# Check for gutter signal
if echo "$LAST_OUTPUT" | grep -q "RALPH_GUTTER"; then
  echo "🚨 Ralph: Gutter detected! Agent is stuck."
  echo ""
  echo "The agent has identified it's in a failure loop."
  echo "Progress saved in .ralph/progress.md"
  echo ""
  echo "Recommended: Review the task and guardrails, then restart."
  
  sed -i "s/^status: .*/status: gutter_detected/" "$STATE_FILE"
  
  exit 0
fi

# Check max iterations
if [[ "$MAX_ITERATIONS" -gt 0 ]] && [[ "$CURRENT_ITERATION" -ge "$MAX_ITERATIONS" ]]; then
  echo "🛑 Ralph: Max iterations ($MAX_ITERATIONS) reached."
  echo ""
  echo "Progress saved in .ralph/progress.md"
  echo "To continue, increase max_iterations in RALPH_TASK.md"
  
  sed -i "s/^status: .*/status: max_iterations_reached/" "$STATE_FILE"
  
  exit 0
fi

# =============================================================================
# CHECK CONTEXT HEALTH (malloc tracking)
# =============================================================================

CONTEXT_CRITICAL=false
GUTTER_RISK_HIGH=false

# Check context health
if [[ -f "$CONTEXT_LOG" ]]; then
  CONTEXT_STATUS=$(grep 'Status:' "$CONTEXT_LOG" | head -1 || echo "")
  if echo "$CONTEXT_STATUS" | grep -q "Critical"; then
    CONTEXT_CRITICAL=true
  fi
fi

# Check gutter risk from failures
if [[ -f "$FAILURES_FILE" ]]; then
  GUTTER_RISK=$(grep 'Gutter risk:' "$FAILURES_FILE" | sed 's/.*Gutter risk: //' || echo "Low")
  if [[ "$GUTTER_RISK" == "HIGH" ]]; then
    GUTTER_RISK_HIGH=true
  fi
fi

# =============================================================================
# HANDLE CONTEXT LIMIT (malloc/free decision)
# =============================================================================

if [[ "$CONTEXT_CRITICAL" == "true" ]] || [[ "$GUTTER_RISK_HIGH" == "true" ]]; then
  
  echo "═══════════════════════════════════════════════════════════════════"
  echo "⚠️  RALPH: CONTEXT LIMIT REACHED (malloc full)"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  
  if [[ "$CONTEXT_CRITICAL" == "true" ]]; then
    echo "Reason: Context window is critically full"
  fi
  if [[ "$GUTTER_RISK_HIGH" == "true" ]]; then
    echo "Reason: High gutter risk (repeated failure patterns)"
  fi
  echo ""
  
  # Try Cloud Mode first
  if is_cloud_enabled; then
    echo "🚀 CLOUD MODE: Spawning new Cloud Agent with fresh context..."
    echo ""
    
    if "$SCRIPT_DIR/spawn-cloud-agent.sh" "$WORKSPACE_ROOT"; then
      # Cloud agent spawned successfully
      echo ""
      echo "═══════════════════════════════════════════════════════════════════"
      echo "✅ Context freed! Cloud Agent continuing with fresh malloc."
      echo "═══════════════════════════════════════════════════════════════════"
      
      # Allow exit - Cloud Agent takes over
      exit 0
    else
      echo ""
      echo "⚠️  Cloud Agent spawn failed. Falling back to Local Mode."
      echo ""
    fi
  fi
  
  # Local Mode - Human in the loop
  echo "═══════════════════════════════════════════════════════════════════"
  echo "📋 LOCAL MODE: Human action required to free context"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  echo "To continue with fresh context (complete the malloc/free cycle):"
  echo ""
  echo "  1. Your progress is saved in .ralph/progress.md"
  echo "  2. START A NEW CONVERSATION in Cursor"
  echo "  3. Tell Cursor: 'Continue the Ralph task from iteration $CURRENT_ITERATION'"
  echo ""
  echo "The new conversation = fresh context = malloc freed"
  echo ""
  echo "Why this matters:"
  echo "  - LLM context is like memory: once allocated, it can't be freed"
  echo "  - The only way to 'free' context is to start a new conversation"
  echo "  - Your progress persists in FILES, not in context"
  echo ""
  
  if ! is_cloud_enabled; then
    echo "💡 TIP: Enable Cloud Mode for automatic context management"
    echo "   Set CURSOR_API_KEY or add to .cursor/ralph-config.json"
    echo "   Get your key: https://cursor.com/dashboard?tab=integrations"
    echo ""
  fi
  
  echo "═══════════════════════════════════════════════════════════════════"
  
  # Update state
  sed -i "s/^status: .*/status: awaiting_fresh_context/" "$STATE_FILE"
  
  # Log the pause
  cat >> "$PROGRESS_FILE" <<EOF

---

## ⏸️ Context Limit Reached (Iteration $CURRENT_ITERATION)

- Time: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Reason: $(if [[ "$CONTEXT_CRITICAL" == "true" ]]; then echo "Context critically full"; else echo "High gutter risk"; fi)
- Mode: Local (human-in-the-loop)
- Action needed: Start new conversation to free context

EOF

  # Allow exit - human needs to start new conversation
  exit 0
fi

# =============================================================================
# NORMAL ITERATION CONTINUE (context still healthy)
# =============================================================================

NEXT_ITERATION=$((CURRENT_ITERATION + 1))

# Check for failure patterns to add as guardrails
if [[ -f "$FAILURES_FILE" ]]; then
  RECENT_FAILURES=$(tail -20 "$FAILURES_FILE")
  
  if echo "$RECENT_FAILURES" | grep -q "Potential Thrashing"; then
    THRASH_FILE=$(echo "$RECENT_FAILURES" | grep "File:" | tail -1 | sed 's/.*File: //')
    
    if [[ -n "$THRASH_FILE" ]]; then
      cat >> "$GUARDRAILS_FILE" <<EOF

### Sign: Careful with $THRASH_FILE
- **Added**: Iteration $CURRENT_ITERATION
- **Reason**: Detected repeated edits without clear progress
- **Instruction**: Before editing this file again, step back and reconsider the approach

EOF
    fi
  fi
fi

# Update progress with iteration summary
cat >> "$PROGRESS_FILE" <<EOF

---

## Iteration $CURRENT_ITERATION Summary
- Ended: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Context status: Healthy
- Status: Continuing to iteration $NEXT_ITERATION

EOF

# Read the task body for continuation
TASK_BODY=$(awk '/^---$/{i++; next} i>=2' "$TASK_FILE")

# Build the continuation prompt
SYSTEM_MSG="🔄 Ralph Iteration $NEXT_ITERATION (same context)

## Continue Working

Read .ralph/progress.md to see what was accomplished.
Check .ralph/guardrails.md for any new signs added.

## Context Status
- Allocated: $(grep 'Allocated:' "$CONTEXT_LOG" 2>/dev/null | grep -oP '\d+' || echo "unknown") tokens
- Status: Healthy (continuing in same context)

## Reminders
- Update progress.md with your work
- Commit checkpoints frequently
- Say RALPH_COMPLETE when ALL criteria in RALPH_TASK.md are met
- Say RALPH_GUTTER if stuck on the same issue repeatedly"

# Output JSON to block exit and continue
jq -n \
  --arg prompt "$TASK_BODY" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'

exit 0
