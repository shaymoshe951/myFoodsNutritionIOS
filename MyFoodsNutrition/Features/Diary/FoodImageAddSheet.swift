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
    @State private var optionalPrompt = ""
    @State private var isAnalyzing = false
    @State private var errorText: String?
    @State private var analysis: FoodImageNutritionResult?
    @State private var editName = ""
    @State private var editGramsText = ""

    private var detailLevel: ImageNutritionDetailLevel {
        ImageNutritionSettings.detailLevel
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
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button {
                                showCamera = true
                            } label: {
                                Label("מצלמה", systemImage: "camera")
                            }
                        }
                    }
                } header: {
                    Text("תמונה")
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
                    selectedImage = image
                    analysis = nil
                    errorText = nil
                }
                .ignoresSafeArea()
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

    private func loadPickerItem(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                await MainActor.run {
                    selectedImage = image
                    analysis = nil
                    errorText = nil
                }
            }
        } catch {
            await MainActor.run {
                errorText = error.localizedDescription
            }
        }
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
            let keys = nutrientKeysForDetail
            let result = try await FoodImageNutritionClient().analyzeFoodImage(
                jpegData: jpeg,
                optionalPrompt: optionalPrompt,
                detailLevel: detailLevel,
                nutrientKeys: keys
            )
            analysis = result
            editName = result.itemName
            editGramsText = String(result.quantityGrams)
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
