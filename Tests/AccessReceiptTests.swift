import Foundation
import XCTest
@testable import TeveeStreaming
#if canImport(CryptoKit)
import CryptoKit
#endif

final class AccessReceiptTests: XCTestCase {
    func testSignedFixtureAndBoundaries() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "access-receipt", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let token = try XCTUnwrap(fixture["token"] as? String)
        let nonce = String(repeating: "a", count: 32)
        let verify: (Data, Data) -> Bool
        #if canImport(CryptoKit)
        let key = try P256.Signing.PublicKey(derRepresentation: XCTUnwrap(Data(base64Encoded: fixture["publicKey"] as! String)))
        verify = { data, signature in
            guard let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
            return key.isValidSignature(sig, for: data)
        }
        #else
        // Linux exercises parsing/binding; Java and macOS tests verify the real signature.
        verify = { _, _ in true }
        #endif
        XCTAssertEqual(try AccessReceipt.decode(token, account: "7", nonce: nonce, now: 1800000001, verify: verify).status, "authorized")
        XCTAssertThrowsError(try AccessReceipt.decode(token, account: "8", nonce: nonce, now: 1800000001, verify: verify))
        XCTAssertThrowsError(try AccessReceipt.decode(token, account: "7", nonce: String(repeating: "b", count: 32), now: 1800000001, verify: verify))
        XCTAssertThrowsError(try AccessReceipt.decode(token, account: "7", nonce: nonce, now: 1800003600, verify: verify))
        XCTAssertThrowsError(try AccessReceipt.decode(token, account: "7", nonce: nonce, now: 1799999900, verify: verify))
        XCTAssertThrowsError(try AccessReceipt.decode(token, account: "7", nonce: nonce, now: 1800000001, verify: { _, _ in false }))
        XCTAssertThrowsError(try AccessReceipt.decode("CSP1.bad!.bad!", account: "7", nonce: nonce, now: 1800000001, verify: verify))
    }
    func testInstallationBoundReceipts() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "access-device", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String])
        let nonce = fixture["nonce"]!, device = fixture["device"]!
        let verify: (Data, Data) -> Bool
        #if canImport(CryptoKit)
        let key = try P256.Signing.PublicKey(derRepresentation: XCTUnwrap(Data(base64Encoded: fixture["publicKey"]!)))
        verify = { data, signature in
            guard let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
            return key.isValidSignature(sig, for: data)
        }
        #else
        verify = { _, _ in true }
        #endif
        for status in ["authorized", "revoked", "join_required"] {
            let receipt = try AccessReceipt.decode(fixture[status]!, account: "7", nonce: nonce, now: 1800000001, device: device, verify: verify)
            XCTAssertEqual(receipt.status, status); XCTAssertEqual(receipt.revision, 3)
            XCTAssertEqual(receipt.missing, status == "join_required" ? [0] : [])
            XCTAssertThrowsError(try AccessReceipt.decode(fixture[status]!, account: "7", nonce: nonce, now: 1800000001, device: String(repeating: "d", count: 24), verify: verify))
        }
    }
}
