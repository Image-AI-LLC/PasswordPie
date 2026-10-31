/// Coarse preference choices that retain the exact value saved by an earlier version.
/// These are presentation helpers only; they do not change defaults or persistence.
public enum PreferenceDurations {
    public static let idleMinutes = [1, 5, 15, 30, 60, 240]
    public static let clipboardSeconds = [15, 30, 60, 90, 120, 300]

    public static func idleOptions(including current: Int) -> [Int] {
        Array(Set(idleMinutes + [current])).sorted()
    }

    public static func clipboardOptions(including current: Int) -> [Int] {
        Array(Set(clipboardSeconds + [current])).sorted()
    }

    public static func minutesLabel(_ value: Int) -> String {
        if value > 0, value.isMultiple(of: 60) {
            return label(value / 60, unit: "hour")
        }
        return label(value, unit: "minute")
    }

    public static func secondsLabel(_ value: Int) -> String {
        if value > 0, value.isMultiple(of: 60) {
            return minutesLabel(value / 60)
        }
        return label(value, unit: "second")
    }

    private static func label(_ value: Int, unit: String) -> String {
        "\(value) \(unit)\(value == 1 ? "" : "s")"
    }
}
