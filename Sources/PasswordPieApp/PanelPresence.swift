import AppKit

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

/// The window level of the menu: the panel, its submenus and the details popover.
enum PanelLevel {
    /// Just under the menu bar, like the attached 1Password mini: above another app's modal dialog (a sign-in window
    /// sits at the modal-panel level while its app is active) and above pinned windows.
    /// While PasswordPie shows a dialog of its own (a file chooser, a question), the menu goes back under the
    /// modal-panel level, or it would cover the dialog it opened.
    static func level(ownDialogOpen: Bool) -> NSWindow.Level {
        ownDialogOpen ? .floating : menuWindowLevel
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
