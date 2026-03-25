#!/usr/bin/env python3
"""Ralph Loop v3 Control Plane — Event-sourced task and patch management.

Single-file module (~793 lines). Standard library only.
SQLite append-only event log is canonical truth. STATE.json and BACKLOG.md are derived views.
"""

import hashlib
import json
import os
import re
import shutil
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

RALPH_DIR = os.environ.get('RALPH_DIR', os.path.dirname(os.path.abspath(__file__)))
DB_PATH = os.path.join(RALPH_DIR, 'ralph.db')
STATE_PATH = os.path.join(RALPH_DIR, 'STATE.json')
BACKLOG_PATH = os.path.join(RALPH_DIR, 'BACKLOG.md')
PROPOSALS_DIR = os.path.join(RALPH_DIR, 'proposals')

DEFERRAL_EXPIRY_COMMITS = 20
MAX_BACKLOG_SIZE = 300
MAX_PENDING_PER_WAVE = 50

VALID_TASK_STATUSES = {'pending', 'claimed', 'proposed', 'done', 'deferred', 'blocked', 'dropped'}
VALID_PATCH_STATUSES = {'queued', 'applied', 'verified', 'promoted', 'discarded'}

# Risk classification patterns — replace per project via ralph.config.json
RISK_PATTERNS = {
    'tier2_files': ['sql/migrations/', 'migrations/', 'handlers/auth/', 'auth/', 'middleware/auth'],
    'tier2_sources': ['ES:30', 'ES:67'],
    'tier3_files': ['.env', 'secrets', 'credentials', '.key', '.pem', 'private'],
    'tier3_keywords': ['DROP TABLE', 'DROP COLUMN', 'DROP DATABASE', 'TRUNCATE', 'rm -rf'],
    'tier0_files': ['schemas/', 'docs/', 'test_data/', 'fixtures/', 'README', '.md', 'ci/', '.github/'],
    'tier0_effort': ['S'],
}

# Wave titles — configurable
WAVE_TITLES = {
    0: 'Wave 0: Critical Fixes & Foundation',
    1: 'Wave 1: Core Infrastructure',
    2: 'Wave 2: Core Features',
    3: 'Wave 3: Extended Features',
    4: 'Wave 4: Polish & Testing',
    5: 'Wave 5: Documentation & Deployment',
    6: 'Wave 6: Optimization',
    7: 'Wave 7: Future Enhancements',
    8: 'Wave 8: Stretch Goals',
}


def _load_config_patterns():
    """Load project-specific risk patterns from ralph.config.json if available."""
    global RISK_PATTERNS
    config_path = os.path.join(os.path.dirname(RALPH_DIR), 'ralph.config.json')
    if not os.path.exists(config_path):
        config_path = os.path.join(RALPH_DIR, '..', 'ralph.config.json')
    if os.path.exists(config_path):
        try:
            with open(config_path) as f:
                cfg = json.load(f)
            if 'risk_patterns' in cfg:
                RISK_PATTERNS.update(cfg['risk_patterns'])
        except (json.JSONDecodeError, IOError):
            pass


_load_config_patterns()

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

_SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS events (
    event_id    TEXT PRIMARY KEY,
    ts          TEXT NOT NULL,
    run_id      TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id   TEXT NOT NULL,
    event_type  TEXT NOT NULL,
    actor       TEXT NOT NULL,
    payload     TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS task_view (
    task_id         TEXT PRIMARY KEY,
    status          TEXT NOT NULL DEFAULT 'pending',
    title           TEXT,
    source          TEXT,
    effort          TEXT,
    deps            TEXT DEFAULT '-',
    wave            INTEGER DEFAULT 0,
    risk_tier       INTEGER DEFAULT 1,
    claimed_by      TEXT,
    patch_id        TEXT,
    version         INTEGER DEFAULT 1,
    deferred_reason TEXT,
    deferred_at     TEXT,
    provenance      TEXT DEFAULT 'spec'
);

CREATE TABLE IF NOT EXISTS patch_view (
    patch_id    TEXT PRIMARY KEY,
    task_id     TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'queued',
    patch_path  TEXT,
    created_by  TEXT,
    created_at  TEXT,
    applied_at  TEXT,
    commit_hash TEXT
);

CREATE INDEX IF NOT EXISTS idx_events_entity ON events(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type);
CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
CREATE INDEX IF NOT EXISTS idx_task_status ON task_view(status);
CREATE INDEX IF NOT EXISTS idx_task_wave ON task_view(wave);
CREATE INDEX IF NOT EXISTS idx_patch_task ON patch_view(task_id);
CREATE INDEX IF NOT EXISTS idx_patch_status ON patch_view(status);
"""


def get_db():
    """Open SQLite connection with WAL mode and auto-schema creation."""
    db = sqlite3.connect(DB_PATH)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA busy_timeout=5000")
    _ensure_schema(db)
    return db


def _ensure_schema(db):
    """Create tables and indices if they don't exist."""
    db.executescript(_SCHEMA_SQL)


def _run_id():
    """Generate a run ID from the current date and PID."""
    return f"run_{datetime.now(timezone.utc).strftime('%Y%m%d')}_{os.getpid()}"


# ---------------------------------------------------------------------------
# Event Emission
# ---------------------------------------------------------------------------

def emit_event(db, entity_type, entity_id, event_type, actor, payload=None):
    """Append an event to the canonical log. Returns the event_id."""
    ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    ts_compact = datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')
    raw = f"{entity_type}{entity_id}{event_type}{ts}{actor}"
    hash8 = hashlib.md5(raw.encode()).hexdigest()[:8]
    event_id = f"evt_{ts_compact}_{hash8}"
    payload_json = json.dumps(payload or {})

    db.execute(
        "INSERT INTO events (event_id, ts, run_id, entity_type, entity_id, event_type, actor, payload) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (event_id, ts, _run_id(), entity_type, entity_id, event_type, actor, payload_json)
    )
    db.commit()
    return event_id


# ---------------------------------------------------------------------------
# Task Operations
# ---------------------------------------------------------------------------

def transition_task(db, task_id, new_status, actor, **extra):
    """Transition a task to a new status, emitting an event and updating task_view."""
    if new_status not in VALID_TASK_STATUSES:
        print(f"ERROR: Invalid status '{new_status}'", file=sys.stderr)
        return False

    row = db.execute("SELECT * FROM task_view WHERE task_id=?", (task_id,)).fetchone()
    old_status = row['status'] if row else 'unknown'

    payload = {'old_status': old_status, 'new_status': new_status}
    payload.update(extra)
    emit_event(db, 'task', task_id, f'task.{new_status}', actor, payload)

    if row:
        updates = ['status=?', 'version=version+1']
        params = [new_status]

        if new_status == 'deferred':
            updates.append('deferred_reason=?')
            params.append(extra.get('deferred_reason', ''))
            updates.append('deferred_at=?')
            params.append(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
        elif new_status in ('pending', 'done', 'claimed'):
            updates.append('deferred_reason=NULL')
            updates.append('deferred_at=NULL')

        if 'claimed_by' in extra:
            updates.append('claimed_by=?')
            params.append(extra['claimed_by'])
        if 'patch_id' in extra:
            updates.append('patch_id=?')
            params.append(extra['patch_id'])
        if 'risk_tier' in extra:
            updates.append('risk_tier=?')
            params.append(extra['risk_tier'])

        params.append(task_id)
        db.execute(f"UPDATE task_view SET {', '.join(updates)} WHERE task_id=?", params)
    else:
        db.execute(
            "INSERT INTO task_view (task_id, status, title, source, effort, deps, wave, claimed_by, provenance) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (task_id, new_status,
             extra.get('title', ''),
             extra.get('source', ''),
             extra.get('effort', 'S'),
             extra.get('deps', '-'),
             extra.get('wave', 0),
             extra.get('claimed_by', ''),
             extra.get('provenance', 'auto'))
        )

    db.commit()
    return True


def pick_ready_task(db, executor_type, exclude_task_id=None):
    """Find the next eligible task for the given executor type."""
    if executor_type == 'worker':
        query = "SELECT * FROM task_view WHERE status='pending' AND effort='S' ORDER BY wave, task_id"
    else:
        # Primary: prefer current wave items
        state = _read_state()
        current_wave = state.get('current_wave', 0)
        query = (
            "SELECT * FROM task_view WHERE status='pending' "
            f"ORDER BY CASE WHEN wave={current_wave} THEN 0 ELSE 1 END, wave, task_id"
        )

    rows = db.execute(query).fetchall()

    for row in rows:
        tid = row['task_id']
        if exclude_task_id and tid == exclude_task_id:
            continue

        deps_str = row['deps'] or '-'
        if deps_str == '-' or deps_str.strip() == '':
            print(tid)
            return tid

        dep_ids = [d.strip() for d in deps_str.split(',') if d.strip() and d.strip() != '-']
        if not dep_ids:
            print(tid)
            return tid

        all_met = True
        for dep_id in dep_ids:
            dep_row = db.execute("SELECT status FROM task_view WHERE task_id=?", (dep_id,)).fetchone()
            if not dep_row or dep_row['status'] != 'done':
                all_met = False
                break

        if all_met:
            print(tid)
            return tid

    print('NONE')
    return 'NONE'


# ---------------------------------------------------------------------------
# Patch Operations
# ---------------------------------------------------------------------------

def queue_patch(db, task_id, patch_path, created_by):
    """Queue a patch from the worker. Returns patch_id."""
    ts_compact = datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')
    patch_id = f"patch_{task_id}_{ts_compact}"

    emit_event(db, 'patch', patch_id, 'patch.queued', created_by, {
        'task_id': task_id, 'patch_path': patch_path
    })

    ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    db.execute(
        "INSERT INTO patch_view (patch_id, task_id, status, patch_path, created_by, created_at) "
        "VALUES (?, ?, 'queued', ?, ?, ?)",
        (patch_id, task_id, patch_path, created_by, ts)
    )

    transition_task(db, task_id, 'proposed', created_by)
    print(patch_id)
    return patch_id


def promote_patch(db, patch_id, commit_hash):
    """Atomic promotion: patch→promoted + task→done in one transaction."""
    patch_row = db.execute("SELECT * FROM patch_view WHERE patch_id=?", (patch_id,)).fetchone()
    if not patch_row:
        print(f"ERROR: Patch {patch_id} not found", file=sys.stderr)
        return False

    task_id = patch_row['task_id']

    # Emit both events
    emit_event(db, 'patch', patch_id, 'patch.promoted', 'control_plane', {
        'commit_hash': commit_hash, 'task_id': task_id
    })
    emit_event(db, 'task', task_id, 'task.completed', 'control_plane', {
        'patch_id': patch_id, 'commit_hash': commit_hash
    })

    # Update both views atomically
    ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    db.execute(
        "UPDATE patch_view SET status='promoted', commit_hash=?, applied_at=? WHERE patch_id=?",
        (commit_hash, ts, patch_id)
    )
    db.execute(
        "UPDATE task_view SET status='done', patch_id=?, version=version+1, "
        "deferred_reason=NULL, deferred_at=NULL WHERE task_id=?",
        (patch_id, task_id)
    )
    db.commit()
    print(f"PROMOTED {patch_id} → {task_id} done (commit {commit_hash[:8]})")
    return True


def discard_patch(db, patch_id, reason):
    """Discard a patch and revert its task to pending."""
    patch_row = db.execute("SELECT * FROM patch_view WHERE patch_id=?", (patch_id,)).fetchone()
    if not patch_row:
        print(f"ERROR: Patch {patch_id} not found", file=sys.stderr)
        return False

    task_id = patch_row['task_id']
    emit_event(db, 'patch', patch_id, 'patch.discarded', 'control_plane', {
        'reason': reason, 'task_id': task_id
    })
    db.execute("UPDATE patch_view SET status='discarded' WHERE patch_id=?", (patch_id,))
    transition_task(db, task_id, 'pending', 'control_plane')
    print(f"DISCARDED {patch_id} ({reason}) → {task_id} pending")
    return True


# ---------------------------------------------------------------------------
# Risk Classification
# ---------------------------------------------------------------------------

def classify_risk(db, task_id):
    """Classify a task's risk tier (0-3) from file patterns."""
    row = db.execute("SELECT * FROM task_view WHERE task_id=?", (task_id,)).fetchone()
    if not row:
        return 1

    files = []
    # Try to get file list from current plan in STATE.json
    state = _read_state()
    plan = state.get('current_plan', {})
    if isinstance(plan, dict):
        files.extend(plan.get('files_modify', []))
        files.extend(plan.get('files_create', []))

    source = row['source'] or ''
    effort = row['effort'] or 'M'

    # Tier 3: restricted (check first)
    for f in files:
        for pat in RISK_PATTERNS.get('tier3_files', []):
            if pat.lower() in f.lower():
                return 3
    # Tier 3 keyword check would require reading file content — skip for classification

    # Tier 2: sensitive paths
    for f in files:
        for pat in RISK_PATTERNS.get('tier2_files', []):
            if pat.lower() in f.lower():
                return 2
    for src_pat in RISK_PATTERNS.get('tier2_sources', []):
        if src_pat in source:
            return 2

    # Tier 0: trivial
    if effort in RISK_PATTERNS.get('tier0_effort', ['S']):
        if files:
            all_trivial = all(
                any(pat.lower() in f.lower() for pat in RISK_PATTERNS.get('tier0_files', []))
                for f in files
            )
            if all_trivial:
                return 0
        elif not files:
            # No files known yet — S-effort defaults to tier 0 if source looks trivial
            for pat in RISK_PATTERNS.get('tier0_files', []):
                if pat.lower() in source.lower():
                    return 0

    # Default: Tier 1
    return 1


def policy_check(db, task_id, patch_id=None):
    """Run policy check: returns (decision, reason)."""
    tier = classify_risk(db, task_id)

    # Store computed tier
    db.execute("UPDATE task_view SET risk_tier=? WHERE task_id=?", (tier, task_id))
    db.commit()

    if tier == 0:
        decision, reason = 'promote', 'tier-0 auto-promote'
    elif tier == 1:
        decision, reason = 'promote', 'tier-1 auto-promote after verification'
    elif tier == 2:
        decision, reason = 'defer', 'tier-2 requires independent judge review'
    else:
        decision, reason = 'decompose', 'tier-3 restricted — decompose into smaller tasks'

    print(json.dumps({'decision': decision, 'reason': reason, 'risk_tier': tier}))
    return decision, reason


# ---------------------------------------------------------------------------
# Deferred Queue Management
# ---------------------------------------------------------------------------

def get_deferred_queue(db, fmt='json'):
    """Get all deferred tasks."""
    rows = db.execute(
        "SELECT task_id, title, source, effort, wave, risk_tier, deferred_reason, deferred_at "
        "FROM task_view WHERE status='deferred' ORDER BY deferred_at ASC"
    ).fetchall()

    items = [dict(r) for r in rows]

    if fmt == 'prompt':
        if not items:
            print("No deferred items.")
            return items
        lines = ["## Deferred Items for Review\n"]
        for item in items:
            lines.append(f"### {item['task_id']}: {item.get('title', 'Untitled')}")
            lines.append(f"- **Risk Tier**: {item.get('risk_tier', '?')}")
            lines.append(f"- **Reason**: {item.get('deferred_reason', 'Unknown')}")
            lines.append(f"- **Deferred At**: {item.get('deferred_at', '?')}")
            lines.append(f"- **Source**: {item.get('source', '-')}")
            lines.append("")
        print('\n'.join(lines))
    else:
        print(json.dumps(items, indent=2))

    return items


def should_review_deferred(db):
    """Check if deferred queue needs review."""
    count = db.execute("SELECT COUNT(*) FROM task_view WHERE status='deferred'").fetchone()[0]
    if count >= 3:
        print("true")
        return True

    # Check if any deferred item has been waiting for a long time (≥30 events since deferral)
    deferred = db.execute(
        "SELECT task_id, deferred_at FROM task_view WHERE status='deferred' AND deferred_at IS NOT NULL"
    ).fetchall()
    for row in deferred:
        events_since = db.execute(
            "SELECT COUNT(*) FROM events WHERE ts > ?", (row['deferred_at'],)
        ).fetchone()[0]
        if events_since >= 30:
            print("true")
            return True

    print("false")
    return False


def resolve_deferred(db, task_id, decision, actor, rationale):
    """Resolve a deferred item: approve, reject, or modify."""
    row = db.execute("SELECT * FROM task_view WHERE task_id=?", (task_id,)).fetchone()
    if not row:
        print(f"ERROR: Task {task_id} not found", file=sys.stderr)
        return False

    payload = {'decision': decision, 'rationale': rationale}
    emit_event(db, 'task', task_id, 'task.deferral_resolved', actor, payload)

    if decision == 'approve':
        # Check if patch has a commit (already applied)
        patch = db.execute(
            "SELECT * FROM patch_view WHERE task_id=? AND status IN ('queued','applied','verified') "
            "ORDER BY created_at DESC LIMIT 1",
            (task_id,)
        ).fetchone()
        if patch and patch['commit_hash']:
            transition_task(db, task_id, 'done', actor, patch_id=patch['patch_id'])
        else:
            transition_task(db, task_id, 'done', actor)
        print(f"APPROVED {task_id}")
    elif decision == 'reject':
        transition_task(db, task_id, 'pending', actor)
        print(f"REJECTED {task_id} → pending")
    elif decision == 'modify':
        transition_task(db, task_id, 'pending', actor, deferred_reason=f"MODIFY: {rationale}")
        print(f"MODIFY {task_id} → pending with instructions")
    else:
        print(f"ERROR: Unknown decision '{decision}'", file=sys.stderr)
        return False

    return True


def expire_stale_deferrals(db):
    """Auto-expire deferred items that have been waiting too long."""
    deferred = db.execute(
        "SELECT task_id, deferred_at, risk_tier FROM task_view "
        "WHERE status='deferred' AND deferred_at IS NOT NULL"
    ).fetchall()

    expired_count = 0
    threshold = DEFERRAL_EXPIRY_COMMITS * 3  # ~60 events

    for row in deferred:
        events_since = db.execute(
            "SELECT COUNT(*) FROM events WHERE ts > ?", (row['deferred_at'],)
        ).fetchone()[0]

        if events_since >= threshold:
            new_tier = max(0, (row['risk_tier'] or 1) - 1)
            emit_event(db, 'task', row['task_id'], 'task.deferral_expired', 'control_plane', {
                'events_since_deferral': events_since,
                'old_tier': row['risk_tier'],
                'new_tier': new_tier
            })
            transition_task(db, row['task_id'], 'pending', 'control_plane', risk_tier=new_tier)
            expired_count += 1

    if expired_count > 0:
        print(f"Expired {expired_count} stale deferrals")
    return expired_count


# ---------------------------------------------------------------------------
# Proposal Processing
# ---------------------------------------------------------------------------

def process_proposals(db):
    """Process proposal files from .ralph/proposals/."""
    os.makedirs(PROPOSALS_DIR, exist_ok=True)
    processed_dir = os.path.join(PROPOSALS_DIR, 'processed')
    os.makedirs(processed_dir, exist_ok=True)

    accepted = 0
    rejected = 0
    deferred_count = 0

    # Check backlog size limits
    total_tasks = db.execute("SELECT COUNT(*) FROM task_view WHERE status != 'dropped'").fetchone()[0]

    proposal_files = sorted(Path(PROPOSALS_DIR).glob('prop_*.json'))

    for pf in proposal_files:
        try:
            with open(pf) as f:
                proposal = json.load(f)
        except (json.JSONDecodeError, IOError) as e:
            print(f"SKIP {pf.name}: {e}", file=sys.stderr)
            continue

        ptype = proposal.get('proposal_type', '')
        confidence = proposal.get('confidence', 0.0)

        if ptype == 'new_task':
            if total_tasks >= MAX_BACKLOG_SIZE:
                _defer_proposal(pf, proposal, 'backlog at max capacity')
                deferred_count += 1
                continue

            task = proposal.get('task', {})
            wave = task.get('wave', 0)
            wave_pending = db.execute(
                "SELECT COUNT(*) FROM task_view WHERE wave=? AND status='pending'", (wave,)
            ).fetchone()[0]
            if wave_pending >= MAX_PENDING_PER_WAVE:
                _defer_proposal(pf, proposal, f'wave {wave} at max pending')
                deferred_count += 1
                continue

            effort = task.get('effort', 'M')
            deps = task.get('deps', '-')
            has_deps = deps and deps != '-'

            # Auto-accept policy
            auto = False
            if confidence >= 0.7 and effort == 'S' and not has_deps:
                auto = True
            elif confidence >= 0.8 and effort in ('S', 'M'):
                auto = True

            if auto:
                _accept_new_task(db, proposal, 'control_plane')
                accepted += 1
                total_tasks += 1
            else:
                _defer_proposal(pf, proposal, 'below auto-accept threshold')
                deferred_count += 1

        elif ptype == 'decompose':
            sub_tasks = proposal.get('sub_tasks', [])
            all_small = all(t.get('effort', 'M') == 'S' for t in sub_tasks)
            if all_small and confidence >= 0.7:
                for st in sub_tasks:
                    sub_proposal = {'proposal_type': 'new_task', 'task': st, 'confidence': confidence}
                    _accept_new_task(db, sub_proposal, 'control_plane')
                    accepted += 1
                # Mark parent as superseded
                parent = proposal.get('parent_task', '')
                if parent:
                    transition_task(db, parent, 'dropped', 'control_plane',
                                    deferred_reason='decomposed into sub-tasks')
            else:
                _defer_proposal(pf, proposal, 'decompose requires review')
                deferred_count += 1

        elif ptype == 'drop_task':
            _defer_proposal(pf, proposal, 'drop always requires judge confirmation')
            deferred_count += 1

        elif ptype == 'reprioritize':
            wave_delta = abs(proposal.get('new_wave', 0) - proposal.get('old_wave', 0))
            if wave_delta <= 1:
                tid = proposal.get('task_id', '')
                new_wave = proposal.get('new_wave', 0)
                db.execute("UPDATE task_view SET wave=? WHERE task_id=?", (new_wave, tid))
                db.commit()
                accepted += 1
            else:
                _defer_proposal(pf, proposal, 'large wave delta requires review')
                deferred_count += 1
        else:
            _defer_proposal(pf, proposal, f'unknown proposal type: {ptype}')
            deferred_count += 1

        # Move processed file
        dest = os.path.join(processed_dir, pf.name)
        shutil.move(str(pf), dest)

    print(json.dumps({'accepted': accepted, 'rejected': rejected, 'deferred': deferred_count}))
    return accepted, rejected, deferred_count


def _accept_new_task(db, proposal, actor):
    """Accept a new_task proposal: insert into task_view and emit event."""
    task = proposal.get('task', {})
    task_id = task.get('id', f"AUTO-{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')}")

    emit_event(db, 'task', task_id, 'task.created', actor, {
        'provenance': 'auto',
        'confidence': proposal.get('confidence', 0),
        'rationale': proposal.get('rationale', '')
    })

    db.execute(
        "INSERT OR IGNORE INTO task_view (task_id, status, title, source, effort, deps, wave, provenance) "
        "VALUES (?, 'pending', ?, ?, ?, ?, ?, 'auto')",
        (task_id, task.get('title', ''), task.get('source', ''),
         task.get('effort', 'S'), task.get('deps', '-'), task.get('wave', 0))
    )
    db.commit()


def _defer_proposal(pf, proposal, reason):
    """Annotate a proposal as deferred (in-place)."""
    proposal['_deferred'] = True
    proposal['_deferred_reason'] = reason
    proposal['_deferred_at'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    try:
        with open(pf, 'w') as f:
            json.dump(proposal, f, indent=2)
    except IOError:
        pass


# ---------------------------------------------------------------------------
# View Rendering
# ---------------------------------------------------------------------------

def _read_state():
    """Read STATE.json, returning empty dict on failure."""
    if os.path.exists(STATE_PATH):
        try:
            with open(STATE_PATH) as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            pass
    return {}


def render_state(db):
    """Regenerate STATE.json from SQLite + agent-written fields."""
    state = _read_state()

    # SQLite-owned count fields
    done_count = db.execute("SELECT COUNT(*) FROM task_view WHERE status='done'").fetchone()[0]
    blocked_count = db.execute("SELECT COUNT(*) FROM task_view WHERE status='blocked'").fetchone()[0]
    deferred_count = db.execute("SELECT COUNT(*) FROM task_view WHERE status='deferred'").fetchone()[0]
    pending_count = db.execute("SELECT COUNT(*) FROM task_view WHERE status='pending'").fetchone()[0]
    total_count = db.execute("SELECT COUNT(*) FROM task_view").fetchone()[0]

    state['items_done_count'] = done_count
    state['items_blocked_count'] = blocked_count
    state['items_deferred_count'] = deferred_count
    state['items_pending_count'] = pending_count
    state['items_total_count'] = total_count

    # Ensure defaults for agent-written fields
    state.setdefault('iteration', 0)
    state.setdefault('phase', 'assess')
    state.setdefault('current_item', None)
    state.setdefault('current_plan', None)
    state.setdefault('current_sub_step', 0)
    state.setdefault('current_wave', 0)
    state.setdefault('retry_count', 0)
    state.setdefault('commits_total', 0)
    state.setdefault('compile_status', 'unknown')
    state.setdefault('test_status', 'unknown')
    state.setdefault('progress_history', [])
    state.setdefault('last_evolve_at', 0)
    state.setdefault('last_dry_at', 0)
    state.setdefault('last_integ_at', 0)
    state.setdefault('last_ui_at', 0)

    with open(STATE_PATH, 'w') as f:
        json.dump(state, f, indent=2)

    return state


def render_backlog(db):
    """Regenerate BACKLOG.md from task_view."""
    rows = db.execute(
        "SELECT * FROM task_view ORDER BY wave, task_id"
    ).fetchall()

    waves = {}
    for row in rows:
        w = row['wave'] or 0
        waves.setdefault(w, []).append(row)

    lines = ["# BACKLOG\n"]

    for wave_num in sorted(waves.keys()):
        title = WAVE_TITLES.get(wave_num, f"Wave {wave_num}")
        lines.append(f"\n## {title}\n")
        lines.append("| ID | Status | Title | Source | Effort | Deps |")
        lines.append("|----|--------|-------|--------|--------|------|")

        for row in waves[wave_num]:
            tid = row['task_id'] or ''
            status = row['status'] or 'pending'
            title = row['title'] or ''
            source = row['source'] or '-'
            effort = row['effort'] or 'S'
            deps = row['deps'] or '-'
            lines.append(f"| {tid} | {status} | {title} | {source} | {effort} | {deps} |")

    lines.append("")  # trailing newline

    with open(BACKLOG_PATH, 'w') as f:
        f.write('\n'.join(lines))

    print(f"Rendered BACKLOG.md ({len(rows)} items)")
    return len(rows)


# ---------------------------------------------------------------------------
# Migration (v2 → v3)
# ---------------------------------------------------------------------------

def init_from_backlog(db):
    """One-time migration: parse BACKLOG.md and load into SQLite."""
    if not os.path.exists(BACKLOG_PATH):
        print("No BACKLOG.md found — creating skeleton")
        _create_skeleton_backlog()

    with open(BACKLOG_PATH) as f:
        content = f.read()

    current_wave = 0
    migrated = 0
    status_map = {
        'in_progress': 'pending',
        'implemented': 'pending',
        'tested': 'pending',
        'planned': 'pending',
        'pending': 'pending',
        'done': 'done',
        'blocked': 'blocked',
        'deferred': 'deferred',
        'dropped': 'dropped',
        'claimed': 'claimed',
        'proposed': 'proposed',
    }

    for line in content.splitlines():
        # Detect wave headers
        wave_match = re.match(r'^##\s+Wave\s+(\d+)', line)
        if wave_match:
            current_wave = int(wave_match.group(1))
            continue

        # Parse item lines: | ID | Status | Title | Source | Effort | Deps |
        if '|' not in line:
            continue
        parts = [p.strip() for p in line.split('|')]
        if len(parts) < 7:
            continue
        # parts[0] is empty (before first |), parts[1]=ID, parts[2]=Status, etc.
        tid = parts[1]
        if not tid or tid == 'ID' or tid.startswith('-'):
            continue

        raw_status = parts[2].lower().strip()
        status = status_map.get(raw_status, 'pending')
        title = parts[3] if len(parts) > 3 else ''
        source = parts[4] if len(parts) > 4 else '-'
        effort = parts[5] if len(parts) > 5 else 'S'
        deps = parts[6] if len(parts) > 6 else '-'

        # Check if already exists
        existing = db.execute("SELECT task_id FROM task_view WHERE task_id=?", (tid,)).fetchone()
        if existing:
            continue

        emit_event(db, 'task', tid, 'task.migrated', 'control_plane', {
            'source': 'backlog_migration', 'original_status': raw_status
        })

        db.execute(
            "INSERT INTO task_view (task_id, status, title, source, effort, deps, wave, provenance) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, 'spec')",
            (tid, status, title, source, effort, deps, current_wave)
        )
        migrated += 1

    db.commit()

    # Regenerate derived views
    render_state(db)
    render_backlog(db)

    print(f"Migrated {migrated} items from BACKLOG.md into SQLite")
    return migrated


def _create_skeleton_backlog():
    """Create a skeleton BACKLOG.md with 3 empty waves."""
    content = """# BACKLOG

## Wave 0: Critical Fixes & Foundation

| ID | Status | Title | Source | Effort | Deps |
|----|--------|-------|--------|--------|------|

## Wave 1: Core Infrastructure

| ID | Status | Title | Source | Effort | Deps |
|----|--------|-------|--------|--------|------|

## Wave 2: Core Features

| ID | Status | Title | Source | Effort | Deps |
|----|--------|-------|--------|--------|------|
"""
    with open(BACKLOG_PATH, 'w') as f:
        f.write(content)


# ---------------------------------------------------------------------------
# Status Summary
# ---------------------------------------------------------------------------

def status_summary(db):
    """Print a summary of the current state."""
    counts = db.execute(
        "SELECT status, COUNT(*) as cnt FROM task_view GROUP BY status ORDER BY status"
    ).fetchall()

    total = sum(r['cnt'] for r in counts)
    status_line = ', '.join(f"{r['status']}={r['cnt']}" for r in counts)

    patches = db.execute(
        "SELECT status, COUNT(*) as cnt FROM patch_view GROUP BY status"
    ).fetchall()
    patch_line = ', '.join(f"{r['status']}={r['cnt']}" for r in patches) if patches else 'none'

    events_total = db.execute("SELECT COUNT(*) FROM events").fetchone()[0]
    events_1h = db.execute(
        "SELECT COUNT(*) FROM events WHERE ts > datetime('now', '-1 hour')"
    ).fetchone()[0]

    deferred_count = db.execute("SELECT COUNT(*) FROM task_view WHERE status='deferred'").fetchone()[0]

    state = _read_state()

    print(f"=== Ralph Loop v3 Status ===")
    print(f"Phase: {state.get('phase', '?')} | Iteration: {state.get('iteration', 0)} | "
          f"Commits: {state.get('commits_total', 0)}")
    print(f"Current: {state.get('current_item', 'none')} | Wave: {state.get('current_wave', 0)}")
    print(f"Tasks ({total}): {status_line}")
    print(f"Patches: {patch_line}")
    print(f"Events: {events_total} total, {events_1h} last hour")
    print(f"Deferred: {deferred_count} | Review needed: ", end='')

    if deferred_count >= 3:
        print("YES (≥3 items)")
    else:
        print("no")


# ---------------------------------------------------------------------------
# Sync: BACKLOG.md done → SQLite
# ---------------------------------------------------------------------------

def sync_backlog_completions(db):
    """Sync items marked done in BACKLOG.md back to SQLite."""
    if not os.path.exists(BACKLOG_PATH):
        return 0

    synced = 0
    with open(BACKLOG_PATH) as f:
        for line in f:
            if '| done |' not in line:
                continue
            parts = [p.strip() for p in line.split('|')]
            if len(parts) < 3 or not parts[1].startswith('W'):
                continue
            task_id = parts[1]
            row = db.execute(
                "SELECT status FROM task_view WHERE task_id=?", (task_id,)
            ).fetchone()
            if row and row['status'] != 'done':
                emit_event(db, 'task', task_id, 'task.completed', 'primary', {
                    'source': 'backlog_sync'
                })
                db.execute(
                    "UPDATE task_view SET status='done', version=version+1 WHERE task_id=?",
                    (task_id,)
                )
                db.commit()
                synced += 1

    if synced > 0:
        render_state(db)
        render_backlog(db)
        print(f"Synced {synced} completions from BACKLOG.md")

    return synced


# ---------------------------------------------------------------------------
# CLI Dispatcher
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 2:
        print("Usage: ralphctl.py <command> [args...]", file=sys.stderr)
        print("Commands: init, emit-event, transition-task, pick-ready-task, "
              "queue-patch, promote-patch, discard-patch, classify-risk, policy-check, "
              "get-deferred-queue, should-review-deferred, resolve-deferred, "
              "expire-stale-deferrals, process-proposals, render-state, render-backlog, "
              "status, sync-backlog", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]
    db = get_db()

    try:
        if cmd == 'init':
            init_from_backlog(db)

        elif cmd == 'emit-event':
            # emit-event <entity_type> <entity_id> <event_type> <actor> [payload_json]
            if len(sys.argv) < 6:
                print("Usage: emit-event <entity_type> <entity_id> <event_type> <actor> [payload]",
                      file=sys.stderr)
                sys.exit(1)
            payload = json.loads(sys.argv[6]) if len(sys.argv) > 6 else {}
            eid = emit_event(db, sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], payload)
            print(eid)

        elif cmd == 'transition-task':
            # transition-task <task_id> <status> <actor> [payload_json]
            if len(sys.argv) < 5:
                print("Usage: transition-task <task_id> <status> <actor> [payload]",
                      file=sys.stderr)
                sys.exit(1)
            extra = json.loads(sys.argv[5]) if len(sys.argv) > 5 else {}
            transition_task(db, sys.argv[2], sys.argv[3], sys.argv[4], **extra)

        elif cmd == 'pick-ready-task':
            # pick-ready-task <worker|primary> [--exclude <id>]
            if len(sys.argv) < 3:
                print("Usage: pick-ready-task <worker|primary> [--exclude <id>]",
                      file=sys.stderr)
                sys.exit(1)
            executor = sys.argv[2]
            exclude = None
            if '--exclude' in sys.argv:
                idx = sys.argv.index('--exclude')
                if idx + 1 < len(sys.argv):
                    exclude = sys.argv[idx + 1]
            pick_ready_task(db, executor, exclude)

        elif cmd == 'queue-patch':
            # queue-patch <task_id> <patch_path> <created_by>
            if len(sys.argv) < 5:
                print("Usage: queue-patch <task_id> <patch_path> <created_by>", file=sys.stderr)
                sys.exit(1)
            queue_patch(db, sys.argv[2], sys.argv[3], sys.argv[4])

        elif cmd == 'promote-patch':
            # promote-patch <patch_id> <commit_hash>
            if len(sys.argv) < 4:
                print("Usage: promote-patch <patch_id> <commit_hash>", file=sys.stderr)
                sys.exit(1)
            promote_patch(db, sys.argv[2], sys.argv[3])

        elif cmd == 'discard-patch':
            # discard-patch <patch_id> <reason>
            if len(sys.argv) < 4:
                print("Usage: discard-patch <patch_id> <reason>", file=sys.stderr)
                sys.exit(1)
            discard_patch(db, sys.argv[2], sys.argv[3])

        elif cmd == 'classify-risk':
            # classify-risk <task_id>
            if len(sys.argv) < 3:
                print("Usage: classify-risk <task_id>", file=sys.stderr)
                sys.exit(1)
            tier = classify_risk(db, sys.argv[2])
            print(tier)

        elif cmd == 'policy-check':
            # policy-check <task_id> [patch_id]
            if len(sys.argv) < 3:
                print("Usage: policy-check <task_id> [patch_id]", file=sys.stderr)
                sys.exit(1)
            patch_id = sys.argv[3] if len(sys.argv) > 3 else None
            policy_check(db, sys.argv[2], patch_id)

        elif cmd == 'get-deferred-queue':
            fmt = 'json'
            if '--format' in sys.argv:
                idx = sys.argv.index('--format')
                if idx + 1 < len(sys.argv):
                    fmt = sys.argv[idx + 1]
            get_deferred_queue(db, fmt)

        elif cmd == 'should-review-deferred':
            should_review_deferred(db)

        elif cmd == 'resolve-deferred':
            # resolve-deferred <task_id> <approve|reject|modify> <actor> <rationale>
            if len(sys.argv) < 6:
                print("Usage: resolve-deferred <task_id> <decision> <actor> <rationale>",
                      file=sys.stderr)
                sys.exit(1)
            resolve_deferred(db, sys.argv[2], sys.argv[3], sys.argv[4],
                             ' '.join(sys.argv[5:]))

        elif cmd == 'expire-stale-deferrals':
            expire_stale_deferrals(db)

        elif cmd == 'process-proposals':
            process_proposals(db)

        elif cmd == 'render-state':
            render_state(db)
            print("STATE.json regenerated")

        elif cmd == 'render-backlog':
            render_backlog(db)

        elif cmd == 'status':
            status_summary(db)

        elif cmd == 'sync-backlog':
            sync_backlog_completions(db)

        else:
            print(f"Unknown command: {cmd}", file=sys.stderr)
            sys.exit(1)

    finally:
        db.close()


if __name__ == '__main__':
    main()
