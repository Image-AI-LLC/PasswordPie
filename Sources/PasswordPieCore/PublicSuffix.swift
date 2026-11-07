import Foundation

/// Registrable domains (eTLD+1) from the bundled Public Suffix List, ICANN and private sections.
/// `gist.github.com` is on `github.com`; `alice.github.io` and `bob.github.io` are two sites.
public enum PublicSuffix {
    private struct Rules: Sendable {
        var exact: Set<String> = []
        /// `*.ck` is stored as `ck`: every label under it is a public suffix.
        var wildcard: Set<String> = []
        /// `!www.ck` is stored as `www.ck`: it is registrable although `*.ck` covers it.
        var exception: Set<String> = []
    }

    /// Parsed on first use.
    private static let rules: Rules = {
        var rules = Rules()
        rules.exact.reserveCapacity(10_000)
        for line in bundledPublicSuffixRules.split(separator: "\n") {
            if line.hasPrefix("!") {
                rules.exception.insert(String(line.dropFirst()))
            } else if line.hasPrefix("*.") {
                rules.wildcard.insert(String(line.dropFirst(2)))
            } else {
                rules.exact.insert(String(line))
            }
        }
        return rules
    }()

    /// The registrable domain of `host`, or nil when it has none: an IP address, a single label such as `localhost`,
    /// or a host that is itself a public suffix such as `co.uk`. The host should be in punycode, as `URL.host` gives it.
    public static func registrableDomain(ofHost raw: String) -> String? {
        var host = raw.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, !host.contains(":"), !isIPv4(host) else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 2, !labels.contains(where: \.isEmpty) else { return nil }
        let suffixCount = publicSuffixLabelCount(labels)
        guard labels.count > suffixCount else { return nil }
        return labels.suffix(suffixCount + 1).joined(separator: ".")
    }

    /// How many labels at the end of `labels` form the public suffix. The longest rule wins; an exception rule makes
    /// its own leftmost label registrable. With no rule, the last label is the suffix.
    private static func publicSuffixLabelCount(_ labels: [String]) -> Int {
        let rules = rules
        for start in labels.indices {
            let candidate = labels[start...].joined(separator: ".")
            if rules.exception.contains(candidate) { return labels.count - start - 1 }
            if rules.exact.contains(candidate) { return labels.count - start }
            if start + 1 < labels.count, rules.wildcard.contains(labels[(start + 1)...].joined(separator: ".")) {
                return labels.count - start
            }
        }
        return 1
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }
}
