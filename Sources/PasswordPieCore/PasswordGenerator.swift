import Foundation
import Security

/// "Characters" tab: random letters with at least `digits` digits and `symbols` symbols.
public struct CharacterRecipe: Equatable, Sendable {
    public static let lengthRange = 4...64
    public static let countRange = 0...10

    public var length: Int
    public var digits: Int
    public var symbols: Int
    public var avoidAmbiguous: Bool

    public init(length: Int = 20, digits: Int = 3, symbols: Int = 1, avoidAmbiguous: Bool = false) {
        self.length = min(max(length, Self.lengthRange.lowerBound), Self.lengthRange.upperBound)
        self.digits = min(max(digits, Self.countRange.lowerBound), Self.countRange.upperBound)
        self.symbols = min(max(symbols, Self.countRange.lowerBound), Self.countRange.upperBound)
        self.avoidAmbiguous = avoidAmbiguous
    }
}

/// "Words" tab.
public struct PassphraseRecipe: Equatable, Sendable {
    public static let wordRange = 3...10

    public var words: Int
    public var separator: String

    public init(words: Int = 6, separator: String = "-") {
        self.words = min(max(words, Self.wordRange.lowerBound), Self.wordRange.upperBound)
        self.separator = separator
    }
}

public enum PasswordGenerator {
    static let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let numerals = Array("0123456789")
    static let punctuation = Array("!@#$%^&*()-_=+[]{};:,.?")
    static let ambiguous = Set("0Ool1I|")

    public static func generate(_ recipe: CharacterRecipe, randomByte: (() -> UInt8)? = nil) -> String {
        let draw = randomByte ?? secureByte
        func pool(_ source: [Character]) -> [Character] {
            recipe.avoidAmbiguous ? source.filter { !ambiguous.contains($0) } : source
        }
        let digits = min(recipe.digits, recipe.length)
        let symbols = min(recipe.symbols, recipe.length - digits)
        var picked: [Character] = []
        picked += (0..<digits).map { _ in pick(pool(numerals), draw) }
        picked += (0..<symbols).map { _ in pick(pool(punctuation), draw) }
        let rest = recipe.length - digits - symbols
        picked += (0..<rest).map { _ in pick(pool(letters), draw) }
        return String(shuffled(picked, draw))
    }

    public static func generate(_ recipe: PassphraseRecipe, randomByte: (() -> UInt8)? = nil) -> String {
        let draw = randomByte ?? secureByte
        return (0..<recipe.words).map { _ in pick(wordList, draw) }.joined(separator: recipe.separator)
    }

    /// Entropy in bits, for the strength meter.
    public static func entropyBits(_ recipe: CharacterRecipe) -> Double {
        let pool = recipe.avoidAmbiguous ? 46.0 : 52.0
        return Double(recipe.length) * log2(pool + Double(recipe.digits > 0 ? 10 : 0) + Double(recipe.symbols > 0 ? 23 : 0))
    }

    public static func entropyBits(_ recipe: PassphraseRecipe) -> Double {
        Double(recipe.words) * log2(Double(wordList.count))
    }

    /// 0...1 rating for a password typed or generated; coarse by design.
    public static func strength(of password: String) -> Double {
        guard !password.isEmpty else { return 0 }
        var pool = 0.0
        if password.contains(where: { $0.isLowercase }) { pool += 26 }
        if password.contains(where: { $0.isUppercase }) { pool += 26 }
        if password.contains(where: { $0.isNumber }) { pool += 10 }
        if password.contains(where: { !$0.isLetter && !$0.isNumber }) { pool += 23 }
        let bits = Double(password.count) * log2(max(pool, 2))
        return min(bits / 100, 1)
    }

    /// Uniform index in 0..<count by rejection sampling, so no value is favored.
    static func index(below count: Int, _ draw: () -> UInt8) -> Int {
        precondition(count > 0 && count <= 256)
        let limit = 256 - 256 % count
        while true {
            let byte = Int(draw())
            if byte < limit { return byte % count }
        }
    }

    private static func pick<T>(_ pool: [T], _ draw: () -> UInt8) -> T {
        pool[index(below: pool.count, draw)]
    }

    private static func shuffled(_ items: [Character], _ draw: () -> UInt8) -> [Character] {
        var out = items
        guard out.count > 1 else { return out }
        for i in stride(from: out.count - 1, to: 0, by: -1) {
            out.swapAt(i, index(below: i + 1, draw))
        }
        return out
    }

    private static func secureByte() -> UInt8 {
        var byte: UInt8 = 0
        if SecRandomCopyBytes(kSecRandomDefault, 1, &byte) != errSecSuccess {
            byte = UInt8.random(in: 0...255)
        }
        return byte
    }

    /// 256 short, common words: 8 bits each.
    static let wordList: [String] = """
    able acid acorn actor adapt agent alarm album alder alley amber anchor angle apple arbor arch
    arena armor arrow ash aspen atlas atom attic autumn avid award axis badge baker balm banjo barn
    basil basin beach beacon bean bear beech bell bench berry birch bison blaze bloom boat bolt
    bonus book boot bow brace bread brick bridge brook broom brush bud cable cactus cairn camel
    candle canoe canyon cape cargo carrot cask cedar cellar chair chalk charm cherry chess chime
    cider cinder circle civic clam clay clever cliff clock cloud clover coast cobalt cocoa comet
    coral cork cove crane creek crest crown crumb crystal cube cup curve daisy dawn delta denim
    desk dew dice dock dove dragon drift drum dune eagle earth easel echo eel elbow elder elm ember
    emerald engine fable falcon fan farm feather fennel fern ferry fiddle field finch fjord flame
    flint flute foam fog forest fort fox frost garden garlic gate gecko gem ginger glade glass glider
    globe goat gold grain grape gravel grove gull gust hammer harbor hare haven hazel heron hill
    hive honey hood horn hound iceberg igloo inlet iris iron island ivory ivy jade jar jasper jazz
    jelly jewel juniper kayak kelp kettle kite knot lake lamp lance lantern lark laurel lava leaf
    ledge lemon lens lilac lily linen lion lotus lunar lynx maple marble marsh meadow melon mesa
    mint mist moon moss moth mouse nectar nest nickel noble north nutmeg oak oasis ocean olive onyx
    opal orbit orchid otter oval owl oyster paddle palm panda paper pearl pebble
    """.split(whereSeparator: { $0.isWhitespace }).map(String.init)
}
