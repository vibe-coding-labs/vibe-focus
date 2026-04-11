#!/usr/bin/env bash
set -euo pipefail

PLAIN_LOGS=("/tmp/vibefocus.log" "/tmp/vibefocus.log.1")
STRUCTURED_LOGS=("/tmp/vibefocus-events.jsonl" "/tmp/vibefocus-events.jsonl.1")

existing_files() {
  local path
  local output=()
  for path in "$@"; do
    if [[ -f "$path" ]]; then
      output+=("$path")
    fi
  done
  echo "${output[@]}"
}

print_usage() {
  cat <<'USAGE'
Usage:
  scripts/log_trace.sh                     # Show recent warnings/errors and slow operations
  scripts/log_trace.sh <operation-id>      # Trace one operation id (e.g. toggle-00000599)
  scripts/log_trace.sh --op <operation-id> # Same as above
USAGE
}

trace_operation() {
  local op="$1"
  if [[ -z "$op" ]]; then
    print_usage
    exit 1
  fi

  echo "== Operation Trace: $op =="
  echo

  local plain_files=()
  local structured_files=()
  local path
  for path in "${PLAIN_LOGS[@]}"; do
    if [[ -f "$path" ]]; then
      plain_files+=("$path")
    fi
  done
  for path in "${STRUCTURED_LOGS[@]}"; do
    if [[ -f "$path" ]]; then
      structured_files+=("$path")
    fi
  done

  if [[ ${#plain_files[@]} -gt 0 ]]; then
    echo "-- Plain Log --"
    rg -n "$op" "${plain_files[@]}" || true
    echo
  else
    echo "-- Plain Log Missing: ${PLAIN_LOGS[*]} --"
    echo
  fi

  if [[ ${#structured_files[@]} -gt 0 ]]; then
    echo "-- Structured Log (JSONL) --"
    if command -v jq >/dev/null 2>&1; then
      local file
      for file in "${structured_files[@]}"; do
        jq -c --arg op "$op" '
          select(
            .fields.op == $op or
            .op == $op or
            (.message | tostring | contains($op))
          )
        ' "$file" || true
      done
    else
      rg -n "$op" "${structured_files[@]}" || true
    fi
    echo
  else
    echo "-- Structured Log Missing: ${STRUCTURED_LOGS[*]} --"
    echo
  fi
}

show_summary() {
  local plain_files=()
  local path
  for path in "${PLAIN_LOGS[@]}"; do
    if [[ -f "$path" ]]; then
      plain_files+=("$path")
    fi
  done

  echo "== Recent Warnings / Errors / Slow Signals =="
  echo
  if [[ ${#plain_files[@]} -gt 0 ]]; then
    rg -n "\\[WARN\\]|\\[ERROR\\]|toggle_slow|yabai command slow|frontmost app changed during toggle" "${plain_files[@]}" | tail -n 120 || true
  else
    echo "Plain log missing: ${PLAIN_LOGS[*]}"
  fi

  echo
  echo "== Recent Operation IDs =="
  if [[ ${#plain_files[@]} -gt 0 ]]; then
    rg -o "op=[A-Za-z0-9\\-]+" "${plain_files[@]}" | tail -n 120 | sed 's/^op=//' | sort -u || true
  fi
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  print_usage
  exit 0
fi

if [[ "${1:-}" == "--op" ]]; then
  trace_operation "${2:-}"
  exit 0
fi

if [[ $# -ge 1 ]]; then
  trace_operation "$1"
  exit 0
fi

show_summary
