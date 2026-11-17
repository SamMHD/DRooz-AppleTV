import SwiftUI
import DroozKit

/// App-wide services and the login/session state. One instance, created at launch.
@MainActor
@Observable
final class AppModel {
    let http: SiteHTTP
    let auth: AuthService
    let site: SiteRepository
    let titleInfo: TitleInfoRepository
    let watch: WatchStore
    let hidden: HiddenTitles
    let playerPrefs = PlayerPrefs()
    let titlePrefs: TitlePrefs
    let recentSearches: RecentSearches
    let homeCache = HomePageCache()
    @ObservationIgnored lazy var player = PlayerPresenter(app: self)

    /// Drives Login vs the main tabs.
    var loggedIn: Bool
    /// Bumped whenever the player closes: pages showing watch state refresh.
    var playbackEnded = 0
    /// Bumped when «لیست من» changed: the My List grid reloads.
    var watchlistChanged = 0

    init() {
        let keychain = KeychainStore(service: "com.drooz.tv")
        let vault = CookieVault(store: keychain)
        let http = SiteHTTP(vault: vault)
        let watch = WatchStore()
        let hidden = HiddenTitles()
        let titlePrefs = TitlePrefs()
        let recent = RecentSearches()
        self.watch = watch
        self.hidden = hidden
        self.titlePrefs = titlePrefs
        self.recentSearches = recent
        let auth = AuthService(http: http, store: keychain, onAccountChanged: {
            // Another account on this TV starts without the previous one's progress and choices.
            watch.clear(); hidden.clear(); titlePrefs.clear(); recent.clear()
        })
        self.http = http
        self.auth = auth
        weak var weakSelf: AppModel?
        let site = SiteRepository(http: http, auth: auth, onSessionLost: {
            Task { @MainActor in weakSelf?.sessionLost() }
        })
        self.site = site
        self.titleInfo = TitleInfoRepository(fetch: { ref in try await site.title(ref) })
        self.loggedIn = auth.isLoggedIn
        weakSelf = self
        configureImageCache()
    }

    /// The site refused the stored credentials: back to Login, with nothing of the old session cached.
    func sessionLost() {
        guard loggedIn else { return }
        forgetSession()
        loggedIn = false
    }

    func didLogIn() {
        forgetSession()
        Task { await site.resetRefusal() }
        loggedIn = true
    }

    func logout() async {
        player.close()
        await auth.logout()
        forgetSession()
        recentSearches.clear()
        loggedIn = false
    }

    private func forgetSession() {
        homeCache.clear()
        Task { await titleInfo.clear() }
    }

    func clearCaches() async {
        homeCache.clear()
        await titleInfo.clear()
        ImagePipeline.shared.clear()
    }

    func play(_ ref: TitleRef, streamId: String, dub: Bool) {
        player.start(ref: ref, streamId: streamId, dub: dub)
    }

    private func configureImageCache() {
        URLCache.shared = URLCache(memoryCapacity: 32 << 20, diskCapacity: 400 << 20)
    }
}

extension Error {
    /// Persian message for a failed load.
    var userMessage: String {
        if let e = self as? SiteError, e.isNetwork { return "اتصال به سایت برقرار نشد" }
        return "بارگذاری نشد"
    }

    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}
