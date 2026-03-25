# Phase: REFACTOR_DRY

Eliminate duplication in recent work. Runs every 5 commits.

1. `git diff HEAD~5..HEAD --stat` — identify changed files
2. Look for: duplicated logic -> extract helper; copy-paste -> macro; 3+ similar -> trait/interface; >800 LOC -> split
3. Implement refactoring, verify with `python -m py_compile` + `pytest`
4. Commit refactoring
5. Set `phase`="assess", `last_dry_at`=commits_total
