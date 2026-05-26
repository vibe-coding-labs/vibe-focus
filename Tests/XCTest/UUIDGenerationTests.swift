import Testing
import Foundation
@testable import VibeFocusKit

@Suite("UUID Generation from Display ID")
@MainActor
struct UUIDGenerationTests {

    @Test("uuidFromDisplayID encodes big-endian bytes")
    func displayIDEncoding() {
        let uuid = ScreenOverlayManager.uuidFromDisplayID(0x12345678)
        let bytes = uuid.uuid
        #expect(bytes.0 == 0x12)
        #expect(bytes.1 == 0x34)
        #expect(bytes.2 == 0x56)
        #expect(bytes.3 == 0x78)
        // Remaining bytes should be 0
        #expect(bytes.4 == 0)
        #expect(bytes.15 == 0)
    }

    @Test("uuidFromDisplayID: zero display ID")
    func zeroDisplayID() {
        let uuid = ScreenOverlayManager.uuidFromDisplayID(0)
        let bytes = uuid.uuid
        #expect(bytes.0 == 0)
        #expect(bytes.1 == 0)
        #expect(bytes.2 == 0)
        #expect(bytes.3 == 0)
    }

    @Test("uuidFromDisplayID: max UInt32")
    func maxDisplayID() {
        let uuid = ScreenOverlayManager.uuidFromDisplayID(UInt32.max)
        let bytes = uuid.uuid
        #expect(bytes.0 == 0xFF)
        #expect(bytes.1 == 0xFF)
        #expect(bytes.2 == 0xFF)
        #expect(bytes.3 == 0xFF)
    }

    @Test("uuidFromDisplayID: deterministic")
    func deterministic() {
        let a = ScreenOverlayManager.uuidFromDisplayID(12345)
        let b = ScreenOverlayManager.uuidFromDisplayID(12345)
        #expect(a == b)
    }

    @Test("uuidFromDisplayID: different IDs produce different UUIDs")
    func differentIDs() {
        let a = ScreenOverlayManager.uuidFromDisplayID(1)
        let b = ScreenOverlayManager.uuidFromDisplayID(2)
        #expect(a != b)
    }

    @Test("fallbackUUIDFromHash: encodes hash in last byte")
    func fallbackHash() {
        let uuid = ScreenOverlayManager.fallbackUUIDFromHash(42)
        let bytes = uuid.uuid
        #expect(bytes.15 == 42)
        // Other bytes should be 0
        #expect(bytes.0 == 0)
        #expect(bytes.14 == 0)
    }

    @Test("fallbackUUIDFromHash: negative hash wraps via abs")
    func fallbackNegativeHash() {
        let uuid = ScreenOverlayManager.fallbackUUIDFromHash(-42)
        let bytes = uuid.uuid
        #expect(bytes.15 == 42)
    }

    @Test("fallbackUUIDFromHash: large hash value wraps via modulo")
    func fallbackLargeHash() {
        let uuid = ScreenOverlayManager.fallbackUUIDFromHash(300)
        let bytes = uuid.uuid
        #expect(bytes.15 == UInt8(300 % 256)) // 44
    }

    @Test("fallbackUUIDFromHash: deterministic")
    func fallbackDeterministic() {
        let a = ScreenOverlayManager.fallbackUUIDFromHash(999)
        let b = ScreenOverlayManager.fallbackUUIDFromHash(999)
        #expect(a == b)
    }
}
