import AppKit
import ApplicationServices

/// Heals stale TCC grants after an app update.
///
/// macOS pins each privacy grant to the code signature recorded at grant
/// time. Entries created by differently-signed builds (ad-hoc ≤2.2, debug
/// copies) still LOOK enabled in System Settings, but no longer match the
/// binary — the only cure is removing the entry and granting afresh, which
/// users had to do by hand (delete the app from the list, re-add). This
/// automates it: when a permission that was demonstrably granted before
/// stops working, the stale entry is dropped (`tccutil reset` for our bundle
/// id — no admin rights needed) so macOS can ask again. Runs at most once
/// per app version, so it can never turn into a nag.
enum PermissionHealer {

    static func healIfNeeded() { healIfNeeded(environment: .live) }

    /// Injection seam so the e2e harness can drive the decision logic without
    /// touching the machine's real TCC database.
    struct Environment {
        var axTrusted: () -> Bool
        var screenGranted: () -> Bool
        var resetTCC: (String) -> Void
        var requestAccessibility: () -> Void
        var defaults: UserDefaults
        var version: String

        static let live = Environment(
            axTrusted: { AXIsProcessTrusted() },
            screenGranted: { CGPreflightScreenCaptureAccess() },
            resetTCC: { service in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                process.arguments = ["reset", service, Bundle.main.bundleIdentifier ?? "com.getcuate.Cuate"]
                try? process.run()
                process.waitUntilExit()
                Diagnostics.log("tcc", "tccutil reset \(service) status=\(process.terminationStatus)")
            },
            requestAccessibility: {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            },
            defaults: .standard,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        )
    }

    static func healIfNeeded(environment env: Environment) {
        let defaults = env.defaults
        let axOK = env.axTrusted()
        let screenOK = env.screenGranted()

        // Remember every healthy state — "was granted before but isn't now"
        // is what tells a stale entry apart from never-granted.
        if axOK { defaults.set(true, forKey: "everTrustedAccessibility") }
        if screenOK { defaults.set(true, forKey: "everGrantedScreenCapture") }

        // One attempt per app version: enough to heal an update, never a nag
        // (a deliberate revocation is re-asked once after the next update only).
        guard defaults.string(forKey: "tccHealedForVersion") != env.version else { return }
        defaults.set(env.version, forKey: "tccHealedForVersion")

        if !axOK, defaults.bool(forKey: "everTrustedAccessibility") {
            env.resetTCC("Accessibility")
            // Re-request right away — dictation typing, LayoutFix and
            // selection capture all depend on it silently.
            env.requestAccessibility()
            Diagnostics.log("tcc", "healed stale Accessibility grant")
        }
        if !screenOK, defaults.bool(forKey: "everGrantedScreenCapture") {
            env.resetTCC("ScreenCapture")
            // No prompt here: macOS asks by itself on the next screenshot.
            Diagnostics.log("tcc", "healed stale ScreenCapture grant")
        }
    }
}
