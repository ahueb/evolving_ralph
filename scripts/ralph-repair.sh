#!/usr/bin/env bash
# ralph-repair.sh — Diagnostics and recovery for Ralph Loop v3.
# Checks system health, identifies issues, and repairs common problems.
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="${PROJ_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RALPH_DIR="${PROJ_DIR}/.ralph"
DB_PATH="${RALPH_DIR}/ralph.db"
STATE_FILE="${RALPH_DIR}/STATE.json"
BACKLOG_FILE="${RALPH_DIR}/BACKLOG.md"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

issues=0
fixed=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
check_pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; }
check_fail() { echo -e "  ${RED}[FAIL]${NC} $1"; issues=$((issues + 1)); }
check_warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
check_fix()  { echo -e "  ${GREEN}[FIX]${NC}  $1"; fixed=$((fixed + 1)); }

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
echo -e "${BOLD}=== Ralph Loop v3 — Diagnostics & Repair ===${NC}"
echo ""

if [[ ! -d "$RALPH_DIR" ]]; then
    echo -e "${RED}ERROR: .ralph/ directory not found in ${PROJ_DIR}${NC}"
    echo "Run ralph-init.sh first."
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. File System Checks
# ---------------------------------------------------------------------------
echo -e "${BOLD}1. File System${NC}"

# Required files
for f in "ralphctl.py" "STATE.json" "BACKLOG.md" "core.md" "GUARDRAILS.md" "REFLECTIONS.md"; do
    if [[ -f "${RALPH_DIR}/${f}" ]]; then
        check_pass "$f exists"
    else
        check_fail "$f MISSING"
    fi
done

# Required directories
for d in "phases" "proposals" "proposals/processed" "commits/pending" "commits/applied" "locks" "logs"; do
    if [[ -d "${RALPH_DIR}/${d}" ]]; then
        check_pass "directory ${d}/ exists"
    else
        check_warn "directory ${d}/ missing — creating"
        mkdir -p "${RALPH_DIR}/${d}"
        check_fix "Created ${d}/"
    fi
done

# Phase files
phase_count=$(ls "${RALPH_DIR}/phases/"*.md 2>/dev/null | wc -l || echo "0")
if [[ "$phase_count" -ge 11 ]]; then
    check_pass "Phase files: ${phase_count} found"
elif [[ "$phase_count" -gt 0 ]]; then
    check_warn "Phase files: only ${phase_count} found (expected 11)"
else
    check_fail "No phase files found in phases/"
fi

echo ""

# ---------------------------------------------------------------------------
# 2. Git Repository
# ---------------------------------------------------------------------------
echo -e "${BOLD}2. Git Repository${NC}"

cd "$PROJ_DIR"

if git rev-parse --git-dir &>/dev/null 2>&1; then
    check_pass "Git repository detected"

    # Check for uncommitted changes
    local_changes=$(git status --porcelain 2>/dev/null | wc -l || echo "0")
    if [[ "$local_changes" -gt 0 ]]; then
        check_warn "Uncommitted changes: ${local_changes} files"
    else
        check_pass "Working tree clean"
    fi

    # Check worktree
    wt_path="${PROJ_DIR}/.worktrees/worker-b"
    if [[ -d "$wt_path" ]]; then
        if git -C "$wt_path" rev-parse HEAD &>/dev/null 2>&1; then
            check_pass "Worker worktree healthy"
        else
            check_fail "Worker worktree corrupted"
            check_warn "Attempting worktree repair..."
            git worktree remove "$wt_path" --force 2>/dev/null || true
            git branch -D "ralph/worker-b" 2>/dev/null || true
            check_fix "Removed corrupted worktree (will recreate on next worker cycle)"
        fi
    else
        check_pass "No worker worktree (will create on demand)"
    fi
else
    check_fail "Not a git repository"
fi

echo ""

# ---------------------------------------------------------------------------
# 3. SQLite Database
# ---------------------------------------------------------------------------
echo -e "${BOLD}3. SQLite Database${NC}"

if [[ -f "$DB_PATH" ]]; then
    check_pass "Database file exists"

    # Integrity check
    integrity=$(python3 -c "
import sqlite3
db = sqlite3.connect('${DB_PATH}')
result = db.execute('PRAGMA integrity_check').fetchone()
print(result[0])
db.close()
" 2>/dev/null || echo "error")

    if [[ "$integrity" == "ok" ]]; then
        check_pass "Database integrity: OK"
    else
        check_fail "Database integrity: ${integrity}"
    fi

    # Table existence
    for table in "events" "task_view" "patch_view"; do
        exists=$(python3 -c "
import sqlite3
db = sqlite3.connect('${DB_PATH}')
r = db.execute(\"SELECT count(*) FROM sqlite_master WHERE type='table' AND name='${table}'\").fetchone()
print(r[0])
db.close()
" 2>/dev/null || echo "0")

        if [[ "$exists" == "1" ]]; then
            count=$(python3 -c "
import sqlite3
db = sqlite3.connect('${DB_PATH}')
print(db.execute('SELECT count(*) FROM ${table}').fetchone()[0])
db.close()
" 2>/dev/null || echo "0")
            check_pass "Table ${table}: ${count} rows"
        else
            check_fail "Table ${table} MISSING"
            check_warn "Attempting schema repair..."
            python3 "$RALPH_DIR/ralphctl.py" init 2>/dev/null || true
            check_fix "Re-initialized schema"
        fi
    done

    # WAL mode check
    journal=$(python3 -c "
import sqlite3
db = sqlite3.connect('${DB_PATH}')
print(db.execute('PRAGMA journal_mode').fetchone()[0])
db.close()
" 2>/dev/null || echo "unknown")

    if [[ "$journal" == "wal" ]]; then
        check_pass "Journal mode: WAL"
    else
        check_warn "Journal mode: ${journal} (expected WAL)"
    fi
else
    check_fail "Database file MISSING"
    check_warn "Attempting to initialize..."
    python3 "$RALPH_DIR/ralphctl.py" init 2>/dev/null || true
    if [[ -f "$DB_PATH" ]]; then
        check_fix "Created database via init"
    fi
fi

echo ""

# ---------------------------------------------------------------------------
# 4. State Consistency
# ---------------------------------------------------------------------------
echo -e "${BOLD}4. State Consistency${NC}"

if [[ -f "$STATE_FILE" ]]; then
    # Validate JSON
    if python3 -c "import json; json.load(open('${STATE_FILE}'))" 2>/dev/null; then
        check_pass "STATE.json is valid JSON"
    else
        check_fail "STATE.json is invalid JSON"
        check_warn "Attempting to regenerate from SQLite..."
        python3 "$RALPH_DIR/ralphctl.py" render-state 2>/dev/null || true
        check_fix "Regenerated STATE.json"
    fi

    # Check for stuck phase
    phase=$(python3 -c "import json; print(json.load(open('${STATE_FILE}')).get('phase',''))" 2>/dev/null || echo "")
    retry=$(python3 -c "import json; print(json.load(open('${STATE_FILE}')).get('retry_count',0))" 2>/dev/null || echo "0")

    if [[ "$retry" -ge 3 ]]; then
        check_warn "High retry count: ${retry} (may be stuck in reflect loop)"
    else
        check_pass "Retry count normal: ${retry}"
    fi

    # Check claimed items that may be abandoned
    if [[ -f "$DB_PATH" ]]; then
        claimed=$(python3 -c "
import sqlite3
db = sqlite3.connect('${DB_PATH}')
rows = db.execute(\"SELECT task_id, claimed_by FROM task_view WHERE status='claimed'\").fetchall()
for r in rows:
    print(f'{r[0]}:{r[1]}')
db.close()
" 2>/dev/null || true)

        if [[ -n "$claimed" ]]; then
            while IFS= read -r line; do
                check_warn "Claimed but not completed: ${line}"
            done <<< "$claimed"
        else
            check_pass "No abandoned claims"
        fi

        # Count consistency between STATE.json and SQLite
        state_done=$(python3 -c "import json; print(json.load(open('${STATE_FILE}')).get('items_done_count',0))" 2>/dev/null || echo "0")
        db_done=$(python3 -c "
import sqlite3
db = sqlite3.connect('${DB_PATH}')
print(db.execute(\"SELECT COUNT(*) FROM task_view WHERE status='done'\").fetchone()[0])
db.close()
" 2>/dev/null || echo "0")

        if [[ "$state_done" == "$db_done" ]]; then
            check_pass "Done count consistent: STATE=${state_done} DB=${db_done}"
        else
            check_warn "Done count mismatch: STATE=${state_done} DB=${db_done}"
            python3 "$RALPH_DIR/ralphctl.py" render-state 2>/dev/null || true
            check_fix "Regenerated STATE.json from SQLite"
        fi
    fi
fi

echo ""

# ---------------------------------------------------------------------------
# 5. Lock File Check
# ---------------------------------------------------------------------------
echo -e "${BOLD}5. Lock Files${NC}"

lock_files=$(ls "${RALPH_DIR}/locks/"*.lock 2>/dev/null || true)
if [[ -n "$lock_files" ]]; then
    while IFS= read -r lock; do
        lock_name=$(basename "$lock")
        # Check if the process holding the lock is still running
        lock_pid=$(cat "$lock" 2>/dev/null | head -1 || echo "")
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            check_pass "Lock ${lock_name}: held by PID ${lock_pid} (running)"
        else
            check_warn "Lock ${lock_name}: stale (PID ${lock_pid} not running)"
            rm -f "$lock"
            check_fix "Removed stale lock ${lock_name}"
        fi
    done <<< "$lock_files"
else
    check_pass "No lock files"
fi

echo ""

# ---------------------------------------------------------------------------
# 6. Pending Patches
# ---------------------------------------------------------------------------
echo -e "${BOLD}6. Pending Patches${NC}"

pending_dir="${RALPH_DIR}/commits/pending"
pending_patches=$(ls "$pending_dir"/*.patch 2>/dev/null || true)
if [[ -n "$pending_patches" ]]; then
    count=$(echo "$pending_patches" | wc -l)
    check_warn "${count} pending patch(es) awaiting merge"
    while IFS= read -r pf; do
        pf_name=$(basename "$pf")
        pf_size=$(stat -c%s "$pf" 2>/dev/null || stat -f%z "$pf" 2>/dev/null || echo "?")
        echo -e "    ${pf_name} (${pf_size} bytes)"
    done <<< "$pending_patches"
else
    check_pass "No pending patches"
fi

echo ""

# ---------------------------------------------------------------------------
# 7. Proposal Queue
# ---------------------------------------------------------------------------
echo -e "${BOLD}7. Proposals${NC}"

proposals=$(find "${RALPH_DIR}/proposals" -maxdepth 1 -name "prop_*.json" 2>/dev/null | wc -l)
processed=$(find "${RALPH_DIR}/proposals/processed" -maxdepth 1 -name "prop_*.json" 2>/dev/null | wc -l)

if [[ "$proposals" -gt 0 ]]; then
    check_warn "${proposals} unprocessed proposal(s)"
else
    check_pass "No unprocessed proposals"
fi
check_pass "${processed} processed proposals"

echo ""

# ---------------------------------------------------------------------------
# 8. Recovery Actions (Interactive)
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--fix" || "${1:-}" == "fix" ]]; then
    echo -e "${BOLD}=== Running Repair Actions ===${NC}"
    echo ""

    # Reset stuck claimed tasks
    python3 -c "
import sqlite3
db = sqlite3.connect('${DB_PATH}')
claimed = db.execute(\"SELECT task_id FROM task_view WHERE status='claimed'\").fetchall()
for row in claimed:
    db.execute(\"UPDATE task_view SET status='pending', claimed_by=NULL WHERE task_id=?\", (row[0],))
    print(f'  Reset {row[0]} from claimed to pending')
db.commit()
db.close()
" 2>/dev/null || true

    # Expire stale deferrals
    python3 "$RALPH_DIR/ralphctl.py" expire-stale-deferrals 2>/dev/null || true

    # Regenerate views
    python3 "$RALPH_DIR/ralphctl.py" render-state 2>/dev/null || true
    python3 "$RALPH_DIR/ralphctl.py" render-backlog 2>/dev/null || true

    # Process pending proposals
    python3 "$RALPH_DIR/ralphctl.py" process-proposals 2>/dev/null || true

    # Sync backlog
    python3 "$RALPH_DIR/ralphctl.py" sync-backlog 2>/dev/null || true

    echo ""
    echo -e "${GREEN}Repair actions completed.${NC}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo -e "${BOLD}=== Summary ===${NC}"
if [[ "$issues" -eq 0 ]]; then
    echo -e "${GREEN}All checks passed. System healthy.${NC}"
elif [[ "$fixed" -ge "$issues" ]]; then
    echo -e "${YELLOW}Found ${issues} issue(s), fixed ${fixed}. System repaired.${NC}"
else
    remaining=$((issues - fixed))
    echo -e "${RED}Found ${issues} issue(s), fixed ${fixed}. ${remaining} remaining.${NC}"
    if [[ "${1:-}" != "--fix" && "${1:-}" != "fix" ]]; then
        echo ""
        echo "Run with --fix to attempt automatic repair:"
        echo "  ./scripts/ralph-repair.sh --fix"
    fi
fi
