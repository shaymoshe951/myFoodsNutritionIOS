import Foundation

#if DEBUG
/// Traces «נקה» clear-command detection in Xcode console (filter: `FoodSearchClear`).
private enum FoodSearchClearDebugLog {
    static func unicodeScalarsHex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
    }

    static func log(_ message: String) {
        print("[FoodSearchClear] \(message)")
    }
}
#endif

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
            return "אין מאגר מזון מקומי וה־API לא הוגדר. הגדר כתובת ואסימון בהגדרות וסנכרן (מוריד את מאגר המזונים), או סנכרן אחרי שכבר הוגדר בעבר."
        }
    }
}

/// Aligns with `index.php` / `updateDailyNutValues.php` (`butBrief` / `butFull`). Brief filters to recent items when viewing **today** (here: last 2 hours by `itmTime`; web uses ~90 minutes).
enum DiaryDisplayMode: String, CaseIterable {
    case brief
    case full

    var label: String {
        switch self {
        case .brief: return "תקציר"
        case .full: return "מלא"
        }
    }
}

@MainActor
final class DailyDiaryViewModel: ObservableObject {
    @Published private(set) var items: [DailyItemRecord] = []
    @Published var selectedDate: Date = .now
    @Published var errorMessage: String?

    /// Bumped in `load()` so views can refetch server-backed nutrition when diary rows change.
    @Published private(set) var nutritionRefreshToken: Int = 0
    @Published private(set) var nutritionSummary: DailyNutritionSummaryDTO?
    @Published private(set) var nutritionSummaryLoading = false
    @Published private(set) var nutritionSummaryFailed = false
    /// True after at least one food-catalog sync populated `food_catalog_item`.
    @Published private(set) var hasLocalFoodCatalog = false
    /// True when `nutrition-attributes.php` was synced into SQLite (full DRI table).
    @Published private(set) var hasNutritionSnapshot = false

    /// Items to show for the current date and display mode (תקציר / מלא).
    func displayedItems(mode: DiaryDisplayMode) -> [DailyItemRecord] {
        switch mode {
        case .full:
            return items
        case .brief:
            return Self.filterBrief(items: items, selectedDate: selectedDate)
        }
    }

    /// On days other than «today», brief shows the full list (same as מלא)—there is no «last 2 hours» window.
    private static func filterBrief(items: [DailyItemRecord], selectedDate: Date) -> [DailyItemRecord] {
        guard diaryCalendar.isDateInToday(selectedDate) else { return items }
        let now = Date()
        guard let cutoff = diaryCalendar.date(byAdding: .minute, value: -120, to: now) else { return items }
        return items.filter { row in
            guard let itemInstant = parseItmTimeToDate(row.itmTime, on: selectedDate) else { return true }
            return itemInstant >= cutoff
        }
    }

    /// Combines the diary day with `itmTime` (`HH:mm` or `HH:mm:ss`) for comparisons.
    static func parseItmTimeToDate(_ itmTime: String, on day: Date) -> Date? {
        let trimmed = itmTime.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":").compactMap { Int(String($0)) }
        guard parts.count >= 2 else { return nil }
        var dc = diaryCalendar.dateComponents([.year, .month, .day], from: day)
        dc.hour = parts[0]
        dc.minute = parts[1]
        dc.second = parts.count > 2 ? parts[2] : 0
        return diaryCalendar.date(from: dc)
    }

    @Published private(set) var searchSuggestions: [FoodSearchItemDTO] = []
    /// Grams used for calorie preview in suggestions (100 if no number in query yet), like the site.
    @Published private(set) var searchPreviewGrams: Double = 100
    /// Incremented when «הוסף»/«אוסף» + single unambiguous search causes an automatic add, so the view can clear the text field.
    @Published private(set) var foodSearchAutoSubmitSucceededTick: Int = 0
    /// Incremented when «נקה» is recognized as a clear-only line so the view can empty the field and reset dictation.
    @Published private(set) var foodSearchClearCommandTick: Int = 0

    private let database: AppDatabase
    private var searchDebounceTask: Task<Void, Never>?

    init(database: AppDatabase) {
        self.database = database
    }

    var dateKey: String {
        Self.dateFormatter.string(from: selectedDate)
    }

    /// kcal estimated from `_energy` stored on rows added via in-app search (offline-friendly). Omits synced/legacy rows without `energy_per_100`.
    var estimatedLocalCalories: Double? {
        Self.sumLocalCalories(from: items)
    }

    private static func sumLocalCalories(from items: [DailyItemRecord]) -> Double? {
        var sum = 0.0
        var any = false
        for row in items {
            guard let e = row.energyPer100 else { continue }
            any = true
            sum += e * Double(row.quantity) / 100.0
        }
        return any ? sum : nil
    }

    func load() {
        do {
            items = try database.itemsForDate(dateKey)
            hasLocalFoodCatalog = ((try? database.foodCatalogItemCount()) ?? 0) > 0
            hasNutritionSnapshot = (try? database.nutritionSnapshot()) != nil
            errorMessage = nil
            nutritionRefreshToken += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Computes totals and the nutrition table from SQLite (`food_catalog_item` + optional DRI snapshot). Same תקציר/מלא rules as the website.
    func refreshNutritionSummary(displayMode: DiaryDisplayMode) async {
        nutritionSummaryLoading = true
        nutritionSummaryFailed = false
        defer { nutritionSummaryLoading = false }

        let dayRows = (try? database.itemsForDate(dateKey)) ?? []
        if dayRows.isEmpty {
            nutritionSummary = DailyNutritionSummaryDTO(date: dateKey, totals: [:])
            return
        }

        do {
            if let local = try database.localNutritionSummary(date: dateKey, displayMode: displayMode) {
                nutritionSummary = local
                nutritionSummaryFailed = false
                return
            }
        } catch {
            nutritionSummary = nil
            nutritionSummaryFailed = true
            return
        }

        nutritionSummary = nil
        nutritionSummaryFailed = estimatedLocalCalories == nil
    }

    /// Debounced live search — same flow as `updateQRSuggestions()` on the site; uses the local catalog when synced.
    func onFoodQueryChanged(_ text: String, api: APIClient) {
        searchDebounceTask?.cancel()
        if Self.fieldTriggersClearCommand(text) {
            #if DEBUG
            FoodSearchClearDebugLog.log("onFoodQueryChanged: clear branch tick -> \(foodSearchClearCommandTick + 1)")
            #endif
            searchSuggestions = []
            searchPreviewGrams = 100
            foodSearchClearCommandTick += 1
            return
        }
        let trimmed = Self.normalizedSearchInput(text)
        if trimmed.isEmpty {
            searchSuggestions = []
            return
        }
        let canSearchLocal = ((try? database.foodCatalogItemCount()) ?? 0) > 0
        if !canSearchLocal, !api.config.isConfigured {
            searchSuggestions = []
            return
        }

        let rawFieldText = text
        // Unstructured `Task` does not inherit @MainActor; UI updates must run on the main actor.
        searchDebounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                let r = try await runFoodSearch(trimmed: trimmed, api: api)
                guard !Task.isCancelled else { return }
                applySearchUI(r)
                await maybeAutoSubmitAfterSearch(rawFieldText: rawFieldText, trimmed: trimmed, response: r, api: api)
            } catch {
                guard !Task.isCancelled else { return }
                searchSuggestions = []
            }
        }
    }

    /// Runs catalog/API search immediately for the final query string. Use when voice input finishes so suggestion rows are not lost to debounce cancellation races with the last partial/final callbacks.
    /// - Parameter rawFieldTextForSubmitCue: Original transcript/field text; used to detect «הוסף»/«אוסף» for auto-submit. Defaults to `text` when omitted.
    func applyFoodQueryNow(_ text: String, api: APIClient, rawFieldTextForSubmitCue: String? = nil) async {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        if Self.fieldTriggersClearCommand(text) {
            #if DEBUG
            FoodSearchClearDebugLog.log("applyFoodQueryNow: clear branch tick -> \(foodSearchClearCommandTick + 1)")
            #endif
            searchSuggestions = []
            searchPreviewGrams = 100
            foodSearchClearCommandTick += 1
            return
        }
        let trimmed = Self.normalizedSearchInput(text)
        if trimmed.isEmpty {
            searchSuggestions = []
            return
        }
        let canSearchLocal = ((try? database.foodCatalogItemCount()) ?? 0) > 0
        if !canSearchLocal, !api.config.isConfigured {
            searchSuggestions = []
            return
        }
        let rawCue = rawFieldTextForSubmitCue ?? text
        do {
            let r = try await runFoodSearch(trimmed: trimmed, api: api)
            applySearchUI(r)
            await maybeAutoSubmitAfterSearch(rawFieldText: rawCue, trimmed: trimmed, response: r, api: api)
        } catch {
            searchSuggestions = []
        }
    }

    /// Exposed so the search field can show the same string used for catalog matching after dictation.
    func normalizedQueryText(_ raw: String) -> String {
        Self.normalizedSearchInput(raw)
    }

    /// True when the field is only a «נקה»/«תנקה»/… clear command (same rules as internal clear handling). Used by the view to clear the `TextField` synchronously.
    func isFoodSearchClearOnlyLine(_ raw: String) -> Bool {
        Self.fieldTriggersClearCommand(raw)
    }

    /// Speech text for the field: bidi + digit cleanup only — keeps «הוסף»/«אוסף»/«נקה» visible; search still uses `normalizedSearchInput`.
    func displayQueryFromSpeech(_ raw: String) -> String {
        Self.strippedBidiAndDigits(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips invisible bidi/format characters dictation often inserts; maps Arabic‑Indic digits to ASCII so `FoodSearchQueryParser` digit rules match speech; removes «הוסף»/«אוסף» and «נקה» so they do not affect catalog search.
    private static func normalizedSearchInput(_ text: String) -> String {
        let nfc = text.precomposedStringWithCanonicalMapping
        let trimmed = strippedBidiAndDigits(nfc).trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutSubmit = removingHebrewSubmitCueTokens(trimmed)
        return removingHebrewClearCueTokens(withoutSubmit)
    }

    private static func strippedBidiAndDigits(_ text: String) -> String {
        var s = text
        for u in ["\u{200E}", "\u{200F}", "\u{FEFF}", "\u{200C}", "\u{200D}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"] {
            s = s.replacingOccurrences(of: u, with: "")
        }
        return latinDigitsToASCII(s)
    }

    /// Words that mean “add” in speech (and common misrecognitions); stripped before SQL/API search.
    private static let hebrewSubmitCueTokens = ["הוסף", "אוסף"]
    /// Voice/command phrases for clearing the search line; stripped like submit cues when mixed with a food query.
    /// **Order of removal is longest-first** so e.g. «תנקה» is not destroyed by removing the substring «נקה» first (which would leave stray «ת»).
    private static let hebrewClearCueTokens = ["נקה", "תנקה", "נכה", "לנקות"]

    private static var hebrewClearCueTokensLongestFirst: [String] {
        hebrewClearCueTokens.sorted { $0.count > $1.count }
    }

    private static func removingHebrewSubmitCueTokens(_ s: String) -> String {
        var t = s
        for tok in hebrewSubmitCueTokens {
            while t.contains(tok) {
                t = t.replacingOccurrences(of: tok, with: " ")
            }
        }
        let ws = try! NSRegularExpression(pattern: "\\s+", options: [])
        let ns = t as NSString
        t = ws.stringByReplacingMatches(in: t, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removingHebrewClearCueTokens(_ s: String) -> String {
        var t = s
        for tok in hebrewClearCueTokensLongestFirst {
            while t.contains(tok) {
                t = t.replacingOccurrences(of: tok, with: " ")
            }
        }
        let ws = try! NSRegularExpression(pattern: "\\s+", options: [])
        let ns = t as NSString
        t = ws.stringByReplacingMatches(in: t, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Collapses internal runs of spaces/newlines so typed/dictated «נקה» matches literals even with odd spacing.
    private static func collapseWhitespaceForCueMatch(_ s: String) -> String {
        let ws = try! NSRegularExpression(pattern: "\\s+", options: [])
        let ns = s as NSString
        let t = ws.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the line ends with a clear command as its **own word** (space before it). Clears the whole field — e.g. «שקד נקה» means clear, not «נקה» as substring inside one token («שקדנקה» is ignored).
    private static func hasTrailingWholeWordClearCommand(_ collapsed: String) -> Bool {
        for tok in hebrewClearCueTokensLongestFirst {
            guard collapsed.hasSuffix(tok) else { continue }
            let withoutTok = String(collapsed.dropLast(tok.count))
            if withoutTok.isEmpty { return true }
            guard let last = withoutTok.last else { return true }
            return last.isWhitespace
        }
        return false
    }

    /// True when the field contains a clear cue and nothing else remains for search after stripping cues (typed or dictated).
    private static func fieldTriggersClearCommand(_ raw: String) -> Bool {
        #if DEBUG
        FoodSearchClearDebugLog.log(
            "fieldTriggersClear INPUT count=\(raw.count) reflecting=\(String(reflecting: raw)) scalars=\(FoodSearchClearDebugLog.unicodeScalarsHex(raw))"
        )
        #endif
        let nfc = raw.precomposedStringWithCanonicalMapping
        let rawTrim = strippedBidiAndDigits(nfc).trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
        FoodSearchClearDebugLog.log(
            "fieldTriggersClear after strip+trim count=\(rawTrim.count) reflecting=\(String(reflecting: rawTrim)) scalars=\(FoodSearchClearDebugLog.unicodeScalarsHex(rawTrim))"
        )
        #endif
        guard !rawTrim.isEmpty else {
            #if DEBUG
            FoodSearchClearDebugLog.log("fieldTriggersClear -> false (empty after trim)")
            #endif
            return false
        }

        let collapsed = collapseWhitespaceForCueMatch(rawTrim)
        #if DEBUG
        FoodSearchClearDebugLog.log(
            "fieldTriggersClear collapsed reflecting=\(String(reflecting: collapsed)) scalars=\(FoodSearchClearDebugLog.unicodeScalarsHex(collapsed))"
        )
        #endif
        for tok in hebrewClearCueTokensLongestFirst {
            if collapsed == tok {
                #if DEBUG
                FoodSearchClearDebugLog.log("fieldTriggersClear -> true (exact match token=\(String(reflecting: tok)))")
                #endif
                return true
            }
        }

        if hasTrailingWholeWordClearCommand(collapsed) {
            #if DEBUG
            FoodSearchClearDebugLog.log("fieldTriggersClear -> true (trailing clear word, clear whole field)")
            #endif
            return true
        }

        let hasClearSubstring = hebrewClearCueTokens.contains(where: { collapsed.contains($0) })
        #if DEBUG
        FoodSearchClearDebugLog.log("fieldTriggersClear hasClearSubstring=\(hasClearSubstring)")
        #endif
        guard hasClearSubstring else {
            #if DEBUG
            FoodSearchClearDebugLog.log("fieldTriggersClear -> false (no clear substring)")
            #endif
            return false
        }
        let normalized = normalizedSearchInput(nfc)
        let normEmpty = normalized.isEmpty
        #if DEBUG
        FoodSearchClearDebugLog.log(
            "fieldTriggersClear normalized reflecting=\(String(reflecting: normalized)) scalars=\(FoodSearchClearDebugLog.unicodeScalarsHex(normalized)) isEmpty=\(normEmpty)"
        )
        FoodSearchClearDebugLog.log("fieldTriggersClear -> \(normEmpty) (normalized-empty path)")
        #endif
        return normEmpty
    }

    private static func fieldContainsSubmitCue(_ raw: String) -> Bool {
        let s = strippedBidiAndDigits(raw)
        return hebrewSubmitCueTokens.contains { s.contains($0) }
    }

    private static func responseAllowsAutoSubmitLikeEnter(_ r: FoodSearchResponse) -> Bool {
        guard r.error != "too many numbers!" else { return false }
        guard r.items.count == 1 else { return false }
        guard r.numberInResult == 1, r.requiredQuantity != nil else { return false }
        return true
    }

    /// If the field contained a submit cue and the search is unambiguous (same conditions as Enter), add the row without requiring the button.
    private func maybeAutoSubmitAfterSearch(rawFieldText: String, trimmed: String, response: FoodSearchResponse, api: APIClient) async {
        guard Self.fieldContainsSubmitCue(rawFieldText) else { return }
        guard Self.responseAllowsAutoSubmitLikeEnter(response) else { return }
        do {
            try await submitFoodQueryLine(trimmed, api: api)
            foodSearchAutoSubmitSucceededTick += 1
        } catch {
            // Ambiguous or invalid line: user can fix text or press Enter (we avoid alert spam while typing).
        }
    }

    private static func latinDigitsToASCII(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for ch in text {
            guard let v = ch.unicodeScalars.first?.value else {
                result.append(ch)
                continue
            }
            if (0x0660 ... 0x0669).contains(v), let u = UnicodeScalar(v - 0x0660 + 0x0030) {
                result.append(Character(u))
            } else if (0x06F0 ... 0x06F9).contains(v), let u = UnicodeScalar(v - 0x06F0 + 0x0030) {
                result.append(Character(u))
            } else {
                result.append(ch)
            }
        }
        return result
    }

    private func runFoodSearch(trimmed: String, api: APIClient) async throws -> FoodSearchResponse {
        if ((try? database.foodCatalogItemCount()) ?? 0) > 0 {
            return try database.searchFoodCatalog(query: trimmed)
        }
        guard api.config.isConfigured else { throw DiaryEntryError.searchNotConfigured }
        return try await api.searchFoods(query: trimmed)
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

    /// Same rules as `qrSearchSubmitted()` in `index.php`. Returns whether a diary row was inserted (false for empty input or a «נקה» clear line).
    @discardableResult
    func submitFoodQueryLine(_ raw: String, api: APIClient) async throws -> Bool {
        if Self.fieldTriggersClearCommand(raw) {
            #if DEBUG
            FoodSearchClearDebugLog.log("submitFoodQueryLine: clear command tick -> \(foodSearchClearCommandTick + 1)")
            #endif
            foodSearchClearCommandTick += 1
            return false
        }
        let trimmed = Self.normalizedSearchInput(raw)
        guard !trimmed.isEmpty else { return false }
        if ((try? database.foodCatalogItemCount()) ?? 0) == 0, !api.config.isConfigured {
            throw DiaryEntryError.searchNotConfigured
        }

        let obj = try await runFoodSearch(trimmed: trimmed, api: api)

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

        let picked = obj.items[pick]
        let itemName = picked.itemName
        let time = Self.itmTimeNow()
        addItem(name: itemName, quantity: numDesired, meal: "", time: time, energyPer100: picked.energy)
        searchSuggestions = []
        return true
    }

    func addItem(name: String, quantity: Int, meal: String, time: String, energyPer100: Double? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try database.insertItem(
                date: dateKey,
                itemName: trimmed,
                quantity: max(1, quantity),
                mealTimeSlot: meal.isEmpty ? DailyDiaryViewModel.defaultMeal(for: Date()) : meal,
                itmTime: time,
                energyPer100: energyPer100
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
