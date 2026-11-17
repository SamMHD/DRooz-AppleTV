import SwiftUI
import DroozKit

struct ListConfig {
    var title: String
    var path: String
    var emptyText: String? = nil
    var watchlist = false
    var categories: CategoryKind? = nil
}

struct CategoryChip: Hashable {
    let label: String
    let path: String
}

@MainActor
@Observable
final class ListModel {
    let config: ListConfig
    private let app: AppModel
    var items: [CardUI] = []
    var loading = true
    var loadingMore = false
    var error: String?
    var pageError = false
    var chips: [CategoryChip] = []
    var selectedChip = 0
    @ObservationIgnored private var path: String
    @ObservationIgnored private var seen = Set<TitleRef>()
    @ObservationIgnored private var loadedPage = 0
    @ObservationIgnored private var lastPage = 1
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var seenWatchlist = 0

    init(config: ListConfig, app: AppModel) {
        self.config = config
        self.app = app
        self.path = config.path
        seenWatchlist = app.watchlistChanged
        loadNext()
    }

    var endReached: Bool { loadedPage >= lastPage }

    func loadNext() {
        guard task == nil, !endReached || loadedPage == 0 else { return }
        let page = loadedPage + 1
        let path = self.path
        if page == 1 { loading = true; error = nil } else { loadingMore = true }
        pageError = false
        task = Task {
            defer { task = nil; loading = false; loadingMore = false }
            do {
                let result: ListPage
                if page == 1 && config.categories != nil && chips.isEmpty {
                    let r = try await app.site.listWithCategories(path)
                    result = r.page
                    chips = Self.chips(r.categories, kind: config.categories!, defaultPath: config.path, title: config.title)
                } else {
                    result = try await app.site.list(path, page: page)
                }
                guard !Task.isCancelled, path == self.path else { return }
                loadedPage = page
                lastPage = max(result.lastPage, page)
                append(result.items)
            } catch {
                guard !Task.isCancelled else { return }
                if page == 1 { self.error = error.userMessage } else { pageError = true }
            }
        }
    }

    private func append(_ cards: [TitleCard]) {
        items += cards.filter { seen.insert($0.ref).inserted }.map { c in
            CardUI(ref: c.ref, title: c.title, imageURL: c.posterHash.flatMap { ImageUrls.poster($0, 360, 540) },
                   subtitle: c.episodeLabel ?? c.year.map { String($0).persianDigits }, landscape: false)
        }
    }

    func onItemAppear(_ index: Int) {
        if index >= items.count - 14 && !pageError { loadNext() }
    }

    func selectChip(_ i: Int) {
        guard i != selectedChip, chips.indices.contains(i) else { return }
        task?.cancel()
        task = nil
        selectedChip = i
        path = chips[i].path
        reset()
        loadNext()
    }

    func onAppear() {
        guard config.watchlist, app.watchlistChanged != seenWatchlist else { return }
        seenWatchlist = app.watchlistChanged
        task?.cancel(); task = nil
        reset()
        loadNext()
    }

    func retry() { if loadedPage == 0 { reset() }; loadNext() }

    private func reset() {
        items = []
        seen = []
        loadedPage = 0
        lastPage = 1
    }

    var titleText: String {
        selectedChip == 0 || !chips.indices.contains(selectedChip) ? config.title : "\(config.title) · \(chips[selectedChip].label)"
    }

    /// The default listing first, then the menu's categories of this kind (or both kinds) in menu order.
    static func chips(_ menu: [SiteCategory], kind: CategoryKind, defaultPath: String, title: String) -> [CategoryChip] {
        let prefix = kind == .film ? "فیلم های " : "سریال های "
        func label(_ c: SiteCategory) -> String {
            var l = PersianText.normalize(c.label)
            if l.hasPrefix(prefix) { l = String(l.dropFirst(prefix.count)) }
            return UiStrings.joinPlurals(l.isEmpty ? c.label : l)
        }
        let first = CategoryChip(label: menu.first { $0.path == defaultPath }.map(label) ?? title, path: defaultPath)
        let rest = menu.filter { ($0.kind == kind || $0.kind == .both) && $0.path != defaultPath }.map { CategoryChip(label: label($0), path: $0.path) }
        return rest.isEmpty ? [] : [first] + rest
    }
}

struct ListScreen: View {
    let config: ListConfig
    @Environment(AppModel.self) private var app
    @State private var model: ListModel?

    var body: some View {
        Group {
            if let model { ListContent(model: model) } else { Palette.background }
        }
        .onAppear { if model == nil { model = ListModel(config: config, app: app) } else { model?.onAppear() } }
    }
}

private struct ListContent: View {
    @Bindable var model: ListModel
    @Environment(\.openTitle) private var openTitle
    private let columns = Array(repeating: GridItem(.fixed(240), spacing: 48, alignment: .top), count: 6)

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 30) {
                Text(model.titleText).font(.vazir(44, .extraBold))
                if !model.chips.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 16) {
                            ForEach(Array(model.chips.enumerated()), id: \.offset) { i, chip in
                                Button { model.selectChip(i) } label: {
                                    Text(chip.label).font(.vazir(24, i == model.selectedChip ? .bold : .medium))
                                }
                                .tint(i == model.selectedChip ? Palette.accent : nil)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .scrollClipDisabled()
                }
                content
            }
            .padding(.horizontal, 90).padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .background(Palette.background)
    }

    @ViewBuilder private var content: some View {
        if let e = model.error {
            StateMessage(text: e) { model.retry() }.frame(maxWidth: .infinity).padding(.top, 120)
        } else if model.loading && model.items.isEmpty {
            Spinner().frame(maxWidth: .infinity).padding(.top, 160)
        } else if model.items.isEmpty {
            StateMessage(text: model.config.emptyText ?? "موردی پیدا نشد").frame(maxWidth: .infinity).padding(.top, 120)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 50) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { i, card in
                    PosterCard(card: card) { openTitle(card.ref) }
                        .onAppear { model.onItemAppear(i) }
                }
            }
            if model.loadingMore { Spinner().frame(maxWidth: .infinity) }
            if model.pageError {
                Button("تلاش دوباره") { model.loadNext() }.frame(maxWidth: .infinity)
            }
        }
    }
}
