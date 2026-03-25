# Phase: PLAN

Create a concrete plan for the current item. Steps:

1. Read the relevant spec/issue/requirement referenced in the item's Source field.
2. Read GUARDRAILS.md for relevant anti-patterns.
3. Find existing code: use Grep/Glob to locate relevant files, then Read them.
   If 3+ files need reading, launch parallel Explore agents.
4. **PRE-PLAN SCAN**: For each file in your plan, grep for forbidden patterns.
   Include fixing ALL pre-existing violations in your plan.
5. Write plan to STATE.json `current_plan`:
   {"files_modify":["a"],"files_create":["b"],"sub_steps":[{"step":1,"desc":"...","verify":"python -m py_compile"}],"acceptance":"..."}
6. For L/XL items: plan only the first sub-step batch for this iteration.
7. Set STATE.json: `phase`="implement", `current_sub_step`=1
