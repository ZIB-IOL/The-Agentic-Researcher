---
description: Set up or start a research project
argument-hint: "[description of your research goal]"
---

You are a research agent. This command sets up and executes a research project.

Detect which instruction file exists in the workspace and use it throughout:
- Check for: `CLAUDE.md`, `GEMINI.md`, `AGENTS.md` (in that order)
- Use the first one found as `$INSTRUCTION_FILE`
- If none exists, check if the template is available at `/claude-home/.claude/INSTRUCTIONS.md.template` and copy it to `CLAUDE.md`

Check the state of `/workspace/$INSTRUCTION_FILE` to determine what to do.

**Detection logic:**
- If `/workspace/$INSTRUCTION_FILE` exists AND its "## 8. Project Instructions" section contains filled-in values (not just placeholders like `[Research objective]`), treat as **RESUME**.
- If `/workspace/$INSTRUCTION_FILE` exists but Project Instructions still has placeholders, treat as **FRESH START** (skip to interactive setup below).
- If no instruction file exists, copy the template first, then treat as **FRESH START**.

**Backward compatibility:** If `/workspace/research_instructions.md` exists (from an older session), read it and migrate its contents into the Project Instructions section. Then proceed as RESUME.

## RESUME (Project Instructions filled AND report.tex exists):

This is a resuming session. The project is already in progress.

1. **Read** `/workspace/$INSTRUCTION_FILE` (especially Section 8), `report.tex`, and `TODO.md`
2. **Run** `git log --oneline -20` to see recent experiment commits
3. **Run** `git status` to check for uncommitted changes
4. **Summarize** the current state to the user:
   - Best result so far and which experiment achieved it
   - What was tried last and whether it worked
   - What's next (from TODO.md or the last experiment's "Next steps")
5. **Ask** the user if they want to continue the planned direction or pivot
6. **Continue** the autonomous experiment loop

## FRESH START (Project Instructions has placeholders, report.tex does not exist):

1. **Read** `/workspace/$INSTRUCTION_FILE` Section 8 to confirm it needs filling
2. If report.tex exists but Section 8 is empty, read report.tex to recover context, then ask user to confirm project instructions before continuing.
3. Otherwise, proceed with interactive setup below.

### Interactive Setup

Guide the user through filling in the Project Instructions section. Use `$ARGUMENTS` (the user's slash command argument) to bootstrap Round 1 -- skip questions already answered by the argument.

#### Round 1 -- Goal & Context
Ask (2-3 questions max):
- What is your **research goal**? What are you trying to improve? (skip if clear from `$ARGUMENTS`)
- What is the **primary metric**? (e.g., perplexity, accuracy, F1, BLEU -- and which direction is better?)
- What is the **current state of the codebase**? (already have training/eval code, or starting from scratch?)

Wait for the user to respond before continuing.

#### Round 2 -- Evaluation & Constraints
Ask (2-3 questions max):
- What is the **evaluation command**? (e.g., `uv run python evaluate.py --split test`)
- What is the **current baseline performance**? (if known)
- Are there **fixed constraints**? (e.g., model size, quantization bits, max training time, specific architecture that must be used)
- What is your **target improvement**? (e.g., "reduce perplexity by 10%", "beat 95% accuracy")

Wait for the user to respond before continuing.

#### Round 3 -- Approach, Scope & Model Size
Ask (2-3 questions max):
- Any **specific approaches** you want tried? (e.g., "try LoRA", "implement flash attention", "explore curriculum learning")
- Any **papers or references** to follow? (arxiv links, method names)
- What is the **minimum model size for drawing conclusions**? (e.g., ">=1.5B parameters" -- smaller models are debugging-only per Commandment VII)
- Any **files that are off-limits**? (files the agent should NOT modify)
- **Compute budget**: how many experiments / how long can this run? How many GPUs?

Wait for the user to respond before continuing.

#### Round 4 -- Generate & Confirm
1. Fill in the Project Instructions section of `/workspace/$INSTRUCTION_FILE` by replacing the placeholder content in Section 8 with the gathered information:

```markdown
## 8. Project Instructions

**Goal:** [filled from Round 1]

**Primary Metric:**
- Name: [metric name]
- Direction: [lower/higher is better]
- Eval command: `[exact command]`
- Baseline: [value or "TBD"]

**Fixed Constraints (protected by Commandment II):**
- [from Round 2]

**Minimum Decision Scale (Commandment VII):**
- [from Round 3, e.g., ">=1.5B parameters -- models below this are debugging-only"]

**Approach Guidelines:**
- [from Round 3, ordered by priority]

**References:**
- [papers/links from Round 3]

**Compute Budget:**
- [from Round 3]

**Off-Limits Files:**
- [from Round 3]

**Notes:**
- [any additional context]
```

2. **Show** the filled-in Section 8 to the user for review
3. **Ask** if they want to modify anything
4. **Save** the updated `/workspace/$INSTRUCTION_FILE`
5. **Proceed** with initial setup:
   - **Explore** the codebase structure (`ls -la /workspace/`, read key files, understand the architecture)
   - **Check GPU** with `nvidia-smi` (note GPU model and VRAM)
   - **Install dependencies** with `uv sync`
   - **Run baseline evaluation (E000)**: Execute the evaluation command from the instructions, record results
   - **Initialize tracking files**:
     - `report.tex` with full preamble (amsmath, amsthm, booktabs, graphicx, tcolorbox with verification box, theorem environments), title/date, experiment log table with E000 entry, and a baseline subsection
     - `TODO.md` with initial open questions
     - `mkdir -p scripts images` for verification/plotting scripts and figures
   - **Commit**: `exp(E000): baseline measurement -- <metric>=<value>`
   - **Begin the autonomous experiment loop** as described in the research workflow
