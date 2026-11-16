import Foundation

/// At most one operation runs per consumer. While it runs, new requests replace the
/// pending request; a stale operation can stop before its next expensive stage.
@MainActor
final class LatestWork {
    private var generation = 0
    private var pending: (Int, (@escaping () -> Bool) async -> Void)?
    private var worker: Task<Void, Never>?

    func submit(_ operation: @escaping (@escaping () -> Bool) async -> Void) {
        generation += 1
        pending = (generation, operation)
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while let (version, operation) = self.pending {
                self.pending = nil
                await operation { self.generation == version }
            }
            self.worker = nil
        }
    }
}
