import Testing
@testable import XKit

@Test func sanitizeStripsXToolPrefix() {
    #expect(
        ProvisioningIdentifiers.sanitize(identifier: "XTL-XBGS7H6Q6L.com.example.game")
            == "com.example.game"
    )
}

@Test func sanitizeLeavesPlainIdentifierUnchanged() {
    #expect(ProvisioningIdentifiers.sanitize(identifier: "com.example.game") == "com.example.game")
}
