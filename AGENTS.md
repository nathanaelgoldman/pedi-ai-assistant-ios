//
//  AGENTS.md
//  
//
//  Created by Nathanael on 1/31/26.
//
# Agent Instructions for this repo (Codex)

## Working style (non-negotiable)
- ONE small change at a time.
- Prefer inspection + explanation BEFORE code.
- Never refactor unrelated files.
- If uncertain, ask for evidence by locating the exact code, schema, or log line.

## When proposing code
- Always include:
  - file path
  - where to insert (show a few lines above/below)
  - what it changes and why
- Mention any knock-on effects (other files that will need changes next).

## Safety checks
- Before edits: identify current behavior by pointing to source lines.
- After edits: suggest the smallest verification step (build/run/test).

## Context
- Read CODEX_CONTEXT.md first.
- Use repo reality as source of truth (don’t assume).
