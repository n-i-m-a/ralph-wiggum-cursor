#!/bin/bash
# Ralph Wiggum: Parallel Execution with Git Worktrees
#
# Runs multiple agents concurrently, each in an isolated git worktree.
# After completion, merges branches back to base.
#
# Usage:
#   source ralph-parallel.sh
#   run_parallel_tasks "$workspace" "$max_parallel"

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

WORKTREE_BASE_DIR=".ralph-worktrees"
MAX_PARALLEL="${MAX_PARALLEL:-3}"
SKIP_MERGE="${SKIP_MERGE:-false}"
CREATE_PR="${CREATE_PR:-false}"

# =============================================================================
# WORKTREE MANAGEMENT
# =============================================================================

# Check if worktrees are usable (not already in a worktree)
can_use_worktrees() {
  local workspace="${1:-.}"
  local git_path="$workspace/.git"
  
  # If .git is a file (linked worktree), we can't nest worktrees
  if [[ -f "$git_path" ]]; then
    return 1
  fi
  
  # Check if .git directory exists
  [[ -d "$git_path" ]]
}

# Get worktree base directory
get_worktree_base() {
  local workspace="${1:-.}"
  local base="$workspace/$WORKTREE_BASE_DIR"
  mkdir -p "$base"
  echo "$base"
}

# Generate unique ID for branch names
generate_unique_id() {
  echo "$(date +%s)-$(head -c 4 /dev/urandom | xxd -p)"
}

# Slugify text for branch names
slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | sed -E 's/^-|-$//g' | cut -c1-40
}

# Create a worktree for an agent
# Args: task_name, agent_num, base_branch, worktree_base, original_dir
# Returns: worktree_dir|branch_name
create_agent_worktree() {
  local task_name="$1"
  local agent_num="$2"
  local base_branch="$3"
  local worktree_base="$4"
  local original_dir="$5"
  
  local unique_id=$(generate_unique_id)
  local branch_name="ralph/agent-${agent_num}-${unique_id}-$(slugify "$task_name")"
  local worktree_dir="$worktree_base/agent-${agent_num}-${unique_id}"
  
  # Remove existing worktree dir if any
  if [[ -d "$worktree_dir" ]]; then
    rm -rf "$worktree_dir"
    git -C "$original_dir" worktree prune 2>/dev/null || true
  fi
  
  # Create worktree with new branch
  git -C "$original_dir" worktree add -B "$branch_name" "$worktree_dir" "$base_branch" 2>/dev/null
  
  echo "$worktree_dir|$branch_name"
}

# Cleanup a worktree after agent completes
# Args: worktree_dir, branch_name, original_dir
# Returns: "left_in_place" or "cleaned"
cleanup_agent_worktree() {
  local worktree_dir="$1"
  local branch_name="$2"
  local original_dir="$3"
  
  if [[ ! -d "$worktree_dir" ]]; then
    echo "cleaned"
    return
  fi
  
  # Check for uncommitted changes
  if git -C "$worktree_dir" status --porcelain 2>/dev/null | grep -q .; then
    echo "left_in_place"
    return
  fi
  
  # Remove worktree
  git -C "$original_dir" worktree remove -f "$worktree_dir" 2>/dev/null || true
  
  echo "cleaned"
}

# List all ralph worktrees
list_worktrees() {
  local workspace="${1:-.}"
  git -C "$workspace" worktree list --porcelain 2>/dev/null | grep "worktree.*$WORKTREE_BASE_DIR" | sed 's/worktree //' || true
}

# Cleanup all ralph worktrees
cleanup_all_worktrees() {
  local workspace="${1:-.}"
  
  for worktree in $(list_worktrees "$workspace"); do
    git -C "$workspace" worktree remove -f "$worktree" 2>/dev/null || true
  done
  
  git -C "$workspace" worktree prune 2>/dev/null || true
}

# =============================================================================
# PARALLEL AGENT EXECUTION
# =============================================================================

# Run a single agent in its worktree
# Args: task_desc, agent_num, worktree_dir, log_file, status_file, output_file
run_agent_in_worktree() {
  local task_desc="$1"
  local agent_num="$2"
  local worktree_dir="$3"
  local log_file="$4"
  local status_file="$5"
  local output_file="$6"
  
  echo "running" > "$status_file"
  
  # Build the parallel agent prompt
  local prompt="# Parallel Agent Task

You are Agent $agent_num working on a specific task in isolation.

## Your Task
$task_desc

## Instructions
1. Implement this specific task completely
2. Write tests if appropriate
3. Update .ralph/progress.md with what you did
4. Commit your changes with a descriptive message like: ralph: [task summary]

## Important
- You are in an isolated worktree - your changes will not affect other agents
- Focus ONLY on your assigned task
- Do NOT modify RALPH_TASK.md - that will be handled by the orchestrator
- Commit frequently so your work is saved

Begin by reading any relevant files, then implement the task."
  
  # Ensure .ralph directory exists
  mkdir -p "$worktree_dir/.ralph"
  
  # Run cursor-agent
  echo "[$(date '+%H:%M:%S')] Agent $agent_num starting task: $task_desc" >> "$log_file"
  
  if cd "$worktree_dir" && cursor-agent -p --force --output-format stream-json --model "$MODEL" "$prompt" >> "$log_file" 2>&1; then
    echo "done" > "$status_file"
    
    # Check if any commits were made
    local commit_count
    commit_count=$(git rev-list --count HEAD ^"$BASE_BRANCH" 2>/dev/null || echo "0")
    
    if [[ "$commit_count" -gt 0 ]]; then
      echo "success|$commit_count" > "$output_file"
    else
      echo "no_commits|0" > "$output_file"
    fi
  else
    echo "failed" > "$status_file"
    echo "error|0" > "$output_file"
  fi
  
  echo "[$(date '+%H:%M:%S')] Agent $agent_num finished" >> "$log_file"
}

# =============================================================================
# MERGE PHASE
# =============================================================================

# Get list of conflicted files
get_conflicted_files() {
  local workspace="${1:-.}"
  git -C "$workspace" diff --name-only --diff-filter=U 2>/dev/null || true
}

# Merge an agent branch into target
# Returns: "success", "conflict", or "error"
merge_agent_branch() {
  local branch="$1"
  local target_branch="$2"
  local workspace="$3"
  
  # Checkout target
  git -C "$workspace" checkout "$target_branch" 2>/dev/null || return 1
  
  # Attempt merge
  if git -C "$workspace" merge --no-ff -m "Merge $branch into $target_branch" "$branch" 2>/dev/null; then
    echo "success"
  else
    # Check for conflicts
    local conflicts
    conflicts=$(get_conflicted_files "$workspace")
    if [[ -n "$conflicts" ]]; then
      echo "conflict"
    else
      echo "error"
    fi
  fi
}

# Abort an in-progress merge
abort_merge() {
  local workspace="${1:-.}"
  git -C "$workspace" merge --abort 2>/dev/null || true
}

# Delete a local branch
delete_local_branch() {
  local branch="$1"
  local workspace="$2"
  git -C "$workspace" branch -D "$branch" 2>/dev/null || true
}

# Merge all completed branches
merge_completed_branches() {
  local workspace="$1"
  local target_branch="$2"
  shift 2
  local branches=("$@")
  
  if [[ ${#branches[@]} -eq 0 ]]; then
    return
  fi
  
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo "📦 Merge Phase: Merging ${#branches[@]} branch(es) into $target_branch"
  echo "═══════════════════════════════════════════════════════════════════"
  
  local merged=()
  local failed=()
  
  for branch in "${branches[@]}"; do
    printf "  Merging %-50s " "$branch..."
    
    local result
    result=$(merge_agent_branch "$branch" "$target_branch" "$workspace")
    
    case "$result" in
      "success")
        echo "✅"
        merged+=("$branch")
        ;;
      "conflict")
        echo "⚠️  (conflict)"
        abort_merge "$workspace"
        failed+=("$branch")
        ;;
      *)
        echo "❌"
        failed+=("$branch")
        ;;
    esac
  done
  
  # Delete merged branches
  for branch in "${merged[@]}"; do
    delete_local_branch "$branch" "$workspace"
  done
  
  echo ""
  if [[ ${#merged[@]} -gt 0 ]]; then
    echo "✅ Successfully merged ${#merged[@]} branch(es)"
  fi
  if [[ ${#failed[@]} -gt 0 ]]; then
    echo "⚠️  Failed to merge ${#failed[@]} branch(es):"
    for branch in "${failed[@]}"; do
      echo "   - $branch"
    done
    echo "   These branches are preserved for manual review."
  fi
}

# =============================================================================
# MAIN PARALLEL RUNNER
# =============================================================================

# Run tasks in parallel with worktrees
# Args: workspace, max_parallel, base_branch
run_parallel_tasks() {
  local workspace="${1:-.}"
  local max_parallel="${2:-$MAX_PARALLEL}"
  local base_branch="${3:-$(git -C "$workspace" rev-parse --abbrev-ref HEAD)}"
  
  # Export for subprocesses
  export MODEL
  export BASE_BRANCH="$base_branch"
  
  # Check if worktrees are usable
  if ! can_use_worktrees "$workspace"; then
    echo "❌ Cannot use worktrees (already in a worktree or no .git directory)"
    return 1
  fi
  
  local worktree_base=$(get_worktree_base "$workspace")
  local original_dir=$(cd "$workspace" && pwd)
  
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo "🚀 Parallel Execution: Up to $max_parallel agents"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  echo "Base branch:    $base_branch"
  echo "Worktree base:  $worktree_base"
  echo ""
  
  # Get all pending tasks
  local tasks=()
  while IFS='|' read -r id status desc; do
    if [[ "$status" == "pending" ]]; then
      tasks+=("$id|$desc")
    fi
  done < <(get_all_tasks "$workspace")
  
  if [[ ${#tasks[@]} -eq 0 ]]; then
    echo "✅ No pending tasks!"
    return 0
  fi
  
  echo "📋 Found ${#tasks[@]} pending task(s)"
  echo ""
  
  # Track completed branches for merge phase
  local completed_branches=()
  local total_completed=0
  local total_failed=0
  
  # Process tasks in batches
  local batch_num=0
  local task_idx=0
  
  while [[ $task_idx -lt ${#tasks[@]} ]]; do
    batch_num=$((batch_num + 1))
    
    # Get batch of tasks
    local batch_end=$((task_idx + max_parallel))
    [[ $batch_end -gt ${#tasks[@]} ]] && batch_end=${#tasks[@]}
    local batch_size=$((batch_end - task_idx))
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📦 Batch $batch_num: Spawning $batch_size parallel agent(s)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Arrays for this batch
    local pids=()
    local worktree_dirs=()
    local branch_names=()
    local task_ids=()
    local task_descs=()
    local status_files=()
    local output_files=()
    local log_files=()
    
    # Start agents for this batch
    for ((i = task_idx; i < batch_end; i++)); do
      local task_data="${tasks[$i]}"
      local task_id="${task_data%%|*}"
      local task_desc="${task_data#*|}"
      local agent_num=$((i + 1))
      
      echo "  🔄 Agent $agent_num: ${task_desc:0:50}..."
      
      # Create worktree
      local wt_result
      wt_result=$(create_agent_worktree "$task_desc" "$agent_num" "$base_branch" "$worktree_base" "$original_dir")
      local worktree_dir="${wt_result%%|*}"
      local branch_name="${wt_result#*|}"
      
      # Create temp files for status tracking
      local status_file=$(mktemp)
      local output_file=$(mktemp)
      local log_file=$(mktemp)
      
      echo "waiting" > "$status_file"
      
      # Store for later
      worktree_dirs+=("$worktree_dir")
      branch_names+=("$branch_name")
      task_ids+=("$task_id")
      task_descs+=("$task_desc")
      status_files+=("$status_file")
      output_files+=("$output_file")
      log_files+=("$log_file")
      
      # Copy RALPH_TASK.md to worktree
      cp "$workspace/RALPH_TASK.md" "$worktree_dir/" 2>/dev/null || true
      
      # Start agent in background
      (
        run_agent_in_worktree "$task_desc" "$agent_num" "$worktree_dir" "$log_file" "$status_file" "$output_file"
      ) &
      pids+=($!)
    done
    
    echo ""
    
    # Monitor progress with spinner
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local spin_idx=0
    local start_time=$SECONDS
    
    while true; do
      local all_done=true
      local running=0
      local done_count=0
      local failed_count=0
      
      for ((j = 0; j < batch_size; j++)); do
        local status
        status=$(cat "${status_files[$j]}" 2>/dev/null || echo "waiting")
        
        case "$status" in
          "running") all_done=false; running=$((running + 1)) ;;
          "done") done_count=$((done_count + 1)) ;;
          "failed") failed_count=$((failed_count + 1)) ;;
          *) all_done=false ;;
        esac
      done
      
      [[ "$all_done" == "true" ]] && break
      
      local elapsed=$((SECONDS - start_time))
      printf "\r  %s Running: %d | Done: %d | Failed: %d | %02d:%02d " \
        "${spin:spin_idx:1}" "$running" "$done_count" "$failed_count" \
        $((elapsed / 60)) $((elapsed % 60))
      
      spin_idx=$(( (spin_idx + 1) % ${#spin} ))
      sleep 0.2
    done
    
    printf "\r%80s\r" ""  # Clear line
    
    # Wait for all agents to finish
    for pid in "${pids[@]}"; do
      wait "$pid" 2>/dev/null || true
    done
    
    # Process results
    echo ""
    echo "Batch $batch_num Results:"
    
    for ((j = 0; j < batch_size; j++)); do
      local task_desc="${task_descs[$j]}"
      local task_id="${task_ids[$j]}"
      local status
      status=$(cat "${status_files[$j]}" 2>/dev/null || echo "unknown")
      local output
      output=$(cat "${output_files[$j]}" 2>/dev/null || echo "error|0")
      local output_status="${output%%|*}"
      local branch_name="${branch_names[$j]}"
      local worktree_dir="${worktree_dirs[$j]}"
      local agent_num=$((task_idx + j + 1))
      
      local icon color
      case "$status" in
        "done")
          if [[ "$output_status" == "success" ]]; then
            icon="✅"
            total_completed=$((total_completed + 1))
            completed_branches+=("$branch_name")
            # Mark task complete
            mark_task_complete "$workspace" "$task_id"
          else
            icon="⚠️ "
            total_failed=$((total_failed + 1))
          fi
          ;;
        "failed")
          icon="❌"
          total_failed=$((total_failed + 1))
          ;;
        *)
          icon="❓"
          total_failed=$((total_failed + 1))
          ;;
      esac
      
      printf "  %s Agent %d: %s → %s\n" "$icon" "$agent_num" "${task_desc:0:40}" "$branch_name"
      
      # Cleanup worktree
      local cleanup_result
      cleanup_result=$(cleanup_agent_worktree "$worktree_dir" "$branch_name" "$original_dir")
      if [[ "$cleanup_result" == "left_in_place" ]]; then
        echo "     ⚠️  Worktree preserved (uncommitted changes): $worktree_dir"
      fi
      
      # Cleanup temp files
      rm -f "${status_files[$j]}" "${output_files[$j]}" "${log_files[$j]}"
    done
    
    echo ""
    task_idx=$batch_end
  done
  
  # Merge phase
  if [[ "$SKIP_MERGE" != "true" ]] && [[ ${#completed_branches[@]} -gt 0 ]]; then
    merge_completed_branches "$original_dir" "$base_branch" "${completed_branches[@]}"
  elif [[ ${#completed_branches[@]} -gt 0 ]]; then
    echo ""
    echo "📝 Branches created (merge skipped):"
    for branch in "${completed_branches[@]}"; do
      echo "   - $branch"
    done
  fi
  
  # Summary
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo "📊 Parallel Execution Complete"
  echo "═══════════════════════════════════════════════════════════════════"
  echo "  Completed: $total_completed"
  echo "  Failed:    $total_failed"
  echo ""
  
  return 0
}

# =============================================================================
# CLI INTERFACE (when run directly)
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Script is being run directly
  
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/ralph-common.sh"
  source "$SCRIPT_DIR/task-parser.sh"
  
  usage() {
    echo "Usage: $0 [options] [workspace]"
    echo ""
    echo "Options:"
    echo "  -n, --max-parallel N    Max parallel agents (default: 3)"
    echo "  -b, --base-branch NAME  Base branch (default: current)"
    echo "  --no-merge              Skip auto-merge after completion"
    echo "  --pr                    Create PRs instead of auto-merge"
    echo "  -m, --model MODEL       Model to use"
    echo "  -h, --help              Show this help"
  }
  
  WORKSPACE="."
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--max-parallel)
        MAX_PARALLEL="$2"
        shift 2
        ;;
      -b|--base-branch)
        BASE_BRANCH="$2"
        shift 2
        ;;
      --no-merge)
        SKIP_MERGE=true
        shift
        ;;
      --pr)
        CREATE_PR=true
        SKIP_MERGE=true
        shift
        ;;
      -m|--model)
        MODEL="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        WORKSPACE="$1"
        shift
        ;;
    esac
  done
  
  # Run parallel tasks
  run_parallel_tasks "$WORKSPACE" "$MAX_PARALLEL" "${BASE_BRANCH:-}"
fi
