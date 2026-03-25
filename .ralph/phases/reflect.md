# Phase: REFLECT

Diagnose the failure. Classify and persist the lesson.

1. Read the error from last verify/implement attempt
2. Classify:
   - TRANSIENT (timeout, flaky) -> retry same approach
   - LLM_RECOVERABLE (wrong approach, type error) -> re-plan
   - ENVIRONMENT (missing dep, toolchain) -> fix env, retry
   - FUNDAMENTAL (ambiguous spec, impossible) -> mark blocked
3. Append 1-2 sentence reflection to REFLECTIONS.md:
   `iteration: N | item: X | class: Y | "Failed because Z. Next time W."`
4. If FUNDAMENTAL or retry_count >= 3: mark item blocked, clear current_item, phase="assess"
5. If LLM_RECOVERABLE: phase="plan" (re-plan with reflection)
6. If TRANSIENT: phase="implement" (retry)
7. If this is a recurring pattern, add guardrail to GUARDRAILS.md
