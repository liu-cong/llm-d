# AI Agent Skills

This directory contains skills for AI agents (such as Claude Code or Antigravity) to assist with development and maintenance of the `llm-d` repository.

## Available Skills

### 1. verify-guide

Performs end-to-end verification of `llm-d` user guides. It validates documentation integrity, repository-wide dependency consistency, and manifest correctness.

#### How to Use

Ask the agent to verify a guide using this skill. For example:
- "Verify the guide `guides/optimized-baseline/README.md`."
- "Run end-to-end verification for the `guides/optimized-baseline/README.md` guide on the cluster `my-cluster`."

For more details, see the [SKILL.md](verify-guide/SKILL.md).

> [!NOTE]
> **Skill Path Differences & Symlinking**
> - **Antigravity**: Uses `.agents/skills/` as the source of truth in this repository.
> - **Claude (e.g., Claude Code)**: Usually expects skills to be placed under `.claude/skills/`.
> 
> To accommodate both, a symlink has been created from `.claude/skills` to `.agents/skills`. This allows both tools to access the same set of skills without duplicating files.

## Adding New Skills

To add a new skill, create a new directory here with a `SKILL.md` file describing the skill and its instructions.
