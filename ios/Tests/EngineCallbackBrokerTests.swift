import XCTest
#if canImport(Locus)
@testable import Locus
#elseif canImport(locus)
@testable import locus
#endif

final class EngineCallbackBrokerTests: XCTestCase {
    private final class Binding: NSObject {
        let name: String

        init(_ name: String) {
            self.name = name
        }
    }

    func testDetachRetriesNewestDifferentEngineAndIgnoresLateReply() {
        let registry = EngineBindingRegistry()
        let scheduler = ManualDeadlineScheduler()
        let broker = makeBroker(registry: registry, scheduler: scheduler)
        let first = Binding("first")
        let second = Binding("second")
        var replies: [String: (String) -> Void] = [:]
        var invocations: [String] = []
        var results: [String] = []

        registry.beginListening(first)
        broker.request(
            invoke: { owner, reply in
                let binding = owner as! Binding
                invocations.append(binding.name)
                replies[binding.name] = reply
            },
            fallback: { $0("fallback") },
            terminalDefault: { "default" },
            completion: { results.append($0) }
        )

        broker.bindingClaimed(registry.beginListening(second))
        registry.detach(first)
        broker.ownerDetached(first)

        XCTAssertEqual(invocations, ["first", "second"])
        replies["first"]?("late")
        XCTAssertTrue(results.isEmpty)
        replies["second"]?("second-result")
        scheduler.runAll()
        XCTAssertEqual(results, ["second-result"])
    }

    func testDeadlineRetriesNewerEngineBeforeFallback() {
        let registry = EngineBindingRegistry()
        let scheduler = ManualDeadlineScheduler()
        let broker = makeBroker(registry: registry, scheduler: scheduler)
        let first = Binding("first")
        let second = Binding("second")
        var replies: [String: (String) -> Void] = [:]
        var invocations: [String] = []
        var results: [String] = []

        registry.beginListening(first)
        broker.request(
            invoke: { owner, reply in
                let binding = owner as! Binding
                invocations.append(binding.name)
                replies[binding.name] = reply
            },
            fallback: { $0("fallback") },
            terminalDefault: { "default" },
            completion: { results.append($0) }
        )
        broker.bindingClaimed(registry.beginListening(second))

        scheduler.runNext()

        XCTAssertEqual(invocations, ["first", "second"])
        replies["second"]?("second-result")
        replies["first"]?("late")
        scheduler.runAll()
        XCTAssertEqual(results, ["second-result"])
    }

    func testTwoEngineDeadlinesUseFallbackExactlyOnce() {
        let registry = EngineBindingRegistry()
        let scheduler = ManualDeadlineScheduler()
        let broker = makeBroker(registry: registry, scheduler: scheduler)
        let first = Binding("first")
        let second = Binding("second")
        var replies: [(String) -> Void] = []
        var invocations: [String] = []
        var results: [String] = []

        registry.beginListening(first)
        broker.request(
            invoke: { owner, reply in
                invocations.append((owner as! Binding).name)
                replies.append(reply)
            },
            fallback: { $0("fallback") },
            terminalDefault: { "default" },
            completion: { results.append($0) }
        )
        broker.bindingClaimed(registry.beginListening(second))

        scheduler.runNext()
        scheduler.runNext()
        replies.forEach { $0("late") }
        scheduler.runAll()

        XCTAssertEqual(invocations, ["first", "second"])
        XCTAssertEqual(results, ["fallback"])
    }

    func testSameOwnerNewGenerationInvalidatesOldAttemptWithoutRetryingOwner() {
        let registry = EngineBindingRegistry()
        let scheduler = ManualDeadlineScheduler()
        let broker = makeBroker(registry: registry, scheduler: scheduler)
        let owner = Binding("owner")
        var oldReply: ((String) -> Void)?
        var invocations: [String] = []
        var results: [String] = []

        registry.beginListening(owner)
        broker.request(
            invoke: { binding, reply in
                invocations.append((binding as! Binding).name)
                oldReply = reply
            },
            fallback: { $0("fallback") },
            terminalDefault: { "default" },
            completion: { results.append($0) }
        )

        registry.detach(owner)
        broker.bindingClaimed(registry.beginListening(owner))
        oldReply?("late")
        scheduler.runAll()

        XCTAssertEqual(invocations, ["owner"])
        XCTAssertEqual(results, ["fallback"])
    }

    func testFallbackDeadlineUsesTerminalDefaultAndSuppressesLateReply() {
        let registry = EngineBindingRegistry()
        let scheduler = ManualDeadlineScheduler()
        let broker = makeBroker(registry: registry, scheduler: scheduler)
        var fallbackReply: ((String) -> Void)?
        var results: [String] = []

        broker.request(
            invoke: { _, _ in XCTFail("No engine should be invoked") },
            fallback: { fallbackReply = $0 },
            terminalDefault: { "default" },
            completion: { results.append($0) }
        )

        scheduler.runNext()
        fallbackReply?("late")

        XCTAssertEqual(results, ["default"])
    }

    private func makeBroker(
        registry: EngineBindingRegistry,
        scheduler: ManualDeadlineScheduler
    ) -> EngineCallbackBroker {
        EngineCallbackBroker(
            bindings: registry,
            deadlineScheduler: scheduler.schedule
        )
    }

    private final class ManualDeadlineScheduler {
        private final class Task {
            let callback: () -> Void
            var cancelled = false

            init(callback: @escaping () -> Void) {
                self.callback = callback
            }
        }

        private final class Cancellation: CallbackDeadlineCancellation {
            private let task: Task

            init(task: Task) {
                self.task = task
            }

            func cancel() {
                task.cancelled = true
            }
        }

        private var tasks: [Task] = []

        func schedule(
            delay: TimeInterval,
            callback: @escaping () -> Void
        ) -> CallbackDeadlineCancellation {
            XCTAssertEqual(delay, 10)
            let task = Task(callback: callback)
            tasks.append(task)
            return Cancellation(task: task)
        }

        func runNext() {
            while !tasks.isEmpty {
                let task = tasks.removeFirst()
                if !task.cancelled {
                    task.callback()
                    return
                }
            }
            XCTFail("No active deadline was scheduled")
        }

        func runAll() {
            while tasks.contains(where: { !$0.cancelled }) {
                runNext()
            }
            tasks.removeAll()
        }
    }
}
