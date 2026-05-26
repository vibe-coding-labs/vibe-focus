// Tests/Standalone/HookScriptContentTests.swift
// Verification: Helper script and remote install script content generation
// Mirrors: Sources/Hook/ClaudeHookPreferences.swift:295-505
// Run: swift Tests/Standalone/HookScriptContentTests.swift

import Foundation

// MARK: - Mirrored logic

func generateHelperScriptContent(lanMode: Bool) -> String {
    let hostBlock = lanMode ? """
        VF_HOST=$(python3 -c "import json;d=json.load(open('$VF_CONFIG'));print(d.get('host','127.0.0.1'))" 2>/dev/null || echo "127.0.0.1")

""" : ""
    let hostDefault = lanMode ? "$VF_HOST" : "127.0.0.1"
    return """
    #!/bin/bash
    set -euo pipefail

    # VibeFocus Hook Forwarder
    # Captures terminal context and forwards Claude Code hook events to VibeFocus

    VF_CONFIG="$HOME/.vibefocus/hook-config.json"
    VF_PORT=39277
    VF_TOKEN=""
    \(hostBlock)
    if [ -f "$VF_CONFIG" ]; then
        VF_PORT=$(python3 -c "import json;d=json.load(open('$VF_CONFIG'));print(d.get('port',39277))" 2>/dev/null || echo "39277")
        VF_TOKEN=$(python3 -c "import json;d=json.load(open('$VF_CONFIG'));print(d.get('token',''))" 2>/dev/null || echo "")
    fi

    VF_PAYLOAD=$(cat)

    VF_TSID="${TERM_SESSION_ID:-}"
    VF_ISID="${ITERM_SESSION_ID:-}"
    VF_KWID="${KITTY_WINDOW_ID:-}"
    VF_WP="${WEZTERM_PANE:-}"
    VF_TTY=$(tty 2>/dev/null || echo "")
    VF_PPID="${PPID:-}"
    VF_CPD="${CLAUDE_PROJECT_DIR:-}"
    VF_WID="${WINDOWID:-}"

    VF_ENRICHED=$(printf '%s' "$VF_PAYLOAD" | python3 -c "
    import sys, json
    d = json.load(sys.stdin)
    d['terminal_ctx'] = {
        'term_session_id': sys.argv[1],
        'iterm_session_id': sys.argv[2],
        'kitty_window_id': sys.argv[3],
        'wezterm_pane': sys.argv[4],
        'tty': sys.argv[5],
        'ppid': sys.argv[6],
        'claude_project_dir': sys.argv[7],
        'window_id': sys.argv[8]
    }
    print(json.dumps(d))
    " "$VF_TSID" "$VF_ISID" "$VF_KWID" "$VF_WP" "$VF_TTY" "$VF_PPID" "$VF_CPD" "$VF_WID" 2>/dev/null || printf '%s' "$VF_PAYLOAD")

    VF_URL="http://\(hostDefault):$VF_PORT/claude/hook"
    VF_CURL_ARGS=(-sS -X POST "$VF_URL" -H "Content-Type: application/json")
    if [ -n "$VF_TOKEN" ]; then
        VF_CURL_ARGS+=(-H "X-VibeFocus-Token: $VF_TOKEN")
    fi
    VF_CURL_ARGS+=(--data "$VF_ENRICHED")
    curl "${VF_CURL_ARGS[@]}" >/dev/null 2>&1 || true
    """
}

func generateRemoteHelperScriptContent() -> String {
    return """
#!/bin/bash
set -euo pipefail

# VibeFocus Hook Forwarder (Remote)
VF_CONFIG="$HOME/.vibefocus/hook-config.json"
VF_HOST="127.0.0.1"
VF_PORT=39277
VF_TOKEN=""
VF_LABEL=""

if [ -f "$VF_CONFIG" ]; then
    VF_HOST=$(python3 -c "import json;d=json.load(open('$VF_CONFIG'));print(d.get('host','127.0.0.1'))" 2>/dev/null || echo "127.0.0.1")
    VF_PORT=$(python3 -c "import json;d=json.load(open('$VF_CONFIG'));print(d.get('port',39277))" 2>/dev/null || echo "39277")
    VF_TOKEN=$(python3 -c "import json;d=json.load(open('$VF_CONFIG'));print(d.get('token',''))" 2>/dev/null || echo "")
    VF_LABEL=$(python3 -c "import json;d=json.load(open('$VF_CONFIG'));print(d.get('machine_label',''))" 2>/dev/null || echo "")
fi

VF_PAYLOAD=$(cat)
"""
}

func generateMachineLabel(host: String) -> String {
    "remote-\(host.replacingOccurrences(of: ".", with: "-"))"
}

func generateHookConfigJSON(host: String, port: Int, token: String, machineLabel: String) -> String {
    """
    {
      "host": "\(host)",
      "port": \(port),
      "token": "\(token)",
      "machine_label": "\(machineLabel)"
    }
    """
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

func checkEqual<T: Equatable>(_ name: String, _ a: T, _ b: T) {
    if a == b { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name) — expected \(b), got \(a)") }
}

func checkEqual<T: Equatable>(_ name: String, _ a: T?, _ b: T) {
    if a == b { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name) — expected \(b), got \(String(describing: a))") }
}

// MARK: - generateHelperScriptContent — local mode

print("1. generateHelperScriptContent — local mode (lanMode=false)")
do {
    let script = generateHelperScriptContent(lanMode: false)
    check("has shebang", script.hasPrefix("#!/bin/bash"))
    check("has set -euo pipefail", script.contains("set -euo pipefail"))
    check("reads config from hook-config.json", script.contains("VF_CONFIG="))
    check("reads port from config", script.contains("VF_PORT="))
    check("reads token from config", script.contains("VF_TOKEN="))
    check("captures TERM_SESSION_ID", script.contains("TERM_SESSION_ID"))
    check("captures ITERM_SESSION_ID", script.contains("ITERM_SESSION_ID"))
    check("captures KITTY_WINDOW_ID", script.contains("KITTY_WINDOW_ID"))
    check("captures WEZTERM_PANE", script.contains("WEZTERM_PANE"))
    check("captures tty", script.contains("VF_TTY"))
    check("captures PPID", script.contains("VF_PPID"))
    check("captures CLAUDE_PROJECT_DIR", script.contains("CLAUDE_PROJECT_DIR"))
    check("captures WINDOWID", script.contains("WINDOWID"))
    check("enriches with terminal_ctx", script.contains("terminal_ctx"))
    check("posts to /claude/hook with 127.0.0.1 hardcoded", script.contains("http://127.0.0.1:$VF_PORT/claude/hook"))
    check("NO VF_HOST variable in local mode", !script.contains("VF_HOST="))
}

print("\n2. generateHelperScriptContent — LAN mode (lanMode=true)")
do {
    let script = generateHelperScriptContent(lanMode: true)
    check("has VF_HOST variable in LAN mode", script.contains("VF_HOST="))
    check("reads host from config in LAN mode", script.contains("d.get('host'"))
    check("uses $VF_HOST in URL", script.contains("http://$VF_HOST:$VF_PORT/claude/hook"))
    check("NO hardcoded 127.0.0.1 in URL", !script.contains("http://127.0.0.1:$VF_PORT"))
}

// MARK: - generateRemoteHelperScriptContent

print("\n3. generateRemoteHelperScriptContent — structure")
do {
    let script = generateRemoteHelperScriptContent()
    check("has shebang", script.hasPrefix("#!/bin/bash"))
    check("reads host from config", script.contains("VF_HOST="))
    check("reads port from config", script.contains("VF_PORT="))
    check("reads token from config", script.contains("VF_TOKEN="))
    check("reads machine_label from config", script.contains("VF_LABEL="))
    check("captures VF_PAYLOAD", script.contains("VF_PAYLOAD"))
}

// MARK: - machineLabel generation

print("\n4. generateMachineLabel — host to label")
do {
    let label1 = generateMachineLabel(host: "192.168.1.100")
    check("IP → label", label1 == "remote-192-168-1-100")

    let label2 = generateMachineLabel(host: "10.0.0.1")
    check("shorter IP → label", label2 == "remote-10-0-0-1")

    let label3 = generateMachineLabel(host: "my-host.local")
    check("hostname → label", label3 == "remote-my-host-local")

    let label4 = generateMachineLabel(host: "no-dots")
    check("no dots → unchanged after prefix", label4 == "remote-no-dots")

    let label5 = generateMachineLabel(host: "...triple...")
    checkEqual("triple dots", label5, "remote----triple---")
}

// MARK: - generateHookConfigJSON

print("\n5. generateHookConfigJSON — structure")
do {
    let json = generateHookConfigJSON(host: "192.168.1.100", port: 39277, token: "abc123", machineLabel: "remote-192-168-1-100")
    check("contains host", json.contains("\"host\": \"192.168.1.100\""))
    check("contains port", json.contains("\"port\": 39277"))
    check("contains token", json.contains("\"token\": \"abc123\""))
    check("contains machine_label", json.contains("\"machine_label\": \"remote-192-168-1-100\""))

    // Verify it's valid JSON
    let data = json.data(using: .utf8)!
    let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    check("is valid JSON", parsed != nil)
    checkEqual("parsed host", parsed?["host"] as? String, "192.168.1.100")
    checkEqual("parsed port", parsed?["port"] as? Int, 39277)
    checkEqual("parsed token", parsed?["token"] as? String, "abc123")
    checkEqual("parsed machine_label", parsed?["machine_label"] as? String, "remote-192-168-1-100")
}

print("\n6. generateHookConfigJSON — empty token")
do {
    let json = generateHookConfigJSON(host: "10.0.0.1", port: 8080, token: "", machineLabel: "remote-10-0-0-1")
    let data = json.data(using: .utf8)!
    let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    checkEqual("empty token", parsed?["token"] as? String, "")
}

// MARK: - Script content key elements (both modes)

print("\n7. Both scripts capture terminal context variables")
do {
    let local = generateHelperScriptContent(lanMode: false)
    let envVars = ["TERM_SESSION_ID", "ITERM_SESSION_ID", "KITTY_WINDOW_ID", "WEZTERM_PANE", "WINDOWID", "PPID"]
    for envVar in envVars {
        check("local captures \(envVar)", local.contains(envVar))
    }
    // Both scripts read from same config file
    check("local reads hook-config.json", local.contains("VF_CONFIG"))
    check("remote reads hook-config.json", generateRemoteHelperScriptContent().contains("VF_CONFIG"))
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
