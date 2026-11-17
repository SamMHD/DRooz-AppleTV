import Foundation

/// tvOS keeps `UserDefaults` (≈ 1 MB) across purges of the app's caches; every small local state lives there.
/// Each store owns one JSON value under its key.
final class DefaultsJSON<T: Codable>: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    init(_ defaults: UserDefaults, _ key: String) { self.defaults = defaults; self.key = key }

    func load() -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func save(_ value: T?) {
        if let value, let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
}

func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

/// Local per-stream watch state, newest first; capped.
public final class WatchStore: @unchecked Sendable {
    public static let cap = 400
    private let box: DefaultsJSON<[WatchEntry]>
    private let lock = NSLock()
    private var entries: [String: WatchEntry]
    private let clock: () -> Int64

    public init(defaults: UserDefaults = .standard, clock: @escaping () -> Int64 = nowMs) {
        box = DefaultsJSON(defaults, "watch.v1")
        self.clock = clock
        entries = Dictionary((box.load() ?? []).map { ($0.streamId, $0) }, uniquingKeysWith: { a, b in a.updatedAt > b.updatedAt ? a : b })
    }

    public func get(_ streamId: String) -> WatchEntry? { lock.lock(); defer { lock.unlock() }; return entries[streamId] }

    /// Inserts or replaces by streamId; stamps updatedAt from the store's clock.
    public func put(_ entry: WatchEntry) {
        lock.lock()
        var e = entry
        e.updatedAt = clock()
        entries[e.streamId] = e
        if entries.count > Self.cap {
            for old in entries.values.sorted(by: { $0.updatedAt < $1.updatedAt }).prefix(entries.count - Self.cap) {
                entries.removeValue(forKey: old.streamId)
            }
        }
        let snapshot = Array(entries.values)
        lock.unlock()
        box.save(snapshot)
    }

    public func all() -> [WatchEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func clear() { lock.lock(); entries = [:]; lock.unlock(); box.save(nil) }
}

/// Titles the user removed from «ادامه تماشا» on this TV: postId → when.
public final class HiddenTitles: @unchecked Sendable {
    private let box: DefaultsJSON<[String: Int64]>
    private let lock = NSLock()
    private var map: [Int64: Int64]

    public init(defaults: UserDefaults = .standard) {
        box = DefaultsJSON(defaults, "hidden.v1")
        map = Dictionary(uniqueKeysWithValues: (box.load() ?? [:]).compactMap { k, v in Int64(k).map { ($0, v) } })
    }

    public func all() -> [Int64: Int64] { lock.lock(); defer { lock.unlock() }; return map }

    public func hide(_ postId: Int64, at: Int64 = nowMs()) {
        lock.lock()
        map[postId] = at
        if map.count > 200 {
            for (k, _) in map.sorted(by: { $0.value < $1.value }).prefix(map.count - 200) { map.removeValue(forKey: k) }
        }
        let snapshot = Dictionary(uniqueKeysWithValues: map.map { (String($0.key), $0.value) })
        lock.unlock()
        box.save(snapshot)
    }

    public func clear() { lock.lock(); map = [:]; lock.unlock(); box.save(nil) }
}

// MARK: - Player settings

/// faDub is per-playback only: it is never stored as the global choice.
public enum SubtitleChoice: String, Codable, CaseIterable, Sendable {
    case fa, en, dual, faDub, off
}

public enum SubtitleColor: String, Codable, CaseIterable, Sendable {
    case white, yellow, cyan, green
    public var rgb: (Double, Double, Double) {
        switch self {
        case .white: return (1, 1, 1)
        case .yellow: return (1, 1, 0)
        case .cyan: return (0x7F / 255.0, 0xE0 / 255.0, 1)
        case .green: return (0xA6 / 255.0, 0xF2 / 255.0, 0x8C / 255.0)
        }
    }
    public var label: String {
        switch self {
        case .white: return "سفید"
        case .yellow: return "زرد"
        case .cyan: return "آبی"
        case .green: return "سبز"
        }
    }
}

public struct SubtitleStyle: Codable, Equatable, Sendable {
    public var sizePercent: Int = 100
    public var color: SubtitleColor = .yellow
    public var backgroundOpacity: Int = 75
    public init(sizePercent: Int = 100, color: SubtitleColor = .yellow, backgroundOpacity: Int = 75) {
        self.sizePercent = sizePercent; self.color = color; self.backgroundOpacity = backgroundOpacity
    }
    public static let sizes = Array(stride(from: 60, through: 200, by: 10))
    public static let opacities = [0, 25, 50, 75, 100]
}

public struct PlayerSettings: Codable, Equatable, Sendable {
    public var subtitle: SubtitleChoice = .fa
    public var style = SubtitleStyle()
    public var audioBoost = true
    public init() {}
}

public final class PlayerPrefs: @unchecked Sendable {
    private let box: DefaultsJSON<PlayerSettings>
    public init(defaults: UserDefaults = .standard) { box = DefaultsJSON(defaults, "player.v1") }

    public var settings: PlayerSettings {
        var s = box.load() ?? PlayerSettings()
        if s.subtitle == .faDub { s.subtitle = .fa }
        if !SubtitleStyle.sizes.contains(s.style.sizePercent) { s.style.sizePercent = 100 }
        if !SubtitleStyle.opacities.contains(s.style.backgroundOpacity) { s.style.backgroundOpacity = 75 }
        return s
    }

    public func update(_ f: (inout PlayerSettings) -> Void) {
        let current = settings
        var next = current
        f(&next)
        // faDub is per-playback only: keep the previously stored choice.
        if next.subtitle == .faDub { next.subtitle = current.subtitle }
        box.save(next)
    }
}

/// Per-title viewing choices (dub) plus the global default.
public final class TitlePrefs: @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func dubSelected(_ postId: Int64) -> Bool? { defaults.object(forKey: "dub.\(postId)") as? Bool }
    public func setDubSelected(_ postId: Int64, _ on: Bool) { defaults.set(on, forKey: "dub.\(postId)") }
    public var defaultDub: Bool {
        get { defaults.bool(forKey: "dub.default") }
        set { defaults.set(newValue, forKey: "dub.default") }
    }
    /// The title's saved choice, else the global default; only when the title has a dub at all.
    public func dubFor(_ postId: Int64, hasDub: Bool) -> Bool { hasDub && (dubSelected(postId) ?? defaultDub) }

    public func clear() {
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix("dub.") { defaults.removeObject(forKey: k) }
    }
}

/// «جستجوهای اخیر»: queries the user opened a result from, newest first.
public final class RecentSearches: @unchecked Sendable {
    public static let max = 8
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var queries: [String] { defaults.stringArray(forKey: "recentSearches") ?? [] }

    public func add(_ query: String) { defaults.set(Self.with(queries, query), forKey: "recentSearches") }
    public func clear() { defaults.removeObject(forKey: "recentSearches") }

    /// `list` with `query` (trimmed, whitespace collapsed) moved or added to the front; repeats match ignoring
    /// case and Persian spelling variants.
    public static func with(_ list: [String], _ query: String) -> [String] {
        let q = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !q.isEmpty else { return list }
        let key = PersianText.normalize(q).lowercased()
        return Array(([q] + list.filter { PersianText.normalize($0).lowercased() != key }).prefix(max))
    }
}

/// The last home page, on disk (Caches) for an instant cold start. Public card data only.
public final class HomePageCache: @unchecked Sendable {
    public static let maxAge: TimeInterval = 7 * 86_400
    private struct Stored: Codable { let v: Int; let savedAt: Date; let page: HomePage }
    private let file: URL
    private let lock = NSLock()
    private var memory: (HomePage, Date)?

    public init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]) {
        file = directory.appendingPathComponent("home_page.json")
    }

    /// The page from this process if younger than `ttl`.
    public func fresh(ttl: TimeInterval = 600) -> HomePage? {
        lock.lock(); defer { lock.unlock() }
        guard let m = memory, Date().timeIntervalSince(m.1) < ttl else { return nil }
        return m.0
    }

    public func stored() -> HomePage? {
        guard let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Stored.self, from: data),
              s.v == 1, Date().timeIntervalSince(s.savedAt) < Self.maxAge, s.savedAt <= Date() else { return nil }
        return s.page
    }

    public func put(_ page: HomePage) {
        lock.lock(); memory = (page, Date()); lock.unlock()
        if let data = try? JSONEncoder().encode(Stored(v: 1, savedAt: Date(), page: page)) {
            try? data.write(to: file, options: .atomic)
        }
    }

    public func clear() {
        lock.lock(); memory = nil; lock.unlock()
        try? FileManager.default.removeItem(at: file)
    }
}

// MARK: - Strings computed in code

public enum UiStrings {
    public static let watchAgain = "تماشای دوباره"
    public static let film = "پخش"
    public static let dub = "دوبله"
    public static let subtitle = "زیرنویس"
    public static let playFailed = "پخش شروع نشد"
    public static let playFailedNetwork = "اتصال به سایت برقرار نشد؛ دوباره تلاش کنید"
    public static let playbackFailed = "پخش با مشکل روبه‌رو شد"

    public static func episodeLabel(_ season: Int, _ episode: Int) -> String { "فصل \(season) · قسمت \(episode)".persianDigits }
    public static func continueWatching(_ s: Int, _ e: Int) -> String { "ادامه فصل \(s) قسمت \(e)".persianDigits }
    public static func playEpisode(_ s: Int, _ e: Int) -> String {
        (s == 1 ? "پخش قسمت \(e)" : "پخش فصل \(s) قسمت \(e)").persianDigits
    }
    public static func upNextLabel(_ s: Int, _ e: Int) -> String { "قسمت بعدی · فصل \(s) قسمت \(e)".persianDigits }
    public static func remaining(_ min: Int) -> String { "\(min) دقیقه باقی‌مانده".persianDigits }
    public static func continueFilm(_ min: Int) -> String { "ادامه (\(remaining(min)))" }
    public static func minutes(_ n: Int) -> String { "\(n) دقیقه".persianDigits }
    public static func autoPlayIn(_ s: Int) -> String { "پخش خودکار تا \(s) ثانیه دیگر".persianDigits }
    public static func percent(_ n: Int) -> String { "\(n)٪".persianDigits }

    private static let plural = Rx(#"(\S) (ها|های|هایی)(?=\s|$)"#)
    /// «سریال های» → «سریال‌های»: Persian typography joins the plural suffix.
    public static func joinPlurals(_ text: String) -> String { plural.replace(in: text, with: "$1\u{200C}$2") }

    /// Subtitle sync: 500 → «+۰٫۵ ثانیه», −1500 → «−۱٫۵ ثانیه».
    public static func syncOffset(_ ms: Int64) -> String {
        let sign = ms > 0 ? "+" : ms < 0 ? "−" : ""
        let v = Double(abs(ms)) / 1000
        let num = v == v.rounded() ? String(Int(v)) : String(v)
        return "\u{2066}\(sign)\(num.replacingOccurrences(of: ".", with: "٫").persianDigits)\u{2069} ثانیه"
    }

    /// Audio rendition names from the stream, by label text; unknown labels verbatim.
    public static func audioLabel(_ label: String) -> String {
        if label.contains("dubbed") { return "دوبله فارسی" }
        if label.contains("6CH") { return "زبان اصلی ۵.۱" }
        if label.contains("original") { return "زبان اصلی" }
        return label
    }

    /// "shaun-the-sheep" → "Shaun The Sheep".
    public static func prettifySlug(_ slug: String) -> String {
        slug.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    public static func imdb(_ score: Double) -> String { String(format: "IMDb %.1f", score) }
}
