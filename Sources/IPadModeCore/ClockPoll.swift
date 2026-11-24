public extension Clock where Duration == Swift.Duration {
    /// Checks `condition` now and then every `interval` until it holds or `timeout` has passed on this clock.
    /// A member rather than a generic function, so that calling it on `any Clock` opens the existential.
    @MainActor func poll(timeout: Duration, every interval: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = now.advanced(by: timeout)
        while !condition() {
            let current = now
            guard current < deadline else { return false }
            do { try await sleep(until: min(current.advanced(by: interval), deadline), tolerance: nil) }
            catch { return condition() }
        }
        return true
    }

    /// The time on this clock since this call, read each time the returned function is called. A member like
    /// `poll`, for the same reason.
    func stopwatch() -> @Sendable () -> Duration {
        let start = now
        return { start.duration(to: self.now) }
    }
}
