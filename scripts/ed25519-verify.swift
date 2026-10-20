// Checks an EdDSA (Ed25519) signature of a file against a public key, as an
// installed copy of ClipShot checks an update. Used by scripts/sparkle-tools.sh
// when the release signs with a key file.
//
//   xcrun swift scripts/ed25519-verify.swift <public-key-base64> <file> <signature-base64>
//
// Exits 0 when the signature verifies, 1 when it does not, 2 on bad input.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4,
      let keyData = Data(base64Encoded: args[1]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
      let message = FileManager.default.contents(atPath: args[2]),
      let signature = Data(base64Encoded: args[3].trimmingCharacters(in: .whitespacesAndNewlines))
else {
    FileHandle.standardError.write(Data("usage: ed25519-verify.swift <public-key> <file> <signature>\n".utf8))
    exit(2)
}
exit(key.isValidSignature(signature, for: message) ? 0 : 1)
