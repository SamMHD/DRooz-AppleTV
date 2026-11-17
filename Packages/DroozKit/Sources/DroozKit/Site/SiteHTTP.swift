import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Small persistent secret storage (the Keychain in the app; memory in tests).
public protocol SecretStore: Sendable {
    func read(_ key: String) -> Data?
    func write(_ key: String, _ data: Data?)
}

public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}
    public func read(_ key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func write(_ key: String, _ data: Data?) { lock.lock(); values[key] = data; lock.unlock() }
}

#if canImport(Security)
import Security

/// Generic-password Keychain items. On tvOS the Keychain is the one local store the system never purges.
public final class KeychainStore: SecretStore, @unchecked Sendable {
    private let service: String
    public init(service: String = "drooz") { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    public func read(_ key: String) -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    public func write(_ key: String, _ data: Data?) {
        let q = query(key)
        guard let data else { SecItemDelete(q as CFDictionary); return }
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        if SecItemUpdate(q as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            SecItemAdd(q.merging(attrs) { $1 } as CFDictionary, nil)
        }
    }
}
#endif

/// The site's cookies live in `HTTPCookieStorage.shared` (so AVPlayer's playlist and segment requests carry
/// them too), mirrored to a [SecretStore] because tvOS may purge the app's Library at any time.
/// `scr=1` is added to the storage at start and never persisted.
public final class CookieVault: @unchecked Sendable {
    private let storage: HTTPCookieStorage
    private let store: SecretStore
    private let key = "cookies.v1"
    private let lock = NSLock()
    private var lastSaved: Data?

    public init(storage: HTTPCookieStorage = .shared, store: SecretStore) {
        self.storage = storage
        self.store = store
        restore()
        ensureScr()
    }

    private var siteURL: URL { URL(string: SiteConfig.baseURL)! }

    public func siteCookies() -> [HTTPCookie] { storage.cookies(for: siteURL) ?? [] }

    public func value(_ name: String) -> String? {
        siteCookies().last { $0.name == name && ($0.expiresDate.map { $0 > Date() } ?? true) }?.value
    }

    private func ensureScr() {
        let c = HTTPCookie(properties: [
            .name: SiteConfig.scrCookie, .value: SiteConfig.scrValue, .domain: SiteConfig.host, .path: "/",
            .expires: Date().addingTimeInterval(10 * 365 * 86_400),
        ])
        if let c { storage.setCookie(c) }
    }

    private func restore() {
        guard let data = store.read(key),
              let list = try? JSONDecoder().decode([[String: String]].self, from: data) else { return }
        lastSaved = data
        for dict in list {
            var props: [HTTPCookiePropertyKey: Any] = [:]
            for (k, v) in dict { props[HTTPCookiePropertyKey(k)] = v }
            if let exp = dict["expiresAt"], let t = Double(exp) {
                props.removeValue(forKey: HTTPCookiePropertyKey("expiresAt"))
                props[.expires] = Date(timeIntervalSince1970: t)
            }
            if let c = HTTPCookie(properties: props), (c.expiresDate.map { $0 > Date() } ?? true) {
                storage.setCookie(c)
            }
        }
    }

    /// Mirrors the site's cookies (except `scr`) to the secret store when they changed.
    public func persist() {
        let list: [[String: String]] = siteCookies().filter { $0.name != SiteConfig.scrCookie }.map { c in
            var d: [String: String] = [
                HTTPCookiePropertyKey.name.rawValue: c.name,
                HTTPCookiePropertyKey.value.rawValue: c.value,
                HTTPCookiePropertyKey.domain.rawValue: c.domain,
                HTTPCookiePropertyKey.path.rawValue: c.path,
            ]
            if c.isSecure { d[HTTPCookiePropertyKey.secure.rawValue] = "TRUE" }
            // Session cookies are kept for a year: the site's own session cookie outlives the app's processes.
            let exp = c.expiresDate ?? Date().addingTimeInterval(365 * 86_400)
            d["expiresAt"] = String(exp.timeIntervalSince1970)
            return d
        }.sorted { ($0["name"] ?? "") < ($1["name"] ?? "") }
        guard let data = try? JSONEncoder().encode(list) else { return }
        lock.lock(); defer { lock.unlock() }
        if data == lastSaved { return }
        lastSaved = data
        store.write(key, data)
    }

    /// Removes all site cookies except those named in `keep` (logout keeps the device id `sf`).
    public func clear(keep: Set<String> = []) {
        for c in siteCookies() where !keep.contains(c.name) && c.name != SiteConfig.scrCookie {
            storage.deleteCookie(c)
        }
        ensureScr()
        persist()
    }
}

public struct SiteResponse: Sendable {
    public let finalPath: String
    public let body: String
}

/// Thin HTTP layer for the site: cookies, browser UA, retries, typed failures.
///
/// The site's server silently drops a share of requests (TLS completes, no response ever comes; healthy
/// responses arrive in < 1 s). GETs therefore use a short timeout and are retried up to `maxAttempts` times
/// on timeouts and gateway errors; a 429 is retried once its short `Retry-After` has passed. POSTs never retry.
public final class SiteHTTP: @unchecked Sendable {
    public let vault: CookieVault
    private let session: URLSession
    private let maxAttempts: Int
    private let timeout: TimeInterval
    private let postTimeout: TimeInterval
    private let retryDelay: TimeInterval

    public init(vault: CookieVault, storage: HTTPCookieStorage = .shared, timeout: TimeInterval = 8,
                maxAttempts: Int = 3, postTimeout: TimeInterval = 30, retryDelay: TimeInterval = 0.5) {
        self.vault = vault
        self.maxAttempts = maxAttempts
        self.timeout = timeout
        self.postTimeout = postTimeout
        self.retryDelay = retryDelay
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = storage
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.httpAdditionalHeaders = ["User-Agent": SiteConfig.userAgent]
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForResource = 25
        session = URLSession(configuration: cfg)
    }

    public func url(_ path: String) throws -> URL {
        if path.hasPrefix("http"), let u = URL(string: path) { return u }
        guard let u = URL(string: path, relativeTo: URL(string: SiteConfig.baseURL)!)?.absoluteURL else {
            throw SiteError.parse("url \(path)")
        }
        return u
    }

    /// Pass `retry = false` for GETs that change server state (toggles): a dropped-but-processed request must not repeat.
    public func get(_ path: String, requiresAuth: Bool = true, retry: Bool = true) async throws -> SiteResponse {
        var req = URLRequest(url: try url(path), timeoutInterval: timeout)
        req.httpMethod = "GET"
        let attempts = retry ? maxAttempts : 1
        var attempt = 1
        while true {
            do {
                return try await execute(req, requiresAuth: requiresAuth)
            } catch let e as SiteError {
                guard let wait = retryWait(e), attempt < attempts else { throw e }
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                attempt += 1
            }
        }
    }

    public func postMultipart(_ path: String, fields: [(String, String)]) async throws -> SiteResponse {
        let boundary = "----drooz\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()
        for (k, v) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        var req = URLRequest(url: try url(path), timeoutInterval: postTimeout)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return try await execute(req, requiresAuth: false)
    }

    private func execute(_ req: URLRequest, requiresAuth: Bool) async throws -> SiteResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            throw SiteError.network(error.localizedDescription)
        }
        vault.persist()
        let body = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if (http.statusCode == 403 || http.statusCode == 503) && (body.contains("cf-chl") || body.contains("Just a moment")) {
                throw SiteError.blocked
            }
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            throw SiteError.http(code: http.statusCode, retryAfterSeconds: retryAfter)
        }
        let finalPath = response.url?.path ?? "/"
        let normalized = finalPath.hasSuffix("/") ? finalPath : finalPath + "/"
        if requiresAuth && normalized.hasPrefix(SiteConfig.loginPath) { throw SiteError.sessionExpired }
        if body.count < 4000 && body.contains("setCookie(window.devicePixelRatio)") { throw SiteError.parse("scr-stub") }
        return SiteResponse(finalPath: normalized, body: body)
    }

    private func retryWait(_ e: SiteError) -> TimeInterval? {
        switch e {
        case .network: return retryDelay
        case .http(let code, _) where [502, 503, 504].contains(code): return retryDelay
        case .http(429, let after):
            let wait = after.map(TimeInterval.init) ?? retryDelay
            return wait <= 5 ? max(wait, retryDelay) : nil
        default: return nil
        }
    }
}
