#!/usr/bin/env bash
# ralph-monitor.sh — Real-time monitoring dashboard for Ralph Loop v3.
# Displays live status, metrics, and event log summaries.
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="${PROJ_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RALPH_DIR="${PROJ_DIR}/.ralph"
DB_PATH="${RALPH_DIR}/ralph.db"
STATE_FILE="${RALPH_DIR}/STATE.json"
LOG_DIR="${RALPH_DIR}/logs"
DATE_TAG=$(date -u +%Y%m%d)
METRICS_FILE="${LOG_DIR}/par-metrics-${DATE_TAG}.jsonl"
NOHUP_LOG="${LOG_DIR}/parallel-nohup.log"
REFRESH_INTERVAL="${1:-5}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
state_field() {
    python3 -c "import json; print(json.load(open('${STATE_FILE}')).get('$1', '$2'))" 2>/dev/null || echo "$2"
}

db_query() {
    python3 -c "
import sqlite3
db = sqlite3.connect('${DB_PATH}')
db.row_factory = sqlite3.Row
rows = db.execute(\"\"\"$1\"\"\").fetchall()
for r in rows:
    print('|'.join(str(r[i]) for i in range(len(r.keys()))))
db.close()
" 2>/dev/null || true
}

db_scalar() {
    python3 -c "
import sqlite3
db = sqlite3.connect('${DB_PATH}')
result = db.execute(\"\"\"$1\"\"\").fetchone()
print(result[0] if result else '0')
db.close()
" 2>/dev/null || echo "0"
}

# ---------------------------------------------------------------------------
# Dashboard Sections
# ---------------------------------------------------------------------------
print_header() {
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║          Ralph Loop v3 — Live Monitoring Dashboard          ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${DIM}$(date -u +%Y-%m-%dT%H:%M:%SZ) | Project: $(basename "$PROJ_DIR") | Refresh: ${REFRESH_INTERVAL}s${NC}"
    echo ""
}

print_state() {
    local phase iteration current_item current_wave commits retry
    phase=$(state_field "phase" "unknown")
    iteration=$(state_field "iteration" "0")
    current_item=$(state_field "current_item" "none")
    current_wave=$(state_field "current_wave" "0")
    commits=$(state_field "commits_total" "0")
    retry=$(state_field "retry_count" "0")

    # Color-code phase
    local phase_color
    case "$phase" in
        assess|commit)    phase_color="${GREEN}" ;;
        implement)        phase_color="${CYAN}" ;;
        plan)             phase_color="${BLUE}" ;;
        verify)           phase_color="${YELLOW}" ;;
        reflect)          phase_color="${RED}" ;;
        *)                phase_color="${NC}" ;;
    esac

    echo -e "${BOLD}── Agent State ──${NC}"
    echo -e "  Phase:     ${phase_color}${phase}${NC}"
    echo -e "  Iteration: ${iteration}"
    echo -e "  Current:   ${current_item:-none}"
    echo -e "  Wave:      ${current_wave}"
    echo -e "  Commits:   ${commits}"
    if [[ "$retry" -gt 0 ]]; then
        echo -e "  Retries:   ${RED}${retry}${NC}"
    fi
    echo ""
}

print_task_summary() {
    echo -e "${BOLD}── Task Summary ──${NC}"

    local done pending claimed proposed deferred blocked dropped total
    done=$(db_scalar "SELECT COUNT(*) FROM task_view WHERE status='done'")
    pending=$(db_scalar "SELECT COUNT(*) FROM task_view WHERE status='pending'")
    claimed=$(db_scalar "SELECT COUNT(*) FROM task_view WHERE status='claimed'")
    proposed=$(db_scalar "SELECT COUNT(*) FROM task_view WHERE status='proposed'")
    deferred=$(db_scalar "SELECT COUNT(*) FROM task_view WHERE status='deferred'")
    blocked=$(db_scalar "SELECT COUNT(*) FROM task_view WHERE status='blocked'")
    dropped=$(db_scalar "SELECT COUNT(*) FROM task_view WHERE status='dropped'")
    total=$(db_scalar "SELECT COUNT(*) FROM task_view")

    # Progress bar
    if [[ "$total" -gt 0 ]]; then
        local pct=$((done * 100 / total))
        local bar_width=40
        local filled=$((pct * bar_width / 100))
        local empty=$((bar_width - filled))
        printf "  Progress:  [${GREEN}"
        printf '%0.s█' $(seq 1 $filled 2>/dev/null) || true
        printf "${DIM}"
        printf '%0.s░' $(seq 1 $empty 2>/dev/null) || true
        echo -e "${NC}] ${pct}%"
    fi

    echo -e "  ${GREEN}done=${done}${NC}  pending=${pending}  claimed=${claimed}  proposed=${proposed}"
    if [[ "$deferred" -gt 0 ]]; then
        echo -e "  ${YELLOW}deferred=${deferred}${NC}  ${RED}blocked=${blocked}${NC}  dropped=${dropped}  total=${total}"
    else
        echo -e "  deferred=${deferred}  ${RED}blocked=${blocked}${NC}  dropped=${dropped}  total=${total}"
    fi
    echo ""
}

print_patch_summary() {
    echo -e "${BOLD}── Patch Summary ──${NC}"

    local queued promoted discarded
    queued=$(db_scalar "SELECT COUNT(*) FROM patch_view WHERE status='queued'")
    promoted=$(db_scalar "SELECT COUNT(*) FROM patch_view WHERE status='promoted'")
    discarded=$(db_scalar "SELECT COUNT(*) FROM patch_view WHERE status='discarded'")

    echo -e "  ${GREEN}promoted=${promoted}${NC}  queued=${queued}  ${RED}discarded=${discarded}${NC}"

    # Pending patches in filesystem
    local pending_files
    pending_files=$(ls "${RALPH_DIR}/commits/pending/"*.patch 2>/dev/null | wc -l || echo "0")
    if [[ "$pending_files" -gt 0 ]]; then
        echo -e "  ${YELLOW}Pending merge: ${pending_files} patch file(s)${NC}"
    fi
    echo ""
}

print_event_activity() {
    echo -e "${BOLD}── Event Activity ──${NC}"

    local total_events events_1h events_10m
    total_events=$(db_scalar "SELECT COUNT(*) FROM events")
    events_1h=$(db_scalar "SELECT COUNT(*) FROM events WHERE ts > datetime('now', '-1 hour')")
    events_10m=$(db_scalar "SELECT COUNT(*) FROM events WHERE ts > datetime('now', '-10 minutes')")

    echo "  Total events: ${total_events}"
    echo "  Last hour:    ${events_1h}"
    echo "  Last 10 min:  ${events_10m}"
    echo ""
}

print_recent_events() {
    echo -e "${BOLD}── Recent Events (last 10) ──${NC}"

    python3 -c "
import sqlite3
db = sqlite3.connect('${DB_PATH}')
db.row_factory = sqlite3.Row
rows = db.execute(
    'SELECT ts, entity_id, event_type, actor FROM events ORDER BY ts DESC LIMIT 10'
).fetchall()
for r in rows:
    ts = r['ts'][11:19] if r['ts'] else '?'
    print(f\"  {ts}  {r['event_type']:<25} {r['entity_id']:<12} ({r['actor']})\")
db.close()
" 2>/dev/null || echo "  (no events)"
    echo ""
}

print_deferred_items() {
    local deferred_count
    deferred_count=$(db_scalar "SELECT COUNT(*) FROM task_view WHERE status='deferred'")

    if [[ "$deferred_count" -gt 0 ]]; then
        echo -e "${BOLD}── Deferred Items (${deferred_count}) ──${NC}"
        python3 -c "
import sqlite3
db = sqlite3.connect('${DB_PATH}')
db.row_factory = sqlite3.Row
rows = db.execute(
    'SELECT task_id, title, risk_tier, deferred_reason FROM task_view WHERE status=\"deferred\" ORDER BY deferred_at'
).fetchall()
for r in rows:
    title = (r['title'] or 'Untitled')[:40]
    reason = (r['deferred_reason'] or '')[:30]
    print(f\"  {r['task_id']:<10} T{r['risk_tier'] or '?'}  {title:<42} {reason}\")
db.close()
" 2>/dev/null
        echo ""
    fi
}

print_metrics_summary() {
    if [[ ! -f "$METRICS_FILE" ]]; then
        return
    fi

    echo -e "${BOLD}── Today's Metrics ──${NC}"

    python3 -c "
import json

total_cost = 0
total_iters = 0
agent_a_cost = 0
agent_b_cost = 0
agent_a_iters = 0
agent_b_iters = 0
errors = 0

with open('$METRICS_FILE') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            m = json.loads(line)
        except:
            continue
        cost = float(m.get('cost', 0))
        total_cost += cost
        total_iters += 1
        if m.get('agent') == 'A':
            agent_a_cost += cost
            agent_a_iters += 1
        else:
            agent_b_cost += cost
            agent_b_iters += 1
        if m.get('subtype', '') != 'success':
            errors += 1

print(f'  Total cost:   \${total_cost:.2f}')
print(f'  Invocations:  {total_iters} (A={agent_a_iters}, B={agent_b_iters})')
print(f'  Primary (A):  \${agent_a_cost:.2f}')
print(f'  Worker (B):   \${agent_b_cost:.2f}')
if errors > 0:
    print(f'  Errors:       {errors}')
" 2>/dev/null || echo "  (no metrics data)"
    echo ""
}

print_process_status() {
    echo -e "${BOLD}── Process Status ──${NC}"

    # Check if ralph-parallel.sh is running
    local parallel_pids
    parallel_pids=$(pgrep -f "ralph-parallel.sh" 2>/dev/null || true)
    if [[ -n "$parallel_pids" ]]; then
        echo -e "  ralph-parallel.sh: ${GREEN}RUNNING${NC} (PID: $(echo "$parallel_pids" | tr '\n' ','))"
    else
        echo -e "  ralph-parallel.sh: ${RED}STOPPED${NC}"
    fi

    # Check for claude processes
    local claude_pids
    claude_pids=$(pgrep -f "claude -p" 2>/dev/null | wc -l || echo "0")
    if [[ "$claude_pids" -gt 0 ]]; then
        echo -e "  Claude instances:  ${GREEN}${claude_pids} active${NC}"
    else
        echo -e "  Claude instances:  ${DIM}none${NC}"
    fi

    # Check lock files
    local locks
    locks=$(ls "${RALPH_DIR}/locks/"*.lock 2>/dev/null | wc -l || echo "0")
    if [[ "$locks" -gt 0 ]]; then
        echo -e "  Active locks:     ${YELLOW}${locks}${NC}"
    fi

    echo ""
}

print_recent_log() {
    echo -e "${BOLD}── Recent Log ──${NC}"
    if [[ -f "$NOHUP_LOG" ]]; then
        tail -5 "$NOHUP_LOG" 2>/dev/null | while read -r line; do
            echo -e "  ${DIM}${line}${NC}"
        done
    else
        echo -e "  ${DIM}(no log file)${NC}"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Check mode
MODE="${1:-live}"
case "$MODE" in
    --once|once|status)
        # Single snapshot
        print_header
        if [[ -f "$DB_PATH" ]]; then
            print_state
            print_task_summary
            print_patch_summary
            print_event_activity
            print_recent_events
            print_deferred_items
            print_metrics_summary
            print_process_status
        else
            echo -e "${RED}No database found at ${DB_PATH}${NC}"
            echo "Run ralph-init.sh first."
        fi
        exit 0
        ;;
    --help|-h)
        echo "Usage: ralph-monitor.sh [--once|live] [refresh_seconds]"
        echo ""
        echo "Modes:"
        echo "  live (default)  Continuous refresh dashboard"
        echo "  --once          Single snapshot and exit"
        echo ""
        echo "Options:"
        echo "  refresh_seconds  Refresh interval for live mode (default: 5)"
        exit 0
        ;;
    *)
        # Live mode — use the argument as refresh interval if numeric
        if [[ "$MODE" =~ ^[0-9]+$ ]]; then
            REFRESH_INTERVAL="$MODE"
        fi
        ;;
esac

# Live dashboard loop
if [[ ! -f "$DB_PATH" ]]; then
    echo -e "${RED}No database found at ${DB_PATH}${NC}"
    echo "Run ralph-init.sh first."
    exit 1
fi

while true; do
    clear
    print_header
    print_state
    print_task_summary
    print_patch_summary
    print_event_activity
    print_recent_events
    print_deferred_items
    print_metrics_summary
    print_process_status
    print_recent_log
    echo -e "${DIM}Press Ctrl+C to exit. Refreshing every ${REFRESH_INTERVAL}s...${NC}"
    sleep "$REFRESH_INTERVAL"
done
