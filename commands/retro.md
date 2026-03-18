---
description: Reflect on the current research session and collect improvement suggestions
argument-hint: "[optional feedback, e.g. 'the report lacked detail on failed experiments']"
---

You are reflecting on the current research session to identify improvements for the agent's base instructions. This is a retrospective -- not about what went wrong, but about what can be made better for future research sessions.

User feedback (may be empty): $ARGUMENTS

## Step 1: Gather Context

Detect which instruction file exists in the workspace:
- Check for: `CLAUDE.md`, `GEMINI.md`, `AGENTS.md` (in that order)
- Use the first one found as `$INSTRUCTION_FILE`

Read the following files (skip any that don't exist):

1. `/workspace/REVISION.md` -- previous retrospective entries (if any)
2. `/workspace/report.tex` -- experiment log, results, analysis quality
3. `/workspace/TODO.md` -- open items, deferred work
4. `/workspace/$INSTRUCTION_FILE` -- the instructions governing this session (especially Section 8: Project Instructions)
5. Run `git log --oneline -30` -- see the commit history (style, frequency, quality)
6. Run `git diff --stat HEAD~5..HEAD 2>/dev/null || true` -- recent change patterns

**Backward compatibility:** If `/workspace/research_instructions.md` exists (older format), read it as supplementary context for the original research goal.

## Step 2: Commandment Compliance

Review compliance with each of the 10 Commandments (Section 1 of the instruction file). For each, assess: **followed**, **partially followed**, or **violated**, with evidence.

| # | Commandment | Status | Evidence |
|---|-------------|--------|----------|
| I | Never break a promise | ? | Did the agent follow through on stated intentions? |
| II | Never manipulate evaluation | ? | Were metrics/test sets/constraints kept unchanged? |
| III | Never fabricate citations | ? | Were bibliography entries verified? |
| IV | Complete all autonomous work | ? | Were tasks left incomplete? Did the agent wait unnecessarily? |
| V | Make it work before moving on | ? | Were methods discarded due to implementation bugs? |
| VI | One variable per experiment | ? | Were experiments properly isolated? |
| VII | Evaluate in tiers | ? | Was the three-tier strategy followed? |
| VIII | Bound your expectations | ? | Were theoretical bounds established before heuristics? |
| IX | Record everything | ? | Are results tables present? Are failures documented? |
| X | Verify before claiming | ? | Were verification scripts created for non-trivial math? |

Also check module compliance if applicable: C1/C2 for compute and M1/M2 for math.

This table goes into the REVISION.md entry.

## Step 3: Analyze the Session

Reflect on these additional dimensions:

### A. Workflow & Process
- Did the experiment loop work well? Were there unnecessary steps or missing steps?
- Was iteration speed good, or did the agent waste time on unproductive paths?

### B. Report Quality (report.tex)
- Is the report clear, well-structured, and useful as a persistent record?
- Are experiment entries detailed enough to reproduce results?
- Are analyses insightful or superficial?
- Are results tables properly formatted with clear columns?

### C. Git Discipline
- Are commit messages descriptive and following the prescribed format?
- Is branching used effectively?
- Are commits atomic (one idea per commit)?

### D. Error Handling & Recovery
- Did the agent handle failures well (OOM, NaN, divergence)?
- Were failed experiments documented properly?
- Did the agent recover autonomously or get stuck?

### E. Communication & Autonomy
- Did the agent ask for help at the right times (not too often, not too rarely)?
- Were results reported honestly, including negative results?

### F. Resource Management
- Was GPU/compute used efficiently? (Relates to module C1)
- Were long runs estimated and confirmed before starting?

### G. User-Specific Feedback
- Address the user's $ARGUMENTS feedback directly. This is the most important input.
- If the user pointed out something specific, propose a concrete instruction file change for it.

## Step 4: Write to REVISION.md

Update `/workspace/REVISION.md` following these rules:

### If REVISION.md does NOT exist:
Create it with this structure:

```markdown
# Instruction File Revision Notes

Collected observations and improvement suggestions from research sessions.
Each retrospective adds entries; later entries may refine or supersede earlier ones.

---

## Revision 1 -- [DATE]

**Session context:** [Brief description of the research task and current state]

**User feedback:** [What the user said, or "None provided"]

### Commandment Compliance

| # | Commandment | Status | Evidence |
|---|-------------|--------|----------|
| I | Never break a promise | followed/partial/violated | [evidence] |
| ... | ... | ... | ... |

### Proposed Changes

#### [Section of instruction file, e.g. "Section 3: Experiment recording"]
- **Issue:** [What was suboptimal]
- **Suggestion:** [Concrete change to instruction file wording/rules]
- **Rationale:** [Why this would help]

### Things That Worked Well
- [Keep these -- don't fix what isn't broken]

### Open Questions
- [Things that need more sessions to evaluate]
```

### If REVISION.md ALREADY exists:
1. Read the existing content carefully
2. Add a new `## Revision N` section (increment the number) at the END of the file
3. Reference previous revisions where relevant ("Revision 1 suggested X; after further experience, Y is better")
4. If a previous suggestion turned out to be wrong or insufficient, note that explicitly
5. Do NOT delete or modify previous revision entries -- they form a history
6. If the same issue appears again, escalate its priority and refine the suggestion

## Step 5: Summarize to the User

After writing REVISION.md, give the user a concise summary:
1. Commandment compliance overview (how many followed/partial/violated)
2. The top 3 most impactful proposed changes
3. Any patterns across multiple retrospectives (if applicable)
4. Ask if they want to elaborate on any point or add more feedback

## Guidelines

- Be **specific and actionable**. Don't say "improve error handling docs". Say "Add an example to Troubleshooting for 'CUDA version mismatch' with fix 'check `nvidia-smi` vs `torch.cuda.get_device_capability()`'".
- Propose **exact wording** for instruction file changes when possible. Quote the current text and show the proposed replacement.
- Be **honest**. If the agent followed instructions perfectly and things still went wrong, the instructions need changing, not the agent.
- Be **conservative**. Don't propose removing rules that exist for good reason (Commandments, verification). Instead, propose clarifications or additions.
- Focus on **high-leverage changes** -- small wording tweaks that would have prevented significant issues or substantially improved output quality.
- Note when something is a **one-off** vs a **pattern**. One-off issues might not warrant an instruction change; recurring patterns definitely do.
