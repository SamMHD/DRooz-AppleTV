import SwiftUI
import DroozKit

/// 2:3 poster with its title underneath.
struct PosterCard: View {
    let card: CardUI
    var width: CGFloat = 240
    var focus: CardFocusTarget? = nil
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: action) {
                RemoteImage(url: card.imageURL)
                    .frame(width: width, height: width * 1.5)
                    .overlay(alignment: .bottomLeading) {
                        if card.imageURL == nil { placeholderTitle }
                    }
            }
            .buttonStyle(.card)
            .cardFocus(focus)
            TitleText(text: card.title, size: 22, lines: 1)
                .frame(width: width, alignment: .leading)
                .foregroundStyle(.white.opacity(0.9))
            if let s = card.subtitle {
                Text(s).font(.vazir(20)).foregroundStyle(Palette.secondary).lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
    }

    private var placeholderTitle: some View {
        TitleText(text: card.title, size: 24, lines: 3).padding(12)
    }
}

/// 16:9 «ادامه تماشا» card: title and episode over the image, red progress bar.
struct LandscapeCard: View {
    let card: CardUI
    var focus: CardFocusTarget? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottom) {
                RemoteImage(url: card.imageURL)
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    TitleText(text: card.title, size: 26, lines: 1)
                    if let s = card.subtitle {
                        Text(s).font(.vazir(20, .medium)).foregroundStyle(Palette.meta).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.bottom, card.progress == nil ? 14 : 20)
                if let p = card.progress {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.3))
                            Rectangle().fill(Palette.accent).frame(width: g.size.width * min(max(p, 0), 1))
                        }
                    }
                    .frame(height: 6)
                }
            }
            .frame(width: 480, height: 270)
            .environment(\.layoutDirection, .rightToLeft)
        }
        .buttonStyle(.card)
        .cardFocus(focus)
    }
}

/// Binds a card's button to a screen's focus state.
struct CardFocusTarget {
    let binding: FocusState<CardFocus?>.Binding
    let key: CardFocus
}

extension View {
    @ViewBuilder func cardFocus(_ target: CardFocusTarget?) -> some View {
        if let target { focused(target.binding, equals: target.key) } else { self }
    }
}
