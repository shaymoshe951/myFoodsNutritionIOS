import Foundation
import UIKit

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
        apiKey: String = ImageNutritionSettings.openAIAPIKey,
        model: String = ImageNutritionSettings.visionModel
    ) async throws -> FoodImageNutritionResult {
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
        let userText = Self.userPrompt(optionalPrompt: optionalPrompt, detailLevel: detailLevel, nutrientKeys: keys)
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
            // Faster, cheaper estimates; GPT-5.x typically rejects `temperature`.
            body["reasoning_effort"] = "low"
        } else {
            body["temperature"] = 0.2
        }

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
            return try payload.toResult()
        } catch let e as FoodImageNutritionError {
            throw e
        } catch {
            throw FoodImageNutritionError.decoding(error)
        }
    }

    /// JPEG data suitable for upload (max edge ~1280, quality ~0.72).
    static func jpegData(from image: UIImage, maxEdge: CGFloat = 1280, quality: CGFloat = 0.72) -> Data? {
        let scaled = image.scaledToMaxEdge(maxEdge)
        return scaled.jpegData(compressionQuality: quality)
    }

    private static let systemPrompt = """
    You are a nutrition estimation assistant for a Hebrew food diary app.
    Identify the food in the photo and estimate nutrition **per 100 grams**.
    Prefer Hebrew food names when the food is commonly named in Hebrew.
    Return ONLY a JSON object with this shape:
    {
      "item_name": string,
      "quantity_grams": number,
      "nutrients_per_100g": { "<nutrient_key>": number, ... },
      "notes": string (optional)
    }
    quantity_grams is the estimated edible portion in the photo (grams).
    nutrients_per_100g values must use the exact nutrient keys requested by the user.
    energy is kcal per 100 g. macronutrients (protein, carbohydrate, total_lipid_fat, dietary_fiber) are grams per 100 g.
    Micronutrients use the same mass units as typical food composition tables for that key (mg/µg as appropriate for the key name); prefer numeric amounts per 100 g consistent with USDA-style tables.
    If unsure, still provide best estimates; do not omit requested keys (use 0 only when truly negligible).
    """

    private static func userPrompt(
        optionalPrompt: String?,
        detailLevel: ImageNutritionDetailLevel,
        nutrientKeys: [String]
    ) -> String {
        let keysList = nutrientKeys.joined(separator: ", ")
        var parts: [String] = [
            "Estimate nutrition for the food in this image.",
            "Detail level: \(detailLevel.rawValue).",
            "Include nutrients_per_100g for exactly these keys: \(keysList).",
        ]
        let extra = optionalPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !extra.isEmpty {
            parts.append("Additional user hint: \(extra)")
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
