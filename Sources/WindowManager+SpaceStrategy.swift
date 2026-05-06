import AppKit
import Foundation

@MainActor
extension WindowManager {

    func applySpaceStrategyForRestore(windowID: UInt32?, operationID: String? = nil, triggerSource: String = "unknown") -> Bool {
        guard let windowID else {
            log(
                "[WindowManager] applySpaceStrategyForRestore: nil windowID, returning true",
                level: .debug
            )
            return true
        }
        let op = operationID ?? makeOperationID(prefix: "restore-space")

        // 注意：focusSpaceKnownBroken 时不能跳过整个 Space 策略！
        // 只跳过 yabai focusSpace（已知失败），但 NativeSpaceBridge.moveWindow + focusWindow 仍需执行
        // 否则用户活跃 Space 不会切换，窗口虽然在正确坐标但用户看不到

        log(
            "[WindowManager] applySpaceStrategyForRestore called",
            level: .debug,
            fields: [
                "op": op,
                "windowID": String(windowID),
                "strategy": SpacePreferences.restoreStrategy.rawValue
            ]
        )

        // 关键安全检查：验证窗口是否仍然存在
        // 如果窗口已被关闭，跳过所有 space 操作以避免 EXC_BAD_ACCESS
        log(
            "[WindowManager] applySpaceStrategyForRestore validating window exists",
            level: .debug,
            fields: ["op": op, "windowID": String(windowID)]
        )
        if !validateWindowExists(windowID: windowID) {
            log(
                "[WindowManager] space strategy aborted: window no longer exists",
                level: .warn,
                fields: [
                    "op": op,
                    "windowID": String(windowID)
                ]
            )
            return true  // 返回 true 表示"不需要 space 操作"，让调用方继续尝试 frame restore
        }

        spaceController.refreshAvailabilityIfNeeded()
        guard spaceController.isEnabled else {
            log(
                "[WindowManager] space strategy skipped: integration disabled",
                fields: [
                    "op": op
                ]
            )
            return true
        }

        log(
            "[WindowManager] applySpaceStrategyForRestore space integration enabled",
            level: .debug,
            fields: ["op": op, "canControlSpaces": String(spaceController.canControlSpaces)]
        )

        guard let currentSpace = spaceController.currentSpaceIndex() else {
            log(
                "[WindowManager] space strategy skipped: current space unavailable",
                level: .warn,
                fields: [
                    "op": op
                ]
            )
            return true
        }

        log(
            "[WindowManager] applySpaceStrategyForRestore resolved currentSpace",
            level: .debug,
            fields: ["op": op, "currentSpace": String(currentSpace)]
        )

        let resolvedSourceSpace = resolveSourceSpaceIndexForRestore()
        log(
            "[WindowManager] applySpaceStrategyForRestore resolvedSourceSpace",
            level: .debug,
            fields: [
                "op": op,
                "resolvedSourceSpace": String(describing: resolvedSourceSpace),
                "lastSourceSpaceIndex": String(describing: lastSourceSpaceIndex)
            ]
        )
        log(
            "[WindowManager] applying space strategy",
            fields: [
                "op": op,
                "strategy": SpacePreferences.restoreStrategy.rawValue,
                "sourceSpace": String(describing: lastSourceSpaceIndex),
                "resolvedSourceSpace": String(describing: resolvedSourceSpace),
                "sourceDisplay": String(describing: lastSourceYabaiDisplayIndex),
                "sourceDisplaySpace": String(describing: lastSourceDisplaySpaceIndex),
                "currentSpace": String(currentSpace),
                "canControlSpaces": String(spaceController.canControlSpaces),
                "windowID": String(windowID)
            ]
        )

        switch SpacePreferences.restoreStrategy {
        case .switchToOriginal:
            log(
                "[WindowManager] applySpaceStrategy using switchToOriginal strategy",
                level: .debug,
                fields: ["op": op]
            )
            guard let sourceSpace = resolvedSourceSpace ?? lastSourceSpaceIndex else {
                log(
                    "[WindowManager] no source space recorded for restore",
                    level: .warn,
                    fields: [
                        "op": op
                    ]
                )
                return true
            }

            guard sourceSpace != currentSpace else {
                log(
                    "[WindowManager] source space equals current space, skip move",
                    fields: [
                        "op": op,
                        "sourceSpace": String(sourceSpace),
                        "currentSpace": String(currentSpace)
                    ]
                )
                return true
            }

            log(
                "[WindowManager] switchToOriginal: sourceSpace != currentSpace, proceeding",
                level: .debug,
                fields: [
                    "op": op,
                    "sourceSpace": String(sourceSpace),
                    "currentSpace": String(currentSpace)
                ]
            )

            guard spaceController.canControlSpaces else {
                log(
                    "[WindowManager] cannot restore to source space: cross-space control unavailable",
                    level: .error,
                    fields: [
                        "op": op,
                        "sourceSpace": String(sourceSpace)
                    ]
                )
                return false
            }

            // === Phase 1: focusSpace 预切换 ===
            // 先切换目标 display 到源 space，确保 space 可见后再移动窗口
            // 这解决了副屏当前显示不同 space 时 AX 坐标被应用到错误 space 的问题

            let preFocusCurrentSpace = currentSpace
            let windowSpaceBefore = spaceController.windowSpaceIndex(windowID: windowID)
            log(
                "[WindowManager] restore_space_pre_focus",
                fields: [
                    "op": op,
                    "windowID": String(windowID),
                    "sourceSpace": String(sourceSpace),
                    "currentSpaceAtEntry": String(preFocusCurrentSpace),
                    "windowActualSpace": String(describing: windowSpaceBefore),
                    "sourceYabaiDisplay": String(describing: lastSourceYabaiDisplayIndex),
                    "sourceDisplaySpace": String(describing: lastSourceDisplaySpaceIndex)
                ]
            )

            let focusStartedAt = Date()
            // 如果上次 focusSpace 已确认无效（yabai SA 不可用），直接跳过
            let focusSucceeded: Bool
            if focusSpaceKnownBroken {
                log(
                    "[WindowManager] switchToOriginal skipping focusSpace (known broken)",
                    level: .debug,
                    fields: ["op": op]
                )
                focusSucceeded = false
            } else {
                focusSucceeded = spaceController.focusSpace(sourceSpace, operationID: op)
            }
            let focusDurationMs = elapsedMilliseconds(since: focusStartedAt)
            log(
                "[WindowManager] switchToOriginal focusSpace returned",
                level: .debug,
                fields: [
                    "op": op,
                    "focusSucceeded": String(focusSucceeded),
                    "focusDurationMs": String(focusDurationMs)
                ]
            )
            let postFocusSpace = spaceController.currentSpaceIndex()

            // 如果 focusSpace "成功"但 Space 没变，标记为 broken 避免下次浪费时间
            if focusSucceeded && postFocusSpace == preFocusCurrentSpace {
                focusSpaceKnownBroken = true
                log(
                    "[WindowManager] focusSpace reported success but space unchanged, marking as broken",
                    level: .warn,
                    fields: ["op": op, "focusDurationMs": String(focusDurationMs)]
                )
            }

            log(
                "[WindowManager] restore_space_post_focus",
                fields: [
                    "op": op,
                    "focusSucceeded": String(focusSucceeded),
                    "focusDurationMs": String(focusDurationMs),
                    "targetSpace": String(sourceSpace),
                    "actualCurrentSpace": String(describing: postFocusSpace),
                    "spaceChanged": String(postFocusSpace != preFocusCurrentSpace)
                ]
            )

            if focusSucceeded {
                // 仅在 space 实际切换且到达目标时等待动画完成
                if postFocusSpace != preFocusCurrentSpace && postFocusSpace == sourceSpace {
                    let settleStart = Date()
                    let targetSourceSpace = sourceSpace
                    while Date().timeIntervalSince(settleStart) < 0.1 {
                        if let s = spaceController.currentSpaceIndex(), s == targetSourceSpace { break }
                        usleep(20_000)
                    }
                }

                let postSettleSpace = spaceController.currentSpaceIndex()
                log(
                    "[WindowManager] restore_space_post_settle",
                    fields: [
                        "op": op,
                        "targetSpace": String(sourceSpace),
                        "actualCurrentSpace": String(describing: postSettleSpace),
                        "settleOk": String(postSettleSpace == sourceSpace),
                        "spaceChanged": String(postFocusSpace != preFocusCurrentSpace)
                    ]
                )
            } else {
                log(
                    "[WindowManager] restore_space_focus_failed_continuing",
                    level: .warn,
                    fields: [
                        "op": op,
                        "targetSpace": String(sourceSpace),
                        "focusDurationMs": String(focusDurationMs)
                    ]
                )
                // focusSpace 失败可能把 canControlSpaces 污染为 false（scripting-addition 错误）
                // 不强制刷新（太慢），直接让 moveWindow 尝试执行
                log(
                    "[WindowManager] restore_space_post_focus_recovery",
                    fields: [
                        "op": op,
                        "canControlSpaces": String(spaceController.canControlSpaces)
                    ]
                )
            }

            // === Phase 2: moveWindow ===
            // 即使 focusSpace 失败，moveWindow 仍需执行（NativeSpaceBridge 不需要 SA）
            log(
                "[WindowManager] switchToOriginal Phase 2: calling moveWindow",
                level: .debug,
                fields: [
                    "op": op,
                    "windowID": String(windowID),
                    "targetSpace": String(sourceSpace)
                ]
            )
            if spaceController.moveWindow(windowID, toSpaceIndex: sourceSpace, focus: false, operationID: op) {
                let windowSpaceAfterMove = spaceController.windowSpaceIndex(windowID: windowID)
                log(
                    "[WindowManager] restore_space_post_move",
                    fields: [
                        "op": op,
                        "windowID": String(windowID),
                        "targetSpace": String(sourceSpace),
                        "windowActualSpace": String(describing: windowSpaceAfterMove),
                        "moveVerified": String(windowSpaceAfterMove == sourceSpace)
                    ]
                )
                if triggerSource == "carbon_hotkey" {
                    if !spaceController.focusWindow(windowID, operationID: op) {
                        log(
                            "[WindowManager] failed to focus restored window on source space",
                            level: .warn,
                            fields: [
                                "op": op,
                                "windowID": String(windowID),
                                "space": String(sourceSpace)
                            ]
                        )
                    } else {
                        log(
                            "[WindowManager] switchToOriginal focusWindow succeeded on source space",
                            level: .debug,
                            fields: ["op": op, "windowID": String(windowID)]
                        )
                    }
                } else {
                    log(
                        "[WindowManager] switchToOriginal skipping focusWindow (hook-restore)",
                        level: .debug,
                        fields: ["op": op, "windowID": String(windowID), "triggerSource": triggerSource]
                    )
                }
            } else {
                log(
                    "[WindowManager] restore_space_move_failed",
                    level: .error,
                    fields: [
                        "op": op,
                        "windowID": String(windowID),
                        "targetSpace": String(sourceSpace)
                    ]
                )
                // moveWindow 失败不应标记 focusSpace broken（两个不同操作）
                // focusSpaceKnownBroken 只在 focusSpace 自身失败时设置
                return false
            }

            log(
                "[WindowManager] restore_space_result",
                fields: [
                    "op": op,
                    "outcome": "success",
                    "sourceSpace": String(sourceSpace),
                    "focusOk": String(focusSucceeded),
                    "focusDurationMs": String(focusDurationMs)
                ]
            )
            return true
        case .pullToCurrent:
            log(
                "[WindowManager] applySpaceStrategy using pullToCurrent strategy",
                level: .debug,
                fields: [
                    "op": op,
                    "currentSpace": String(currentSpace),
                    "lastSourceSpaceIndex": String(describing: lastSourceSpaceIndex)
                ]
            )
            if let sourceSpace = lastSourceSpaceIndex, sourceSpace != currentSpace {
                log(
                    "[WindowManager] pullToCurrent: sourceSpace != currentSpace, need to move",
                    level: .debug,
                    fields: [
                        "op": op,
                        "sourceSpace": String(sourceSpace),
                        "currentSpace": String(currentSpace)
                    ]
                )
                guard spaceController.canControlSpaces else {
                    log(
                        "[WindowManager] cannot pull window: cross-space control unavailable",
                        level: .error,
                        fields: [
                            "op": op,
                            "sourceSpace": String(sourceSpace),
                            "currentSpace": String(currentSpace)
                        ]
                    )
                    return false
                }

                if spaceController.moveWindow(windowID, toSpaceIndex: currentSpace, focus: false, operationID: op) {
                    log(
                        "[WindowManager] moved window to current space for restore",
                        fields: [
                            "op": op,
                            "windowID": String(windowID),
                            "space": String(currentSpace)
                        ]
                    )
                    if triggerSource == "carbon_hotkey" {
                        if !spaceController.focusWindow(windowID, operationID: op) {
                            log(
                                "[WindowManager] pullToCurrent focusWindow failed",
                                level: .debug,
                                fields: ["op": op, "windowID": String(windowID)]
                            )
                            log(
                                "[WindowManager] failed to focus restored window on current space",
                                level: .warn,
                                fields: [
                                    "op": op,
                                    "windowID": String(windowID),
                                    "space": String(currentSpace)
                                ]
                            )
                        }
                    } else {
                        log(
                            "[WindowManager] pullToCurrent skipping focusWindow (hook-restore)",
                            level: .debug,
                            fields: ["op": op, "windowID": String(windowID), "triggerSource": triggerSource]
                        )
                    }
                } else {
                    log(
                        "[WindowManager] failed to move window to current space",
                        level: .error,
                        fields: [
                            "op": op,
                            "windowID": String(windowID),
                            "space": String(currentSpace)
                        ]
                    )
                    return false
                }
            }
            return true
        }
    }

    private func resolveSourceSpaceIndexForRestore() -> Int? {
        log(
            "[WindowManager] resolveSourceSpaceIndexForRestore called",
            level: .debug,
            fields: [
                "lastSourceYabaiDisplayIndex": String(describing: lastSourceYabaiDisplayIndex),
                "lastSourceDisplaySpaceIndex": String(describing: lastSourceDisplaySpaceIndex),
                "lastSourceSpaceIndex": String(describing: lastSourceSpaceIndex)
            ]
        )
        guard let displayIndex = lastSourceYabaiDisplayIndex,
              let displaySpaceIndex = lastSourceDisplaySpaceIndex else {
            return lastSourceSpaceIndex
        }

        guard let mapped = spaceController.globalSpaceIndex(
            displayIndex: displayIndex,
            localSpaceIndex: displaySpaceIndex
        ) else {
            log("resolveSourceSpaceIndexForRestore: failed to map display-local space (display=\(displayIndex), local=\(displaySpaceIndex)); fallback to source=\(String(describing: lastSourceSpaceIndex))")
            return lastSourceSpaceIndex
        }

        if mapped != lastSourceSpaceIndex {
            log("resolveSourceSpaceIndexForRestore: remapped source from \(String(describing: lastSourceSpaceIndex)) to \(mapped) using display=\(displayIndex) local=\(displaySpaceIndex)")
        }
        return mapped
    }
}
