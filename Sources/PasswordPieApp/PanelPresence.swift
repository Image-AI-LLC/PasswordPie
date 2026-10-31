import Foundation

/// Whether the panel may close because focus moved. The Touch ID sheet is another process.
/// Cancelling that sheet must leave the lock form open.
enum PanelPresence {
    static func hidesOnFocusLoss(
        keepOpenDepth: Int,
        touchIDBusy: Bool,
        recordingHotKey: Bool,
        autoHideEnabled: Bool
    ) -> Bool {
        autoHideEnabled && keepOpenDepth == 0 && !touchIDBusy && !recordingHotKey
    }
}
