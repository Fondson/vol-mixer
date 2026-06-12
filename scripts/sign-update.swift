#!/usr/bin/env swift
// Sign a file with the Ed25519 update key, writing the 64-byte detached
// signature to <file>.sig. The private key is read (base64) from the
// UPDATE_PRIVATE_KEY environment variable so it never touches disk or argv.
//
//   UPDATE_PRIVATE_KEY=… ./scripts/sign-update.swift "Volume.Mixer.app.zip"
import CryptoKit
import Foundation

guard let file = CommandLine.arguments.dropFirst().first else {
    FileHandle.standardError.write(Data("usage: sign-update.swift <file>\n".utf8))
    exit(2)
}
guard let b64 = ProcessInfo.processInfo.environment["UPDATE_PRIVATE_KEY"],
      let keyData = Data(base64Encoded: b64),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
    FileHandle.standardError.write(Data("UPDATE_PRIVATE_KEY is missing or not a valid base64 Ed25519 key\n".utf8))
    exit(1)
}
do {
    let data = try Data(contentsOf: URL(fileURLWithPath: file))
    let signature = try key.signature(for: data)
    try Data(signature).write(to: URL(fileURLWithPath: file + ".sig"))
    print("wrote \(file).sig (\(signature.count) bytes)")
} catch {
    FileHandle.standardError.write(Data("signing failed: \(error)\n".utf8))
    exit(1)
}
