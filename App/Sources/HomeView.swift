import SwiftUI
import DroozKit

struct CardFocus: Hashable {
    let row: String
    let ref: TitleRef
}

/// Netflix-style home: the focused title's backdrop and info on top, rows below.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openTitle) private var openTitle
    @State private var model: HomeModel?

    var body: some View {
        Group {
            if let model { HomeContent(model: model) } else { Palette.background }
        }
        .onAppear {
            if model == nil { model = HomeModel(app: app) } else { model?.onAppear() }
        }
        .onChange(of: app.playbackEnded) { _, _ in model?.onAppear() }
    }
}

private struct HomeContent: View {
    @Bindable var model: HomeModel
    @Environment(\.openTitle) private var openTitle
    @FocusState private var focus: CardFocus?

    var body: some View {
        ZStack(alignment: .top) {
            hero
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 50) {
                    Color.clear.frame(height: 470)
                    ForEach(model.rows.filter { !$0.isEmptyResult }) { row in
                        RowView(row: row, model: model, focus: $focus) { ref in
                            if let route = model.activate(row.key, ref) { openTitle(route) }
                        }
                    }
                }
                .padding(.bottom, 80)
            }
            .scrollClipDisabled()
        }
        .background(Palette.background)
        .ignoresSafeArea(edges: [.top, .horizontal])
        .onChange(of: focus) { _, f in if let f { model.onFocus(f.row, f.ref) } }
    }

    private var hero: some View {
        // Leading is the right edge in this RTL screen: the info sits over the gradient's dark side.
        ZStack(alignment: .topLeading) {
            if let h = model.hero {
                BackdropView(backdrop: h.backdrop)
                    .frame(width: 1920, height: 1080)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.45),
                                                 .init(color: .clear, location: 0.85)], startPoint: .top, endPoint: .bottom))
                LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .trailing, endPoint: .center)
                    .environment(\.layoutDirection, .leftToRight)
                HeroInfo(hero: h)
                    .frame(width: 1000, alignment: .leading)
                    .padding(.top, 150).padding(.horizontal, 90)
            }
        }
        .frame(width: 1920, height: 1080, alignment: .top)
        .animation(.easeInOut(duration: 0.3), value: model.hero?.ref)
    }
}

struct HeroInfo: View {
    let hero: HeroUI
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TitleText(text: hero.title, size: 64, lines: 1)
            HStack(spacing: 18) {
                if let s = hero.imdb { ImdbBadge(score: s) }
                ForEach(hero.meta, id: \.self) { Text($0).font(.vazir(24, .medium)).foregroundStyle(Palette.meta).lineLimit(1) }
                ForEach(hero.chips, id: \.self) { MetaChip(text: $0) }
            }
            if let s = hero.synopsis {
                Text(s).font(.vazir(25)).foregroundStyle(.white.opacity(0.9)).lineLimit(3).lineSpacing(6)
            }
        }
    }
}

private struct RowView: View {
    let row: RowUI
    let model: HomeModel
    var focus: FocusState<CardFocus?>.Binding
    let activate: (TitleRef) -> Void
    @Environment(\.openTitle) private var openTitle

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 20) {
                Text(row.title).font(.vazir(32, .bold))
                if row.key == "recent" && !row.items.isEmpty {
                    Text("برای گزینه‌های بیشتر OK را نگه دارید").font(.vazir(20)).foregroundStyle(Palette.secondary)
                }
            }
            .padding(.horizontal, 90)
            content
        }
        .onAppear { model.loadRowIfNeeded(row.key) }
    }

    @ViewBuilder private var content: some View {
        if row.items.isEmpty {
            Group {
                if row.loading || (!row.loaded && !row.error && row.key != "recent") {
                    HStack { Spinner(); Spacer() }
                } else if row.error {
                    Button("تلاش دوباره") { model.retry(row.key) }.font(.vazir(24, .bold))
                } else {
                    Text("هنوز چیزی تماشا نکرده‌اید").font(.vazir(22)).foregroundStyle(Palette.secondary)
                }
            }
            .padding(.horizontal, 90)
            .frame(height: 120)
        } else {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(row.items) { card in
                        cardView(card)
                    }
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
        }
    }

    @ViewBuilder private func cardView(_ card: CardUI) -> some View {
        if card.landscape {
            LandscapeCard(card: card, focus: target(card)) { activate(card.ref) }
                .contextMenu {
                    Button("جزئیات") { openTitle(card.ref) }
                    Button("حذف از ادامه تماشا", role: .destructive) { model.removeFromContinue(card.ref) }
                }
        } else {
            PosterCard(card: card, focus: target(card)) { activate(card.ref) }
        }
    }

    private func target(_ card: CardUI) -> CardFocusTarget {
        CardFocusTarget(binding: focus, key: CardFocus(row: row.key, ref: card.ref))
    }
}
