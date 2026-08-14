import PhotosUI
import SwiftUI
import UIKit

/// Pick a food photo, optional hint, run AI nutrition analysis, then confirm add to the diary.
struct FoodImageAddSheet: View {
    @Environment(\.dismiss) private var dismiss

    let nutrientKeysForDetail: [String]
    var onConfirm: (FoodImageNutritionResult) -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var showCamera = false
    @State private var showLiDAR = false
    @State private var optionalPrompt = ""
    @State private var isAnalyzing = false
    @State private var isRunningOnDeviceVision = false
    @State private var errorText: String?
    @State private var analysis: FoodImageNutritionResult?
    @State private var editName = ""
    @State private var editGramsText = ""
    @State private var visionResult: VisionFoodSceneAnalyzer.Result?
    @State private var volumeResult: FoodVolumeEstimator.Result?
    @State private var volumeEstimatedGrams: Int?
    @State private var volumeDensity: Double?

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
                        Text("בחרו תמונה של המזון או צלמו.")
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
                        Text("«נפח» משתמש ב־LiDAR + סגמנטציה במכשיר להערכת מ״ל/גרם.")
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
                        if visionResult.tableDetected {
                            Label("זוהה שולחן/משטח", systemImage: "table.furniture")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if visionResult.foregroundMask != nil {
                            Label("מסכת מזון (סגמנטציה) זמינה", systemImage: "circle.dashed")
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
                        Text("סיווג במכשיר (Apple Vision)")
                    }
                }

                if let volumeResult {
                    Section {
                        LabeledContent("נפח") {
                            Text("\(Int(volumeResult.volumeMl.rounded())) מ״ל")
                        }
                        LabeledContent("טביעת רגל") {
                            Text(String(format: "%.0f×%.0f ס״מ", volumeResult.footprintLengthCm, volumeResult.footprintWidthCm))
                        }
                        LabeledContent("גובה (חציון)") {
                            Text(String(format: "%.1f ס״מ", volumeResult.medianHeightCm))
                        }
                        if let grams = volumeEstimatedGrams {
                            LabeledContent("גרם משוער") {
                                Text("\(grams) ג׳")
                            }
                        }
                        if let density = volumeDensity {
                            Text(String(format: "צפיפות משוערת %.2f ג׳/מ״ל לפי תוויות Vision", density))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("נפח מ־LiDAR")
                    }
                }

                Section {
                    TextField("למשל: חצי מנה, בלי רוטב…", text: $optionalPrompt, axis: .vertical)
                        .lineLimit(2 ... 4)
                        .multilineTextAlignment(.leading)
                } header: {
                    Text("הנחיה ל־AI (אופציונלי)")
                } footer: {
                    Text("רמת פירוט נוכחית: \(detailLevel.labelHe). ניתן לשנות בהגדרות.")
                }

                if let analysis {
                    Section {
                        TextField("שם המזון", text: $editName)
                            .multilineTextAlignment(.leading)
                        TextField("כמות בגרם", text: $editGramsText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.leading)
                        nutrientPreview(analysis.nutrientsPer100g)
                        if let notes = analysis.notes, !notes.isEmpty {
                            Text(notes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                        }
                    } header: {
                        Text("תוצאת ניתוח")
                    } footer: {
                        Text("הערכים הם ל־100 גרם. ניתן לערוך שם וכמות לפני הוספה ליומן.")
                    }
                }

                Section {
                    if isAnalyzing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("מנתח תמונה…")
                                .foregroundStyle(.secondary)
                        }
                    } else if analysis == nil {
                        Button("נתח תזונה מהתמונה") {
                            Task { await analyze() }
                        }
                        .disabled(selectedImage == nil || !ImageNutritionSettings.isConfigured)
                    } else {
                        Button("הוסף ליומן") {
                            commitAdd()
                        }
                        .disabled(!canCommit)
                        Button("נתח שוב", role: .destructive) {
                            analysis = nil
                            Task { await analyze() }
                        }
                        .disabled(selectedImage == nil || isAnalyzing)
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
            }
            .navigationTitle("הוספה מתמונה")
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

    private var canCommit: Bool {
        guard analysis != nil else { return false }
        let nameOK = !editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let gramsOK = Int(editGramsText).map { $0 > 0 } ?? false
        return nameOK && gramsOK
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
        analysis = nil
        errorText = nil
        visionResult = nil
        if clearVolume {
            volumeResult = nil
            volumeEstimatedGrams = nil
            volumeDensity = nil
        }
        Task { await runOnDeviceVision(for: image) }
    }

    private func applyLiDARCapture(_ capture: FoodDepthCaptureResult) {
        selectedImage = capture.colorImage
        analysis = nil
        errorText = nil
        visionResult = capture.vision
        volumeResult = capture.volume
        volumeEstimatedGrams = capture.estimatedGrams
        volumeDensity = capture.densityGPerMl
        editGramsText = String(capture.estimatedGrams)
        if let name = capture.vision.suggestedFoodNameEn {
            // Prefill prompt only; AI will localize Hebrew name.
            if optionalPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                optionalPrompt = "Vision label: \(name); volume \(Int(capture.volume.volumeMl.rounded())) ml"
            }
        }
    }

    private func runOnDeviceVision(for image: UIImage) async {
        isRunningOnDeviceVision = true
        defer { isRunningOnDeviceVision = false }
        do {
            let result = try await VisionFoodSceneAnalyzer.analyze(image)
            await MainActor.run {
                visionResult = result
            }
        } catch {
            // Vision assist is optional; don't block AI analysis.
            await MainActor.run {
                visionResult = nil
            }
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
        let labels = (visionResult?.classifications ?? []).map {
            FoodImageOnDeviceHints.LabelHint(id: $0.identifier, confidence: $0.confidence)
        }
        let hints = FoodImageOnDeviceHints(
            visionLabels: labels,
            tableDetected: visionResult?.tableDetected,
            volumeMl: volumeResult?.volumeMl,
            estimatedGramsFromVolume: volumeEstimatedGrams,
            densityGPerMl: volumeDensity
        )
        return hints.isEmpty ? nil : hints
    }

    private func analyze() async {
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
            let keys = nutrientKeysForDetail
            let result = try await FoodImageNutritionClient().analyzeFoodImage(
                jpegData: jpeg,
                optionalPrompt: optionalPrompt,
                detailLevel: detailLevel,
                nutrientKeys: keys,
                onDeviceHints: makeOnDeviceHints()
            )
            analysis = result
            editName = result.itemName
            if let volumeGrams = volumeEstimatedGrams, volumeGrams > 0 {
                editGramsText = String(volumeGrams)
            } else {
                editGramsText = String(result.quantityGrams)
            }
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func commitAdd() {
        guard var result = analysis else { return }
        let name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let grams = Int(editGramsText), grams > 0 else { return }
        result.itemName = name
        result.quantityGrams = grams
        onConfirm(result)
        dismiss()
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
