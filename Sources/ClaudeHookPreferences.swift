import Foundation

enum ClaudeHookPreferences {
    static let enabledKey = "claudeHookEnabled"
    static let portKey = "claudeHookPort"
    static let tokenKey = "claudeHookToken"
    static let autoFocusOnSessionEndKey = "claudeHookAutoFocusOnSessionEnd"

    static let endpointPath = "/claude/hook"
    static let defaultPort = 39277

    static var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    static var listenPort: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: portKey)
            if stored == 0 {
                return defaultPort
            }
            return normalizePort(stored)
        }
        set {
            UserDefaults.standard.set(normalizePort(newValue), forKey: portKey)
        }
    }

    static var authToken: String? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: tokenKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                return nil
            }
            return raw
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            UserDefaults.standard.set(trimmed, forKey: tokenKey)
        }
    }

    static var autoFocusOnSessionEnd: Bool {
        get {
            UserDefaults.standard.object(forKey: autoFocusOnSessionEndKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoFocusOnSessionEndKey)
        }
    }

    static func endpointURLString(port: Int? = nil) -> String {
        let effectivePort = normalizePort(port ?? listenPort)
        return "http://127.0.0.1:\(effectivePort)\(endpointPath)"
    }

    static func hookCommandExample(port: Int? = nil, token: String? = nil) -> String {
        let effectivePort = normalizePort(port ?? listenPort)
        let tokenHeader = token?.isEmpty == false
            ? "  \\\n  -H 'X-VibeFocus-Token: \(token!)'"
            : ""
        return """
#!/bin/bash
set -euo pipefail

EVENT="$1" # SessionStart or SessionEnd
PAYLOAD="$(cat)"
SESSION_ID="$(echo "$PAYLOAD" | jq -r '.session_id // .sessionId // empty' 2>/dev/null || true)"
if [ -z "$SESSION_ID" ]; then
  SESSION_ID="unknown-session"
fi

curl -sS -X POST "http://127.0.0.1:\(effectivePort)/claude/hook" \
  -H "Content-Type: application/json"\(tokenHeader) \
  --data "{\"event\":\"$EVENT\",\"session_id\":\"$SESSION_ID\",\"source\":\"claude-code-hook\"}" >/dev/null || true
"""
    }

    private static func normalizePort(_ value: Int) -> Int {
        min(max(value, 1024), 65535)
    }
}
