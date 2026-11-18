import Foundation

public enum SiteConfig {
    public static let host = "robin.robert-redford.net"
    public static let baseURL = "https://\(host)"
    public static let userAgent =
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36"
    public static let loginPath = "/user/login/"
    public static let logoutPath = "/user/logout/"
    /// Cookie the site normally sets from JavaScript; without it every page is a JS redirect stub.
    public static let scrCookie = "scr"
    public static let scrValue = "1"
    /// Session (login) cookie.
    public static let sessionCookie = "cf"
    /// Device id cookie: kept forever (the site counts devices by it).
    public static let deviceCookie = "sf"
}

public enum SiteError: Error, Equatable, LocalizedError {
    case http(code: Int, retryAfterSeconds: Int?)
    case network(String)
    case blocked
    case sessionExpired
    case notLoggedIn
    case parse(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code, _): return "HTTP \(code)"
        case .network(let m): return "network: \(m)"
        case .blocked: return "blocked by Cloudflare challenge"
        case .sessionExpired: return "session expired"
        case .notLoggedIn: return "not logged in"
        case .parse(let what): return "could not parse \(what)"
        }
    }

    /// Failures that are worth telling the user "check the connection".
    public var isNetwork: Bool {
        switch self {
        case .network, .blocked: return true
        case .http(let code, _): return code >= 500
        default: return false
        }
    }
}

public enum TitleKind: String, Codable, Hashable, Sendable {
    case film, series
}

public struct TitleRef: Hashable, Codable, Sendable {
    public let kind: TitleKind
    public let postId: Int64
    public let slug: String

    public init(kind: TitleKind, postId: Int64, slug: String) {
        self.kind = kind
        self.postId = postId
        self.slug = slug
    }

    public var path: String { "/post/\(kind.rawValue)/\(postId)/\(slug)/" }

    private static let pattern = Rx(#"/post/(film|series)/(\d+)/([^/?#]+)/?"#)

    public static func fromPath(_ raw: String) -> TitleRef? {
        let path = raw.hasPrefix(SiteConfig.baseURL) ? String(raw.dropFirst(SiteConfig.baseURL.count)) : raw
        guard let g = pattern.firstGroups(in: path), let id = Int64(g[2]) else { return nil }
        return TitleRef(kind: g[1] == "film" ? .film : .series, postId: id, slug: g[3])
    }
}

/// IMDb score with absolute vote count (۱۸۱ هزار → 181000).
public struct Rating: Hashable, Codable, Sendable {
    public let score: Double
    public let votes: Int
    public init(score: Double, votes: Int) { self.score = score; self.votes = votes }
}

public struct TitleCard: Hashable, Codable, Sendable {
    public var ref: TitleRef
    public var title: String
    public var year: Int?
    public var posterHash: String?
    public var durationMin: Int?
    public var imdb: Rating?
    public var criticsScore: Int?
    public var genres: [String]
    public var countries: [String]
    public var director: String?
    public var stars: [String]
    public var synopsis: String?
    /// Series badge, e.g. «قسمت ۰۷ فصل سوم».
    public var episodeLabel: String?
    /// Series status, e.g. «در حال پخش», «پایان فصل».
    public var status: String?

    public init(ref: TitleRef, title: String, year: Int? = nil, posterHash: String? = nil, durationMin: Int? = nil,
                imdb: Rating? = nil, criticsScore: Int? = nil, genres: [String] = [], countries: [String] = [],
                director: String? = nil, stars: [String] = [], synopsis: String? = nil,
                episodeLabel: String? = nil, status: String? = nil) {
        self.ref = ref; self.title = title; self.year = year; self.posterHash = posterHash
        self.durationMin = durationMin; self.imdb = imdb; self.criticsScore = criticsScore
        self.genres = genres; self.countries = countries; self.director = director; self.stars = stars
        self.synopsis = synopsis; self.episodeLabel = episodeLabel; self.status = status
    }

    public static func minimal(_ ref: TitleRef) -> TitleCard { TitleCard(ref: ref, title: UiStrings.prettifySlug(ref.slug)) }
}

public struct FeaturedItem: Hashable, Codable, Sendable {
    public let ref: TitleRef
    public let backdropHash: String
}

/// Home "recently streamed" items carry only a link and a poster.
public struct PosterRef: Hashable, Codable, Sendable {
    public let ref: TitleRef
    public let posterHash: String
}

public struct HomeSection: Hashable, Codable, Sendable {
    public let title: String
    public let morePath: String?
    public let items: [TitleCard]
}

public struct HomePage: Hashable, Codable, Sendable {
    public let featured: [FeaturedItem]
    public let recentlyStreamed: [PosterRef]
    public let sections: [HomeSection]
}

public struct ListPage: Hashable, Sendable {
    public let items: [TitleCard]
    public let page: Int
    public let lastPage: Int
}

public enum CategoryKind: String, Hashable, Sendable { case film, series, both }

public struct SiteCategory: Hashable, Sendable {
    public let label: String
    public let path: String
    public let kind: CategoryKind
}

public struct CategorizedListPage: Sendable {
    public let page: ListPage
    public let categories: [SiteCategory]
}

public struct VideoVariant: Hashable, Codable, Sendable {
    public let id: String
    public let width: Int
    public let height: Int
    public let size: String
}

/// `lang` is "original" or "dubbed-fa".
public struct AudioTrackInfo: Hashable, Codable, Sendable {
    public let id: String
    public let lang: String
    public let channels: Int
}

/// `lang` is "fa" or "en".
public struct SubtitleRef: Hashable, Codable, Sendable {
    public let id: String
    public let lang: String
}

public struct Episode: Hashable, Codable, Sendable {
    public let season: Int
    public let number: Int
    public let streamId: String
    public let videos: [VideoVariant]
    public let audios: [AudioTrackInfo]
    public let subtitles: [SubtitleRef]
    public let played: Bool

    public init(season: Int, number: Int, streamId: String, videos: [VideoVariant] = [],
                audios: [AudioTrackInfo] = [], subtitles: [SubtitleRef] = [], played: Bool = false) {
        self.season = season; self.number = number; self.streamId = streamId
        self.videos = videos; self.audios = audios; self.subtitles = subtitles; self.played = played
    }
}

public struct Season: Hashable, Codable, Sendable {
    public let number: Int
    public let episodes: [Episode]
    public init(number: Int, episodes: [Episode]) { self.number = number; self.episodes = episodes }
}

/// Films are one Season(1) with one Episode(1); `dub` is empty when there is no Persian dub.
public struct StreamCatalog: Hashable, Codable, Sendable {
    public let main: [Season]
    public let dub: [Season]
    public init(main: [Season], dub: [Season]) { self.main = main; self.dub = dub }
}

public struct TitleDetail: Hashable, Sendable {
    public var card: TitleCard
    public var channel: String?
    public var awards: [String]
    public var catalog: StreamCatalog
    public var suggestions: [TitleRef]
    public var trailerThumbHash: String?
    public var suggestionPosters: [TitleRef: String]
    /// Whether the title is on the user's watchlist, as the page renders it; nil when the page doesn't say.
    public var inWatchlist: Bool?
}

public enum SubtitleKind: String, Hashable, Sendable, CaseIterable {
    case fa, en, dual, faDub, other

    public static func of(_ label: String) -> SubtitleKind {
        switch label.trimmingCharacters(in: .whitespaces) {
        case "Farsi": return .fa
        case "English": return .en
        case "English + Farsi": return .dual
        case "Farsi for Dub": return .faDub
        default: return .other
        }
    }
}

/// Labels as on the site: Farsi, English, English + Farsi, Farsi for Dub.
public struct SubtitleTrack: Hashable, Sendable {
    public let label: String
    public let url: String
    public var kind: SubtitleKind { .of(label) }
}

public struct StreamSession: Sendable {
    public let title: String
    public let masterUrl: String
    public let backdropPath: String?
    public let subtitles: [SubtitleTrack]
    /// Keyed by bitrate in kbps, e.g. 2475 → "1080 [ 2.48 GB ]".
    public let qualityLabels: [Int: String]
    /// (segment seconds, gain) loudness map used by Audio Boost.
    public let gains: [(Double, Double)]
    public let minGain: Double?
    public let maxGain: Double?
    /// Keyframe times per quality level.
    public let iframes: [[Double]]
    public let streamId: String
}

/// The site resizes `/img/W-H/<hash>` to any requested size; always request exactly what is drawn.
public enum ImageUrls {
    public static func poster(_ hash: String, _ w: Int, _ h: Int) -> URL? { URL(string: "\(SiteConfig.baseURL)/img/\(w)-\(h)/\(hash)") }
    public static func backdrop(_ hash: String, _ w: Int, _ h: Int) -> URL? { poster(hash, w, h) }
    public static func trailerThumb(_ hash: String, _ w: Int, _ h: Int) -> URL? {
        URL(string: "\(SiteConfig.baseURL)/img/\(w)-\(h)/trailer/\(hash)")
    }

    private static let hashPattern = Rx(#"/img/\d+-\d+/(?:trailer/)?([^/'"\s?]+)"#)

    /// Extracts the image hash from an `/img/W-H/<hash>` path, or nil.
    public static func hashOf(_ path: String) -> String? { hashPattern.firstGroups(in: path)?[1] }
}
