import SwiftUI
import DroozKit

/// The system search field (on-screen keyboard and Siri dictation), live results as you type.
struct SearchScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openTitle) private var openTitle
    @State private var query = ""
    @State private var results: [CardUI] = []
    @State private var searching = false
    @State private var error: String?
    @State private var answered: String?
    @State private var recent: [String] = []
    private let columns = Array(repeating: GridItem(.fixed(240), spacing: 48, alignment: .top), count: 6)

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 30) {
                content
            }
            .padding(.horizontal, 90).padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .searchable(text: $query, prompt: "جستجوی فیلم و سریال")
        .searchSuggestions {
            if query.isEmpty {
                ForEach(recent, id: \.self) { q in
                    Text(q).searchCompletion(q)
                }
            }
        }
        .task(id: query) { await search() }
        .onAppear { recent = app.recentSearches.queries }
        .background(Palette.background)
    }

    @ViewBuilder private var content: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.count < 2 {
            VStack(alignment: .leading, spacing: 12) {
                Text("نام فیلم یا سریال را بنویسید یا با میکروفون بگویید").font(.vazir(28, .medium))
                Text("نام انگلیسی بهترین نتیجه را می‌دهد").font(.vazir(24)).foregroundStyle(Palette.secondary)
                if !recent.isEmpty {
                    Text("جستجوهای اخیر").font(.vazir(28, .bold)).padding(.top, 30)
                    HStack(spacing: 16) {
                        ForEach(recent, id: \.self) { r in
                            Button(r) { query = r }.font(.vazir(24))
                        }
                    }
                    Button("پاک کردن") { app.recentSearches.clear(); recent = [] }.font(.vazir(22))
                }
            }
            .padding(.top, 40)
        } else if let error {
            StateMessage(text: error) { answered = nil; Task { await search(immediate: true) } }
                .frame(maxWidth: .infinity).padding(.top, 80)
        } else if searching && results.isEmpty {
            Spinner().frame(maxWidth: .infinity).padding(.top, 120)
        } else if results.isEmpty && answered != nil {
            VStack(spacing: 12) {
                Text("نتیجه‌ای پیدا نشد").font(.vazir(30, .medium))
                if !q.isLatinTitle { Text("نام انگلیسی فیلم یا سریال را امتحان کنید").font(.vazir(24)).foregroundStyle(Palette.secondary) }
            }
            .frame(maxWidth: .infinity).padding(.top, 80)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 50) {
                ForEach(results) { card in
                    PosterCard(card: card) {
                        app.recentSearches.add(q)
                        recent = app.recentSearches.queries
                        openTitle(card.ref)
                    }
                }
            }
        }
    }

    private func search(immediate: Bool = false) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { results = []; error = nil; answered = nil; return }
        if q == answered { return }
        if !immediate {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
        }
        searching = true
        error = nil
        defer { searching = false }
        do {
            let cards = try await app.site.search(q)
            if Task.isCancelled { return }
            results = cards.map { c in
                CardUI(ref: c.ref, title: c.title, imageURL: c.posterHash.flatMap { ImageUrls.poster($0, 360, 540) },
                       subtitle: c.year.map { String($0).persianDigits }, landscape: false)
            }
            answered = q
        } catch {
            if Task.isCancelled || error.isCancellation { return }
            self.error = "جستجو انجام نشد"
        }
    }
}
