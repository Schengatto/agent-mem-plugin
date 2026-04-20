# Mandatory Rules

IMPORTANT: These rules are NON-NEGOTIABLE. Every single rule MUST be followed on EVERY task. No exceptions, no shortcuts, no skipping "just this once". Violation of any rule means the task is incomplete.

## Workflow Rules (execute in order)

### 1. PRE-TASK: Consult Memory (BLOCKING)
Before writing ANY code or making ANY changes:
- Read MEMORY.md for relevant context
- Search claude-mem (`mem-search` skill or MCP tools) for past decisions, bugs, and patterns related to the task
- DO NOT proceed until this step is done

### 3. Unit Tests (BLOCKING)
- All new/changed code MUST be covered by unit tests before the task is considered complete
- If no test framework exists yet, set one up before proceeding

### 4. Test Suite (BLOCKING)
- ALL existing project unit tests MUST pass before the task is complete
- If a test fails, fix it — do not skip or disable it

### 5. Documentation (BLOCKING)
- After tests pass, update relevant docs in `docs/`
- Update MEMORY.md with new patterns, decisions, or implementation details
- Save observations to claude-mem

### 6. Memory Update (BLOCKING — NEVER SKIP)
- At the END of every task, ALWAYS update BOTH:
  - `MEMORY.md` (local auto-memory)
  - `claude-mem` (cross-session memory via MCP tools)
- This MUST happen BEFORE asking about commit/push/deploy
- This is the most frequently skipped rule — pay extra attention

### 7. End of Task
- Always ask the user if they want to commit, push, and deploy
- Never auto-commit or auto-push without explicit confirmation
