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
