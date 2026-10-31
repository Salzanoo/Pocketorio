// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see ../Madeira/LICENSES/LICENSE-EXCEPTION.md
//
// The developer certificate the app signs the downloaded game with
// (probe/patcher/CodeSigner.swift). iOS loads only code signed by the app's own
// team, so this is the certificate the app itself is signed with: the one
// SideStore or Xcode uses, exported as a .p12 with its private key. It is kept
// in this app's Keychain and never leaves the device. A free account's
// certificate lasts a year; the app's own 7-day profile doesn't matter here.

import Foundation
import Security
import SwiftUI
import UniformTypeIdentifiers

enum GameCertificate {
    struct Info: Equatable {
        let name: String
        let team: String?
        let issuer: String
        /// SHA-256 of the certificate, to tell when the game was signed with another one.
        let fingerprint: String
    }

    struct CertificateError: Error, CustomStringConvertible { let description: String }

    private static let label = "Factoriduo game signing"

    static func importP12(_ data: Data, password: String) throws {
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else {
            throw CertificateError(description: status == errSecAuthFailed ? "Wrong password for the certificate." : "Not a certificate with its private key (\(status)).")
        }
        remove()
        let add: [String: Any] = [kSecValueRef as String: identity as! SecIdentity, kSecAttrLabel as String: label]
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess || added == errSecDuplicateItem else {
            throw CertificateError(description: "Couldn't keep the certificate (\(added)).")
        }
        guard info != nil else { throw CertificateError(description: "The certificate was imported but can't be read back.") }
    }

    static func remove() {
        for kind in [kSecClassIdentity, kSecClassCertificate, kSecClassKey] {
            SecItemDelete([kSecClass as String: kind, kSecAttrLabel as String: label] as CFDictionary)
        }
    }

    static var identity: SecIdentity? {
        // By label first; any identity in this app's keychain otherwise (it keeps only this one).
        for labelled in [true, false] {
            var query: [String: Any] = [kSecClass as String: kSecClassIdentity,
                                        kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            if labelled { query[kSecAttrLabel as String] = label }
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let result {
                return (result as! SecIdentity)
            }
        }
        return nil
    }

    private static var certificate: SecCertificate? {
        guard let identity else { return nil }
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)
        return certificate
    }

    static var info: Info? {
        guard let certificate else { return nil }
        let der = [UInt8](SecCertificateCopyData(certificate) as Data)
        let parsed = try? DER.Certificate(der)
        let name = parsed?.commonName ?? (SecCertificateCopySubjectSummary(certificate) as String?) ?? "Certificate"
        return Info(name: name, team: parsed?.organizationalUnit,
                    issuer: [parsed?.issuerCommonName, parsed?.issuerOrganizationalUnit].compactMap { $0 }.joined(separator: " "),
                    fingerprint: Hashing.sha256(der).map { String(format: "%02x", $0) }.joined())
    }

    /// Apple's intermediate that issued the certificate, then Apple's root. G3 is
    /// built in; another generation is fetched from apple.com once and kept.
    static func chain(for certificate: DER.Certificate) throws -> [[UInt8]] {
        let generation = certificate.issuerOrganizationalUnit ?? "G3"
        if generation == "G3" { return AppleCertificates.chain }
        let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Factoriduo/AppleWWDRCA\(generation).cer")
        if let kept = try? Data(contentsOf: cache) { return [[UInt8](kept), AppleCertificates.root] }
        guard let url = AppleCertificates.intermediateURL(generation: generation) else {
            throw CertificateError(description: "The certificate's issuer (\(certificate.issuerCommonName ?? "?") \(generation)) isn't one of Apple's WWDR authorities.")
        }
        // Synchronous: this runs off the main thread, while preparing the game.
        var fetched: Data?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { fetched = data }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 30)
        guard let fetched, let parsed = try? DER.Certificate([UInt8](fetched)), parsed.organizationalUnit == generation else {
            throw CertificateError(description: "Couldn't get Apple's WWDR \(generation) certificate from apple.com.")
        }
        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fetched.write(to: cache)
        return [[UInt8](fetched), AppleCertificates.root]
    }

    /// A signer for the game library, with the private key used in the Keychain.
    static func signer(identifier: String) throws -> CodeSigner {
        guard let identity, let certificate else { throw CertificateError(description: "Import your signing certificate first.") }
        var key: SecKey?
        SecIdentityCopyPrivateKey(identity, &key)
        guard let key else { throw CertificateError(description: "The certificate has no private key.") }
        let parsed = try DER.Certificate([UInt8](SecCertificateCopyData(certificate) as Data))
        let chain = try chain(for: parsed)
        SteamLog.event("[game-sign] certificate=\(parsed.commonName ?? "?") team=\(parsed.organizationalUnit ?? "?") issuer=\(parsed.issuerCommonName ?? "?") \(parsed.issuerOrganizationalUnit ?? "")")
        return CodeSigner(identifier: identifier, certificate: parsed, chain: chain) { message in
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(message) as CFData, &error) else {
                throw error?.takeRetainedValue() ?? CertificateError(description: "Signing failed.")
            }
            return [UInt8](signature as Data)
        }
    }
}

// MARK: - Settings section

struct GameCertificateSection: View {
    let title: String

    init(title: String = "Signing") { self.title = title }
    @State private var info = GameCertificate.info
    @State private var importing = false
    @State private var file: Data?
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        Section {
            if let info {
                LabeledContent("Certificate", value: info.name)
                if let team = info.team { LabeledContent("Team", value: team) }
                LabeledContent("Issued by", value: info.issuer)
                Button("Remove certificate", role: .destructive) {
                    GameCertificate.remove()
                    self.info = nil
                }
            } else if file != nil {
                SecureField("Certificate password", text: $password)
                Button("Import") {
                    do {
                        try GameCertificate.importP12(file!, password: password)
                        info = GameCertificate.info
                        file = nil; password = ""; error = nil
                    } catch let failure {
                        error = "\(failure)"
                    }
                }
                Button("Cancel", role: .cancel) { file = nil; password = "" }
            } else {
                Button("Import signing certificate…") { importing = true }
            }
            if let error { Text(error).foregroundStyle(.red) }
        } header: {
            Text(title)
        } footer: {
            Text("The certificate this app is signed with, as a .p12 with its private key: export it from SideStore, or from Keychain Access on the Mac you install from with Xcode. The app signs the downloaded game with it, because iOS only runs code signed by the app's own team. It stays in this app's keychain.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "p12") ?? .data, .data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { file = try Data(contentsOf: url); error = nil } catch let failure { error = "\(failure)" }
        }
    }
}
