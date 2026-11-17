import Foundation
import CryptoKit

public enum LoginResult: Equatable, Sendable {
    case success
    case needsMobile(hint: String)
    case wrongCredentials
    case failed(String)
}

public struct Credentials: Codable, Equatable, Sendable {
    public let username: String
    public let password: String
    public let mobile: String?
}

/// The site's two-step login: username+password, then (for a new device) the full mobile number together with
/// the `recaptchaPass` token from the first response. Login, relogin and logout run one at a time (actor).
public actor AuthService {
    private let http: SiteHTTP
    private let store: SecretStore
    /// Runs before a login of a different account than the previous one completes: clear that account's local data.
    private let onAccountChanged: @Sendable () async -> Void
    private var logoutGeneration = 0
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public static let networkMessage = "اتصال به سایت برقرار نشد"
    private static let credsKey = "credentials.v1"
    private static let ownerKey = "account.owner"

    public init(http: SiteHTTP, store: SecretStore, onAccountChanged: @escaping @Sendable () async -> Void = {}) {
        self.http = http
        self.store = store
        self.onAccountChanged = onAccountChanged
    }

    public nonisolated var isLoggedIn: Bool { http.vault.value(SiteConfig.sessionCookie) != nil }
    public nonisolated var sessionToken: String? { http.vault.value(SiteConfig.sessionCookie) }

    public nonisolated func username() -> String? { loadCredentials()?.username }

    nonisolated func loadCredentials() -> Credentials? {
        store.read(Self.credsKey).flatMap { try? JSONDecoder().decode(Credentials.self, from: $0) }
    }

    private func saveCredentials(_ c: Credentials?) {
        store.write(Self.credsKey, c.flatMap { try? JSONEncoder().encode($0) })
    }

    /// Serializes the critical sections (an actor alone re-enters at every await).
    private func lock() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func unlock() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    public func login(username: String, password: String, mobile: String?) async -> LoginResult {
        let gen = logoutGeneration
        await lock()
        defer { unlock() }
        return await loginLocked(username, password, mobile, gen)
    }

    private func loginLocked(_ username: String, _ password: String, _ mobile: String?, _ gen: Int) async -> LoginResult {
        if logoutGeneration != gen { return .failed("ورود انجام نشد") }
        do {
            // Like a browser, load the form first: the site pairs its `sf` cookie with the `recaptchaPass` token.
            let form = try await http.get(SiteConfig.loginPath, requiresAuth: false)
            if !form.finalPath.hasPrefix(SiteConfig.loginPath) {
                // Already logged in: end that session server-side, keep the device cookie, log in as requested.
                _ = try? await http.get(SiteConfig.logoutPath, requiresAuth: false, retry: false)
                http.vault.clear(keep: [SiteConfig.deviceCookie])
                _ = try await http.get(SiteConfig.loginPath, requiresAuth: false)
            }
            let base = [("username", username), ("password", password)]
            let first = try await post(base)
            var result: LoginResult
            if case let .needsMobile(pass, hint) = first {
                guard let mobile, !mobile.trimmingCharacters(in: .whitespaces).isEmpty else { return .needsMobile(hint: hint) }
                result = toResult(try await post(base + [("recaptchaPass", pass), ("mobile", mobile)]))
            } else {
                result = toResult(first)
            }
            if logoutGeneration != gen {
                http.vault.clear(keep: [SiteConfig.deviceCookie])
                return .failed("ورود انجام نشد")
            }
            if result == .success {
                saveCredentials(Credentials(username: username, password: password, mobile: mobile))
                if claimOwner(username) { await onAccountChanged() }
                // The website reports the screen once; we report a 4K panel.
                _ = try? await http.get("/json/device/?width=3840&height=2160&pixelRatio=1", requiresAuth: false)
            }
            return result
        } catch let e as SiteError {
            return .failed(e.isNetwork ? Self.networkMessage : "ورود انجام نشد")
        } catch {
            return .failed("ورود انجام نشد")
        }
    }

    public enum Renewal: Sendable { case renewed, refused, unreachable }

    /// Renews an expired session with the stored credentials; the `sf` device cookie is kept.
    /// `.refused` when the site refuses (or nothing is stored): the dead session cookie is dropped.
    /// `.unreachable` when the site could not be asked (network): nothing is dropped.
    public func relogin() async -> Renewal {
        let gen = logoutGeneration
        let c = loadCredentials()
        await lock()
        defer { unlock() }
        guard let c else {
            if logoutGeneration == gen { http.vault.clear(keep: [SiteConfig.deviceCookie]) }
            return .refused
        }
        let result = await loginLocked(c.username, c.password, c.mobile, gen)
        if result == .success { return .renewed }
        if result == .failed(Self.networkMessage) { return .unreachable }
        if logoutGeneration == gen {
            if result == .wrongCredentials { saveCredentials(nil) }
            http.vault.clear(keep: [SiteConfig.deviceCookie])
        }
        return .refused
    }

    /// Credentials go first so a relogin starting now cannot reuse them. The `sf` device cookie is kept.
    public func logout() async {
        logoutGeneration += 1
        saveCredentials(nil)
        await lock()
        defer { unlock() }
        saveCredentials(nil)
        _ = try? await http.get(SiteConfig.logoutPath, requiresAuth: false, retry: false)
        http.vault.clear(keep: [SiteConfig.deviceCookie])
    }

    private func post(_ fields: [(String, String)]) async throws -> LoginPage {
        LoginParser.parse(try await http.postMultipart(SiteConfig.loginPath, fields: fields).body)
    }

    private func toResult(_ page: LoginPage) -> LoginResult {
        switch page {
        case .redirecting: return isLoggedIn ? .success : .failed("ورود انجام نشد")
        case .wrongCredentials: return .wrongCredentials
        case .needsMobile: return .failed("شماره موبایل پذیرفته نشد")
        case .form: return .failed("ورود انجام نشد")
        case .unknown(let alert): return .failed(alert ?? "پاسخ ناشناخته از سایت")
        }
    }

    /// True when a different account owned the local data before (the caller clears it).
    private func claimOwner(_ username: String) -> Bool {
        let digest = SHA256.hash(data: Data(username.trimmingCharacters(in: .whitespaces).lowercased().utf8))
        let id = Data(digest.map { $0 }).base64EncodedString()
        let previous = store.read(Self.ownerKey).map { String(decoding: $0, as: UTF8.self) }
        if previous == id { return false }
        store.write(Self.ownerKey, Data(id.utf8))
        return previous != nil
    }
}

/// Everything the UI asks of the site. An expired session is renewed once, transparently; when that fails
/// `onSessionLost` runs (the app goes to Login) and `SiteError.notLoggedIn` is thrown.
public actor SiteRepository {
    public let http: SiteHTTP
    public let auth: AuthService
    private let onSessionLost: @Sendable () -> Void
    private var refused = false
    private var refusedToken: String?
    private var renewing: Task<AuthService.Renewal, Never>?

    public init(http: SiteHTTP, auth: AuthService, onSessionLost: @escaping @Sendable () -> Void = {}) {
        self.http = http
        self.auth = auth
        self.onSessionLost = onSessionLost
    }

    public func home() async throws -> HomePage {
        try await authed { try HomeParser.parse(try await self.http.get("/").body) }
    }

    /// Page 1 is `path` itself; page N inserts `N/` before any query string.
    public func list(_ path: String, page: Int = 1) async throws -> ListPage {
        let target: String
        if page <= 1 { target = path } else {
            let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
            let base = parts[0].hasSuffix("/") ? parts[0] : parts[0] + "/"
            target = "\(base)\(page)/" + (parts.count > 1 ? "?\(parts[1])" : "")
        }
        return try await authed { ListParser.parse(try await self.http.get(target).body) }
    }

    /// Page 1 of `path` and the navigation menu's categories, from one request.
    public func listWithCategories(_ path: String) async throws -> CategorizedListPage {
        try await authed {
            let doc = parseDoc(try await self.http.get(path).body)
            return CategorizedListPage(page: ListParser.parse(doc: doc), categories: CategoryMenuParser.parse(doc: doc))
        }
    }

    public func search(_ query: String) async throws -> [TitleCard] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        return try await authed { SearchParser.parse(try await self.http.get("/search/?s=\(q)").body) }
    }

    public func title(_ ref: TitleRef) async throws -> TitleDetail {
        try await authed { try TitleParser.parse(try await self.http.get(ref.path).body, ref: ref) }
    }

    /// Opening the stream page marks the title as streamed on the account; call only right before playback.
    public func openStream(_ episode: Episode, ref: TitleRef, lang: String, height: Int = 1080) async throws -> StreamSession {
        try await authed {
            let body = try await self.http.get("/stream/\(episode.streamId)/\(ref.postId)/?lang=\(lang)&h=\(height)").body
            return try StreamPageParser.parse(body, streamId: episode.streamId)
        }
    }

    /// `state` is one of `watch`, `favorite`, `watched`. It toggles on the site, so it is never retried.
    public func setWatchlist(postId: Int64, state: String) async throws {
        _ = try await authed { try await self.http.get("/json/userWatchlist/\(postId)/\(state)/", retry: false) }
    }

    public func subtitle(_ url: String) async throws -> String {
        try await authed { try await self.http.get(url).body }
    }

    public func reportStreamError(streamId: String, event: String, msg: String) async {
        let m = msg.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        _ = try? await http.get("/json/logStreamError/\(streamId)/?event=\(event)&msg=\(m)", requiresAuth: false, retry: false)
    }

    /// Runs `block`; on an expired session renews it once and retries. Concurrent expiries share one login.
    private func authed<T: Sendable>(_ block: @Sendable () async throws -> T) async throws -> T {
        let tokenBefore = auth.sessionToken
        do {
            return try await block()
        } catch SiteError.sessionExpired {}
        switch await renew(tokenBefore) {
        case .renewed: break
        case .unreachable: throw SiteError.network("relogin")
        case .refused: onSessionLost(); throw SiteError.notLoggedIn
        }
        do {
            return try await block()
        } catch SiteError.sessionExpired {
            onSessionLost()
            throw SiteError.notLoggedIn
        }
    }

    private func renew(_ tokenBefore: String?) async -> AuthService.Renewal {
        if let current = auth.sessionToken, current != tokenBefore { return .renewed }
        if refused && auth.sessionToken == refusedToken { return .refused }
        if let running = renewing { return await running.value }
        let task = Task { await auth.relogin() }
        renewing = task
        let result = await task.value
        renewing = nil
        if result != .unreachable {
            refused = result == .refused
            refusedToken = auth.sessionToken
        }
        return result
    }

    /// A new login (from the Login screen) lifts an earlier refusal.
    public func resetRefusal() { refused = false; refusedToken = nil }
}
