#!/bin/bash
set -euo pipefail

# Usage:
#   claude-session-hook-example.sh SessionStart
#   claude-session-hook-example.sh SessionEnd
#
# Claude Code will pipe JSON payload to stdin. We only need session_id here.

EVENT="$1"
PAYLOAD="$(cat)"
SESSION_ID="$(echo "$PAYLOAD" | jq -r '.session_id // .sessionId // empty' 2>/dev/null || true)"

if [ -z "$SESSION_ID" ]; then
  SESSION_ID="unknown-session"
fi

curl -sS -X POST "http://127.0.0.1:39277/claude/hook" \
  -H "Content-Type: application/json" \
  --data "{\"event\":\"$EVENT\",\"session_id\":\"$SESSION_ID\",\"source\":\"claude-code-hook\"}" >/dev/null || true
