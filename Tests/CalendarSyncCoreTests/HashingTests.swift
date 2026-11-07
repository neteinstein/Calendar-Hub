import XCTest
@testable import CalendarSyncCore

final class HashingTests: XCTestCase {
    func testKnownAnswers() {
        // FIPS 180-4 examples: one block, an empty message, two blocks, and a long message.
        XCTAssertEqual(Hashing.hex(Hashing.sha256("abc")),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Hashing.hex(Hashing.sha256("")),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Hashing.hex(Hashing.sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(Hashing.hex(Hashing.sha256(String(repeating: "a", count: 1_000_000))),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testPaddingAroundTheBlockBoundary() {
        // 55, 56 and 64 bytes: the length field fits in the first block, needs a second, or fills one.
        XCTAssertEqual(Hashing.hex(Hashing.sha256(String(repeating: "a", count: 55))),
                       "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
        XCTAssertEqual(Hashing.hex(Hashing.sha256(String(repeating: "a", count: 56))),
                       "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
        XCTAssertEqual(Hashing.hex(Hashing.sha256(String(repeating: "a", count: 64))),
                       "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
    }
}
