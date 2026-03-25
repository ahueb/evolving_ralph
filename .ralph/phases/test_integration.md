# Phase: TEST_INTEGRATION

Full test suite. Runs every 10 commits.

1. `pytest 2>&1 | tail -100` — fix any failures
2. Run integration tests if configured
3. Update STATE.json: `last_integ_at` = commits_total
4. If failures: `phase`="reflect"
5. If all pass: `phase`="assess"
