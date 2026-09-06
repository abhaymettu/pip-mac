import Foundation

public protocol BindingStore: Sendable {
    /// Implementations must return an atomic value snapshot.
    func binding(for slot: Slot) async -> Binding?
}

public actor InMemoryBindingStore: BindingStore {
    private var bindings: [Slot: Binding]

    public init(bindings: [Binding]) {
        self.bindings = Dictionary(
            bindings.map { ($0.slot, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    public func binding(for slot: Slot) -> Binding? {
        bindings[slot]
    }

    public func set(_ binding: Binding) {
        bindings[binding.slot] = binding
    }
}

public actor PipControl {
    private var mode: InputMode
    private var pausedUntil: Date?

    public init(inputMode: InputMode = .chassisTaps) {
        mode = inputMode
    }

    public func setInputMode(_ mode: InputMode) {
        self.mode = mode
    }

    public func pause(minutes: Int, now: Date = Date()) throws {
        try ActionKind.pausePip(minutes: minutes).validate()
        pausedUntil = now.addingTimeInterval(TimeInterval(minutes) * 60)
    }

    public func resume() {
        pausedUntil = nil
    }

    public func isAccepting(_ inputMode: InputMode, now: Date = Date()) -> Bool {
        inputMode == mode && (pausedUntil.map { $0 <= now } ?? true)
    }
}

public actor GestureRouter {
    private let store: any BindingStore
    private let control: PipControl

    // IDs remain tombstoned for this router's lifetime, including rejected events.
    // There is intentionally no eviction that could re-enable an old group.
    private var seenGroups = Set<UUID>()

    public init(store: any BindingStore, control: PipControl = PipControl()) {
        self.store = store
        self.control = control
    }

    public func route(_ event: GestureEvent) async -> RoutedGesture? {
        // Insert before any suspension: concurrent deliveries cannot both win.
        guard seenGroups.insert(event.groupID).inserted else { return nil }
        guard await control.isAccepting(event.inputMode) else { return nil }
        guard let snapshot = await store.binding(for: Slot(event.gesture)),
              snapshot.enabled else {
            return nil
        }
        // Recheck after the store suspension, e.g. if Pip was paused meanwhile.
        guard await control.isAccepting(event.inputMode) else { return nil }
        return RoutedGesture(event: event, binding: snapshot)
    }
}
