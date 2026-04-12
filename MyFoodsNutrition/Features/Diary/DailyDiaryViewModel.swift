import Foundation

enum DiaryEntryError: LocalizedError {
    case needsGramAmount
    case pickExactFood
    case noMatch
    case tooManyNumbers
    case searchNotConfigured

    var errorDescription: String? {
        switch self {
        case .needsGramAmount:
            return "ציין כמות בגרם (מספר בשורת החיפוש), כמו באתר."
        case .pickExactFood:
            return "יש כמה התאמות — הקלד את שם המזון המלא כפי שמופיע או בחר מהרשימה."
        case .noMatch:
            return "לא נמצא מזון מתאים."
        case .tooManyNumbers:
            return "יותר ממספר אחד בשורה."
        case .searchNotConfigured:
            return "הגדר כתובת API ואסימון בהגדרות כדי לחפש מאכלים."
        }
    }
}

@MainActor
final class DailyDiaryViewModel: ObservableObject {
    @Published private(set) var items: [DailyItemRecord] = []
    @Published var selectedDate: Date = .now
    @Published var errorMessage: String?

    @Published private(set) var searchSuggestions: [FoodSearchItemDTO] = []
    /// Grams used for calorie preview in suggestions (100 if no number in query yet), like the site.
    @Published private(set) var searchPreviewGrams: Double = 100

    private let database: AppDatabase
    private var searchDebounceTask: Task<Void, Never>?

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

    /// Debounced live search — same flow as `updateQRSuggestions()` on the site.
    func onFoodQueryChanged(_ text: String, api: APIClient) {
        searchDebounceTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            searchSuggestions = []
            return
        }
        guard api.config.isConfigured else {
            searchSuggestions = []
            return
        }

        searchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                let r = try await api.searchFoods(query: text)
                guard !Task.isCancelled else { return }
                applySearchUI(r)
            } catch {
                guard !Task.isCancelled else { return }
                searchSuggestions = []
            }
        }
    }

    private func applySearchUI(_ r: FoodSearchResponse) {
        if r.error == "too many numbers!" {
            searchSuggestions = []
            return
        }
        searchSuggestions = r.items
        if r.numberInResult == 1, let q = r.requiredQuantity {
            searchPreviewGrams = q
        } else {
            searchPreviewGrams = 100
        }
    }

    /// Same rules as `qrSearchSubmitted()` in `index.php`.
    func submitFoodQueryLine(_ raw: String, api: APIClient) async throws {
        guard api.config.isConfigured else { throw DiaryEntryError.searchNotConfigured }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let obj = try await api.searchFoods(query: trimmed)

        if obj.error == "too many numbers!" {
            throw DiaryEntryError.tooManyNumbers
        }
        guard !obj.items.isEmpty else {
            throw DiaryEntryError.noMatch
        }
        guard obj.numberInResult == 1, let qtyDouble = obj.requiredQuantity else {
            throw DiaryEntryError.needsGramAmount
        }

        let numDesired = max(1, Int(qtyDouble.rounded(.towardZero)))
        let queryTxtOnly = (obj.queryTxtOnly ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        var itemIdx = -1
        for (i, cur) in obj.items.enumerated() {
            if cur.itemName.trimmingCharacters(in: .whitespacesAndNewlines) == queryTxtOnly {
                itemIdx = i
                break
            }
        }

        let pick: Int
        if obj.items.count == 1 {
            pick = 0
        } else if itemIdx >= 0 {
            pick = itemIdx
        } else {
            throw DiaryEntryError.pickExactFood
        }

        let itemName = obj.items[pick].itemName
        let time = Self.itmTimeNow()
        addItem(name: itemName, quantity: numDesired, meal: "", time: time)
        searchSuggestions = []
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

    /// Diary dates follow the site (`addDailyItemDB.php`): Gregorian calendar, Asia/Jerusalem.
    /// The DatePicker should use this calendar too, or `dateKey` can shift when the device timezone differs.
    static let diaryCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Jerusalem")!
        return c
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = diaryCalendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func itmTimeNow() -> String {
        let f = DateFormatter()
        f.calendar = diaryCalendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }

    /// Mirrors server-side defaults from `addDailyItemDB.php` (Asia/Jerusalem).
    static func defaultMeal(for date: Date) -> String {
        let comps = diaryCalendar.dateComponents([.hour, .minute], from: date)
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
