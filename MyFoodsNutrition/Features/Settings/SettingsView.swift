import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var baseURL = ""
    @State private var token = ""
    @State private var savedNotice = false
    @State private var isReplayingSync = false
    @State private var replaySyncError: String?

    var body: some View {
        Form {
            Section {
                TextField("כתובת בסיס API (ללא סלאש בסוף)", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("אסימון (Bearer)", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("שמור בהגדרות המכשיר") {
                    var c = APIConfig(baseURL: baseURL, token: token)
                    c.saveToUserDefaults()
                    appModel.reloadAPIConfig()
                    savedNotice = true
                }
            } header: {
                Text("API")
            } footer: {
                Text("ניתן גם להוסיף Secrets.plist ליעד (העתק מ-Secrets.example.plist). ערכי UserDefaults גוברים על הקובץ.")
            }

            Section("מצב") {
                HStack {
                    Text("מוגדר")
                    Spacer()
                    Text(appModel.apiClient.config.isConfigured ? "כן" : "לא")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    Task {
                        isReplayingSync = true
                        replaySyncError = nil
                        defer { isReplayingSync = false }
                        do {
                            try await appModel.resyncFromFirstChangeLog()
                        } catch {
                            replaySyncError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        }
                    }
                } label: {
                    if isReplayingSync {
                        HStack {
                            ProgressView()
                            Text("מייבא מחדש מהשרת…")
                        }
                    } else {
                        Text("ייבא מחדש הכל מהשרת (סנכרון מלא)")
                    }
                }
                .disabled(!appModel.apiClient.config.isConfigured || isReplayingSync)
            } header: {
                Text("יומן")
            } footer: {
                Text("משמש אם פריטים מהעבר לא מופיעים: מאפס את סמן הסנכרון ומושך שוב את כל השורות מ־sync_change_log (בטוח: מתמזג לפי מזהה שרת).")
            }
        }
        .navigationTitle("הגדרות")
        .onAppear {
            let c = APIConfig.load()
            baseURL = c.baseURL
            token = c.token
        }
        .alert("נשמר", isPresented: $savedNotice) {
            Button("אישור", role: .cancel) {}
        } message: {
            Text("ההגדרות נשמרו. סנכרון הבא ישתמש בהן.")
        }
        .alert("ייבוא מחדש", isPresented: Binding(
            get: { replaySyncError != nil },
            set: { if !$0 { replaySyncError = nil } }
        )) {
            Button("אישור", role: .cancel) { replaySyncError = nil }
        } message: {
            Text(replaySyncError ?? "")
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(AppModel())
    }
}
