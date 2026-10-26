# CCJV (Claude Code JSON View)

A local, read-only macOS reader for Claude Code `.jsonl` sessions.

CCJV turns raw Claude Code transcripts into a readable conversation view: your questions, the final answers, and collapsed process details in between. Everything stays on your Mac — the app does not upload session data.

## Features

- Reads sessions from `~/.claude/projects/**/*.jsonl` without modifying them.
- Question → folded process → final answer layout.
- Subagent branches and tool activity stay collapsed until expanded.
- Full-text search across questions and final answers, grouped by session.
- Merges continuation/compact chains into one reading view while keeping each raw segment available.
- Local archive keeps Q&A content available after Claude Code's 30-day transcript cleanup.
- Session groups, display-name aliases, multi-select, and a collapsible question outline.
- Light/dark appearances and accent themes.

## Requirements

- macOS 14 or later
- Swift 5.9+ / Xcode Command Line Tools

## Build and run

```sh
git clone https://github.com/JoshuaMi449/CCJV.git
cd CCJV
./build-app.sh release
open "dist/Claude Recall.app"
```

The repository name is **CCJV**; the built app is named **Claude Recall**.

## Data and privacy

- Session files are opened read-only. CCJV never renames, moves, or deletes `~/.claude/projects` files.
- No network calls and no telemetry.
- CCJV's optional local archive and workspace settings live under `~/Library/Application Support/Claude Recall/`.
- This repository contains source code only — no session data, archive data, or credentials.
