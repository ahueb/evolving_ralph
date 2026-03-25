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
