# The Agentic Researcher: A Practical Guide to AI-Assisted Research in Mathematics and Machine Learning

> A sandboxed framework for autonomous AI research agents on local machines and Linux compute environments.

**Paper:** [The Agentic Researcher: A Practical Guide to AI-Assisted Research in Mathematics and Machine Learning](https://arxiv.org/abs/2603.15914)

**Authors:**
[Max Zimmer](https://maxzimmer.org)·
[Nico Pelleriti](https://pelleriti.org) ·
[Christophe Roux](http://christopheroux.de/) ·
[Sebastian Pokutta](http://www.pokutta.com/)

[IOL Lab](https://iol.zib.de) · Zuse Institute Berlin & TU Berlin

---

## What Is This?

The Agentic Researcher launches AI coding agents inside sandboxed containers with filesystem isolation, GPU support, and structured research instructions.

Supports: [Claude Code](https://claude.ai/code), [OpenCode](https://opencode.ai), [Gemini CLI](https://github.com/google/gemini-cli), [Codex CLI](https://github.com/openai/codex).

## Quick Start

Clone the repository, then run the local install script for your runtime:

```bash
# 1. Clone the repository
git clone https://github.com/ZIB-IOL/The-Agentic-Researcher.git

# 2. Enter the repository checkout
cd The-Agentic-Researcher

# 3 Install
./scripts/install.sh 

# 4a. Build container for apptainer
agentic-researcher --apptainer --build

# 4b. Build container for docker (default)
agentic-researcher --build
```

Docker is the default runtime. Apptainer is supported on Linux hosts. By default the launcher stores state under `~/.cache/agentic-researcher` and launches Claude. Claude uses OAuth by default. Other CLIs handle auth inside the tool, with standard API key env vars passed through if set.

Your project should have its dependencies ready (we recommend [uv](https://docs.astral.sh/uv/)). The agent runs `uv sync` inside the sandbox to install them.


## Usage

```bash
# Sandbox current directory (default: Claude Code)
agentic-researcher

# Sandbox a specific directory
agentic-researcher ~/my-project

# Auto-approve all tool calls
agentic-researcher --yolo

# Specify a CLI tool: gemini, codex, opencode, or claude
agentic-researcher --tool <gemini|codex|opencode|claude>
```

## Supported CLI Tools

| Tool | Instruction file | Provider | Flag |
|------|-----------------|----------|------|
| [Claude Code](https://claude.ai/code) | `CLAUDE.md` | Anthropic | `--tool claude` (default) |
| [OpenCode](https://opencode.ai) | `AGENTS.md` | Any (LiteLLM) | `--tool opencode` |
| [Gemini CLI](https://github.com/google/gemini-cli) | `GEMINI.md` | Google | `--tool gemini` |
| [Codex CLI](https://github.com/openai/codex) | `AGENTS.md` | OpenAI | `--tool codex` |

## Architecture

### Sandbox

- **Filesystem isolation** — the agent can only access `/workspace`; extra directories from `AR_EXTRA_BIND_DIRS` are mounted under `/workspace/.mount/<basename>`
- **Namespace isolation** — Apptainer `--compat` enables user/mount namespaces
- **Path traversal protection** — symlinks resolved; system directories blocked

`--yolo` auto-approves tool calls but does **not** weaken filesystem isolation.

### Research Agent Instructions

The framework ships `INSTRUCTIONS.md` as a canonical template. At launch, it is copied into the workspace under the filename required by the selected tool (`CLAUDE.md`, `GEMINI.md`, or `AGENTS.md`). These tool-specific instruction files are generated at launch rather than maintained separately in the repo. The copied file defines research workflow rules, structured experiment recording in `report.tex`, and a verification protocol.

## Citation

```bibtex
@misc{zimmer2026agenticresearcherpracticalguide,
  title         = {The Agentic Researcher: A Practical Guide to AI-Assisted Research in Mathematics and Machine Learning},
  author        = {Max Zimmer and Nico Pelleriti and Christophe Roux and Sebastian Pokutta},
  year          = {2026},
  eprint        = {2603.15914},
  archivePrefix = {arXiv},
  primaryClass  = {cs.LG},
  url           = {https://arxiv.org/abs/2603.15914}
}
```


