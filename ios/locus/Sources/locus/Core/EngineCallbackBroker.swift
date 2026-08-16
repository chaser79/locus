import Foundation

protocol CallbackDeadlineCancellation: AnyObject {
    func cancel()
}

typealias CallbackDeadlineScheduler = (
    _ delay: TimeInterval,
    _ callback: @escaping () -> Void
) -> CallbackDeadlineCancellation

private final class DispatchWorkItemDeadline: CallbackDeadlineCancellation {
    private let workItem: DispatchWorkItem

    init(_ workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

func mainQueueCallbackDeadlineScheduler(
    delay: TimeInterval,
    callback: @escaping () -> Void
) -> CallbackDeadlineCancellation {
    let workItem = DispatchWorkItem(block: callback)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    return DispatchWorkItemDeadline(workItem)
}

/// Gives engine-scoped Dart callbacks process-owned completion semantics.
///
/// Each request is tied to an engine owner/generation, bounded by a deadline,
/// retried once on the newest different live engine, and then completed through
/// the existing headless/default fallback. Superseded and late replies are
/// ignored so the native caller observes exactly one completion.
final class EngineCallbackBroker {
    private let bindings: EngineBindingRegistry
    private let deadlineScheduler: CallbackDeadlineScheduler
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var pending: [UInt64: PendingEngineCallback] = [:]
    private var nextRequestID: UInt64 = 0

    init(
        bindings: EngineBindingRegistry,
        deadlineScheduler: @escaping CallbackDeadlineScheduler,
        timeout: TimeInterval = 10
    ) {
        self.bindings = bindings
        self.deadlineScheduler = deadlineScheduler
        self.timeout = timeout
    }

    func request<Result>(
        invoke: @escaping (AnyObject, @escaping (Result) -> Void) -> Void,
        fallback: @escaping (@escaping (Result) -> Void) -> Void,
        terminalDefault: @escaping () -> Result,
        completion: @escaping (Result) -> Void
    ) {
        let requestID: UInt64 = withLock {
            nextRequestID += 1
            return nextRequestID
        }
        let operation = EngineCallbackOperation(
            bindingProvider: { [bindings] excluded in
                bindings.activeSnapshot(excludingOwners: excluded)
            },
            bindingIsLive: { [bindings] snapshot in
                bindings.contains(snapshot)
            },
            deadlineScheduler: deadlineScheduler,
            timeout: timeout,
            invoke: invoke,
            fallback: fallback,
            terminalDefault: terminalDefault,
            completion: completion,
            onFinish: { [weak self] in
                guard let self else { return }
                self.withLock { self.pending.removeValue(forKey: requestID) }
            }
        )
        withLock { pending[requestID] = operation }
        operation.start()
    }

    func ownerDetached(_ owner: AnyObject) {
        let affected = withLock { pending.values.filter { $0.isOwned(by: owner) } }
        affected.forEach { $0.ownerDetached(owner) }
    }

    func bindingClaimed(_ binding: EngineBindingSnapshot) {
        let affected = withLock {
            pending.values.filter {
                $0.isOlderGeneration(owner: binding.owner, generation: binding.generation)
            }
        }
        affected.forEach {
            $0.bindingReplaced(owner: binding.owner, generation: binding.generation)
        }
    }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private protocol PendingEngineCallback: AnyObject {
    func isOwned(by owner: AnyObject) -> Bool
    func isOlderGeneration(owner: AnyObject, generation: UInt64) -> Bool
    func ownerDetached(_ owner: AnyObject)
    func bindingReplaced(owner: AnyObject, generation: UInt64)
}

private final class EngineCallbackOperation<Result>: PendingEngineCallback {
    private static var maxEngineAttempts: Int { 2 }

    private let bindingProvider: ([AnyObject]) -> EngineBindingSnapshot?
    private let bindingIsLive: (EngineBindingSnapshot) -> Bool
    private let deadlineScheduler: CallbackDeadlineScheduler
    private let timeout: TimeInterval
    private let invoke: (AnyObject, @escaping (Result) -> Void) -> Void
    private let fallback: (@escaping (Result) -> Void) -> Void
    private let terminalDefault: () -> Result
    private let completion: (Result) -> Void
    private let onFinish: () -> Void
    private let lock = NSLock()
    private var attemptedOwners: [AnyObject] = []
    private var activeBinding: EngineBindingSnapshot?
    private var activeToken: UInt64 = 0
    private var deadline: CallbackDeadlineCancellation?
    private var completed = false
    private var fallbackStarted = false

    init(
        bindingProvider: @escaping ([AnyObject]) -> EngineBindingSnapshot?,
        bindingIsLive: @escaping (EngineBindingSnapshot) -> Bool,
        deadlineScheduler: @escaping CallbackDeadlineScheduler,
        timeout: TimeInterval,
        invoke: @escaping (AnyObject, @escaping (Result) -> Void) -> Void,
        fallback: @escaping (@escaping (Result) -> Void) -> Void,
        terminalDefault: @escaping () -> Result,
        completion: @escaping (Result) -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.bindingProvider = bindingProvider
        self.bindingIsLive = bindingIsLive
        self.deadlineScheduler = deadlineScheduler
        self.timeout = timeout
        self.invoke = invoke
        self.fallback = fallback
        self.terminalDefault = terminalDefault
        self.completion = completion
        self.onFinish = onFinish
    }

    func start() {
        advanceFromEngine(expectedToken: nil)
    }

    func isOwned(by owner: AnyObject) -> Bool {
        withLock { !completed && activeBinding?.owner === owner }
    }

    func isOlderGeneration(owner: AnyObject, generation: UInt64) -> Bool {
        withLock {
            !completed &&
                activeBinding?.owner === owner &&
                (activeBinding?.generation ?? generation) < generation
        }
    }

    func ownerDetached(_ owner: AnyObject) {
        let token: UInt64? = withLock {
            activeBinding?.owner === owner ? activeToken : nil
        }
        guard let token else { return }
        advanceFromEngine(expectedToken: token)
    }

    func bindingReplaced(owner: AnyObject, generation: UInt64) {
        let token: UInt64? = withLock {
            guard activeBinding?.owner === owner,
                  let currentGeneration = activeBinding?.generation,
                  currentGeneration < generation else {
                return nil
            }
            return activeToken
        }
        guard let token else { return }
        advanceFromEngine(expectedToken: token)
    }

    private func advanceFromEngine(expectedToken: UInt64?) {
        let transition: (token: UInt64, exclusions: [AnyObject], deadline: CallbackDeadlineCancellation?)? = withLock {
            guard !completed, !fallbackStarted else { return nil }
            if let expectedToken, expectedToken != activeToken { return nil }
            let oldDeadline = deadline
            deadline = nil
            activeBinding = nil
            activeToken += 1
            return (activeToken, attemptedOwners, oldDeadline)
        }
        guard let transition else { return }
        transition.deadline?.cancel()

        let next = transition.exclusions.count < Self.maxEngineAttempts
            ? bindingProvider(transition.exclusions)
            : nil
        if let next {
            beginEngineAttempt(next, transitionToken: transition.token)
        } else {
            beginFallback(transitionToken: transition.token)
        }
    }

    private func beginEngineAttempt(
        _ binding: EngineBindingSnapshot,
        transitionToken: UInt64
    ) {
        let shouldInvoke = withLock {
            guard !completed,
                  !fallbackStarted,
                  activeToken == transitionToken else {
                return false
            }
            attemptedOwners.append(binding.owner)
            activeBinding = binding
            return true
        }
        guard shouldInvoke else { return }
        guard bindingIsLive(binding) else {
            advanceFromEngine(expectedToken: transitionToken)
            return
        }

        installDeadline(token: transitionToken) { [weak self] in
            self?.advanceFromEngine(expectedToken: transitionToken)
        }
        let isCurrent = withLock {
            !completed &&
                activeToken == transitionToken &&
                activeBinding?.owner === binding.owner &&
                activeBinding?.generation == binding.generation
        }
        guard isCurrent else { return }
        invoke(binding.owner) { [weak self] value in
            self?.completeIfCurrent(token: transitionToken, value: value)
        }
    }

    private func beginFallback(transitionToken: UInt64) {
        let shouldInvoke = withLock {
            guard !completed,
                  !fallbackStarted,
                  activeToken == transitionToken else {
                return false
            }
            fallbackStarted = true
            return true
        }
        guard shouldInvoke else { return }

        installDeadline(token: transitionToken) { [weak self] in
            guard let self else { return }
            self.completeIfCurrent(
                token: transitionToken,
                value: self.terminalDefault()
            )
        }
        fallback { [weak self] value in
            self?.completeIfCurrent(token: transitionToken, value: value)
        }
    }

    private func installDeadline(token: UInt64, callback: @escaping () -> Void) {
        let cancellation = deadlineScheduler(timeout, callback)
        let shouldCancel = withLock {
            if completed || token != activeToken {
                return true
            }
            deadline = cancellation
            return false
        }
        if shouldCancel { cancellation.cancel() }
    }

    private func completeIfCurrent(token: UInt64, value: Result) {
        let transition: (accepted: Bool, cancellation: CallbackDeadlineCancellation?) = withLock {
            guard !completed, token == activeToken else { return (false, nil) }
            completed = true
            let currentDeadline = deadline
            deadline = nil
            activeBinding = nil
            return (true, currentDeadline)
        }
        guard transition.accepted else { return }
        transition.cancellation?.cancel()
        onFinish()
        completion(value)
    }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
