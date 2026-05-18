import XCTest
import CryptoKit
@testable import SmartAccessCore

final class PolicyEnvelopeTests: XCTestCase {

    func testCanonicalDecodingAndSignatureRoundTrip() throws {
        let policyDict: [String: Any] = [
            "project_id": "customer_app",
            "version": 1,
            "issued_at": 1_760_000_000,
            "expires_at": Date().addingTimeInterval(3600).timeIntervalSince1970,
            "config_sources": [],
            "endpoints": [
                [
                    "id": "api-sg",
                    "url": "https://api-sg.example.com",
                    "kind": "http",
                    "role": "direct",
                    "health_path": "/healthy",
                    "priority": 1,
                    "enabled": true
                ]
            ],
            "ip_pools": [],
            "health_check": ["timeout_ms": 2000, "startup_max_wait_ms": 500, "parallel_limit": 3],
            "websocket_check": ["enabled": true, "timeout_ms": 3000],
            "retry": ["max_attempts": 2, "retry_methods": ["GET", "HEAD"]],
            "circuit_breaker": ["failure_threshold": 2, "open_seconds": 60]
        ]
        let canonical = try JSONSerialization.data(withJSONObject: policyDict, options: [.sortedKeys])

        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: canonical)

        let envelope: [String: Any] = [
            "policy": policyDict,
            "signature": signature.base64EncodedString()
        ]
        let envelopeData = try JSONSerialization.data(withJSONObject: envelope, options: [])

        let decoded = try PolicyEnvelope.decode(from: envelopeData)
        XCTAssertEqual(decoded.policy.projectId, "customer_app")
        XCTAssertEqual(decoded.policy.endpoints.first?.id, "api-sg")
        XCTAssertTrue(SignatureVerifier.verifyEd25519(
            data: decoded.canonicalPolicyBytes,
            signature: decoded.signature,
            publicKey: key.publicKey
        ))
    }
}
