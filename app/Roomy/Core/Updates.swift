import Observation

/// What the app's views need from the updater (Sparkle), without importing it.
@MainActor @Observable
final class Updates {
    /// Check for new versions on its own, about once a day.
    var automaticallyChecks: Bool {
        didSet { if automaticallyChecks != oldValue { setAutomatic(automaticallyChecks) } }
    }
    private let setAutomatic: (Bool) -> Void
    private let checkNow: () -> Void

    init(automaticallyChecks: Bool, setAutomatic: @escaping (Bool) -> Void, checkNow: @escaping () -> Void) {
        self.automaticallyChecks = automaticallyChecks
        self.setAutomatic = setAutomatic
        self.checkNow = checkNow
    }

    func check() { checkNow() }
}
