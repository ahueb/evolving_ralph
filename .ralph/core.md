# Coding Standards — test-project (python)

## Build & Test Commands
- Build: `python -m py_compile`
- Test (full): `pytest`
- Test (unit): `pytest -x --tb=short`
- Lint: `ruff check`
- Format: `ruff format --check`

## Forbidden Patterns
bare except:|eval(|import \*

## Rules
1. NEVER skip build verification after code changes.
2. NEVER commit code that fails the build command.
3. NEVER introduce forbidden patterns.
4. Prefer editing existing files over creating new ones.
5. Keep changes minimal and focused on the current task.
6. Run the lint command before committing.
