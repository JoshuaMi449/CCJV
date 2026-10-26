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

## Download

Prebuilt macOS releases are available on the [Releases page](https://github.com/JoshuaMi449/CCJV/releases).

1. Download the latest `CCJV-*-macOS.zip` and unzip it.
2. Move `CCJV.app` into Applications.
3. The app is not notarized: right-click the app and choose **Open**. If macOS still blocks it, allow it under **System Settings → Privacy & Security → Open Anyway**.

Upgrading from the earlier `Claude Recall` build moves `~/Library/Application Support/Claude Recall/` to `~/Library/Application Support/CCJV/` automatically.

## Requirements

- macOS 14 or later
- Swift 5.9+ / Xcode Command Line Tools (only for building from source)

## Build and run

```sh
git clone https://github.com/JoshuaMi449/CCJV.git
cd CCJV
./build-app.sh release
open "dist/CCJV.app"
```

Run the standalone regression tests with:

```sh
tools/run-p0-tests.sh
```

## Data and privacy

- Session files are opened read-only. CCJV never renames, moves, or deletes `~/.claude/projects` files.
- No network calls and no telemetry.
- CCJV's optional local archive and workspace settings live under `~/Library/Application Support/CCJV/`.
- This repository contains source code only — no session data, archive data, or credentials.

## License

[MIT](LICENSE)
