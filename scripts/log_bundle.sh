#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"
OP_ID=""
OUT_DIR=""

usage() {
  cat <<'USAGE'
Usage:
  scripts/log_bundle.sh
  scripts/log_bundle.sh --op <operation-id>
  scripts/log_bundle.sh --output <directory>
  scripts/log_bundle.sh --op <operation-id> --output <directory>

Examples:
  scripts/log_bundle.sh
  scripts/log_bundle.sh --op toggle-00000599
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --op)
      OP_ID="${2:-}"
      shift 2
      ;;
    --output)
      OUT_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="/tmp/vibefocus-diagnostics-${TIMESTAMP}"
fi

mkdir -p "$OUT_DIR"

copy_if_exists() {
  local source_path="$1"
  local target_name="$2"
  if [[ -f "$source_path" ]]; then
    cp "$source_path" "$OUT_DIR/$target_name"
  fi
}

copy_if_exists "/tmp/vibefocus.log" "vibefocus.log"
copy_if_exists "/tmp/vibefocus.log.1" "vibefocus.log.1"
copy_if_exists "/tmp/vibefocus-events.jsonl" "vibefocus-events.jsonl"
copy_if_exists "/tmp/vibefocus-events.jsonl.1" "vibefocus-events.jsonl.1"
copy_if_exists "/tmp/vibefocus-crash-context.json" "vibefocus-crash-context.json"
copy_if_exists "/tmp/vibefocus-crash-tail.log" "vibefocus-crash-tail.log"
copy_if_exists "/tmp/vibefocus-crash-tail-events.jsonl" "vibefocus-crash-tail-events.jsonl"

DIAG_DIR="$HOME/Library/Logs/DiagnosticReports"
if [[ -d "$DIAG_DIR" ]]; then
  while IFS= read -r report_path; do
    cp "$report_path" "$OUT_DIR/$(basename "$report_path")"
  done < <(ls -1t "$DIAG_DIR"/VibeFocusHotkeys-*.ips 2>/dev/null | head -n 3 || true)
fi

{
  echo "VibeFocus Diagnostics Bundle"
  echo "generated_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "host=$(hostname)"
  echo "out_dir=$OUT_DIR"
  echo

  echo "[files]"
  if command -v stat >/dev/null 2>&1; then
    shopt -s nullglob
    for file_path in "$OUT_DIR"/*; do
      if [[ -f "$file_path" ]]; then
        size_bytes="$(stat -f "%z" "$file_path" 2>/dev/null || echo 0)"
        echo "$size_bytes $(basename "$file_path")"
      fi
    done | sort -nr
    shopt -u nullglob
  fi
  echo

  if [[ -f "$OUT_DIR/vibefocus-events.jsonl" ]] && command -v jq >/dev/null 2>&1; then
    echo "[level_counts]"
    jq -r '.level // "UNKNOWN"' "$OUT_DIR/vibefocus-events.jsonl" | sort | uniq -c | sort -nr || true
    echo

    echo "[slow_toggles_ms]"
    jq -r '
      select(.message == "[WindowManager] toggle finished")
      | select((.fields.durationMs | tonumber?) != null)
      | "\(.fields.durationMs)\t\(.fields.op // "-")\t\(.fields.mode // "-")\t\(.fields.source // "-")\t\(.ts // "-")"
    ' "$OUT_DIR/vibefocus-events.jsonl" | sort -nr -k1,1 | head -n 30 || true
    echo

    echo "[recent_warn_error_events]"
    jq -c 'select(.level == "WARN" or .level == "ERROR")' "$OUT_DIR/vibefocus-events.jsonl" | tail -n 120 || true
    echo
  else
    echo "[recent_warn_error_events_plain]"
    if [[ -f "$OUT_DIR/vibefocus.log" ]]; then
      rg -n "\\[WARN\\]|\\[ERROR\\]|toggle_slow|yabai command slow|frontmost app changed during toggle" "$OUT_DIR/vibefocus.log" | tail -n 120 || true
    fi
    echo
  fi

  echo "[recent_ops]"
  if [[ -f "$OUT_DIR/vibefocus.log" ]]; then
    rg -o "op=[A-Za-z0-9\\-]+" "$OUT_DIR/vibefocus.log" | tail -n 200 | sed 's/^op=//' | sort -u || true
  fi
  echo

  echo "[trace_summary]"
  "$SCRIPT_DIR/log_trace.sh" || true
} > "$OUT_DIR/summary.txt"

if [[ -n "$OP_ID" ]]; then
  "$SCRIPT_DIR/log_trace.sh" "$OP_ID" > "$OUT_DIR/trace-${OP_ID}.txt" || true
fi

ARCHIVE_PATH="${OUT_DIR}.tar.gz"
tar -czf "$ARCHIVE_PATH" -C "$(dirname "$OUT_DIR")" "$(basename "$OUT_DIR")"

echo "Bundle directory: $OUT_DIR"
echo "Bundle archive:   $ARCHIVE_PATH"
echo "Summary file:     $OUT_DIR/summary.txt"
if [[ -n "$OP_ID" ]]; then
  echo "Operation trace:   $OUT_DIR/trace-${OP_ID}.txt"
fi
