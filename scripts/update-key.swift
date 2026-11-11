import Foundation
import CryptoKit

// Compare the supplied CI key with the public key embedded in released apps.
// Private material arrives only on stdin and is never printed or written.
do {
    guard CommandLine.arguments.count == 2,
          let seed = Data(base64Encoded: String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw NSError(domain: "UpdateKey", code: 1)
    }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    let expected = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard key.publicKey.rawRepresentation.base64EncodedString() == expected else {
        throw NSError(domain: "UpdateKey", code: 2)
    }
} catch {
    fputs("Update signing key does not match the embedded public key.\n", stderr)
    exit(1)
}
