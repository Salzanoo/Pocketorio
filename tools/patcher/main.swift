// SPDX-License-Identifier: MIT
//
// The on-device patcher (probe/patcher) as a command, for CI and the Mac:
//
//   swiftc -O probe/patcher/*.swift tools/patcher/main.swift -o build/patcher
//   build/patcher <factorio executable> <app Frameworks folder> <SDK version> <output>
//       [--expected-redirects N] [--compare <signed FactorioProbe>]
//   build/patcher sign <input> <output> --certificate <cert.der> --key <key.pem> [--library <name>]
//
// It writes what build_probe.py writes before codesign and prints the report.
// --compare checks the result against an app's signed executable.

import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())

// patcher sign <input> <output> --certificate <cert.der> --key <key.pem> [--library <install name>]
//     [--identifier <id>]: probe/patcher/CodeSigner.swift (and GameLibrary.swift with
// --library), with openssl doing the RSA signature, for tests/test_code_signer.py.
if arguments.first == "sign" {
    var options: [String: String] = [:]
    var rest: [String] = []
    var i = 1
    while i < arguments.count {
        if arguments[i].hasPrefix("--"), i + 1 < arguments.count { options[arguments[i]] = arguments[i + 1]; i += 2 }
        else { rest.append(arguments[i]); i += 1 }
    }
    guard rest.count == 2, let certificatePath = options["--certificate"] ?? options["--unsigned"], let key = options["--key"] ?? options["--unsigned"] else {
        fail("usage: patcher sign <input> <output> --certificate <cert.der> --key <key.pem> [--library <install name>] [--identifier <id>]")
    }
    do {
        var bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: rest[0])))
        if let name = options["--library"] { bytes = try GameLibrary.make(bytes, installName: name) }
        if options["--unsigned"] != nil {   // the library only, for comparing with codesign's signature
            try Data(bytes).write(to: URL(fileURLWithPath: rest[1]))
            exit(0)
        }
        let certificate = try DER.Certificate([UInt8](try Data(contentsOf: URL(fileURLWithPath: certificatePath))))
        let signer = CodeSigner(identifier: options["--identifier"] ?? "com.factoriduo.game", certificate: certificate,
                                chain: AppleCertificates.chain) { message in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let input = folder.appendingPathComponent("in"), output = folder.appendingPathComponent("sig")
            try Data(message).write(to: input)
            let openssl = Process()
            openssl.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            openssl.arguments = ["openssl", "dgst", "-sha256", "-sign", key, "-out", output.path, input.path]
            try openssl.run()
            openssl.waitUntilExit()
            guard openssl.terminationStatus == 0 else { throw MachOError("openssl failed") }
            return [UInt8](try Data(contentsOf: output))
        }
        let signed = try signer.sign(bytes)
        try Data(signed).write(to: URL(fileURLWithPath: rest[1]))
        exit(0)
    } catch {
        fail("\(error)")
    }
}
var expected: Int?
var compare: String?
while let flag = arguments.firstIndex(where: { $0.hasPrefix("--") }) {
    guard flag + 1 < arguments.count else { fail("\(arguments[flag]) needs a value") }
    switch arguments[flag] {
    case "--expected-redirects": expected = Int(arguments[flag + 1])
    case "--compare": compare = arguments[flag + 1]
    default: fail("Unknown option \(arguments[flag])")
    }
    arguments.removeSubrange(flag ... flag + 1)
}
guard arguments.count == 4 else {
    fail("usage: patcher <factorio executable> <Frameworks folder> <SDK version> <output> [--expected-redirects N] [--compare <signed executable>]")
}

do {
    let frameworks = URL(fileURLWithPath: arguments[1])
    let sdl3 = frameworks.appendingPathComponent("libSDL3.dylib")
    let sdlMajor = FileManager.default.fileExists(atPath: sdl3.path) ? 3 : 2
    let sdl = sdlMajor == 3 ? sdl3 : frameworks.appendingPathComponent("libSDL2.dylib")
    let host = GamePatcher.Host(
        sdlExports: try GamePatcher.exports(MachOFile(file: Data(contentsOf: sdl))),
        shimSymbols: try GamePatcher.defined(MachOFile(file: Data(contentsOf: frameworks.appendingPathComponent("ProbeShim.dylib")))),
        sdlMajor: sdlMajor, sdk: try MachOFile.packedVersion(arguments[2]), platform: 2, expectedRedirects: expected)
    let game = try MachOFile(file: Data(contentsOf: URL(fileURLWithPath: arguments[0]), options: .alwaysMapped))
    let (bytes, report) = try GamePatcher.patch(game, host: host)
    let output = URL(fileURLWithPath: arguments[3])
    try Data(bytes).write(to: output)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: output.path)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(report), as: UTF8.self))
    if let compare {
        let signed = try MachOFile(file: Data(contentsOf: URL(fileURLWithPath: compare))).data
        if let difference = try GamePatcher.difference(bytes, signed: signed) { fail("Differs from \(compare): \(difference)") }
        print("Matches \(compare)")
    }
} catch {
    fail("\(error)")
}
