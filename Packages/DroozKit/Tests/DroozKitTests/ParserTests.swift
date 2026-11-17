import XCTest
@testable import DroozKit

func fixture(_ name: String) -> String {
    let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    return try! String(contentsOf: url, encoding: .utf8)
}

final class ParserTests: XCTestCase {
    func testHome() throws {
        let home = try HomeParser.parse(fixture("home.html"))
        XCTAssertEqual(home.featured.count, 6)
        XCTAssertEqual(home.featured[0].ref.postId, 5740731)
        XCTAssertEqual(home.featured[2].backdropHash, "ac89a599f201a486ad141d4d2defd72f.jpg.webp")
        XCTAssertEqual(home.recentlyStreamed.first?.posterHash, "f2e1a13c82b663225f6fad126480684c.jpg.webp")
        XCTAssertEqual(Array(home.sections.map(\.title).prefix(2)), ["فیلم های برگزیده", "سریال های بروز شده"])
        let series = try XCTUnwrap(home.sections.first { $0.title == "سریال های بروز شده" })
        XCTAssertEqual(series.morePath, "/archive/series/")
        XCTAssertEqual(series.items.first?.ref.kind, .series)
        XCTAssertEqual(series.items.first?.episodeLabel, "قسمت ۱۱ فصل یازدهم")
        XCTAssertEqual(series.items.first?.status, "در حال پخش")
        let featured = try XCTUnwrap(home.sections.first { $0.title == "فیلم های برگزیده" })
        XCTAssertEqual(featured.morePath, "/archive/category/featured-films/")
        XCTAssertEqual(featured.items.first?.posterHash, "8bde473599128f72889fe6670cbebcb2.jpg.webp")
        let c = try XCTUnwrap(home.sections.flatMap(\.items).first { $0.ref.postId == 5744063 })
        XCTAssertEqual(c.title, "Ali G: Who Iz I?")
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.durationMin, 89)
        XCTAssertEqual(c.imdb, Rating(score: 5.8, votes: 1000))
        XCTAssertEqual(c.criticsScore, 38)
        XCTAssertEqual(c.genres, ["کمدی"])
        XCTAssertEqual(c.director, "Sacha Baron Cohen")
        XCTAssertTrue(c.synopsis?.hasPrefix("روزنامه‌نگار هیپ‌هاپ") == true)
    }

    func testHomeTitlesAreNormalized() throws {
        let html = fixture("home.html").replacingOccurrences(of: "فیلم های برگزیده", with: "فیلم\u{200C}هاي برگزیده")
        XCTAssertEqual(try HomeParser.parse(html).sections.first?.title, "فیلم های برگزیده")
    }

    func testHomeNothingRecognisable() {
        XCTAssertThrowsError(try HomeParser.parse("<html><body></body></html>")) {
            XCTAssertEqual($0 as? SiteError, .parse("home"))
        }
    }

    func testList() throws {
        let list = ListParser.parse(fixture("list_new_films.html"))
        XCTAssertEqual(list.items.count, 8)
        XCTAssertEqual(list.items[0].ref.postId, 5744063)
        XCTAssertEqual(list.page, 1)
        XCTAssertEqual(list.lastPage, 478)
        let verity = try XCTUnwrap(list.items.first { $0.ref.postId == 5738721 })
        XCTAssertEqual(verity.title, "Verity")
        XCTAssertEqual(verity.genres, ["جنایی", "درام", "معمایی", "هیجان انگیز"])
        XCTAssertEqual(verity.stars, ["Anne Hathaway", "Dakota Johnson", "Josh Hartnett"])
        XCTAssertEqual(verity.countries, ["آمریکا"])
        XCTAssertEqual(verity.posterHash, "0ad6ee864a9a4e46a99be4f13316e245.jpg.webp")
        let empty = ListParser.parse("<html><body></body></html>")
        XCTAssertEqual(empty.page, 1)
        XCTAssertEqual(empty.lastPage, 1)
    }

    func testCategoryMenu() {
        let cats = CategoryMenuParser.parse(fixture("list_new_films.html"))
        XCTAssertFalse(cats.isEmpty)
        XCTAssertTrue(cats.allSatisfy { $0.path.hasPrefix("/archive/") })
    }

    func testSearch() {
        let r = SearchParser.parse(fixture("search_pluribus.html"))
        XCTAssertEqual(r.map(\.ref.postId), [5735053])
        XCTAssertEqual(r.first?.title, "Pluribus")
        XCTAssertEqual(r.first?.imdb, Rating(score: 7.9, votes: 181000))
        let arabic = fixture("search_pluribus.html").replacingOccurrences(of: "فیلم و سریال", with: "فيلم و سريال")
        XCTAssertEqual(SearchParser.parse(arabic).count, 1)
    }

    func testSeriesTitle() throws {
        let ref = TitleRef(kind: .series, postId: 5735053, slug: "pluribus")
        let d = try TitleParser.parse(fixture("title_series_pluribus.html"), ref: ref)
        XCTAssertEqual(d.catalog.main.count, 1)
        let eps = d.catalog.main[0].episodes
        XCTAssertEqual(eps.map(\.number), Array(1...9))
        XCTAssertTrue(eps.allSatisfy(\.played))
        XCTAssertEqual(eps[0].streamId, "325497")
        XCTAssertEqual(eps[0].videos.map(\.height), [480, 720, 1080])
        XCTAssertEqual(eps[0].audios.map(\.channels), [2, 6])
        XCTAssertEqual(eps[0].subtitles.map(\.lang), ["fa", "en"])
        XCTAssertTrue(d.catalog.dub.isEmpty)
        XCTAssertEqual(d.card.title, "Pluribus")
        XCTAssertEqual(d.card.year, 2025)
        XCTAssertEqual(d.card.imdb, Rating(score: 7.9, votes: 181000))
        XCTAssertEqual(d.channel, "Apple TV+")
        XCTAssertEqual(d.card.genres, ["درام", "علمی-تخیلی"])
        XCTAssertEqual(d.card.episodeLabel, "قسمت ۰۹ فصل اول")
        XCTAssertEqual(d.card.status, "پایان فصل")
        XCTAssertEqual(Array(d.suggestions.prefix(4).map(\.postId)), [20835, 4444536, 5688281, 5733846])
        XCTAssertEqual(d.suggestionPosters[d.suggestions[0]], "933a5416ee8344d0532c9e34ecf5b267.jpg.webp")
        XCTAssertTrue(d.awards.contains { $0.contains("برنده بهترین بازیگر نقش اول زن") })
        XCTAssertEqual(d.card.posterHash, "eac12b446fe94c8ef5485a2291db460a.jpg.webp")
    }

    func testFilmTitle() throws {
        let ref = TitleRef(kind: .film, postId: 5744530, slug: "once-upon-a-time-in-the-middle-east")
        let d = try TitleParser.parse(fixture("title_film_ouatime.html"), ref: ref)
        XCTAssertEqual(d.card.title, "Once Upon a Time in the Middle East")
        XCTAssertEqual(d.card.durationMin, 141)
        XCTAssertEqual(d.card.imdb, Rating(score: 8.3, votes: 2000))
        XCTAssertEqual(d.catalog.main.first?.episodes.first?.streamId, "371517")
        XCTAssertEqual(d.catalog.dub.first?.episodes.first?.streamId, "372848")
        XCTAssertEqual(d.catalog.dub.first?.episodes.first?.audios.first?.lang, "dubbed-fa")
        XCTAssertEqual(d.catalog.main.first?.episodes.first?.played, false)
    }

    func testCatalogObjectFormSorted() throws {
        let c = try TitleParser.parseCatalog(#"{"main":{"10":{"1":{"id":"b"}},"2":{"1":{"id":"a"},"2":{}}}}"#)
        XCTAssertEqual(c.main.map(\.number), [2, 10])
        XCTAssertEqual(c.main[0].episodes.map(\.streamId), ["a"])
    }

    func testStreamPage() throws {
        let html = fixture("stream_film_ouatime.html")
        let s = try StreamPageParser.parse(html, streamId: "371517")
        XCTAssertEqual(s.masterUrl, "https://robin.robert-redford.net/json/m3u8/371517/5744530/USERTOKEN/master.m3u8?key=KEY&expire=1800000000&load")
        XCTAssertEqual(s.subtitles.map(\.label), ["Farsi", "English", "English + Farsi"])
        XCTAssertEqual(s.subtitles.map(\.kind), [.fa, .en, .dual])
        XCTAssertEqual(s.qualityLabels, [2475: "1080 [ 2.48 GB ]", 1100: "720 [ 1.14 GB ]", 488: "480 [ 553 MB ]"])
        XCTAssertEqual(s.gains.count, 841)
        XCTAssertEqual(s.gains[0].0, 10.0078)
        XCTAssertEqual(s.gains[0].1, 7.81)
        XCTAssertEqual(s.minGain, 0.64)
        XCTAssertEqual(s.maxGain, 1.93)
        XCTAssertEqual(s.iframes.count, 3)
        XCTAssertEqual(Array(s.iframes[0].prefix(3)), [0.0, 6.5, 8.208])
        XCTAssertEqual(s.title, "Once Upon a Time in the Middle East")
        XCTAssertEqual(s.backdropPath, "/img/1920-1080/ac89a599f201a486ad141d4d2defd72f.jpg.webp")
        XCTAssertThrowsError(try StreamPageParser.parse("<html></html>", streamId: "1"))
    }

    func testLogin() {
        XCTAssertEqual(LoginParser.parse(fixture("login_form.html")), .form)
        XCTAssertEqual(LoginParser.parse(fixture("login_needs_mobile.html")),
                       .needsMobile(recaptchaPass: "000000000000000000000000000000001800000000", mobileHint: "0912***0000"))
        XCTAssertEqual(LoginParser.parse(fixture("login_wrong.html")), .wrongCredentials)
        XCTAssertEqual(LoginParser.parse(fixture("login_success.html")), .redirecting)
    }

    func testPersianText() {
        XCTAssertEqual(PersianText.digits("۱۲٫۵"), "12.5")
        XCTAssertEqual(PersianText.digits("۱٬۲۳۴"), "1234")
        XCTAssertEqual(PersianText.normalize("فيلم\u{200C}ها  ك"), "فیلم ها ک")
        XCTAssertEqual(PersianText.minutes("مدت: ۸۹ دقیقه"), 89)
        XCTAssertEqual("فصل 2".persianDigits, "فصل ۲")
    }

    func testTitleRef() {
        let r = TitleRef.fromPath("https://robin.robert-redford.net/post/series/5735053/pluribus/")
        XCTAssertEqual(r, TitleRef(kind: .series, postId: 5735053, slug: "pluribus"))
        XCTAssertEqual(r?.path, "/post/series/5735053/pluribus/")
        XCTAssertNil(TitleRef.fromPath("/archive/series/"))
    }
}

final class LogicTests: XCTestCase {
    private func ep(_ s: Int, _ n: Int, played: Bool = false) -> Episode {
        Episode(season: s, number: n, streamId: "\(s)-\(n)", played: played)
    }

    private func entry(_ id: String, pos: Int64, dur: Int64 = 3_000_000, at: Int64, finished: Bool = false) -> WatchEntry {
        WatchEntry(streamId: id, refPath: "/post/series/1/x/", season: 1, episode: 1, positionMs: pos,
                   durationMs: dur, updatedAt: at, finished: finished)
    }

    func testNextUp() {
        let seasons = [Season(number: 1, episodes: [ep(1, 1), ep(1, 2), ep(1, 3)]), Season(number: 2, episodes: [ep(2, 1)])]
        XCTAssertEqual(nextUp(seasons, [:]), .start(ep(1, 1)))
        XCTAssertEqual(nextUp(seasons, ["1-1": entry("1-1", pos: 2_900_000, at: 1)])?.episode, ep(1, 2))
        if case .resume(let e, _) = nextUp(seasons, ["1-2": entry("1-2", pos: 600_000, at: 5)]) {
            XCTAssertEqual(e, ep(1, 2))
        } else { XCTFail() }
        let watchedAll = [Season(number: 1, episodes: [ep(1, 1, played: true), ep(1, 2, played: true)])]
        XCTAssertEqual(nextUp(watchedAll, [:]), .again(ep(1, 1, played: true)))
        // Crosses seasons.
        XCTAssertEqual(nextUp(seasons, ["1-3": entry("1-3", pos: 0, at: 1, finished: true)])?.episode, ep(2, 1))
    }

    func testResume() {
        XCTAssertEqual(PlaybackRules.resumeStart(20_000, 100_000, finished: false), 0)
        XCTAssertEqual(PlaybackRules.resumeStart(60_000, 1_000_000, finished: false), 57_000)
        XCTAssertEqual(PlaybackRules.resumeStart(950_000, 1_000_000, finished: false), 0)
    }

    func testSrt() {
        let cues = SrtParser.parse("1\n00:00:01,000 --> 00:00:02,5\n<i>Hello</i>\nworld\n\n2\n00:00:03,000 --> 00:00:04,000\nBye\n")
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "Hello\nworld")
        XCTAssertEqual(cues[0].endMs, 2500)
        let t = SubtitleTimeline(cues)
        XCTAssertEqual(t.at(1500).map(\.text), ["Hello\nworld"])
        XCTAssertTrue(t.at(2600).isEmpty)
    }

    func testQualityOptions() {
        let o = qualityOptions([VariantInfo(height: 1080, bitrateKbps: 2500), VariantInfo(height: 720, bitrateKbps: 1100)],
                               siteLabels: [2475: "1080 [ 2.48 GB ]", 1100: "720 [ 1.14 GB ]"])
        XCTAssertEqual(o.map(\.label), ["1080 [ 2.48 GB ]", "720 [ 1.14 GB ]"])
    }

    func testRecentSearches() {
        XCTAssertEqual(RecentSearches.with(["Lupin", "Dark"], "  dark "), ["dark", "Lupin"])
    }

    func testContinueOrder() {
        let server = [PosterRef(ref: TitleRef(kind: .series, postId: 1, slug: "a"), posterHash: "h")]
        let local = [WatchEntry(streamId: "s", refPath: "/post/film/2/b/", season: 1, episode: 1, positionMs: 60_000,
                                durationMs: 6_000_000, updatedAt: 10, finished: false)]
        XCTAssertEqual(ContinueWatching.order(server: server, local: local).map(\.0.postId), [1, 2])
        XCTAssertEqual(ContinueWatching.order(server: server, local: local, hidden: [1: 5]).map(\.0.postId), [2])
    }
}
