import Foundation
import SwiftSoup

// MARK: - SwiftSoup conveniences (the parsers are tolerant: a selector that throws finds nothing)

extension Element {
    func all(_ css: String) -> [Element] { (try? select(css).array()) ?? [] }
    func one(_ css: String) -> Element? { try? select(css).first() }
    func a(_ name: String) -> String { (try? attr(name)) ?? "" }
    var txt: String { ((try? text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    var inner: String { (try? html()) ?? "" }
    var nextSibling: Element? { try? nextElementSibling() }
    var kids: [Element] { children().array() }
    var ancestors: [Element] { parents().array() }
}

func parseDoc(_ html: String) -> Document {
    (try? SwiftSoup.parse(html, SiteConfig.baseURL)) ?? Document(SiteConfig.baseURL)
}

private func imgPath(_ img: Element) -> String {
    let ds = img.a("data-src")
    return ds.isEmpty ? img.a("src") : ds
}

// MARK: - Card

/// Parses one title "card" (`.postMeta` on lists/home, the header block on title pages).
/// Metadata lines are recognised by their Font Awesome icon, not by position.
public enum CardParser {
    static let titleYear = Rx(#"^(.*?)\s*\((\d{4})\)\s*$"#)

    public static func parse(_ el: Element) -> TitleCard? {
        guard let link = el.all("a[href*=/post/]").first(where: { TitleRef.fromPath($0.a("href")) != nil }),
              let ref = TitleRef.fromPath(link.a("href")) else { return nil }
        let headingEl = el.one("h1, h2, h3") ?? el.one("b")
        var heading = ""
        if let h = headingEl {
            let own = (h.one("a")?.ownText() ?? h.ownText()).trimmingCharacters(in: .whitespacesAndNewlines)
            heading = own.isEmpty ? h.txt : own
        }
        let m = titleYear.firstGroups(in: heading)
        let title = m?[1].nilIfBlank ?? heading.nilIfBlank ?? UiStrings.prettifySlug(ref.slug)
        let year = m.flatMap { Int($0[2]) }
        let poster = el.all("img").lazy.map(imgPath)
            .compactMap { src -> String? in
                guard src.contains("/img/"), !src.contains("avatar") else { return nil }
                return ImageUrls.hashOf(src)
            }.first

        func line(_ icon: String) -> Element? { el.one("i.\(icon)")?.parent() }
        func value(_ icon: String) -> String? { line(icon)?.txt.afterColon().nilIfBlank }
        func list(_ icon: String) -> [String] {
            guard let l = line(icon) else { return [] }
            let links = l.all("a").map(\.txt).filter { !$0.isEmpty }
            if !links.isEmpty { return links }
            return l.inner.afterColon().components(separatedBy: "<spl></spl>")
                .map { parseDoc($0).body()?.txt ?? "" }
                .filter { !$0.isEmpty }
        }

        return TitleCard(
            ref: ref,
            title: title,
            year: year,
            posterHash: poster,
            durationMin: line("fa-hourglass-half").flatMap { PersianText.minutes($0.txt) },
            imdb: line("fa-star").flatMap { PersianText.rating($0.txt) },
            criticsScore: line("fa-flag").flatMap { PersianText.criticsScore($0.txt) },
            genres: list("fa-typo3"),
            countries: list("fa-globe"),
            director: list("fa-user").first,
            stars: list("fa-users"),
            synopsis: el.one(".text-justify")?.txt.nilIfBlank,
            episodeLabel: value("fa-chevron-circle-left") ?? line("fa-chevron-circle-left")?.txt,
            status: line("fa-circle-notch")?.txt.nilIfBlank
        )
    }
}

private func distinctByRef(_ cards: [TitleCard]) -> [TitleCard] {
    var seen = Set<TitleRef>()
    return cards.filter { seen.insert($0.ref).inserted }
}

// MARK: - Home

public enum HomeParser {
    static let recentlyStreamed = "مشاهدات اخیر"
    static let newFilmsTitle = "فیلم های جدید"
    static let newFilmsPath = "/archive/category/new-films/"

    public static func parse(_ html: String) throws -> HomePage {
        let doc = parseDoc(html)
        let featured: [FeaturedItem] = doc.all(".carousel-item").compactMap { item in
            guard let ref = TitleRef.fromPath(item.a("href")),
                  let img = item.one("img"), let hash = ImageUrls.hashOf(imgPath(img)) else { return nil }
            return FeaturedItem(ref: ref, backdropHash: hash)
        }
        var recent: [PosterRef] = []
        var sections: [HomeSection] = []
        for h2 in doc.all("h2") {
            guard let header = h2.parent(), let content = header.nextSibling else { continue }
            // Normalized, so a ZWNJ or an Arabic yeh in the heading still matches the configured row.
            let title = PersianText.normalize(h2.txt)
            if title.contains(recentlyStreamed) {
                recent = posters(content)
                continue
            }
            let items = distinctByRef(content.kids.compactMap(CardParser.parse))
            if !items.isEmpty {
                let more = header.one("a.btn[href]")?.a("href")
                sections.append(HomeSection(title: title, morePath: more, items: items))
            }
        }
        let newFilms = distinctByRef(doc.all(".postMeta").compactMap(CardParser.parse))
        if !newFilms.isEmpty { sections.append(HomeSection(title: newFilmsTitle, morePath: newFilmsPath, items: newFilms)) }
        // The home always has content: nothing recognised means the markup changed.
        if featured.isEmpty && recent.isEmpty && sections.isEmpty { throw SiteError.parse("home") }
        return HomePage(featured: featured, recentlyStreamed: recent, sections: sections)
    }

    private static func posters(_ content: Element) -> [PosterRef] {
        var seen = Set<TitleRef>()
        return content.all("a[href*=/post/]").compactMap { a -> PosterRef? in
            guard let ref = TitleRef.fromPath(a.a("href")), let img = a.one("img"),
                  let hash = ImageUrls.hashOf(imgPath(img)), seen.insert(ref).inserted else { return nil }
            return PosterRef(ref: ref, posterHash: hash)
        }
    }
}

// MARK: - Lists, search, menu

public enum ListParser {
    public static func parse(_ html: String) -> ListPage { parse(doc: parseDoc(html)) }

    public static func parse(doc: Document) -> ListPage {
        let items = distinctByRef(doc.all(".postMeta").compactMap(CardParser.parse))
        let page = doc.one(".pagination .page-item.active").flatMap {
            Int(PersianText.digits($0.txt).trimmingCharacters(in: .whitespaces))
        } ?? 1
        let last = doc.all(".pagination .page-link")
            .compactMap { Int(PersianText.digits($0.txt).trimmingCharacters(in: .whitespaces)) }
            .max() ?? page
        return ListPage(items: items, page: page, lastPage: max(page, last))
    }
}

/// «لیست من» (`/user/watchlist/`) has compact cards instead of `.postMeta`, films first and then series, all on one page.
/// Each card carries the lists it is on (`watchList`, `favoriteList`, `watchedList`) as classes and the site's script
/// shows one list at a time; «لیست من» is `watchList`. The name and year are only in the poster's `title`.
public enum WatchlistParser {
    public static func parse(_ html: String) -> ListPage { parse(doc: parseDoc(html)) }

    public static func parse(doc: Document) -> ListPage {
        let items = doc.all(".ty-compact-list.watchList").compactMap { card -> TitleCard? in
            guard let ref = card.all("a[href*=/post/]").lazy.compactMap({ TitleRef.fromPath($0.a("href")) }).first else {
                return nil
            }
            let img = card.one("img")
            let label = img?.a("title").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let m = CardParser.titleYear.firstGroups(in: label)
            return TitleCard(ref: ref, title: m?[1].nilIfBlank ?? label.nilIfBlank ?? UiStrings.prettifySlug(ref.slug),
                             year: m.flatMap { Int($0[2]) }, posterHash: img.map(imgPath).flatMap(ImageUrls.hashOf))
        }
        return ListPage(items: distinctByRef(items), page: 1, lastPage: 1)
    }
}

/// Only the «فیلم و سریال» result block; the page's sidebar lists are ignored.
public enum SearchParser {
    public static func parse(_ html: String) -> [TitleCard] {
        let doc = parseDoc(html)
        guard let h2 = doc.all("h2").first(where: { PersianText.normalize($0.txt).contains("فیلم و سریال") }),
              let block = h2.parent()?.parent() else { return [] }
        return distinctByRef(block.all("div.rtl").compactMap(CardParser.parse))
    }
}

/// The site's navigation menu as browsable categories (only ordinary `/archive/...` listings).
public enum CategoryMenuParser {
    private static let listing = Rx(#"^/archive/(?:category/([a-z0-9-]+)|series|(?:film|series)/(?:country|genre)/[a-z0-9-]+)/$"#)
    private static let typeQuery = Rx(#"^type=(film|series)$"#)

    public static func parse(_ html: String) -> [SiteCategory] { parse(doc: parseDoc(html)) }

    public static func parse(doc: Document) -> [SiteCategory] {
        guard let menu = doc.one("#navbar") ?? doc.one("nav") else { return [] }
        var seen = Set<String>()
        return menu.all("a[href]").compactMap { a -> SiteCategory? in
            let label = PersianText.normalize(a.txt)
            guard !label.isEmpty else { return nil }
            var href = a.a("href").trimmingCharacters(in: .whitespaces)
            if href.hasPrefix(SiteConfig.baseURL) { href = String(href.dropFirst(SiteConfig.baseURL.count)) }
            let noFragment = href.components(separatedBy: "#")[0]
            let parts = noFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let rawPath = parts[0]
            let path = rawPath.hasSuffix("/") ? rawPath : rawPath + "/"
            let query = parts.count > 1 ? parts[1] : ""
            guard let m = listing.firstGroups(in: path) else { return nil }
            let slug = m[1]
            if slug == "coming-soon" { return nil }
            var type: String? = nil
            if !query.isEmpty {
                guard let t = typeQuery.firstGroups(in: query) else { return nil }
                type = t[1]
            }
            let full = query.isEmpty ? path : "\(path)?\(query)"
            guard seen.insert(full).inserted else { return nil }
            return SiteCategory(label: label, path: full, kind: kind(path, slug, type, a))
        }
    }

    private static func kind(_ path: String, _ slug: String, _ type: String?, _ link: Element) -> CategoryKind {
        if type == "film" { return .film }
        if type == "series" { return .series }
        if path.hasPrefix("/archive/film/") { return .film }
        if path.hasPrefix("/archive/series/") { return .series }
        if slug.hasSuffix("-films") || slug.hasSuffix("-film") { return .film }
        if slug.contains("series") || slug.contains("tv-show") { return .series }
        let menu = link.ancestors.first(where: { $0.hasClass("dropdown") })?.one(".dropdown-toggle")
            .map { PersianText.normalize($0.txt) } ?? ""
        if menu.contains("فیلم") { return .film }
        if menu.contains("سریال") { return .series }
        return .both
    }
}

// MARK: - Title page

public enum TitleParser {
    /// The object ends at the first `}` followed by `;` and a line end, or by `</script>` (minified pages).
    private static let stream = Rx(#"var STREAM\s*=\s*(\{.*?\})\s*(?:;\s*\n|;?\s*</script>)"#, dotAll: true)
    private static let trailer = Rx(#"/img/590-331/trailer/[^'"\s]+"#)

    public static func parse(_ html: String, ref: TitleRef) throws -> TitleDetail {
        guard let json = stream.firstGroups(in: html)?[1] else { throw SiteError.parse("STREAM") }
        let catalog = try parseCatalog(json)
        let doc = parseDoc(html)
        // The catalog makes the title playable; a header that no longer parses only costs its metadata.
        let meta = doc.one(".postMeta")?.parent()
        var card = meta.flatMap(CardParser.parse) ?? .minimal(ref)
        card.ref = ref

        let channel = meta?.one("i.fa-tv")?.parent()?.txt.afterColon().nilIfBlank
        var seenAwards = Set<String>()
        let awards: [String] = (meta?.all("i.fa-flag") ?? []).flatMap { icon -> [String] in
            // The critics score line carries the same flag icon; its neighbours are not award entries.
            guard let heading = icon.parent(), let box = heading.parent(),
                  PersianText.criticsScore(heading.txt) == nil else { return [] }
            var title = heading.txt
            while title.hasSuffix(":") || title.hasSuffix(" ") { title.removeLast() }
            return box.all("div.col-12.px-0").map { "\(title): \($0.txt)" }
        }
        // Entries are nested `div.col-12.px-0`s (column and cell), so each one matches twice.
        .filter { seenAwards.insert($0).inserted }
        let links: [(TitleRef, String?)] = (doc.all("h2")
            .first(where: { PersianText.normalize($0.txt).contains("آثار پیشنهادی") })?
            .parent()?.parent()?.all("a[href*=/post/]") ?? [])
            .compactMap { a in
                guard let r = TitleRef.fromPath(a.a("href")) else { return nil }
                let img = a.one("img")
                let src = img.map { $0.a("data-src").nilIfBlank ?? $0.a("src") }
                return (r, src.flatMap(ImageUrls.hashOf))
            }
        var seen = Set<TitleRef>()
        let suggestions = links.map(\.0).filter { seen.insert($0).inserted }
        var posters: [TitleRef: String] = [:]
        for (r, h) in links { if let h { posters[r] = h } }
        let trailerHash = trailer.firstGroups(in: html).flatMap { ImageUrls.hashOf($0[0]) }
        let button = doc.one("button.watchlist[value2=watch]")
        let inWatchlist: Bool? = button.flatMap { b in
            if b.hasClass("btn-warning") { return true }
            if b.hasClass("btn-gray") { return false }
            return nil
        }
        return TitleDetail(card: card, channel: channel, awards: awards, catalog: catalog, suggestions: suggestions,
                           trailerThumbHash: trailerHash, suggestionPosters: posters, inWatchlist: inWatchlist)
    }

    /// `STREAM` is `{"main": seasons, "dub"?: seasons, "subtitle": bool}`; films use arrays, series objects keyed by number.
    public static func parseCatalog(_ json: String) throws -> StreamCatalog {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SiteError.parse("STREAM")
        }
        return StreamCatalog(main: root["main"].map(seasons) ?? [], dub: root["dub"].map(seasons) ?? [])
    }

    private static func numbered(_ v: Any) -> [(Int, Any)] {
        if let arr = v as? [Any] { return arr.enumerated().map { ($0.offset + 1, $0.element) } }
        if let obj = v as? [String: Any] {
            return obj.compactMap { k, v in Int(k).map { ($0, v) } }.sorted { $0.0 < $1.0 }
        }
        return []
    }

    private static func seasons(_ v: Any) -> [Season] {
        numbered(v).map { s, eps in
            Season(number: s, episodes: numbered(eps).compactMap { n, e in episode(s, n, e) })
        }
    }

    private static func str(_ o: [String: Any], _ k: String) -> String {
        switch o[k] {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }

    private static func episode(_ season: Int, _ number: Int, _ v: Any) -> Episode? {
        guard let o = v as? [String: Any] else { return nil }
        let id = str(o, "id").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        func list(_ k: String) -> [[String: Any]] { (o[k] as? [Any])?.compactMap { $0 as? [String: Any] } ?? [] }
        let played: Bool = {
            switch o["played"] {
            case let b as Bool: return b
            case let n as NSNumber: return n.intValue == 1
            case let s as String: return s == "1" || s == "true"
            default: return false
            }
        }()
        return Episode(
            season: season, number: number, streamId: id,
            videos: list("videos").map { VideoVariant(id: str($0, "id"), width: Int(str($0, "width")) ?? 0,
                                                      height: Int(str($0, "height")) ?? 0, size: str($0, "size")) },
            audios: list("audios").map { AudioTrackInfo(id: str($0, "id"), lang: str($0, "lang"), channels: Int(str($0, "channels")) ?? 2) },
            subtitles: list("subtitles").map { SubtitleRef(id: str($0, "id"), lang: str($0, "lang")) },
            played: played
        )
    }
}

// MARK: - Stream page

/// Reads the JW Player setup script of a `/stream/{streamId}/{postId}/` page.
public enum StreamPageParser {
    private static let master = Rx(#"file:\s*'(/json/m3u8/[^']+)'"#)
    private static let track = Rx(#"kind:\s*'captions',\s*file:\s*"([^"]+)",\s*label:\s*'([^']+)'"#)
    private static let qualityBlock = Rx(#"qualityLabels:\s*\{([^}]*)\}"#)
    private static let quality = Rx(#"'(\d+)'\s*:\s*'([^']*)'"#)
    private static let gainsRx = Rx(#"Gains\s*=\s*(\[\[.*?\]\]);"#)
    private static let pair = Rx(#"\[([\d.]+),([\d.]+)\]"#)
    private static let minGain = Rx(#"minGain\s*=\s*([\d.]+);"#)
    private static let maxGain = Rx(#"maxGain\s*=\s*([\d.]+);"#)
    private static let iframesRx = Rx(#"IFrames\[(\d+)\]\s*=\s*\[([^\]]*)\];"#)
    private static let title = Rx(#"title:\s*"([^"]*)""#)
    private static let image = Rx(#"image:\s*'([^']+)'"#)

    public static func parse(_ html: String, streamId: String) throws -> StreamSession {
        guard let m = master.firstGroups(in: html)?[1] else { throw SiteError.parse("m3u8") }
        var labels: [Int: String] = [:]
        if let block = qualityBlock.firstGroups(in: html)?[1] {
            for g in quality.allGroups(in: block) { if let k = Int(g[1]) { labels[k] = g[2] } }
        }
        let gains: [(Double, Double)] = gainsRx.firstGroups(in: html).map { b in
            pair.allGroups(in: b[1]).compactMap { g in
                guard let t = Double(g[1]), let v = Double(g[2]) else { return nil }
                return (t, v)
            }
        } ?? []
        let frames = iframesRx.allGroups(in: html)
            .compactMap { g -> (Int, [Double])? in
                guard let i = Int(g[1]) else { return nil }
                return (i, g[2].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) })
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
        return StreamSession(
            title: title.firstGroups(in: html)?[1] ?? "",
            masterUrl: absolute(m),
            backdropPath: image.firstGroups(in: html)?[1],
            subtitles: track.allGroups(in: html).map { SubtitleTrack(label: $0[2], url: absolute($0[1])) },
            qualityLabels: labels,
            gains: gains,
            minGain: minGain.firstGroups(in: html).flatMap { Double($0[1]) },
            maxGain: maxGain.firstGroups(in: html).flatMap { Double($0[1]) },
            iframes: frames,
            streamId: streamId
        )
    }

    private static func absolute(_ p: String) -> String { p.hasPrefix("/") ? SiteConfig.baseURL + p : p }
}

// MARK: - Login page

public enum LoginPage: Equatable, Sendable {
    case form
    case needsMobile(recaptchaPass: String, mobileHint: String)
    case wrongCredentials
    case redirecting
    case unknown(alertText: String?)
}

/// Classifies the HTML returned by `/user/login/`. Only alerts inside the form are login messages.
public enum LoginParser {
    public static func parse(_ html: String) -> LoginPage {
        let doc = parseDoc(html)
        let form = doc.one("form")
        let alert = (form ?? doc).all(form != nil ? ".alert" : ".alert-danger").first?.txt.nilIfBlank
        let key = alert.map(PersianText.normalize)
        if let key, key.contains("در حال انتقال") { return .redirecting }
        if let key, key.contains("نام کاربری یا رمز عبور اشتباه") { return .wrongCredentials }
        guard let form else { return .unknown(alertText: alert) }
        let names = Set(form.all("input[name]").map { $0.a("name") })
        let recaptcha = form.one("input[name=recaptchaPass]")?.a("value") ?? ""
        if let mobile = form.one("input[name=mobile]"), !recaptcha.isEmpty,
           key == nil || key!.contains("شماره موبایل") {
            return .needsMobile(recaptchaPass: recaptcha, mobileHint: mobile.a("placeholder"))
        }
        if alert == nil && names == ["username", "password"] { return .form }
        return .unknown(alertText: alert)
    }
}
