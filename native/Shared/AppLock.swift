import LocalAuthentication
import SwiftUI

/// 应用锁 (Face ID, Touch ID): optional, off by default. It stands in front of the app; it does not
/// encrypt the library's files. The device's own passcode or password is the way in when biometrics
/// fail, so that a failed sensor never locks a person out of their library.
enum AppLock {
    enum Outcome {
        case passed
        /// Cancelled or not recognized: the lock stays, with its reason if there is one to give.
        case stayed(String?)
        /// The device has no way to ask (no passcode any more).
        case unavailable
    }

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "appLock.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "appLock.enabled") }
    }

    /// What this device will ask for, for the setting's name.
    static var methodName: String {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return L("applock.method.passcode") }
        switch context.biometryType {
        case .faceID: return L("applock.method.faceID")
        case .touchID: return L("applock.method.touchID")
        case .opticID: return L("applock.method.opticID")
        default: return L("applock.method.passcode")
        }
    }

    static var available: Bool { LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) }

    /// Asks the system; `done` on the main thread.
    static func authenticate(_ done: @escaping @MainActor (Outcome) -> Void) {
        #if DEBUG
        // the Mac debug tour: looks at the lock without a finger on the sensor
        if let fake = ProcessInfo.processInfo.environment["TL_FAKE_UNLOCK"] {
            DispatchQueue.main.async { MainActor.assumeIsolated { done(fake == "pass" ? .passed : fake == "none" ? .unavailable : .stayed(nil)) } }
            return
        }
        #endif
        let context = LAContext()
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            let noWay = (problem as? LAError)?.code == .passcodeNotSet
            DispatchQueue.main.async { MainActor.assumeIsolated { done(noWay ? .unavailable : .stayed(problem?.localizedDescription)) } }
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L("applock.reason")) { ok, error in
            let code = (error as? LAError)?.code
            let quiet = code == .userCancel || code == .appCancel || code == .systemCancel
            let text = quiet ? nil : error?.localizedDescription
            DispatchQueue.main.async { MainActor.assumeIsolated { done(ok ? .passed : .stayed(text)) } }
        }
    }
}

/// What shows while locked; the system's own prompt comes up in front of it.
struct AppLockScreen: View {
    /// Asks the system now; the outcome comes back to the host.
    let unlock: () -> Void
    /// The device has no way to ask any more: open, and the lock is off.
    let openAnyway: () -> Void
    @ObservedObject var state: State

    final class State: ObservableObject {
        @Published var message: String?
        @Published var unavailable = false
        @Published var busy = false
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(L("applock.title")).font(.system(size: 20, weight: .semibold))
            if state.unavailable {
                Text(L("applock.unavailable"))
                    .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(action: openAnyway) { Text(L("applock.openAnyway")).padding(.horizontal, 16).frame(minHeight: 36) }
                    .blueGlassButton()
                    .accessibilityIdentifier("appLockOpenAnyway")
            } else {
                if let message = state.message {
                    Text(message).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                Button(action: unlock) { Text(L("applock.unlock")).padding(.horizontal, 16).frame(minHeight: 36) }
                    .blueGlassButton()
                    .disabled(state.busy)
                    .accessibilityIdentifier("appLockUnlock")
            }
        }
        .padding(32)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
