// SPDX-License-Identifier: MIT
//
// SHA-1 and SHA-256 for the code signer (CodeSigner.swift): CryptoKit on Apple
// platforms, a plain Swift version elsewhere (Linux CI). Not named Digest, which
// CryptoKit already uses.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

enum Hashing {
    static func sha1<C: Collection>(_ bytes: C) -> [UInt8] where C.Element == UInt8 {
        #if canImport(CryptoKit)
        return withContiguous(bytes) { Array(Insecure.SHA1.hash(data: $0)) }
        #else
        return SoftSHA.sha1(Array(bytes))
        #endif
    }

    static func sha256<C: Collection>(_ bytes: C) -> [UInt8] where C.Element == UInt8 {
        #if canImport(CryptoKit)
        return withContiguous(bytes) { Array(SHA256.hash(data: $0)) }
        #else
        return SoftSHA.sha256(Array(bytes))
        #endif
    }

    #if canImport(CryptoKit)
    private static func withContiguous<C: Collection, R>(_ bytes: C, _ body: (UnsafeRawBufferPointer) -> R) -> R where C.Element == UInt8 {
        if let result = bytes.withContiguousStorageIfAvailable({ body(UnsafeRawBufferPointer($0)) }) { return result }
        return Array(bytes).withUnsafeBytes(body)
    }
    #endif
}

/// FIPS 180-4, for platforms without CryptoKit.
enum SoftSHA {
    private static func padded(_ message: [UInt8]) -> [UInt8] {
        var data = message
        let bits = UInt64(message.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for i in (0..<8).reversed() { data.append(UInt8(truncatingIfNeeded: bits >> (8 * UInt64(i)))) }
        return data
    }

    private static func word(_ data: [UInt8], _ at: Int) -> UInt32 {
        UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3])
    }

    private static func bytes(_ words: [UInt32]) -> [UInt8] {
        words.flatMap { w in [UInt8(w >> 24), UInt8(truncatingIfNeeded: w >> 16), UInt8(truncatingIfNeeded: w >> 8), UInt8(truncatingIfNeeded: w)] }
    }

    static func sha1(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6745_2301, 0xefcd_ab89, 0x98ba_dcfe, 0x1032_5476, 0xc3d2_e1f0]
        let data = padded(message)
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 { w[i] = word(data, chunk + 4 * i) }
            for i in 16..<80 {
                let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = (x << 1) | (x >> 31)
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5a82_7999
                case 20..<40: f = b ^ c ^ d; k = 0x6ed9_eba1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8f1b_bcdc
                default: f = b ^ c ^ d; k = 0xca62_c1d6
                }
                let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = temp
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d; h[4] = h[4] &+ e
        }
        return bytes(h)
    }

    private static let k256: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func sha256(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        let data = padded(message)
        var w = [UInt32](repeating: 0, count: 64)
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for chunk in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 { w[i] = word(data, chunk + 4 * i) }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k256[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return bytes(h)
    }
}
