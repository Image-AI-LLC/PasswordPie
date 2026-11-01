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

/// When to show an open or save panel.
enum FilePanelTiming {
    /// The menu-bar panel does not activate the app. The first file panel built in
    /// that state selects the folder it is showing, and clicks in the sidebar and
    /// file list do nothing. Cancelling that panel activates the app, so the next
    /// one accepts a selection. Show the first panel, and any later panel opened
    /// while inactive, on the turn after activation.
    static func deferPresentation(appIsActive: Bool, hasPresentedFilePanel: Bool) -> Bool {
        !hasPresentedFilePanel || !appIsActive
    }
}
