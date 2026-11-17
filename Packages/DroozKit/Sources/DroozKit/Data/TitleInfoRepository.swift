import Foundation

/// Counts permits; `acquire` waits for one (FIFO).
actor AsyncSemaphore {
    private var free: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ n: Int) { free = n }
    func acquire() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { free += 1 } else { waiters.removeFirst().resume() }
    }
}

/// Title details cache: TTL, in-flight dedupe, at most 2 concurrent background fetches; failures are not cached.
/// A play changes the page (played ✓, next episode): `invalidate` makes the next `get` refetch while
/// `lastKnown` still serves the old detail for an instant display.
public actor TitleInfoRepository {
    public static let pageMaxAge: TimeInterval = 15 * 60
    private let ttl: TimeInterval = 24 * 3600
    private let fetch: @Sendable (TitleRef) async throws -> TitleDetail

    private struct Entry { let detail: TitleDetail; let at: Date; var stale: Bool }
    private var cache: [TitleRef: Entry] = [:]
    private var inFlight: [TitleRef: Task<TitleDetail, Error>] = [:]
    private var versions: [TitleRef: Int] = [:]
    private var epoch = 0
    private let background = AsyncSemaphore(2)

    /// Stream-page backdrop paths recorded after playback.
    public private(set) var playedBackdrops: [TitleRef: String] = [:]
    /// Counts plays (invalidations): home revalidates «ادامه تماشا» when it changed.
    public private(set) var invalidations = 0
    /// Counts «لیست من» toggles.
    public private(set) var watchlistChanges = 0

    public init(fetch: @escaping @Sendable (TitleRef) async throws -> TitleDetail) { self.fetch = fetch }

    /// `maxAge`: a cached detail older than this is refetched. `priority`: skips the background queue.
    public func get(_ ref: TitleRef, maxAge: TimeInterval? = nil, priority: Bool = false) async throws -> TitleDetail {
        if let d = fresh(ref, maxAge ?? ttl) { return d }
        if let t = inFlight[ref] { return try await t.value }
        let stamp = (epoch, versions[ref] ?? 0)
        let fetch = self.fetch
        let sem = background
        let task = Task<TitleDetail, Error> {
            if !priority { await sem.acquire() }
            defer { if !priority { Task { await sem.release() } } }
            return try await fetch(ref)
        }
        inFlight[ref] = task
        do {
            let d = try await task.value
            if inFlight[ref] == task { inFlight[ref] = nil }
            if stamp == (epoch, versions[ref] ?? 0) { cache[ref] = Entry(detail: d, at: Date(), stale: false) }
            return d
        } catch {
            if inFlight[ref] == task { inFlight[ref] = nil }
            throw error
        }
    }

    public func peek(_ ref: TitleRef) -> TitleDetail? { fresh(ref, ttl) }

    /// The cached detail even if invalidated (within the TTL).
    public func lastKnown(_ ref: TitleRef) -> TitleDetail? {
        guard let e = cache[ref], Date().timeIntervalSince(e.at) < ttl else { return nil }
        return e.detail
    }

    public func invalidate(_ ref: TitleRef) {
        versions[ref, default: 0] += 1
        inFlight[ref] = nil
        cache[ref]?.stale = true
        invalidations += 1
    }

    public func patch(_ ref: TitleRef, _ f: (inout TitleDetail) -> Void) {
        guard var e = cache[ref] else { return }
        var d = e.detail
        f(&d)
        e = Entry(detail: d, at: e.at, stale: e.stale)
        cache[ref] = e
    }

    public func watchlistChanged() { watchlistChanges += 1 }

    public func remember(_ ref: TitleRef, backdropPath: String) { playedBackdrops[ref] = backdropPath }

    public func clear() {
        epoch += 1
        versions = [:]
        inFlight = [:]
        cache = [:]
        playedBackdrops = [:]
    }

    private func fresh(_ ref: TitleRef, _ maxAge: TimeInterval) -> TitleDetail? {
        guard let e = cache[ref], !e.stale, Date().timeIntervalSince(e.at) < min(maxAge, ttl) else { return nil }
        return e.detail
    }
}
