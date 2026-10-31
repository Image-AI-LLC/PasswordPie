import Foundation
import CryptoKit

/// IETF ChaCha20 (RFC 8439). Counter 0 matches the KeePass inner stream.
struct ChaCha20 {
    private var state: [UInt32]
    private var keystream = [UInt8]()
    private var offset = 0

    init(key: Data, nonce: Data, counter: UInt32 = 0) {
        precondition(key.count == 32, "ChaCha20 key is 32 bytes")
        precondition(nonce.count == 12, "ChaCha20 nonce is 12 bytes")
        func word(_ data: Data, _ index: Int) -> UInt32 {
            let start = index * 4
            return UInt32(data[start])
                | (UInt32(data[start + 1]) << 8)
                | (UInt32(data[start + 2]) << 16)
                | (UInt32(data[start + 3]) << 24)
        }
        state = [
            0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,
            word(key, 0), word(key, 1), word(key, 2), word(key, 3),
            word(key, 4), word(key, 5), word(key, 6), word(key, 7),
            counter, word(nonce, 0), word(nonce, 1), word(nonce, 2)
        ]
    }

    mutating func xor(_ input: Data) -> Data {
        var output = Data(count: input.count)
        for index in 0..<input.count {
            if offset == keystream.count {
                refill()
            }
            output[index] = input[index] ^ keystream[offset]
            offset += 1
        }
        return output
    }

    private mutating func refill() {
        var working = state
        for _ in 0..<10 {
            quarterRound(&working, 0, 4, 8, 12)
            quarterRound(&working, 1, 5, 9, 13)
            quarterRound(&working, 2, 6, 10, 14)
            quarterRound(&working, 3, 7, 11, 15)
            quarterRound(&working, 0, 5, 10, 15)
            quarterRound(&working, 1, 6, 11, 12)
            quarterRound(&working, 2, 7, 8, 13)
            quarterRound(&working, 3, 4, 9, 14)
        }
        var block = [UInt8]()
        block.reserveCapacity(64)
        for index in 0..<16 {
            let value = working[index] &+ state[index]
            block.append(UInt8(truncatingIfNeeded: value))
            block.append(UInt8(truncatingIfNeeded: value >> 8))
            block.append(UInt8(truncatingIfNeeded: value >> 16))
            block.append(UInt8(truncatingIfNeeded: value >> 24))
        }
        keystream = block
        offset = 0
        state[12] = state[12] &+ 1
    }
}

private func quarterRound(_ state: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
    state[a] = state[a] &+ state[b]
    state[d] ^= state[a]
    state[d] = (state[d] << 16) | (state[d] >> 16)
    state[c] = state[c] &+ state[d]
    state[b] ^= state[c]
    state[b] = (state[b] << 12) | (state[b] >> 20)
    state[a] = state[a] &+ state[b]
    state[d] ^= state[a]
    state[d] = (state[d] << 8) | (state[d] >> 24)
    state[c] = state[c] &+ state[d]
    state[b] ^= state[c]
    state[b] = (state[b] << 7) | (state[b] >> 25)
}

func sha512SplitKey(protectedStreamKey: Data) -> (key: Data, nonce: Data) {
    let digest = [UInt8](SHA512.hash(data: protectedStreamKey))
    return (Data(digest.prefix(32)), Data(digest.dropFirst(32).prefix(12)))
}
