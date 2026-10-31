// SPDX-License-Identifier: MIT
//
// Just enough ASN.1 DER for the code signature's CMS blob (CodeSigner.swift):
// encoding the few types it uses, and reading a certificate's issuer, serial
// number and subject.

import Foundation

enum DER {
    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var n = count
        while n > 0 { bytes.insert(UInt8(n & 0xff), at: 0); n >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }
    static func sequence(_ items: [[UInt8]]) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    /// A SET OF, with its elements sorted as DER requires.
    static func set(_ items: [[UInt8]]) -> [UInt8] { tlv(0x31, items.sorted { $0.lexicographicallyPrecedes($1) }.flatMap { $0 }) }
    static func octetString(_ bytes: [UInt8]) -> [UInt8] { tlv(0x04, bytes) }
    static func integer(_ value: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var n = value
        repeat { bytes.insert(UInt8(n & 0xff), at: 0); n >>= 8 } while n > 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, bytes)
    }
    static let null: [UInt8] = [0x05, 0x00]
    /// [n] EXPLICIT, or IMPLICIT constructed when `implicit` (content is the inner value's content).
    static func context(_ n: UInt8, _ content: [UInt8]) -> [UInt8] { tlv(0xa0 | n, content) }

    static func oid(_ dotted: String) -> [UInt8] {
        let parts = dotted.split(separator: ".").compactMap { UInt64($0) }
        var bytes: [UInt8] = [UInt8(parts[0] * 40 + parts[1])]
        for part in parts.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(part & 0x7f)]
            var n = part >> 7
            while n > 0 { chunk.insert(UInt8(n & 0x7f) | 0x80, at: 0); n >>= 7 }
            bytes += chunk
        }
        return tlv(0x06, bytes)
    }

    static func utcTime(_ date: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let text = String(format: "%02d%02d%02d%02d%02d%02dZ", (c.year ?? 2000) % 100, c.month ?? 1, c.day ?? 1,
                          c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return tlv(0x17, Array(text.utf8))
    }

    // MARK: Reading

    struct Node {
        let tag: UInt8
        /// The whole encoding, tag and length included.
        let encoded: ArraySlice<UInt8>
        let content: ArraySlice<UInt8>

        var children: [Node] {
            var nodes: [Node] = []
            var at = content.startIndex
            while at < content.endIndex, let node = try? DER.read(content, at: at) {
                nodes.append(node)
                at = node.encoded.endIndex
            }
            return nodes
        }
    }

    static func read(_ bytes: ArraySlice<UInt8>, at start: Int) throws -> Node {
        guard start + 2 <= bytes.endIndex else { throw MachOError("DER: truncated") }
        let tag = bytes[start]
        var at = start + 1
        var count = Int(bytes[at]); at += 1
        if count & 0x80 != 0 {
            let width = count & 0x7f
            guard width > 0, width <= 4, at + width <= bytes.endIndex else { throw MachOError("DER: bad length") }
            count = 0
            for _ in 0..<width { count = count << 8 | Int(bytes[at]); at += 1 }
        }
        guard at + count <= bytes.endIndex else { throw MachOError("DER: truncated") }
        return Node(tag: tag, encoded: bytes[start ..< at + count], content: bytes[at ..< at + count])
    }

    /// The parts of a certificate the signer needs.
    struct Certificate {
        let encoded: [UInt8]
        let issuer: [UInt8]
        let serial: [UInt8]
        /// The subject's organizational unit: a developer certificate's Team ID.
        let organizationalUnit: String?
        let commonName: String?
        /// The issuer's common name and organizational unit (Apple's WWDR intermediates: "G3", "G4", ...).
        let issuerCommonName: String?
        let issuerOrganizationalUnit: String?

        init(_ der: [UInt8]) throws {
            encoded = der
            let certificate = try DER.read(ArraySlice(der), at: 0)
            guard let tbs = certificate.children.first else { throw MachOError("DER: not a certificate") }
            var fields = tbs.children
            if fields.first?.tag == 0xa0 { fields.removeFirst() }   // [0] version
            guard fields.count >= 6 else { throw MachOError("DER: short certificate") }
            serial = Array(fields[0].encoded)
            issuer = Array(fields[2].encoded)
            func names(_ name: Node) -> (cn: String?, ou: String?) {
                var ou: String?, cn: String?
                for rdn in name.children {
                    for attribute in rdn.children {
                        let parts = attribute.children
                        guard parts.count == 2 else { continue }
                        let value = String(decoding: parts[1].content, as: UTF8.self)
                        if Array(parts[0].encoded) == DER.oid("2.5.4.11") { ou = value }
                        if Array(parts[0].encoded) == DER.oid("2.5.4.3") { cn = value }
                    }
                }
                return (cn, ou)
            }
            let subject = names(fields[4]), issuerNames = names(fields[2])
            commonName = subject.cn
            organizationalUnit = subject.ou
            issuerCommonName = issuerNames.cn
            issuerOrganizationalUnit = issuerNames.ou
        }
    }

    /// The DER inside a PEM block.
    static func fromPEM(_ pem: String) -> [UInt8]? {
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: body).map { [UInt8]($0) }
    }
}
