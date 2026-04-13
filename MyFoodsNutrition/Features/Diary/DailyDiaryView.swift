import SwiftUI

struct DailyDiaryView: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var viewModel: DailyDiaryViewModel
    @AppStorage("diaryDisplayMode") private var displayModeRaw: String = DiaryDisplayMode.brief.rawValue
    @State private var queryLine = ""
    @StateObject private var foodSpeech = FoodSearchSpeechService()
    @State private var isSyncingSheet = false
    @State private var syncAlert: String?
    @State private var submitAlert: String?
    @State private var editLocalId: Int64?
    @State private var editQtyText = ""
    @State private var pendingDelete: PendingDelete?

    private struct PendingDelete: Identifiable {
        var id: Int64 { localId }
        let localId: Int64
        let itemLabel: String
    }

    /// `TextField` must use this binding: `.onChange(of: queryLine)` does not run for every edit after programmatic updates (voice), so live search would stop updating until the field is cleared.
    private var foodSearchQueryBinding: Binding<String> {
        Binding(
            get: { queryLine },
            set: { newValue in
                queryLine = newValue
                viewModel.onFoodQueryChanged(newValue, api: appModel.apiClient)
            }
        )
    }

    init(database: AppDatabase) {
        _viewModel = StateObject(wrappedValue: DailyDiaryViewModel(database: database))
    }

    private var displayMode: DiaryDisplayMode {
        DiaryDisplayMode(rawValue: displayModeRaw) ?? .brief
    }

    private var displayModeBinding: Binding<DiaryDisplayMode> {
        Binding(
            get: { DiaryDisplayMode(rawValue: displayModeRaw) ?? .brief },
            set: { displayModeRaw = $0.rawValue }
        )
    }

    private var visibleRows: [DailyItemRecord] {
        viewModel.displayedItems(mode: displayMode)
    }

    /// Consecutive rows with the same `mealTimeSlot` share one group (order matches `visibleRows`, like `updateDailyNutValues.php` meal headers).
    private var fullModeMealGroups: [(meal: String, items: [DailyItemRecord])] {
        Self.groupConsecutiveMeals(visibleRows)
    }

    private static func mealSectionLabel(for row: DailyItemRecord) -> String {
        let m = row.mealTimeSlot.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? "ללא ארוחה" : m
    }

    private static func groupConsecutiveMeals(_ rows: [DailyItemRecord]) -> [(meal: String, items: [DailyItemRecord])] {
        var groups: [(meal: String, items: [DailyItemRecord])] = []
        for row in rows {
            let label = mealSectionLabel(for: row)
            if var last = groups.last, last.meal == label {
                last.items.append(row)
                groups[groups.count - 1] = last
            } else {
                groups.append((meal: label, items: [row]))
            }
        }
        return groups
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DatePicker("תאריך", selection: $viewModel.selectedDate, displayedComponents: .date)
                        .environment(\.locale, Locale(identifier: "he_IL"))
                        .environment(\.calendar, DailyDiaryViewModel.diaryCalendar)
                        .onChange(of: viewModel.selectedDate) { _, _ in
                            viewModel.load()
                        }
                    Picker("תצוגה", selection: displayModeBinding) {
                        ForEach(DiaryDisplayMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    if !appModel.apiClient.config.isConfigured {
                        Text(
                            viewModel.hasLocalFoodCatalog
                                ? "מאגר המזונים המלא נשמר במכשיר — סיכום יום מחושב מקומית. הגדר API כדי לסנכרן יומן עם השרת."
                                : "הגדר API בהגדרות כדי להוריד את מאגר המזונים ולסנכרן, ולהציג סיכום מלא (או סיכום קלוריות מקומי לפריטים שנוספו מהאפליקציה)."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                    } else if viewModel.nutritionSummaryLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("טוען סיכום תזונה…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let s = viewModel.nutritionSummary {
                        dailyNutritionSummaryContent(s)
                    } else if let cal = viewModel.estimatedLocalCalories {
                        localCaloriesOnlyContent(cal)
                    } else if viewModel.nutritionSummaryFailed {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("לא ניתן לחשב סיכום מהנתונים המקומיים ליום זה.")
                            Text("ודא שמאגר המזונים מכיל את שמות הפריטים, או הוסף פריטים מחיפוש עם קלוריות ל־100 גרם.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                    } else {
                        Text("אין סיכום זמין ליום זה.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } header: {
                    Text("סיכום יום")
                } footer: {
                    nutritionSummaryFooter
                }

                Section {
                    HStack(alignment: .center, spacing: 10) {
                        TextField("מה אכלתם היום?", text: foodSearchQueryBinding)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .submitLabel(.done)
                            .onSubmit {
                                Task { await submitFoodLine() }
                            }

                        Group {
                            switch foodSpeech.phase {
                            case .idle:
                                Button {
                                    toggleFoodVoiceInput()
                                } label: {
                                    Image(systemName: "mic")
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("הזנה בקול")
                            case .listening:
                                Button {
                                    foodSpeech.cancelSession()
                                } label: {
                                    Image(systemName: "mic.fill")
                                        .font(.body)
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("עצור הקלטה")
                            case .transcribingRemote:
                                ProgressView()
                                    .accessibilityLabel("מתמלל בשרת…")
                            }
                        }
                        .frame(width: 36, height: 36)
                    }

                    if !viewModel.searchSuggestions.isEmpty {
                        ForEach(viewModel.searchSuggestions) { item in
                            Button {
                                let g = Int(viewModel.searchPreviewGrams.rounded(.towardZero))
                                queryLine = "\(item.itemName) \(g)"
                                viewModel.onFoodQueryChanged(queryLine, api: appModel.apiClient)
                            } label: {
                                suggestionLabel(item)
                            }
                        }
                    }

                    Button("הוסף (כמו Enter באתר)") {
                        Task { await submitFoodLine() }
                    }
                    .disabled(queryLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("חיפוש והוספה")
                } footer: {
                    Text("שורה אחת: שם מזון + מספר גרם (למשל «חלב 200»). ארוחה נקבעת אוטומטית לפי שעת ההוספה, כמו בשרת.")
                }

                if viewModel.items.isEmpty {
                    Section("פריטים") {
                        Text("אין פריטים ליום זה")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                    }
                } else if visibleRows.isEmpty {
                    Section("פריטים") {
                        Text(emptyBriefHint)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                    }
                } else if displayMode == .brief {
                    Section("פריטים") {
                        ForEach(visibleRows, id: \.clientUuid) { row in
                            if let id = row.id {
                                DailyItemRow(
                                    row: row,
                                    onEdit: {
                                        editLocalId = id
                                        editQtyText = String(row.quantity)
                                    },
                                    onDelete: {
                                        pendingDelete = PendingDelete(
                                            localId: id,
                                            itemLabel: "\(row.itemName) \(row.quantity) גרם"
                                        )
                                    }
                                )
                            }
                        }
                    }
                } else {
                    ForEach(Array(fullModeMealGroups.enumerated()), id: \.offset) { _, group in
                        Section {
                            ForEach(group.items, id: \.clientUuid) { row in
                                if let id = row.id {
                                    DailyItemRow(
                                        row: row,
                                        onEdit: {
                                            editLocalId = id
                                            editQtyText = String(row.quantity)
                                        },
                                        onDelete: {
                                            pendingDelete = PendingDelete(
                                                localId: id,
                                                itemLabel: "\(row.itemName) \(row.quantity) גרם"
                                            )
                                        }
                                    )
                                }
                            }
                        } header: {
                            Text(group.meal)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                                .textCase(nil)
                        }
                    }
                }

                if let summary = viewModel.nutritionSummary,
                   let rows = summary.nutrition_rows,
                   !rows.isEmpty,
                   !summary.totals.isEmpty
                {
                    Section {
                        nutritionRowsTable(rows)
                    } header: {
                        Text("ערכים תזונתיים")
                    }
                }

                if let err = viewModel.errorMessage {
                    Section {
                        Text(err)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .navigationTitle("יומן יומי")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Menu {
                        Button("סנכרון עכשיו") {
                            Task {
                                isSyncingSheet = true
                                defer { isSyncingSheet = false }
                                do {
                                    try await appModel.syncEngine.syncNow()
                                    viewModel.load()
                                } catch {
                                    syncAlert = error.localizedDescription
                                }
                            }
                        }
                        if let last = appModel.syncEngine.lastSyncedAt {
                            Text("סנכרון אחרון: \(Self.formatTime(last))")
                        }
                        if let e = appModel.syncEngine.lastError {
                            Text(e)
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
            }
            .overlay {
                if isSyncingSheet {
                    ProgressView("מסנכרן…")
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert("סנכרון", isPresented: Binding(
                get: { syncAlert != nil },
                set: { if !$0 { syncAlert = nil } }
            )) {
                Button("אישור", role: .cancel) { syncAlert = nil }
            } message: {
                Text(syncAlert ?? "")
            }
            .alert("הוספה", isPresented: Binding(
                get: { submitAlert != nil },
                set: { if !$0 { submitAlert = nil } }
            )) {
                Button("אישור", role: .cancel) { submitAlert = nil }
            } message: {
                Text(submitAlert ?? "")
            }
            .alert("עריכת כמות", isPresented: Binding(
                get: { editLocalId != nil },
                set: { if !$0 { editLocalId = nil } }
            )) {
                TextField("כמות בגרם", text: $editQtyText)
                    .keyboardType(.numberPad)
                Button("שמור") {
                    if let id = editLocalId, let q = Int(editQtyText), q > 0 {
                        viewModel.updateQuantity(localId: id, quantity: q)
                    }
                    editLocalId = nil
                }
                Button("ביטול", role: .cancel) { editLocalId = nil }
            } message: {
                Text("הזן כמות חדשה בגרם.")
            }
            .alert("מחיקת פריט", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("ביטול", role: .cancel) { pendingDelete = nil }
                Button("מחק", role: .destructive) {
                    if let id = pendingDelete?.localId {
                        viewModel.delete(localId: id)
                    }
                    pendingDelete = nil
                }
            } message: {
                Text("האם למחוק את «\(pendingDelete?.itemLabel ?? "")»?")
            }
            .onAppear {
                viewModel.load()
            }
            .onChange(of: viewModel.foodSearchAutoSubmitSucceededTick) { _, _ in
                queryLine = ""
                viewModel.onFoodQueryChanged("", api: appModel.apiClient)
            }
            .onChange(of: appModel.syncEngine.lastSyncedAt) { _, _ in
                viewModel.load()
            }
            .onChange(of: appModel.syncEngine.lastFoodCatalogAt) { _, _ in
                viewModel.load()
            }
            .task(id: "\(viewModel.dateKey)-\(viewModel.nutritionRefreshToken)-\(displayModeRaw)") {
                await viewModel.refreshNutritionSummary(displayMode: displayMode)
            }
            .onChange(of: appModel.syncEngine.lastNutritionSnapshotAt) { _, _ in
                viewModel.load()
            }
        }
    }

    /// Same columns as `tableNutValues` on the site (RTL: label, total, % of DRI).
    private func nutritionRowsTable(_ rows: [NutritionTableRow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("סימון תזונתי")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("סה\"כ")
                    .font(.caption.weight(.semibold))
                    .frame(minWidth: 72, alignment: .trailing)
                Text("אחוז מהמומלץ")
                    .font(.caption.weight(.semibold))
                    .frame(width: 88, alignment: .trailing)
            }
            .foregroundStyle(.secondary)
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: 8) {
                    Text(row.label_he)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                    Text(row.amount_text)
                        .font(.caption)
                        .frame(minWidth: 72, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                    Group {
                        if let p = row.percent {
                            Text("\(p)%")
                        } else {
                            Text("לא ידוע")
                        }
                    }
                    .font(.caption)
                    .frame(width: 88, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func dailyNutritionSummaryContent(_ s: DailyNutritionSummaryDTO) -> some View {
        if s.totals.isEmpty {
            Text("אין נתוני תזונה ליום זה.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let order = DailyNutritionSummaryDTO.displayOrder
            if let cal = s.totals["energy"] {
                Text("\(Self.formatNutInt(cal)) קלוריות")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(order.filter { $0 != "energy" }), id: \.self) { key in
                if let v = s.totals[key] {
                    HStack {
                        Text(s.labels_he?[key] ?? key)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(Self.formatNutValue(v, key: key))
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    private static func formatNutInt(_ v: Double) -> String {
        String(Int(v.rounded()))
    }

    private static func formatNutValue(_ v: Double, key: String) -> String {
        switch key {
        case "energy":
            return "\(formatNutInt(v)) קל׳"
        default:
            let x = (v * 10).rounded() / 10
            if x.rounded() == x {
                return "\(Int(x)) גרם"
            }
            return String(format: "%.1f גרם", x)
        }
    }

    @ViewBuilder
    private func localCaloriesOnlyContent(_ cal: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(Int(cal.rounded())) קלוריות (הערכה מקומית)")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("מוצגות רק קלוריות לפי נתון שנשמר בפריט בעת ההוספה מהחיפוש. סנכרן את מאגר המזונים כדי לחשב את כל הרכיבים מהיומן.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
    }

    @ViewBuilder
    private var nutritionSummaryFooter: some View {
        Group {
            if viewModel.nutritionSummary != nil {
                if viewModel.hasNutritionSnapshot {
                    Text("הסיכום מחושב במכשיר מהיומן ומאגר המזונים. יעדי DRI והטבלה המלאה מתעדכנים בסנכרון (מאגר מזונים + מאפייני תזונה).")
                } else {
                    Text("הסיכום מחושב במכשיר. לטבלת אחוזים מהמומלץ בכל הרכיבים, סנכרן כשה־API מוגדר (מוריד גם מאפייני תזונה).")
                }
            } else if viewModel.estimatedLocalCalories != nil {
                Text("הקלוריות המקומיות כוללות רק פריטים שנשמר בהם ערך קלוריות ל־100 גרם בעת ההוספה מהאפליקציה.")
            } else {
                Text(
                    viewModel.hasLocalFoodCatalog
                        ? "סנכרן את היומן כשהרשת זמינה. אם אין התאמות בשמות מול המאגר המקומי, הוסף פריטים מחיפוש או הגדר API."
                        : "לסיכום מלא נדרש מאגר מזונים מקומי: הגדר API וסנכרן (מוריד catalog-items ומאפייני תזונה)."
                )
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var emptyBriefHint: String {
        if displayMode == .brief, DailyDiaryViewModel.diaryCalendar.isDateInToday(viewModel.selectedDate) {
            return "אין פריטים משעתיים האחרונות (תקציר). עבור ל«מלא» כדי לראות את כל היום."
        }
        return "אין פריטים להצגה"
    }

    @ViewBuilder
    private func suggestionLabel(_ item: FoodSearchItemDTO) -> some View {
        let g = viewModel.searchPreviewGrams
        let energy = (item.energy ?? 0) * g / 100.0
        let line = "\(item.itemName) [\(Int(energy.rounded())) קלוריות ל-\(Int(g.rounded(.towardZero))) גרם]"
        Text(line)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
    }

    private func toggleFoodVoiceInput() {
        switch foodSpeech.phase {
        case .listening, .transcribingRemote:
            foodSpeech.cancelSession()
        case .idle:
            foodSpeech.startListening(
                onPartial: { text in
                    queryLine = viewModel.displayQueryFromSpeech(text)
                    viewModel.onFoodQueryChanged(text, api: appModel.apiClient)
                },
                onFinished: { result in
                    switch result {
                    case let .success(text):
                        queryLine = viewModel.displayQueryFromSpeech(text)
                        Task {
                            await viewModel.applyFoodQueryNow(text, api: appModel.apiClient)
                        }
                    case let .failure(err):
                        submitAlert = err.localizedDescription
                    }
                }
            )
        }
    }

    /// - Parameter explicitLine: Use after dictation so submit runs with the finalized string even if `queryLine` has not been committed yet.
    private func submitFoodLine(explicitLine: String? = nil) async {
        let raw = (explicitLine ?? queryLine).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        do {
            try await viewModel.submitFoodQueryLine(raw, api: appModel.apiClient)
            queryLine = ""
            viewModel.onFoodQueryChanged("", api: appModel.apiClient)
        } catch let e as DiaryEntryError {
            submitAlert = e.localizedDescription
        } catch {
            submitAlert = error.localizedDescription
        }
    }

    private static func formatTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: d)
    }
}

private struct DailyItemRow: View {
    let row: DailyItemRecord
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onEdit) {
                Text("\(row.itemName) \(row.quantity) גרם")
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("עריכת כמות: \(row.itemName)")

            Button(action: onEdit) {
                Image(systemName: "square.and.pencil")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("עריכת כמות בגרם")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .accessibilityLabel("מחיקה")
        }
    }
}

#Preview {
    struct PreviewHost: View {
        @StateObject private var appModel = AppModel()
        var body: some View {
            DailyDiaryView(database: appModel.database)
                .environmentObject(appModel)
        }
    }
    return PreviewHost()
}
