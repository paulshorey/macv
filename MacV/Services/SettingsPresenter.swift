import AppKit

/// Opens Settings / dismisses history from SwiftUI buttons without SwiftUI `openSettings`.
enum SettingsPresenter {
    @MainActor
    static var openHandler: (() -> Void)?

    @MainActor
    static var dismissHistoryHandler: (() -> Void)?

    @MainActor
    static func openSettings() {
        dismissHistoryHandler?()
        openHandler?()
    }
}
