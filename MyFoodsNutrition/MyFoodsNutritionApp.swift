import SwiftUI

@main
struct MyFoodsNutritionApp: App {
    @StateObject private var appModel = AppModel()

    init() {
        FoodVolumeScanDebugStore.ensureRootDirectoryExists()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "he_IL"))
        }
    }
}
