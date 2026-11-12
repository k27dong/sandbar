import AppKit
import SandbarCore
import SandbarTestSupport
import SandbarUI
import Testing

@Suite(.serialized) struct SignInTests {
    @Test func theKeychainKeepsAValueUntilItIsDeleted() throws {
        let name = "test-\(UUID().uuidString)"
        defer { #expect(throws: Never.self) { try Keychain.delete(name) } }
        #expect(try Keychain.read(name) == nil)

        try Keychain.write("first-made-up-value", as: name)
        #expect(try Keychain.read(name) == "first-made-up-value")

        try Keychain.write("second-made-up-value", as: name)
        #expect(try Keychain.read(name) == "second-made-up-value")

        try Keychain.delete(name)
        #expect(try Keychain.read(name) == nil)
    }
}
