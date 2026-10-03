import Foundation
import LocalAuthentication
import Testing
@testable import BudgetSecurity

@MainActor
private final class AuthenticationStub: AppAuthenticating {
    var calls = 0
    var cancellations = 0
    var methods: [AppAuthenticationMethod] = []
    var result: Result<Bool, Error> = .success(true)
    var pause = false
    private var pending: CheckedContinuation<Bool, Error>?
    private var started: CheckedContinuation<Void, Never>?
    func authenticate(using method: AppAuthenticationMethod) async throws -> Bool {
        calls += 1
        methods.append(method)
        if !pause { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }
    func waitForRequest() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() {
        pending?.resume(with: result)
        pending = nil
    }
    // Deliberately allow a late success after cancellation to test the guard.
    func cancel() { cancellations += 1 }
}

@MainActor
private func preferences(enabled: Bool) -> (UserDefaults, String) {
    let name = "BudgetAppLockTests.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defaults.set(enabled, forKey: AppLock.preferenceKey)
    return (defaults, name)
}

@Test @MainActor func lockIsOptIn() {
    let (defaults, name) = preferences(enabled: false)
    defer { defaults.removePersistentDomain(forName: name) }
    let auth = AuthenticationStub()
    let lock = AppLock(defaults: defaults, authenticator: auth)
    #expect(lock.isUnlocked)
    #expect(!lock.coversContent)
    #expect(lock.becameActive() == nil)
    #expect(auth.calls == 0)
}

@Test @MainActor func launchLocksUntilSuccessfulAuthentication() async throws {
    let (defaults, name) = preferences(enabled: true)
    defer { defaults.removePersistentDomain(forName: name) }
    let auth = AuthenticationStub()
    auth.pause = true
    let lock = AppLock(defaults: defaults, authenticator: auth)
    #expect(!lock.isUnlocked && lock.coversContent)
    let attempt = try #require(lock.becameActive())
    await auth.waitForRequest()
    await lock.unlock() // Duplicate button taps must not issue another prompt.
    #expect(auth.calls == 1)
    #expect(lock.coversContent)
    auth.finish()
    await attempt.value
    #expect(lock.isUnlocked && !lock.coversContent)
}

@Test @MainActor func cancellationStaysLockedWithoutPromptLoopAndAllowsRetry() async throws {
    let (defaults, name) = preferences(enabled: true)
    defer { defaults.removePersistentDomain(forName: name) }
    let auth = AuthenticationStub()
    auth.result = .failure(LAError(.userCancel))
    let lock = AppLock(defaults: defaults, authenticator: auth)
    let attempt = try #require(lock.becameActive())
    await attempt.value
    #expect(!lock.isUnlocked && lock.coversContent)
    #expect(lock.message != nil)
    lock.becameInactive()
    #expect(lock.becameActive() == nil)
    #expect(auth.calls == 1)
    auth.result = .success(true)
    await lock.unlock()
    #expect(lock.isUnlocked && !lock.coversContent)
}

@Test @MainActor func briefAppSwitchesStayUnlockedButFiveMinutesAwayRequiresAuthentication() async throws {
    let (defaults, name) = preferences(enabled: true)
    defer { defaults.removePersistentDomain(forName: name) }
    let auth = AuthenticationStub()
    var time = Date()
    let lock = AppLock(defaults: defaults, authenticator: auth, now: { time })
    var cover = true
    lock.coverChanged = { cover = $0 }
    let attempt = try #require(lock.becameActive())
    await attempt.value
    #expect(!cover)
    lock.becameInactive()
    #expect(cover && lock.isUnlocked)
    #expect(lock.becameActive() == nil)
    #expect(!cover && auth.calls == 1)
    lock.enteredBackground()
    #expect(cover && lock.isUnlocked)
    time.addTimeInterval(299)
    #expect(lock.becameActive() == nil)
    #expect(!cover && auth.calls == 1)
    // The timeout starts afresh on each departure, not at the last unlock.
    lock.enteredBackground()
    time.addTimeInterval(300)
    let next = try #require(lock.becameActive())
    await next.value
    #expect(!cover && auth.calls == 2)
}

@Test @MainActor func disablingDuringGracePeriodStillRequiresFinalUnlock() async throws {
    let (defaults, name) = preferences(enabled: true)
    defer { defaults.removePersistentDomain(forName: name) }
    let auth = AuthenticationStub()
    let lock = AppLock(defaults: defaults, authenticator: auth)
    await lock.becameActive()?.value
    lock.enteredBackground()
    defaults.set(false, forKey: AppLock.preferenceKey)
    auth.result = .failure(LAError(.userCancel))
    let attempt = try #require(lock.becameActive())
    await attempt.value
    #expect(!lock.isUnlocked && lock.coversContent)
    lock.becameInactive()
    #expect(lock.becameActive() == nil)
    auth.result = .success(true)
    await lock.unlock()
    #expect(lock.isUnlocked && !lock.coversContent)
}

@Test @MainActor func relaunchDoesNotInheritGracePeriod() async throws {
    let (defaults, name) = preferences(enabled: true)
    defer { defaults.removePersistentDomain(forName: name) }
    let lock = AppLock(defaults: defaults, authenticator: AuthenticationStub())
    await lock.becameActive()?.value
    lock.enteredBackground()
    let relaunched = AppLock(defaults: defaults, authenticator: AuthenticationStub())
    #expect(!relaunched.isUnlocked && relaunched.coversContent)
}

@Test @MainActor func lateSuccessCannotUnlockAfterBackgrounding() async throws {
    let (defaults, name) = preferences(enabled: true)
    defer { defaults.removePersistentDomain(forName: name) }
    let auth = AuthenticationStub()
    auth.pause = true
    let lock = AppLock(defaults: defaults, authenticator: auth)
    let attempt = try #require(lock.becameActive())
    await auth.waitForRequest()
    lock.enteredBackground()
    auth.finish()
    await attempt.value
    #expect(auth.cancellations == 1)
    #expect(!lock.isUnlocked && lock.coversContent)
    #expect(!lock.isAuthenticating)
}

@Test @MainActor func disablingInSettingsCannotBypassAnExistingLockEvenAfterRelaunch() async throws {
    let (defaults, name) = preferences(enabled: true)
    defer { defaults.removePersistentDomain(forName: name) }
    _ = AppLock(defaults: defaults, authenticator: AuthenticationStub())
    defaults.set(false, forKey: AppLock.preferenceKey)
    let auth = AuthenticationStub()
    let relaunched = AppLock(defaults: defaults, authenticator: auth)
    #expect(relaunched.coversContent && !relaunched.isUnlocked)
    let attempt = try #require(relaunched.becameActive())
    await attempt.value
    relaunched.enteredBackground()
    #expect(relaunched.isUnlocked && !relaunched.coversContent)
    let nextLaunch = AppLock(defaults: defaults, authenticator: AuthenticationStub())
    #expect(nextLaunch.isUnlocked && !nextLaunch.coversContent)
}

@Test @MainActor func enablingInSettingsLocksOnReturn() async throws {
    let (defaults, name) = preferences(enabled: false)
    defer { defaults.removePersistentDomain(forName: name) }
    let auth = AuthenticationStub()
    let lock = AppLock(defaults: defaults, authenticator: auth)
    lock.becameActive()
    lock.enteredBackground()
    defaults.set(true, forKey: AppLock.preferenceKey)
    let attempt = try #require(lock.becameActive())
    #expect(lock.coversContent && !lock.isUnlocked)
    await attempt.value
    #expect(lock.isUnlocked)
}

@Test @MainActor func unavailableDeviceAuthenticationDoesNotUnlock() async throws {
    let (defaults, name) = preferences(enabled: true)
    defer { defaults.removePersistentDomain(forName: name) }
    let auth = AuthenticationStub()
    auth.result = .failure(LAError(.passcodeNotSet))
    let lock = AppLock(defaults: defaults, authenticator: auth)
    let attempt = try #require(lock.becameActive())
    await attempt.value
    #expect(!lock.isUnlocked && lock.coversContent)
    #expect(lock.message?.contains("Set up") == true)
}

@Test @MainActor func failedFaceIDCanBeFollowedByExplicitPasscodeAuthentication() async throws {
    let (defaults, name) = preferences(enabled: true)
    defer { defaults.removePersistentDomain(forName: name) }
    let auth = AuthenticationStub()
    auth.result = .failure(LAError(.authenticationFailed))
    let lock = AppLock(defaults: defaults, authenticator: auth)
    let attempt = try #require(lock.becameActive())
    await attempt.value
    #expect(lock.coversContent && !lock.isUnlocked)
    auth.result = .success(true)
    await lock.unlock(using: .passcode)
    #expect(auth.methods == [.biometricsOrPasscode, .passcode])
    #expect(lock.isUnlocked && !lock.coversContent)
}

@Test @MainActor func cancellingPasscodeEntryKeepsAppLockedAndAllowsPasscodeRetry() async throws {
    let (defaults, name) = preferences(enabled: true)
    defer { defaults.removePersistentDomain(forName: name) }
    let auth = AuthenticationStub()
    auth.result = .failure(LAError(.userCancel))
    let lock = AppLock(defaults: defaults, authenticator: auth)
    let attempt = try #require(lock.becameActive())
    await attempt.value
    await lock.unlock(using: .passcode)
    #expect(!lock.isUnlocked && lock.coversContent)
    #expect(lock.becameActive() == nil)
    #expect(auth.calls == 2)
    auth.result = .success(true)
    await lock.unlock(using: .passcode)
    #expect(auth.methods == [.biometricsOrPasscode, .passcode, .passcode])
    #expect(lock.isUnlocked && !lock.coversContent)
}

@Test @MainActor func passcodeSuccessAfterBackgroundingCannotUnlockApp() async throws {
    let (defaults, name) = preferences(enabled: true)
    defer { defaults.removePersistentDomain(forName: name) }
    let auth = AuthenticationStub()
    auth.result = .failure(LAError(.userCancel))
    let lock = AppLock(defaults: defaults, authenticator: auth)
    let initial = try #require(lock.becameActive())
    await initial.value
    auth.result = .success(true)
    auth.pause = true
    let passcode = Task { await lock.unlock(using: .passcode) }
    await auth.waitForRequest()
    lock.enteredBackground()
    auth.finish()
    await passcode.value
    #expect(auth.methods == [.biometricsOrPasscode, .passcode])
    #expect(!lock.isUnlocked && lock.coversContent)
}
