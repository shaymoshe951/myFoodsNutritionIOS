import CoreVideo
import Foundation
import UIKit
import Vision

/// One edible region after dropping plate/bowl/tableware, with measured volume.
struct FoodVolumeItem: Equatable, Identifiable {
    var id: String
    var label: String
    var labelConfidence: Float
    var volumeMl: Double
    var estimatedGrams: Int
    var densityGPerMl: Double
    var footprintLengthCm: Double
    var footprintWidthCm: Double
    var medianHeightCm: Double
}

enum FoodTablewareLexicon {
    /// Vision / English labels that must not contribute volume (plate, bowl, utensils, table…).
    static func isNonFood(_ identifier: String) -> Bool {
        let s = identifier.lowercased()
        let tokens = [
            "plate", "bowl", "dish", "saucer", "tray", "platter",
            "cup", "mug", "glass", "bottle", "jar", "can",
            "fork", "knife", "spoon", "chopsticks", "napkin", "utensil", "cutlery",
            "table", "desk", "countertop", "dining table", "tablecloth",
            "person", "hand", "finger", "arm",
        ]
        return tokens.contains { s == $0 || s.contains($0) }
    }
}

/// Splits a LiDAR frame into labeled food volumes: instance masks → classify → drop tableware → height+volume.
enum FoodItemVolumeSegmenter {

    struct Output: Equatable {
        var items: [FoodVolumeItem]
        var sceneClassifications: [VisionFoodSceneAnalyzer.Classification]
        var tableDetected: Bool
        /// Union soft mask of kept food instances (depth resolution), for debugging/UI.
        var combinedFoodMask01: [Float]?
        var depthWidth: Int
        var depthHeight: Int
    }

    static func analyze(
        colorImage: UIImage,
        depthMeters: [Float],
        depthWidth: Int,
        depthHeight: Int,
        intrinsics: FoodVolumeEstimator.Intrinsics
    ) async throws -> Output {
        guard let cgImage = colorImage.cgImage else {
            throw VisionFoodSceneError.invalidImage
        }
        let orientation = CGImagePropertyOrientation(colorImage.imageOrientation)

        return try await Task.detached(priority: .userInitiated) {
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            let classifyScene = VNClassifyImageRequest()
            let segment = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([classifyScene, segment])

            let sceneLabels: [VisionFoodSceneAnalyzer.Classification] = (classifyScene.results ?? [])
                .prefix(12)
                .map { .init(identifier: $0.identifier, confidence: $0.confidence) }
            let tableDetected = sceneLabels.contains {
                VisionFoodSceneAnalyzer.isTableLike($0.identifier) && $0.confidence >= 0.15
            }

            guard let obs = segment.results?.first else {
                // No instances: single height-only food volume with scene label.
                return try Self.singleBlobFallback(
                    sceneLabels: sceneLabels,
                    tableDetected: tableDetected,
                    depthMeters: depthMeters,
                    depthWidth: depthWidth,
                    depthHeight: depthHeight,
                    intrinsics: intrinsics
                )
            }

            let instances = obs.allInstances
            var items: [FoodVolumeItem] = []
            var combined = Array(repeating: Float(0), count: depthWidth * depthHeight)

            if instances.isEmpty {
                return try Self.singleBlobFallback(
                    sceneLabels: sceneLabels,
                    tableDetected: tableDetected,
                    depthMeters: depthMeters,
                    depthWidth: depthWidth,
                    depthHeight: depthHeight,
                    intrinsics: intrinsics
                )
            }

            for (idx, instanceIndex) in instances.enumerated() {
                let maskBuffer = try obs.generateScaledMaskForImage(
                    forInstances: IndexSet(integer: instanceIndex),
                    from: handler
                )
                let rgbMask = Self.pixelBufferToFloatGrid(maskBuffer, width: cgImage.width, height: cgImage.height)
                let depthMask = Self.resample(rgbMask, toWidth: depthWidth, height: depthHeight)

                guard let crop = Self.maskedCrop(cgImage: cgImage, softMask: rgbMask, threshold: 0.35) else {
                    continue
                }
                let labels = try Self.classify(crop)
                let top = labels.first
                let labelId = top?.identifier ?? "food"
                if FoodTablewareLexicon.isNonFood(labelId) {
                    // Also skip if any high-confidence tableware label ranks above food-like.
                    continue
                }
                if let strongWare = labels.first(where: { $0.confidence >= 0.35 && FoodTablewareLexicon.isNonFood($0.identifier) }),
                   (top?.confidence ?? 0) < strongWare.confidence + 0.05 {
                    continue
                }

                do {
                    let volume = try FoodVolumeEstimator.estimateVolume(
                        depthMeters: depthMeters,
                        width: depthWidth,
                        height: depthHeight,
                        intrinsics: intrinsics,
                        mask01: depthMask,
                        maskThreshold: 0.35,
                        minHeightMeters: 0.008
                    )
                    let density = VisionFoodSceneAnalyzer.suggestedDensityGPerMl(from: labels)
                    let grams = max(1, Int((volume.volumeMl * density).rounded()))
                    let conf = top?.confidence ?? 0
                    items.append(
                        FoodVolumeItem(
                            id: "inst-\(idx)",
                            label: Self.preferredFoodLabel(labels),
                            labelConfidence: conf,
                            volumeMl: volume.volumeMl,
                            estimatedGrams: grams,
                            densityGPerMl: density,
                            footprintLengthCm: volume.footprintLengthCm,
                            footprintWidthCm: volume.footprintWidthCm,
                            medianHeightCm: volume.medianHeightCm
                        )
                    )
                    for i in depthMask.indices {
                        combined[i] = max(combined[i], depthMask[i])
                    }
                } catch {
                    continue
                }
            }

            // Merge tiny fragments with same label if needed later; for now keep separate.
            items.sort { $0.volumeMl > $1.volumeMl }

            if items.isEmpty {
                return try Self.singleBlobFallback(
                    sceneLabels: sceneLabels,
                    tableDetected: tableDetected,
                    depthMeters: depthMeters,
                    depthWidth: depthWidth,
                    depthHeight: depthHeight,
                    intrinsics: intrinsics
                )
            }

            return Output(
                items: items,
                sceneClassifications: sceneLabels,
                tableDetected: tableDetected,
                combinedFoodMask01: combined,
                depthWidth: depthWidth,
                depthHeight: depthHeight
            )
        }.value
    }

    // MARK: - Helpers

    private static func singleBlobFallback(
        sceneLabels: [VisionFoodSceneAnalyzer.Classification],
        tableDetected: Bool,
        depthMeters: [Float],
        depthWidth: Int,
        depthHeight: Int,
        intrinsics: FoodVolumeEstimator.Intrinsics
    ) throws -> Output {
        if let top = sceneLabels.first, FoodTablewareLexicon.isNonFood(top.identifier) {
            throw FoodVolumeEstimator.EstimateError.noFoodPixels
        }
        let volume = try FoodVolumeEstimator.estimateVolume(
            depthMeters: depthMeters,
            width: depthWidth,
            height: depthHeight,
            intrinsics: intrinsics,
            mask01: nil,
            minHeightMeters: 0.008
        )
        let density = VisionFoodSceneAnalyzer.suggestedDensityGPerMl(from: sceneLabels)
        let grams = max(1, Int((volume.volumeMl * density).rounded()))
        let item = FoodVolumeItem(
            id: "scene-0",
            label: preferredFoodLabel(sceneLabels),
            labelConfidence: sceneLabels.first?.confidence ?? 0,
            volumeMl: volume.volumeMl,
            estimatedGrams: grams,
            densityGPerMl: density,
            footprintLengthCm: volume.footprintLengthCm,
            footprintWidthCm: volume.footprintWidthCm,
            medianHeightCm: volume.medianHeightCm
        )
        return Output(
            items: [item],
            sceneClassifications: sceneLabels,
            tableDetected: tableDetected,
            combinedFoodMask01: nil,
            depthWidth: depthWidth,
            depthHeight: depthHeight
        )
    }

    private static func preferredFoodLabel(_ labels: [VisionFoodSceneAnalyzer.Classification]) -> String {
        let foodish = labels.filter {
            VisionFoodSceneAnalyzer.isFoodLike($0.identifier) && !FoodTablewareLexicon.isNonFood($0.identifier)
        }
        if let specific = foodish.first(where: { $0.identifier.lowercased() != "food" }) {
            return specific.identifier
        }
        return foodish.first?.identifier ?? labels.first?.identifier ?? "food"
    }

    private static func classify(_ image: UIImage) throws -> [VisionFoodSceneAnalyzer.Classification] {
        guard let cg = image.cgImage else { return [] }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let req = VNClassifyImageRequest()
        try handler.perform([req])
        return (req.results ?? []).prefix(8).map {
            .init(identifier: $0.identifier, confidence: $0.confidence)
        }
    }

    private static func maskedCrop(cgImage: CGImage, softMask: [[Float]], threshold: Float) -> UIImage? {
        let w = cgImage.width
        let h = cgImage.height
        guard softMask.count == h, softMask.first?.count == w else { return nil }
        var minX = w, minY = h, maxX = 0, maxY = 0
        var any = false
        for y in 0 ..< h {
            for x in 0 ..< w where softMask[y][x] >= threshold {
                any = true
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard any, maxX > minX, maxY > minY else { return nil }
        let pad = 4
        let rect = CGRect(
            x: max(0, minX - pad),
            y: max(0, minY - pad),
            width: min(w - 1, maxX + pad) - max(0, minX - pad) + 1,
            height: min(h - 1, maxY + pad) - max(0, minY - pad) + 1
        )
        guard let cropped = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped)
    }

    private static func resample(_ mask: [[Float]], toWidth width: Int, height: Int) -> [Float] {
        guard !mask.isEmpty, let first = mask.first, !first.isEmpty else {
            return Array(repeating: 0, count: width * height)
        }
        let srcH = mask.count
        let srcW = first.count
        var out = Array(repeating: Float(0), count: width * height)
        for y in 0 ..< height {
            let sy = min(srcH - 1, Int((Double(y) + 0.5) * Double(srcH) / Double(height)))
            for x in 0 ..< width {
                let sx = min(srcW - 1, Int((Double(x) + 0.5) * Double(srcW) / Double(width)))
                out[y * width + x] = mask[sy][sx]
            }
        }
        return out
    }

    private static func pixelBufferToFloatGrid(_ buffer: CVPixelBuffer, width: Int, height: Int) -> [[Float]] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let srcW = CVPixelBufferGetWidth(buffer)
        let srcH = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return Array(repeating: Array(repeating: 0, count: width), count: height)
        }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        var grid = Array(repeating: Array(repeating: Float(0), count: width), count: height)
        for y in 0 ..< height {
            let sy = min(srcH - 1, Int((Double(y) + 0.5) * Double(srcH) / Double(height)))
            for x in 0 ..< width {
                let sx = min(srcW - 1, Int((Double(x) + 0.5) * Double(srcW) / Double(width)))
                let v: Float
                if format == kCVPixelFormatType_OneComponent32Float {
                    let row = base.advanced(by: sy * bytesPerRow).assumingMemoryBound(to: Float.self)
                    v = row[sx]
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
