import Foundation
import Combine
import LocalAuthentication
import Security

enum AppAuthenticationMethod {
    case biometricsOrPasscode
    case passcode
}

@MainActor
protocol AppAuthenticating {
    func authenticate(using method: AppAuthenticationMethod) async throws -> Bool
    func cancel()
}

@MainActor
final class DeviceAuthenticator: AppAuthenticating {
    private var context: LAContext?
    func authenticate(using method: AppAuthenticationMethod) async throws -> Bool {
        let context = LAContext()
        self.context = context
        defer { if self.context === context { self.context = nil } }
        context.localizedCancelTitle = "Cancel"
        context.localizedFallbackTitle = "Use device passcode"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error ?? NSError(domain: LAError.errorDomain, code: LAError.passcodeNotSet.rawValue)
        }
        if method == .passcode {
            // Re-evaluating deviceOwnerAuthentication would start Face ID again.
            // Evaluate a passcode-only constraint instead; iOS owns the keypad
            // and validates the device passcode. Budget never receives the PIN.
            var creationError: Unmanaged<CFError>?
            guard let accessControl = SecAccessControlCreateWithFlags(nil,
                kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .devicePasscode, &creationError) else {
                if let creationError { throw creationError.takeRetainedValue() as Error }
                throw LAError(.passcodeNotSet)
            }
            return try await context.evaluateAccessControl(accessControl, operation: .useItem,
                localizedReason: "Use your device passcode to unlock your accounts and transactions.")
        }
        return try await context.evaluatePolicy(.deviceOwnerAuthentication,
            localizedReason: "Unlock Budget to view your accounts and transactions.")
    }
    func cancel() { context?.invalidate(); context = nil }
}

/// Keeps an authenticated session through temporary interruptions (including the
/// Face ID prompt) and brief app switches. Background content is always covered.
@MainActor
final class AppLock: ObservableObject {
    static let preferenceKey = "requireAppAuthentication"
    private static let enforcedKey = "appAuthenticationEnforced"
    @Published private(set) var isUnlocked: Bool
    @Published private(set) var isAuthenticating = false
    @Published private(set) var coversContent: Bool
    @Published private(set) var message: String?
    var coverChanged: ((Bool) -> Void)?
    private let defaults: UserDefaults
    private let authenticator: any AppAuthenticating
    private let now: () -> Date
    private var backgroundedAt: Date?
    private static let gracePeriod: TimeInterval = 5 * 60
    private var enforced: Bool
    private var active = false
    private var attempted = false
    private var generation = 0

    init(defaults: UserDefaults = .standard, authenticator: (any AppAuthenticating)? = nil,
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        self.authenticator = authenticator ?? DeviceAuthenticator()
        enforced = defaults.bool(forKey: Self.preferenceKey) || defaults.bool(forKey: Self.enforcedKey)
        isUnlocked = !enforced
        coversContent = enforced
        if enforced { defaults.set(true, forKey: Self.enforcedKey) }
    }

    @discardableResult
    func becameActive() -> Task<Void, Never>? {
        active = true
        if enforced {
            let elapsed = backgroundedAt.map { now().timeIntervalSince($0) }
            // Disabling protection still requires a final authentication, even
            // when returning from Settings within the grace period.
            if (isUnlocked && !defaults.bool(forKey: Self.preferenceKey))
                || elapsed.map({ $0 >= Self.gracePeriod || $0 < 0 }) == true {
                isUnlocked = false
                attempted = false
            }
        }
        backgroundedAt = nil
        if defaults.bool(forKey: Self.preferenceKey), !enforced {
            enforced = true
            defaults.set(true, forKey: Self.enforcedKey)
            isUnlocked = false
            attempted = false
        }
        updateCover()
        if enforced, !isUnlocked, !attempted {
            attempted = true
            return Task { await unlock() }
        }
        return nil
    }

    func becameInactive() {
        active = false
        updateCover()
    }

    func enteredBackground() {
        active = false
        if backgroundedAt == nil { backgroundedAt = now() }
        generation += 1
        authenticator.cancel()
        isAuthenticating = false
        attempted = false
        message = nil
        updateCover()
    }

    func unlock(using method: AppAuthenticationMethod = .biometricsOrPasscode) async {
        guard active, enforced, !isUnlocked, !isAuthenticating else { return }
        attempted = true
        isAuthenticating = true
        message = nil
        let currentGeneration = generation
        do {
            let success = try await authenticator.authenticate(using: method)
            guard currentGeneration == generation else { return }
            if success {
                isUnlocked = true
                // Turning the setting off also requires authentication. A user
                // cannot bypass an existing lock by toggling it in Settings.
                enforced = defaults.bool(forKey: Self.preferenceKey)
                defaults.set(enforced, forKey: Self.enforcedKey)
            } else {
                message = "Authentication didn’t complete. Tap Unlock to try again."
            }
        } catch {
            guard currentGeneration == generation else { return }
            if let error = error as? LAError, error.code == .passcodeNotSet {
                message = "Set up Face ID, Touch ID or a device passcode in Settings, then try again."
            } else {
                message = "Tap Unlock to try again, or choose Use device passcode."
            }
        }
        isAuthenticating = false
        updateCover()
    }

    private func updateCover() {
        coversContent = enforced && (!active || !isUnlocked)
        coverChanged?(coversContent)
    }
}

#if canImport(UIKit)
import SwiftUI
import UIKit

struct AppLockScreen: View {
    @ObservedObject var lock: AppLock
    var body: some View {
        ZStack {
            Color(red: 31 / 255, green: 56 / 255, blue: 48 / 255)
            Button {
                // After a dismissed or failed prompt, a tap offers the device
                // passcode directly without adding controls to the cover.
                Task { await lock.unlock(using: lock.message == nil ? .biometricsOrPasscode : .passcode) }
            } label: {
                Image("BudgetLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
            }
            .buttonStyle(.plain)
            .disabled(lock.isAuthenticating)
            .accessibilityLabel("Unlock Budget")
            .accessibilityHint(lock.message == nil ? "Authenticate to view your accounts" : "Use your device passcode")
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}

struct AppLockContainer<Content: View>: View {
    @ObservedObject var lock: AppLock
    @ViewBuilder let content: Content
    var body: some View {
        ZStack {
            // Preserve navigation and bank authorisation state underneath the
            // lock. The separate window also covers any presented sheets.
            content.opacity(lock.coversContent ? 0 : 1)
                .allowsHitTesting(!lock.coversContent)
                .accessibilityHidden(lock.coversContent)
            if lock.coversContent { AppLockScreen(lock: lock) }
        }
        .background(AppPrivacyWindow(lock: lock))
    }
}

private struct AppPrivacyWindow: UIViewRepresentable {
    let lock: AppLock
    func makeCoordinator() -> Coordinator { Coordinator(lock: lock) }
    func makeUIView(context: Context) -> WindowReader {
        let view = WindowReader()
        view.attached = { [weak coordinator = context.coordinator] window in coordinator?.attach(to: window) }
        return view
    }
    func updateUIView(_ uiView: WindowReader, context: Context) {}
    static func dismantleUIView(_ uiView: WindowReader, coordinator: Coordinator) { coordinator.stop() }

    final class WindowReader: UIView {
        var attached: ((UIWindow) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { attached?(window) }
        }
    }

    @MainActor
    final class Coordinator {
        let lock: AppLock
        private var privacyWindow: UIWindow?
        private var observers: [NSObjectProtocol] = []
        init(lock: AppLock) { self.lock = lock }
        func attach(to window: UIWindow) {
            guard privacyWindow == nil, let scene = window.windowScene else { return }
            let cover = UIWindow(windowScene: scene)
            cover.windowLevel = .alert + 1
            cover.rootViewController = UIHostingController(rootView: AppLockScreen(lock: lock))
            privacyWindow = cover
            lock.coverChanged = { [weak cover] showing in cover?.isHidden = !showing }
            cover.isHidden = !lock.coversContent
            // Synchronous notifications cover sheets before iOS snapshots the
            // app. Scene-specific observers avoid another window changing it.
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: UIScene.willDeactivateNotification, object: scene, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.lock.becameInactive() }
                },
                center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: scene, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.lock.enteredBackground() }
                },
                center.addObserver(forName: UIScene.didActivateNotification, object: scene, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { _ = self?.lock.becameActive() }
                }
            ]
            if scene.activationState == .foregroundActive { lock.becameActive() }
        }
        func stop() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            lock.coverChanged = nil
            privacyWindow?.isHidden = true
            privacyWindow = nil
        }
    }
}
#endif
