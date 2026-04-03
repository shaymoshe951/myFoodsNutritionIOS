import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        TabView {
            DailyDiaryView(database: appModel.database)
                .environmentObject(appModel)
                .tabItem {
                    Label("יומן", systemImage: "list.bullet.rectangle")
                }

            NavigationStack {
                SettingsView()
                    .environmentObject(appModel)
            }
            .tabItem {
                Label("הגדרות", systemImage: "gearshape")
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppModel())
}
