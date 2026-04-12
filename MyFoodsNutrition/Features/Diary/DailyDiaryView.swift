import SwiftUI

struct DailyDiaryView: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var viewModel: DailyDiaryViewModel
    @AppStorage("diaryDisplayMode") private var displayModeRaw: String = DiaryDisplayMode.brief.rawValue
    @State private var queryLine = ""
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
                    TextField("מה אכלתם היום?", text: $queryLine)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .submitLabel(.done)
                        .onChange(of: queryLine) { _, new in
                            viewModel.onFoodQueryChanged(new, api: appModel.apiClient)
                        }
                        .onSubmit {
                            Task { await submitFoodLine() }
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
            .alert("עריכת כמות [גרם]", isPresented: Binding(
                get: { editLocalId != nil },
                set: { if !$0 { editLocalId = nil } }
            )) {
                TextField("גרם", text: $editQtyText)
                    .keyboardType(.numberPad)
                Button("אישור") {
                    if let id = editLocalId, let q = Int(editQtyText), q > 0 {
                        viewModel.updateQuantity(localId: id, quantity: q)
                    }
                    editLocalId = nil
                }
                Button("ביטול", role: .cancel) { editLocalId = nil }
            } message: {
                Text("הזן כמות בגרם")
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
        }
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

    private func submitFoodLine() async {
        do {
            try await viewModel.submitFoodQueryLine(queryLine, api: appModel.apiClient)
            queryLine = ""
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

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
        }
        .accessibilityElement(children: .combine)
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
