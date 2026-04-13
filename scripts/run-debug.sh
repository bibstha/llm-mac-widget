#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BIN="$ROOT/.build/debug/LlmTokenWidget"

case "${1:-lldb}" in
  -h|--help|help)
    cat <<'EOF'
LlmTokenWidget debug launcher

  ./scripts/run-debug.sh          Build, then lldb (in lldb: run — on crash: bt all)
  ./scripts/run-debug.sh logs     Stream unified logs (second terminal while app runs)
  ./scripts/run-debug.sh asan      Build with Address Sanitizer + lldb (slow)

Crash reports: ~/Library/Logs/DiagnosticReports/LlmTokenWidget-*.ips
EOF
    exit 0
    ;;
  logs)
    echo "Streaming logs for LlmTokenWidget (Ctrl+C to stop)…"
    exec log stream --style compact \
      --predicate 'process == "LlmTokenWidget" OR senderImagePath CONTAINS "LlmTokenWidget"' \
      --level debug
    ;;
  asan)
    echo "Building with Address Sanitizer (much slower)…"
    swift build -Xswiftc -sanitize=address -Xlinker -sanitize=address
    export MallocStackLogging=1
    export MallocStackLoggingNoCompact=1
    echo "Starting lldb — type: run"
    exec lldb "$BIN"
    ;;
  *)
    echo "Building debug…"
    swift build
    export MallocStackLogging=1
    export MallocStackLoggingNoCompact=1
    echo ""
    echo "Starting lldb with: $BIN"
    echo "  (lldb) run"
    echo "  (lldb) bt all     # after a crash or break"
    echo "Parallel terminal:  ./scripts/run-debug.sh logs"
    echo ""
    exec lldb "$BIN"
    ;;
esac
