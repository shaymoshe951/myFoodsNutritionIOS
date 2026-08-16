import Foundation
import UIKit

/// Optional on-device Vision / LiDAR hints appended to the AI user prompt.
struct FoodImageOnDeviceHints: Equatable {
    struct LabelHint: Equatable {
        var id: String
        var confidence: Float
    }

    struct VolumeItemHint: Equatable {
        var label: String
        var confidence: Float
        var volumeMl: Double
        var footprintLengthCm: Double
        var footprintWidthCm: Double
        var medianHeightCm: Double
        var foodPixelCount: Int
        var touchesImageBorder: Bool
    }

    var visionLabels: [LabelHint]
    var tableDetected: Bool?
    /// Raw LiDAR height islands (food plus possible box/plate/walls).
    var volumeItems: [VolumeItemHint]
    /// Set only when there is a single island, so the model does not sum candidates.
    var volumeMl: Double?

    var isEmpty: Bool {
        visionLabels.isEmpty
            && tableDetected == nil
            && volumeItems.isEmpty
            && volumeMl == nil
    }

    static func fromVolumeSegmentation(_ output: FoodItemVolumeSegmenter.Output) -> FoodImageOnDeviceHints {
        let labels = output.sceneClassifications.map {
            LabelHint(id: $0.identifier, confidence: $0.confidence)
        }
        let items = output.items.map {
            VolumeItemHint(
                label: $0.label,
                confidence: $0.labelConfidence,
                volumeMl: $0.volumeMl,
                footprintLengthCm: $0.footprintLengthCm,
                footprintWidthCm: $0.footprintWidthCm,
                medianHeightCm: $0.medianHeightCm,
                foodPixelCount: $0.foodPixelCount,
                touchesImageBorder: $0.touchesImageBorder
            )
        }
        return FoodImageOnDeviceHints(
            visionLabels: labels,
            tableDetected: output.tableDetected,
            volumeItems: items,
            volumeMl: items.count == 1 ? items[0].volumeMl : nil
        )
    }
}

/// Sends a food photo (+ optional prompt) or a text-only description to OpenAI and returns structured nutrition per 100 g.
struct FoodImageNutritionClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func analyzeFoodImage(
        jpegData: Data,
        optionalPrompt: String?,
        detailLevel: ImageNutritionDetailLevel,
        nutrientKeys: [String],
        onDeviceHints: FoodImageOnDeviceHints? = nil,
        apiKey: String = ImageNutritionSettings.openAIAPIKey,
        model: String = ImageNutritionSettings.visionModel
    ) async throws -> [FoodImageNutritionResult] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw FoodImageNutritionError.notConfigured }
        guard !jpegData.isEmpty else { throw FoodImageNutritionError.invalidImage }

        let keys = Self.resolvedNutrientKeys(nutrientKeys)
        let base64 = jpegData.base64EncodedString()
        let dataURL = "data:image/jpeg;base64,\(base64)"
        let userText = Self.imageUserPrompt(
            optionalPrompt: optionalPrompt,
            detailLevel: detailLevel,
            nutrientKeys: keys,
            onDeviceHints: onDeviceHints
        )
        let userContent: [[String: Any]] = [
            ["type": "text", "text": userText],
            [
                "type": "image_url",
                "image_url": [
                    "url": dataURL,
                    "detail": "high",
                ] as [String: Any],
            ],
        ]
        return try await performCompletions(
            systemPrompt: Self.imageSystemPrompt,
            userContent: userContent,
            apiKey: key,
            model: model
        )
    }

    func analyzeFoodText(
        description: String,
        detailLevel: ImageNutritionDetailLevel,
        nutrientKeys: [String],
        apiKey: String = ImageNutritionSettings.openAIAPIKey,
        model: String = ImageNutritionSettings.visionModel
    ) async throws -> [FoodImageNutritionResult] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw FoodImageNutritionError.notConfigured }
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw FoodImageNutritionError.emptyDescription }

        let keys = Self.resolvedNutrientKeys(nutrientKeys)
        let userText = Self.textUserPrompt(
            description: text,
            detailLevel: detailLevel,
            nutrientKeys: keys
        )
        let userContent: [[String: Any]] = [
            ["type": "text", "text": userText],
        ]
        return try await performCompletions(
            systemPrompt: Self.textSystemPrompt,
            userContent: userContent,
            apiKey: key,
            model: model
        )
    }

    static func jpegData(from image: UIImage, maxEdge: CGFloat = 1280, quality: CGFloat = 0.72) -> Data? {
        let scaled = image.scaledToMaxEdge(maxEdge)
        return scaled.jpegData(compressionQuality: quality)
    }

    private func performCompletions(
        systemPrompt: String,
        userContent: [[String: Any]],
        apiKey: String,
        model: String
    ) async throws -> [FoodImageNutritionResult] {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw FoodImageNutritionError.invalidURL
        }

        let modelOption = OpenAIVisionModelOption.fromStoredModelId(model)
        var body: [String: Any] = [
            "model": modelOption.rawValue,
            "response_format": ["type": "json_object"],
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt,
                ],
                [
                    "role": "user",
                    "content": userContent,
                ],
            ],
        ]
        if modelOption.usesReasoningAPIConstraints {
            body["reasoning_effort"] = "low"
        } else if modelOption.supportsCustomTemperature {
            body["temperature"] = 0.2
        }
        // Else omit temperature (required for models that only allow the API default).

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FoodImageNutritionError.http(-1, error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FoodImageNutritionError.badResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let preview = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw FoodImageNutritionError.http(http.statusCode, preview)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw FoodImageNutritionError.emptyContent
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let contentData = trimmed.data(using: .utf8) else {
            throw FoodImageNutritionError.emptyContent
        }

        do {
            let payload = try JSONDecoder().decode(FoodImageNutritionPayload.self, from: contentData)
            return try payload.toResults()
        } catch let e as FoodImageNutritionError {
            throw e
        } catch {
            throw FoodImageNutritionError.decoding(error)
        }
    }

    private static func resolvedNutrientKeys(_ nutrientKeys: [String]) -> [String] {
        nutrientKeys.isEmpty ? ImageNutritionSettings.basicNutrientKeys : nutrientKeys
    }

    private static let imageSystemPrompt = """
    You are a nutrition estimation assistant for a Hebrew food diary app.
    Identify edible foods in the photo and estimate nutrition **per 100 grams** for each distinct food.
    Ignore plates, bowls, utensils, pizza boxes, cartons, and the table — they are not food diary items.
    Prefer Hebrew food names when the food is commonly named in Hebrew.
    Return ONLY a JSON object with this shape:
    {
      "items": [
        {
          "item_name": string,
          "quantity_grams": number,
          "nutrients_per_100g": { "<nutrient_key>": number, ... },
          "notes": string (optional),
          "source_label": string (optional on-device label),
          "volume_ml": number (optional echo of on-device volume)
        }
      ]
    }
    quantity_grams is the edible portion weight in grams for that item.
    If on-device volume_items are provided, they are RAW height-island candidates — food plus possible box/plate/walls. Using the photo, keep only edible food. Return one output item per kept candidate and echo that candidate's volume_ml. Do not output a row for container/box/plate/table/wall candidates. Do not return one row per candidate unless that candidate is edible. Do not sum candidate volumes. Candidates that touch the image border or have a footprint much larger than the visible food are often container walls, not food. Use each kept volume_ml together with the image (and food type) to estimate quantity_grams yourself — do not assume a fixed density from the app. Improve the food name from the image.
    If only a single food is present, still return an "items" array with one element.
    nutrients_per_100g must use the exact nutrient keys requested by the user.
    energy is kcal per 100 g. macronutrients (protein, carbohydrate, total_lipid_fat, dietary_fiber) are grams per 100 g.
    Micronutrients use typical food-composition units for that key.
    If unsure, still provide best estimates; do not omit requested keys (use 0 only when truly negligible).
    """

    private static let textSystemPrompt = """
    You are a nutrition estimation assistant for a Hebrew food diary app.
    The user describes food in text (no photo). Identify the edible foods and estimate nutrition **per 100 grams** for each distinct food.
    Prefer Hebrew food names when the food is commonly named in Hebrew.
    Parse any portion size from the description (grams, milliliters, pieces, cups, tablespoons, household measures such as "חצי מנה") into quantity_grams.
    If no portion is given, use a typical serving and still return quantity_grams.
    Return ONLY a JSON object with this shape:
    {
      "items": [
        {
          "item_name": string,
          "quantity_grams": number,
          "nutrients_per_100g": { "<nutrient_key>": number, ... },
          "notes": string (optional)
        }
      ]
    }
    quantity_grams is the edible portion weight in grams for that item.
    If only a single food is present, still return an "items" array with one element.
    nutrients_per_100g must use the exact nutrient keys requested by the user.
    energy is kcal per 100 g. macronutrients (protein, carbohydrate, total_lipid_fat, dietary_fiber) are grams per 100 g.
    Micronutrients use typical food-composition units for that key.
    If unsure, still provide best estimates; do not omit requested keys (use 0 only when truly negligible).
    """

    private static func imageUserPrompt(
        optionalPrompt: String?,
        detailLevel: ImageNutritionDetailLevel,
        nutrientKeys: [String],
        onDeviceHints: FoodImageOnDeviceHints?
    ) -> String {
        let keysList = nutrientKeys.joined(separator: ", ")
        var parts: [String] = [
            "Estimate nutrition for edible food in this image (exclude plate/bowl/utensils/box/carton).",
            "Detail level: \(detailLevel.rawValue).",
            "Include nutrients_per_100g for exactly these keys: \(keysList).",
            "Estimate quantity_grams for each edible item from the image. If you keep a volume_item, use that candidate's volume_ml for the weight — do not sum unused candidates.",
        ]
        let extra = optionalPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !extra.isEmpty {
            parts.append("Additional user hint: \(extra)")
        }
        if let hints = onDeviceHints, !hints.isEmpty {
            parts.append("On-device measurements/hints:")
            if let table = hints.tableDetected {
                parts.append("- table_detected_by_vision: \(table)")
            }
            if !hints.volumeItems.isEmpty {
                parts.append("- volume_items (raw LiDAR height islands; keep edible food only, do not sum):")
                for (i, it) in hints.volumeItems.enumerated() {
                    parts.append(
                        "  \(i + 1). label=\(it.label) conf=\(String(format: "%.2f", it.confidence)) volume_ml=\(String(format: "%.1f", it.volumeMl)) footprint_cm=\(String(format: "%.1f", it.footprintLengthCm))x\(String(format: "%.1f", it.footprintWidthCm)) median_height_cm=\(String(format: "%.1f", it.medianHeightCm)) pixels=\(it.foodPixelCount) touches_image_border=\(it.touchesImageBorder)"
                    )
                }
            } else if let v = hints.volumeMl {
                parts.append("- measured_volume_ml: \(String(format: "%.1f", v))")
            }
            if !hints.visionLabels.isEmpty {
                let labelText = hints.visionLabels.prefix(8).map { "\($0.id)(\(String(format: "%.2f", $0.confidence)))" }.joined(separator: ", ")
                parts.append("- apple_vision_scene_labels: \(labelText)")
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func textUserPrompt(
        description: String,
        detailLevel: ImageNutritionDetailLevel,
        nutrientKeys: [String]
    ) -> String {
        let keysList = nutrientKeys.joined(separator: ", ")
        return [
            "Estimate nutrition from this food description (no image).",
            "Detail level: \(detailLevel.rawValue).",
            "Include nutrients_per_100g for exactly these keys: \(keysList).",
            "Parse quantity_grams from the description when a portion is given.",
            "Food description: \(description)",
        ].joined(separator: "\n")
    }
}

private extension UIImage {
    func scaledToMaxEdge(_ maxEdge: CGFloat) -> UIImage {
        let w = size.width
        let h = size.height
        let longest = max(w, h)
        guard longest > maxEdge, longest > 0 else { return self }
        let scale = maxEdge / longest
        let newSize = CGSize(width: (w * scale).rounded(.down), height: (h * scale).rounded(.down))
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
