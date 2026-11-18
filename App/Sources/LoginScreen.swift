import SwiftUI
import DroozKit

/// First run only: username, password, then the mobile number when the site asks for it.
struct LoginScreen: View {
    @Environment(AppModel.self) private var app
    @State private var username = ""
    @State private var password = ""
    @State private var mobile = ""
    @State private var mobileHint: String?
    @State private var error: String?
    @State private var busy = false
    @FocusState private var mobileFocused: Bool

    var body: some View {
        HStack(spacing: 120) {
            VStack(alignment: .leading, spacing: 28) {
                Text("ورود به حساب کاربری").font(.vazir(52, .extraBold))
                Text("با نام کاربری و رمز دی‌ال‌روز خودتان وارد شوید").font(.vazir(26)).foregroundStyle(Palette.secondary)

                TextField("نام کاربری یا ایمیل", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .environment(\.layoutDirection, .leftToRight)
                SecureField("رمز عبور", text: $password)
                    .textContentType(.password)
                    .environment(\.layoutDirection, .leftToRight)
                if let hint = mobileHint {
                    Text("لطفا شماره موبایل خود را کامل کنید").font(.vazir(26, .medium))
                    TextField(hint.isEmpty ? "شماره موبایل" : hint, text: $mobile)
                        .keyboardType(.numberPad)
                        .environment(\.layoutDirection, .leftToRight)
                        .focused($mobileFocused)
                }
                if let error {
                    Text(error).font(.vazir(26, .medium)).foregroundStyle(Palette.accent)
                }
                Button {
                    submit()
                } label: {
                    HStack(spacing: 16) {
                        if busy { ProgressView() }
                        Text("ورود").font(.vazir(30, .bold))
                    }
                    .frame(minWidth: 300)
                }
                .disabled(busy || username.isEmpty || password.isEmpty || (mobileHint != nil && mobile.isEmpty))
            }
            .frame(width: 760)

            Image("LogoMark", bundle: nil)
                .resizable().scaledToFit().frame(width: 520)
                .opacity(0.95)
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background.ignoresSafeArea())
    }

    private func submit() {
        busy = true
        error = nil
        let u = username.trimmingCharacters(in: .whitespaces)
        let m = mobileHint == nil ? nil : PersianText.digits(mobile).trimmingCharacters(in: .whitespaces)
        Task {
            let result = await app.auth.login(username: u, password: password, mobile: m)
            busy = false
            switch result {
            case .success:
                app.didLogIn()
            case .needsMobile(let hint):
                mobileHint = hint
                // Focus stayed on the (now disabled) login button; the new field is the next step.
                Task { @MainActor in mobileFocused = true }
            case .wrongCredentials:
                error = "نام کاربری یا رمز عبور اشتباه است"
            case .failed(let message):
                error = message
            }
        }
    }
}
