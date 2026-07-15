import Foundation

struct EngineBindingSnapshot {
    let owner: AnyObject
    let generation: UInt64
}

/// Selects the Flutter engine that owns method callbacks and event delivery
/// while retaining only weak references to engine-scoped plugin bindings.
///
/// A listener takes precedence over method-only background engines. When the
/// active listener cancels or detaches, the most recently registered surviving
/// listener is promoted instead of orphaning the event stream.
final class EngineBindingRegistry {
    private final class Entry {
        weak var binding: AnyObject?
        var isListening: Bool
        let generation: UInt64

        init(binding: AnyObject, generation: UInt64, isListening: Bool = false) {
            self.binding = binding
            self.generation = generation
            self.isListening = isListening
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var order: [ObjectIdentifier] = []
    private var activeID: ObjectIdentifier?
    private var nextGeneration: UInt64 = 0
    private let lock = NSLock()

    var activeBinding: AnyObject? {
        activeSnapshot()?.owner
    }

    func activeSnapshot(excludingOwners: [AnyObject] = []) -> EngineBindingSnapshot? {
        withLock {
            compactLocked()
            let candidate: (ObjectIdentifier, Bool) -> EngineBindingSnapshot? = { id, requireListener in
                guard let entry = self.entries[id],
                      !requireListener || entry.isListening,
                      let owner = entry.binding,
                      !excludingOwners.contains(where: { $0 === owner }) else {
                    return nil
                }
                return EngineBindingSnapshot(owner: owner, generation: entry.generation)
            }

            if let activeID, let active = candidate(activeID, false) {
                return active
            }

            for id in order.reversed() {
                if let listener = candidate(id, true) {
                    return listener
                }
            }

            for id in order.reversed() {
                if let fallback = candidate(id, false) {
                    return fallback
                }
            }
            return nil
        }
    }

    func contains(_ snapshot: EngineBindingSnapshot) -> Bool {
        withLock {
            compactLocked()
            let id = ObjectIdentifier(snapshot.owner)
            guard let entry = entries[id],
                  entry.generation == snapshot.generation,
                  let owner = entry.binding else {
                return false
            }
            return owner === snapshot.owner
        }
    }

    @discardableResult
    func activateForMethod(_ binding: AnyObject) -> EngineBindingSnapshot {
        withLock {
            let registration = registerLocked(binding)
            let id = registration.id
            if let activeID,
               activeID != id,
               entries[activeID]?.isListening == true,
               !registration.entry.isListening {
                return EngineBindingSnapshot(
                    owner: binding,
                    generation: registration.entry.generation
                )
            }
            self.activeID = id
            return EngineBindingSnapshot(
                owner: binding,
                generation: registration.entry.generation
            )
        }
    }

    @discardableResult
    func beginListening(_ binding: AnyObject) -> EngineBindingSnapshot {
        withLock {
            let registration = registerLocked(binding)
            registration.entry.isListening = true
            activeID = registration.id
            return EngineBindingSnapshot(
                owner: binding,
                generation: registration.entry.generation
            )
        }
    }

    func endListening(_ binding: AnyObject) {
        withLock {
            let id = ObjectIdentifier(binding)
            entries[id]?.isListening = false
            if activeID == id {
                activeID = mostRecentListenerIDLocked() ?? id
            }
            compactLocked()
        }
    }

    func detach(_ binding: AnyObject) {
        withLock {
            let id = ObjectIdentifier(binding)
            entries.removeValue(forKey: id)
            order.removeAll { $0 == id }
            if activeID == id {
                activeID = mostRecentListenerIDLocked() ?? order.last
            }
            compactLocked()
        }
    }

    private func registerLocked(
        _ binding: AnyObject
    ) -> (id: ObjectIdentifier, entry: Entry) {
        compactLocked()
        let id = ObjectIdentifier(binding)
        if let entry = entries[id] {
            return (id, entry)
        }
        nextGeneration += 1
        let entry = Entry(binding: binding, generation: nextGeneration)
        entries[id] = entry
        order.append(id)
        return (id, entry)
    }

    private func mostRecentListenerIDLocked() -> ObjectIdentifier? {
        order.last { entries[$0]?.binding != nil && entries[$0]?.isListening == true }
    }

    private func compactLocked() {
        let dead = entries.compactMap { id, entry in
            entry.binding == nil ? id : nil
        }
        guard !dead.isEmpty else { return }
        let deadSet = Set(dead)
        entries = entries.filter { !deadSet.contains($0.key) }
        order.removeAll { deadSet.contains($0) }
        if let activeID, deadSet.contains(activeID) {
            self.activeID = mostRecentListenerIDLocked() ?? order.last
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
