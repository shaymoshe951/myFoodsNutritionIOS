import PhotosUI
import SwiftUI
import UIKit

/// Pick a food photo / volume scan, or describe food in text; run AI nutrition analysis; then confirm add to the diary.
struct FoodImageAddSheet: View {
    @Environment(\.dismiss) private var dismiss

    let nutrientKeysForDetail: [String]
    /// Called once per food item to add (multi-item LiDAR/AI may invoke several times via batch confirm).
    var onConfirm: (FoodImageNutritionResult) -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var showCamera = false
    @State private var showLiDAR = false
    @State private var optionalPrompt = ""
    @State private var isAnalyzing = false
    @State private var isRunningOnDeviceVision = false
    @State private var errorText: String?
    @State private var analysisItems: [FoodImageNutritionResult] = []
    @State private var editNames: [String] = []
    @State private var editGrams: [String] = []
    @State private var visionResult: VisionFoodSceneAnalyzer.Result?
    @State private var volumeItems: [FoodVolumeItem] = []
    @State private var tableDetected = false
    @State private var scanQuality: ScanQualityAnalyzer.CaptureQuality?
    /// Debug folder from the latest LiDAR volume capture (Documents/FoodVolumeScans/...).
    @State private var debugScanDirectoryURL: URL?
    /// Height-above-table + mask heatmap from the latest LiDAR capture (debug).
    @State private var heightDebugImage: UIImage?

    private var detailLevel: ImageNutritionDetailLevel {
        ImageNutritionSettings.detailLevel
    }

    private var lidarAvailable: Bool {
        FoodLiDARCaptureModel.isLiDARSupported
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let selectedImage {
                        Image(uiImage: selectedImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Text("בחרו תמונה, צלמו, או תארו את המזון בטקסט.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(spacing: 16) {
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label("גלריה", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(.borderless)

                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button {
                                showCamera = true
                            } label: {
                                Label("מצלמה", systemImage: "camera")
                            }
                            .buttonStyle(.borderless)
                        }

                        if lidarAvailable {
                            Button {
                                showLiDAR = true
                            } label: {
                                Label("נפח", systemImage: "cube.transparent")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text("תמונה")
                } footer: {
                    if lidarAvailable {
                        Text("«נפח»: LiDAR + הפרדת פריטים; צלחת/קערה מסוננות כשאפשר. לכל פריט נשלחים label+volume ל־AI.")
                    }
                }

                Section {
                    TextField(
                        selectedImage == nil ? "למשל: קציצות עוף 70 גרם" : "למשל: חצי מנה, בלי רוטב…",
                        text: $optionalPrompt,
                        axis: .vertical
                    )
                    .lineLimit(2 ... 4)
                    .multilineTextAlignment(.leading)
                } header: {
                    Text(selectedImage == nil ? "תיאור המזון" : "הנחיה ל־AI (אופציונלי)")
                } footer: {
                    if selectedImage == nil {
                        Text("אפשר לנתח מתיאור בלבד, בלי תמונה. רמת פירוט נוכחית: \(detailLevel.labelHe). ניתן לשנות בהגדרות.")
                    } else {
                        Text("רמת פירוט נוכחית: \(detailLevel.labelHe). ניתן לשנות בהגדרות.")
                    }
                }

                Section {
                    if isAnalyzing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(selectedImage == nil ? "מנתח תזונה…" : "מנתח תמונה…")
                                .foregroundStyle(.secondary)
                        }
                    } else if analysisItems.isEmpty {
                        Button(selectedImage == nil ? "נתח תזונה מהטקסט" : "נתח תזונה מהתמונה") {
                            Task { await analyze() }
                        }
                        .disabled(!canAnalyze)
                    } else {
                        Button(analysisItems.count > 1 ? "הוסף הכל ליומן" : "הוסף ליומן") {
                            commitAdd()
                        }
                        .disabled(!canCommit)
                        Button("נתח שוב", role: .destructive) {
                            analysisItems = []
                            Task { await analyze() }
                        }
                        .disabled(!canAnalyze || isAnalyzing)
                    }
                }

                if !ImageNutritionSettings.isConfigured {
                    Section {
                        Text("חסר מפתח OpenAI — הגדירו אותו במסך ההגדרות.")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                    }
                }

                if !analysisItems.isEmpty {
                    Section {
                        ForEach(Array(analysisItems.enumerated()), id: \.offset) { idx, item in
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("שם המזון", text: editNameBinding(idx))
                                    .multilineTextAlignment(.leading)
                                HStack(spacing: 6) {
                                    TextField("כמות", text: editGramsBinding(idx))
                                        .keyboardType(.numberPad)
                                        .multilineTextAlignment(.leading)
                                    Text("גרם")
                                        .foregroundStyle(.secondary)
                                }
                                if let totalCal = totalCaloriesText(for: idx, nutrients: item.nutrientsPer100g) {
                                    Text(totalCal)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                }
                                if item.volumeMl != nil || item.sourceLabel != nil {
                                    HStack(spacing: 6) {
                                        if let label = item.sourceLabel, !label.isEmpty {
                                            Text("תווית: \(label)")
                                        }
                                        if let vol = item.volumeMl {
                                            Text(String(format: "נפח RGB+D: %.0f מ״ל", vol))
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                                nutrientPreview(item.nutrientsPer100g)
                                if let notes = item.notes, !notes.isEmpty {
                                    Text(notes)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text(analysisItems.count > 1 ? "תוצאות ניתוח (\(analysisItems.count))" : "תוצאת ניתוח")
                    } footer: {
                        Text("הערכים הם ל־100 גרם. כל פריט יתווסף ליומן בנפרד.")
                    }
                }

                if !volumeItems.isEmpty {
                    Section {
                        ForEach(volumeItems) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.label)
                                    .font(.subheadline.weight(.semibold))
                                Text(
                                    String(
                                        format: "%.0f מ״ל · %.0f×%.0f ס״מ · גובה %.1f",
                                        item.volumeMl,
                                        item.footprintLengthCm,
                                        item.footprintWidthCm,
                                        item.medianHeightCm
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                if item.touchesImageBorder {
                                    Text("נוגע במסגרת התמונה (ייתכן קיר/מכסה קופסה)")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }

                        if let quality = scanQuality {
                            ScanQualityResultView(quality: quality)
                        }
                    } header: {
                        Text("מועמדי נפח (ה־AI יבחר מזון)")
                    }
                }

                if let heightDebugImage {
                    Section {
                        Image(uiImage: heightDebugImage)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } header: {
                        Text("תמונת גבהים")
                    } footer: {
                        Text("סולם צבעים מ־0 ס״מ עד גובה מקסימלי בסריקה. קו צהוב = מסיכת מזון.")
                    }
                }

                if isRunningOnDeviceVision {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("מנתח במכשיר (סיווג/סגמנטציה)…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let visionResult {
                    Section {
                        if visionResult.tableDetected || tableDetected {
                            Label("זוהה שולחן/משטח", systemImage: "table.furniture")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(visionResult.classifications.prefix(6)) { item in
                            HStack {
                                Text(item.identifier)
                                Spacer()
                                Text("\(Int((item.confidence * 100).rounded()))%")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    } header: {
                        Text("סיווג סצנה (Apple Vision)")
                    }
                }
            }
            .navigationTitle("הוספה עם AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("ביטול") { dismiss() }
                }
            }
            .onChange(of: pickerItem) { _, newItem in
                Task { await loadPickerItem(newItem) }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    applyNewImage(image, clearVolume: true)
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $showLiDAR) {
                FoodLiDARCaptureSheet { capture in
                    applyLiDARCapture(capture)
                }
            }
        }
    }

    private var hasFoodDescription: Bool {
        !optionalPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canAnalyze: Bool {
        ImageNutritionSettings.isConfigured && (selectedImage != nil || hasFoodDescription)
    }

    private var canCommit: Bool {
        guard !analysisItems.isEmpty, editNames.count == analysisItems.count, editGrams.count == analysisItems.count else {
            return false
        }
        for i in analysisItems.indices {
            guard !editNames[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            guard let g = Int(editGrams[i]), g > 0 else { return false }
        }
        return true
    }

    private func editNameBinding(_ idx: Int) -> Binding<String> {
        Binding(
            get: { editNames.indices.contains(idx) ? editNames[idx] : "" },
            set: { newValue in
                while editNames.count <= idx { editNames.append("") }
                editNames[idx] = newValue
            }
        )
    }

    private func editGramsBinding(_ idx: Int) -> Binding<String> {
        Binding(
            get: { editGrams.indices.contains(idx) ? editGrams[idx] : "" },
            set: { newValue in
                while editGrams.count <= idx { editGrams.append("") }
                editGrams[idx] = newValue
            }
        )
    }

    /// Total kcal for the edited weight from energy per 100 g.
    private func totalCaloriesText(for idx: Int, nutrients: [String: Double]) -> String? {
        guard let energyPer100 = nutrients["energy"],
              editGrams.indices.contains(idx),
              let grams = Int(editGrams[idx]),
              grams > 0
        else { return nil }
        let total = energyPer100 * Double(grams) / 100.0
        return "\(Int(total.rounded())) קלוריות ל־\(grams) גרם"
    }

    @ViewBuilder
    private func nutrientPreview(_ nuts: [String: Double]) -> some View {
        let order = ImageNutritionSettings.basicNutrientKeys + nuts.keys.filter { !ImageNutritionSettings.basicNutrientKeys.contains($0) }.sorted()
        VStack(alignment: .leading, spacing: 4) {
            ForEach(order.filter { nuts[$0] != nil }, id: \.self) { key in
                if let v = nuts[key] {
                    HStack {
                        Text(hebrewLabel(for: key))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(formatNut(v, key: key))
                    }
                    .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hebrewLabel(for key: String) -> String {
        switch key {
        case "energy": return "קלוריות"
        case "protein": return "חלבון"
        case "carbohydrate": return "פחמימות"
        case "total_lipid_fat": return "שומן"
        case "dietary_fiber": return "סיבים"
        default: return key
        }
    }

    private func formatNut(_ v: Double, key: String) -> String {
        if key == "energy" {
            return "\(Int(v.rounded())) /100ג׳"
        }
        let x = (v * 10).rounded() / 10
        if x.rounded() == x {
            return "\(Int(x)) /100ג׳"
        }
        return String(format: "%.1f /100ג׳", x)
    }

    private func applyNewImage(_ image: UIImage, clearVolume: Bool) {
        selectedImage = image
        analysisItems = []
        editNames = []
        editGrams = []
        errorText = nil
        visionResult = nil
        if clearVolume {
            volumeItems = []
            tableDetected = false
            scanQuality = nil
            debugScanDirectoryURL = nil
            heightDebugImage = nil
        }
        Task { await runOnDeviceVision(for: image) }
    }

    private func applyLiDARCapture(_ capture: FoodDepthCaptureResult) {
        selectedImage = capture.colorImage
        analysisItems = []
        editNames = []
        editGrams = []
        errorText = nil
        volumeItems = capture.items
        tableDetected = capture.tableDetected
        scanQuality = capture.scanQuality
        debugScanDirectoryURL = capture.debugScanDirectoryURL
        heightDebugImage = capture.heightDebugImage
        visionResult = VisionFoodSceneAnalyzer.Result(
            classifications: capture.visionLabels,
            foregroundMask: nil,
            imageWidth: Int(capture.colorImage.size.width),
            imageHeight: Int(capture.colorImage.size.height)
        )
    }

    private func runOnDeviceVision(for image: UIImage) async {
        isRunningOnDeviceVision = true
        defer { isRunningOnDeviceVision = false }
        do {
            let result = try await VisionFoodSceneAnalyzer.analyze(image)
            await MainActor.run {
                visionResult = result
                tableDetected = result.tableDetected
            }
        } catch {
            await MainActor.run { visionResult = nil }
        }
    }

    private func loadPickerItem(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                await MainActor.run {
                    applyNewImage(image, clearVolume: true)
                }
            }
        } catch {
            await MainActor.run {
                errorText = error.localizedDescription
            }
        }
    }

    private func makeOnDeviceHints() -> FoodImageOnDeviceHints? {
        if !volumeItems.isEmpty {
            let output = FoodItemVolumeSegmenter.Output(
                items: volumeItems,
                sceneClassifications: visionResult?.classifications ?? [],
                tableDetected: tableDetected,
                combinedFoodMask01: nil,
                islandLabelMap: nil,
                depthWidth: 0,
                depthHeight: 0
            )
            return FoodImageOnDeviceHints.fromVolumeSegmentation(output)
        }
        let labels = (visionResult?.classifications ?? []).map {
            FoodImageOnDeviceHints.LabelHint(id: $0.identifier, confidence: $0.confidence)
        }
        let hints = FoodImageOnDeviceHints(
            visionLabels: labels,
            tableDetected: visionResult?.tableDetected,
            volumeItems: [],
            volumeMl: nil
        )
        return hints.isEmpty ? nil : hints
    }

    private func analyze() async {
        if selectedImage == nil {
            await analyzeTextOnly()
            return
        }
        guard let image = selectedImage,
              let jpeg = FoodImageNutritionClient.jpegData(from: image)
        else {
            errorText = FoodImageNutritionError.invalidImage.localizedDescription
            return
        }
        isAnalyzing = true
        errorText = nil
        defer { isAnalyzing = false }
        do {
            if visionResult == nil {
                await runOnDeviceVision(for: image)
            }
            let hints = makeOnDeviceHints()
            let results = try await FoodImageNutritionClient().analyzeFoodImage(
                jpegData: jpeg,
                optionalPrompt: optionalPrompt,
                detailLevel: detailLevel,
                nutrientKeys: nutrientKeysForDetail,
                onDeviceHints: hints
            )
            let merged = Self.mergeVolumeEstimations(into: results, volumeItems: volumeItems)
            analysisItems = merged
            editNames = merged.map(\.itemName)
            editGrams = merged.map { String($0.quantityGrams) }
            FoodVolumeScanDebugStore.saveAIAnalysisIfPossible(
                scanDirectory: debugScanDirectoryURL,
                hints: hints,
                results: merged,
                jpegSentToAPI: jpeg
            )
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func analyzeTextOnly() async {
        let description = optionalPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            errorText = FoodImageNutritionError.emptyDescription.localizedDescription
            return
        }
        isAnalyzing = true
        errorText = nil
        defer { isAnalyzing = false }
        do {
            let results = try await FoodImageNutritionClient().analyzeFoodText(
                description: description,
                detailLevel: detailLevel,
                nutrientKeys: nutrientKeysForDetail
            )
            analysisItems = results
            editNames = results.map(\.itemName)
            editGrams = results.map { String($0.quantityGrams) }
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Attaches the matching on-device island onto analysis rows by echoed volume_ml.
    private static func mergeVolumeEstimations(
        into results: [FoodImageNutritionResult],
        volumeItems: [FoodVolumeItem]
    ) -> [FoodImageNutritionResult] {
        guard !volumeItems.isEmpty else { return results }
        var remaining = volumeItems
        return results.map { result in
            var updated = result
            guard let vm = result.volumeMl, !remaining.isEmpty else { return updated }
            let best = remaining.enumerated().min { a, b in
                abs(a.element.volumeMl - vm) < abs(b.element.volumeMl - vm)
            }
            guard let best, abs(best.element.volumeMl - vm) < 1.0 else { return updated }
            let vol = remaining.remove(at: best.offset)
            updated.sourceLabel = vol.label
            updated.volumeMl = vol.volumeMl
            return updated
        }
    }

    private func commitAdd() {
        guard canCommit else { return }
        for i in analysisItems.indices {
            var result = analysisItems[i]
            result.itemName = editNames[i].trimmingCharacters(in: .whitespacesAndNewlines)
            result.quantityGrams = Int(editGrams[i]) ?? result.quantityGrams
            onConfirm(result)
        }
        dismiss()
    }
}

// MARK: - Scan Quality Result View

private struct ScanQualityResultView: View {
    let quality: ScanQualityAnalyzer.CaptureQuality
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Reliability indicator
                Circle()
                    .fill(reliabilityColor)
                    .frame(width: 10, height: 10)
                
                Text("איכות סריקה: \(reliabilityText)")
                    .font(.caption)
                    .fontWeight(.medium)
                
                Spacer()
                
                Text(String(format: "%.0f ס״מ", quality.medianDistanceCm))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            
            // Warning message if any
            if let warning = quality.warningMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            
            // Quality details
            HStack(spacing: 16) {
                qualityMetric(label: "כיסוי עומק", value: String(format: "%.0f%%", quality.depthCoverage * 100))
                qualityMetric(label: "איכות מישור", value: String(format: "%.0f%%", quality.planeFitQuality * 100))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
    
    private var reliabilityColor: Color {
        if quality.reliabilityScore >= 0.7 {
            return .green
        } else if quality.reliabilityScore >= 0.4 {
            return .yellow
        } else {
            return .red
        }
    }
    
    private var reliabilityText: String {
        if quality.reliabilityScore >= 0.8 {
            return "מצוינת"
        } else if quality.reliabilityScore >= 0.6 {
            return "טובה"
        } else if quality.reliabilityScore >= 0.4 {
            return "בינונית"
        } else {
            return "חלשה"
        }
    }
    
    @ViewBuilder
    private func qualityMetric(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label + ":")
            Text(value)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Camera

private struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.dismiss()
        }
    }
}
