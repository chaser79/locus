import XCTest
#if canImport(Locus)
@testable import Locus
#elseif canImport(locus)
@testable import locus
#endif

final class EngineBindingRegistryTests: XCTestCase {
    private final class Binding {}

    func testCancelPromotesSurvivingListener() {
        let registry = EngineBindingRegistry()
        let first = Binding()
        let second = Binding()

        registry.beginListening(first)
        registry.beginListening(second)
        registry.endListening(second)

        XCTAssertTrue(registry.activeBinding === first)
    }

    func testDetachPromotesSurvivingListener() {
        let registry = EngineBindingRegistry()
        let first = Binding()
        let second = Binding()

        registry.beginListening(first)
        registry.beginListening(second)
        registry.detach(second)

        XCTAssertTrue(registry.activeBinding === first)
    }

    func testMethodOnlyEngineCannotStealActiveListener() {
        let registry = EngineBindingRegistry()
        let listener = Binding()
        let background = Binding()

        registry.beginListening(listener)
        registry.activateForMethod(background)

        XCTAssertTrue(registry.activeBinding === listener)
    }

    func testConcurrentReadsAndMutationsLeaveRegistryUsable() {
        let registry = EngineBindingRegistry()
        let bindings = (0..<32).map { _ in Binding() }
        let group = DispatchGroup()
        let workerQueue = DispatchQueue(
            label: "dev.locus.engine-binding-registry-tests",
            attributes: .concurrent
        )

        for index in 0..<2_000 {
            group.enter()
            workerQueue.async {
                let binding = bindings[index % bindings.count]
                switch index % 4 {
                case 0: registry.beginListening(binding)
                case 1: registry.activateForMethod(binding)
                case 2: registry.endListening(binding)
                default: registry.detach(binding)
                }
                _ = registry.activeBinding
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        let finalBinding = Binding()
        registry.beginListening(finalBinding)
        XCTAssertTrue(registry.activeBinding === finalBinding)
    }

    func testConcurrentSnapshotReadsTolerateWeakBindingDeallocation() {
        let registry = EngineBindingRegistry()
        let group = DispatchGroup()
        let workerQueue = DispatchQueue(
            label: "dev.locus.engine-binding-deallocation-tests",
            attributes: .concurrent
        )

        for _ in 0..<2_000 {
            group.enter()
            workerQueue.async {
                autoreleasepool {
                    let transient = Binding()
                    registry.beginListening(transient)
                    _ = registry.activeSnapshot()
                }
                _ = registry.activeSnapshot()
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        _ = registry.activeSnapshot()
    }
}
