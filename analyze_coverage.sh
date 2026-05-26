#!/bin/bash

# Script to find untested internal functions and properties

# Create temporary files
FUNCTIONS_LIST="/tmp/functions_list.txt"
PROPERTIES_LIST="/tmp/properties_list.txt"
TESTED_FUNCTIONS="/tmp/tested_functions.txt"
UNTESTED_FUNCTIONS="/tmp/untested_functions.txt"

# Clear temporary files
> "$FUNCTIONS_LIST"
> "$PROPERTIES_LIST"
> "$TESTED_FUNCTIONS"
> "$UNTESTED_FUNCTIONS"

# Get all functions, excluding private, UI/AppKit, and other skipped categories
echo "Extracting functions..."
find Sources -name "*.swift" -exec grep -n "^[[:space:]]*func " {} \; | \
  grep -v "private " | \
  grep -v "IBAction" | \
  grep -v "NSResponder" | \
  grep -v "NSView" | \
  grep -v "NSWindow" | \
  grep -v "NSApplication" | \
  grep -v "NSStatusItem" | \
  grep -v "NSMenuItem" | \
  grep -v "NSImage" | \
  grep -v "NSScreen" | \
  grep -v "CGWindowList" | \
  grep -v "AXUIElement" | \
  grep -v "Process\|Shell\|FileManager\|URLSession\|GCDWebServer" | \
  sort > "$FUNCTIONS_LIST"

# Get all properties, excluding private and UI/AppKit categories
echo "Extracting properties..."
find Sources -name "*.swift" -exec grep -n "^[[:space:]]*var " {} \; | \
  grep -v "private " | \
  grep -v "@IBOutlet" | \
  grep -v "@IBAction" | \
  grep -v "NSResponder" | \
  grep -v "NSView" | \
  grep -v "NSWindow" | \
  grep -v "NSApplication" | \
  grep -v "NSStatusItem" | \
  grep -v "NSMenuItem" | \
  grep -v "NSImage" | \
  grep -v "NSScreen" | \
  grep -v "CGWindowList" | \
  grep -v "AXUIElement" | \
  sort > "$PROPERTIES_LIST"

# Get all tested functions from test files
echo "Extracting tested functions..."
find Tests -name "*.swift" -exec grep -n "func " {} \; | \
  grep -v "private " | \
  cut -d: -f3 | \
  grep -E '^[[:space:]]*[a-zA-Z_]' | \
  tr -d ' ' | \
  sort > "$TESTED_FUNCTIONS"

echo "Total functions extracted: $(wc -l < "$FUNCTIONS_LIST")"
echo "Total properties extracted: $(wc -l < "$PROPERTIES_LIST")"
echo "Total tested functions found: $(wc -l < "$TESTED_FUNCTIONS")"

# Check which functions are untested
echo "Checking test coverage..."
cut -d: -f3 "$FUNCTIONS_LIST" | grep -v '^$' | tr -d ' ' | sort > "$FUNCTIONS_NAMES.txt"
cut -d: -f3 "$PROPERTIES_LIST" | grep -v '^$' | tr -d ' ' | sort > "$PROPERTIES_NAMES.txt"

cat "$FUNCTIONS_NAMES.txt" "$PROPERTIES_NAMES.txt" | sort | uniq > "$ALL_NAMES.txt"

while IFS= read -r name; do
    if ! grep -Fxq "$name" "$TESTED_FUNCTIONS"; then
        # Find the original line with this name
        grep ":$name$" "$FUNCTIONS_LIST" "$PROPERTIES_LIST" | head -1
    fi
done < "$ALL_NAMES.txt" > "$UNTESTED_FUNCTIONS"

echo "Untested functions/properties found: $(wc -l < "$UNTESTED_FUNCTIONS")"

# Display results
echo ""
echo "=== UNTESTED FUNCTIONS AND PROPERTIES ==="
cat "$UNTESTED_FUNCTIONS"

# Clean up
rm -f "$FUNCTIONS_LIST" "$PROPERTIES_LIST" "$TESTED_FUNCTIONS" "$UNTESTED_FUNCTIONS" "$FUNCTIONS_NAMES.txt" "$PROPERTIES_NAMES.txt" "$ALL_NAMES.txt"
