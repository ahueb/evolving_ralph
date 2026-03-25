# Phase: TEST_UI

Browser/E2E testing. Runs every 15 commits. Skip if no UI.

1. Check if server can start
2. Run end-to-end tests if configured
3. For NEW features: create test specs
4. Update STATE.json: `last_ui_at` = commits_total
5. Set `phase`="assess"
