import Foundation

/// Replaces every exact occurrence of the values a command was given with `[concealed by PasswordPie]`, in a stream that
/// arrives in pieces. A value split across two pieces is still caught: the end of a piece that could be the start of a
/// value is held until the next piece says whether it is. Values shorter than `AgentConstants.minimumMaskedLength` are not
/// masked (`skipped` counts them), and transformed values (base64, a substring, URL-encoded) are not caught.
public struct OutputMasker {
    private let values: [[UInt8]]
    private let minimumLength: Int
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
        self.minimumLength = minimumLength
        firstBytes = Set(unique.compactMap(\.first))
        skipped = short
    }

    public var isEmpty: Bool { values.isEmpty }

    /// The masked bytes that can be passed on now.
    public mutating func feed(_ chunk: Data) -> Data {
        guard !values.isEmpty else { return chunk }
        return scan(held + Array(chunk), final: false)
    }

    /// What is still held, at the end of the stream, with any whole value in it masked: a held tail can start a longer
    /// value that never came and still hold a shorter one. `cut`: the stream did not end, it was cut (a timeout, a
    /// cancelled run), so a held start of a value at least `minimumLength` long is concealed too: the command was
    /// stopped in the middle of writing the value. A stream that ended keeps what the command wrote.
    public mutating func finish(cut: Bool = false) -> Data {
        guard !held.isEmpty else { return Data() }
        return scan(held, final: true, cut: cut)
    }

    /// Masks `buffer`. Unless `final`, a tail that could still become a value is kept in `held` for the next piece.
    private mutating func scan(_ buffer: [UInt8], final: Bool, cut: Bool = false) -> Data {
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
            for value in values where !final && value.count > remaining && starts(buffer, at: index, with: value, length: remaining) {
                held = Array(buffer[index...])
                break scanning
            }
            // The stream was cut in the middle of a value: its start, when long enough to say something, is concealed. Checked before a
            // shorter whole value, which would leave the longer one's rest showing.
            if cut, remaining >= minimumLength,
               values.contains(where: { $0.count > remaining && starts(buffer, at: index, with: $0, length: remaining) }) {
                out += concealed
                concealedCount += 1
                index = buffer.count
                continue scanning
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

    private func starts(_ buffer: [UInt8], at index: Int, with value: [UInt8], length: Int) -> Bool {
        for offset in 0..<length where buffer[index + offset] != value[offset] { return false }
        return true
    }
}
