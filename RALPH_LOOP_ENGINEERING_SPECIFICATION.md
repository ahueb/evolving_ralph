# Ralph Loop v3 — Engineering Specification

**Version**: 3.0.0
**Date**: 2026-03-25
**Status**: Active — Production
**Constraint**: Fully autonomous. Zero human gates. All decisions via policy. Humans override asynchronously, never block.

---

## 1. Overview

Ralph Loop is a **language-agnostic, event-sourced autonomous software engineering system**. It runs two parallel LLM agents that continuously implement, test, and commit code changes to any software project. All agent activity produces proposals; only the control plane advances truth. Truth lives in an append-only SQLite event log. All mutable files (STATE.json, BACKLOG.md) are derived views.

The system is bootstrapped for any project via `ralph-init.sh`, which auto-detects the language and generates all configuration, phase files, and data structures.

### 1.1 Design Principles

| # | Principle | Implementation |
|---|-----------|---------------|
| 1 | **Proposals, not mutations** | Agents propose plans/patches/items. Control plane decides. |
| 2 | **Event-sourced truth** | SQLite append-only log. STATE.json and BACKLOG.md are derived views. |
| 3 | **Transactional task lifecycle** | Task cannot be `done` until its patch is `promoted` in the event log. |
| 4 | **Risk-tiered autonomy** | Tier 0-1 auto-promote. Tier 2 deferred to independent judge. Tier 3 decomposed. |
| 5 | **Generator/Judge separation** | Independent judge reviews deferred items in separate invocation. |
| 6 | **Fresh context per invocation** | State on disk. Each agent call starts clean — no context degradation. |
| 7 | **Machine-verifiable gates** | Build, test, pattern grep. Never trust agent self-assessment. |
| 8 | **The loop never blocks on a human** | Deferred items auto-expire. Humans override asynchronously. |

Research basis: Reflexion (NeurIPS 2023), SWE-agent (NeurIPS 2024), OpenHands (ICLR 2025), AutoCodeRover (ISSTA 2024), Aider architect/editor split, Self-Refine (NeurIPS 2023), CodeAct, Ralph Loop (asdlc.io).

### 1.2 Supported Languages

`ralph-init.sh` generates project-specific configuration for:

| Language | Build | Test | Lint | Forbidden Patterns |
|----------|-------|------|------|--------------------|
| **Rust** | `cargo check --workspace` | `cargo test --workspace` | `cargo clippy` | `.unwrap()`, `.expect()`, `panic!()` outside tests |
| **Python** | `python -m py_compile` | `pytest` | `ruff check` | `bare except:`, `eval(`, `import *` |
| **TypeScript** | `npm run build` | `npm test` | `eslint` | `any` type, `console.log` in prod, `eval(` |
| **Go** | `go build ./...` | `go test ./...` | `golangci-lint` | `panic()` in libraries, `os.Exit()` outside main |
| **Java** | `mvn compile` | `mvn test` | `checkstyle` | `System.out.println`, `catch (Exception)` without logging |
| **Ruby** | `ruby -c` | `rspec` | `rubocop` | `eval(`, `puts` in production, `rescue Exception` |
| **C#** | `dotnet build` | `dotnet test` | `dotnet format` | `Console.WriteLine`, `Thread.Sleep` in async |
| **Generic** | `make build` | `make test` | `make lint` | `TODO`, `FIXME`, `HACK` |

---

## 2. Architecture

### 2.1 System Diagram

```
ralph-parallel.sh (control harness, ~780 lines bash)
│
├── ralphctl.py (control plane, ~790 lines Python)
│   ├── SQLite event log (ralph.db)     ── Append-only canonical truth
│   ├── task_view                        ── Materialized from events
│   ├── patch_view                       ── Materialized from events
│   ├── Risk classifier                  ── Tier 0-3 from file patterns
│   ├── Policy engine                    ── Auto-promote / defer / decompose
│   ├── Proposal processor               ── Auto-accept high-confidence items
│   ├── Deferred expiry                  ── Auto-expire stale deferrals
│   └── View renderer                    ── STATE.json + BACKLOG.md from SQLite
│
├── Primary Agent (A)                    ── Sequential state machine, main branch
│   ├── build_primary_prompt()           ── Token-efficient prompt (~2-9KB)
│   ├── claude -p                        ── One phase per invocation
│   ├── extract_metrics()                ── Full token/turn/cost extraction
│   ├── apply_pending_patches()          ── Git plumbing merge + promote-patch
│   ├── sync_primary_completions()       ── BACKLOG.md done → SQLite task_view
│   └── adaptive_sleep()                 ── 5-15s between phases
│
├── Worker Agent (B)                     ── Full-cycle in worktree, all waves
│   ├── pick_worker_item()               ── SQLite query: S-effort, no unmet deps
│   ├── task.claimed event               ── Logged before execution
│   ├── build_worker_prompt()            ── Ultra-lean prompt (~3.5KB)
│   ├── claude -p                        ── Full plan→implement→verify→commit
│   ├── queue-patch                      ── Deferred merge (NOT mark done)
│   └── merge_worker_to_main()           ── format-patch → pending/
│
└── Independent Judge                    ── Separate invocation, no shared context
    ├── review_deferred phase            ── Triggers when deferred queue ≥ 3
    └── approve / reject / modify        ── Via ralphctl resolve-deferred
```

### 2.2 Data Flow

```
Agent produces artifact (plan, diff, proposal)
  → Control plane validates (risk tier, policy check)
    → Tier 0-1: auto-promote after verification
    → Tier 2: defer to independent judge
    → Tier 3: decompose into smaller tasks
  → Promoted patch: git plumbing commit + task.completed event
  → Derived views regenerated (STATE.json, BACKLOG.md)
  → Agents see updated views on next invocation
```

---

## 3. Canonical Data Model (SQLite)

### 3.1 Event Log (append-only truth)

```sql
CREATE TABLE events (
    event_id    TEXT PRIMARY KEY,   -- 'evt_{timestamp}_{hash}'
    ts          TEXT NOT NULL,      -- ISO 8601
    run_id      TEXT NOT NULL,      -- 'run_{date}_{instance}'
    entity_type TEXT NOT NULL,      -- 'task' | 'patch' | 'run' | 'incident' | 'spec_proposal'
    entity_id   TEXT NOT NULL,      -- 'W3-014' | 'patch_001'
    event_type  TEXT NOT NULL,      -- 'task.claimed' | 'patch.promoted' | etc.
    actor       TEXT NOT NULL,      -- 'control_plane' | 'primary' | 'worker-b' | 'judge'
    payload     TEXT NOT NULL       -- JSON blob
);
```

Event types: `task.migrated`, `task.claimed`, `task.proposed`, `task.completed`, `task.deferred`, `task.deferral_expired`, `task.deferral_resolved`, `patch.queued`, `patch.promoted`, `patch.discarded`

### 3.2 Task View (materialized projection)

```sql
CREATE TABLE task_view (
    task_id     TEXT PRIMARY KEY,
    status      TEXT NOT NULL,      -- pending|claimed|proposed|done|deferred|blocked|dropped
    title       TEXT,
    source      TEXT,               -- spec reference (e.g., 'ES:42.3')
    effort      TEXT,               -- S|M|L|XL
    deps        TEXT,               -- comma-separated task IDs or '-'
    wave        INTEGER,
    risk_tier   INTEGER DEFAULT 1,  -- 0=trivial, 1=normal, 2=sensitive, 3=restricted
    claimed_by  TEXT,               -- executor ID
    patch_id    TEXT,               -- winning patch ID (set on promotion)
    version     INTEGER DEFAULT 1,  -- increments on every status change
    deferred_reason TEXT,
    deferred_at TEXT,
    provenance  TEXT DEFAULT 'spec' -- 'spec' | 'auto' | 'human' | 'decomposed'
);
```

### 3.3 Patch View (materialized projection)

```sql
CREATE TABLE patch_view (
    patch_id    TEXT PRIMARY KEY,
    task_id     TEXT NOT NULL,
    status      TEXT NOT NULL,      -- queued|applied|verified|promoted|discarded
    patch_path  TEXT,
    created_by  TEXT,
    created_at  TEXT,
    applied_at  TEXT,
    commit_hash TEXT                -- git SHA after promotion
);
```

### 3.4 Derived Views

STATE.json and BACKLOG.md are **regenerated from SQLite** after every state change. They preserve the exact schema that agents expect, ensuring prompt compatibility. Agents never know the truth lives in SQLite.

---

## 4. State Machine

### 4.1 Phase Diagram

```
  assess ──► plan ──► implement ──► verify ──► reflect
    ▲                                  │          │
    │                                  │     [PASS]│[FAIL]
    │                               ┌──┘          │
    │                               ▼             ▼
    │                          commit ◄── retry (max 3)
    │                             │
    │                             ▼
    │                 ┌── review_deferred (if deferred ≥ 3)
    │                 ├── test_integration (if >30 commits overdue)
    │                 ├── test_ui (if >30 commits overdue)
    │                 ├── evolve_goals (every 5 commits)
    │                 └── refactor_dry (every 5 commits)
    │                             │
    └─────────────────────────────┘
```

### 4.2 Phase Specifications

| Phase | Prompt Size | Avg Cost | Avg Duration | Avg Turns | Description |
|-------|-------------|----------|--------------|-----------|-------------|
| **assess** | 6.5KB | $0.14 | 25s | 3 | Pick next item, check periodic overrides |
| **plan** | 8.7KB | $0.50 | 140s | 17 | Read specs, find code, pre-scan for violations, write plan |
| **implement** | 6.7KB | $0.70 | 200s | 16 | Execute one sub-step, immediate build check |
| **verify** | 6.3KB | $0.27 | 80s | 10 | Machine gates: build, test, forbidden pattern grep |
| **reflect** | 7.0KB | $0.66 | 188s | 12 | Classify error, persist lesson, decide retry/replan/block |
| **commit** | 2.2KB | $0.27 | 65s | 8 | Git commit, update backlog, increment counters |
| **evolve_goals** | 9.7KB | $0.60 | 160s | 24 | Emit proposals (not mutations), scan specs, decompose |
| **refactor_dry** | 2.4KB | $1.50 | 350s | 30 | Eliminate duplication in recent commits |
| **review_deferred** | varies | $0.25 | 80s | 10 | Independent judge reviews deferred queue |
| **test_integration** | varies | $0.90 | 600s | 50 | Full test suite |
| **test_ui** | varies | $0.27 | 75s | 13 | Browser/E2E tests |

### 4.3 Periodic Phase Priority

When the primary enters `assess`, the control plane checks in order:

1. **test_integration** if >30 commits overdue (prevents test debt)
2. **test_ui** if >30 commits overdue
3. **review_deferred** if deferred queue ≥ 3 items
4. **evolve_goals** if ≥5 commits since last
5. **refactor_dry** if ≥5 commits since last
6. **test_integration** if ≥10 commits since last
7. **test_ui** if ≥15 commits since last

---

## 5. Task Lifecycle (Transactional)

```
pending                          ── Eligible for work
  → claimed                      ── Assigned to an executor (event logged)
    → proposed                   ── Patch/plan artifact exists
      → [verify passes]
        → Tier 0-1: promoted     ── Patch applied, task done (atomic)
        → Tier 2: deferred       ── Independent judge will review
        → Tier 3: decomposed     ── Split into smaller safe tasks
      → [verify fails]
        → reflect → retry/replan

deferred                         ── Awaiting judge review
  → approved → done              ── Judge approves
  → rejected → pending           ── Judge rejects, agent retries
  → expired → pending            ── Auto-expire after 20 commits, tier lowered

blocked                          ── Dependencies unmet or fundamental failure
dropped                          ── Obsolete, removed by evolve_goals
```

**Critical invariant: No task reaches `done` without a `promoted` patch in the event log.**

---

## 6. Patch Lifecycle

```
queued      ── Worker generated patch, saved to commits/pending/
  → applied ── Git plumbing applied to temp index
    → promoted ── Commit created, HEAD advanced, task→done (ATOMIC)
  → discarded  ── Conflict or stale, task reverts to pending
```

### 6.1 Git Plumbing Merge (Zero Working-Tree Conflicts)

```bash
# 1. Create temporary index from current HEAD
tmp_idx=$(mktemp)
GIT_INDEX_FILE="$tmp_idx" git read-tree HEAD

# 2. Apply patch to temp index only (exclude .ralph/ to avoid backlog conflicts)
GIT_INDEX_FILE="$tmp_idx" git apply --cached --3way --exclude='.ralph/*' "$patch"

# 3. Write tree object from temp index
new_tree=$(GIT_INDEX_FILE="$tmp_idx" git write-tree)

# 4. Create commit with HEAD as parent
new_commit=$(git commit-tree "$new_tree" -p HEAD -m "$message")

# 5. Advance HEAD
git update-ref HEAD "$new_commit"

# 6. Promote in event log (ATOMIC: patch→promoted + task→done)
ralphctl.py promote-patch "$patch_id" "$new_commit"
```

This approach **never touches the working tree**, so the primary agent's in-progress edits are unaffected. Merge success rate: **100%**.

---

## 7. Risk Classification

### 7.1 Tier Definitions

| Tier | Scope | Autonomy | Examples |
|------|-------|----------|---------|
| **0 — Trivial** | Non-runtime config, docs, schemas, test fixtures | Auto-promote after deterministic verification | Schema YAML, CI config, README, test data |
| **1 — Normal** | Standard product code | Auto-promote after full verification | Helper refactors, validators, parsers |
| **2 — Sensitive** | Auth, data paths, migrations, regulated code | Defer to independent judge | SQL migrations, auth handlers, export pipelines |
| **3 — Restricted** | Secrets, destructive ops, broad rewrites | Decompose into smaller safe tasks | Key material, `DROP TABLE`, compliance outputs |

### 7.2 Classification Algorithm

Computed from file patterns in the plan's `files_modify` + `files_create`:

```python
# Tier 3: check first (most restrictive)
if any file matches tier3_patterns: return 3

# Tier 2: sensitive paths
if any file matches tier2_patterns: return 2
if task source matches tier2_sources: return 2

# Tier 0: trivial paths + S-effort
if effort == 'S' and all files match tier0_patterns: return 0

# Default: Tier 1
return 1
```

Patterns are configurable per project via `ralph.config.json` or `ralphctl.py` RISK_PATTERNS dict.

### 7.3 Autonomous Resolution (No Human Gates)

- **Tier 0-1**: Auto-promote after verification passes.
- **Tier 2**: Deferred to `review_deferred` phase. Independent judge Claude invocation reviews the diff against the specific concern. Approve/reject/modify.
- **Tier 3**: Control plane emits decompose proposal. Agent breaks restricted task into Tier 1-2 sub-tasks. Parent task → `superseded`.
- **Expiry**: Deferred items auto-expire to `pending` after 20 commits with lowered tier.

---

## 8. Independent Judge

The judge is a **separate Claude invocation** that does not share context with the generator. It runs as the `review_deferred` phase when the deferred queue reaches ≥3 items.

### 8.1 Judge Prompt

```
You are an INDEPENDENT JUDGE. You did NOT generate the changes you are reviewing.
For each deferred item:
1. Read the deferral reason
2. Read the diff (git show <commit>)
3. Evaluate against the specific concern
4. Decide: APPROVE / REJECT / MODIFY
```

### 8.2 Judge Decisions

- **APPROVE**: `ralphctl resolve-deferred <task_id> approve judge "<rationale>"`
- **REJECT**: `ralphctl resolve-deferred <task_id> reject judge "<rationale>"` + lesson to REFLECTIONS.md
- **MODIFY**: `ralphctl resolve-deferred <task_id> modify judge "<fix instructions>"`

Cost: ~$0.25 per invocation. Frequency: ~once per hour.

---

## 9. Self-Evolution (Proposal Model)

### 9.1 How evolve_goals Works in v3

The `evolve_goals` phase **emits proposals** to `.ralph/proposals/`, NOT direct backlog mutations:

```json
{
  "proposal_type": "new_task",
  "confidence": 0.85,
  "task": {"id": "W3-035", "title": "...", "source": "ES:42.3", "effort": "S", "wave": 3, "deps": "-"},
  "rationale": "Found in spec section 42.3, not covered by existing items"
}
```

### 9.2 Auto-Acceptance Policy

| Proposal Type | Auto-Accept Condition | Otherwise |
|---------------|----------------------|-----------|
| New S-effort, no deps, confidence ≥0.7 | Accept | Defer to judge |
| New S/M-effort, confidence ≥0.8 | Accept | Defer to judge |
| Decompose (all sub-tasks S-effort) | Accept | Defer to judge |
| Drop task | Always defer | Judge must confirm |
| Reprioritize (±1 wave) | Accept | Defer to judge |

### 9.3 Backlog Growth Control

- Max backlog size: 300 items
- Max pending per wave: 50 items
- Proposals exceeding limits are deferred

---

## 10. Control Plane (ralphctl.py)

### 10.1 CLI Commands

```bash
ralphctl.py init                           # Migrate BACKLOG.md → SQLite (one-time)
ralphctl.py emit-event <type> <id> <event> <actor> <payload>
ralphctl.py transition-task <id> <status> <actor> [payload]
ralphctl.py pick-ready-task <worker|primary> [--exclude <id>]
ralphctl.py queue-patch <task_id> <path> <created_by>
ralphctl.py promote-patch <patch_id> <commit_hash>
ralphctl.py discard-patch <patch_id> <reason>
ralphctl.py classify-risk <task_id>
ralphctl.py policy-check <task_id> [<patch_id>]
ralphctl.py get-deferred-queue [--format prompt|json]
ralphctl.py should-review-deferred
ralphctl.py resolve-deferred <id> <approve|reject|modify> <actor> <rationale>
ralphctl.py expire-stale-deferrals
ralphctl.py process-proposals
ralphctl.py render-state                   # Regenerate STATE.json from events
ralphctl.py render-backlog                 # Regenerate BACKLOG.md from task_view
ralphctl.py status                         # Summary: done/pending/deferred/blocked
```

### 10.2 Integration Points

The bash harness calls `ralphctl.py` at these points:

| When | Call | Purpose |
|------|------|---------|
| Worker picks item | `pick-ready-task worker` | SQLite query for S-effort items |
| Worker picks item | `transition-task <id> claimed worker-b` | Log claim event |
| Worker completes | `queue-patch <id> <path> worker-b` | Queue patch, mark task proposed |
| Primary applies patch | `promote-patch <id> <hash>` | Atomic: patch→promoted + task→done |
| Patch conflicts | `discard-patch <id> conflict` | Revert task to pending |
| After commit phase | sync BACKLOG.md done → SQLite | Catch primary-agent completions |
| After every iteration | `render-state` | Regenerate STATE.json |
| After every iteration | `expire-stale-deferrals` | Auto-expire old deferrals |
| After evolve_goals | `process-proposals` | Auto-accept/defer new proposals |
| Periodic check | `should-review-deferred` | Trigger judge phase |

### 10.3 Internal Architecture

`ralphctl.py` is a single-file Python module (~793 lines) using only standard library (`sqlite3`, `json`, `os`, `re`, `hashlib`, `datetime`, `pathlib`, `sys`). No external dependencies.

#### 10.3.1 Constants

```python
RALPH_DIR = os.environ.get('RALPH_DIR', os.path.dirname(__file__))
DB_PATH = os.path.join(RALPH_DIR, 'ralph.db')
STATE_PATH = os.path.join(RALPH_DIR, 'STATE.json')
BACKLOG_PATH = os.path.join(RALPH_DIR, 'BACKLOG.md')
PROPOSALS_DIR = os.path.join(RALPH_DIR, 'proposals')

DEFERRAL_EXPIRY_COMMITS = 20   # auto-expire deferred items after this many commits
MAX_BACKLOG_SIZE = 300          # reject proposals if backlog exceeds this
MAX_PENDING_PER_WAVE = 50       # reject proposals if wave exceeds this
```

#### 10.3.2 Risk Classification Patterns (Project-Configurable)

```python
RISK_PATTERNS = {
    'tier2_files': ['sql/migrations/', 'handlers/auth/', ...],  # sensitive paths
    'tier2_sources': ['ES:30', 'ES:67', ...],                   # sensitive spec refs
    'tier3_files': ['.env', 'secrets', 'credentials', ...],     # restricted paths
    'tier3_keywords': ['DROP TABLE', 'DROP COLUMN', ...],       # restricted operations
    'tier0_files': ['schemas/', 'docs/', 'test_data/', ...],    # trivial paths
    'tier0_effort': ['S'],                                       # trivial effort level
}
```

When rebuilding for a new project, replace these patterns with project-appropriate paths and keywords.

#### 10.3.3 Database Connection

```python
def get_db():
    db = sqlite3.connect(DB_PATH)
    db.row_factory = sqlite3.Row       # dict-like row access
    db.execute("PRAGMA journal_mode=WAL")   # concurrent reads
    db.execute("PRAGMA busy_timeout=5000")  # 5s retry on lock
    _ensure_schema(db)                  # create tables if missing
    return db
```

Schema auto-creates on first connection. Tables defined in §3.

#### 10.3.4 Event Emission

```python
def emit_event(db, entity_type, entity_id, event_type, actor, payload=None):
    """Append to canonical log. Event ID = 'evt_{ts}_{md5hash[:8]}'."""
    ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    event_id = f"evt_{ts_compact}_{hash8}"
    db.execute("INSERT INTO events (...) VALUES (...)")
    db.commit()
    return event_id
```

Every state mutation goes through `emit_event`. This is the append-only truth guarantee.

#### 10.3.5 Task Operations

**`transition_task(db, task_id, new_status, actor, **extra)`**
- Emits `task.{new_status}` event with old/new status in payload
- Updates `task_view` row: status, version++
- If `new_status == 'deferred'`: sets `deferred_reason` and `deferred_at`
- If `new_status in ('pending', 'done', 'claimed')`: clears deferral fields
- Accepts optional `claimed_by`, `patch_id`, `risk_tier` in `**extra`
- If task doesn't exist in task_view, INSERTs it

**`pick_ready_task(db, executor_type, exclude_task_id=None)`**
- Worker mode: `SELECT task_id FROM task_view WHERE status='pending' AND effort='S' ORDER BY wave, task_id`
- Primary mode: `SELECT ... WHERE status='pending' ORDER BY CASE WHEN wave=current THEN 0 ELSE 1 END, wave, task_id`
- For each candidate: checks deps by querying `task_view WHERE task_id IN (dep_ids) AND status='done'`
- Returns first task with all deps met, or `'NONE'`

#### 10.3.6 Patch Operations

**`queue_patch(db, task_id, patch_path, created_by)`**
- Generates `patch_id = f"patch_{task_id}_{timestamp}"`
- Emits `patch.queued` event
- INSERTs into `patch_view` with `status='queued'`
- Calls `transition_task(task_id, 'proposed', created_by)`
- Returns patch_id

**`promote_patch(db, patch_id, commit_hash)`** — THE v3 CORRECTNESS GUARANTEE
- Looks up patch in `patch_view`
- Emits `patch.promoted` event with commit hash
- Emits `task.completed` event for the patch's task
- Updates `patch_view`: `status='promoted'`, `commit_hash=hash`
- Updates `task_view`: `status='done'`, `patch_id=patch_id`
- **Atomic**: both updates in same SQLite transaction
- Returns True on success

**`discard_patch(db, patch_id, reason)`**
- Emits `patch.discarded` event
- Updates `patch_view`: `status='discarded'`
- Reverts task to `pending` via `transition_task`

#### 10.3.7 Risk Classification

**`classify_risk(db, task_id)`** → returns integer 0-3
- Reads task from `task_view`
- Reads `current_plan` from STATE.json if task is current item (for file list)
- Checks files against `RISK_PATTERNS` in order: tier 3 → tier 2 → tier 0 → default tier 1
- Falls back to source-tag matching if no plan/files available

**`policy_check(db, task_id, patch_id=None)`** → returns `(decision, reason)`
- Calls `classify_risk`
- Stores computed tier in `task_view.risk_tier`
- Tier 0: `('promote', 'tier-0 auto-promote')`
- Tier 1: `('promote', 'tier-1 auto-promote after verification')`
- Tier 2: `('defer', 'tier-2 requires independent judge review')`
- Tier 3: `('decompose', 'tier-3 restricted — decompose into smaller tasks')`

#### 10.3.8 Deferred Queue Management

**`get_deferred_queue(db)`** → list of dicts
- `SELECT ... FROM task_view WHERE status='deferred' ORDER BY deferred_at ASC`

**`should_review_deferred(db)`** → bool
- True if deferred count ≥ 3
- True if any deferred item has ≥30 events since deferral (proxy for ~10 commits)

**`resolve_deferred(db, task_id, decision, actor, rationale)`**
- `approve`: emits `task.deferral_resolved`, transitions to `done` (if patch has commit) or `pending`
- `reject`: emits event, transitions to `pending`
- `modify`: emits event, transitions to `pending` (agent will re-plan with fix instructions)

**`expire_stale_deferrals(db)`** → count of expired items
- For each deferred item: counts events since `deferred_at`
- If events ≥ `DEFERRAL_EXPIRY_COMMITS * 3` (~60 events): auto-expire
- Lowers risk tier by 1 (min 0) on expiry
- Transitions to `pending`

#### 10.3.9 Proposal Processing

**`process_proposals(db)`** → `(accepted, rejected, deferred_count)`
- Scans `.ralph/proposals/prop_*.json` files
- For each proposal:
  - `new_task`: auto-accept if confidence ≥0.7 + S-effort + no deps, or ≥0.8 + S/M
  - `decompose`: auto-accept if all sub-tasks are S-effort
  - `drop_task`: always defer (judge must confirm)
  - `reprioritize`: auto-accept if wave delta ≤1
- Accepted proposals: INSERT into `task_view` + emit `task.created` event
- Deferred proposals: annotated with reason and timestamp in-place
- Processed proposals: moved to `proposals/processed/`

**`_accept_new_task(db, proposal, actor)`**
- Extracts task dict from proposal
- Generates task_id if not provided
- Emits `task.created` event with provenance='auto'
- INSERTs into `task_view`

#### 10.3.10 View Rendering

**`render_state(db)`** — regenerates STATE.json
- Reads existing STATE.json for agent-written fields (iteration, phase, current_item, current_plan, sub_step, retry_count, compile/test status, progress_history, periodic counters)
- Overwrites count fields from SQLite: `items_done_count`, `items_blocked_count`, `items_deferred_count`
- Writes merged result back to STATE.json
- **Note**: This is a hybrid model — SQLite owns task counts, agents own phase state

**`render_backlog(db)`** — regenerates BACKLOG.md
- Queries all tasks from `task_view ORDER BY wave, task_id`
- Groups by wave
- Renders markdown table with header row per wave
- Wave titles are configurable (default: Wave 0 through Wave 8)
- Output format matches exactly what agents expect for prompt injection

#### 10.3.11 Migration

**`init_from_backlog(db)`** — one-time v2 → v3 migration
- Parses BACKLOG.md line-by-line
- Detects wave headers via `^## Wave (\d+):` regex
- Parses item lines: `| ID | Status | Title | Source | Effort | Deps |`
- Maps v2 statuses (`in_progress`, `implemented`, `tested`, `planned`) → `pending`
- Emits `task.migrated` event for each item
- INSERTs into `task_view`
- Calls `render_state` + `render_backlog` to regenerate derived views

---

## 11. Control Harness (ralph-parallel.sh)

### 11.1 Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `BUDGET_PRIMARY` | $2.50 | Per-invocation cost limit for primary |
| `BUDGET_WORKER` | $5.00 | Per-invocation cost limit for worker |
| `MODEL` | opus | Claude model alias |
| `EFFORT` | max | Claude effort level |
| `INTERVAL_PRIMARY` | 20s | Base sleep (adaptive: 5s implement, 15s plan) |
| `INTERVAL_WORKER` | 30s | Sleep between worker cycles |

### 11.2 Prompt Composition

**Primary prompt** — injects only phase-relevant content:

| Component | When Injected | Size |
|-----------|--------------|------|
| `core.md` (coding standards) | Always | ~1.5KB |
| Slim STATE.json (phase-relevant fields) | Always | 200-500B |
| Phase instructions (`phases/<phase>.md`) | Always | 0.3-2.7KB |
| Active backlog wave | assess, plan | ~3KB |
| All-wave summary + S-effort items | evolve_goals | ~5KB |
| Deferred queue | review_deferred | varies |
| Guardrail triggers | plan, implement, verify, reflect | ~1.7KB |

**Worker prompt** — ultra-lean single-session:

| Component | Size |
|-----------|------|
| `core.md` | ~1.5KB |
| Item details (pre-extracted from backlog) | ~200B |
| Full-cycle instructions (plan→commit) | ~800B |
| Guardrail triggers | ~500B |
| **Total** | **~3.5KB** |

### 11.3 Metrics Extraction

After every Claude invocation, `extract_metrics()` parses the JSON output:

```json
{
  "agent": "A",
  "iter": 4,
  "phase_from": "assess",
  "phase_to": "plan",
  "duration": 19,
  "cost": 0.137,
  "prompt_bytes": 6823,
  "turns": 3,
  "input_tokens": 4,
  "cache_read": 53944,
  "cache_create": 14902,
  "output_tokens": 679,
  "model": "claude-opus-4-6",
  "subtype": "success"
}
```

Fields: `turns` (tool calls), `input_tokens` (fresh prompt), `cache_read` (cached context), `cache_create` (new cache entries), `output_tokens` (model response), `model` (which model handled the request), `subtype` (success/error/budget).

#### 11.3.1 Parsing claude -p JSON Output

The `claude -p --output-format json` command produces a JSON object with this structure:

```json
{
  "type": "result",
  "subtype": "success",              // "success" | "error_max_budget_usd" | "error"
  "is_error": false,
  "duration_ms": 80145,
  "duration_api_ms": 43003,
  "num_turns": 8,                    // total tool calls in session
  "result": "One-line summary...",   // agent's text output
  "stop_reason": "end_turn",
  "session_id": "uuid",
  "total_cost_usd": 0.269,
  "usage": {                         // aggregate (often zeros — use modelUsage instead)
    "input_tokens": 0,
    "cache_creation_input_tokens": 0,
    "cache_read_input_tokens": 0,
    "output_tokens": 0
  },
  "modelUsage": {                    // per-model breakdown (AUTHORITATIVE)
    "claude-opus-4-6": {
      "inputTokens": 8,
      "outputTokens": 1991,
      "cacheReadInputTokens": 160757,
      "cacheCreationInputTokens": 22324,
      "costUSD": 0.269,
      "contextWindow": 200000
    }
  }
}
```

The `extract_metrics()` function parses this by:
1. Reading `total_cost_usd`, `num_turns`, `subtype` from top level
2. Iterating `modelUsage` dict — summing `inputTokens`, `cacheReadInputTokens`, `cacheCreationInputTokens`, `outputTokens` across all models (worker sessions may use multiple models via subagents)
3. Tracking the model with highest `costUSD` as the primary model
4. Exporting as bash variables via `eval "$(python3 -c ...)"`:
   - `METRIC_COST`, `METRIC_TURNS`, `METRIC_INPUT`, `METRIC_CACHE_READ`, `METRIC_CACHE_CREATE`, `METRIC_OUTPUT`, `METRIC_MODEL`, `METRIC_SUBTYPE`

### 11.4 Worker Execution Mechanics

#### 11.4.1 Worktree Setup

The worker operates in an isolated git worktree at `${PROJ_DIR}/.worktrees/worker-b` on branch `ralph/worker-b`.

```bash
setup_worktree() {
    wt_path="${WORKTREE_BASE}/worker-b"
    branch="ralph/worker-b"

    if [[ -d "$wt_path" ]]; then
        # Reset existing worktree to current main HEAD
        git -C "$wt_path" reset --hard HEAD >/dev/null 2>&1
        git -C "$wt_path" clean -fd >/dev/null 2>&1
        git -C "$wt_path" checkout main >/dev/null 2>&1
        git -C "$wt_path" reset --hard main >/dev/null 2>&1
    else
        # Create new worktree (delete stale branch if needed)
        git branch -D "$branch" >/dev/null 2>&1 || true
        git worktree add "$wt_path" -b "$branch" HEAD >/dev/null 2>&1
    fi

    # Copy ralph config into worktree (NOT STATE.json — worker doesn't use it)
    cp .ralph/core.md .ralph/BACKLOG.md .ralph/GUARDRAILS.md "$wt_path/.ralph/"
    cp -r .ralph/phases/* "$wt_path/.ralph/phases/"
}
```

Key properties:
- `reset --hard main` syncs worktree to current main HEAD (including primary's recent commits)
- Branch `ralph/worker-b` is reused across cycles (reset each time)
- All git output suppressed with `>/dev/null 2>&1` to prevent stdout pollution
- STATE.json is NOT copied — worker doesn't need phase state

#### 11.4.2 Worker Claude Invocation

The worker uses file-based stdin (not pipe) to avoid output capture issues:

```bash
# Write prompt to temp file
prompt_file="${LOG_DIR}/par-B-prompt-${cycle}.txt"
echo "$prompt" > "$prompt_file"

# Run Claude in worktree directory via pushd
pushd "$wt_path" >/dev/null 2>&1
claude -p \
    --model "$MODEL" --effort "$EFFORT" \
    --max-budget-usd "$BUDGET_WORKER" \
    --output-format json \
    --dangerously-skip-permissions \
    < "$prompt_file" \
    > "$result_file" 2>>"${LOG_DIR}/par-B-errors.log" || exit_code=$?
popd >/dev/null 2>&1
rm -f "$prompt_file"
```

Key properties:
- `pushd`/`popd` changes CWD so Claude sees the worktree as its project root
- Stdin from file (not pipe) ensures reliable output capture to `$result_file`
- `$BUDGET_WORKER` ($5.00) is higher than primary ($2.50) because worker does full cycle

#### 11.4.3 Worker Event Sequence

```
1. pick_worker_item()               → ralphctl pick-ready-task worker --exclude <primary_item>
2. ralphctl transition-task <id> claimed worker-b    → event: task.claimed
3. setup_worktree()                 → reset worktree to main HEAD
4. build_worker_prompt()            → core.md + item details + instructions + guardrails
5. claude -p (in worktree)          → full plan→implement→verify→commit cycle
6. merge_worker_to_main()           → git format-patch main..HEAD → commits/pending/
7. ralphctl queue-patch <id> <path> → event: patch.queued, task→proposed
8. (later) apply_pending_patches()  → git plumbing merge + ralphctl promote-patch
```

### 11.5 Primary→SQLite Sync

Claude (the primary agent) writes directly to STATE.json and BACKLOG.md during its phases — it marks items `done` in BACKLOG.md during the commit phase. These changes must be synced back to SQLite.

After every primary iteration where the phase is `commit` or the new phase is `assess`:

```python
# Read BACKLOG.md for items Claude marked done
with open(BACKLOG_PATH) as f:
    for line in f:
        if '| done |' not in line: continue
        parts = [p.strip() for p in line.split('|')]
        if len(parts) < 3 or not parts[1].startswith('W'): continue
        task_id = parts[1]
        row = db.execute('SELECT status FROM task_view WHERE task_id=?', (task_id,)).fetchone()
        if row and row[0] != 'done':
            emit_event(db, 'task', task_id, 'task.completed', 'primary', {'source': 'backlog_sync'})
            db.execute('UPDATE task_view SET status="done" WHERE task_id=?', (task_id,))
            db.commit()
render_state(db)
render_backlog(db)
```

This ensures SQLite stays consistent with Claude's direct edits. Without this sync, `pick_ready_task` would offer already-completed items to the worker.

### 11.6 Adaptive Sleep

Between iterations, the primary sleeps for a duration based on the NEXT phase:

```bash
case "$new_phase" in
    assess|commit)                                    sleep_secs=10  ;;
    verify|reflect|plan)                              sleep_secs=15  ;;
    implement)                                        sleep_secs=5   ;;
    evolve_goals|refactor_dry|test_integration|test_ui|review_deferred)  sleep_secs=10  ;;
    *)                                                sleep_secs=20  ;;
esac
```

Rationale:
- `implement` gets 5s because sub-step iterations should chain quickly
- `assess`/`commit` get 10s because they're fast phases
- `plan`/`verify`/`reflect` get 15s because they involve significant reading
- Periodic phases get 10s to avoid stalling the loop

The worker uses a fixed 30s sleep between cycles (configurable via `INTERVAL_WORKER`).

---

## 12. Bootstrapping a New Project

### 12.1 ralph-init.sh

```bash
# Auto-detect language and generate full .ralph/ directory
cd /path/to/my-project
ralph-init.sh                              # auto-detect from Cargo.toml/package.json/etc.
ralph-init.sh --lang python --name "my-app"
ralph-init.sh --config ralph.config.json
```

Generates:
- `.ralph/core.md` — coding standards for the detected language
- `.ralph/STATE.json` — initial state (iteration 0, phase assess)
- `.ralph/BACKLOG.md` — skeleton with 3 empty waves
- `.ralph/GUARDRAILS.md` — 2 universal pre-loaded guardrails
- `.ralph/REFLECTIONS.md` — empty failure log
- `.ralph/EVOLVE_LOG.md` — initial entry
- `.ralph/SPEC_REGISTRY.md` — auto-discovered spec files
- `.ralph/phases/*.md` — 11 phase files with language-specific commands
- `ralph.config.json` — project configuration

### 12.2 ralph.config.json

```json
{
  "name": "project-name",
  "lang": "rust",
  "build": "cargo check --workspace",
  "lint": "cargo clippy --workspace -- -D warnings",
  "test": "cargo test --workspace",
  "test_unit": "cargo test --lib -p <crate> -- <module>::tests",
  "fmt": "cargo fmt --check",
  "forbidden_patterns": ".unwrap() outside #[cfg(test)]|.expect() outside #[cfg(test)]|panic!()",
  "domain_constraints": "ALL SQL must include tenant_id|Multi-step mutations require transactions",
  "model": "opus",
  "budget_primary": "2.50",
  "budget_worker": "5.00"
}
```

### 12.3 Populating the Backlog

Option A — manual: Add items directly to `.ralph/BACKLOG.md`.

Option B — from specs: Add specification documents to `specs/` and run the loop. The `evolve_goals` phase will discover them, extract requirements, and create backlog items as proposals.

Option C — bootstrap: Run a one-time Claude call:
```bash
claude -p "Read specs/YOUR_SPEC.md and .ralph/BACKLOG.md. Extract all actionable requirements and add them as work items. Wave 0 for critical fixes, Wave 1 for core, Wave 2 for features."
```

---

## 13. Phase File Specifications

All phase files live in `.ralph/phases/` and are injected into the prompt when their phase is active. Build/test commands reference `core.md` which contains the project-specific commands set by `ralph-init.sh`.

### 13.1 assess.md

```markdown
# Phase: ASSESS

Pick the next work item. Rules:
1. If STATE.json has `current_item` set and not done → resume it at its last sub-phase
2. Otherwise scan the BACKLOG section below for the first `pending` item (top to bottom)
3. Skip items whose deps are not all `done` → mark `blocked` in backlog
4. Set STATE.json: `phase`="plan", `current_item`=<chosen ID>, increment `iteration`
5. If no pending items remain in this wave, advance `current_wave` and re-scan

Do NOT read any code files. Do NOT implement anything. Just pick the item and update state.
```

### 13.2 plan.md

```markdown
# Phase: PLAN

Create a concrete plan for the current item. Steps:

1. Read the relevant spec/issue/requirement referenced in the item's Source field.
2. Read GUARDRAILS.md for relevant anti-patterns.
3. Find existing code: use Grep/Glob to locate relevant files, then Read them.
   If 3+ files need reading, launch parallel Explore agents.
4. **PRE-PLAN SCAN**: For each file in your plan, grep for forbidden patterns.
   Include fixing ALL pre-existing violations in your plan.
5. Write plan to STATE.json `current_plan`:
   {"files_modify":["a"],"files_create":["b"],"sub_steps":[{"step":1,"desc":"...","verify":"<build_cmd>"}],"acceptance":"..."}
6. For L/XL items: plan only the first sub-step batch for this iteration.
7. Set STATE.json: `phase`="implement", `current_sub_step`=1
```

### 13.3 implement.md

```markdown
# Phase: IMPLEMENT

Execute one sub-step from the plan in STATE.json.

1. Read `current_plan.sub_steps[current_sub_step - 1]`
2. Write code: Edit existing files (preferred) or Write new files
3. IMMEDIATE verification: `<build_cmd> 2>&1 | tail -50`
   - If FAIL: fix the error, re-check. Max 3 attempts.
   - After 3 fails: set `phase`="reflect"
4. If build passes: run unit test: `<test_unit_cmd> 2>&1 | tail -30`
5. If all sub-steps done: set `phase`="verify"
6. If more sub-steps: increment `current_sub_step`, keep `phase`="implement"
```

### 13.4 verify.md

```markdown
# Phase: VERIFY

Machine-verifiable quality gates. Run ALL:

1. `<build_cmd>` → must pass
2. `<test_unit_cmd>` → must pass for changed modules
3. Grep changed files for forbidden patterns (from core.md)
4. ALL pass → set `phase`="commit"
5. ANY fail → set `phase`="reflect", increment `retry_count`
```

### 13.5 reflect.md

```markdown
# Phase: REFLECT

Diagnose the failure. Classify and persist the lesson.

1. Read the error from last verify/implement attempt
2. Classify:
   - TRANSIENT (timeout, flaky) → retry same approach
   - LLM_RECOVERABLE (wrong approach, type error) → re-plan
   - ENVIRONMENT (missing dep, toolchain) → fix env, retry
   - FUNDAMENTAL (ambiguous spec, impossible) → mark blocked
3. Append 1-2 sentence reflection to REFLECTIONS.md:
   `iteration: N | item: X | class: Y | "Failed because Z. Next time W."`
4. If FUNDAMENTAL or retry_count >= 3: mark item blocked, clear current_item, phase="assess"
5. If LLM_RECOVERABLE: phase="plan" (re-plan with reflection)
6. If TRANSIENT: phase="implement" (retry)
7. If this is a recurring pattern, add guardrail to GUARDRAILS.md
```

### 13.6 commit.md

```markdown
# Phase: COMMIT

Persist progress with a structured commit.

1. Stage changed files: `git add <files from plan>`
2. Also stage: `.ralph/STATE.json .ralph/BACKLOG.md`
3. Commit:
   git commit -m "ralph(W<wave>-<id>): <brief description>
   Implements <source>.
   Co-Authored-By: Claude <model> <noreply@anthropic.com>"
4. Update BACKLOG.md: item status → "done"
5. Update STATE.json: increment `commits_total`, `items_done_count`, clear `current_item`/`current_plan`
6. Set `phase`="assess"
```

### 13.7 evolve_goals.md (v3 — proposals)

```markdown
# Phase: EVOLVE_GOALS (v3 — proposals, not mutations)

Self-improve the backlog via PROPOSALS. You do NOT modify BACKLOG.md directly.
Your goal is to keep BOTH agents busy with at least 3 S-effort items available.

## 1. Scan for new spec documents
find specs/ docs/ adrs/ -type f \( -name "*.md" -o -name "*.json" -o -name "*.yml" \) | sort
Compare against SPEC_REGISTRY.md. For new files: read first 50 lines, add to registry.

## 2. Deep-read UNDER-READ specs
Check SPEC_REGISTRY.md "Last Read" column. Pick 1-2 specs not read recently.
For each requirement NOT in the backlog, emit a proposal.

## 3. Emit proposals to .ralph/proposals/
  {"proposal_type":"new_task", "confidence":0.85, "task":{"id":"W3-035","title":"...","effort":"S","wave":3,"deps":"-"}, "rationale":"..."}
  {"proposal_type":"decompose", "parent_task":"W3-002", "confidence":0.9, "sub_tasks":[...], "rationale":"..."}

## 4. Standard evaluation
- git log --oneline -5
- Blocked items unblockable differently? → emit proposal

## 5. Update SPEC_REGISTRY.md, EVOLVE_LOG.md
- Set `phase`="assess", `last_evolve_at`=commits_total

Do NOT modify BACKLOG.md directly. The control plane processes proposals after this phase.
```

### 13.8 refactor_dry.md

```markdown
# Phase: REFACTOR_DRY

Eliminate duplication in recent work. Runs every 5 commits.

1. `git diff HEAD~5..HEAD --stat` — identify changed files
2. Look for: duplicated logic → extract helper; copy-paste → macro; 3+ similar → trait/interface; >800 LOC → split
3. Implement refactoring, verify with build + test
4. Commit refactoring
5. Set `phase`="assess", `last_dry_at`=commits_total
```

### 13.9 test_integration.md

```markdown
# Phase: TEST_INTEGRATION

Full test suite. Runs every 10 commits.

1. `<test_cmd> 2>&1 | tail -100` — fix any failures
2. Run integration tests if configured
3. Update STATE.last_integ_at = commits_total
4. If failures: phase="reflect"
5. If all pass: phase="assess"
```

### 13.10 test_ui.md

```markdown
# Phase: TEST_UI

Browser/E2E testing. Runs every 15 commits. Skip if no UI.

1. Check if server can start
2. Run end-to-end tests if configured
3. For NEW features: create test specs
4. Update STATE.last_ui_at = commits_total
5. Set phase="assess"
```

### 13.11 review_deferred.md

```markdown
# Phase: REVIEW_DEFERRED

You are an INDEPENDENT JUDGE. You did NOT generate the changes you are reviewing.
Your job is to evaluate deferred items and decide: approve, reject, or modify.

## For each deferred item:
1. Read the deferral reason
2. If a patch exists, read the diff: `git show <commit_hash>`
3. Read the relevant spec section
4. Evaluate against the specific concern that caused deferral

## Decisions:
- APPROVE: `python3 .ralph/ralphctl.py resolve-deferred <task_id> approve judge "<rationale>"`
- REJECT: `python3 .ralph/ralphctl.py resolve-deferred <task_id> reject judge "<rationale>"`
- MODIFY: `python3 .ralph/ralphctl.py resolve-deferred <task_id> modify judge "<fix instructions>"`

Update .ralph/STATE.json when done. One-line summary per item.
```

---

## 14. Backlog Management

### 14.1 Format

```markdown
| ID | Status | Title | Source | Effort | Deps |
|----|--------|-------|--------|--------|------|
| W2-001 | done | Create shared helpers | ES:59 | S | - |
| W2-008 | pending | Add test suite | ES:35 | M | W2-007 |
```

Status: `pending`, `claimed`, `proposed`, `done`, `deferred`, `blocked`, `dropped`
Effort: S (1 iteration), M (2-3), L (4-6), XL (7+)
Deps: comma-separated task IDs, or `-` for none

### 14.2 Wave Structure

Waves are priority-ordered batches. Wave 0 runs first. Items within a wave run top-to-bottom. The worker searches ALL waves for S-effort items with no unmet deps.

### 14.3 Dependency Resolution

An item is eligible for work only when all tasks listed in its `Deps` column have status `done` in the SQLite task_view.

---

## 15. Guardrails & Reflections

### 15.1 Guardrails

Anti-patterns learned from failures. Injected into plan/implement/verify/reflect prompts.

Format:
```
---
trigger: <condition>
instruction: <what to do instead>
learned_at: iteration N
---
```

Universal guardrails (pre-loaded by `ralph-init.sh`):
1. Scan for forbidden patterns BEFORE implementing (prevents reflect loops)
2. Run exhaustive grep before scoping crate/module-wide refactors

### 15.2 Reflections

Failure analysis using the Reflexion pattern. Each entry records iteration, item, error class, and a verbal lesson.

Error classes: `TRANSIENT` (retry), `LLM_RECOVERABLE` (replan), `ENVIRONMENT` (fix env), `FUNDAMENTAL` (block).

---

## 16. Hard Limits

| Limit | Value | Enforcement |
|-------|-------|-------------|
| Max retry per sub-step | 3 | Code: reflect phase checks retry_count |
| Max blocked items | 10 | Spec only (consider adding enforcement) |
| Build must pass | Always | verify phase gate |
| Tests must not regress | Always | verify phase gate |
| No force-push | Always | Git append-only |
| No skip verification | Always | Machine gates required |
| Deferral auto-expiry | 20 commits | ralphctl expire-stale-deferrals |
| Max backlog size | 300 items | ralphctl process-proposals checks |

---

## 17. Observability

### 17.1 Metrics JSONL

Every invocation appends to `.ralph/logs/par-metrics-{date}.jsonl`:

```json
{
  "ts": "2026-03-25T02:43:07Z",
  "agent": "A",
  "iter": 4,
  "phase_from": "assess",
  "phase_to": "plan",
  "duration": 19,
  "cost": 0.137,
  "prompt_bytes": 6823,
  "turns": 3,
  "input_tokens": 4,
  "cache_read": 53944,
  "cache_create": 14902,
  "output_tokens": 679,
  "model": "claude-opus-4-6",
  "subtype": "success"
}
```

### 17.2 Event Log Queries

```sql
-- Tasks completed today
SELECT entity_id, ts FROM events WHERE event_type='task.completed' AND ts > date('now');

-- Patch success rate
SELECT status, COUNT(*) FROM patch_view GROUP BY status;

-- Deferred items pending review
SELECT task_id, deferred_reason, deferred_at FROM task_view WHERE status='deferred';

-- Event rate (activity level)
SELECT COUNT(*) FROM events WHERE ts > datetime('now', '-1 hour');
```

### 17.3 Monitoring

```bash
./scripts/ralph-monitor.sh                # Live dashboard
python3 .ralph/ralphctl.py status         # Quick summary
tail -f .ralph/logs/parallel-nohup.log    # Operational log
```

---

## 18. File Inventory

| Path | Lines | Bytes | Type | Role |
|------|-------|-------|------|------|
| `scripts/ralph-parallel.sh` | 783 | 30,625 | Script | Dual-agent control harness |
| `scripts/ralph-init.sh` | 622 | 26,216 | Script | Bootstrap for any project (8 languages) |
| `scripts/ralph-monitor.sh` | 314 | 11,744 | Script | Real-time monitoring dashboard |
| `scripts/ralph-repair.sh` | 223 | 7,529 | Script | Diagnostics and recovery |
| `.ralph/ralphctl.py` | 793 | 32,207 | Python | v3 control plane (SQLite, events, policy) |
| `.ralph/ralph.db` | — | ~100KB | SQLite | Canonical truth (event log + views) |
| `.ralph/core.md` | 31 | 1,469 | Config | Coding standards (always injected) |
| `.ralph/STATE.json` | ~40 | ~3.8KB | Derived | Machine state (regenerated from SQLite) |
| `.ralph/BACKLOG.md` | ~327 | ~27KB | Derived | Work items (regenerated from task_view) |
| `.ralph/GUARDRAILS.md` | 45 | 2,265 | Config | Learned anti-patterns |
| `.ralph/REFLECTIONS.md` | varies | varies | Log | Failure analysis |
| `.ralph/EVOLVE_LOG.md` | varies | varies | Log | Goal evolution history |
| `.ralph/SPEC_REGISTRY.md` | ~100 | ~6KB | Index | Spec document tracker |
| `.ralph/phases/*.md` | 197 | 9,135 | Config | 11 phase instruction files |
| `.ralph/proposals/` | — | — | Dir | Staging for evolve_goals proposals |
| `.ralph/commits/pending/` | — | — | Dir | Worker patches awaiting merge |
| `.ralph/commits/applied/` | — | — | Dir | Merged patch archive |
| `.ralph/locks/` | — | — | Dir | flock files (state.lock) |
| `.ralph/logs/` | — | — | Dir | Metrics, tool use, error logs |
| `ralph.config.json` | 16 | 573 | Config | Project configuration |

---

## 19. Rebuilding the System

To rebuild Ralph Loop from scratch on any project:

### Step 1: Install prerequisites
- `claude` CLI (Claude Code)
- `python3` with `sqlite3` (standard library)
- `git`
- Project's build toolchain

### Step 2: Bootstrap
```bash
cd /path/to/project
/path/to/ralph-init.sh --lang <language>
```

### Step 3: Create the control plane
Copy `ralphctl.py` to `.ralph/ralphctl.py`. Run `python3 .ralph/ralphctl.py init` to migrate the skeleton backlog into SQLite.

### Step 4: Populate the backlog
Either manually add items to BACKLOG.md and re-run `ralphctl.py init`, or add spec documents to `specs/` and let `evolve_goals` discover them.

### Step 5: Start the loop
```bash
./scripts/ralph-parallel.sh
```

### Step 6: Monitor
```bash
tail -f .ralph/logs/parallel-nohup.log
python3 .ralph/ralphctl.py status
```

The system will:
- Pick items from the backlog
- Plan, implement, verify, and commit changes
- Merge worker patches via git plumbing
- Evolve the backlog by scanning specs
- Review deferred items via independent judge
- Run indefinitely with zero human intervention

---

## Appendix A: Glossary

| Term | Definition |
|------|-----------|
| **Wave** | Priority-ordered batch of work items |
| **Phase** | One step in the state machine (11 phases total) |
| **Iteration** | One invocation of claude -p executing one phase |
| **Sub-step** | One step within a plan (L/XL items have multiple) |
| **Guardrail** | Learned anti-pattern with trigger and corrective instruction |
| **Reflection** | Verbal failure diagnosis persisted for future avoidance |
| **Deferred merge** | Patch queued by worker, applied by primary via git plumbing |
| **Slim state** | Phase-relevant subset of STATE.json injected into prompt |
| **Promotion** | Atomic operation: patch→promoted + task→done in event log |
| **Derived view** | STATE.json or BACKLOG.md regenerated from SQLite truth |
| **Proposal** | Suggested backlog change from evolve_goals, subject to policy acceptance |
| **Risk tier** | 0-3 classification governing autonomy level for a task |
| **Independent judge** | Separate Claude invocation reviewing deferred items |

## Appendix B: Research Bibliography

Design informed by 75 parallel research/analysis subagents:

| Group | Count | Focus |
|-------|-------|-------|
| Agentic patterns | 2 | Reflexion, SWE-agent, OpenHands, AutoCodeRover, Aider, Self-Refine, CodeAct |
| Standards research | 9 | Domain-specific validation standards |
| Test data catalogs | 5 | Real-world test data acquisition |
| Tooling research | 9 | Build tools, frameworks, testing infrastructure |
| Codebase analysis | 15 | Architecture, dependencies, security |
| Spec extraction | 10 | Requirement extraction from specifications |
| Domain cookbooks | 25 | Implementation patterns for domain modules |
