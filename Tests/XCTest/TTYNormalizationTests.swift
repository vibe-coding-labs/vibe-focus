import Testing
import Foundation
@testable import VibeFocusKit

@Suite("TTY Normalization")
@MainActor
struct TTYNormalizationTests {

    @Test("normalizeTTY: nil → nil")
    func nilTTY() {
        #expect(WindowManager.normalizeTTY(nil) == nil)
    }

    @Test("normalizeTTY: empty string → nil")
    func emptyTTY() {
        #expect(WindowManager.normalizeTTY("") == nil)
    }

    @Test("normalizeTTY: 'not a tty' → nil")
    func notATty() {
        #expect(WindowManager.normalizeTTY("not a tty") == nil)
    }

    @Test("normalizeTTY: bare tty name gets /dev/ prefix")
    func bareName() {
        #expect(WindowManager.normalizeTTY("ttys001") == "/dev/ttys001")
    }

    @Test("normalizeTTY: full path returned as-is")
    func fullPath() {
        #expect(WindowManager.normalizeTTY("/dev/ttys003") == "/dev/ttys003")
    }

    @Test("normalizeTTY: pts style")
    func ptsStyle() {
        #expect(WindowManager.normalizeTTY("pts/0") == "/dev/pts/0")
    }

    @Test("normalizeTTY: full pts path")
    func fullPtsPath() {
        #expect(WindowManager.normalizeTTY("/dev/pts/0") == "/dev/pts/0")
    }

    @Test("normalizeTTY: conspy style")
    func conspyStyle() {
        #expect(WindowManager.normalizeTTY("tty1") == "/dev/tty1")
    }
}
