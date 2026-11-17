import SwiftUI
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

    var body: some View {
        Group {
            if app.loggedIn {
                TabView(selection: $tab) {
                    TabStack { HomeView() }
                        .tabItem { Text("خانه") }.tag(Tab.home)
                    TabStack {
                        ListScreen(config: .init(title: "سریال‌ها", path: "/archive/series/", categories: .series))
                    }
                    .tabItem { Text("سریال‌ها") }.tag(Tab.series)
                    TabStack {
                        ListScreen(config: .init(title: "فیلم‌ها", path: "/archive/category/new-films/", categories: .film))
                    }
                    .tabItem { Text("فیلم‌ها") }.tag(Tab.films)
                    TabStack {
                        ListScreen(config: .init(title: "لیست من", path: "/user/watchlist/", emptyText: "لیست شما خالی است", watchlist: true))
                    }
                    .tabItem { Text("لیست من") }.tag(Tab.myList)
                    TabStack { SearchScreen() }
                        .tabItem { Image(systemName: "magnifyingglass") }.tag(Tab.search)
                    NavigationStack { SettingsScreen() }
                        .tabItem { Image(systemName: "gearshape") }.tag(Tab.settings)
                }
                .font(.vazir(28, .medium))
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
    @ViewBuilder var root: () -> Root
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            root()
                .navigationDestination(for: TitleRoute.self) { TitleScreen(route: $0) }
        }
        .environment(\.openTitle, OpenTitle { route in path.append(route) })
    }
}
