import SwiftUI
import UIKit.UIGestureRecognizerSubclass
import AVFoundation
import DroozKit

@main
struct DroozApp: App {
    @State private var app = AppModel()

    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setSupportsMultichannelContent(true)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "fa_IR"))
                .preferredColorScheme(.dark)
                .tint(Palette.accent)
        }
    }
}

enum Tab: Hashable { case home, series, films, myList, search, settings }

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var tab: Tab = .home
    /// Bumped when the tab that is already showing is chosen again: that tab's stack goes back to its root.
    @State private var popToRoot: [Tab: Int] = [:]

    var body: some View {
        Group {
            if app.loggedIn {
                TabView(selection: $tab) {
                    TabStack(popToken: popToRoot[.home, default: 0]) { HomeView() }
                        .tabItem { Text("خانه") }.tag(Tab.home)
                    TabStack(popToken: popToRoot[.series, default: 0]) {
                        ListScreen(config: .init(title: "سریال‌ها", path: "/archive/series/", categories: .series))
                    }
                    .tabItem { Text("سریال‌ها") }.tag(Tab.series)
                    TabStack(popToken: popToRoot[.films, default: 0]) {
                        ListScreen(config: .init(title: "فیلم‌ها", path: "/archive/category/new-films/", categories: .film))
                    }
                    .tabItem { Text("فیلم‌ها") }.tag(Tab.films)
                    TabStack(popToken: popToRoot[.myList, default: 0]) {
                        ListScreen(config: .init(title: "لیست من", path: "/user/watchlist/", emptyText: "لیست شما خالی است", watchlist: true))
                    }
                    .tabItem { Text("لیست من") }.tag(Tab.myList)
                    TabStack(popToken: popToRoot[.search, default: 0]) { SearchScreen() }
                        .tabItem { Image(systemName: "magnifyingglass") }.tag(Tab.search)
                    NavigationStack { SettingsScreen() }
                        .tabItem { Image(systemName: "gearshape") }.tag(Tab.settings)
                }
                .font(.vazir(28, .medium))
                .background(TabBarSelectPress { popToRoot[tab, default: 0] += 1 })
            } else {
                LoginScreen()
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .onChange(of: app.loggedIn) { _, now in if now { tab = .home } }
    }
}

/// Every title link in the app navigates with this value.
struct TitleRoute: Hashable {
    let ref: TitleRef
    var featuredBackdrop: String? = nil
}

/// Opens a title page on the current tab's stack.
struct OpenTitle {
    var action: (TitleRoute) -> Void = { _ in }
    func callAsFunction(_ route: TitleRoute) { action(route) }
    func callAsFunction(_ ref: TitleRef) { action(TitleRoute(ref: ref)) }
}

private struct OpenTitleKey: EnvironmentKey { static let defaultValue = OpenTitle() }

extension EnvironmentValues {
    var openTitle: OpenTitle {
        get { self[OpenTitleKey.self] }
        set { self[OpenTitleKey.self] = newValue }
    }
}

/// One tab's navigation stack: its root, then title pages.
struct TabStack<Root: View>: View {
    /// A change returns the stack to its root.
    var popToken = 0
    @ViewBuilder var root: () -> Root
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            root()
                .navigationDestination(for: TitleRoute.self) { TitleScreen(route: $0) }
        }
        .environment(\.openTitle, OpenTitle { route in path.append(route) })
        .onChange(of: popToken) { path = NavigationPath() }
    }
}

/// tvOS selects a tab as soon as it gets focus, so pressing Select on the tab bar means "this tab again".
/// SwiftUI doesn't report that, so a press recognizer on the system tab bar does.
private struct TabBarSelectPress: UIViewRepresentable {
    var action: () -> Void

    func makeUIView(context: Context) -> Anchor { Anchor() }
    func updateUIView(_ view: Anchor, context: Context) { view.action = action }

    final class Anchor: UIView {
        var action: () -> Void = {} { didSet { recognizer?.action = action } }
        private weak var recognizer: Recognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // The tab bar controller is set up after this view joins the window.
            DispatchQueue.main.async { [weak self] in self?.install() }
        }

        private func install() {
            guard recognizer == nil, let root = window?.rootViewController, let tabBar = Self.tabBarController(in: root)?.tabBar else { return }
            let r = Recognizer()
            r.action = action
            tabBar.addGestureRecognizer(r)
            recognizer = r
        }

        private static func tabBarController(in vc: UIViewController) -> UITabBarController? {
            if let t = vc as? UITabBarController { return t }
            for child in vc.children + [vc.presentedViewController].compactMap({ $0 }) {
                if let t = tabBarController(in: child) { return t }
            }
            return nil
        }
    }

    /// Holds its own action: the tab bar keeps the recognizer alive, not the SwiftUI view.
    final class Recognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
        var action: () -> Void = {}

        init() {
            super.init(target: nil, action: nil)
            addTarget(self, action: #selector(fire))
            allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
            allowedTouchTypes = []
            cancelsTouchesInView = false
            delegate = self
        }

        // Recognized as soon as Select goes down: on the same press the tab bar moves focus into the tab,
        // which makes a tap recognizer fail at random.
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            state = presses.contains { $0.type == .select } ? .recognized : .failed
        }

        // The tab bar's own handling of the press goes on as usual.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc private func fire() { action() }
    }
}
