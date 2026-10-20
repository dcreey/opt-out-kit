import Foundation

/// Per-device progress. Platform stores persist this as JSON; the core stays platform-neutral.
public struct Progress: Codable, Equatable, Sendable {
    public var completedSteps: [String: Set<Int>] = [:]
    public var doneAt: [String: Date] = [:]

    public init() {}

    public func isStepDone(_ brokerID: String, _ index: Int) -> Bool {
        completedSteps[brokerID]?.contains(index) ?? false
    }

    public func isDone(_ brokerID: String) -> Bool { doneAt[brokerID] != nil }

    /// A step is available once every earlier step is done.
    public func isUnlocked(_ brokerID: String, step index: Int) -> Bool {
        (0..<index).allSatisfy { isStepDone(brokerID, $0) }
    }

    public mutating func complete(_ broker: Broker, step index: Int, now: Date = Date()) {
        guard broker.steps.indices.contains(index), isUnlocked(broker.id, step: index) else { return }
        completedSteps[broker.id, default: []].insert(index)
        if (0..<broker.steps.count).allSatisfy({ isStepDone(broker.id, $0) }) { doneAt[broker.id] = now }
    }

    public mutating func reset(_ brokerID: String) {
        completedSteps[brokerID] = nil
        doneAt[brokerID] = nil
    }

    /// Next broker in queue order that is not done. Drives the "next-best step" button.
    public func nextBroker(in queue: [Broker]) -> Broker? { queue.first { !isDone($0.id) } }

    /// Share of queued brokers done. TODO: exposure ring should count only re-verified brokers.
    public func completion(in queue: [Broker]) -> Double {
        queue.isEmpty ? 0 : Double(queue.filter { isDone($0.id) }.count) / Double(queue.count)
    }
}
