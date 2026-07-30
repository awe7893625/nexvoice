import CryptoKit
import XCTest
@testable import NexVoice

final class LocalRuntimeContractTests: XCTestCase {
    func testManifestRequiresV2AndSHA256BuildIdentity() throws {
        let digest = String(repeating: "a", count: 64)
        let valid = Data(
            """
            {"schema":1,"contract_version":2,"runtime_build":"sha256:\(digest)"}
            """.utf8
        )
        XCTAssertEqual(
            LocalRuntimeContract.decodeManifest(valid),
            LocalRuntimeManifest(
                schema: 1,
                contractVersion: 2,
                runtimeBuild: "sha256:\(digest)"
            )
        )

        let legacy = Data(
            """
            {"schema":1,"contract_version":1,"runtime_build":"sha256:\(digest)"}
            """.utf8
        )
        XCTAssertNil(LocalRuntimeContract.decodeManifest(legacy))
        XCTAssertNil(
            LocalRuntimeContract.decodeManifest(
                Data("{\"schema\":1,\"contract_version\":2,\"runtime_build\":\"latest\"}".utf8)
            )
        )
    }

    func testHealthIdentityRequiresExplicitFields() throws {
        let digest = String(repeating: "b", count: 64)
        let instance = UUID().uuidString.lowercased()
        let data = Data(
            """
            {
              "status":"ok",
              "authenticated":true,
              "contract_version":2,
              "runtime_build":"sha256:\(digest)",
              "instance_id":"\(instance)",
              "owner_nonce":"owner",
              "parent_pid":123,
              "mlx_whisper_version":"0.4.2",
              "capabilities":["identity-v1","shutdown-v1"],
              "response_proof":"deadbeef"
            }
            """.utf8
        )
        let identity = try JSONDecoder().decode(LocalRuntimeIdentity.self, from: data)
        XCTAssertEqual(identity.instanceID, instance)
        XCTAssertEqual(identity.contractVersion, 2)
        XCTAssertTrue(identity.capabilities.contains("shutdown-v1"))
        XCTAssertEqual(identity.responseProof, "deadbeef")
    }

    // MARK: - P0-E: challenge-response never discloses the secret, and a
    // responder without it cannot forge a valid proof (port-squatter defense).

    private func makeIdentity(
        instanceID: String = UUID().uuidString.lowercased(),
        runtimeBuild: String = "sha256:" + String(repeating: "c", count: 64),
        ownerNonce: String = "owner-nonce",
        contractVersion: Int = 2,
        responseProof: String? = nil
    ) -> LocalRuntimeIdentity {
        LocalRuntimeIdentity(
            status: "ok",
            authenticated: true,
            contractVersion: contractVersion,
            runtimeBuild: runtimeBuild,
            instanceID: instanceID,
            ownerNonce: ownerNonce,
            parentPID: nil,
            mlxWhisperVersion: nil,
            capabilities: ["identity-v1", "shutdown-v1", "challenge-response-v1"],
            responseProof: responseProof
        )
    }

    func testGenuineResponderProofVerifiesAgainstTheSameSecretAndNonce() {
        let secret = "shared-secret-value"
        let nonce = LocalRuntimeChallenge.nonce()
        let identity = makeIdentity()
        let message = LocalRuntimeChallenge.healthResponseMessage(nonce: nonce, identity: identity)
        // The real runtime signs with the secret it read from the same 0600
        // file the client trusts; simulate that here without a live server.
        let proof = signForTest(secret: secret, message: message)
        XCTAssertTrue(LocalRuntimeChallenge.verify(proofBase64: proof, secret: secret, message: message))
    }

    func testPortSquatterWithoutTheSecretCannotForgeAPlausibleIdentity() {
        let realSecret = "shared-secret-value"
        let nonce = LocalRuntimeChallenge.nonce()
        // A squatter without file access to the token guesses a different
        // secret (or fabricates any proof string) while presenting an
        // otherwise well-formed identity (valid build hash, valid UUID,
        // non-empty owner nonce, all expected capabilities).
        let fabricatedIdentity = makeIdentity(responseProof: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
        let message = LocalRuntimeChallenge.healthResponseMessage(nonce: nonce, identity: fabricatedIdentity)
        XCTAssertFalse(
            LocalRuntimeChallenge.verify(
                proofBase64: fabricatedIdentity.responseProof, secret: realSecret, message: message
            )
        )

        // Even if the squatter somehow signs with the *wrong* secret, the
        // client (which only trusts its own copy of the real secret) rejects it.
        let wrongSecretProof = signForTest(secret: "guessed-secret", message: message)
        XCTAssertFalse(
            LocalRuntimeChallenge.verify(proofBase64: wrongSecretProof, secret: realSecret, message: message)
        )
    }

    func testTamperedIdentityFieldsInvalidateAGenuinelySignedProof() {
        let secret = "shared-secret-value"
        let nonce = LocalRuntimeChallenge.nonce()
        let identity = makeIdentity()
        let genuineMessage = LocalRuntimeChallenge.healthResponseMessage(nonce: nonce, identity: identity)
        let proof = signForTest(secret: secret, message: genuineMessage)

        // A man-in-the-middle (or a squatter replaying a captured proof for a
        // different instance) cannot reuse this proof once any bound field changes.
        let mutated = makeIdentity(instanceID: UUID().uuidString.lowercased(), responseProof: proof)
        let mutatedMessage = LocalRuntimeChallenge.healthResponseMessage(nonce: nonce, identity: mutated)
        XCTAssertFalse(LocalRuntimeChallenge.verify(proofBase64: proof, secret: secret, message: mutatedMessage))
    }

    func testMissingResponseProofIsRejected() {
        XCTAssertFalse(
            LocalRuntimeChallenge.verify(proofBase64: nil, secret: "shared-secret-value", message: "health\nx")
        )
    }

    /// Mirrors LocalRuntimeChallenge's private `sign` for test-side "server" simulation.
    private func signForTest(secret: String, message: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(code).base64EncodedString()
    }
}
