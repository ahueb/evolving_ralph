# Phase: IMPLEMENT

Execute one sub-step from the plan in STATE.json.

1. Read `current_plan.sub_steps[current_sub_step - 1]`
2. Write code: Edit existing files (preferred) or Write new files
3. IMMEDIATE verification: `python -m py_compile 2>&1 | tail -50`
   - If FAIL: fix the error, re-check. Max 3 attempts.
   - After 3 fails: set `phase`="reflect"
4. If build passes: run unit test: `pytest -x --tb=short 2>&1 | tail -30`
5. If all sub-steps done: set `phase`="verify"
6. If more sub-steps: increment `current_sub_step`, keep `phase`="implement"
