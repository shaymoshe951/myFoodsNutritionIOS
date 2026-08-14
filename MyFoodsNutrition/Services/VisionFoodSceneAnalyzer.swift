import Foundation
import UIKit
import Vision

/// On-device scene labels + foreground mask via Apple Vision (no network).
enum VisionFoodSceneAnalyzer {

    struct Classification: Equatable, Identifiable {
        var identifier: String
        var confidence: Float
        var id: String { identifier }
    }

    struct Result: Equatable {
        var classifications: [Classification]
        /// Soft mask aligned to the source image size (1 = foreground). Nil if segmentation failed.
        var foregroundMask: [[Float]]?
        var imageWidth: Int
        var imageHeight: Int

        var topFoodLikeLabels: [Classification] {
            classifications.filter { VisionFoodSceneAnalyzer.isFoodLike($0.identifier) }
        }

        var tableDetected: Bool {
            classifications.contains { VisionFoodSceneAnalyzer.isTableLike($0.identifier) && $0.confidence >= 0.15 }
        }

        var suggestedFoodNameEn: String? {
            topFoodLikeLabels.first(where: { $0.identifier != "food" })?.identifier
                ?? topFoodLikeLabels.first?.identifier
        }
    }

    static func analyze(_ image: UIImage, maxClassifications: Int = 12) async throws -> Result {
        guard let cgImage = image.cgImage else {
            throw VisionFoodSceneError.invalidImage
        }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return try await Task.detached(priority: .userInitiated) {
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            let classify = VNClassifyImageRequest()
            let segment = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([classify, segment])

            let labels: [Classification] = (classify.results ?? [])
                .prefix(maxClassifications)
                .map { Classification(identifier: $0.identifier, confidence: $0.confidence) }

            var mask: [[Float]]?
            if let obs = segment.results?.first {
                mask = try Self.softMask(from: obs, handler: handler, width: cgImage.width, height: cgImage.height)
            }

            return Result(
                classifications: labels,
                foregroundMask: mask,
                imageWidth: cgImage.width,
                imageHeight: cgImage.height
            )
        }.value
    }

    static func isFoodLike(_ id: String) -> Bool {
        let s = id.lowercased()
        if s == "food" || s == "meal" || s == "dish" || s == "cuisine" { return true }
        let foodTokens = [
            "bread", "loaf", "bagel", "pizza", "pasta", "salad", "soup", "rice", "meat", "chicken",
            "beef", "fish", "sushi", "fruit", "apple", "banana", "vegetable", "cheese", "egg",
            "cake", "cookie", "sandwich", "burger", "steak", "yogurt", "dessert", "noodle",
            "potato", "toast", "croissant", "pretzel",
        ]
        return foodTokens.contains { s.contains($0) }
    }

    static func isTableLike(_ id: String) -> Bool {
        let s = id.lowercased()
        return s.contains("table") || s == "desk" || s.contains("countertop") || s.contains("dining")
    }

    private static func softMask(
        from observation: VNInstanceMaskObservation,
        handler: VNImageRequestHandler,
        width: Int,
        height: Int
    ) throws -> [[Float]] {
        let instances = observation.allInstances
        guard !instances.isEmpty else { return [] }
        let maskPixelBuffer = try observation.generateScaledMaskForImage(forInstances: instances, from: handler)
        return pixelBufferToFloatGrid(maskPixelBuffer, targetWidth: width, targetHeight: height)
    }

    private static func pixelBufferToFloatGrid(_ buffer: CVPixelBuffer, targetWidth: Int, targetHeight: Int) -> [[Float]] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let srcW = CVPixelBufferGetWidth(buffer)
        let srcH = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return Array(repeating: Array(repeating: 0, count: targetWidth), count: targetHeight)
        }

        var grid = Array(repeating: Array(repeating: Float(0), count: targetWidth), count: targetHeight)
        let format = CVPixelBufferGetPixelFormatType(buffer)

        for y in 0 ..< targetHeight {
            let sy = min(srcH - 1, Int((Double(y) + 0.5) * Double(srcH) / Double(targetHeight)))
            for x in 0 ..< targetWidth {
                let sx = min(srcW - 1, Int((Double(x) + 0.5) * Double(srcW) / Double(targetWidth)))
                let v: Float
                if format == kCVPixelFormatType_OneComponent32Float {
                    let row = base.advanced(by: sy * bytesPerRow).assumingMemoryBound(to: Float.self)
                    v = row[sx]
                } else if format == kCVPixelFormatType_OneComponent16Half {
                    let row = base.advanced(by: sy * bytesPerRow).assumingMemoryBound(to: UInt16.self)
                    v = Float(float16: row[sx])
                } else {
                    let row = base.advanced(by: sy * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                    v = Float(row[sx]) / 255.0
                }
                grid[y][x] = max(0, min(1, v))
            }
        }
        return grid
    }
}

enum VisionFoodSceneError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "לא ניתן לנתח את התמונה במכשיר."
        }
    }
}

private extension Float {
    init(float16 bits: UInt16) {
        // IEEE 754 half → float
        let sign = (bits & 0x8000) != 0
        let exp = Int((bits >> 10) & 0x1F)
        let frac = Int(bits & 0x03FF)
        let value: Float
        if exp == 0 {
            value = Float(frac) / 1024.0 * pow(2, -14)
        } else if exp == 31 {
            value = frac == 0 ? Float.infinity : Float.nan
        } else {
            value = (1.0 + Float(frac) / 1024.0) * pow(2, Float(exp - 15))
        }
        self = sign ? -value : value
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
