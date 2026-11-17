import SwiftUI
import DroozKit

struct SettingsScreen: View {
    @Environment(AppModel.self) private var app
    @State private var settings = PlayerSettings()
    @State private var defaultDub = false
    @State private var username: String?
    @State private var cleared = false
    @State private var confirmLogout = false

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            List {
                Section(header: header("زیرنویس")) {
                    Picker(selection: binding(\.subtitle)) {
                        Text("فارسی").tag(SubtitleChoice.fa)
                        Text("English").tag(SubtitleChoice.en)
                        Text("فارسی + English").tag(SubtitleChoice.dual)
                        Text("خاموش").tag(SubtitleChoice.off)
                    } label: { Text("زبان") }
                    Picker(selection: binding(\.style.sizePercent)) {
                        ForEach(SubtitleStyle.sizes, id: \.self) { Text(UiStrings.percent($0)).tag($0) }
                    } label: { Text("اندازه") }
                    Picker(selection: binding(\.style.color)) {
                        ForEach(SubtitleColor.allCases, id: \.self) { Text($0.label).tag($0) }
                    } label: { Text("رنگ") }
                    Picker(selection: binding(\.style.backgroundOpacity)) {
                        ForEach(SubtitleStyle.opacities, id: \.self) { Text(UiStrings.percent($0)).tag($0) }
                    } label: { Text("پس‌زمینه") }
                }
                Section(header: header("صدا")) {
                    Toggle("زبان پیش‌فرض: دوبله فارسی (در صورت وجود)", isOn: $defaultDub)
                        .onChange(of: defaultDub) { _, v in app.titlePrefs.defaultDub = v }
                    Toggle("تقویت صدا (یکسان‌سازی بلندی صدا)", isOn: binding(\.audioBoost))
                }
                Section(header: header("حافظه")) {
                    Button(cleared ? "پاک شد" : "پاک کردن حافظه موقت") {
                        Task { await app.clearCaches(); cleared = true }
                    }
                }
                Section(header: header("حساب کاربری")) {
                    if let username { Text(username).environment(\.layoutDirection, .leftToRight) }
                    Button("خروج از حساب", role: .destructive) { confirmLogout = true }
                }
                Section(header: header("درباره")) {
                    Text("نسخه \(version)".persianDigits).foregroundStyle(Palette.secondary)
                }
            }
            .frame(width: 1000)

            SubtitlePreview(style: settings.style)
                .frame(width: 720, height: 405)
                .padding(.top, 40)
        }
        .font(.vazir(28, .medium))
        .padding(.horizontal, 60)
        .onAppear {
            settings = app.playerPrefs.settings
            defaultDub = app.titlePrefs.defaultDub
            username = app.auth.username()
        }
        .confirmationDialog("از حساب خارج می‌شوید؟", isPresented: $confirmLogout) {
            Button("خروج", role: .destructive) { Task { await app.logout() } }
            Button("انصراف", role: .cancel) {}
        }
    }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private func header(_ t: String) -> some View { Text(t).font(.vazir(26, .bold)) }

    private func binding<T>(_ kp: WritableKeyPath<PlayerSettings, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: kp] }, set: { v in
            settings[keyPath: kp] = v
            app.playerPrefs.update { $0[keyPath: kp] = v }
        })
    }
}

/// Subtitle look on a sample frame.
struct SubtitlePreview: View {
    let style: SubtitleStyle
    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(white: 0.25), Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 6) {
                SubtitleLine(text: "این یک زیرنویس نمونه است", style: style, scale: 0.6)
                SubtitleLine(text: "This is a sample subtitle", style: style, scale: 0.6)
            }
            .padding(.bottom, 30)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
