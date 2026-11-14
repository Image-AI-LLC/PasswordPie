import Foundation

/// A release version such as `0.2.0`: one to four numbers with dots. Compared number by number, so 0.10.0 is above 0.9.1.
public struct AppVersion: Comparable, Hashable, CustomStringConvertible, Sendable {
    public let description: String
    private let parts: [Int]

    public init?(_ text: String) {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard (1...6).contains(piece.count), piece.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(piece) else { return nil }
            parts.append(number)
        }
        self.parts = parts
        description = text
    }

    /// A release tag: `v` and the version, nothing else.
    public init?(tag: String) {
        guard tag.hasPrefix("v") else { return nil }
        self.init(String(tag.dropFirst()))
    }

    public static func < (left: AppVersion, right: AppVersion) -> Bool {
        for index in 0..<max(left.parts.count, right.parts.count) {
            let a = index < left.parts.count ? left.parts[index] : 0
            let b = index < right.parts.count ? right.parts[index] : 0
            if a != b { return a < b }
        }
        return false
    }

    /// 1.0 and 1.0.0 are the same version.
    public static func == (left: AppVersion, right: AppVersion) -> Bool { !(left < right) && !(right < left) }

    public func hash(into hasher: inout Hasher) {
        var parts = parts
        while parts.last == 0 { parts.removeLast() }
        hasher.combine(parts)
    }
}
