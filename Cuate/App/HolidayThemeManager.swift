import SwiftUI
import Combine

/// Auto-switches the chat theme for seasonal holidays: Halloween on Oct 31,
/// Día de Muertos on Nov 1–2, Yule on Dec 24 – Jan 1 (local calendar). When a holiday starts, the
/// user's current theme is remembered and the holiday theme applied; when it
/// ends, the remembered theme comes back. A manual theme change during the
/// holiday always wins — the manager backs off until the holiday's next
/// occurrence. The whole feature sits behind Settings → Appearance →
/// "Holiday themes" (on by default).
@MainActor
final class HolidayThemeManager {
    static let shared = HolidayThemeManager()

    private let defaults = UserDefaults.standard
    private let settings = AppSettings.shared
    private var cancellables: Set<AnyCancellable> = []

    // Persisted state:
    /// "halloween-2026" while an auto-applied holiday theme is active.
    private let appliedKey = "holidayAppliedToken"
    /// The theme to restore when the holiday ends.
    private let savedKey = "holidaySavedTheme"
    /// Occurrence the user manually overrode — don't re-apply it this year.
    private let overriddenKey = "holidayOverriddenToken"

    private enum Holiday {
        case halloween, diaDeMuertos, yule

        var theme: AppTheme {
            switch self {
            case .halloween: return .halloween
            case .diaDeMuertos: return .diaDeMuertos
            case .yule: return .yule
            }
        }

        var slug: String {
            switch self {
            case .halloween: return "halloween"
            case .diaDeMuertos: return "dia"
            case .yule: return "yule"
            }
        }
    }

    private init() {}

    func start() {
        refresh()
        // Day rolls over while the app is running (incl. wake from sleep).
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // The user's manual theme picks (the theme picker in Settings).
        // Deferred one tick: the manager's own writes finish updating their
        // bookkeeping keys first, so `userPicked` only sees genuine picks.
        settings.$theme
            .dropFirst()
            .sink { [weak self] newTheme in
                Task { @MainActor in self?.userPicked(newTheme) }
            }
            .store(in: &cancellables)
        // Toggling the feature off hands the theme back; on re-checks today.
        settings.$holidayThemes
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // The @Published fires on willSet — re-read on the next tick.
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &cancellables)
    }

    /// Reconcile the theme with today's date. Idempotent; safe to call often.
    func refresh() {
        guard settings.holidayThemes else {
            restoreIfApplied()
            return
        }
        guard let (holiday, token) = Self.occurrence(on: Date()) else {
            restoreIfApplied()
            defaults.removeObject(forKey: overriddenKey)   // occurrence passed
            return
        }
        guard defaults.string(forKey: overriddenKey) != token else { return }
        let applied = defaults.string(forKey: appliedKey)
        guard applied != token else { return }             // already active
        if applied == nil {
            // Fresh application: remember what to come back to. (A
            // Halloween→Día transition keeps the original saved theme.)
            defaults.set(settings.theme.rawValue, forKey: savedKey)
        }
        setTheme(holiday.theme)
        defaults.set(token, forKey: appliedKey)
    }

    /// The holiday occurring on `date`, with its per-year token.
    private static func occurrence(on date: Date) -> (Holiday, String)? {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        let holiday: Holiday?
        // Yule's window crosses the year boundary (Dec 24 – Jan 1): Jan 1
        // belongs to the PREVIOUS year's occurrence, so its token matches and
        // a manual override on Dec 28 keeps holding on New Year's morning.
        var tokenYear = y
        switch (m, d) {
        case (10, 31): holiday = .halloween
        case (11, 1), (11, 2): holiday = .diaDeMuertos
        case (12, 24...31): holiday = .yule
        case (1, 1):
            holiday = .yule
            tokenYear = y - 1
        default: holiday = nil
        }
        return holiday.map { ($0, "\($0.slug)-\(tokenYear)") }
    }

    /// Holiday over (or feature off): hand back the remembered theme.
    private func restoreIfApplied() {
        guard defaults.string(forKey: appliedKey) != nil else { return }
        if let raw = defaults.string(forKey: savedKey), let theme = AppTheme(rawValue: raw) {
            setTheme(theme)
        }
        defaults.removeObject(forKey: appliedKey)
        defaults.removeObject(forKey: savedKey)
    }

    /// A manual pick during an active holiday wins: drop our claim and skip
    /// this occurrence (nothing will be force-restored later either).
    ///
    /// The manager's own writes never land here: applying sets the holiday
    /// theme itself (filtered below), and restoring clears `appliedKey`
    /// before this deferred check runs.
    private func userPicked(_ newTheme: AppTheme) {
        guard let token = defaults.string(forKey: appliedKey) else { return }
        let holidayTheme: AppTheme
        if token.hasPrefix("halloween") {
            holidayTheme = .halloween
        } else if token.hasPrefix("yule") {
            holidayTheme = .yule
        } else {
            holidayTheme = .diaDeMuertos
        }
        guard newTheme != holidayTheme else { return }
        defaults.set(token, forKey: overriddenKey)
        defaults.removeObject(forKey: appliedKey)
        defaults.removeObject(forKey: savedKey)
    }

    private func setTheme(_ theme: AppTheme) {
        settings.theme = theme
    }
}
