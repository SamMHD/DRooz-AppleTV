import Foundation

// MARK: - Watch state rules

public enum PlaybackRules {
    public static let resumeMinMs: Int64 = 30_000
    /// A resume starts this much before the saved position, so the scene picks up where the viewer left it.
    public static let resumeRewindMs: Int64 = 3_000
    public static let finishedFraction = 0.9
    public static let upNextLeadMs: Int64 = 40_000
    public static let upNextCountdownS = 8
    public static let upNextMinDurationMs: Int64 = 120_000

    public static func isFinished(_ positionMs: Int64, _ durationMs: Int64) -> Bool {
        durationMs > 0 && Double(positionMs) >= Double(durationMs) * finishedFraction
    }

    public static func resumePosition(_ savedMs: Int64, _ durationMs: Int64, finished: Bool) -> Int64 {
        savedMs > resumeMinMs && !finished && !isFinished(savedMs, durationMs) ? savedMs : 0
    }

    public static func resumeStart(_ savedMs: Int64, _ durationMs: Int64, finished: Bool) -> Int64 {
        let p = resumePosition(savedMs, durationMs, finished: finished)
        return p > 0 ? max(p - resumeRewindMs, 0) : 0
    }

    public static func upNextDue(_ positionMs: Int64, _ durationMs: Int64) -> Bool {
        durationMs >= upNextMinDurationMs && durationMs - positionMs <= upNextLeadMs
    }

    public static func ordered(_ seasons: [Season]) -> [Episode] {
        seasons.sorted { $0.number < $1.number }.flatMap { $0.episodes.sorted { $0.number < $1.number } }
    }

    public static func nextEpisode(_ seasons: [Season], after streamId: String) -> Episode? {
        let all = ordered(seasons)
        guard let i = all.firstIndex(where: { $0.streamId == streamId }), i + 1 < all.count else { return nil }
        return all[i + 1]
    }
}

public struct WatchEntry: Codable, Hashable, Sendable {
    public var streamId: String
    public var refPath: String
    public var season: Int
    public var episode: Int
    public var positionMs: Int64
    public var durationMs: Int64
    public var updatedAt: Int64
    public var finished: Bool
    public var subtitleOffsetMs: Int64

    public init(streamId: String, refPath: String, season: Int, episode: Int, positionMs: Int64, durationMs: Int64,
                updatedAt: Int64 = 0, finished: Bool, subtitleOffsetMs: Int64 = 0) {
        self.streamId = streamId; self.refPath = refPath; self.season = season; self.episode = episode
        self.positionMs = positionMs; self.durationMs = durationMs; self.updatedAt = updatedAt
        self.finished = finished; self.subtitleOffsetMs = subtitleOffsetMs
    }

    var isDone: Bool { finished || PlaybackRules.isFinished(positionMs, durationMs) }
}

/// Local and server state of one episode. progress is in 0..1, non-nil only while resumable (not watched).
public struct EpisodeState: Equatable, Sendable {
    public let watched: Bool
    public let progress: Double?
    public let resumeMs: Int64
    public let remainingMin: Int?
}

/// A resumable local entry decides for its episode even when the server says played.
public func episodeState(_ ep: Episode, _ entry: WatchEntry?) -> EpisodeState {
    let resume = entry.map { PlaybackRules.resumePosition($0.positionMs, $0.durationMs, finished: $0.finished) } ?? 0
    guard let entry, resume > 0 else {
        let watched = ep.played || entry?.finished == true || (entry.map { PlaybackRules.isFinished($0.positionMs, $0.durationMs) } ?? false)
        return EpisodeState(watched: watched, progress: nil, resumeMs: 0, remainingMin: nil)
    }
    let progress = Double(entry.positionMs) / Double(entry.durationMs)
    let remaining = Int(ceil(Double(entry.durationMs - entry.positionMs) / 60_000))
    return EpisodeState(watched: false, progress: progress, resumeMs: resume, remainingMin: remaining)
}

public enum NextUp: Equatable, Sendable {
    /// Nothing watched yet: the first episode.
    case start(Episode)
    /// An episode is part-watched locally and nothing later was watched since.
    case resume(Episode, EpisodeState)
    /// The episode after the last watched one, across seasons.
    case next(Episode)
    /// Everything watched: offers the first episode again.
    case again(Episode)

    public var episode: Episode {
        switch self {
        case .start(let e), .next(let e), .again(let e): return e
        case .resume(let e, _): return e
        }
    }
}

/// nil when seasons has no episodes. entries are keyed by streamId.
public func nextUp(_ seasons: [Season], _ entries: [String: WatchEntry]) -> NextUp? {
    let ordered = PlaybackRules.ordered(seasons)
    guard let first = ordered.first else { return nil }
    let states = ordered.map { ($0, episodeState($0, entries[$0.streamId])) }

    // A partial episode is left behind once a later one is watched after it; a server-played one has no time.
    func superseded(_ i: Int) -> Bool {
        let at = entries[ordered[i].streamId]!.updatedAt
        return states[(i + 1)...].contains { ep, st in st.watched && (entries[ep.streamId]?.updatedAt ?? .max) > at }
    }
    let resumable = states.indices.filter { states[$0].1.progress != nil && !superseded($0) }
    if let best = resumable.max(by: { entries[ordered[$0].streamId]!.updatedAt < entries[ordered[$1].streamId]!.updatedAt }) {
        return .resume(states[best].0, states[best].1)
    }
    guard let last = states.lastIndex(where: { $0.1.watched }) else { return .start(first) }
    return last + 1 < ordered.count ? .next(ordered[last + 1]) : .again(first)
}

// MARK: - Continue watching

public struct ContinueItem: Equatable, Sendable {
    public let ref: TitleRef
    public let posterHash: String?
    public let subtitle: String?
    public let progress: Double?
    /// nil until the title's detail resolved; then OK plays this stream directly.
    public let playStreamId: String?
}

public enum ContinueWatching {
    /// At most this many titles come from local history alone.
    public static let localOnlyMax = 10

    /// Titles in row order: server order, then local-only titles newest first; de-duplicated by postId.
    /// `hidden` (postId → when removed from the row) leaves a title out until it is played again after that.
    public static func order(server: [PosterRef], local: [WatchEntry], hidden: [Int64: Int64] = [:]) -> [(TitleRef, String?)] {
        var newestByPost: [Int64: (TitleRef, WatchEntry)] = [:]
        for e in local {
            guard let ref = TitleRef.fromPath(e.refPath) else { continue }
            if let cur = newestByPost[ref.postId], cur.1.updatedAt >= e.updatedAt { continue }
            newestByPost[ref.postId] = (ref, e)
        }
        func isHidden(_ id: Int64) -> Bool {
            guard let at = hidden[id] else { return false }
            return (newestByPost[id]?.1.updatedAt ?? .min) <= at
        }
        var result: [(TitleRef, String?)] = []
        var seen = Set<Int64>()
        for p in server where !isHidden(p.ref.postId) && seen.insert(p.ref.postId).inserted {
            result.append((p.ref, p.posterHash))
        }
        let localOnly = newestByPost.values
            .sorted { $0.1.updatedAt > $1.1.updatedAt }
            .filter { ref, e in !seen.contains(ref.postId) && !isHidden(ref.postId) && !(ref.kind == .film && e.isDone) }
            .prefix(localOnlyMax)
        for (ref, _) in localOnly { result.append((ref, nil)) }
        return result
    }

    /// The card for a resolved title, or nil when it's done (series fully watched, film watched).
    public static func resolve(ref: TitleRef, posterHash: String?, detail: TitleDetail,
                               entries: [String: WatchEntry], dub: Bool) -> ContinueItem? {
        let seasons = dub ? detail.catalog.dub : detail.catalog.main
        guard let next = nextUp(seasons, entries) else { return nil }
        let ep = next.episode
        let film = ref.kind == .film
        let label = UiStrings.episodeLabel(ep.season, ep.number)
        var subtitle: String?
        var progress: Double?
        switch next {
        case .again: return nil
        case .start: subtitle = film ? nil : label
        case .next: subtitle = label
        case .resume(_, let st):
            subtitle = film ? UiStrings.remaining(st.remainingMin ?? 0) : label
            progress = st.progress
        }
        return ContinueItem(ref: ref, posterHash: posterHash, subtitle: subtitle, progress: progress, playStreamId: ep.streamId)
    }

    public static func pending(_ ref: TitleRef, _ posterHash: String?) -> ContinueItem {
        ContinueItem(ref: ref, posterHash: posterHash, subtitle: nil, progress: nil, playStreamId: nil)
    }
}

// MARK: - Home rows

public enum RowSource: Hashable, Sendable {
    case recent
    /// A section of the home page, by normalized title.
    case homeSection(String)
    case listPath(String)
}

public struct HomeRowConfig: Hashable, Sendable {
    public let key: String
    public let title: String
    public let source: RowSource
}

public enum HomeRows {
    public static let rows: [HomeRowConfig] = [
        .init(key: "recent", title: "ادامه تماشا", source: .recent),
        .init(key: "featured", title: "فیلم های برگزیده", source: .homeSection(PersianText.normalize("فیلم های برگزیده"))),
        .init(key: "updated-series", title: "سریال های بروز شده", source: .homeSection(PersianText.normalize("سریال های بروز شده"))),
        .init(key: "new-films", title: "فیلم های جدید", source: .homeSection(PersianText.normalize("فیلم های جدید"))),
        .init(key: "new-series", title: "سریال های جدید", source: .listPath("/archive/category/new-tv-show/")),
        .init(key: "popular", title: "سریال های محبوب", source: .listPath("/archive/playlist/show/most-popular-tv-shows/")),
        .init(key: "imdb-top", title: "سریال های برتر IMDb", source: .listPath("/archive/playlist/show/imdb-top-250-tv-series/")),
        .init(key: "dubbed", title: "دوبله فارسی", source: .listPath("/archive/category/dubbed-films/")),
        .init(key: "kids", title: "مناسب کودکان", source: .listPath("/archive/category/safe-for-children/")),
    ]
}

// MARK: - Backdrops

public enum Backdrop: Equatable, Sendable {
    case wide(URL)
    case blurredPoster(URL)
    case none
}

public enum BackdropResolver {
    public static func resolve(ref: TitleRef, featured: [TitleRef: String], played: [TitleRef: String],
                               detail: TitleDetail?, posterHash: String? = nil, w: Int = 1920, h: Int = 1080) -> Backdrop {
        if let f = featured[ref], let u = ImageUrls.backdrop(f, w, h) { return .wide(u) }
        if let p = played[ref], let u = URL(string: SiteConfig.baseURL + p) { return .wide(u) }
        if let t = detail?.trailerThumbHash, let u = ImageUrls.trailerThumb(t, w, h) { return .wide(u) }
        if let p = detail?.card.posterHash ?? posterHash, let u = ImageUrls.poster(p, 240, 360) { return .blurredPoster(u) }
        return .none
    }
}

// MARK: - Subtitles

public struct SubCue: Equatable, Sendable {
    public let startMs: Int64
    public let endMs: Int64
    public let text: String
}

/// Lenient SRT parser: malformed blocks are skipped, non-SRT input yields no cues.
public enum SrtParser {
    private static let timing = Rx(#"(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})"#)
    private static let tags = Rx(#"<[^>]+>|\{\\[^}]*\}"#)

    public static func parse(_ srt: String) -> [SubCue] {
        var text = srt
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var cues: [SubCue] = []
        var i = 0
        while i < lines.count {
            let g = timing.firstGroups(in: lines[i])
            i += 1
            guard let g else { continue }
            var body: [String] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, !timing.matches(lines[i]) {
                body.append(tags.replace(in: lines[i], with: "").trimmingCharacters(in: .whitespaces))
                i += 1
            }
            // Block without a blank separator: the trailing bare number is the next block's index.
            if i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
               let last = body.last, !last.isEmpty, last.allSatisfy(\.isNumber) {
                body.removeLast()
            }
            let joined = body.filter { !$0.isEmpty }.joined(separator: "\n")
            if !joined.isEmpty {
                cues.append(SubCue(startMs: ms(g[1], g[2], g[3], g[4]), endMs: ms(g[5], g[6], g[7], g[8]), text: joined))
            }
        }
        return cues.sorted { $0.startMs < $1.startMs }
    }

    private static func ms(_ h: String, _ m: String, _ s: String, _ frac: String) -> Int64 {
        let f = frac.padding(toLength: 3, withPad: "0", startingAt: 0)
        return ((Int64(h) ?? 0) * 3600 + (Int64(m) ?? 0) * 60 + (Int64(s) ?? 0)) * 1000 + (Int64(f) ?? 0)
    }
}

/// Cues indexed by start time for the position poll.
public struct SubtitleTimeline: Sendable {
    private let sorted: [SubCue]
    private let maxCueMs: Int64

    public init(_ cues: [SubCue]) {
        sorted = cues.sorted { $0.startMs < $1.startMs }
        maxCueMs = sorted.map { $0.endMs - $0.startMs }.max() ?? 0
    }

    public var isEmpty: Bool { sorted.isEmpty }

    /// Every cue with `startMs <= positionMs < endMs`, in start order.
    public func at(_ positionMs: Int64) -> [SubCue] {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid].startMs <= positionMs { lo = mid + 1 } else { hi = mid }
        }
        var result: [SubCue] = []
        var i = lo - 1
        while i >= 0 && sorted[i].startMs > positionMs - maxCueMs {
            if sorted[i].endMs > positionMs { result.append(sorted[i]) }
            i -= 1
        }
        return result.reversed()
    }
}

// MARK: - Audio Boost (the site's per-segment loudness map)

public struct GainSchedule: Sendable {
    let gains: [(Double, Double)]
    let minGain: Double?
    let maxGain: Double?

    public init(gains: [(Double, Double)], minGain: Double?, maxGain: Double?) {
        self.gains = gains; self.minGain = minGain; self.maxGain = maxGain
    }

    func clamp(_ v: Double) -> Double {
        var r = v
        if let minGain, r < minGain { r = minGain }
        if let maxGain, r > maxGain { r = maxGain }
        return r
    }

    public var isEmpty: Bool { gains.isEmpty }

    public func target(at positionSec: Double) -> Double {
        if gains.isEmpty { return 1 }
        var end = 0.0
        for (duration, gain) in gains {
            end += duration
            if end - 4 > positionSec { return clamp(gain * 0.9) }
        }
        return clamp(2)
    }

    /// The loudest boost the schedule can ask for: AVPlayer cannot amplify, so gains are applied relative to it.
    public var peak: Double {
        let all = gains.map { clamp($0.1 * 0.9) } + [clamp(2)]
        return max(all.max() ?? 1, 0.01)
    }
}

/// The site's gain smoothing: ignore changes of 0.01 or less, otherwise move 1/18 of the way.
public struct GainSmoother: Sendable {
    public private(set) var current: Double
    private var first = true

    public init(_ initial: Double = 1) { current = initial }

    public mutating func step(_ target: Double) -> Double {
        if first || (abs(target - current) * 100).rounded() > 1 {
            current = ((target + current * 17) / 18 * 100).rounded() / 100
        }
        first = false
        return current
    }
}

// MARK: - Quality labels

public struct QualityOption: Hashable, Sendable {
    public let height: Int
    public let label: String
    /// Peak bitrate of the variant (bps), used to cap AVPlayer's choice.
    public let peakBitRate: Double?
}

public struct VariantInfo: Hashable, Sendable {
    public let height: Int
    public let bitrateKbps: Int?
    public init(height: Int, bitrateKbps: Int?) { self.height = height; self.bitrateKbps = bitrateKbps }
}

/// One option per height (highest-bitrate variant of each), highest first, labelled like the site.
public func qualityOptions(_ variants: [VariantInfo], siteLabels: [Int: String]) -> [QualityOption] {
    let byHeight = Dictionary(grouping: variants, by: \.height)
        .compactMapValues { $0.max { ($0.bitrateKbps ?? -1) < ($1.bitrateKbps ?? -1) } }
    return byHeight.values.sorted { $0.height > $1.height }.map { v in
        let byRate = v.bitrateKbps.flatMap { kbps -> String? in
            if let exact = siteLabels[kbps] { return exact }
            guard let nearest = siteLabels.keys.min(by: { abs($0 - kbps) < abs($1 - kbps) }) else { return nil }
            return Double(abs(nearest - kbps)) <= Double(kbps) * 0.15 ? siteLabels[nearest] : nil
        }
        let byHeightLabel = siteLabels.values.sorted().first { Int($0.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }) == v.height }
        return QualityOption(height: v.height, label: byRate ?? byHeightLabel ?? "\(v.height)p",
                             peakBitRate: v.bitrateKbps.map { Double($0) * 1000 })
    }
}
