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
                    // tvOS 27 draws a picker without its label (inline: a bare segmented row where 15 sizes
                    // don't fit); each row names its setting and opens a menu of values.
                    ChoiceRow(title: "زبان", options: [.fa, .en, .dual, .off], selection: binding(\.subtitle)) {
                        switch $0 {
                        case .fa: "فارسی"
                        case .en: "English"
                        case .dual: "فارسی + English"
                        case .faDub: "فارسی (دوبله)"
                        case .off: "خاموش"
                        }
                    }
                    ChoiceRow(title: "اندازه", options: SubtitleStyle.sizes, selection: binding(\.style.sizePercent)) { UiStrings.percent($0) }
                    ChoiceRow(title: "رنگ", options: SubtitleColor.allCases, selection: binding(\.style.color)) { $0.label }
                    ChoiceRow(title: "پس‌زمینه", options: SubtitleStyle.opacities, selection: binding(\.style.backgroundOpacity)) { UiStrings.percent($0) }
                }
                Section(header: header("صدا")) {
                    SwitchRow(title: "زبان پیش‌فرض: دوبله فارسی (در صورت وجود)", isOn: $defaultDub)
                        .onChange(of: defaultDub) { _, v in app.titlePrefs.defaultDub = v }
                    SwitchRow(title: "تقویت صدا (یکسان‌سازی بلندی صدا)", isOn: binding(\.audioBoost))
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

/// A setting with several values: its name, the current value, and a menu to change it.
private struct ChoiceRow<T: Hashable>: View {
    let title: String
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(label(selection)).foregroundStyle(.secondary)
            }
        }
        .tint(.white) // neutral like the other rows, not the app's red accent
    }
}

/// A switch whose state reads in Persian (a system Toggle says On/Off: tvOS has no Persian strings).
private struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack {
                Text(title)
                Spacer()
                Text(isOn ? "روشن" : "خاموش").foregroundStyle(.secondary)
            }
        }
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
