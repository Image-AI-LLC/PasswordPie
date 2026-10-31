import Foundation

/// Twofish-256 CBC decrypt. The block cipher follows the AES-submission reference:
/// external words are little-endian, and the round function uses the published q-boxes.
enum Twofish {
    static func cbcDecrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 32, iv.count == 16, data.count % 16 == 0, !data.isEmpty else {
            throw VaultOpenError.crypto("Twofish needs a 32-byte key and whole 16-byte blocks.")
        }
        let schedule = keySchedule(words(key))
        var previous = iv
        var plain = Data()
        var offset = 0
        while offset < data.count {
            let block = data.subdata(in: offset..<(offset + 16))
            let decrypted = bytes(decryptBlock(words(block), schedule))
            plain.append(xor(decrypted, previous))
            previous = block
            offset += 16
        }
        return try pkcs7Unpad(plain)
    }

    static func encryptBlock(_ block: Data, key: Data) -> Data {
        let schedule = keySchedule(words(key))
        return bytes(encryptBlock(words(block), schedule))
    }

    private struct Schedule {
        var k: [UInt32]
        var s: [UInt32]
        var width: Int
    }

    private static func encryptBlock(_ plain: [UInt32], _ schedule: Schedule) -> [UInt32] {
        var r = (0..<4).map { plain[$0] ^ schedule.k[$0] }
        for round in 0..<16 {
            let (f0, f1) = f(r[0], r[1], round, schedule)
            let right2 = ror(r[2] ^ f0, 1)
            let right3 = rol(r[3], 1) ^ f1
            r = [r[0], r[1], right2, right3]
            if round < 15 {
                r.swapAt(0, 2)
                r.swapAt(1, 3)
            }
        }
        let swapped = [r[2], r[3], r[0], r[1]]
        return (0..<4).map { swapped[($0 + 2) % 4] ^ schedule.k[$0 + 4] }
    }

    private static func decryptBlock(_ cipher: [UInt32], _ schedule: Schedule) -> [UInt32] {
        var r = (0..<4).map { cipher[$0] ^ schedule.k[$0 + 4] }
        for round in stride(from: 15, through: 0, by: -1) {
            let (f0, f1) = f(r[0], r[1], round, schedule)
            let right2 = rol(r[2], 1) ^ f0
            let right3 = ror(r[3] ^ f1, 1)
            r = [r[0], r[1], right2, right3]
            if round > 0 {
                r.swapAt(0, 2)
                r.swapAt(1, 3)
            }
        }
        let swapped = [r[2], r[3], r[0], r[1]]
        return (0..<4).map { swapped[($0 + 2) % 4] ^ schedule.k[$0] }
    }

    private static func f(_ r0: UInt32, _ r1: UInt32, _ round: Int, _ schedule: Schedule) -> (UInt32, UInt32) {
        let t0 = g(r0, schedule)
        let t1 = g(rol(r1, 8), schedule)
        let f0 = t0 &+ t1 &+ schedule.k[2 * round + 8]
        let f1 = t0 &+ (t1 &* 2) &+ schedule.k[2 * round + 9]
        return (f0, f1)
    }

    private static func g(_ x: UInt32, _ schedule: Schedule) -> UInt32 {
        h(x, schedule.s, schedule.width)
    }

    private static func keySchedule(_ keyWords: [UInt32]) -> Schedule {
        // Key bytes are loaded little-endian, then used as big-endian words by the key schedule.
        let keyWords = keyWords.map(\.byteSwapped)
        let width = keyWords.count / 2
        let me = stride(from: 0, to: keyWords.count, by: 2).map { keyWords[$0] }
        let mo = stride(from: 1, to: keyWords.count, by: 2).map { keyWords[$0] }
        var s: [UInt32] = []
        for index in 0..<width {
            let vector = beBytes(me[index]) + beBytes(mo[index])
            var product = matrixMultiply(rs, vector, modulus: rsModulus)
            product.reverse()
            s.insert(packBE(product), at: 0)
        }
        let rho: UInt32 = 0x01010101
        var subkeys: [UInt32] = []
        for index in 0..<(16 + 4) {
            let a = h(UInt32(2 * index) &* rho, me, width)
            var b = h(UInt32(2 * index + 1) &* rho, mo, width)
            b = rol(b, 8)
            subkeys.append(a &+ b)
            subkeys.append(rol(a &+ (b &* 2), 9))
        }
        return Schedule(k: subkeys, s: s, width: width)
    }

    private static let qOrder: [[[[Int]]]] = [
        [q1, q0, q1, q0],
        [q0, q0, q1, q1],
        [q0, q1, q0, q1],
        [q1, q1, q0, q0],
        [q1, q0, q0, q1]
    ]

    private static func h(_ x: UInt32, _ material: [UInt32], _ width: Int) -> UInt32 {
        var y = Array(beBytes(x).reversed())
        let rows = material.map(beBytes)
        if width > 0 {
            for index in stride(from: width - 1, through: 0, by: -1) {
                for byte in 0..<4 {
                    y[byte] = qPermute(y[byte], qOrder[index + 1][byte]) ^ rows[index][byte]
                }
            }
        }
        for byte in 0..<4 {
            y[byte] = qPermute(y[byte], qOrder[0][byte])
        }
        return packBE(matrixMultiply(mds, y, modulus: mdsModulus))
    }

    private static func qPermute(_ x: UInt8, _ table: [[Int]]) -> UInt8 {
        let a0 = Int(x) / 16
        let b0 = Int(x) % 16
        let a1 = a0 ^ b0
        let b1 = (a0 ^ ror4(b0, 1) ^ (8 * a0)) % 16
        let a2 = table[0][a1]
        let b2 = table[1][b1]
        let a3 = a2 ^ b2
        let b3 = (a2 ^ ror4(b2, 1) ^ (8 * a2)) % 16
        let a4 = table[2][a3]
        let b4 = table[3][b3]
        return UInt8(16 * b4 + a4)
    }

    private static func ror4(_ x: Int, _ n: Int) -> Int {
        let x = x & 0xf
        return ((x >> n) | ((x & ((1 << n) - 1)) << (4 - n))) & 0xf
    }

    private static func matrixMultiply(_ matrix: [[Int]], _ vector: [UInt8], modulus: Int) -> [UInt8] {
        var result: [UInt8] = []
        for row in matrix {
            var mixed = 0
            for column in 0..<vector.count {
                mixed ^= gfMultiply(row[column], Int(vector[column]), modulus)
            }
            result.insert(UInt8(mixed), at: 0)
        }
        return result
    }

    private static func gfMultiply(_ a: Int, _ b: Int, _ modulus: Int) -> Int {
        var left = a
        var right = b
        var product = 0
        while left != 0 {
            if left & 1 != 0 { product ^= right }
            right <<= 1
            left >>= 1
        }
        var reducer = modulus << 7
        for _ in 0..<8 {
            let reduced = product ^ reducer
            if reduced < product { product = reduced }
            reducer >>= 1
        }
        return product
    }

    private static func beBytes(_ word: UInt32) -> [UInt8] {
        [UInt8(word >> 24), UInt8((word >> 16) & 0xff), UInt8((word >> 8) & 0xff), UInt8(word & 0xff)]
    }

    private static func packBE(_ bytes: [UInt8]) -> UInt32 {
        bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func words(_ data: Data) -> [UInt32] {
        stride(from: 0, to: data.count, by: 4).map { offset in
            UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
        }
    }

    private static func bytes(_ words: [UInt32]) -> Data {
        var data = Data(capacity: words.count * 4)
        for word in words {
            data.append(UInt8(word & 0xff))
            data.append(UInt8((word >> 8) & 0xff))
            data.append(UInt8((word >> 16) & 0xff))
            data.append(UInt8(word >> 24))
        }
        return data
    }

    private static func xor(_ left: Data, _ right: Data) -> Data {
        Data(zip(left, right).map { $0 ^ $1 })
    }

    private static func pkcs7Unpad(_ data: Data) throws -> Data {
        guard let last = data.last, last > 0, last <= 16, data.count >= Int(last) else {
            throw VaultOpenError.crypto("Twofish padding is invalid.")
        }
        let pad = Int(last)
        guard data.suffix(pad).allSatisfy({ $0 == last }) else { throw VaultOpenError.crypto("Twofish padding is invalid.") }
        return data.prefix(data.count - pad)
    }

    private static func rol(_ x: UInt32, _ n: Int) -> UInt32 { (x << n) | (x >> (32 - n)) }
    private static func ror(_ x: UInt32, _ n: Int) -> UInt32 { (x >> n) | (x << (32 - n)) }

    private static let mdsModulus = 0x169
    private static let rsModulus = 0x14d
    private static let mds: [[Int]] = [
        [0x01, 0xEF, 0x5B, 0x5B],
        [0x5B, 0xEF, 0xEF, 0x01],
        [0xEF, 0x5B, 0x01, 0xEF],
        [0xEF, 0x01, 0xEF, 0x5B]
    ]
    private static let rs: [[Int]] = [
        [0x01, 0xA4, 0x55, 0x87, 0x5A, 0x58, 0xDB, 0x9E],
        [0xA4, 0x56, 0x82, 0xF3, 0x1E, 0xC6, 0x68, 0xE5],
        [0x02, 0xA1, 0xFC, 0xC1, 0x47, 0xAE, 0x3D, 0x19],
        [0xA4, 0x55, 0x87, 0x5A, 0x58, 0xDB, 0x9E, 0x03]
    ]
    private static let q0: [[Int]] = [
        [0x8, 0x1, 0x7, 0xD, 0x6, 0xF, 0x3, 0x2, 0x0, 0xB, 0x5, 0x9, 0xE, 0xC, 0xA, 0x4],
        [0xE, 0xC, 0xB, 0x8, 0x1, 0x2, 0x3, 0x5, 0xF, 0x4, 0xA, 0x6, 0x7, 0x0, 0x9, 0xD],
        [0xB, 0xA, 0x5, 0xE, 0x6, 0xD, 0x9, 0x0, 0xC, 0x8, 0xF, 0x3, 0x2, 0x4, 0x7, 0x1],
        [0xD, 0x7, 0xF, 0x4, 0x1, 0x2, 0x6, 0xE, 0x9, 0xB, 0x3, 0x0, 0x8, 0x5, 0xC, 0xA]
    ]
    private static let q1: [[Int]] = [
        [0x2, 0x8, 0xB, 0xD, 0xF, 0x7, 0x6, 0xE, 0x3, 0x1, 0x9, 0x4, 0x0, 0xA, 0xC, 0x5],
        [0x1, 0xE, 0x2, 0xB, 0x4, 0xC, 0x3, 0x7, 0x6, 0xD, 0xA, 0x5, 0xF, 0x9, 0x0, 0x8],
        [0x4, 0xC, 0x7, 0x5, 0x1, 0x6, 0x9, 0xA, 0x0, 0xE, 0xD, 0x8, 0x2, 0xB, 0x3, 0xF],
        [0xB, 0x9, 0x5, 0x1, 0xC, 0x3, 0xD, 0xE, 0x6, 0x4, 0x7, 0xF, 0x2, 0x0, 0x8, 0xA]
    ]
}
