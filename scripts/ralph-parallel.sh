#!/usr/bin/env bash
# ralph-parallel.sh — Dual-agent control harness for Ralph Loop v3.
# Runs two parallel LLM agents: Primary (A) sequential state machine, Worker (B) full-cycle in worktree.
# All agent activity produces proposals; only the control plane advances truth.
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="${PROJ_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RALPH_DIR="${PROJ_DIR}/.ralph"
RALPHCTL="${RALPH_DIR}/ralphctl.py"

# Load project config
CONFIG_FILE="${PROJ_DIR}/ralph.config.json"
if [[ -f "$CONFIG_FILE" ]]; then
    MODEL=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('model','opus'))" 2>/dev/null || echo "opus")
    BUDGET_PRIMARY=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('budget_primary','2.50'))" 2>/dev/null || echo "2.50")
    BUDGET_WORKER=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('budget_worker','5.00'))" 2>/dev/null || echo "5.00")
    BUILD_CMD=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('build','make build'))" 2>/dev/null || echo "make build")
    TEST_CMD=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('test','make test'))" 2>/dev/null || echo "make test")
else
    MODEL="${MODEL:-opus}"
    BUDGET_PRIMARY="${BUDGET_PRIMARY:-2.50}"
    BUDGET_WORKER="${BUDGET_WORKER:-5.00}"
    BUILD_CMD="${BUILD_CMD:-make build}"
    TEST_CMD="${TEST_CMD:-make test}"
fi

EFFORT="${EFFORT:-max}"
INTERVAL_PRIMARY="${INTERVAL_PRIMARY:-20}"
INTERVAL_WORKER="${INTERVAL_WORKER:-30}"

# Derived paths
LOG_DIR="${RALPH_DIR}/logs"
WORKTREE_BASE="${PROJ_DIR}/.worktrees"
LOCK_DIR="${RALPH_DIR}/locks"
STATE_FILE="${RALPH_DIR}/STATE.json"
BACKLOG_FILE="${RALPH_DIR}/BACKLOG.md"
CORE_FILE="${RALPH_DIR}/core.md"
GUARDRAILS_FILE="${RALPH_DIR}/GUARDRAILS.md"

DATE_TAG=$(date -u +%Y%m%d)
METRICS_FILE="${LOG_DIR}/par-metrics-${DATE_TAG}.jsonl"
PRIMARY_LOG="${LOG_DIR}/par-A-${DATE_TAG}.log"
WORKER_LOG="${LOG_DIR}/par-B-${DATE_TAG}.log"
NOHUP_LOG="${LOG_DIR}/parallel-nohup.log"

# Ensure directories exist
mkdir -p "$LOG_DIR" "$LOCK_DIR" "$WORKTREE_BASE" \
         "${RALPH_DIR}/proposals/processed" \
         "${RALPH_DIR}/commits/pending" \
         "${RALPH_DIR}/commits/applied"

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------
log() {
    local agent="$1"; shift
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "[$ts] [$agent] $*" | tee -a "$NOHUP_LOG"
}

die() {
    log "SYSTEM" "FATAL: $*"
    exit 1
}

# Read a JSON field from STATE.json
state_field() {
    python3 -c "import json; print(json.load(open('${STATE_FILE}')).get('$1', '$2'))" 2>/dev/null || echo "$2"
}

# Read STATE.json as compact JSON
state_json() {
    python3 -c "import json; print(json.dumps(json.load(open('${STATE_FILE}'))))" 2>/dev/null || echo '{}'
}

# Get a slim version of state with only phase-relevant fields
slim_state() {
    local phase="$1"
    python3 -c "
import json
s = json.load(open('${STATE_FILE}'))
# Always include
slim = {k: s.get(k) for k in ['iteration','phase','current_item','current_wave','retry_count',
    'commits_total','compile_status','test_status','items_done_count','items_pending_count']}
# Phase-specific
if '$phase' in ('implement',):
    slim['current_plan'] = s.get('current_plan')
    slim['current_sub_step'] = s.get('current_sub_step', 0)
elif '$phase' in ('plan',):
    slim['current_plan'] = s.get('current_plan')
elif '$phase' in ('reflect',):
    slim['current_plan'] = s.get('current_plan')
    slim['current_sub_step'] = s.get('current_sub_step', 0)
    slim['retry_count'] = s.get('retry_count', 0)
elif '$phase' in ('evolve_goals',):
    slim['last_evolve_at'] = s.get('last_evolve_at', 0)
elif '$phase' in ('refactor_dry',):
    slim['last_dry_at'] = s.get('last_dry_at', 0)
elif '$phase' in ('test_integration',):
    slim['last_integ_at'] = s.get('last_integ_at', 0)
elif '$phase' in ('test_ui',):
    slim['last_ui_at'] = s.get('last_ui_at', 0)
elif '$phase' in ('commit',):
    slim['current_plan'] = s.get('current_plan')
print(json.dumps(slim))
" 2>/dev/null || echo '{}'
}

# ---------------------------------------------------------------------------
# Metrics Extraction
# ---------------------------------------------------------------------------
extract_metrics() {
    local result_file="$1"
    local agent="$2"
    local iter="$3"
    local phase_from="$4"

    if [[ ! -f "$result_file" ]]; then
        echo "METRIC_COST=0 METRIC_TURNS=0 METRIC_INPUT=0 METRIC_CACHE_READ=0 METRIC_CACHE_CREATE=0 METRIC_OUTPUT=0 METRIC_MODEL=unknown METRIC_SUBTYPE=error"
        return
    fi

    python3 << PYEOF
import json, sys
try:
    with open('$result_file') as f:
        data = json.load(f)
except:
    print('METRIC_COST=0 METRIC_TURNS=0 METRIC_INPUT=0 METRIC_CACHE_READ=0 METRIC_CACHE_CREATE=0 METRIC_OUTPUT=0 METRIC_MODEL=unknown METRIC_SUBTYPE=error')
    sys.exit(0)

cost = data.get('total_cost_usd', 0)
turns = data.get('num_turns', 0)
subtype = data.get('subtype', 'unknown')
duration = data.get('duration_ms', 0) // 1000

# Parse modelUsage (authoritative)
input_t = 0; cache_r = 0; cache_c = 0; output_t = 0
primary_model = 'unknown'
max_cost = 0
for model, usage in data.get('modelUsage', {}).items():
    input_t += usage.get('inputTokens', 0)
    cache_r += usage.get('cacheReadInputTokens', 0)
    cache_c += usage.get('cacheCreationInputTokens', 0)
    output_t += usage.get('outputTokens', 0)
    if usage.get('costUSD', 0) > max_cost:
        max_cost = usage.get('costUSD', 0)
        primary_model = model

print(f'METRIC_COST={cost} METRIC_TURNS={turns} METRIC_INPUT={input_t} '
      f'METRIC_CACHE_READ={cache_r} METRIC_CACHE_CREATE={cache_c} '
      f'METRIC_OUTPUT={output_t} METRIC_MODEL={primary_model} METRIC_SUBTYPE={subtype}')
PYEOF
}

record_metrics() {
    local agent="$1" iter="$2" phase_from="$3" phase_to="$4"
    local cost="$5" turns="$6" input_t="$7" cache_r="$8" cache_c="$9"
    local output_t="${10}" model="${11}" subtype="${12}" duration="${13}" prompt_bytes="${14}"

    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    python3 -c "
import json
m = {
    'ts': '$ts', 'agent': '$agent', 'iter': $iter,
    'phase_from': '$phase_from', 'phase_to': '$phase_to',
    'duration': $duration, 'cost': $cost, 'prompt_bytes': $prompt_bytes,
    'turns': $turns, 'input_tokens': $input_t, 'cache_read': $cache_r,
    'cache_create': $cache_c, 'output_tokens': $output_t,
    'model': '$model', 'subtype': '$subtype'
}
with open('$METRICS_FILE', 'a') as f:
    f.write(json.dumps(m) + '\n')
" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Periodic Phase Override
# ---------------------------------------------------------------------------
check_periodic_override() {
    local commits
    commits=$(state_field "commits_total" "0")
    local last_integ last_ui last_evolve last_dry
    last_integ=$(state_field "last_integ_at" "0")
    last_ui=$(state_field "last_ui_at" "0")
    last_evolve=$(state_field "last_evolve_at" "0")
    last_dry=$(state_field "last_dry_at" "0")

    local since_integ=$((commits - last_integ))
    local since_ui=$((commits - last_ui))
    local since_evolve=$((commits - last_evolve))
    local since_dry=$((commits - last_dry))

    # 0. Cold-start: if backlog is empty and specs/docs exist, force evolve_goals
    local pending_count
    pending_count=$(python3 -c "
import sqlite3
db = sqlite3.connect('${RALPH_DIR}/ralph.db')
print(db.execute(\"SELECT COUNT(*) FROM task_view WHERE status='pending'\").fetchone()[0])
db.close()
" 2>/dev/null || echo "0")

    if [[ "$pending_count" -eq 0 ]]; then
        # Check if there are spec/doc files to discover
        local has_specs=false
        for dir in "${PROJ_DIR}/specs" "${PROJ_DIR}/docs" "${PROJ_DIR}/adrs"; do
            if [[ -d "$dir" ]] && find "$dir" -type f \( -name "*.md" -o -name "*.json" -o -name "*.yml" -o -name "*.yaml" \) 2>/dev/null | head -1 | grep -q .; then
                has_specs=true
                break
            fi
        done
        if [[ "$has_specs" == "true" ]]; then
            echo "evolve_goals"
            return
        fi
    fi

    # Priority-ordered checks
    # 1. test_integration if >30 commits overdue
    if [[ $since_integ -gt 30 ]]; then
        echo "test_integration"
        return
    fi

    # 2. test_ui if >30 commits overdue
    if [[ $since_ui -gt 30 ]]; then
        echo "test_ui"
        return
    fi

    # 3. review_deferred if deferred queue >= 3
    local should_review
    should_review=$(python3 "$RALPHCTL" should-review-deferred 2>/dev/null || echo "false")
    if [[ "$should_review" == "true" ]]; then
        echo "review_deferred"
        return
    fi

    # 4. evolve_goals every 5 commits
    if [[ $since_evolve -ge 5 ]]; then
        echo "evolve_goals"
        return
    fi

    # 5. refactor_dry every 5 commits
    if [[ $since_dry -ge 5 ]]; then
        echo "refactor_dry"
        return
    fi

    # 6. test_integration every 10 commits
    if [[ $since_integ -ge 10 ]]; then
        echo "test_integration"
        return
    fi

    # 7. test_ui every 15 commits
    if [[ $since_ui -ge 15 ]]; then
        echo "test_ui"
        return
    fi

    echo ""
}

# ---------------------------------------------------------------------------
# Adaptive Sleep
# ---------------------------------------------------------------------------
adaptive_sleep() {
    local phase="$1"
    local sleep_secs

    case "$phase" in
        assess|commit)
            sleep_secs=10 ;;
        verify|reflect|plan)
            sleep_secs=15 ;;
        implement)
            sleep_secs=5 ;;
        evolve_goals|refactor_dry|test_integration|test_ui|review_deferred)
            sleep_secs=10 ;;
        *)
            sleep_secs=20 ;;
    esac

    sleep "$sleep_secs"
}

# ---------------------------------------------------------------------------
# Primary Prompt Composition
# ---------------------------------------------------------------------------
build_primary_prompt() {
    local phase="$1"
    local prompt=""

    # 1. Core coding standards (always)
    if [[ -f "$CORE_FILE" ]]; then
        prompt+="$(cat "$CORE_FILE")"$'\n\n'
    fi

    # 2. Slim STATE.json (phase-relevant fields)
    prompt+="## Current State"$'\n'
    prompt+='```json'$'\n'
    prompt+="$(slim_state "$phase")"$'\n'
    prompt+='```'$'\n\n'

    # 3. Phase instructions
    local phase_file="${RALPH_DIR}/phases/${phase}.md"
    if [[ -f "$phase_file" ]]; then
        prompt+="$(cat "$phase_file")"$'\n\n'
    fi

    # 4. Active backlog wave (assess, plan)
    if [[ "$phase" == "assess" || "$phase" == "plan" ]]; then
        local current_wave
        current_wave=$(state_field "current_wave" "0")
        prompt+="## Active Backlog (Wave ${current_wave})"$'\n'
        # Extract just the current wave from BACKLOG.md
        if [[ -f "$BACKLOG_FILE" ]]; then
            prompt+="$(python3 -c "
import re
with open('$BACKLOG_FILE') as f:
    content = f.read()
# Find the wave section
pattern = r'(## Wave ${current_wave}:.*?)(?=## Wave |\Z)'
match = re.search(pattern, content, re.DOTALL)
if match:
    print(match.group(1).strip())
else:
    # Fallback: show first 50 lines
    print('\n'.join(content.splitlines()[:50]))
" 2>/dev/null)"$'\n\n'
        fi
    fi

    # 5. All-wave summary for evolve_goals
    if [[ "$phase" == "evolve_goals" ]]; then
        prompt+="## Full Backlog Summary"$'\n'
        if [[ -f "$BACKLOG_FILE" ]]; then
            # Show all-wave summary + S-effort items
            prompt+="$(python3 -c "
import re
with open('$BACKLOG_FILE') as f:
    content = f.read()
lines = content.splitlines()
summary_lines = []
for line in lines:
    if line.startswith('## Wave') or line.startswith('# BACKLOG'):
        summary_lines.append(line)
    elif '| S |' in line and '| pending |' in line:
        summary_lines.append(line)
    elif '|----' in line or '| ID |' in line:
        summary_lines.append(line)
print('\n'.join(summary_lines))
" 2>/dev/null)"$'\n\n'
        fi
    fi

    # 6. Deferred queue for review_deferred
    if [[ "$phase" == "review_deferred" ]]; then
        prompt+="$(python3 "$RALPHCTL" get-deferred-queue --format prompt 2>/dev/null)"$'\n\n'
    fi

    # 7. Guardrail triggers (plan, implement, verify, reflect)
    if [[ "$phase" == "plan" || "$phase" == "implement" || "$phase" == "verify" || "$phase" == "reflect" ]]; then
        if [[ -f "$GUARDRAILS_FILE" ]]; then
            prompt+="## Guardrails"$'\n'
            prompt+="$(cat "$GUARDRAILS_FILE")"$'\n\n'
        fi
    fi

    echo "$prompt"
}

# ---------------------------------------------------------------------------
# Worker Prompt Composition
# ---------------------------------------------------------------------------
build_worker_prompt() {
    local task_id="$1"
    local task_title="$2"
    local task_source="$3"
    local task_effort="$4"
    local prompt=""

    # 1. Core coding standards
    if [[ -f "$CORE_FILE" ]]; then
        prompt+="$(cat "$CORE_FILE")"$'\n\n'
    fi

    # 2. Item details
    prompt+="## Your Task"$'\n'
    prompt+="- **ID**: ${task_id}"$'\n'
    prompt+="- **Title**: ${task_title}"$'\n'
    prompt+="- **Source**: ${task_source}"$'\n'
    prompt+="- **Effort**: ${task_effort}"$'\n\n'

    # 3. Full-cycle instructions
    prompt+="## Instructions"$'\n'
    prompt+="Complete this task in a single session. Follow this sequence:"$'\n'
    prompt+="1. **PLAN**: Read specs/code, create a plan."$'\n'
    prompt+="2. **IMPLEMENT**: Write the code changes."$'\n'
    prompt+="3. **VERIFY**: Run build (\`${BUILD_CMD}\`) and tests (\`${TEST_CMD}\`). Fix failures."$'\n'
    prompt+="4. **COMMIT**: Stage and commit with message: \`ralph(${task_id}): <description>\`"$'\n\n'
    prompt+="Do NOT modify .ralph/STATE.json or .ralph/BACKLOG.md."$'\n'
    prompt+="Stage only your code changes plus any test files you created."$'\n\n'

    # 4. Guardrail triggers
    if [[ -f "$GUARDRAILS_FILE" ]]; then
        prompt+="## Guardrails"$'\n'
        prompt+="$(cat "$GUARDRAILS_FILE")"$'\n\n'
    fi

    echo "$prompt"
}

# ---------------------------------------------------------------------------
# Worker: Pick Item
# ---------------------------------------------------------------------------
pick_worker_item() {
    local primary_item="$1"
    local exclude_flag=""
    if [[ -n "$primary_item" && "$primary_item" != "null" && "$primary_item" != "None" ]]; then
        exclude_flag="--exclude $primary_item"
    fi

    local task_id
    task_id=$(python3 "$RALPHCTL" pick-ready-task worker $exclude_flag 2>/dev/null | tail -1)
    echo "$task_id"
}

# ---------------------------------------------------------------------------
# Worker: Worktree Setup
# ---------------------------------------------------------------------------
setup_worktree() {
    local wt_path="${WORKTREE_BASE}/worker-b"
    local branch="ralph/worker-b"

    if [[ -d "$wt_path" ]]; then
        # Reset existing worktree to current main HEAD
        git -C "$wt_path" reset --hard HEAD >/dev/null 2>&1 || true
        git -C "$wt_path" clean -fd >/dev/null 2>&1 || true

        # Determine the main branch name
        local main_branch
        main_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "main")
        git -C "$wt_path" checkout "$main_branch" >/dev/null 2>&1 || true
        git -C "$wt_path" reset --hard "$main_branch" >/dev/null 2>&1 || true
    else
        # Create new worktree
        git branch -D "$branch" >/dev/null 2>&1 || true
        git worktree add "$wt_path" -b "$branch" HEAD >/dev/null 2>&1
    fi

    # Copy ralph config into worktree (NOT STATE.json)
    mkdir -p "$wt_path/.ralph/phases"
    cp "$CORE_FILE" "$wt_path/.ralph/" 2>/dev/null || true
    cp "$BACKLOG_FILE" "$wt_path/.ralph/" 2>/dev/null || true
    cp "$GUARDRAILS_FILE" "$wt_path/.ralph/" 2>/dev/null || true
    cp "${RALPH_DIR}/phases/"* "$wt_path/.ralph/phases/" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Worker: Merge to Main
# ---------------------------------------------------------------------------
merge_worker_to_main() {
    local wt_path="${WORKTREE_BASE}/worker-b"
    local task_id="$1"

    # Check if worker made any commits
    local main_branch
    main_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "main")
    local worker_commits
    worker_commits=$(git -C "$wt_path" log "${main_branch}..HEAD" --oneline 2>/dev/null | wc -l)

    if [[ "$worker_commits" -eq 0 ]]; then
        log "B" "No commits from worker for ${task_id}"
        return 1
    fi

    # Generate format-patch
    local patch_dir="${RALPH_DIR}/commits/pending"
    local ts
    ts=$(date -u +%Y%m%d%H%M%S)
    local patch_file="${patch_dir}/${task_id}_${ts}.patch"

    git -C "$wt_path" format-patch "${main_branch}..HEAD" --stdout > "$patch_file" 2>/dev/null

    if [[ ! -s "$patch_file" ]]; then
        log "B" "Empty patch for ${task_id}"
        rm -f "$patch_file"
        return 1
    fi

    # Queue the patch via control plane
    local patch_id
    patch_id=$(python3 "$RALPHCTL" queue-patch "$task_id" "$patch_file" "worker-b" 2>/dev/null | tail -1)
    log "B" "Queued patch ${patch_id} for ${task_id}"
    return 0
}

# ---------------------------------------------------------------------------
# Primary: Apply Pending Patches (Git Plumbing — Zero Working-Tree Conflicts)
# ---------------------------------------------------------------------------
apply_pending_patches() {
    local patch_dir="${RALPH_DIR}/commits/pending"
    local applied_dir="${RALPH_DIR}/commits/applied"

    for patch_file in "$patch_dir"/*.patch; do
        [[ -f "$patch_file" ]] || continue

        local basename
        basename=$(basename "$patch_file")
        local task_id
        task_id=$(echo "$basename" | sed 's/_[0-9]*\.patch$//')

        # Look up patch_id from patch_view
        local patch_id
        patch_id=$(python3 -c "
import sqlite3, os
db = sqlite3.connect('${RALPH_DIR}/ralph.db')
row = db.execute(\"SELECT patch_id FROM patch_view WHERE patch_path=? AND status='queued'\",
    ('$patch_file',)).fetchone()
print(row[0] if row else '')
db.close()
" 2>/dev/null)

        if [[ -z "$patch_id" ]]; then
            log "A" "No patch_id found for ${basename}, skipping"
            continue
        fi

        log "A" "Applying patch ${patch_id} (${basename})..."

        # Git plumbing merge: never touches working tree
        local tmp_idx
        tmp_idx=$(mktemp)

        # 1. Create temporary index from current HEAD
        GIT_INDEX_FILE="$tmp_idx" git read-tree HEAD 2>/dev/null

        # 2. Apply patch to temp index (exclude .ralph/ to avoid conflicts)
        if ! GIT_INDEX_FILE="$tmp_idx" git apply --cached --3way --exclude='.ralph/*' "$patch_file" 2>/dev/null; then
            log "A" "CONFLICT applying ${patch_id} — discarding"
            rm -f "$tmp_idx"
            python3 "$RALPHCTL" discard-patch "$patch_id" "conflict" 2>/dev/null || true
            mv "$patch_file" "${applied_dir}/${basename}.discarded" 2>/dev/null || true
            continue
        fi

        # 3. Write tree from temp index
        local new_tree
        new_tree=$(GIT_INDEX_FILE="$tmp_idx" git write-tree 2>/dev/null)
        rm -f "$tmp_idx"

        if [[ -z "$new_tree" ]]; then
            log "A" "Failed to write tree for ${patch_id}"
            python3 "$RALPHCTL" discard-patch "$patch_id" "write-tree-failed" 2>/dev/null || true
            continue
        fi

        # 4. Create commit
        local commit_msg="ralph(${task_id}): worker patch ${patch_id}"
        local new_commit
        new_commit=$(git commit-tree "$new_tree" -p HEAD -m "$commit_msg" 2>/dev/null)

        if [[ -z "$new_commit" ]]; then
            log "A" "Failed to create commit for ${patch_id}"
            python3 "$RALPHCTL" discard-patch "$patch_id" "commit-tree-failed" 2>/dev/null || true
            continue
        fi

        # 5. Advance HEAD
        git update-ref HEAD "$new_commit" 2>/dev/null

        # 6. Promote in event log (atomic: patch→promoted + task→done)
        python3 "$RALPHCTL" promote-patch "$patch_id" "$new_commit" 2>/dev/null || true

        # 7. Move patch to applied
        mv "$patch_file" "${applied_dir}/${basename}" 2>/dev/null || true

        log "A" "PROMOTED ${patch_id} → ${task_id} done (commit ${new_commit:0:8})"
    done
}

# ---------------------------------------------------------------------------
# Primary: Sync BACKLOG.md Completions → SQLite
# ---------------------------------------------------------------------------
sync_primary_completions() {
    python3 "$RALPHCTL" sync-backlog 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Primary Agent Loop
# ---------------------------------------------------------------------------
run_primary() {
    local iter=0

    log "A" "Primary agent starting (model=${MODEL}, budget=\$${BUDGET_PRIMARY})"

    while true; do
        iter=$((iter + 1))
        local phase
        phase=$(state_field "phase" "assess")

        # Check for periodic overrides at assess time
        if [[ "$phase" == "assess" ]]; then
            local override
            override=$(check_periodic_override)
            if [[ -n "$override" ]]; then
                log "A" "Periodic override: ${override}"
                phase="$override"
                # Update STATE.json phase
                python3 -c "
import json
with open('${STATE_FILE}') as f:
    s = json.load(f)
s['phase'] = '$phase'
with open('${STATE_FILE}', 'w') as f:
    json.dump(s, f, indent=2)
" 2>/dev/null
            fi
        fi

        log "A" "Iteration ${iter}, phase: ${phase}"

        # Apply any pending worker patches before we begin
        apply_pending_patches

        # Build prompt
        local prompt
        prompt=$(build_primary_prompt "$phase")
        local prompt_bytes=${#prompt}

        # Write prompt to temp file (avoids pipe issues)
        local prompt_file="${LOG_DIR}/par-A-prompt-${iter}.txt"
        local result_file="${LOG_DIR}/par-A-result-${iter}.json"
        echo "$prompt" > "$prompt_file"

        # Run Claude
        local start_ts
        start_ts=$(date +%s)
        local exit_code=0

        claude -p \
            --model "$MODEL" --effort "$EFFORT" \
            --max-budget-usd "$BUDGET_PRIMARY" \
            --output-format json \
            --dangerously-skip-permissions \
            < "$prompt_file" \
            > "$result_file" 2>>"${LOG_DIR}/par-A-errors.log" || exit_code=$?

        local end_ts
        end_ts=$(date +%s)
        local duration=$((end_ts - start_ts))

        rm -f "$prompt_file"

        # Extract metrics
        local metrics
        metrics=$(extract_metrics "$result_file" "A" "$iter" "$phase")
        eval "$metrics"

        # Get new phase from STATE.json (Claude updates it)
        local new_phase
        new_phase=$(state_field "phase" "$phase")

        # Record metrics
        record_metrics "A" "$iter" "$phase" "$new_phase" \
            "${METRIC_COST:-0}" "${METRIC_TURNS:-0}" "${METRIC_INPUT:-0}" \
            "${METRIC_CACHE_READ:-0}" "${METRIC_CACHE_CREATE:-0}" \
            "${METRIC_OUTPUT:-0}" "${METRIC_MODEL:-unknown}" \
            "${METRIC_SUBTYPE:-unknown}" "$duration" "$prompt_bytes"

        log "A" "Phase ${phase} → ${new_phase} | cost=\$${METRIC_COST:-0} turns=${METRIC_TURNS:-0} dur=${duration}s"

        # Sync primary completions to SQLite
        if [[ "$phase" == "commit" || "$new_phase" == "assess" ]]; then
            sync_primary_completions
        fi

        # Post-phase control plane operations
        python3 "$RALPHCTL" render-state 2>/dev/null || true
        python3 "$RALPHCTL" expire-stale-deferrals 2>/dev/null || true

        # Process proposals after evolve_goals
        if [[ "$phase" == "evolve_goals" ]]; then
            python3 "$RALPHCTL" process-proposals 2>/dev/null || true
            python3 "$RALPHCTL" render-backlog 2>/dev/null || true
        fi

        # Handle budget exhaustion
        if [[ "${METRIC_SUBTYPE:-}" == "error_max_budget_usd" ]]; then
            log "A" "Budget exhausted — sleeping 60s"
            sleep 60
        fi

        # Adaptive sleep
        adaptive_sleep "$new_phase"
    done
}

# ---------------------------------------------------------------------------
# Worker Agent Loop
# ---------------------------------------------------------------------------
run_worker() {
    local cycle=0

    log "B" "Worker agent starting (model=${MODEL}, budget=\$${BUDGET_WORKER})"

    # Initial delay to let primary get started
    sleep 15

    while true; do
        cycle=$((cycle + 1))

        # Get current primary item to exclude
        local primary_item
        primary_item=$(state_field "current_item" "")

        # Pick a ready task
        local task_id
        task_id=$(pick_worker_item "$primary_item")

        if [[ "$task_id" == "NONE" || -z "$task_id" ]]; then
            log "B" "No S-effort items available, sleeping ${INTERVAL_WORKER}s"
            sleep "$INTERVAL_WORKER"
            continue
        fi

        log "B" "Cycle ${cycle}: picked ${task_id}"

        # Claim the task
        python3 "$RALPHCTL" transition-task "$task_id" claimed worker-b \
            "{\"claimed_by\": \"worker-b\"}" 2>/dev/null || true

        # Get task details for prompt
        local task_info
        task_info=$(python3 -c "
import sqlite3
db = sqlite3.connect('${RALPH_DIR}/ralph.db')
db.row_factory = sqlite3.Row
row = db.execute('SELECT * FROM task_view WHERE task_id=?', ('$task_id',)).fetchone()
if row:
    print(f\"{row['title']}|{row['source'] or '-'}|{row['effort'] or 'S'}\")
else:
    print('Unknown task|-|S')
db.close()
" 2>/dev/null || echo "Unknown task|-|S")

        local task_title task_source task_effort
        task_title=$(echo "$task_info" | cut -d'|' -f1)
        task_source=$(echo "$task_info" | cut -d'|' -f2)
        task_effort=$(echo "$task_info" | cut -d'|' -f3)

        # Setup worktree
        setup_worktree

        local wt_path="${WORKTREE_BASE}/worker-b"

        # Build prompt
        local prompt
        prompt=$(build_worker_prompt "$task_id" "$task_title" "$task_source" "$task_effort")
        local prompt_bytes=${#prompt}

        # Write prompt to temp file
        local prompt_file="${LOG_DIR}/par-B-prompt-${cycle}.txt"
        local result_file="${LOG_DIR}/par-B-result-${cycle}.json"
        echo "$prompt" > "$prompt_file"

        # Run Claude in worktree directory
        local start_ts exit_code=0
        start_ts=$(date +%s)

        pushd "$wt_path" >/dev/null 2>&1
        claude -p \
            --model "$MODEL" --effort "$EFFORT" \
            --max-budget-usd "$BUDGET_WORKER" \
            --output-format json \
            --dangerously-skip-permissions \
            < "$prompt_file" \
            > "$result_file" 2>>"${LOG_DIR}/par-B-errors.log" || exit_code=$?
        popd >/dev/null 2>&1

        local end_ts duration
        end_ts=$(date +%s)
        duration=$((end_ts - start_ts))

        rm -f "$prompt_file"

        # Extract metrics
        local metrics
        metrics=$(extract_metrics "$result_file" "B" "$cycle" "full_cycle")
        eval "$metrics"

        log "B" "Cycle ${cycle}: ${task_id} | cost=\$${METRIC_COST:-0} turns=${METRIC_TURNS:-0} dur=${duration}s"

        # Record metrics
        record_metrics "B" "$cycle" "full_cycle" "done" \
            "${METRIC_COST:-0}" "${METRIC_TURNS:-0}" "${METRIC_INPUT:-0}" \
            "${METRIC_CACHE_READ:-0}" "${METRIC_CACHE_CREATE:-0}" \
            "${METRIC_OUTPUT:-0}" "${METRIC_MODEL:-unknown}" \
            "${METRIC_SUBTYPE:-unknown}" "$duration" "$prompt_bytes"

        # Merge worker output to main (queue patch, NOT mark done)
        if [[ "$exit_code" -eq 0 && "${METRIC_SUBTYPE:-}" == "success" ]]; then
            merge_worker_to_main "$task_id" || true
        else
            log "B" "Worker failed for ${task_id} (exit=${exit_code}, subtype=${METRIC_SUBTYPE:-unknown})"
            python3 "$RALPHCTL" transition-task "$task_id" pending "worker-b" 2>/dev/null || true
        fi

        # Sleep between cycles
        sleep "$INTERVAL_WORKER"
    done
}

# ---------------------------------------------------------------------------
# Signal Handling
# ---------------------------------------------------------------------------
PRIMARY_PID=""
WORKER_PID=""

cleanup() {
    log "SYSTEM" "Shutting down..."
    [[ -n "$PRIMARY_PID" ]] && kill "$PRIMARY_PID" 2>/dev/null || true
    [[ -n "$WORKER_PID" ]] && kill "$WORKER_PID" 2>/dev/null || true
    wait 2>/dev/null || true
    log "SYSTEM" "Shutdown complete"
    exit 0
}

trap cleanup SIGINT SIGTERM EXIT

# ---------------------------------------------------------------------------
# Pre-flight Checks
# ---------------------------------------------------------------------------
preflight() {
    # Check for claude CLI
    if ! command -v claude &>/dev/null; then
        die "claude CLI not found. Install Claude Code first."
    fi

    # Check for python3
    if ! command -v python3 &>/dev/null; then
        die "python3 not found."
    fi

    # Check for git
    if ! command -v git &>/dev/null; then
        die "git not found."
    fi

    # Check for .ralph directory
    if [[ ! -d "$RALPH_DIR" ]]; then
        die ".ralph/ directory not found. Run ralph-init.sh first."
    fi

    # Check for ralphctl.py
    if [[ ! -f "$RALPHCTL" ]]; then
        die ".ralph/ralphctl.py not found."
    fi

    # Check for STATE.json
    if [[ ! -f "$STATE_FILE" ]]; then
        die ".ralph/STATE.json not found. Run ralph-init.sh first."
    fi

    # Check for git repo
    if ! git rev-parse --git-dir &>/dev/null 2>&1; then
        die "Not a git repository. Initialize git first."
    fi

    # Ensure database is initialized
    python3 "$RALPHCTL" render-state 2>/dev/null || true

    log "SYSTEM" "Pre-flight checks passed"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    cd "$PROJ_DIR"

    echo "========================================"
    echo "  Ralph Loop v3 — Parallel Agent Harness"
    echo "========================================"
    echo "Project: $(basename "$PROJ_DIR")"
    echo "Model: $MODEL | Effort: $EFFORT"
    echo "Budget: Primary=\$${BUDGET_PRIMARY} Worker=\$${BUDGET_WORKER}"
    echo "Logs: $LOG_DIR"
    echo ""

    preflight

    log "SYSTEM" "Starting dual-agent loop"

    # Start primary agent in background
    run_primary >> "$PRIMARY_LOG" 2>&1 &
    PRIMARY_PID=$!
    log "SYSTEM" "Primary agent started (PID ${PRIMARY_PID})"

    # Start worker agent in background
    run_worker >> "$WORKER_LOG" 2>&1 &
    WORKER_PID=$!
    log "SYSTEM" "Worker agent started (PID ${WORKER_PID})"

    # Wait for both
    log "SYSTEM" "Both agents running. Press Ctrl+C to stop."
    log "SYSTEM" "Monitor: tail -f ${NOHUP_LOG}"

    wait
}

main "$@"
