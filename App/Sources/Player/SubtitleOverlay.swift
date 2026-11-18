import SwiftUI
import DroozKit

/// What the subtitle layer draws. DUAL: `primary` = Farsi, `secondary` = English.
@MainActor
@Observable
final class SubtitleOverlayModel {
    var primary: String?
    var secondary: String?
    var style = SubtitleStyle()
    /// The video's natural size (for the letterbox bars); nil until known.
    var videoSize: CGSize?
    /// The player's own title view overlaps its buttons on tvOS 27, so the title is drawn here instead,
    /// shown only while the transport bar is.
    var heading = ""
    var subheading: String?
    /// The transport bar is on screen: show the heading and keep subtitles clear of the controls.
    var chromeVisible = false
}

/// One subtitle line block as styled by the user.
struct SubtitleLine: View {
    let text: String
    let style: SubtitleStyle
    var scale: CGFloat = 1

    var body: some View {
        let (r, g, b) = style.color.rgb
        Text(text)
            .font(.vazir(46 * CGFloat(style.sizePercent) / 100 * scale, .bold))
            .foregroundStyle(Color(red: r, green: g, blue: b))
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .shadow(color: .black, radius: 2, x: 0, y: 0)
            .shadow(color: .black.opacity(0.8), radius: 4, x: 1, y: 2)
            .padding(.horizontal, 14).padding(.vertical, 4)
            .background(Color.black.opacity(Double(style.backgroundOpacity) / 100), in: RoundedRectangle(cornerRadius: 8))
            .environment(\.layoutDirection, text.isLatinTitle ? .leftToRight : .rightToLeft)
    }
}

/// Subtitles over the video. When the picture leaves a bottom bar tall enough, subtitles sit in the bar
/// (dual mode: Persian in the picture, English in the bar), as on the site.
struct SubtitleOverlayView: View {
    let model: SubtitleOverlayModel

    var body: some View {
        GeometryReader { g in
            let rect = fit(model.videoSize, in: g.size)
            let bar = g.size.height - rect.maxY
            let lineH = 46 * CGFloat(model.style.sizePercent) / 100 * 1.55
            let x = g.size.width / 2
            // While the controls are up, subtitles end above the heading (or above the buttons without one).
            let limit = model.chromeVisible ? g.size.height * (model.heading.isEmpty ? 770 : 640) / 1080 : .infinity
            if let fa = model.primary, let en = model.secondary {
                let enLines = CGFloat(lines(en)), faLines = CGFloat(lines(fa))
                let enInBar = bar >= lineH * enLines + 16
                let enY = enInBar ? rect.maxY + bar / 2 : rect.maxY - 50 - (enLines - 1) * lineH / 2
                let faBottom = enInBar ? rect.maxY - 40 : enY - enLines * lineH / 2 - 14
                let lift = max(0, enY + enLines * lineH / 2 - limit)
                line(en).position(x: x, y: enY - lift)
                line(fa).position(x: x, y: faBottom - faLines * lineH / 2 - lift)
            } else if let one = model.primary ?? model.secondary {
                let n = CGFloat(lines(one))
                let inBar = bar >= lineH * n + 16
                let y = inBar ? rect.maxY + bar / 2 : rect.maxY - 60 - (n - 1) * lineH / 2
                line(one).position(x: x, y: min(y, limit - n * lineH / 2))
            }
            if model.chromeVisible, !model.heading.isEmpty {
                heading
                    .frame(width: g.size.width - 168, alignment: .leading)
                    .position(x: g.size.width / 2, y: g.size.height * 715 / 1080)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// Episode line over the title, left-aligned with the transport bar's buttons (the player is laid out LTR).
    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sub = model.subheading {
                Text(sub).font(.vazir(30, .medium)).foregroundStyle(.white.opacity(0.75))
            }
            TitleText(text: model.heading, size: 54, lines: 1).foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 2)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func line(_ t: String) -> some View {
        SubtitleLine(text: t, style: model.style).frame(maxWidth: 1500)
    }

    private func lines(_ t: String) -> Int { max(1, t.split(separator: "\n").count) }

    private func fit(_ video: CGSize?, in box: CGSize) -> CGRect {
        guard let v = video, v.width > 0, v.height > 0 else { return CGRect(origin: .zero, size: box) }
        let s = min(box.width / v.width, box.height / v.height)
        let w = v.width * s, h = v.height * s
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }
}
