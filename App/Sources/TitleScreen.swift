import SwiftUI
import DroozKit

struct EpisodeUI: Identifiable, Equatable {
    let episode: Episode
    let label: String
    let watched: Bool
    let progress: Double?
    var id: String { episode.streamId }
}

@MainActor
@Observable
final class TitleModel {
    let ref: TitleRef
    private let app: AppModel
    var detail: TitleDetail?
    var error: String?
    var dub = false
    var inWatchlist: Bool?
    var watchlistError = false
    var selectedSeason: Int?
    var played: [TitleRef: String] = [:]
    @ObservationIgnored private var dubRestored = false
    @ObservationIgnored private var watchlistInFlight = false
    var local: [String: WatchEntry] = [:]

    init(ref: TitleRef, app: AppModel) {
        self.ref = ref
        self.app = app
        load()
    }

    func load() {
        error = nil
        readLocal()
        Task {
            if detail == nil, let known = await app.titleInfo.lastKnown(ref) { show(known) }
            do {
                show(try await app.titleInfo.get(ref, maxAge: TitleInfoRepository.pageMaxAge, priority: true))
            } catch {
                if detail == nil && !error.isCancellation { self.error = error.userMessage }
            }
            played = await app.titleInfo.playedBackdrops
        }
    }

    /// Back from the player: the page changed (played ✓, next episode) and local progress moved.
    func refreshAfterPlay() { load() }

    private func readLocal() {
        local = Dictionary(app.watch.all().filter { TitleRef.fromPath($0.refPath)?.postId == ref.postId }
            .map { ($0.streamId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func show(_ d: TitleDetail) {
        if !dubRestored {
            dubRestored = true
            dub = app.titlePrefs.dubFor(ref.postId, hasDub: !d.catalog.dub.isEmpty)
        }
        if dub && d.catalog.dub.isEmpty { dub = false }
        if !watchlistInFlight { inWatchlist = d.inWatchlist }
        detail = d
    }

    var seasons: [Season] {
        guard let d = detail else { return [] }
        return (dub ? d.catalog.dub : d.catalog.main).sorted { $0.number < $1.number }
    }

    var next: NextUp? { nextUp(seasons, local) }

    var primaryLabel: String {
        let film = ref.kind == .film
        switch next {
        case nil: return ""
        case .start(let e)?: return film ? UiStrings.film : UiStrings.playEpisode(e.season, e.number)
        case .resume(let e, let st)?: return film ? UiStrings.continueFilm(st.remainingMin ?? 0) : UiStrings.continueWatching(e.season, e.number)
        case .next(let e)?: return UiStrings.continueWatching(e.season, e.number)
        case .again?: return UiStrings.watchAgain
        }
    }

    var shownSeason: Int {
        let numbers = seasons.map(\.number)
        if let s = selectedSeason, numbers.contains(s) { return s }
        if case .again? = next, let last = lastWatched { return last.season }
        return next?.episode.season ?? numbers.first ?? 1
    }

    private var lastWatched: Episode? {
        let all = PlaybackRules.ordered(seasons)
        return all.filter { local[$0.streamId] != nil }.max { local[$0.streamId]!.updatedAt < local[$1.streamId]!.updatedAt }
            ?? all.last { episodeState($0, local[$0.streamId]).watched }
    }

    var episodes: [EpisodeUI] {
        (seasons.first { $0.number == shownSeason }?.episodes ?? []).sorted { $0.number < $1.number }.map { e in
            let st = episodeState(e, local[e.streamId])
            return EpisodeUI(episode: e, label: "قسمت \(e.number)".persianDigits, watched: st.watched, progress: st.progress)
        }
    }

    var focusEpisode: String? {
        let eps = episodes
        if let p = next?.episode, eps.contains(where: { $0.id == p.streamId }) { return p.streamId }
        return eps.first { !$0.watched }?.id
    }

    func toggleDub() {
        guard let d = detail, !d.catalog.dub.isEmpty else { return }
        dub.toggle()
        app.titlePrefs.setDubSelected(ref.postId, dub)
    }

    func toggleWatchlist() {
        guard !watchlistInFlight else { return }
        watchlistInFlight = true
        let previous = inWatchlist
        inWatchlist = previous.map { !$0 }
        watchlistError = false
        Task {
            do {
                try await app.site.setWatchlist(postId: ref.postId, state: "watch")
                let now = inWatchlist
                await app.titleInfo.patch(ref) { $0.inWatchlist = now }
                await app.titleInfo.watchlistChanged()
                app.watchlistChanged += 1
            } catch {
                inWatchlist = previous
                watchlistError = true
            }
            watchlistInFlight = false
        }
    }

    func play(_ episode: Episode? = nil) {
        guard let ep = episode ?? next?.episode else { return }
        app.play(ref, streamId: ep.streamId, dub: dub)
    }
}

struct TitleScreen: View {
    let route: TitleRoute
    @Environment(AppModel.self) private var app
    @State private var model: TitleModel?

    var body: some View {
        Group {
            if let model { TitleContent(model: model, featuredBackdrop: route.featuredBackdrop) } else { Palette.background }
        }
        .onAppear { if model == nil { model = TitleModel(ref: route.ref, app: app) } }
        .onChange(of: app.playbackEnded) { _, _ in model?.refreshAfterPlay() }
    }
}

private struct TitleContent: View {
    @Bindable var model: TitleModel
    let featuredBackdrop: String?
    @Environment(\.openTitle) private var openTitle
    @FocusState private var focusedEpisode: String?
    @FocusState private var playFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            BackdropView(backdrop: backdrop)
                .frame(width: 1920, height: 1080)
                .ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.92), .black.opacity(0.5), .clear], startPoint: .trailing, endPoint: .leading)
                .environment(\.layoutDirection, .leftToRight)
                .ignoresSafeArea()
            LinearGradient(colors: [.clear, Palette.background], startPoint: .center, endPoint: .bottom).ignoresSafeArea()

            if let d = model.detail {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 34) {
                        header(d)
                        buttons(d)
                        if d.card.ref.kind == .series || model.seasons.count > 1 { seasonsAndEpisodes }
                        if !d.suggestions.isEmpty { suggestions(d) }
                    }
                    .padding(.horizontal, 90).padding(.top, 60).padding(.bottom, 80)
                }
                .scrollClipDisabled()
            } else if let e = model.error {
                StateMessage(text: e) { model.load() }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spinner().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.background)
        .onAppear { playFocused = true }
    }

    private var backdrop: Backdrop {
        BackdropResolver.resolve(ref: model.ref, featured: featuredBackdrop.map { [model.ref: $0] } ?? [:],
                                 played: model.played, detail: model.detail)
    }

    private func header(_ d: TitleDetail) -> some View {
        let c = d.card
        return VStack(alignment: .leading, spacing: 16) {
            TitleText(text: c.title, size: 70, lines: 2)
            HStack(spacing: 18) {
                if let s = c.imdb?.score { ImdbBadge(score: s) }
                if let y = c.year { meta(String(y).persianDigits) }
                if let ch = d.channel { meta(ch) }
                if model.ref.kind == .series {
                    let n = model.seasons.count
                    if n > 0 { meta("\(n) فصل".persianDigits) }
                } else if let m = c.durationMin { meta(UiStrings.minutes(m)) }
                if !c.genres.isEmpty { meta(c.genres.joined(separator: "، ")) }
                if !d.catalog.dub.isEmpty { MetaChip(text: UiStrings.dub) }
                if d.catalog.main.flatMap(\.episodes).contains(where: { $0.subtitles.contains { $0.lang == "fa" } }) {
                    MetaChip(text: "زیرنویس فارسی")
                }
            }
            if let s = c.status ?? c.episodeLabel { meta(s) }
            if let a = d.awards.first { Text("🏆 " + a).font(.vazir(22)).foregroundStyle(Palette.meta).lineLimit(1) }
            if let syn = c.synopsis {
                Text(syn).font(.vazir(26)).lineSpacing(6).lineLimit(4).frame(width: 1100, alignment: .leading)
            }
            if let dir = c.director {
                meta((model.ref.kind == .series ? "خالق: " : "کارگردان: ") + dir)
            }
            if !c.stars.isEmpty { meta("بازیگران: " + c.stars.prefix(4).joined(separator: "، ")) }
        }
    }

    private func meta(_ t: String) -> some View {
        Text(t).font(.vazir(24, .medium)).foregroundStyle(Palette.meta).lineLimit(1)
    }

    private func buttons(_ d: TitleDetail) -> some View {
        HStack(spacing: 30) {
            if model.next != nil {
                Button { model.play() } label: {
                    Label(model.primaryLabel, systemImage: "play.fill").font(.vazir(28, .bold)).padding(.horizontal, 16)
                }
                .focused($playFocused)
            }
            Button { model.toggleWatchlist() } label: {
                Label("لیست من", systemImage: model.inWatchlist == true ? "checkmark" : "plus").font(.vazir(26, .medium))
            }
            if !d.catalog.dub.isEmpty {
                Button { if model.dub { model.toggleDub() } } label: {
                    Label("زبان اصلی", systemImage: model.dub ? "circle" : "largecircle.fill.circle").font(.vazir(26, .medium))
                }
                Button { if !model.dub { model.toggleDub() } } label: {
                    Label("دوبله", systemImage: model.dub ? "largecircle.fill.circle" : "circle").font(.vazir(26, .medium))
                }
            }
            if model.watchlistError {
                Text("لیست من به‌روز نشد").font(.vazir(22)).foregroundStyle(Palette.accent)
            }
        }
    }

    private var seasonsAndEpisodes: some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.seasons.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 20) {
                        ForEach(model.seasons, id: \.number) { s in
                            Button { model.selectedSeason = s.number } label: {
                                Text("فصل \(s.number)".persianDigits).font(.vazir(24, s.number == model.shownSeason ? .extraBold : .medium))
                                    .foregroundStyle(s.number == model.shownSeason ? Palette.accent : .white)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 10)
                }
                .scrollClipDisabled()
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 28) {
                        ForEach(model.episodes) { e in
                            EpisodeTile(ep: e, minutes: model.detail?.card.durationMin) { model.play(e.episode) }
                                .focused($focusedEpisode, equals: e.id)
                                .id(e.id)
                        }
                    }
                    .padding(.vertical, 20)
                }
                .scrollClipDisabled()
                .onAppear { if let f = model.focusEpisode { proxy.scrollTo(f, anchor: .center) } }
            }
            .defaultFocus($focusedEpisode, model.focusEpisode)
        }
    }

    private func suggestions(_ d: TitleDetail) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("آثار پیشنهادی").font(.vazir(32, .bold))
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(d.suggestions, id: \.self) { ref in
                        let card = CardUI(ref: ref, title: UiStrings.prettifySlug(ref.slug),
                                          imageURL: d.suggestionPosters[ref].flatMap { ImageUrls.poster($0, 360, 540) },
                                          subtitle: nil, landscape: false)
                        PosterCard(card: card, width: 200) { openTitle(ref) }
                    }
                }
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
        }
    }
}

private struct EpisodeTile: View {
    let ep: EpisodeUI
    let minutes: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Palette.surface
                VStack(spacing: 6) {
                    Text(String(ep.episode.number).persianDigits).font(.vazir(54, .extraBold))
                    if let m = minutes { Text(UiStrings.minutes(m)).font(.vazir(18)).foregroundStyle(Palette.secondary) }
                }
                if ep.watched {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).foregroundStyle(Palette.watched)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(12)
                }
                if let p = ep.progress {
                    GeometryReader { g in
                        Rectangle().fill(Palette.accent).frame(width: g.size.width * p, height: 6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                }
            }
            .frame(width: 220, height: 150)
        }
        .buttonStyle(.card)
    }
}
