import Foundation

/// Prevents one-shot native requests from silently replacing an earlier
/// Flutter result and clears ownership when the requesting engine detaches.
final class SingleFlightRequestGate {
    private var ownerID: ObjectIdentifier?

    func begin(owner: AnyObject) -> Bool {
        guard ownerID == nil else { return false }
        ownerID = ObjectIdentifier(owner)
        return true
    }

    func complete() {
        ownerID = nil
    }

    func detach(owner: AnyObject) -> Bool {
        guard ownerID == ObjectIdentifier(owner) else { return false }
        ownerID = nil
        return true
    }
}
