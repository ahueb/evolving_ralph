# Phase: ASSESS

Pick the next work item. Rules:
1. If STATE.json has `current_item` set and not done -> resume it at its last sub-phase
2. Otherwise scan the BACKLOG section below for the first `pending` item (top to bottom)
3. Skip items whose deps are not all `done` -> mark `blocked` in backlog
4. Set STATE.json: `phase`="plan", `current_item`=<chosen ID>, increment `iteration`
5. If no pending items remain in this wave, advance `current_wave` and re-scan

Do NOT read any code files. Do NOT implement anything. Just pick the item and update state.
