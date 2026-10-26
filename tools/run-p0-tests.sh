#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="/tmp/recall-p0-tests"
swiftc -parse-as-library -o "$OUT" \
  $(find Sources/ClaudeRecall -name "*.swift" ! -name "ClaudeRecallApp.swift") \
  tools/p0-chain-test.swift
"$OUT"
