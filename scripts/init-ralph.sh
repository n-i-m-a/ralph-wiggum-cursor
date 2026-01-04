#!/bin/bash
# Ralph Wiggum: Initialize Ralph in a project
# Sets up Ralph tracking and optionally configures Cloud Agent integration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

echo "═══════════════════════════════════════════════════════════════════"
echo "🐛 Ralph Wiggum Initialization"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Check if we're in a git repo
if ! git rev-parse --git-dir > /dev/null 2>&1; then
  echo "⚠️  Warning: Not in a git repository."
  echo "   Ralph works best with git for checkpoint tracking."
  echo "   Cloud Mode REQUIRES a GitHub repository."
  echo ""
  read -p "Continue anyway? [y/N] " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

# Create directories
mkdir -p .ralph
mkdir -p .cursor/ralph-scripts

# =============================================================================
# EXPLAIN THE TWO MODES
# =============================================================================

echo "Ralph has two modes for handling context (malloc/free):"
echo ""
echo "┌─────────────────────────────────────────────────────────────────┐"
echo "│ 🌩️  CLOUD MODE (True Ralph)                                     │"
echo "├─────────────────────────────────────────────────────────────────┤"
echo "│ • Automatic fresh context via Cloud Agent API                  │"
echo "│ • When context fills up, spawns new Cloud Agent automatically  │"
echo "│ • True malloc/free cycle - fully autonomous                    │"
echo "│ • Requires: Cursor API key + GitHub repository                 │"
echo "└─────────────────────────────────────────────────────────────────┘"
echo ""
echo "┌─────────────────────────────────────────────────────────────────┐"
echo "│ 💻 LOCAL MODE (Assisted Ralph)                                  │"
echo "├─────────────────────────────────────────────────────────────────┤"
echo "│ • Hooks detect when context is full                            │"
echo "│ • Instructs YOU to start a new conversation                    │"
echo "│ • Human-in-the-loop malloc/free cycle                          │"
echo "│ • Works without API key, works with local repos                │"
echo "└─────────────────────────────────────────────────────────────────┘"
echo ""

# =============================================================================
# CLOUD MODE CONFIGURATION
# =============================================================================

CLOUD_ENABLED=false
API_KEY=""

# Check for existing API key
if [[ -n "${CURSOR_API_KEY:-}" ]]; then
  echo "✓ Found CURSOR_API_KEY in environment"
  CLOUD_ENABLED=true
elif [[ -f "$HOME/.cursor/ralph-config.json" ]]; then
  EXISTING_KEY=$(jq -r '.cursor_api_key // empty' "$HOME/.cursor/ralph-config.json" 2>/dev/null || echo "")
  if [[ -n "$EXISTING_KEY" ]]; then
    echo "✓ Found API key in global config (~/.cursor/ralph-config.json)"
    CLOUD_ENABLED=true
  fi
fi

if [[ "$CLOUD_ENABLED" == "false" ]]; then
  echo ""
  read -p "Enable Cloud Mode? (requires Cursor API key) [y/N] " -n 1 -r
  echo
  
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "Get your API key from: https://cursor.com/dashboard?tab=integrations"
    echo ""
    read -p "Enter your Cursor API key (or press Enter to skip): " API_KEY
    
    if [[ -n "$API_KEY" ]]; then
      # Ask where to store it
      echo ""
      echo "Where should the API key be stored?"
      echo "  1) Project only (.cursor/ralph-config.json) - gitignored"
      echo "  2) Global (~/.cursor/ralph-config.json) - available in all projects"
      read -p "Choice [1/2]: " -n 1 -r STORAGE_CHOICE
      echo
      
      if [[ "$STORAGE_CHOICE" == "2" ]]; then
        mkdir -p "$HOME/.cursor"
        echo "{\"cursor_api_key\": \"$API_KEY\"}" | jq '.' > "$HOME/.cursor/ralph-config.json"
        echo "✓ API key saved to ~/.cursor/ralph-config.json"
      else
        echo "{\"cursor_api_key\": \"$API_KEY\", \"cloud_agent_enabled\": true}" | jq '.' > .cursor/ralph-config.json
        echo "✓ API key saved to .cursor/ralph-config.json"
      fi
      
      CLOUD_ENABLED=true
    fi
  fi
fi

echo ""

# =============================================================================
# CREATE RALPH_TASK.md IF NOT EXISTS
# =============================================================================

if [[ ! -f "RALPH_TASK.md" ]]; then
  echo "📝 Creating RALPH_TASK.md template..."
  cp "$SKILL_DIR/assets/RALPH_TASK_TEMPLATE.md" RALPH_TASK.md
  echo "   Edit RALPH_TASK.md to define your task."
else
  echo "✓ RALPH_TASK.md already exists"
fi

# =============================================================================
# INITIALIZE STATE FILES
# =============================================================================

echo "📁 Initializing .ralph/ directory..."

cat > .ralph/state.md <<EOF
---
iteration: 0
status: initialized
mode: $(if [[ "$CLOUD_ENABLED" == "true" ]]; then echo "cloud"; else echo "local"; fi)
started_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
---

# Ralph State

Ready to begin. Start a conversation and mention the Ralph task.

## Mode

$(if [[ "$CLOUD_ENABLED" == "true" ]]; then
  echo "**Cloud Mode (True Ralph)**: Automatic fresh context via Cloud Agent API"
else
  echo "**Local Mode (Assisted Ralph)**: Human-triggered fresh context"
fi)
EOF

cat > .ralph/guardrails.md <<EOF
# Ralph Guardrails (Signs)

These are lessons learned from iterations. Follow these to avoid known pitfalls.

## Core Signs

### Sign: Read Before Writing
- **Always** read existing files before modifying them
- Check git history for context on why things are the way they are

### Sign: Test After Changes
- Run tests after every significant change
- Don't assume code works - verify it

### Sign: Commit Checkpoints
- Commit working states before attempting risky changes
- Use descriptive commit messages

### Sign: One Thing at a Time
- Focus on one criterion at a time
- Don't try to do everything in one iteration

### Sign: Update Progress
- Always update .ralph/progress.md with what you accomplished
- This is how future iterations (and fresh contexts) know what's done

---

## Learned Signs

(Signs added from observed failures will appear below)

EOF

cat > .ralph/context-log.md <<EOF
# Context Allocation Log

Tracking what's been loaded into context to prevent redlining.

## The malloc/free Metaphor

- Reading files = malloc() into context
- There is NO free() - context cannot be selectively cleared
- Only way to free: start a new conversation (Cloud Mode does this automatically)

## Current Session

| File | Size (est tokens) | Timestamp |
|------|-------------------|-----------|

## Estimated Context Usage

- Allocated: 0 tokens
- Threshold: 80000 tokens (warn at 80%)
- Status: 🟢 Healthy

## Mode

$(if [[ "$CLOUD_ENABLED" == "true" ]]; then
  echo "Cloud Mode: When critical, will automatically spawn Cloud Agent with fresh context"
else
  echo "Local Mode: When critical, will instruct you to start a new conversation"
fi)
EOF

cat > .ralph/failures.md <<EOF
# Failure Log

Tracking failure patterns to detect "gutter" situations.

## What is the Gutter?

> "If the bowling ball is in the gutter, there's no saving it."

When the agent is stuck in a failure loop, it's "in the gutter."
The solution is fresh context, not more attempts in polluted context.

## Recent Failures

(Failures will be logged here)

## Pattern Detection

- Repeated failures: 0
- Gutter risk: Low

EOF

cat > .ralph/progress.md <<EOF
# Progress Log

## Summary

- Iterations completed: 0
- Tasks completed: 0
- Current status: Initialized
- Mode: $(if [[ "$CLOUD_ENABLED" == "true" ]]; then echo "Cloud (True Ralph)"; else echo "Local (Assisted Ralph)"; fi)

## How This Works

Progress is tracked in THIS FILE, not in LLM context.
When context is freed (new conversation), the new context reads this file.
This is how Ralph maintains continuity across the malloc/free cycle.

## Iteration History

(Progress will be logged here as iterations complete)

EOF

# =============================================================================
# INSTALL HOOKS
# =============================================================================

echo "📦 Installing hooks and scripts..."

# Copy hooks.json
cp "$SKILL_DIR/hooks.json" .cursor/hooks.json

# Copy scripts
cp "$SKILL_DIR/scripts/"*.sh .cursor/ralph-scripts/
chmod +x .cursor/ralph-scripts/*.sh

# Update hooks.json to point to local scripts
sed -i 's|./scripts/|./.cursor/ralph-scripts/|g' .cursor/hooks.json

echo "✓ Hooks installed to .cursor/"

# =============================================================================
# UPDATE .gitignore
# =============================================================================

if [[ -f ".gitignore" ]]; then
  if ! grep -q "^\.ralph/" .gitignore; then
    echo "" >> .gitignore
    echo "# Ralph state (regenerated each session)" >> .gitignore
    echo ".ralph/" >> .gitignore
  fi
  if ! grep -q "ralph-config.json" .gitignore; then
    echo "" >> .gitignore
    echo "# Ralph config (contains API key)" >> .gitignore
    echo ".cursor/ralph-config.json" >> .gitignore
  fi
  echo "✓ Updated .gitignore"
else
  cat > .gitignore <<EOF
# Ralph state (regenerated each session)
.ralph/

# Ralph config (contains API key)
.cursor/ralph-config.json
EOF
  echo "✓ Created .gitignore"
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "✅ Ralph initialized!"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Mode: $(if [[ "$CLOUD_ENABLED" == "true" ]]; then echo "🌩️  Cloud (True Ralph)"; else echo "💻 Local (Assisted Ralph)"; fi)"
echo ""
echo "Next steps:"
echo "  1. Edit RALPH_TASK.md to define your task and completion criteria"
echo "  2. Start a new Cursor conversation"
echo "  3. Tell Cursor: 'Work on the Ralph task in RALPH_TASK.md'"
echo ""

if [[ "$CLOUD_ENABLED" == "true" ]]; then
  echo "Cloud Mode enabled:"
  echo "  • When context fills up, Ralph will automatically spawn a Cloud Agent"
  echo "  • The Cloud Agent continues with fresh context"
  echo "  • True malloc/free cycle - fully autonomous"
else
  echo "Local Mode active:"
  echo "  • When context fills up, Ralph will tell you to start a new conversation"
  echo "  • You manually trigger the malloc/free cycle"
  echo "  • To enable Cloud Mode, set CURSOR_API_KEY or run init again"
fi

echo ""
echo "Learn more: https://ghuntley.com/ralph/"
echo "═══════════════════════════════════════════════════════════════════"
