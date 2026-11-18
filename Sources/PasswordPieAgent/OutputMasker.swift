import Foundation

/// Replaces every exact occurrence of the values a command was given with `[concealed by PasswordPie]`, in a stream that
/// arrives in pieces. A value split across two pieces is still caught: the end of a piece that could be the start of a
/// value is held until the next piece says whether it is. Values shorter than `AgentConstants.minimumMaskedLength` are not
/// masked (`skipped` counts them), and transformed values (base64, a substring, URL-encoded) are not caught.
public struct OutputMasker {
    private let values: [[UInt8]]
    private let firstBytes: Set<UInt8>
    private let concealed = Array(AgentConstants.concealed.utf8)
    private var held: [UInt8] = []
    /// How many values were replaced so far.
    public private(set) var concealedCount = 0
    /// Values too short to mask.
    public let skipped: Int

    public init(values: [Data], minimumLength: Int = AgentConstants.minimumMaskedLength) {
        var unique: [[UInt8]] = []
        var short = 0
        for value in values {
            let bytes = Array(value)
            if bytes.count < minimumLength {
                if !bytes.isEmpty { short += 1 }
                continue
            }
            if !unique.contains(bytes) { unique.append(bytes) }
        }
        self.values = unique.sorted { $0.count > $1.count }
        firstBytes = Set(unique.compactMap(\.first))
        skipped = short
    }

    public var isEmpty: Bool { values.isEmpty }

    /// The masked bytes that can be passed on now.
    public mutating func feed(_ chunk: Data) -> Data {
        guard !values.isEmpty else { return chunk }
        let buffer = held + Array(chunk)
        held = []
        var out: [UInt8] = []
        out.reserveCapacity(buffer.count)
        var index = 0
        scanning: while index < buffer.count {
            let byte = buffer[index]
            guard firstBytes.contains(byte) else {
                out.append(byte)
                index += 1
                continue
            }
            let remaining = buffer.count - index
            // A longer value may still be arriving: wait for it before taking a shorter one that matches now.
            for value in values where value.count > remaining && starts(buffer, at: index, with: value, length: remaining) {
                held = Array(buffer[index...])
                break scanning
            }
            for value in values where value.count <= remaining && starts(buffer, at: index, with: value, length: value.count) {
                out += concealed
                concealedCount += 1
                index += value.count
                continue scanning
            }
            out.append(byte)
            index += 1
        }
        return Data(out)
    }

    /// What is still held, at the end of the stream. It was not a whole value.
    public mutating func finish() -> Data {
        defer { held = [] }
        return Data(held)
    }

    private func starts(_ buffer: [UInt8], at index: Int, with value: [UInt8], length: Int) -> Bool {
        for offset in 0..<length where buffer[index + offset] != value[offset] { return false }
        return true
    }
}
