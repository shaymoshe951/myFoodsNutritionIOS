import Foundation

@MainActor
final class DailyDiaryViewModel: ObservableObject {
    @Published private(set) var items: [DailyItemRecord] = []
    @Published var selectedDate: Date = .now
    @Published var errorMessage: String?

    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    var dateKey: String {
        Self.dateFormatter.string(from: selectedDate)
    }

    func load() {
        do {
            items = try database.itemsForDate(dateKey)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addItem(name: String, quantity: Int, meal: String, time: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try database.insertItem(
                date: dateKey,
                itemName: trimmed,
                quantity: max(1, quantity),
                mealTimeSlot: meal.isEmpty ? DailyDiaryViewModel.defaultMeal(for: Date()) : meal,
                itmTime: time
            )
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateQuantity(localId: Int64, quantity: Int) {
        do {
            try database.updateQuantity(id: localId, quantity: max(1, quantity))
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(localId: Int64) {
        do {
            try database.deleteItem(localId: localId)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Jerusalem")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Mirrors server-side defaults from `addDailyItemDB.php` (Asia/Jerusalem).
    static func defaultMeal(for date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Jerusalem")!
        let comps = cal.dateComponents([.hour, .minute], from: date)
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        switch minutes {
        case 360 ..< 720: return "ארוחת בוקר"
        case 720 ..< 930: return "ארוחת צהריים"
        case 930 ..< 1110: return "ארוחת אחהצ"
        case 1110 ..< 1350: return "ארוחת ערב"
        case 1350 ..< 1440: return "ארוחת לילה"
        default: return "ארוחת לילה"
        }
    }
}
