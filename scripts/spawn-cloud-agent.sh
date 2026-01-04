#!/bin/bash
# Ralph Wiggum: Spawn Cloud Agent for True malloc/free
# This script spawns a new Cloud Agent with fresh context to continue the Ralph task

set -euo pipefail

WORKSPACE_ROOT="${1:-.}"
RALPH_DIR="$WORKSPACE_ROOT/.ralph"
STATE_FILE="$RALPH_DIR/state.md"
CONFIG_FILE="$WORKSPACE_ROOT/.cursor/ralph-config.json"
GLOBAL_CONFIG="$HOME/.cursor/ralph-config.json"

# Get API key from config or environment
get_api_key() {
  # 1. Environment variable (highest priority)
  if [[ -n "${CURSOR_API_KEY:-}" ]]; then
    echo "$CURSOR_API_KEY"
    return 0
  fi
  
  # 2. Project config
  if [[ -f "$CONFIG_FILE" ]]; then
    KEY=$(jq -r '.cursor_api_key // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [[ -n "$KEY" ]]; then
      echo "$KEY"
      return 0
    fi
  fi
  
  # 3. Global config
  if [[ -f "$GLOBAL_CONFIG" ]]; then
    KEY=$(jq -r '.cursor_api_key // empty' "$GLOBAL_CONFIG" 2>/dev/null || echo "")
    if [[ -n "$KEY" ]]; then
      echo "$KEY"
      return 0
    fi
  fi
  
  return 1
}

# Get repository URL from git
get_repo_url() {
  cd "$WORKSPACE_ROOT"
  git remote get-url origin 2>/dev/null | sed 's/\.git$//' | sed 's|git@github.com:|https://github.com/|'
}

# Get current branch
get_current_branch() {
  cd "$WORKSPACE_ROOT"
  git branch --show-current 2>/dev/null || echo "main"
}

# Main execution
main() {
  # Check for API key
  API_KEY=$(get_api_key) || {
    echo "❌ Cloud Agent integration not configured."
    echo ""
    echo "To enable True Ralph (automatic fresh context), configure your Cursor API key:"
    echo ""
    echo "Option 1: Environment variable"
    echo "  export CURSOR_API_KEY='your-key-here'"
    echo ""
    echo "Option 2: Project config (.cursor/ralph-config.json)"
    echo '  { "cursor_api_key": "your-key-here", "cloud_agent_enabled": true }'
    echo ""
    echo "Option 3: Global config (~/.cursor/ralph-config.json)"
    echo '  { "cursor_api_key": "your-key-here" }'
    echo ""
    echo "Get your API key from: https://cursor.com/dashboard?tab=integrations"
    return 1
  }
  
  # Get repo info
  REPO_URL=$(get_repo_url) || {
    echo "❌ Could not determine repository URL."
    echo "   Cloud Agents require a GitHub repository."
    return 1
  }
  
  CURRENT_BRANCH=$(get_current_branch)
  
  # Get current iteration
  CURRENT_ITERATION=$(grep '^iteration:' "$STATE_FILE" 2>/dev/null | sed 's/iteration: *//' || echo "0")
  NEXT_ITERATION=$((CURRENT_ITERATION + 1))
  
  # Commit current state before spawning cloud agent
  cd "$WORKSPACE_ROOT"
  if [[ -n "$(git status --porcelain)" ]]; then
    git add -A
    git commit -m "Ralph iteration $CURRENT_ITERATION checkpoint (before cloud handoff)"
    git push origin "$CURRENT_BRANCH" 2>/dev/null || {
      echo "⚠️  Could not push to remote. Cloud Agent may not see latest changes."
    }
  fi
  
  # Build the continuation prompt
  CONTINUATION_PROMPT="# Ralph Iteration $NEXT_ITERATION (Cloud Agent - Fresh Context)

You are continuing a Ralph Wiggum autonomous development task.

## CRITICAL: Read State Files First

1. Read \`RALPH_TASK.md\` for the full task definition and completion criteria
2. Read \`.ralph/progress.md\` to see what has been accomplished in previous iterations
3. Read \`.ralph/guardrails.md\` for 'signs' (lessons learned from previous failures)

## Your Mission

Continue working on the task from where the previous iteration left off.
The previous iteration ended because context was getting full (malloc limit reached).
You have FRESH CONTEXT - use it wisely.

## Ralph Protocol

1. Check progress.md for what's done
2. Work on the NEXT incomplete item from RALPH_TASK.md
3. Follow all signs in guardrails.md
4. Update progress.md with your accomplishments
5. Commit your changes frequently with descriptive messages
6. When ALL completion criteria are met, add to progress.md: 'RALPH_COMPLETE: All criteria satisfied'
7. If stuck on the same issue 3+ times, add: 'RALPH_GUTTER: Need human intervention'

## Context Management

You have fresh context. Be efficient:
- Only read files you need
- Don't load unnecessary history
- Focus on the current task

Begin by reading the state files, then continue the work."

  # Create the Cloud Agent
  echo "🚀 Spawning Cloud Agent for iteration $NEXT_ITERATION..."
  echo ""
  
  RESPONSE=$(curl -s -X POST "https://api.cursor.com/v0/agents" \
    -u "$API_KEY:" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg prompt "$CONTINUATION_PROMPT" \
      --arg repo "$REPO_URL" \
      --arg ref "$CURRENT_BRANCH" \
      --arg branch "ralph-iteration-$NEXT_ITERATION" \
      '{
        "prompt": { "text": $prompt },
        "source": {
          "repository": $repo,
          "ref": $ref
        },
        "target": {
          "branchName": $branch,
          "autoCreatePr": false
        }
      }'
    )")
  
  # Check response
  AGENT_ID=$(echo "$RESPONSE" | jq -r '.id // empty')
  
  if [[ -n "$AGENT_ID" ]]; then
    AGENT_URL=$(echo "$RESPONSE" | jq -r '.target.url // empty')
    
    echo "✅ Cloud Agent spawned successfully!"
    echo ""
    echo "   Agent ID: $AGENT_ID"
    echo "   Branch: ralph-iteration-$NEXT_ITERATION"
    echo "   Monitor: $AGENT_URL"
    echo ""
    echo "The Cloud Agent is now working with FRESH CONTEXT."
    echo "Your local context has been freed (malloc → free cycle complete)."
    echo ""
    echo "You can:"
    echo "  - Monitor progress at the URL above"
    echo "  - Send follow-ups via the Cursor dashboard"
    echo "  - Take over the agent at any time"
    
    # Log the handoff
    cat >> "$RALPH_DIR/progress.md" <<EOF

---

## 🚀 Cloud Agent Handoff

- Local iteration: $CURRENT_ITERATION
- Cloud iteration: $NEXT_ITERATION
- Agent ID: $AGENT_ID
- Branch: ralph-iteration-$NEXT_ITERATION
- Reason: Context malloc limit reached
- Time: $(date -u +%Y-%m-%dT%H:%M:%SZ)

Context has been freed. Cloud Agent continuing with fresh context.

EOF
    
    return 0
  else
    ERROR=$(echo "$RESPONSE" | jq -r '.error // .message // "Unknown error"')
    echo "❌ Failed to spawn Cloud Agent"
    echo "   Error: $ERROR"
    echo ""
    echo "Falling back to Local Mode."
    echo "Please start a new conversation manually to free context."
    return 1
  fi
}

main "$@"
