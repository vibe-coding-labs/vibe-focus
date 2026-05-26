#!/bin/bash
# Run all standalone tests for VibeFocus
# Usage: bash Tests/run_all_tests.sh
# Exit code: 0 = all pass, 1 = any fail

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$SCRIPT_DIR/Standalone"

if [ ! -d "$TEST_DIR" ]; then
    echo "ERROR: Test directory not found: $TEST_DIR"
    exit 1
fi

TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_FILES=()

for test_file in "$TEST_DIR"/*.swift; do
    [ -f "$test_file" ] || continue
    filename=$(basename "$test_file")
    echo ""
    echo "=========================================="
    echo "  Running: $filename"
    echo "=========================================="

    if swift "$test_file" 2>&1; then
        TOTAL_PASS=$((TOTAL_PASS + 1))
        echo "  OK: $filename"
    else
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        FAILED_FILES+=("$filename")
        echo "  FAILED: $filename"
    fi
done

echo ""
echo "=========================================="
echo "  Summary: $((TOTAL_PASS + TOTAL_FAIL)) tests, $TOTAL_PASS passed, $TOTAL_FAIL failed"
echo "=========================================="

if [ $TOTAL_FAIL -gt 0 ]; then
    echo ""
    echo "  Failed:"
    for f in "${FAILED_FILES[@]}"; do
        echo "    - $f"
    done
    exit 1
fi

echo ""
echo "  All tests passed."
exit 0
