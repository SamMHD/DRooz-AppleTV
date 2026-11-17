import SwiftUI
import UIKit
import DroozKit

enum Palette {
    static let background = Color(red: 0x0B / 255, green: 0x0B / 255, blue: 0x0F / 255)
    static let accent = Color(red: 0xE5 / 255, green: 0x09 / 255, blue: 0x14 / 255)
    static let imdb = Color(red: 0xF5 / 255, green: 0xC5 / 255, blue: 0x18 / 255)
    static let watched = Color(red: 0x46 / 255, green: 0xD3 / 255, blue: 0x69 / 255)
    static let secondary = Color(red: 0x9E / 255, green: 0xA2 / 255, blue: 0xAD / 255)
    static let meta = Color(red: 0xCF / 255, green: 0xD2 / 255, blue: 0xDA / 255)
    static let surface = Color(red: 0x1A / 255, green: 0x1A / 255, blue: 0x21 / 255)
}

extension Font {
    enum VazirWeight: String { case regular = "Regular", medium = "Medium", bold = "Bold", extraBold = "ExtraBold" }

    /// Vazirmatn (Persian chrome); sizes are tvOS points (1920×1080).
    static func vazir(_ size: CGFloat, _ weight: VazirWeight = .regular) -> Font {
        .custom("Vazirmatn-\(weight.rawValue)", size: size)
    }
}

extension String {
    /// Titles are mostly Latin (original names); those keep the system font and left-to-right order.
    var isLatinTitle: Bool {
        contains { $0.isLetter } && !unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }
    }
}

/// A title in its own script: Latin titles in SF, left-to-right; Persian ones in Vazirmatn.
struct TitleText: View {
    let text: String
    var size: CGFloat
    var lines = 2

    var body: some View {
        if text.isLatinTitle {
            Text(text).font(.system(size: size, weight: .bold)).lineLimit(lines)
                .environment(\.layoutDirection, .leftToRight)
        } else {
            Text(text).font(.vazir(size, .extraBold)).lineLimit(lines)
        }
    }
}

struct ImdbBadge: View {
    let score: Double
    var size: CGFloat = 24
    var body: some View {
        Text(UiStrings.imdb(score))
            .font(.system(size: size, weight: .heavy))
            .foregroundStyle(.black)
            .padding(.horizontal, 10).padding(.vertical, 2)
            .background(Palette.imdb, in: RoundedRectangle(cornerRadius: 6))
            .environment(\.layoutDirection, .leftToRight)
    }
}

struct MetaChip: View {
    let text: String
    var body: some View {
        Text(text).font(.vazir(22, .medium)).foregroundStyle(Palette.meta)
            .padding(.horizontal, 10).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.4), lineWidth: 1.5))
    }
}

/// Image loading with a memory cache on top of URLCache's disk cache.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()
    private let memory = NSCache<NSURL, UIImage>()
    private let session: URLSession

    init() {
        memory.totalCostLimit = 150 << 20
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 500 << 20)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.httpAdditionalHeaders = ["User-Agent": SiteConfig.userAgent]
        cfg.httpCookieStorage = .shared
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg)
    }

    func cached(_ url: URL) -> UIImage? { memory.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        for attempt in 0..<2 {
            do {
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return nil }
                guard let img = UIImage(data: data) else { return nil }
                let decoded = await Task.detached(priority: .utility) { img.preparingForDisplay() ?? img }.value
                memory.setObject(decoded, forKey: url as NSURL, cost: data.count * 4)
                return decoded
            } catch {
                if error.isCancellation || attempt == 1 { return nil }
            }
        }
        return nil
    }

    func clear() {
        memory.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }
}

/// A remote image that fades in; `placeholder` shows until (or unless) it loads.
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?
    @State private var loadedURL: URL?

    var body: some View {
        ZStack {
            Palette.surface
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            }
        }
        .clipped()
        .task(id: url) {
            guard let url else { image = nil; return }
            if loadedURL == url, image != nil { return }
            if let hit = ImagePipeline.shared.cached(url) { image = hit; loadedURL = url; return }
            let img = await ImagePipeline.shared.load(url)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { image = img; loadedURL = url }
        }
    }
}

/// Full-screen backdrop that crossfades between titles.
struct BackdropView: View {
    let backdrop: Backdrop

    var body: some View {
        ZStack {
            Palette.background
            switch backdrop {
            case .wide(let url):
                RemoteImage(url: url).id(url)
            case .blurredPoster(let url):
                RemoteImage(url: url).blur(radius: 40).opacity(0.7).id(url)
            case .none:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.4), value: backdrop)
    }
}

/// Persian loading / error states.
struct StateMessage: View {
    let text: String
    var retry: (() -> Void)?
    var body: some View {
        VStack(spacing: 24) {
            Text(text).font(.vazir(30, .medium)).foregroundStyle(Palette.secondary)
            if let retry {
                Button("تلاش دوباره", action: retry).font(.vazir(26, .bold))
            }
        }
    }
}

struct Spinner: View {
    var body: some View { ProgressView().scaleEffect(1.4).tint(.white) }
}
