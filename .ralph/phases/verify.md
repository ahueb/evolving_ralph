# Phase: VERIFY

Machine-verifiable quality gates. Run ALL:

1. `python -m py_compile` -> must pass
2. `pytest -x --tb=short` -> must pass for changed modules
3. Grep changed files for forbidden patterns (from core.md)
4. ALL pass -> set `phase`="commit"
5. ANY fail -> set `phase`="reflect", increment `retry_count`
