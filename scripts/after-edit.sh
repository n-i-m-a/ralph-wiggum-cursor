#!/bin/bash
# Ralph Wiggum: After File Edit Hook
# - Uses EXTERNAL state (agent cannot tamper)
# - Logs edits for progress tracking
# - Detects attempts to edit .ralph/ files (observability)
# - Detects thrashing patterns

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ralph-common.sh"

# =============================================================================
# MAIN
# =============================================================================

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Extract file info
FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.file_path // ""')
WORKSPACE_ROOT=$(echo "$HOOK_INPUT" | jq -r '.workspace_roots[0] // "."')

# Cursor sends edits as an array with old_string/new_string
OLD_TOTAL=$(echo "$HOOK_INPUT" | jq -r '[.edits[].old_string // ""] | map(length) | add // 0')
NEW_TOTAL=$(echo "$HOOK_INPUT" | jq -r '[.edits[].new_string // ""] | map(length) | add // 0')

# Get external state directory (if Ralph is active)
EXT_DIR=$(get_ralph_external_dir "$WORKSPACE_ROOT")
if [[ ! -d "$EXT_DIR" ]]; then
  echo '{}'
  exit 0
fi

# Skip processing if agent is being terminated (mid-handoff)
if is_terminated "$EXT_DIR"; then
  echo '{}'
  exit 0
fi

# Get current iteration
CURRENT_ITERATION=$(get_iteration "$EXT_DIR")

# =============================================================================
# DETECT .ralph/ EDIT ATTEMPTS (Observability)
# =============================================================================

if [[ "$FILE_PATH" == *".ralph/"* ]]; then
  TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  
  # Log the bypass attempt
  cat >> "$EXT_DIR/failures.md" <<EOF

## ⚠️ Attempted .ralph/ Edit Detected
- File: $FILE_PATH
- Iteration: $CURRENT_ITERATION
- Time: $TIMESTAMP
- Note: State is stored externally, this edit has no effect on Ralph tracking.

EOF

  # Increment bypass counter
  BYPASS_COUNT=$(grep -c "Attempted .ralph/ Edit" "$EXT_DIR/failures.md" 2>/dev/null) || BYPASS_COUNT=0
  
  # If multiple bypass attempts, add a guardrail
  if [[ "$BYPASS_COUNT" -ge 2 ]]; then
    if ! grep -q "Sign: Don't Edit State Files" "$EXT_DIR/guardrails.md" 2>/dev/null; then
      cat >> "$EXT_DIR/guardrails.md" <<EOF

### Sign: Don't Edit State Files
- **Trigger**: Attempting to edit .ralph/ files
- **Instruction**: State is managed externally. Editing .ralph/ has no effect. Focus on the task.
- **Added after**: Iteration $CURRENT_ITERATION - Multiple bypass attempts

EOF
    fi
  fi
  
  echo '{}'
  exit 0
fi

# =============================================================================
# CALCULATE CHANGE
# =============================================================================

CHANGE_SIZE=$((NEW_TOTAL - OLD_TOTAL))

if [[ $CHANGE_SIZE -lt 0 ]]; then
  CHANGE_SIZE=$((-CHANGE_SIZE))
  CHANGE_TYPE="removed"
elif [[ $CHANGE_SIZE -eq 0 ]] && [[ $NEW_TOTAL -gt 0 ]]; then
  CHANGE_SIZE=$NEW_TOTAL
  CHANGE_TYPE="modified"
elif [[ $CHANGE_SIZE -gt 0 ]]; then
  CHANGE_TYPE="added"
else
  echo '{}'
  exit 0
fi

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TIME_SHORT=$(date -u +%H:%M:%S)
FILENAME=$(basename "$FILE_PATH")

# =============================================================================
# LOG TO EXTERNAL STATE
# =============================================================================

# Append to edits log
echo "$TIMESTAMP | $FILENAME | $CHANGE_TYPE | $CHANGE_SIZE chars | iter $CURRENT_ITERATION" >> "$EXT_DIR/edits.log"

# Append to progress (skip noise from very small edits)
if [[ $CHANGE_SIZE -gt 50 ]]; then
  cat >> "$EXT_DIR/progress.md" <<EOF

**[$TIME_SHORT]** Edited \`$FILENAME\` ($CHANGE_SIZE chars $CHANGE_TYPE)
EOF
fi

# =============================================================================
# CHECK FOR THRASHING PATTERNS
# =============================================================================

EDIT_COUNT=$(grep -c "| $FILENAME |" "$EXT_DIR/edits.log" 2>/dev/null) || EDIT_COUNT=0

if [[ "$EDIT_COUNT" -gt 5 ]]; then
  cat >> "$EXT_DIR/failures.md" <<EOF

## Potential Thrashing Detected
- File: $FILENAME
- Edits in session: $EDIT_COUNT
- Iteration: $CURRENT_ITERATION
- Time: $TIMESTAMP

EOF

  THRASH_COUNT=$(grep -c "Potential Thrashing" "$EXT_DIR/failures.md" 2>/dev/null) || THRASH_COUNT=0
  sedi "s/Repeated failures: [0-9]*/Repeated failures: $THRASH_COUNT/" "$EXT_DIR/failures.md"
  
  if [[ "$THRASH_COUNT" -gt 2 ]]; then
    sedi "s/Gutter risk: .*/Gutter risk: HIGH/" "$EXT_DIR/failures.md"
  fi
fi

echo '{}'
exit 0
