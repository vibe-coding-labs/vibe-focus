import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerAuditBubbleSessionRestoreTests.swift — Bubble/SessionRestore 域
// 审计批回归锁（2026-09-26 精读批）。两项修复的「修复前红」语义都锁死：
// ①SSHCommandParser 带值选项漏 -m/-S 时 `ssh -m mymacs host` 会把 mymacs 误认成
//   目的地（错连风险）；②iTerm bounds 解析 compactMap 丢段会把坏行凑成合法四元组
//   （违背「解析失败整行跳过」契约）。

extension RunnerHarness {
    func runAuditBubbleSessionRestoreTests() {

        // MARK: A. SSH 带值选项补全（-m/-S）
        do {
            let parsed = SSHCommandParser.parseDestination(commandLine: "ssh -m mymacs cc@1.2.3.4")
            check("audit: ssh -m 的值不被误认成目的地",
                  parsed?.host == "1.2.3.4" && parsed?.user == "cc")
            let parsedS = SSHCommandParser.parseDestination(commandLine: "ssh -S ctl-sock cc@host")
            check("audit: ssh -S 的值不被误认成目的地", parsedS?.host == "host")
            // 既有形态回归：分离式与粘写带值不受影响
            let pFlag = SSHCommandParser.parseDestination(commandLine: "ssh -p 2222 cc@host")
            check("audit: -p 2222 分离式端口仍解析", pFlag?.port == "2222" && pFlag?.host == "host")
            let oFlag = SSHCommandParser.parseDestination(
                commandLine: "ssh -o StrictHostKeyChecking=no cc@192.168.1.83")
            check("audit: 真机实锚形态不回归",
                  oFlag?.host == "192.168.1.83" && oFlag?.user == "cc")
            let inline = SSHCommandParser.parseDestination(commandLine: "ssh -p2222 cc@host")
            check("audit: -p2222 粘写端口仍解析", inline?.port == "2222" && inline?.host == "host")
        }

        // MARK: B. iTerm 枚举解析严格四段
        do {
            // 坏段行：compactMap 旧实现会丢掉 abc 凑成 [10,20,40,50] 错误四元组
            let bad = PaneEnumeration.parseITermSessions(
                "123|1|1|ttys001|10,20,abc,40|name\n")
            check("audit: bounds 坏段→整行跳过（契约对齐）", bad.isEmpty)
            // 好段行：正常解析成 bounds（l,t,r,b → x,y,w,h）
            let good = PaneEnumeration.parseITermSessions(
                "123|2|3|ttys002|100,200,500,600|proj\n")
            check("audit: 合法行照常解析", good.count == 1
                  && good[0].windowBounds == CGRect(x: 100, y: 200, width: 400, height: 400))
            check("audit: 合法行 tty 补前缀/序号保留",
                  good[0].tty == "ttys002" || good[0].tty == "/dev/ttys002",
                  )
            // name 含 | 的既有边界不回归
            let pipeName = PaneEnumeration.parseITermSessions(
                "123|1|1|ttys001|10,20,40,60|na|me\n")
            check("audit: name 含 | 撕列边界不回归",
                  pipeName.count == 1 && pipeName[0].name == "na|me")
        }

        // MARK: C. SSHCommandParser destinationArg 组合不回归
        do {
            let withPort = SSHCommandParser.parseDestination(commandLine: "ssh -p 2200 cc@host")
            check("audit: destinationArg 组合 user@host", withPort?.destinationArg == "cc@host")
            let noUser = SSHCommandParser.parseDestination(commandLine: "ssh host")
            check("audit: 无用户形态 destinationArg=host", noUser?.destinationArg == "host")
        }
    }
}
