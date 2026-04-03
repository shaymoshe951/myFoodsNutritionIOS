import SwiftUI

struct DailyDiaryView: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var viewModel: DailyDiaryViewModel
    @State private var newName = ""
    @State private var newQuantity = "1"
    @State private var newMeal = ""
    @State private var newTime = ""
    @State private var isSyncingSheet = false
    @State private var syncAlert: String?

    init(database: AppDatabase) {
        _viewModel = StateObject(wrappedValue: DailyDiaryViewModel(database: database))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DatePicker("תאריך", selection: $viewModel.selectedDate, displayedComponents: .date)
                        .environment(\.locale, Locale(identifier: "he_IL"))
                        .onChange(of: viewModel.selectedDate) { _, _ in
                            viewModel.load()
                        }
                }

                Section("פריט חדש") {
                    TextField("שם מזון", text: $newName)
                        .textFieldStyle(.roundedBorder)
                    TextField("כמות", text: $newQuantity)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                    TextField("סוג ארוחה (ריק = אוטומטי)", text: $newMeal)
                        .textFieldStyle(.roundedBorder)
                    TextField("שעה HH:mm", text: $newTime)
                        .textFieldStyle(.roundedBorder)

                    Button("הוסף") {
                        let qty = Int(newQuantity) ?? 1
                        let time = newTime.isEmpty ? Self.currentTimeHHmm() : newTime
                        viewModel.addItem(name: newName, quantity: qty, meal: newMeal, time: time)
                        newName = ""
                        newQuantity = "1"
                        newMeal = ""
                        newTime = ""
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("פריטים") {
                    if viewModel.items.isEmpty {
                        Text("אין פריטים ליום זה")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.items, id: \.clientUuid) { row in
                            if let id = row.id {
                                DailyItemRow(
                                    row: row,
                                    onQuantityChange: { q in viewModel.updateQuantity(localId: id, quantity: q) },
                                    onDelete: { viewModel.delete(localId: id) }
                                )
                            }
                        }
                    }
                }

                if let err = viewModel.errorMessage {
                    Section {
                        Text(err).foregroundStyle(.red)
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
            .onAppear {
                viewModel.load()
            }
        }
    }

    private static func currentTimeHHmm() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Jerusalem")
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
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
    var onQuantityChange: (Int) -> Void
    var onDelete: () -> Void

    @State private var qtyText: String

    init(row: DailyItemRecord, onQuantityChange: @escaping (Int) -> Void, onDelete: @escaping () -> Void) {
        self.row = row
        self.onQuantityChange = onQuantityChange
        self.onDelete = onDelete
        _qtyText = State(initialValue: String(row.quantity))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.itemName)
                .font(.headline)
            HStack {
                Text(row.mealTimeSlot)
                Spacer()
                Text(row.itmTime)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)

            HStack {
                Text("כמות")
                TextField("", text: $qtyText)
                    .keyboardType(.numberPad)
                    .frame(width: 56)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        commitQty()
                    }
                Button("עדכן") { commitQty() }
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
            }
        }
        .onChange(of: row.quantity) { _, new in
            qtyText = String(new)
        }
    }

    private func commitQty() {
        let q = Int(qtyText) ?? row.quantity
        onQuantityChange(q)
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
