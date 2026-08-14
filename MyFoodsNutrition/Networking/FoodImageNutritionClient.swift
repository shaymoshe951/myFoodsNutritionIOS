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
        var estimatedGrams: Int
        var densityGPerMl: Double
    }

    var visionLabels: [LabelHint]
    var tableDetected: Bool?
    /// Preferred: one entry per edible instance (plate/bowl excluded).
    var volumeItems: [VolumeItemHint]
    /// Legacy single-blob fields (sum / first item) for older UI paths.
    var volumeMl: Double?
    var estimatedGramsFromVolume: Int?
    var densityGPerMl: Double?

    var isEmpty: Bool {
        visionLabels.isEmpty
            && tableDetected == nil
            && volumeItems.isEmpty
            && volumeMl == nil
            && estimatedGramsFromVolume == nil
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
                estimatedGrams: $0.estimatedGrams,
                densityGPerMl: $0.densityGPerMl
            )
        }
        let totalMl = output.items.reduce(0.0) { $0 + $1.volumeMl }
        let totalG = output.items.reduce(0) { $0 + $1.estimatedGrams }
        return FoodImageOnDeviceHints(
            visionLabels: labels,
            tableDetected: output.tableDetected,
            volumeItems: items,
            volumeMl: totalMl > 0 ? totalMl : nil,
            estimatedGramsFromVolume: totalG > 0 ? totalG : nil,
            densityGPerMl: output.items.first?.densityGPerMl
        )
    }
}

/// Sends a food photo (+ optional prompt) to OpenAI vision and returns structured nutrition per 100 g.
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
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw FoodImageNutritionError.invalidURL
        }

        let keys = nutrientKeys.isEmpty
            ? ImageNutritionSettings.basicNutrientKeys
            : nutrientKeys

        let base64 = jpegData.base64EncodedString()
        let dataURL = "data:image/jpeg;base64,\(base64)"
        let userText = Self.userPrompt(
            optionalPrompt: optionalPrompt,
            detailLevel: detailLevel,
            nutrientKeys: keys,
            onDeviceHints: onDeviceHints
        )
        let modelOption = OpenAIVisionModelOption.fromStoredModelId(model)

        var body: [String: Any] = [
            "model": modelOption.rawValue,
            "response_format": ["type": "json_object"],
            "messages": [
                [
                    "role": "system",
                    "content": Self.systemPrompt,
                ],
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": userText],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": dataURL,
                                "detail": "high",
                            ] as [String: Any],
                        ] as [String: Any],
                    ],
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
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
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

    static func jpegData(from image: UIImage, maxEdge: CGFloat = 1280, quality: CGFloat = 0.72) -> Data? {
        let scaled = image.scaledToMaxEdge(maxEdge)
        return scaled.jpegData(compressionQuality: quality)
    }

    private static let systemPrompt = """
    You are a nutrition estimation assistant for a Hebrew food diary app.
    Identify edible foods in the photo and estimate nutrition **per 100 grams** for each distinct food.
    Ignore plates, bowls, utensils, and the table — they are not food diary items.
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
          "volume_ml": number (optional on-device volume)
        }
      ]
    }
    If on-device volume_items are provided, return one output item per volume_item (same order), using measured volume/grams for quantity_grams (you may refine slightly), and improve the food name from the image.
    If only a single food is present, still return an "items" array with one element.
    nutrients_per_100g must use the exact nutrient keys requested by the user.
    energy is kcal per 100 g. macronutrients (protein, carbohydrate, total_lipid_fat, dietary_fiber) are grams per 100 g.
    Micronutrients use typical food-composition units for that key.
    If unsure, still provide best estimates; do not omit requested keys (use 0 only when truly negligible).
    """

    private static func userPrompt(
        optionalPrompt: String?,
        detailLevel: ImageNutritionDetailLevel,
        nutrientKeys: [String],
        onDeviceHints: FoodImageOnDeviceHints?
    ) -> String {
        let keysList = nutrientKeys.joined(separator: ", ")
        var parts: [String] = [
            "Estimate nutrition for edible food in this image (exclude plate/bowl/utensils).",
            "Detail level: \(detailLevel.rawValue).",
            "Include nutrients_per_100g for exactly these keys: \(keysList).",
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
                parts.append("- volume_items (plate/bowl already excluded when possible):")
                for (i, it) in hints.volumeItems.enumerated() {
                    parts.append(
                        "  \(i + 1). label=\(it.label) conf=\(String(format: "%.2f", it.confidence)) volume_ml=\(String(format: "%.1f", it.volumeMl)) estimated_grams=\(it.estimatedGrams) density_g_per_ml=\(String(format: "%.2f", it.densityGPerMl))"
                    )
                }
            } else {
                if let v = hints.volumeMl {
                    parts.append("- measured_volume_ml: \(String(format: "%.1f", v))")
                }
                if let g = hints.estimatedGramsFromVolume {
                    parts.append("- estimated_grams_from_volume: \(g)")
                }
                if let d = hints.densityGPerMl {
                    parts.append("- assumed_density_g_per_ml: \(String(format: "%.2f", d))")
                }
            }
            if !hints.visionLabels.isEmpty {
                let labelText = hints.visionLabels.prefix(8).map { "\($0.id)(\(String(format: "%.2f", $0.confidence)))" }.joined(separator: ", ")
                parts.append("- apple_vision_scene_labels: \(labelText)")
            }
        }
        return parts.joined(separator: "\n")
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
