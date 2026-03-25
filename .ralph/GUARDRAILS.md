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
