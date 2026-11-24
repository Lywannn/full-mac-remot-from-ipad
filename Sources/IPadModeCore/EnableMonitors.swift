public extension DisplayBackend {
    /// Turns `ids` on in one transaction, and when that fails, each in a transaction of its own, so that one monitor
    /// that cannot be enabled does not keep the others off (R69). Returns the IDs whose enable was accepted.
    /// `failed` hears of each failed transaction: the batch with all its IDs, then each monitor that failed alone.
    func enableMonitors(_ ids: [DisplayID], scope: ConfigScope,
                        failed: ([DisplayID], any Error) -> Void) -> [DisplayID] {
        guard !ids.isEmpty else { return [] }
        do {
            try setEnabled(ids, enabled: true, scope: scope)
            return ids
        } catch {
            failed(ids, error)
        }
        guard ids.count > 1 else { return [] }
        return ids.filter { id in
            do {
                try setEnabled([id], enabled: true, scope: scope)
                return true
            } catch {
                failed([id], error)
                return false
            }
        }
    }
}
