//
//  CODEX_CONTEXT.md
//  
//
//  Created by Nathanael on 1/31/26.
//
# Codex Context — pedi-ai-assistant-ios

## What this project is
- Pediatric EMR ecosystem (DrsMainApp + PatientViewerApp)
- Portable peMR bundles (SQLite + manifest.json + docs/)
- Heavy focus on growth charts, perinatal summary, well/sick visit PDFs
- Strong requirement: step-by-step, no regressions, no speculative refactors

## Current state (as of now)
- Codex CLI installed and authenticated
- Repo builds but recent work focused on:
  - Growth chart logic
  - PDF generation consistency
  - DB path correctness inside bundles
- Past issues: Git timeouts, PATH issues (now resolved)

## How to work in this repo
- ONE small change at a time
- Always name files and paths explicitly
- Prefer inspection + explanation before code
- Avoid touching unrelated files

## Immediate goal
- Resume where we left off and identify the next *minimal* safe fix
