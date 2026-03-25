#!/usr/bin/env bash
# ralph-init.sh — Bootstrap Ralph Loop v3 for any project.
# Auto-detects language and generates all configuration, phase files, and data structures.
#
# Usage:
#   ralph-init.sh                              # auto-detect language
#   ralph-init.sh --lang python --name "my-app"
#   ralph-init.sh --config ralph.config.json
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="${PROJ_DIR:-$(pwd)}"
RALPH_DIR="${PROJ_DIR}/.ralph"
LANG=""
PROJECT_NAME=""
CONFIG_FILE=""
MODEL="opus"
BUDGET_PRIMARY="2.50"
BUDGET_WORKER="5.00"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --lang)     LANG="$2"; shift 2 ;;
        --name)     PROJECT_NAME="$2"; shift 2 ;;
        --config)   CONFIG_FILE="$2"; shift 2 ;;
        --dir)      PROJ_DIR="$2"; RALPH_DIR="${PROJ_DIR}/.ralph"; shift 2 ;;
        --model)    MODEL="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: ralph-init.sh [--lang <language>] [--name <project>] [--config <file>] [--dir <path>]"
            echo ""
            echo "Languages: rust, python, typescript, go, java, ruby, csharp, generic"
            echo ""
            echo "If --lang is omitted, auto-detects from project files."
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Load config file if provided
# ---------------------------------------------------------------------------
if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
    LANG=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('lang',''))" 2>/dev/null || true)
    PROJECT_NAME=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('name',''))" 2>/dev/null || true)
    MODEL=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('model','opus'))" 2>/dev/null || true)
fi

# ---------------------------------------------------------------------------
# Auto-detect language
# ---------------------------------------------------------------------------
detect_language() {
    cd "$PROJ_DIR"
    if [[ -f "Cargo.toml" ]]; then echo "rust"
    elif [[ -f "pyproject.toml" || -f "setup.py" || -f "requirements.txt" || -f "Pipfile" ]]; then echo "python"
    elif [[ -f "package.json" ]]; then
        if grep -q '"typescript"' package.json 2>/dev/null || [[ -f "tsconfig.json" ]]; then
            echo "typescript"
        else
            echo "typescript"  # default JS projects to TS tooling
        fi
    elif [[ -f "go.mod" ]]; then echo "go"
    elif [[ -f "pom.xml" || -f "build.gradle" || -f "build.gradle.kts" ]]; then echo "java"
    elif [[ -f "Gemfile" ]]; then echo "ruby"
    elif [[ -f "*.csproj" || -f "*.sln" ]] 2>/dev/null; then echo "csharp"
    elif ls ./*.csproj >/dev/null 2>&1 || ls ./*.sln >/dev/null 2>&1; then echo "csharp"
    else echo "generic"
    fi
}

if [[ -z "$LANG" ]]; then
    LANG=$(detect_language)
fi

if [[ -z "$PROJECT_NAME" ]]; then
    PROJECT_NAME=$(basename "$PROJ_DIR")
fi

echo "=== Ralph Loop v3 Bootstrap ==="
echo "Project: $PROJECT_NAME"
echo "Language: $LANG"
echo "Directory: $PROJ_DIR"
echo ""

# ---------------------------------------------------------------------------
# Language-specific configuration
# ---------------------------------------------------------------------------
declare -A BUILD_CMD TEST_CMD TEST_UNIT_CMD LINT_CMD FMT_CMD FORBIDDEN_PATTERNS

BUILD_CMD=(
    [rust]="cargo check --workspace"
    [python]="python -m py_compile"
    [typescript]="npm run build"
    [go]="go build ./..."
    [java]="mvn compile"
    [ruby]="ruby -c"
    [csharp]="dotnet build"
    [generic]="make build"
)

TEST_CMD=(
    [rust]="cargo test --workspace"
    [python]="pytest"
    [typescript]="npm test"
    [go]="go test ./..."
    [java]="mvn test"
    [ruby]="rspec"
    [csharp]="dotnet test"
    [generic]="make test"
)

TEST_UNIT_CMD=(
    [rust]="cargo test --lib"
    [python]="pytest -x --tb=short"
    [typescript]="npm test -- --bail"
    [go]="go test -short ./..."
    [java]="mvn test -pl ."
    [ruby]="rspec --fail-fast"
    [csharp]="dotnet test --filter 'Category!=Integration'"
    [generic]="make test"
)

LINT_CMD=(
    [rust]="cargo clippy --workspace -- -D warnings"
    [python]="ruff check"
    [typescript]="npx eslint ."
    [go]="golangci-lint run"
    [java]="mvn checkstyle:check"
    [ruby]="rubocop"
    [csharp]="dotnet format --verify-no-changes"
    [generic]="make lint"
)

FMT_CMD=(
    [rust]="cargo fmt --check"
    [python]="ruff format --check"
    [typescript]="npx prettier --check ."
    [go]="gofmt -l ."
    [java]="mvn spotless:check"
    [ruby]="rubocop -A"
    [csharp]="dotnet format"
    [generic]="true"
)

FORBIDDEN_PATTERNS=(
    [rust]='.unwrap() outside #[cfg(test)]|.expect() outside #[cfg(test)]|panic!() outside tests'
    [python]='bare except:|eval(|import \*'
    [typescript]='any type annotation|console.log in production|eval('
    [go]='panic() in libraries|os.Exit() outside main'
    [java]='System.out.println|catch (Exception) without logging'
    [ruby]='eval(|puts in production|rescue Exception'
    [csharp]='Console.WriteLine|Thread.Sleep in async'
    [generic]='TODO|FIXME|HACK'
)

# Resolve for selected language
build_cmd="${BUILD_CMD[$LANG]:-make build}"
test_cmd="${TEST_CMD[$LANG]:-make test}"
test_unit_cmd="${TEST_UNIT_CMD[$LANG]:-make test}"
lint_cmd="${LINT_CMD[$LANG]:-make lint}"
fmt_cmd="${FMT_CMD[$LANG]:-true}"
forbidden="${FORBIDDEN_PATTERNS[$LANG]:-TODO|FIXME|HACK}"

# ---------------------------------------------------------------------------
# Create directory structure
# ---------------------------------------------------------------------------
echo "Creating .ralph/ directory structure..."
mkdir -p "$RALPH_DIR"/{phases,proposals/processed,commits/pending,commits/applied,locks,logs}

# ---------------------------------------------------------------------------
# Generate core.md
# ---------------------------------------------------------------------------
cat > "$RALPH_DIR/core.md" << COREEOF
# Coding Standards — ${PROJECT_NAME} (${LANG})

## Build & Test Commands
- Build: \`${build_cmd}\`
- Test (full): \`${test_cmd}\`
- Test (unit): \`${test_unit_cmd}\`
- Lint: \`${lint_cmd}\`
- Format: \`${fmt_cmd}\`

## Forbidden Patterns
${forbidden}

## Rules
1. NEVER skip build verification after code changes.
2. NEVER commit code that fails the build command.
3. NEVER introduce forbidden patterns.
4. Prefer editing existing files over creating new ones.
5. Keep changes minimal and focused on the current task.
6. Run the lint command before committing.
COREEOF

# ---------------------------------------------------------------------------
# Generate STATE.json
# ---------------------------------------------------------------------------
cat > "$RALPH_DIR/STATE.json" << STATEEOF
{
  "iteration": 0,
  "phase": "assess",
  "current_item": null,
  "current_plan": null,
  "current_sub_step": 0,
  "current_wave": 0,
  "retry_count": 0,
  "commits_total": 0,
  "compile_status": "unknown",
  "test_status": "unknown",
  "items_done_count": 0,
  "items_blocked_count": 0,
  "items_deferred_count": 0,
  "items_pending_count": 0,
  "items_total_count": 0,
  "progress_history": [],
  "last_evolve_at": 0,
  "last_dry_at": 0,
  "last_integ_at": 0,
  "last_ui_at": 0
}
STATEEOF

# ---------------------------------------------------------------------------
# Generate BACKLOG.md
# ---------------------------------------------------------------------------
cat > "$RALPH_DIR/BACKLOG.md" << 'BACKLOGEOF'
# BACKLOG

## Wave 0: Critical Fixes & Foundation

| ID | Status | Title | Source | Effort | Deps |
|----|--------|-------|--------|--------|------|

## Wave 1: Core Infrastructure

| ID | Status | Title | Source | Effort | Deps |
|----|--------|-------|--------|--------|------|

## Wave 2: Core Features

| ID | Status | Title | Source | Effort | Deps |
|----|--------|-------|--------|--------|------|
BACKLOGEOF

# ---------------------------------------------------------------------------
# Generate GUARDRAILS.md
# ---------------------------------------------------------------------------
cat > "$RALPH_DIR/GUARDRAILS.md" << 'GUARDRAILSEOF'
# GUARDRAILS — Learned Anti-Patterns

---
trigger: implementing any code change
instruction: Scan for forbidden patterns BEFORE implementing. Run grep on target files for known forbidden patterns listed in core.md. Include fixing ALL pre-existing violations in your plan. This prevents reflect loops caused by pre-existing violations discovered only at verify time.
learned_at: iteration 0 (pre-loaded)
---

---
trigger: planning a crate/module/package-wide refactor
instruction: Run exhaustive grep before scoping. Search the ENTIRE codebase for the pattern you plan to change, not just the files you initially found. Missing call sites causes verify failures and wastes iterations.
learned_at: iteration 0 (pre-loaded)
---
GUARDRAILSEOF

# ---------------------------------------------------------------------------
# Generate REFLECTIONS.md
# ---------------------------------------------------------------------------
cat > "$RALPH_DIR/REFLECTIONS.md" << 'REFLEOF'
# REFLECTIONS — Failure Analysis Log

Format: `iteration: N | item: X | class: Y | "lesson"`
Classes: TRANSIENT (retry), LLM_RECOVERABLE (replan), ENVIRONMENT (fix env), FUNDAMENTAL (block)

REFLEOF

# ---------------------------------------------------------------------------
# Generate EVOLVE_LOG.md
# ---------------------------------------------------------------------------
cat > "$RALPH_DIR/EVOLVE_LOG.md" << EVOLVEEOF
# EVOLVE LOG — Goal Evolution History

## Initial Bootstrap
- Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Project: ${PROJECT_NAME}
- Language: ${LANG}
- Action: Ralph Loop v3 initialized
EVOLVEEOF

# ---------------------------------------------------------------------------
# Generate SPEC_REGISTRY.md
# ---------------------------------------------------------------------------
{
    echo "# SPEC REGISTRY — Discovered Specification Documents"
    echo ""
    echo "| File | Type | Last Read | Sections | Items Generated |"
    echo "|------|------|-----------|----------|-----------------|"

    # Auto-discover spec files
    if [[ -d "${PROJ_DIR}/specs" ]]; then
        find "${PROJ_DIR}/specs" -type f \( -name "*.md" -o -name "*.json" -o -name "*.yml" -o -name "*.yaml" \) 2>/dev/null | sort | while read -r spec; do
            relpath="${spec#${PROJ_DIR}/}"
            echo "| ${relpath} | spec | never | - | 0 |"
        done
    fi
    if [[ -d "${PROJ_DIR}/docs" ]]; then
        find "${PROJ_DIR}/docs" -type f -name "*.md" 2>/dev/null | sort | while read -r spec; do
            relpath="${spec#${PROJ_DIR}/}"
            echo "| ${relpath} | doc | never | - | 0 |"
        done
    fi
    if [[ -d "${PROJ_DIR}/adrs" ]]; then
        find "${PROJ_DIR}/adrs" -type f -name "*.md" 2>/dev/null | sort | while read -r spec; do
            relpath="${spec#${PROJ_DIR}/}"
            echo "| ${relpath} | adr | never | - | 0 |"
        done
    fi
} > "$RALPH_DIR/SPEC_REGISTRY.md"

# ---------------------------------------------------------------------------
# Generate Phase Files
# ---------------------------------------------------------------------------
echo "Generating phase files..."

# --- assess.md ---
cat > "$RALPH_DIR/phases/assess.md" << 'PHASEEOF'
# Phase: ASSESS

Pick the next work item. Rules:
1. If STATE.json has `current_item` set and not done -> resume it at its last sub-phase
2. Otherwise scan the BACKLOG section below for the first `pending` item (top to bottom)
3. Skip items whose deps are not all `done` -> mark `blocked` in backlog
4. Set STATE.json: `phase`="plan", `current_item`=<chosen ID>, increment `iteration`
5. If no pending items remain in this wave, advance `current_wave` and re-scan

Do NOT read any code files. Do NOT implement anything. Just pick the item and update state.
PHASEEOF

# --- plan.md ---
cat > "$RALPH_DIR/phases/plan.md" << PHASEEOF
# Phase: PLAN

Create a concrete plan for the current item. Steps:

1. Read the relevant spec/issue/requirement referenced in the item's Source field.
2. Read GUARDRAILS.md for relevant anti-patterns.
3. Find existing code: use Grep/Glob to locate relevant files, then Read them.
   If 3+ files need reading, launch parallel Explore agents.
4. **PRE-PLAN SCAN**: For each file in your plan, grep for forbidden patterns.
   Include fixing ALL pre-existing violations in your plan.
5. Write plan to STATE.json \`current_plan\`:
   {"files_modify":["a"],"files_create":["b"],"sub_steps":[{"step":1,"desc":"...","verify":"${build_cmd}"}],"acceptance":"..."}
6. For L/XL items: plan only the first sub-step batch for this iteration.
7. Set STATE.json: \`phase\`="implement", \`current_sub_step\`=1
PHASEEOF

# --- implement.md ---
cat > "$RALPH_DIR/phases/implement.md" << PHASEEOF
# Phase: IMPLEMENT

Execute one sub-step from the plan in STATE.json.

1. Read \`current_plan.sub_steps[current_sub_step - 1]\`
2. Write code: Edit existing files (preferred) or Write new files
3. IMMEDIATE verification: \`${build_cmd} 2>&1 | tail -50\`
   - If FAIL: fix the error, re-check. Max 3 attempts.
   - After 3 fails: set \`phase\`="reflect"
4. If build passes: run unit test: \`${test_unit_cmd} 2>&1 | tail -30\`
5. If all sub-steps done: set \`phase\`="verify"
6. If more sub-steps: increment \`current_sub_step\`, keep \`phase\`="implement"
PHASEEOF

# --- verify.md ---
cat > "$RALPH_DIR/phases/verify.md" << PHASEEOF
# Phase: VERIFY

Machine-verifiable quality gates. Run ALL:

1. \`${build_cmd}\` -> must pass
2. \`${test_unit_cmd}\` -> must pass for changed modules
3. Grep changed files for forbidden patterns (from core.md)
4. ALL pass -> set \`phase\`="commit"
5. ANY fail -> set \`phase\`="reflect", increment \`retry_count\`
PHASEEOF

# --- reflect.md ---
cat > "$RALPH_DIR/phases/reflect.md" << 'PHASEEOF'
# Phase: REFLECT

Diagnose the failure. Classify and persist the lesson.

1. Read the error from last verify/implement attempt
2. Classify:
   - TRANSIENT (timeout, flaky) -> retry same approach
   - LLM_RECOVERABLE (wrong approach, type error) -> re-plan
   - ENVIRONMENT (missing dep, toolchain) -> fix env, retry
   - FUNDAMENTAL (ambiguous spec, impossible) -> mark blocked
3. Append 1-2 sentence reflection to REFLECTIONS.md:
   `iteration: N | item: X | class: Y | "Failed because Z. Next time W."`
4. If FUNDAMENTAL or retry_count >= 3: mark item blocked, clear current_item, phase="assess"
5. If LLM_RECOVERABLE: phase="plan" (re-plan with reflection)
6. If TRANSIENT: phase="implement" (retry)
7. If this is a recurring pattern, add guardrail to GUARDRAILS.md
PHASEEOF

# --- commit.md ---
cat > "$RALPH_DIR/phases/commit.md" << 'PHASEEOF'
# Phase: COMMIT

Persist progress with a structured commit.

1. Stage changed files: `git add <files from plan>`
2. Also stage: `.ralph/STATE.json .ralph/BACKLOG.md`
3. Commit:
   git commit -m "ralph(W<wave>-<id>): <brief description>
   Implements <source>.
   Co-Authored-By: Claude <model> <noreply@anthropic.com>"
4. Update BACKLOG.md: item status -> "done"
5. Update STATE.json: increment `commits_total`, `items_done_count`, clear `current_item`/`current_plan`
6. Set `phase`="assess"
PHASEEOF

# --- evolve_goals.md ---
cat > "$RALPH_DIR/phases/evolve_goals.md" << 'PHASEEOF'
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
Write one JSON file per proposal: prop_<timestamp>_<n>.json
  {"proposal_type":"new_task", "confidence":0.85, "task":{"id":"W3-035","title":"...","effort":"S","wave":3,"deps":"-"}, "rationale":"..."}
  {"proposal_type":"decompose", "parent_task":"W3-002", "confidence":0.9, "sub_tasks":[...], "rationale":"..."}

## 4. Standard evaluation
- git log --oneline -5
- Blocked items unblockable differently? -> emit proposal

## 5. Update SPEC_REGISTRY.md, EVOLVE_LOG.md
- Set `phase`="assess", `last_evolve_at`=commits_total

Do NOT modify BACKLOG.md directly. The control plane processes proposals after this phase.
PHASEEOF

# --- refactor_dry.md ---
cat > "$RALPH_DIR/phases/refactor_dry.md" << PHASEEOF
# Phase: REFACTOR_DRY

Eliminate duplication in recent work. Runs every 5 commits.

1. \`git diff HEAD~5..HEAD --stat\` — identify changed files
2. Look for: duplicated logic -> extract helper; copy-paste -> macro; 3+ similar -> trait/interface; >800 LOC -> split
3. Implement refactoring, verify with \`${build_cmd}\` + \`${test_cmd}\`
4. Commit refactoring
5. Set \`phase\`="assess", \`last_dry_at\`=commits_total
PHASEEOF

# --- test_integration.md ---
cat > "$RALPH_DIR/phases/test_integration.md" << PHASEEOF
# Phase: TEST_INTEGRATION

Full test suite. Runs every 10 commits.

1. \`${test_cmd} 2>&1 | tail -100\` — fix any failures
2. Run integration tests if configured
3. Update STATE.json: \`last_integ_at\` = commits_total
4. If failures: \`phase\`="reflect"
5. If all pass: \`phase\`="assess"
PHASEEOF

# --- test_ui.md ---
cat > "$RALPH_DIR/phases/test_ui.md" << 'PHASEEOF'
# Phase: TEST_UI

Browser/E2E testing. Runs every 15 commits. Skip if no UI.

1. Check if server can start
2. Run end-to-end tests if configured
3. For NEW features: create test specs
4. Update STATE.json: `last_ui_at` = commits_total
5. Set `phase`="assess"
PHASEEOF

# --- review_deferred.md ---
cat > "$RALPH_DIR/phases/review_deferred.md" << 'PHASEEOF'
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
PHASEEOF

echo "  Created 11 phase files"

# ---------------------------------------------------------------------------
# Generate ralph.config.json
# ---------------------------------------------------------------------------
cat > "$PROJ_DIR/ralph.config.json" << CONFIGEOF
{
  "name": "${PROJECT_NAME}",
  "lang": "${LANG}",
  "build": "${build_cmd}",
  "lint": "${lint_cmd}",
  "test": "${test_cmd}",
  "test_unit": "${test_unit_cmd}",
  "fmt": "${fmt_cmd}",
  "forbidden_patterns": "${forbidden}",
  "domain_constraints": "",
  "model": "${MODEL}",
  "budget_primary": "${BUDGET_PRIMARY}",
  "budget_worker": "${BUDGET_WORKER}"
}
CONFIGEOF

# ---------------------------------------------------------------------------
# Copy ralphctl.py if not present
# ---------------------------------------------------------------------------
if [[ ! -f "$RALPH_DIR/ralphctl.py" ]]; then
    if [[ -f "$SCRIPT_DIR/../.ralph/ralphctl.py" ]]; then
        cp "$SCRIPT_DIR/../.ralph/ralphctl.py" "$RALPH_DIR/ralphctl.py"
        echo "Copied ralphctl.py to .ralph/"
    elif [[ -f "$SCRIPT_DIR/ralphctl.py" ]]; then
        cp "$SCRIPT_DIR/ralphctl.py" "$RALPH_DIR/ralphctl.py"
        echo "Copied ralphctl.py to .ralph/"
    else
        echo "WARNING: ralphctl.py not found. Place it at .ralph/ralphctl.py manually."
    fi
fi

# ---------------------------------------------------------------------------
# Initialize SQLite database
# ---------------------------------------------------------------------------
echo ""
echo "Initializing SQLite database..."
cd "$PROJ_DIR"
python3 "$RALPH_DIR/ralphctl.py" init

# ---------------------------------------------------------------------------
# Initialize git repo if needed
# ---------------------------------------------------------------------------
if [[ ! -d "$PROJ_DIR/.git" ]]; then
    echo ""
    echo "Initializing git repository..."
    cd "$PROJ_DIR"
    git init
    git add -A
    git commit -m "ralph-init: bootstrap project ${PROJECT_NAME} (${LANG})

Ralph Loop v3 initialized with event-sourced control plane.
Co-Authored-By: Ralph Loop <noreply@ralph.dev>"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Ralph Loop v3 Initialized ==="
echo ""
echo "Files created:"
echo "  .ralph/core.md              — Coding standards (${LANG})"
echo "  .ralph/STATE.json           — Machine state"
echo "  .ralph/BACKLOG.md           — Work items"
echo "  .ralph/GUARDRAILS.md        — Learned anti-patterns (2 pre-loaded)"
echo "  .ralph/REFLECTIONS.md       — Failure analysis log"
echo "  .ralph/EVOLVE_LOG.md        — Goal evolution history"
echo "  .ralph/SPEC_REGISTRY.md     — Spec document tracker"
echo "  .ralph/ralph.db             — SQLite event log"
echo "  .ralph/ralphctl.py          — Control plane"
echo "  .ralph/phases/*.md          — 11 phase instruction files"
echo "  ralph.config.json           — Project configuration"
echo ""
echo "Next steps:"
echo "  1. Add work items to .ralph/BACKLOG.md (or add specs to specs/)"
echo "  2. Run: python3 .ralph/ralphctl.py init   (if you modified BACKLOG.md)"
echo "  3. Run: ./scripts/ralph-parallel.sh        (start the loop)"
echo "  4. Monitor: tail -f .ralph/logs/parallel-nohup.log"
echo ""
