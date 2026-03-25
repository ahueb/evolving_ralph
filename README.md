# Ralph Loop v3

**Fully autonomous, event-sourced software engineering system.**

Ralph Loop runs two parallel LLM agents that continuously plan, implement, test, and commit code changes to any software project. All agent activity produces proposals; only the control plane advances truth. Truth lives in an append-only SQLite event log. No human gates — humans override asynchronously, never block.

---

## Table of Contents

- [How It Works](#how-it-works)
- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Supported Languages](#supported-languages)
- [Project Structure](#project-structure)
- [The Control Plane (ralphctl.py)](#the-control-plane-ralphctlpy)
- [The Control Harness (ralph-parallel.sh)](#the-control-harness-ralph-parallelsh)
- [Phase Reference](#phase-reference)
- [Risk Classification](#risk-classification)
- [Backlog Management](#backlog-management)
- [Self-Evolution](#self-evolution)
- [Monitoring & Repair](#monitoring--repair)
- [Configuration Reference](#configuration-reference)
- [Design Principles](#design-principles)
- [Research Basis](#research-basis)

---

## How It Works

```
You add spec documents to specs/ or docs/
  --> Ralph discovers them automatically
    --> Extracts requirements into backlog proposals
      --> Control plane auto-accepts qualifying items
        --> Two agents work in parallel:

Primary Agent (A)                    Worker Agent (B)
Sequential state machine             Full-cycle in git worktree
  assess -> plan -> implement          pick S-effort item
    -> verify -> commit                  plan -> implement -> verify -> commit
                                         queue patch for merge

        --> Git plumbing merges worker patches (zero working-tree conflicts)
          --> Runs indefinitely with zero human intervention
```

The system bootstraps itself. Drop specification documents into `specs/` and start the loop. Ralph reads the specs, populates the backlog, and begins building. New specs added later are discovered on subsequent `evolve_goals` cycles.

---

## Architecture

```
ralph-parallel.sh (control harness)
|
+-- ralphctl.py (control plane)
|   +-- SQLite event log (ralph.db)       Append-only canonical truth
|   +-- task_view                          Materialized from events
|   +-- patch_view                         Materialized from events
|   +-- Risk classifier                    Tier 0-3 from file patterns
|   +-- Policy engine                      Auto-promote / defer / decompose
|   +-- Proposal processor                 Auto-accept high-confidence items
|   +-- Deferred expiry                    Auto-expire stale deferrals
|   +-- View renderer                      STATE.json + BACKLOG.md from SQLite
|
+-- Primary Agent (A)                      Sequential state machine, main branch
|   +-- build_primary_prompt()             Token-efficient prompt (~2-9KB)
|   +-- claude -p                          One phase per invocation
|   +-- extract_metrics()                  Full token/turn/cost extraction
|   +-- apply_pending_patches()            Git plumbing merge + promote-patch
|   +-- sync_primary_completions()         BACKLOG.md done -> SQLite task_view
|   +-- adaptive_sleep()                   5-15s between phases
|
+-- Worker Agent (B)                       Full-cycle in worktree, all waves
|   +-- pick_worker_item()                 SQLite query: S-effort, no unmet deps
|   +-- setup_worktree()                   Isolated git worktree
|   +-- build_worker_prompt()              Ultra-lean prompt (~3.5KB)
|   +-- claude -p                          Full plan->implement->verify->commit
|   +-- merge_worker_to_main()             format-patch -> commits/pending/
|
+-- Independent Judge                      Separate invocation, no shared context
    +-- review_deferred phase              Triggers when deferred queue >= 3
    +-- approve / reject / modify          Via ralphctl resolve-deferred
```

### Data Flow

```
Agent produces artifact (plan, diff, proposal)
  -> Control plane validates (risk tier, policy check)
    -> Tier 0-1: auto-promote after verification
    -> Tier 2: defer to independent judge
    -> Tier 3: decompose into smaller tasks
  -> Promoted patch: git plumbing commit + task.completed event
  -> Derived views regenerated (STATE.json, BACKLOG.md)
  -> Agents see updated views on next invocation
```

---

## Quick Start

### Prerequisites

- **Claude Code CLI** (`claude`) — [install instructions](https://docs.anthropic.com/en/docs/claude-code)
- **Python 3** with `sqlite3` (standard library)
- **Git**
- Your project's build toolchain

### 1. Bootstrap

```bash
cd /path/to/your-project

# Auto-detect language from Cargo.toml, package.json, go.mod, etc.
/path/to/scripts/ralph-init.sh

# Or specify explicitly
/path/to/scripts/ralph-init.sh --lang python --name "my-app"
```

This creates the entire `.ralph/` directory, generates language-specific phase files, initializes the SQLite database, and writes `ralph.config.json`.

### 2. Populate the Backlog

**Option A** — From specs (recommended):

```bash
mkdir -p specs/
cp your-specification.md specs/
```

Ralph discovers spec files automatically and extracts requirements into backlog items.

**Option B** — Manually:

Edit `.ralph/BACKLOG.md` and add items, then re-initialize:

```bash
python3 .ralph/ralphctl.py init
```

**Option C** — One-time bootstrap with Claude:

```bash
claude -p "Read specs/YOUR_SPEC.md and .ralph/BACKLOG.md. \
  Extract all actionable requirements and add them as work items. \
  Wave 0 for critical fixes, Wave 1 for core, Wave 2 for features."
```

### 3. Start the Loop

```bash
./scripts/ralph-parallel.sh
```

Both agents start working. The system runs indefinitely.

### 4. Monitor

```bash
# Live dashboard (refreshes every 5s)
./scripts/ralph-monitor.sh

# Single snapshot
./scripts/ralph-monitor.sh --once

# Quick status
python3 .ralph/ralphctl.py status

# Tail the operational log
tail -f .ralph/logs/parallel-nohup.log
```

### 5. Diagnose & Repair

```bash
# Health check
./scripts/ralph-repair.sh

# Auto-repair
./scripts/ralph-repair.sh --fix
```

---

## Supported Languages

`ralph-init.sh` auto-detects and generates configuration for:

| Language | Detection | Build | Test | Lint | Forbidden Patterns |
|----------|-----------|-------|------|------|--------------------|
| **Rust** | `Cargo.toml` | `cargo check --workspace` | `cargo test --workspace` | `cargo clippy` | `.unwrap()`, `.expect()`, `panic!()` outside tests |
| **Python** | `pyproject.toml`, `setup.py`, `requirements.txt` | `python -m py_compile` | `pytest` | `ruff check` | `bare except:`, `eval(`, `import *` |
| **TypeScript** | `package.json`, `tsconfig.json` | `npm run build` | `npm test` | `eslint` | `any` type, `console.log` in prod, `eval(` |
| **Go** | `go.mod` | `go build ./...` | `go test ./...` | `golangci-lint` | `panic()` in libraries, `os.Exit()` outside main |
| **Java** | `pom.xml`, `build.gradle` | `mvn compile` | `mvn test` | `checkstyle` | `System.out.println`, `catch (Exception)` without logging |
| **Ruby** | `Gemfile` | `ruby -c` | `rspec` | `rubocop` | `eval(`, `puts` in production, `rescue Exception` |
| **C#** | `*.csproj`, `*.sln` | `dotnet build` | `dotnet test` | `dotnet format` | `Console.WriteLine`, `Thread.Sleep` in async |
| **Generic** | fallback | `make build` | `make test` | `make lint` | `TODO`, `FIXME`, `HACK` |

---

## Project Structure

```
your-project/
+-- ralph.config.json              Project configuration
+-- specs/                         Specification documents (auto-discovered)
+-- docs/                          Documentation (auto-discovered)
|
+-- scripts/
|   +-- ralph-parallel.sh          Dual-agent control harness
|   +-- ralph-init.sh              Bootstrap for any project
|   +-- ralph-monitor.sh           Real-time monitoring dashboard
|   +-- ralph-repair.sh            Diagnostics and recovery
|
+-- .ralph/
    +-- ralphctl.py                Control plane (SQLite, events, policy)
    +-- ralph.db                   Canonical truth (append-only event log)
    +-- STATE.json                 Machine state (derived view)
    +-- BACKLOG.md                 Work items (derived view)
    +-- core.md                    Coding standards (always injected into prompts)
    +-- GUARDRAILS.md              Learned anti-patterns
    +-- REFLECTIONS.md             Failure analysis log
    +-- EVOLVE_LOG.md              Goal evolution history
    +-- SPEC_REGISTRY.md           Spec document tracker
    +--phases/
    |   +-- assess.md              Pick next work item
    |   +-- plan.md                Create implementation plan
    |   +-- implement.md           Execute one sub-step
    |   +-- verify.md              Machine-verifiable quality gates
    |   +-- reflect.md             Diagnose failures
    |   +-- commit.md              Git commit and state update
    |   +-- evolve_goals.md        Self-improve backlog via proposals
    |   +-- refactor_dry.md        Eliminate duplication
    |   +-- test_integration.md    Full test suite
    |   +-- test_ui.md             Browser/E2E tests
    |   +-- review_deferred.md     Independent judge review
    +-- proposals/                 Staging for evolve_goals proposals
    +-- commits/
    |   +-- pending/               Worker patches awaiting merge
    |   +-- applied/               Merged patch archive
    +-- locks/                     flock files
    +-- logs/                      Metrics JSONL, tool use, error logs
```

---

## The Control Plane (ralphctl.py)

Single-file Python module using only standard library (`sqlite3`, `json`, `os`, `re`, `hashlib`, `datetime`, `pathlib`, `sys`). No external dependencies.

### Data Model

**Events** (append-only truth):

```sql
CREATE TABLE events (
    event_id    TEXT PRIMARY KEY,   -- 'evt_{timestamp}_{hash}'
    ts          TEXT NOT NULL,      -- ISO 8601
    run_id      TEXT NOT NULL,      -- 'run_{date}_{pid}'
    entity_type TEXT NOT NULL,      -- 'task' | 'patch' | 'run' | 'incident'
    entity_id   TEXT NOT NULL,      -- 'W3-014' | 'patch_001'
    event_type  TEXT NOT NULL,      -- 'task.claimed' | 'patch.promoted' | etc.
    actor       TEXT NOT NULL,      -- 'control_plane' | 'primary' | 'worker-b' | 'judge'
    payload     TEXT NOT NULL       -- JSON blob
);
```

**Task View** (materialized projection):

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
    ...
);
```

**Patch View** (materialized projection):

```sql
CREATE TABLE patch_view (
    patch_id    TEXT PRIMARY KEY,
    task_id     TEXT NOT NULL,
    status      TEXT NOT NULL,      -- queued|applied|verified|promoted|discarded
    patch_path  TEXT,
    commit_hash TEXT                -- git SHA after promotion
);
```

### CLI Commands

```bash
ralphctl.py init                           # Migrate BACKLOG.md -> SQLite
ralphctl.py emit-event <type> <id> ...     # Append to event log
ralphctl.py transition-task <id> <status>  # Change task status
ralphctl.py pick-ready-task <worker|primary> [--exclude <id>]
ralphctl.py queue-patch <task_id> <path> <created_by>
ralphctl.py promote-patch <patch_id> <commit_hash>
ralphctl.py discard-patch <patch_id> <reason>
ralphctl.py classify-risk <task_id>        # Returns tier 0-3
ralphctl.py policy-check <task_id>         # Returns promote|defer|decompose
ralphctl.py get-deferred-queue [--format prompt|json]
ralphctl.py should-review-deferred         # true if >= 3 deferred
ralphctl.py resolve-deferred <id> <approve|reject|modify> <actor> <rationale>
ralphctl.py expire-stale-deferrals
ralphctl.py process-proposals
ralphctl.py render-state                   # Regenerate STATE.json
ralphctl.py render-backlog                 # Regenerate BACKLOG.md
ralphctl.py sync-backlog                   # Sync BACKLOG.md done -> SQLite
ralphctl.py status                         # Summary
```

---

## The Control Harness (ralph-parallel.sh)

Orchestrates two agents running concurrently:

### Primary Agent (A)

Runs a sequential state machine on the main branch. Each invocation executes one phase:

```
assess -> plan -> implement -> verify -> commit
  ^                              |         |
  |                              |    [PASS]|[FAIL]
  |                           +--+         |
  |                           v            v
  |                      commit <-- retry (max 3)
  |                         |
  |                         v
  |             +-- review_deferred (if deferred >= 3)
  |             +-- test_integration (if >30 commits overdue)
  |             +-- evolve_goals (every 5 commits)
  |             +-- refactor_dry (every 5 commits)
  |                         |
  +-------------------------+
```

Between invocations, the harness:
- Applies pending worker patches via git plumbing (zero working-tree conflicts)
- Syncs BACKLOG.md completions back to SQLite
- Renders updated STATE.json
- Expires stale deferrals
- Processes proposals (after `evolve_goals`)

### Worker Agent (B)

Runs full plan-implement-verify-commit cycles in an isolated git worktree:

1. Picks an S-effort task with no unmet dependencies (excludes primary's current item)
2. Claims it in the event log
3. Resets the worktree to the current main HEAD
4. Runs a single Claude invocation that does the entire cycle
5. Generates a `git format-patch` and queues it for merge
6. **Does NOT mark the task done** — only the control plane does that after promotion

### Git Plumbing Merge

Worker patches merge via git plumbing, **never touching the working tree**:

```bash
# 1. Temp index from HEAD
GIT_INDEX_FILE="$tmp" git read-tree HEAD
# 2. Apply patch (exclude .ralph/ to avoid backlog conflicts)
GIT_INDEX_FILE="$tmp" git apply --cached --3way --exclude='.ralph/*' "$patch"
# 3. Write tree, create commit, advance HEAD
# 4. Atomic promotion: patch->promoted + task->done
```

This means the primary agent's in-progress edits are never disturbed. Merge success rate: 100%.

---

## Phase Reference

| Phase | Triggers | What It Does |
|-------|----------|-------------|
| **assess** | Start of every cycle | Pick next work item, check periodic overrides |
| **plan** | After assess | Read specs, find code, pre-scan for violations, write plan |
| **implement** | After plan | Execute one sub-step, immediate build check |
| **verify** | After all sub-steps | Machine gates: build, test, forbidden pattern grep |
| **reflect** | After verify failure | Classify error, persist lesson, decide retry/replan/block |
| **commit** | After verify passes | Git commit, update backlog, increment counters |
| **evolve_goals** | Every 5 commits, or cold-start | Scan specs, emit proposals for new backlog items |
| **refactor_dry** | Every 5 commits | Eliminate duplication in recent commits |
| **test_integration** | Every 10 commits (overdue at 30) | Full test suite |
| **test_ui** | Every 15 commits (overdue at 30) | Browser/E2E tests |
| **review_deferred** | Deferred queue >= 3 | Independent judge reviews deferred items |

### Periodic Phase Priority

When the primary enters `assess`, the control plane checks in order:

1. `test_integration` if >30 commits overdue
2. `test_ui` if >30 commits overdue
3. `review_deferred` if deferred queue >= 3 items
4. `evolve_goals` if >= 5 commits since last (or backlog empty + specs exist)
5. `refactor_dry` if >= 5 commits since last
6. `test_integration` if >= 10 commits since last
7. `test_ui` if >= 15 commits since last

---

## Risk Classification

Every task is classified into a risk tier based on the files it touches:

| Tier | Scope | Autonomy | Examples |
|------|-------|----------|---------|
| **0 (Trivial)** | Docs, schemas, test fixtures | Auto-promote after deterministic verification | Schema YAML, CI config, README, test data |
| **1 (Normal)** | Standard product code | Auto-promote after full verification | Helper refactors, validators, parsers |
| **2 (Sensitive)** | Auth, data paths, migrations | Defer to independent judge | SQL migrations, auth handlers, export pipelines |
| **3 (Restricted)** | Secrets, destructive ops, broad rewrites | Decompose into smaller safe tasks | Key material, `DROP TABLE`, compliance outputs |

### Classification Algorithm

```
if any file matches tier3_patterns -> return 3   (check first, most restrictive)
if any file matches tier2_patterns -> return 2
if task source matches tier2_sources -> return 2
if effort == 'S' and all files match tier0_patterns -> return 0
return 1   (default)
```

Risk patterns are configurable per project via `ralph.config.json`.

### Autonomous Resolution

- **Tier 0-1**: Auto-promote after verification passes.
- **Tier 2**: Deferred to `review_deferred` phase. An independent judge (separate Claude invocation with no shared context) reviews the diff.
- **Tier 3**: Control plane decomposes into smaller Tier 1-2 sub-tasks. Parent task marked `dropped`.
- **Expiry**: Deferred items auto-expire to `pending` after ~20 commits with lowered tier.

---

## Backlog Management

### Format

```markdown
| ID | Status | Title | Source | Effort | Deps |
|----|--------|-------|--------|--------|------|
| W2-001 | done   | Create shared helpers | ES:59 | S | -     |
| W2-008 | pending | Add test suite       | ES:35 | M | W2-007 |
```

- **Status**: `pending`, `claimed`, `proposed`, `done`, `deferred`, `blocked`, `dropped`
- **Effort**: S (1 iteration), M (2-3), L (4-6), XL (7+)
- **Deps**: Comma-separated task IDs, or `-` for none

### Wave Structure

Waves are priority-ordered batches. Wave 0 runs first. Items within a wave run top-to-bottom. The worker searches ALL waves for S-effort items with no unmet dependencies.

### Task Lifecycle

```
pending                          -- Eligible for work
  -> claimed                     -- Assigned to an executor (event logged)
    -> proposed                  -- Patch/plan artifact exists
      -> [verify passes]
        -> Tier 0-1: promoted    -- Patch applied, task done (atomic)
        -> Tier 2: deferred      -- Independent judge will review
        -> Tier 3: decomposed    -- Split into smaller safe tasks
      -> [verify fails]
        -> reflect -> retry/replan

deferred                         -- Awaiting judge review
  -> approved -> done            -- Judge approves
  -> rejected -> pending         -- Judge rejects, agent retries
  -> expired  -> pending         -- Auto-expire after 20 commits, tier lowered

blocked                          -- Dependencies unmet or fundamental failure
dropped                          -- Obsolete, removed by evolve_goals
```

**Critical invariant: No task reaches `done` without a `promoted` patch in the event log.**

---

## Self-Evolution

The `evolve_goals` phase emits proposals to `.ralph/proposals/`, not direct backlog mutations:

```json
{
  "proposal_type": "new_task",
  "confidence": 0.85,
  "task": {"id": "W3-035", "title": "...", "source": "ES:42.3", "effort": "S", "wave": 3, "deps": "-"},
  "rationale": "Found in spec section 42.3, not covered by existing items"
}
```

### Auto-Acceptance Policy

| Proposal Type | Auto-Accept Condition | Otherwise |
|---------------|----------------------|-----------|
| New S-effort, no deps, confidence >= 0.7 | Accept | Defer to judge |
| New S/M-effort, confidence >= 0.8 | Accept | Defer to judge |
| Decompose (all sub-tasks S-effort) | Accept | Defer to judge |
| Drop task | Always defer | Judge must confirm |
| Reprioritize (+/-1 wave) | Accept | Defer to judge |

### Backlog Growth Control

- Max backlog size: 300 items
- Max pending per wave: 50 items
- Proposals exceeding limits are deferred

### Cold-Start Behavior

If the backlog is empty and spec files exist in `specs/`, `docs/`, or `adrs/`, the system forces `evolve_goals` immediately on the next `assess` cycle, bypassing the normal 5-commit interval. This means you can bootstrap a project by:

1. Running `ralph-init.sh`
2. Dropping spec documents into `specs/`
3. Starting `ralph-parallel.sh`

The system handles the rest.

---

## Monitoring & Repair

### Live Dashboard

```bash
./scripts/ralph-monitor.sh        # live, refreshes every 5s
./scripts/ralph-monitor.sh 10     # custom refresh interval
./scripts/ralph-monitor.sh --once # single snapshot
```

Displays:
- Current phase, iteration, wave, commit count
- Task summary with progress bar (done/pending/claimed/deferred/blocked)
- Patch summary (promoted/queued/discarded, pending merge files)
- Event activity (total, last hour, last 10 minutes)
- Last 10 events with timestamps
- Deferred items awaiting review
- Today's cost and invocation metrics
- Process status (ralph-parallel.sh, active Claude instances)
- Recent log lines

### SQL Queries

The event log supports direct querying:

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

### Diagnostics & Repair

```bash
./scripts/ralph-repair.sh         # check health
./scripts/ralph-repair.sh --fix   # check and auto-repair
```

Checks:
1. **File system** -- required files and directories exist
2. **Git repository** -- repo health, worktree integrity
3. **SQLite database** -- integrity check, table existence, WAL mode
4. **State consistency** -- valid JSON, retry count, abandoned claims, count sync
5. **Lock files** -- detect and clean stale locks
6. **Pending patches** -- report queued patches
7. **Proposals** -- unprocessed proposal count

Auto-repair actions (`--fix`):
- Reset stuck claimed tasks to pending
- Expire stale deferrals
- Regenerate STATE.json and BACKLOG.md from SQLite
- Process pending proposals
- Sync BACKLOG.md completions

---

## Configuration Reference

### ralph.config.json

```json
{
  "name": "project-name",
  "lang": "python",
  "build": "python -m py_compile",
  "lint": "ruff check",
  "test": "pytest",
  "test_unit": "pytest -x --tb=short",
  "fmt": "ruff format --check",
  "forbidden_patterns": "bare except:|eval(|import *",
  "domain_constraints": "ALL SQL must include tenant_id",
  "model": "opus",
  "budget_primary": "2.50",
  "budget_worker": "5.00"
}
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PROJ_DIR` | current directory | Project root |
| `RALPH_DIR` | `$PROJ_DIR/.ralph` | Ralph data directory |
| `MODEL` | `opus` | Claude model alias |
| `EFFORT` | `max` | Claude effort level |
| `BUDGET_PRIMARY` | `$2.50` | Per-invocation cost limit for primary |
| `BUDGET_WORKER` | `$5.00` | Per-invocation cost limit for worker |
| `INTERVAL_PRIMARY` | `20` | Base sleep between primary iterations (seconds) |
| `INTERVAL_WORKER` | `30` | Sleep between worker cycles (seconds) |

### Adaptive Sleep

Sleep between iterations adapts to the next phase:

| Phase | Sleep | Rationale |
|-------|-------|-----------|
| `implement` | 5s | Sub-step iterations should chain quickly |
| `assess`, `commit` | 10s | Fast phases |
| `plan`, `verify`, `reflect` | 15s | Significant reading |
| Periodic phases | 10s | Avoid stalling the loop |

### Hard Limits

| Limit | Value |
|-------|-------|
| Max retry per sub-step | 3 |
| Deferral auto-expiry | 20 commits |
| Max backlog size | 300 items |
| Max pending per wave | 50 items |
| Build must pass | Always |
| Tests must not regress | Always |
| No force-push | Always |
| No skip verification | Always |

---

## Design Principles

| # | Principle | Implementation |
|---|-----------|---------------|
| 1 | **Proposals, not mutations** | Agents propose plans/patches/items. Control plane decides. |
| 2 | **Event-sourced truth** | SQLite append-only log. STATE.json and BACKLOG.md are derived views. |
| 3 | **Transactional task lifecycle** | Task cannot be `done` until its patch is `promoted` in the event log. |
| 4 | **Risk-tiered autonomy** | Tier 0-1 auto-promote. Tier 2 deferred to independent judge. Tier 3 decomposed. |
| 5 | **Generator/Judge separation** | Independent judge reviews deferred items in separate invocation. |
| 6 | **Fresh context per invocation** | State on disk. Each agent call starts clean -- no context degradation. |
| 7 | **Machine-verifiable gates** | Build, test, pattern grep. Never trust agent self-assessment. |
| 8 | **The loop never blocks on a human** | Deferred items auto-expire. Humans override asynchronously. |

---

## Research Basis

Design informed by:

- **Reflexion** (NeurIPS 2023) -- verbal reinforcement for self-correcting agents
- **SWE-agent** (NeurIPS 2024) -- agent-computer interface for software engineering
- **OpenHands** (ICLR 2025) -- platform for AI software developers
- **AutoCodeRover** (ISSTA 2024) -- autonomous program improvement
- **Aider** -- architect/editor split pattern
- **Self-Refine** (NeurIPS 2023) -- iterative refinement with self-feedback
- **CodeAct** -- executable code actions for LLM agents

---

## Metrics & Observability

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

---

## Glossary

| Term | Definition |
|------|-----------|
| **Wave** | Priority-ordered batch of work items |
| **Phase** | One step in the state machine (11 phases total) |
| **Iteration** | One invocation of `claude -p` executing one phase |
| **Sub-step** | One step within a plan (L/XL items have multiple) |
| **Guardrail** | Learned anti-pattern with trigger and corrective instruction |
| **Reflection** | Verbal failure diagnosis persisted for future avoidance |
| **Deferred merge** | Patch queued by worker, applied by primary via git plumbing |
| **Promotion** | Atomic operation: patch->promoted + task->done in event log |
| **Derived view** | STATE.json or BACKLOG.md regenerated from SQLite truth |
| **Proposal** | Suggested backlog change from evolve_goals, subject to policy acceptance |
| **Risk tier** | 0-3 classification governing autonomy level for a task |
| **Independent judge** | Separate Claude invocation reviewing deferred items |

---

## License

See repository root for license details.
