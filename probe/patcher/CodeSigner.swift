// SPDX-License-Identifier: MIT
//
// Signs a Mach-O library with a developer certificate, on the device, so the app
// can load the downloaded game (iOS loads only code signed by the app's own
// team). The signature is laid out as codesign makes it for a library on a
// current iOS (and ZSign in its SHA-256-only mode):
//   - a SuperBlob with one SHA-256 CodeDirectory, the designated requirement
//     ZSign writes, and a CMS signature. (A SHA-1 CodeDirectory with a SHA-256 alternate, ZSign's
//     default, is rejected by codesign for this platform: it verifies the CMS
//     against the SHA-256 directory.)
//   - CodeDirectory version 0x20400, 4 KB pages, the identifier (the app's own
//     bundle ID, which amfid matches against the app's profile) and Team ID,
//     special slots for the requirements and (empty) Info.plist, __TEXT as the
//     executable segment;
//   - CMS: detached SignedData over the CodeDirectory, SHA-256 digest, RSA
//     PKCS#1 v1.5, with Apple's cdhashes attributes (100.9.1: a plist of the
//     CodeDirectory hash cut to 20 bytes; 100.9.2: the hash in full), and the
//     developer certificate with Apple's WWDR CA and root.
// The RSA signature itself comes from `sign`, so the key can stay in the
// Keychain (SecKeyCreateSignature) on iOS, and tests can use openssl.

import Foundation

struct CodeSigner {
    let identifier: String
    let certificate: DER.Certificate
    let chain: [[UInt8]]
    /// RSA PKCS#1 v1.5 with SHA-256 over the given bytes.
    let rsaSign: ([UInt8]) throws -> [UInt8]
    var signingTime = Date()

    static let pageShift = 12
    static let cmsReserve = 16 * 1024

    var teamID: String? { certificate.organizationalUnit }

    // MARK: Big-endian blobs

    private static func be32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * (3 - $0))) } }
    private static func be64(_ value: Int) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * (7 - $0))) } }

    /// The designated requirement ZSign writes (and LiveContainer's signatures
    /// carry): identifier "<id>" and anchor apple generic and
    /// certificate leaf[subject.CN] = "<CN>" and
    /// certificate 1[field.1.2.840.113635.100.6.2.1] exists. An empty set without a CN.
    var requirements: [UInt8] {
        guard let cn = certificate.commonName else { return Self.be32(0xfade_0c01) + Self.be32(12) + Self.be32(0) }
        func padded(_ text: String) -> [UInt8] {
            var bytes = Array(text.utf8)
            while bytes.count % 4 != 0 { bytes.append(0) }
            return bytes
        }
        let andIdent: [UInt8] = [0, 0, 0, 1, 0, 0, 0, 6, 0, 0, 0, 2]   // expression form; and; identifier
        let anchorAndLeafCN: [UInt8] = [0, 0, 0, 6, 0, 0, 0, 0x0f, 0, 0, 0, 6, 0, 0, 0, 0x0b, 0, 0, 0, 0, 0, 0, 0, 0x0a,
                                        0x73, 0x75, 0x62, 0x6a, 0x65, 0x63, 0x74, 0x2e, 0x43, 0x4e, 0, 0, 0, 0, 0, 1]
        let intermediateMarker: [UInt8] = [0, 0, 0, 0x0e, 0, 0, 0, 1, 0, 0, 0, 0x0a,
                                           0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x06, 0x02, 0x01, 0, 0, 0, 0, 0, 0]
        var expression = andIdent + Self.be32(identifier.utf8.count) + padded(identifier)
        expression += anchorAndLeafCN + Self.be32(cn.utf8.count) + padded(cn) + intermediateMarker
        let requirement = Self.be32(0xfade_0c00) + Self.be32(8 + expression.count) + expression
        return Self.be32(0xfade_0c01) + Self.be32(8 + 12 + requirement.count) + [0, 0, 0, 1, 0, 0, 0, 3, 0, 0, 0, 0x14] + requirement
    }

    /// A CodeDirectory over `code` (the file up to the signature).
    func codeDirectory(_ code: ArraySlice<UInt8>, sha256: Bool, execSegLimit: Int) -> [UInt8] {
        let hash: (ArraySlice<UInt8>) -> [UInt8] = sha256 ? { Hashing.sha256($0) } : { Hashing.sha1($0) }
        let hashSize = sha256 ? 32 : 20
        let page = 1 << Self.pageShift
        let ident = Array(identifier.utf8) + [0]
        let team: [UInt8] = teamID.map { Array($0.utf8) + [0] } ?? []
        let special = [hash(ArraySlice(requirements)), [UInt8](repeating: 0, count: hashSize)]   // slots -2, -1
        let slots = (code.count + page - 1) / page
        let header = 88
        let hashOffset = header + ident.count + team.count + special.count * hashSize
        let length = hashOffset + slots * hashSize
        var cd: [UInt8] = []
        cd.reserveCapacity(length)
        cd += Self.be32(0xfade_0c02) + Self.be32(length) + Self.be32(0x20400) + Self.be32(0)
        cd += Self.be32(hashOffset) + Self.be32(header) + Self.be32(special.count) + Self.be32(slots)
        cd += Self.be32(code.count)
        cd += [UInt8(hashSize), sha256 ? 2 : 1, 0, UInt8(Self.pageShift)] + Self.be32(0)
        cd += Self.be32(0)                                        // scatterOffset
        cd += Self.be32(team.isEmpty ? 0 : header + ident.count)  // teamOffset
        cd += Self.be32(0) + Self.be64(0)                         // spare3, codeLimit64
        cd += Self.be64(0) + Self.be64(execSegLimit) + Self.be64(0)   // execSeg base, limit, flags (a library: none)
        cd += ident + team
        for slot in special { cd += slot }
        var at = code.startIndex
        while at < code.endIndex {
            let end = min(at + page, code.endIndex)
            cd += hash(code[at ..< end])
            at = end
        }
        return cd
    }

    // MARK: CMS

    func cms(codeDirectory: [UInt8]) throws -> [UInt8] {
        let sha256OID = DER.oid("2.16.840.1.101.3.4.2.1")
        let sha256Algorithm = DER.sequence([sha256OID, DER.null])   // with NULL parameters, as codesign writes it
        let dataOID = DER.oid("1.2.840.113549.1.7.1")
        let cdhash256 = Hashing.sha256(codeDirectory)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["cdhashes": [Data(cdhash256.prefix(20))]],
                                                       format: .xml, options: 0)
        func attribute(_ oid: String, _ value: [UInt8]) -> [UInt8] { DER.sequence([DER.oid(oid), DER.set([value])]) }
        let attributes = [
            attribute("1.2.840.113549.1.9.3", dataOID),                                     // contentType
            attribute("1.2.840.113549.1.9.5", DER.utcTime(signingTime)),                    // signingTime
            attribute("1.2.840.113549.1.9.4", DER.octetString(Hashing.sha256(codeDirectory))), // messageDigest
            attribute("1.2.840.113635.100.9.1", DER.octetString([UInt8](plist))),
            attribute("1.2.840.113635.100.9.2", DER.sequence([sha256OID, DER.octetString(cdhash256)])),
        ]
        let signedAttributes = DER.set(attributes)   // what is signed: the SET, with its own tag
        let signature = try rsaSign(signedAttributes)
        let signerInfo = DER.sequence([
            DER.integer(1),
            DER.sequence([certificate.issuer, certificate.serial]),
            sha256Algorithm,
            Array([0xa0] + signedAttributes.dropFirst()),   // [0] IMPLICIT: the same content
            DER.sequence([DER.oid("1.2.840.113549.1.1.1"), DER.null]),
            DER.octetString(signature),
        ])
        let signedData = DER.sequence([
            DER.integer(1),
            DER.set([sha256Algorithm]),
            DER.sequence([dataOID]),
            // [0] IMPLICIT SET OF: sorted, as DER requires (OpenSSL sorts it too; Apple's parser is strict).
            DER.context(0, ([certificate.encoded] + chain).sorted { $0.lexicographicallyPrecedes($1) }.flatMap { $0 }),
            DER.set([signerInfo]),
        ])
        return DER.sequence([DER.oid("1.2.840.113549.1.7.2"), DER.context(0, signedData)])
    }

    // MARK: Signing

    /// `input` with an LC_CODE_SIGNATURE and the signature appended.
    func sign(_ input: [UInt8]) throws -> [UInt8] {
        let image = try MachOFile(bytes: input)
        guard image.command(0x1d) == nil else { throw MachOError("Already signed") }
        guard GameLibrary.freeAfterLoadCommands(input, sections: image.sections) >= 16 else {
            throw MachOError("No room for LC_CODE_SIGNATURE")
        }
        let segments = image.commands.filter { $0.cmd == 0x19 }
        guard let linkedit = segments.first(where: { input.fixedString($0.offset + 8, 16) == "__LINKEDIT" }),
              let text = segments.first(where: { input.fixedString($0.offset + 8, 16) == "__TEXT" }) else {
            throw MachOError("No __TEXT or __LINKEDIT")
        }
        guard linkedit.offset == segments.last?.offset else { throw MachOError("__LINKEDIT is not the last segment") }

        var data = input
        let dataoff = (data.count + 15) & ~15
        data += [UInt8](repeating: 0, count: dataoff - data.count)
        // Sizes are known before hashing, except the CMS blob's: it gets a fixed reserve.
        let pages = (dataoff + (1 << Self.pageShift) - 1) >> Self.pageShift
        let identLength = identifier.utf8.count + 1 + (teamID.map { $0.utf8.count + 1 } ?? 0)
        let cdLength = 88 + identLength + 2 * 32 + pages * 32
        let superHeader = 12 + 3 * 8
        let total = superHeader + cdLength + requirements.count + 8 + Self.cmsReserve

        // LC_CODE_SIGNATURE, and __LINKEDIT grown over the signature.
        let commandsEnd = 32 + data.int32(20)
        data.replaceSubrange(commandsEnd ..< commandsEnd + 16, with: Self.le32(0x1d) + Self.le32(16) + Self.le32(dataoff) + Self.le32(total))
        data.put32(int: data.int32(16) + 1, at: 16)
        data.put32(int: data.int32(20) + 16, at: 20)
        let leoff = data.int64(linkedit.offset + 40)
        data.put64(int: dataoff + total - leoff, at: linkedit.offset + 48)
        data.put64(int: (dataoff + total - leoff + 0x3fff) & ~0x3fff, at: linkedit.offset + 32)

        let code = data[0 ..< dataoff]
        let execSegLimit = data.int64(text.offset + 48)
        let cd = codeDirectory(code, sha256: true, execSegLimit: execSegLimit)
        precondition(cd.count == cdLength)
        let cmsBlob = try cms(codeDirectory: cd)
        guard cmsBlob.count + 8 <= 8 + Self.cmsReserve else { throw MachOError("CMS signature larger than its reserve") }

        let wrapper = Self.be32(0xfade_0b01) + Self.be32(8 + cmsBlob.count) + cmsBlob
        var offset = superHeader
        var index: [UInt8] = []
        for (type, blob) in [(0, cd), (2, requirements), (0x10000, wrapper)] {
            index += Self.be32(type) + Self.be32(offset)
            offset += blob.count
        }
        var superBlob = Self.be32(0xfade_0cc0) + Self.be32(offset) + Self.be32(3) + index
        superBlob += cd + requirements + wrapper
        superBlob += [UInt8](repeating: 0, count: total - superBlob.count)
        return data + superBlob
    }

    private static func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
}
