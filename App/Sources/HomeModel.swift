import SwiftUI
import DroozKit

struct CardUI: Identifiable, Equatable {
    let ref: TitleRef
    let title: String
    let imageURL: URL?
    let subtitle: String?
    let landscape: Bool
    var progress: Double? = nil
    var id: TitleRef { ref }
}

struct RowUI: Identifiable, Equatable {
    let key: String
    let title: String
    var items: [CardUI] = []
    var loading = false
    var error = false
    /// Items have arrived at least once (possibly none).
    var loaded = false
    var id: String { key }
    /// A section the site left empty: nothing to show, so the row is hidden rather than spinning.
    var isEmptyResult: Bool { loaded && items.isEmpty && !loading && !error && key != "recent" }
}

struct HeroUI: Equatable {
    let ref: TitleRef
    let title: String
    let meta: [String]
    let chips: [String]
    let synopsis: String?
    let backdrop: Backdrop
    var imdb: Double?
}

/// Builds the focus-following hero: instant from card data, then the title page (after a short dwell) for a
/// wide backdrop and missing info.
@MainActor
final class HeroController {
    private let app: AppModel
    private let featured: () -> [TitleRef: String]
    private let publish: (HeroUI?) -> Void
    private var dwell: Task<Void, Never>?
    private(set) var current: TitleRef?

    init(app: AppModel, featured: @escaping () -> [TitleRef: String], publish: @escaping (HeroUI?) -> Void) {
        self.app = app
        self.featured = featured
        self.publish = publish
    }

    func focus(_ ref: TitleRef, card: TitleCard?, posterHash: String?) {
        guard ref != current else { return }
        current = ref
        dwell?.cancel()
        dwell = Task {
            let played = await app.titleInfo.playedBackdrops
            let cached = await app.titleInfo.peek(ref)
            guard current == ref, !Task.isCancelled else { return }
            publish(Self.hero(ref, card ?? cached?.card, detail: cached, posterHash: posterHash, featured: featured(), played: played))
            if cached != nil && (featured()[ref] != nil || played[ref] != nil || cached?.trailerThumbHash != nil) { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, current == ref else { return }
            guard let d = try? await app.titleInfo.get(ref, priority: true), current == ref, !Task.isCancelled else { return }
            publish(Self.hero(ref, card ?? d.card, detail: d, posterHash: posterHash, featured: featured(), played: played))
        }
    }

    func clear() { current = nil; dwell?.cancel(); publish(nil) }

    static func hero(_ ref: TitleRef, _ card: TitleCard?, detail: TitleDetail?, posterHash: String?,
                     featured: [TitleRef: String], played: [TitleRef: String]) -> HeroUI {
        let c = card ?? detail?.card
        var meta: [String] = []
        if let y = c?.year { meta.append(String(y).persianDigits) }
        if ref.kind == .series {
            if let e = c?.episodeLabel { meta.append(e) }
        } else if let m = c?.durationMin { meta.append(UiStrings.minutes(m)) }
        if let g = c?.genres, !g.isEmpty { meta.append(g.prefix(3).joined(separator: "، ")) }
        var chips: [String] = []
        if let d = detail {
            if !d.catalog.dub.isEmpty { chips.append(UiStrings.dub) }
            if d.catalog.main.flatMap(\.episodes).contains(where: { !$0.subtitles.isEmpty }) { chips.append(UiStrings.subtitle) }
            if d.catalog.main.flatMap(\.episodes).contains(where: { $0.videos.contains { $0.height >= 2000 } }) { chips.append("4K") }
        }
        let backdrop = BackdropResolver.resolve(ref: ref, featured: featured, played: played, detail: detail,
                                                posterHash: posterHash ?? c?.posterHash)
        return HeroUI(ref: ref, title: c?.title ?? UiStrings.prettifySlug(ref.slug), meta: meta, chips: chips,
                      synopsis: c?.synopsis, backdrop: backdrop, imdb: c?.imdb?.score)
    }
}

@MainActor
@Observable
final class HomeModel {
    private let app: AppModel
    var rows: [RowUI]
    var hero: HeroUI?

    @ObservationIgnored private var cards: [String: [TitleRef: TitleCard]] = [:]
    @ObservationIgnored private var posters: [TitleRef: String] = [:]
    @ObservationIgnored private(set) var featured: [TitleRef: String] = [:]
    @ObservationIgnored private var recentServer: [PosterRef]?
    @ObservationIgnored private var resolved: [TitleRef: TitleDetail] = [:]
    @ObservationIgnored private var continueItems: [TitleRef: ContinueItem] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var seenPlays = -1
    @ObservationIgnored private var startedLists = Set<String>()
    @ObservationIgnored private lazy var heroes = HeroController(app: app, featured: { [weak self] in self?.featured ?? [:] }) {
        [weak self] h in self?.hero = h
    }

    init(app: AppModel) {
        self.app = app
        rows = HomeRows.rows.map { cfg in
            var r = RowUI(key: cfg.key, title: UiStrings.joinPlurals(cfg.title))
            if case .listPath = cfg.source {} else { r.loading = true }
            return r
        }
        load(useCache: true)
        // The baseline for "a play happened since": without it the first play after launch never reloads Home.
        Task { [weak self] in
            guard let self else { return }
            let plays = await app.titleInfo.invalidations
            if seenPlays < 0 { seenPlays = plays }
        }
    }

    /// Home is showing again: after a play or 15 minutes, revalidate in place.
    func onAppear() {
        Task {
            let plays = await app.titleInfo.invalidations
            let old = loadedAt.map { Date().timeIntervalSince($0) > 15 * 60 } ?? false
            rebuildRecent()
            if seenPlays >= 0 && (plays != seenPlays || old) {
                seenPlays = plays
                load(useCache: false, quiet: true)
            }
            seenPlays = plays
        }
    }

    func refresh() { load(useCache: false) }

    private func load(useCache: Bool, quiet: Bool = false) {
        loadTask?.cancel()
        var showing = quiet
        if useCache, let cached = app.homeCache.fresh() ?? app.homeCache.stored() {
            apply(cached)
            showing = true
        }
        if !showing {
            for i in rows.indices where isHomeRow(rows[i].key) { rows[i].loading = true; rows[i].error = false }
        }
        loadTask = Task {
            do {
                let page = try await app.site.home()
                guard !Task.isCancelled else { return }
                app.homeCache.put(page)
                loadedAt = Date()
                apply(page)
            } catch {
                guard !Task.isCancelled, !showing else { return }
                for i in rows.indices where isHomeRow(rows[i].key) { rows[i].loading = false; rows[i].error = true }
                if recentServer == nil { recentServer = []; rebuildRecent() }
            }
        }
    }

    private func isHomeRow(_ key: String) -> Bool {
        guard let cfg = HomeRows.rows.first(where: { $0.key == key }) else { return false }
        if case .listPath = cfg.source { return false }
        return true
    }

    private func apply(_ page: HomePage) {
        featured = Dictionary(page.featured.map { ($0.ref, $0.backdropHash) }, uniquingKeysWith: { a, _ in a })
        for cfg in HomeRows.rows {
            switch cfg.source {
            case .recent:
                recentServer = page.recentlyStreamed
                rebuildRecent()
                resolveRecent(refetch: true)
            case .homeSection(let title):
                let items = page.sections.first { $0.title == title }?.items ?? []
                setPosterRow(cfg.key, items)
            case .listPath:
                break
            }
        }
    }

    func loadRowIfNeeded(_ key: String) {
        guard let cfg = HomeRows.rows.first(where: { $0.key == key }), case .listPath(let path) = cfg.source,
              startedLists.insert(key).inserted else { return }
        loadList(key, path)
    }

    func retry(_ key: String) {
        guard let cfg = HomeRows.rows.first(where: { $0.key == key }) else { return }
        if case .listPath(let path) = cfg.source { loadList(key, path) } else { refresh() }
    }

    private func loadList(_ key: String, _ path: String) {
        update(key) { $0.loading = true; $0.error = false }
        Task {
            do {
                let page = try await app.site.list(path)
                setPosterRow(key, page.items)
            } catch {
                update(key) { $0.loading = false; $0.error = true }
            }
        }
    }

    private func setPosterRow(_ key: String, _ items: [TitleCard]) {
        var seen = Set<TitleRef>()
        let unique = items.filter { seen.insert($0.ref).inserted }
        cards[key] = Dictionary(unique.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        let ui = unique.map { c in
            CardUI(ref: c.ref, title: c.title, imageURL: c.posterHash.flatMap { ImageUrls.poster($0, 360, 540) },
                   subtitle: c.episodeLabel ?? c.year.map { String($0).persianDigits }, landscape: false)
        }
        update(key) { $0.items = ui; $0.loading = false; $0.error = false; $0.loaded = true }
    }

    // MARK: «ادامه تماشا»

    private var recentKey: String { "recent" }

    private func rebuildRecent() {
        guard let server = recentServer else { return }
        let local = app.watch.all()
        let byStream = Dictionary(local.map { ($0.streamId, $0) }, uniquingKeysWith: { a, _ in a })
        Task {
            var ui: [CardUI] = []
            var items: [TitleRef: ContinueItem] = [:]
            let played = await app.titleInfo.playedBackdrops
            for (ref, hash) in ContinueWatching.order(server: server, local: local, hidden: app.hidden.all()) {
                let item: ContinueItem
                if let d = resolved[ref] {
                    let dub = app.titlePrefs.dubFor(ref.postId, hasDub: !d.catalog.dub.isEmpty)
                    guard let r = ContinueWatching.resolve(ref: ref, posterHash: hash ?? d.card.posterHash, detail: d,
                                                           entries: byStream, dub: dub) else { continue }
                    item = r
                } else {
                    item = ContinueWatching.pending(ref, hash)
                }
                items[ref] = item
                if let hash { posters[ref] = hash }
                let detail = resolved[ref]
                let wide = BackdropResolver.resolve(ref: ref, featured: featured, played: played, detail: detail, w: 480, h: 270)
                var url: URL?
                if case .wide(let u) = wide { url = u }
                url = url ?? (item.posterHash ?? posters[ref]).flatMap { ImageUrls.poster($0, 480, 270) }
                ui.append(CardUI(ref: ref, title: detail?.card.title ?? UiStrings.prettifySlug(ref.slug), imageURL: url,
                                 subtitle: item.subtitle, landscape: true, progress: item.progress))
            }
            continueItems = items
            update(recentKey) { $0.items = ui; $0.loading = false; $0.error = false; $0.loaded = true }
        }
    }

    private func resolveRecent(refetch: Bool) {
        guard let server = recentServer else { return }
        for (ref, _) in ContinueWatching.order(server: server, local: app.watch.all(), hidden: app.hidden.all()) {
            if !refetch && resolved[ref] != nil { continue }
            Task {
                guard let d = try? await app.titleInfo.get(ref, maxAge: TitleInfoRepository.pageMaxAge) else { return }
                resolved[ref] = d
                rebuildRecent()
            }
        }
    }

    /// OK on a card: a resolved «ادامه تماشا» card plays at once; anything else opens the title.
    func activate(_ row: String, _ ref: TitleRef) -> TitleRoute? {
        if row == recentKey, let item = continueItems[ref], let stream = item.playStreamId, let d = resolved[ref] {
            app.play(ref, streamId: stream, dub: app.titlePrefs.dubFor(ref.postId, hasDub: !d.catalog.dub.isEmpty))
            return nil
        }
        return TitleRoute(ref: ref, featuredBackdrop: featured[ref])
    }

    func removeFromContinue(_ ref: TitleRef) {
        app.hidden.hide(ref.postId)
        rebuildRecent()
    }

    func onFocus(_ row: String, _ ref: TitleRef) {
        let card = cards[row]?[ref]
        heroes.focus(ref, card: card, posterHash: card?.posterHash ?? posters[ref])
    }

    private func update(_ key: String, _ f: (inout RowUI) -> Void) {
        guard let i = rows.firstIndex(where: { $0.key == key }) else { return }
        var r = rows[i]
        f(&r)
        if r != rows[i] { rows[i] = r }
    }
}
