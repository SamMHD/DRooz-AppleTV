import AVKit
import SwiftUI
import UIKit
import DroozKit

/// Opens and owns the one player at a time.
@MainActor
final class PlayerPresenter {
    private unowned let app: AppModel
    private var session: PlayerSession?

    init(app: AppModel) { self.app = app }

    func start(ref: TitleRef, streamId: String, dub: Bool) {
        guard session == nil else { return }
        let s = PlayerSession(app: app, ref: ref, streamId: streamId, dub: dub)
        s.onClosed = { [weak self] in
            self?.session = nil
            self?.app.playbackEnded += 1
        }
        session = s
        s.present()
    }

    func close() { session?.dismiss() }
}

/// AVPlayerViewController that reports its own dismissal (Menu on the remote).
final class DroozPlayerViewController: AVPlayerViewController {
    var onDismissed: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { onDismissed?(); onDismissed = nil }
    }
}

/// The subtitle choices the stream offers: FA, EN, DUAL (both files), FA_DUB, then OFF always.
private func subtitleKinds(_ c: SubtitleChoice) -> [SubtitleKind] {
    switch c {
    case .fa: return [.fa]
    case .en: return [.en]
    case .dual: return [.fa, .en]
    case .faDub: return [.faDub]
    case .off: return []
    }
}

private func choiceLabel(_ c: SubtitleChoice) -> String {
    switch c {
    case .fa: return "فارسی"
    case .en: return "English"
    case .dual: return "فارسی + English"
    case .faDub: return "فارسی (دوبله)"
    case .off: return "خاموش"
    }
}

/// One playback: stream page → AVPlayer, with the site player's features on top of the native controls
/// (transport bar menus for subtitles, quality, audio boost and episodes; contextual "next episode").
@MainActor
final class PlayerSession: NSObject {
    private let app: AppModel
    private let ref: TitleRef
    private let dub: Bool
    var onClosed: (() -> Void)?

    private let player = AVPlayer()
    private let vc = DroozPlayerViewController()
    private let overlay = SubtitleOverlayModel()
    private var overlayHost: UIHostingController<SubtitleOverlayView>?

    private var streamId: String
    private var episode: Episode?
    private var seasons: [Season] = []
    private var title = ""
    private var stream: StreamSession?
    private var openTask: Task<Void, Never>?
    private var closed = false
    private var everReady = false
    private var readySinceLoad = false

    // Recovery / reporting
    private var lastReopen: Date?
    private var reopenReady = false
    private var quickReopens = 0
    private var lastReport: Date?
    private var backgroundedAt: Date?

    // Progress
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var notes: [NSObjectProtocol] = []
    private var playedSinceSave: TimeInterval = 0
    private var knownDuration: Int64 = 0
    private var upNextReached = false
    private var upNextDismissed = false
    private var upNextShown: TimeInterval = 0
    private var switching = false

    // Subtitles
    private var globalChoice: SubtitleChoice = .fa
    private var choice: SubtitleChoice = .fa
    private var available: [SubtitleChoice] = []
    private var offsetMs: Int64 = 0
    private var resolvedFor: String?
    private var timelines: [SubtitleKind: SubtitleTimeline] = [:]
    private var requested = Set<SubtitleKind>()

    // Tracks
    private var qualities: [QualityOption] = []
    private var selectedQuality: Int?
    private var audioOptions: [AVMediaSelectionOption] = []
    private var audioGroup: AVMediaSelectionGroup?
    private var audioDubbed = false
    private var manualAudioLabel: String?

    // Boost
    private var boost = true
    private var schedule: GainSchedule?
    private var smoother = GainSmoother()
    private var boostClock: TimeInterval = 0

    init(app: AppModel, ref: TitleRef, streamId: String, dub: Bool) {
        self.app = app
        self.ref = ref
        self.dub = dub
        self.streamId = streamId
        super.init()
        let s = app.playerPrefs.settings
        globalChoice = s.subtitle
        overlay.style = s.style
        boost = s.audioBoost
    }

    // MARK: Presentation

    func present() {
        vc.player = player
        vc.allowsPictureInPicturePlayback = false
        // tvOS 27 mirrors the transport bar's buttons to the right in RTL apps but still opens their menus
        // rightwards, off screen. Laying the player out LTR keeps every menu on screen; menu rows stay RTL.
        vc.traitOverrides.layoutDirection = .leftToRight
        // Its title view sits on the same row as the buttons (tvOS 27); the overlay draws the title instead.
        vc.transportBarIncludesTitleView = false
        vc.delegate = self
        vc.onDismissed = { [weak self] in self?.finish() }
        let host = UIHostingController(rootView: SubtitleOverlayView(model: overlay))
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        overlayHost = host
        if let content = vc.contentOverlayView {
            host.view.frame = content.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            content.addSubview(host.view)
        }
        installObservers()
        rebuildMenus()
        topViewController()?.present(vc, animated: true)
        open(streamId, startAt: nil)
    }

    func dismiss() {
        if vc.presentingViewController != nil { vc.dismiss(animated: true) } else { finish() }
    }

    private func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
        while let p = top?.presentedViewController { top = p }
        return top
    }

    /// After the player left the screen: saves, releases the item, tells the app.
    private func finish() {
        guard !closed else { return }
        closed = true
        openTask?.cancel()
        save()
        player.pause()
        if let t = timeObserver { player.removeTimeObserver(t) }
        timeObserver = nil
        observations.forEach { $0.invalidate() }
        observations = []
        notes.forEach { NotificationCenter.default.removeObserver($0) }
        notes = []
        player.replaceCurrentItem(with: nil)
        onClosed?()
    }

    private func installObservers() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        let center = NotificationCenter.default
        notes.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, (n.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.ended()
            }
        })
        notes.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, (n.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.failed(n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
            }
        })
        notes.append(center.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, (n.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.audioSelectionChanged()
            }
        })
        notes.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.backgroundedAt = Date()
                self.save()
                self.player.pause()
            }
        })
        notes.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.returnedToForeground() }
        })
    }

    /// Back from the Home screen: the old stream key is short-lived, so a long absence opens a fresh stream here.
    private func returnedToForeground() {
        guard let at = backgroundedAt, !closed else { return }
        backgroundedAt = nil
        if Date().timeIntervalSince(at) > 30, stream != nil {
            let pos = everReady ? positionMs : nil
            open(streamId, startAt: pos, silent: true, play: false)
        }
    }

    // MARK: Opening

    /// Opens `id`'s stream page and loads it at `startAt` (nil = resume from the watch store).
    /// `silent` reopens (recovery, return from Home) keep the current picture until the new stream is ready.
    private func open(_ id: String, startAt: Int64?, silent: Bool = false, play: Bool = true) {
        guard !closed else { return }
        openTask?.cancel()
        if id != streamId {
            do {
                streamId = id
                episode = nil
                stream = nil
                everReady = false
                lastReopen = nil
                reopenReady = false
                quickReopens = 0
                upNextReached = false
                upNextDismissed = false
                upNextShown = 0
                knownDuration = 0
                schedule = nil
                smoother = GainSmoother()
                timelines = [:]
                requested = []
                offsetMs = 0
                overlay.primary = nil
                overlay.secondary = nil
                vc.contextualActions = []
            }
        }
        openTask = Task { [weak self] in
            let delays: [UInt64] = [2, 4, 8]
            var attempt = 0
            while let self, !Task.isCancelled {
                do {
                    try await self.openOnce(id, startAt: startAt, play: play)
                    return
                } catch SiteError.notLoggedIn {
                    self.dismiss()
                    return
                } catch {
                    if Task.isCancelled || error.isCancellation { return }
                    let network = (error as? SiteError)?.isNetwork == true
                    guard network, attempt < delays.count else {
                        self.fail(network ? UiStrings.playFailedNetwork : UiStrings.playFailed)
                        return
                    }
                    try? await Task.sleep(nanoseconds: delays[attempt] * 1_000_000_000)
                    attempt += 1
                }
            }
        }
    }

    private func openOnce(_ id: String, startAt: Int64?, play: Bool) async throws {
        let ep: Episode
        if let known = episode { ep = known } else {
            guard let e = try await resolveEpisode(id) else { throw SiteError.parse("episode") }
            ep = e
        }
        episode = ep
        let s = try await app.site.openStream(ep, ref: ref, lang: dub ? "dubbed-fa" : "original")
        guard !Task.isCancelled, !closed, id == streamId else { return }
        // Opening the stream marks it played on the site: the title page is stale.
        await app.titleInfo.invalidate(ref)
        if let b = s.backdropPath { await app.titleInfo.remember(ref, backdropPath: b) }
        stream = s
        schedule = GainSchedule(gains: s.gains, minGain: s.minGain, maxGain: s.maxGain)
        let saved = app.watch.get(id)
        available = availableChoices(s)
        if resolvedFor != id {
            resolvedFor = id
            choice = (dub || audioDubbed) ? (available.contains(.faDub) ? .faDub : .off) : originalChoice()
            offsetMs = saved?.subtitleOffsetMs ?? 0
        }
        if title.isEmpty { title = s.title }
        let start = startAt ?? saved.map { PlaybackRules.resumeStart($0.positionMs, $0.durationMs, finished: $0.finished) } ?? 0
        ensureSubtitles()
        await load(s, startMs: start, play: play)
        rebuildMenus()
    }

    private func resolveEpisode(_ id: String) async throws -> Episode? {
        var ep = seasons.flatMap(\.episodes).first { $0.streamId == id }
        if ep == nil {
            let d = try await app.titleInfo.get(ref)
            seasons = dub ? d.catalog.dub : d.catalog.main
            title = d.card.title
            ep = seasons.flatMap(\.episodes).first { $0.streamId == id }
        }
        return ep
    }

    private var episodeLabel: String? {
        guard ref.kind == .series, let e = episode else { return nil }
        return UiStrings.episodeLabel(e.season, e.number)
    }

    private func load(_ s: StreamSession, startMs: Int64, play: Bool) async {
        guard let url = URL(string: s.masterUrl) else { fail(UiStrings.playFailed); return }
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetHTTPCookiesKey: cookies,
            AVURLAssetHTTPUserAgentKey: SiteConfig.userAgent,
        ])
        let item = AVPlayerItem(asset: asset)
        item.externalMetadata = metadata()
        overlay.heading = title
        overlay.subheading = episodeLabel
        readySinceLoad = false
        observations.forEach { $0.invalidate() }
        observations = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in self?.statusChanged(item) }
            },
            item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, item.presentationSize.width > 0 else { return }
                    let heightChanged = self.overlay.videoSize?.height != item.presentationSize.height
                    self.overlay.videoSize = item.presentationSize
                    // «خودکار (1080p)» names the playing height, unknown when the menus were first built.
                    if heightChanged, self.selectedQuality == nil, !self.qualities.isEmpty { self.rebuildMenus() }
                }
            },
        ]
        pendingStart = startMs
        pendingPlay = play
        seekTarget = startMs
        player.replaceCurrentItem(with: item)
        await loadTracks(asset)
    }

    private var pendingStart: Int64 = 0
    private var pendingPlay = true
    /// Where a freshly loaded item is headed until its first seek lands; its own clock reads 0 until then,
    /// and a save, retry or recovery in that gap must not take that for the viewer's position.
    private var seekTarget: Int64?
    /// The item whose failure is being handled: AVFoundation can report one failure twice
    /// (status and failed-to-play-to-end), and the second must not cancel the recovery the first started.
    private weak var failedItem: AVPlayerItem?

    private func statusChanged(_ item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            guard !readySinceLoad else { return }
            readySinceLoad = true
            everReady = true
            switching = false
            if lastReopen != nil { reopenReady = true }
            applyQuality()
            let start = pendingStart
            let go = pendingPlay
            if start > 0 {
                player.seek(to: CMTime(value: start, timescale: 1000), toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600)) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.player.currentItem === item else { return }
                        self.seekTarget = nil
                        if go { self.player.play() }
                    }
                }
            } else {
                seekTarget = nil
                if go { player.play() }
            }
        case .failed:
            failed(item.error)
        default:
            break
        }
    }

    private func metadata() -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.extendedLanguageTag = "und"
            return m.copy() as! AVMetadataItem
        }
        var items = [item(.commonIdentifierTitle, title)]
        if let e = episodeLabel { items.append(item(.iTunesMetadataTrackSubTitle, e)) }
        return items
    }

    // MARK: Tracks

    private func loadTracks(_ asset: AVURLAsset) async {
        if let variants = try? await asset.load(.variants) {
            let infos = variants.compactMap { v -> VariantInfo? in
                guard let h = v.videoAttributes?.presentationSize.height, h > 0 else { return nil }
                let rate = v.peakBitRate ?? v.averageBitRate
                return VariantInfo(height: Int(h), bitrateKbps: rate.map { Int(($0 / 1000).rounded()) })
            }
            qualities = qualityOptions(infos, siteLabels: stream?.qualityLabels ?? [:])
            if let q = selectedQuality, !qualities.contains(where: { $0.height == q }) { selectedQuality = nil }
            applyQuality()
        }
        if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
            audioGroup = group
            audioOptions = group.options
            let labels = audioOptions.map(audioName)
            var index: Int?
            if let manual = manualAudioLabel { index = labels.firstIndex(of: manual) }
            if index == nil {
                let multichannel = AVAudioSession.sharedInstance().maximumOutputNumberOfChannels >= 6
                index = pickAudio(labels, dub: dub, multichannel: multichannel)
            }
            if let i = index, let item = player.currentItem {
                item.select(audioOptions[i], in: group)
                setAudioDubbed(labels[i].contains("dubbed"))
            }
        }
        rebuildMenus()
    }

    private func audioName(_ o: AVMediaSelectionOption) -> String {
        let name = o.displayName
        if name.contains("original") || name.contains("dubbed") || name.contains("6CH") { return name }
        // Some playlists name renditions by language only.
        if let tag = o.extendedLanguageTag, tag.hasPrefix("fa") { return "dubbed-fa" }
        return name
    }

    private func pickAudio(_ labels: [String], dub: Bool, multichannel: Bool) -> Int? {
        guard !labels.isEmpty else { return nil }
        let i: Int?
        if dub { i = labels.firstIndex { $0.contains("dubbed") } }
        else if multichannel { i = labels.firstIndex { $0.contains("6CH") && $0.contains("original") } }
        else { i = labels.firstIndex { $0.contains("original") && !$0.contains("6CH") } }
        return i ?? 0
    }

    /// The user picked another audio track in the native Audio menu.
    private func audioSelectionChanged() {
        guard let group = audioGroup, let item = player.currentItem,
              let o = item.currentMediaSelection.selectedMediaOption(in: group) else { return }
        let label = audioName(o)
        manualAudioLabel = label
        let dubbed = label.contains("dubbed")
        if dubbed != audioDubbed {
            setAudioDubbed(dubbed)
            app.titlePrefs.setDubSelected(ref.postId, dubbed)
        }
    }

    private func setAudioDubbed(_ dubbed: Bool) {
        let was = audioDubbed
        audioDubbed = dubbed
        guard was != dubbed, resolvedFor == streamId else { return }
        setChoice(dubbed ? (available.contains(.faDub) ? .faDub : .off) : originalChoice(), persist: false)
    }

    private func applyQuality() {
        guard let item = player.currentItem else { return }
        if let h = selectedQuality, let q = qualities.first(where: { $0.height == h }) {
            item.preferredMaximumResolution = CGSize(width: 8192, height: CGFloat(h))
            item.preferredPeakBitRate = (q.peakBitRate ?? 0) * 1.05
        } else {
            item.preferredMaximumResolution = .zero
            item.preferredPeakBitRate = 0
        }
    }

    // MARK: Ticks

    private var positionMs: Int64 {
        if let seekTarget { return seekTarget }
        let t = player.currentTime().seconds
        return t.isFinite ? Int64(t * 1000) : 0
    }

    private var durationMs: Int64 {
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { knownDuration = Int64(d * 1000) }
        return knownDuration
    }

    private func tick() {
        updateCues()
        guard everReady, player.timeControlStatus == .playing else { return }
        boostClock += 0.1
        if boostClock >= 0.25 { boostClock = 0; boostTick() }
        if upNextTick() { return }
        playedSinceSave += 0.1
        if playedSinceSave >= 10 { save() }
    }

    private func boostTick() {
        guard let schedule, !schedule.isEmpty else { player.volume = 1; return }
        guard boost else { player.volume = 1; return }
        let g = smoother.step(schedule.target(at: Double(positionMs) / 1000))
        // AVPlayer cannot amplify: quiet scenes play at full volume and loud ones are brought down to match.
        player.volume = Float(min(1, max(0.05, g / schedule.peak)))
    }

    /// The up-next card near the end; counts down in playing time, then plays the next episode.
    private func upNextTick() -> Bool {
        guard episode != nil, let next = PlaybackRules.nextEpisode(seasons, after: streamId) else { return false }
        guard PlaybackRules.upNextDue(positionMs, durationMs) else {
            if upNextReached || !vc.contextualActions.isEmpty { upNextReached = false; upNextShown = 0; vc.contextualActions = [] }
            return false
        }
        upNextReached = true
        if upNextDismissed { return false }
        upNextShown += 0.1
        let left = PlaybackRules.upNextCountdownS - Int(upNextShown)
        if left <= 0 {
            playNext()
            return true
        }
        let title = "\(UiStrings.upNextLabel(next.season, next.number)) (\(String(left).persianDigits))"
        if vc.contextualActions.first?.title != title {
            vc.contextualActions = [
                UIAction(title: title, image: UIImage(systemName: "forward.end.fill")) { [weak self] _ in self?.playNext() },
                UIAction(title: "تماشای تیتراژ", image: UIImage(systemName: "text.alignleft")) { [weak self] _ in
                    self?.upNextDismissed = true
                    self?.vc.contextualActions = []
                },
            ]
        }
        return false
    }

    private func save() {
        guard let ep = episode, everReady else { return }
        playedSinceSave = 0
        let pos = positionMs, dur = durationMs
        guard dur > 0 else { return }
        app.watch.put(WatchEntry(streamId: streamId, refPath: ref.path, season: ep.season, episode: ep.number,
                                 positionMs: pos, durationMs: dur,
                                 finished: PlaybackRules.isFinished(pos, dur) || upNextReached,
                                 subtitleOffsetMs: offsetMs))
    }

    private func ended() {
        if switching { return }
        upNextReached = true
        save()
        if everReady, PlaybackRules.nextEpisode(seasons, after: streamId) != nil { playNext() } else { dismiss() }
    }

    // MARK: Errors

    private func failed(_ error: Error?) {
        guard !closed else { return }
        if let item = player.currentItem {
            if item === failedItem { return }
            failedItem = item
        }
        report(error)
        // An expired stream key or a dropped CDN connection: open the stream page again where we were.
        if stream != nil, reopenAllowed() {
            open(streamId, startAt: everReady ? positionMs : nil, silent: true, play: player.rate > 0 || !everReady)
        } else {
            openTask?.cancel()
            let ns = error as NSError?
            fail(ns?.domain == NSURLErrorDomain ? UiStrings.playFailedNetwork : UiStrings.playbackFailed)
        }
    }

    private func reopenAllowed() -> Bool {
        let now = Date()
        var allowed = false
        if lastReopen == nil || now.timeIntervalSince(lastReopen!) >= 60 {
            quickReopens = 0
            allowed = true
        } else if reopenReady && quickReopens < 3 {
            quickReopens += 1
            allowed = true
        }
        if allowed { lastReopen = now; reopenReady = false }
        return allowed
    }

    private func report(_ error: Error?) {
        if let last = lastReport, Date().timeIntervalSince(last) < 60 { return }
        lastReport = Date()
        let event = readySinceLoad ? "error" : "setupError"
        let code = (error as NSError?).map { String($0.code) } ?? "unknown"
        let id = streamId
        Task { await app.site.reportStreamError(streamId: id, event: event, msg: code) }
    }

    private func fail(_ message: String) {
        switching = false
        guard !closed else { return }
        let alert = UIAlertController(title: message, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "تلاش دوباره", style: .default) { [weak self] _ in
            guard let self else { return }
            self.lastReopen = nil
            self.open(self.streamId, startAt: self.everReady ? self.positionMs : nil)
        })
        alert.addAction(UIAlertAction(title: "بستن", style: .cancel) { [weak self] _ in self?.dismiss() })
        (vc.presentedViewController == nil ? vc : vc.presentedViewController)?.present(alert, animated: true)
    }

    // MARK: Subtitles

    private func availableChoices(_ s: StreamSession) -> [SubtitleChoice] {
        let kinds = Set(s.subtitles.map(\.kind))
        var out: [SubtitleChoice] = []
        if kinds.contains(.fa) { out.append(.fa) }
        if kinds.contains(.en) { out.append(.en) }
        if kinds.contains(.fa) && kinds.contains(.en) { out.append(.dual) }
        if kinds.contains(.faDub) { out.append(.faDub) }
        out.append(.off)
        return out
    }

    private func originalChoice() -> SubtitleChoice {
        [globalChoice, .fa, .en].first { available.contains($0) } ?? .off
    }

    private func setChoice(_ c: SubtitleChoice, persist: Bool) {
        choice = c
        if persist && c != .faDub {
            globalChoice = c
            app.playerPrefs.update { $0.subtitle = c }
        }
        ensureSubtitles()
        updateCues()
        rebuildMenus()
    }

    /// Downloads the files the choice needs, once per stream; one automatic retry after 5 s.
    private func ensureSubtitles(retry: Bool = true) {
        guard let s = stream else { return }
        let id = streamId
        for kind in subtitleKinds(choice) where !requested.contains(kind) {
            guard let url = s.subtitles.first(where: { $0.kind == kind })?.url else { continue }
            requested.insert(kind)
            Task { [weak self] in
                guard let self else { return }
                do {
                    let body = try await self.app.site.subtitle(url)
                    let timeline = await Task.detached { SubtitleTimeline(SrtParser.parse(body)) }.value
                    guard id == self.streamId else { return }
                    self.timelines[kind] = timeline
                    self.updateCues()
                } catch {
                    guard id == self.streamId else { return }
                    self.requested.remove(kind)
                    if retry {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        if id == self.streamId { self.ensureSubtitles(retry: false) }
                    }
                }
            }
        }
    }

    private func updateCues() {
        let pos = positionMs - offsetMs
        func text(_ k: SubtitleKind) -> String? {
            let t = timelines[k]?.at(pos).map(\.text).joined(separator: "\n")
            return t?.isEmpty == false ? t : nil
        }
        var p: String?, s: String?
        switch choice {
        case .fa: p = text(.fa)
        case .en: p = text(.en)
        case .dual: p = text(.fa); s = text(.en)
        case .faDub: p = text(.faDub)
        case .off: break
        }
        if overlay.primary != p { overlay.primary = p }
        if overlay.secondary != s { overlay.secondary = s }
    }

    private func shift(_ delta: Int64) {
        offsetMs = delta == 0 ? 0 : offsetMs + delta
        updateCues()
        rebuildMenus()
    }

    private func setStyle(_ f: (inout SubtitleStyle) -> Void) {
        var st = overlay.style
        f(&st)
        overlay.style = st
        app.playerPrefs.update { $0.style = st }
        rebuildMenus()
    }

    // MARK: Episodes

    private func playNext() {
        guard let next = PlaybackRules.nextEpisode(seasons, after: streamId) else { return }
        playEpisode(next.streamId)
    }

    private func playEpisode(_ id: String) {
        guard !closed, !switching, id != streamId else { return }
        save()
        player.pause()
        switching = true
        vc.contextualActions = []
        open(id, startAt: nil)
    }

    // MARK: Menus

    private func rebuildMenus() {
        var items: [UIMenuElement] = []
        items.append(subtitleMenu())
        if !qualities.isEmpty { items.append(qualityMenu()) }
        items.append(UIMenu(title: "تقویت صدا", image: UIImage(systemName: "speaker.wave.3"), options: .singleSelection, children: [
            UIAction(title: "روشن", state: boost ? .on : .off) { [weak self] _ in self?.setBoost(true) },
            UIAction(title: "خاموش", state: boost ? .off : .on) { [weak self] _ in self?.setBoost(false) },
        ]))
        if ref.kind == .series, !seasons.isEmpty { items.append(episodesMenu()) }
        if PlaybackRules.nextEpisode(seasons, after: streamId) != nil {
            items.append(UIAction(title: "قسمت بعد", image: UIImage(systemName: "forward.end")) { [weak self] _ in self?.playNext() })
        }
        vc.transportBarCustomMenuItems = items
    }

    private func setBoost(_ on: Bool) {
        boost = on
        smoother = GainSmoother()
        if !on { player.volume = 1 }
        app.playerPrefs.update { $0.audioBoost = on }
        rebuildMenus()
    }

    private func subtitleMenu() -> UIMenu {
        let langs = UIMenu(title: "زبان", options: .displayInline, children: available.map { c in
            UIAction(title: choiceLabel(c), state: c == choice ? .on : .off) { [weak self] _ in self?.setChoice(c, persist: true) }
        })
        let keep: UIMenuElement.Attributes = [.keepsMenuPresented]
        let sync = UIMenu(title: "هماهنگی: \(UiStrings.syncOffset(offsetMs))", children: [
            UIAction(title: "+۰٫۵ ثانیه (دیرتر)", attributes: keep) { [weak self] _ in self?.shift(500) },
            UIAction(title: "−۰٫۵ ثانیه (زودتر)", attributes: keep) { [weak self] _ in self?.shift(-500) },
            UIAction(title: "بازنشانی") { [weak self] _ in self?.shift(0) },
        ])
        let st = overlay.style
        let size = UIMenu(title: "اندازه: \(UiStrings.percent(st.sizePercent))", options: .singleSelection,
                          children: SubtitleStyle.sizes.map { v in
            UIAction(title: UiStrings.percent(v), state: v == st.sizePercent ? .on : .off) { [weak self] _ in self?.setStyle { $0.sizePercent = v } }
        })
        let color = UIMenu(title: "رنگ: \(st.color.label)", options: .singleSelection, children: SubtitleColor.allCases.map { c in
            UIAction(title: c.label, state: c == st.color ? .on : .off) { [weak self] _ in self?.setStyle { $0.color = c } }
        })
        let bg = UIMenu(title: "پس‌زمینه: \(UiStrings.percent(st.backgroundOpacity))", options: .singleSelection,
                        children: SubtitleStyle.opacities.map { v in
            UIAction(title: UiStrings.percent(v), state: v == st.backgroundOpacity ? .on : .off) { [weak self] _ in self?.setStyle { $0.backgroundOpacity = v } }
        })
        return UIMenu(title: "زیرنویس", image: UIImage(systemName: "captions.bubble"),
                      children: [langs, UIMenu(title: "", options: .displayInline, children: [sync, size, color, bg])])
    }

    private func qualityMenu() -> UIMenu {
        let playing = player.currentItem.map { Int($0.presentationSize.height) } ?? 0
        // Named like the options below: a 2:1 film's «1080» variant is 1920×960, and «960p» read as a downgrade.
        let current = qualities.min { abs($0.height - playing) < abs($1.height - playing) }
        let name = current.map { q -> String in
            let n = q.label.components(separatedBy: "[").first?.trimmingCharacters(in: .whitespaces) ?? q.label
            return n.allSatisfy(\.isNumber) ? "\(n)p" : n
        } ?? "\(playing)p"
        let auto = playing > 0 ? "خودکار (\(name))" : "خودکار"
        var children: [UIMenuElement] = [UIAction(title: auto, state: selectedQuality == nil ? .on : .off) { [weak self] _ in
            self?.selectedQuality = nil; self?.applyQuality(); self?.rebuildMenus()
        }]
        children += qualities.map { q in
            UIAction(title: q.label, state: selectedQuality == q.height ? .on : .off) { [weak self] _ in
                self?.selectedQuality = q.height; self?.applyQuality(); self?.rebuildMenus()
            }
        }
        return UIMenu(title: "کیفیت", image: UIImage(systemName: "sparkles.tv"), options: .singleSelection, children: children)
    }

    private func episodesMenu() -> UIMenu {
        let seasonMenus: [UIMenuElement] = seasons.sorted { $0.number < $1.number }.map { s in
            UIMenu(title: "فصل \(s.number)".persianDigits, children: s.episodes.sorted { $0.number < $1.number }.map { e in
                let watched = e.played || app.watch.get(e.streamId)?.finished == true
                let title = "قسمت \(e.number)".persianDigits + (watched ? " ✓" : "")
                return UIAction(title: title, state: e.streamId == streamId ? .on : .off) { [weak self] _ in self?.playEpisode(e.streamId) }
            })
        }
        if seasonMenus.count == 1, let only = seasonMenus.first as? UIMenu {
            return UIMenu(title: "قسمت‌ها", image: UIImage(systemName: "list.bullet"), children: only.children)
        }
        return UIMenu(title: "قسمت‌ها", image: UIImage(systemName: "list.bullet"), children: seasonMenus)
    }
}

extension PlayerSession: AVPlayerViewControllerDelegate {
    nonisolated func playerViewController(_ playerViewController: AVPlayerViewController,
                                          willTransitionToVisibilityOfTransportBar visible: Bool,
                                          with coordinator: AVPlayerViewControllerAnimationCoordinator) {
        MainActor.assumeIsolated {
            withAnimation(.easeInOut(duration: 0.3)) { overlay.chromeVisible = visible }
        }
    }
}
