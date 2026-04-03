import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var baseURL = ""
    @State private var token = ""
    @State private var savedNotice = false

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
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(AppModel())
    }
}
