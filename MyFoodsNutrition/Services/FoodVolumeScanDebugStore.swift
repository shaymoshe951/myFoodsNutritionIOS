import Foundation
import UIKit
import os

/// Persists each LiDAR food-volume scan under Documents for offline debug pull
/// (`FoodVolumeScans/<scanId>/`). Visible via Files / Xcode device container.
enum FoodVolumeScanDebugStore {
    private static let rootFolderName = "FoodVolumeScans"
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "MyFoodsNutrition",
        category: "VolumeScanDebug"
    )

    struct CaptureArtifacts {
        /// Portrait / display-oriented RGB (for humans + AI request photo).
        var colorImage: UIImage
        /// Sensor-frame RGB aligned with `depth.bin` / `food_mask.bin` (same axes as LiDAR).
        var colorSensorImage: UIImage?
        var depthMeters: [Float]
        var depthWidth: Int
        var depthHeight: Int
        var intrinsics: FoodVolumeEstimator.Intrinsics
        var segmented: FoodItemVolumeSegmenter.Output
        var scanQuality: ScanQualityAnalyzer.CaptureQuality?
        var heightDebugImage: UIImage?
    }

    /// Documents/FoodVolumeScans
    static var rootDirectoryURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(rootFolderName, isDirectory: true)
    }

    /// Ensures the debug root folder exists so the app appears under Files → On My iPhone.
    static func ensureRootDirectoryExists() {
        do {
            try FileManager.default.createDirectory(at: rootDirectoryURL, withIntermediateDirectories: true)
        } catch {
            log.error("Failed to create FoodVolumeScans root: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes color, depth, mask, intermediate + result JSON. Returns the scan folder URL.
    static func saveCapture(_ artifacts: CaptureArtifacts) throws -> URL {
        let folder = try makeScanDirectory()
        let encoder = makeEncoder()

        if let jpeg = artifacts.colorImage.jpegData(compressionQuality: 0.92) {
            try jpeg.write(to: folder.appendingPathComponent("color.jpg"), options: .atomic)
        }
        if let sensor = artifacts.colorSensorImage,
           let jpeg = sensor.jpegData(compressionQuality: 0.92) {
            try jpeg.write(to: folder.appendingPathComponent("color_sensor.jpg"), options: .atomic)
        }

        try writeFloatBin(artifacts.depthMeters, to: folder.appendingPathComponent("depth.bin"))
        try writeJSON(
            DepthMetaDTO(
                width: artifacts.depthWidth,
                height: artifacts.depthHeight,
                format: "float32_le",
                unit: "meters",
                rowMajor: true,
                intrinsics: IntrinsicsDTO(artifacts.intrinsics)
            ),
            to: folder.appendingPathComponent("depth.json"),
            encoder: encoder
        )
        if let preview = depthPreviewImage(
            depthMeters: artifacts.depthMeters,
            width: artifacts.depthWidth,
            height: artifacts.depthHeight
        ), let png = preview.pngData() {
            try png.write(to: folder.appendingPathComponent("depth_preview.png"), options: .atomic)
        }

        if let mask = artifacts.segmented.combinedFoodMask01 {
            try writeFloatBin(mask, to: folder.appendingPathComponent("food_mask.bin"))
            if let preview = softMaskPreviewImage(
                mask01: mask,
                width: artifacts.segmented.depthWidth,
                height: artifacts.segmented.depthHeight
            ), let png = preview.pngData() {
                try png.write(to: folder.appendingPathComponent("food_mask_preview.png"), options: .atomic)
            }
        }

        if let heightDebug = artifacts.heightDebugImage, let png = heightDebug.pngData() {
            try png.write(to: folder.appendingPathComponent("height_mask_overlay.png"), options: .atomic)
        }

        try writeJSON(
            IntermediateDTO(
                tableDetected: artifacts.segmented.tableDetected,
                visionLabels: artifacts.segmented.sceneClassifications.map(LabelDTO.init),
                scanQuality: artifacts.scanQuality.map(ScanQualityDTO.init),
                depthWidth: artifacts.segmented.depthWidth,
                depthHeight: artifacts.segmented.depthHeight,
                hasCombinedFoodMask: artifacts.segmented.combinedFoodMask01 != nil
            ),
            to: folder.appendingPathComponent("intermediate.json"),
            encoder: encoder
        )

        try writeJSON(
            ResultDTO(
                totalVolumeMl: artifacts.segmented.items.reduce(0) { $0 + $1.volumeMl },
                items: artifacts.segmented.items.map(VolumeItemDTO.init)
            ),
            to: folder.appendingPathComponent("result.json"),
            encoder: encoder
        )

        try writeJSON(
            MetaDTO(
                createdAt: ISO8601DateFormatter().string(from: Date()),
                scanId: folder.lastPathComponent,
                colorJpg: "displayOrientedPortrait",
                colorSensorJpg: artifacts.colorSensorImage == nil ? nil : "sensorFrameAlignedWithDepthAndMask",
                depthAndMask: "ARKitSensorFrame"
            ),
            to: folder.appendingPathComponent("meta.json"),
            encoder: encoder
        )

        log.info("Saved volume scan debug folder \(folder.lastPathComponent, privacy: .public)")
        return folder
    }

    /// Appends AI hints + nutrition results (and optional JPEG sent to the API).
    static func saveAIAnalysis(
        scanDirectory: URL,
        hints: FoodImageOnDeviceHints?,
        results: [FoodImageNutritionResult],
        jpegSentToAPI: Data?
    ) throws {
        let encoder = makeEncoder()
        if let hints {
            try writeJSON(HintsDTO(hints), to: scanDirectory.appendingPathComponent("ai_hints.json"), encoder: encoder)
        }
        if let jpegSentToAPI {
            try jpegSentToAPI.write(
                to: scanDirectory.appendingPathComponent("ai_request.jpg"),
                options: .atomic
            )
        }
        try writeJSON(
            FinalDTO(
                analyzedAt: ISO8601DateFormatter().string(from: Date()),
                items: results.map(NutritionResultDTO.init)
            ),
            to: scanDirectory.appendingPathComponent("final.json"),
            encoder: encoder
        )
        log.info("Saved AI analysis into \(scanDirectory.lastPathComponent, privacy: .public)")
    }

    /// Best-effort capture save; returns nil on failure so food logging is not blocked.
    static func saveCaptureIfPossible(_ artifacts: CaptureArtifacts) -> URL? {
        do {
            return try saveCapture(artifacts)
        } catch {
            log.error("Volume scan debug save failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func saveAIAnalysisIfPossible(
        scanDirectory: URL?,
        hints: FoodImageOnDeviceHints?,
        results: [FoodImageNutritionResult],
        jpegSentToAPI: Data?
    ) {
        guard let scanDirectory else { return }
        do {
            try saveAIAnalysis(
                scanDirectory: scanDirectory,
                hints: hints,
                results: results,
                jpegSentToAPI: jpegSentToAPI
            )
        } catch {
            log.error("Volume scan AI debug save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private

    private static func makeScanDirectory() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: rootDirectoryURL, withIntermediateDirectories: true)
        let stamp = Self.folderDateFormatter.string(from: Date())
        let id = "\(stamp)-\(UUID().uuidString.prefix(8))"
        let folder = rootDirectoryURL.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static let folderDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private static func writeFloatBin(_ values: [Float], to url: URL) throws {
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: url, options: .atomic)
    }

    private static func depthPreviewImage(depthMeters: [Float], width: Int, height: Int) -> UIImage? {
        guard width > 0, height > 0, depthMeters.count == width * height else { return nil }
        var valid: [Float] = []
        valid.reserveCapacity(depthMeters.count / 4)
        for z in depthMeters where z.isFinite && z > 0.05 && z < 3.5 {
            valid.append(z)
        }
        guard let minZ = valid.min(), let maxZ = valid.max(), maxZ > minZ else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let span = maxZ - minZ
        for i in depthMeters.indices {
            let z = depthMeters[i]
            guard z.isFinite, z > 0.05, z < 3.5 else {
                pixels[i] = 0
                continue
            }
            let t = (z - minZ) / span
            pixels[i] = UInt8(max(0, min(255, Int((1 - t) * 255))))
        }
        return grayImage(pixels: pixels, width: width, height: height)
    }

    private static func softMaskPreviewImage(mask01: [Float], width: Int, height: Int) -> UIImage? {
        guard width > 0, height > 0, mask01.count == width * height else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        for i in mask01.indices {
            let v = max(0, min(1, mask01[i]))
            pixels[i] = UInt8(v * 255)
        }
        return grayImage(pixels: pixels, width: width, height: height)
    }

    private static func grayImage(pixels: [UInt8], width: Int, height: Int) -> UIImage? {
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        guard let cg = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Codable DTOs

private struct MetaDTO: Encodable {
    var createdAt: String
    var scanId: String
    var colorJpg: String
    var colorSensorJpg: String?
    var depthAndMask: String
}

private struct IntrinsicsDTO: Encodable {
    var fx: Float
    var fy: Float
    var cx: Float
    var cy: Float

    init(_ k: FoodVolumeEstimator.Intrinsics) {
        fx = k.fx
        fy = k.fy
        cx = k.cx
        cy = k.cy
    }
}

private struct DepthMetaDTO: Encodable {
    var width: Int
    var height: Int
    var format: String
    var unit: String
    var rowMajor: Bool
    var intrinsics: IntrinsicsDTO
}

private struct LabelDTO: Encodable {
    var identifier: String
    var confidence: Float

    init(_ c: VisionFoodSceneAnalyzer.Classification) {
        identifier = c.identifier
        confidence = c.confidence
    }
}

private struct ScanQualityDTO: Encodable {
    var medianDistanceCm: Double
    var depthCoverage: Float
    var planeFitQuality: Float
    var validPointCount: Int
    var reliabilityScore: Float
    var hasReliabilityWarning: Bool
    var warningMessage: String?

    init(_ q: ScanQualityAnalyzer.CaptureQuality) {
        medianDistanceCm = q.medianDistanceCm
        depthCoverage = q.depthCoverage
        planeFitQuality = q.planeFitQuality
        validPointCount = q.validPointCount
        reliabilityScore = q.reliabilityScore
        hasReliabilityWarning = q.hasReliabilityWarning
        warningMessage = q.warningMessage
    }
}

private struct IntermediateDTO: Encodable {
    var tableDetected: Bool
    var visionLabels: [LabelDTO]
    var scanQuality: ScanQualityDTO?
    var depthWidth: Int
    var depthHeight: Int
    var hasCombinedFoodMask: Bool
}

private struct VolumeItemDTO: Encodable {
    var id: String
    var label: String
    var labelConfidence: Float
    var volumeMl: Double
    var footprintLengthCm: Double
    var footprintWidthCm: Double
    var medianHeightCm: Double
    var foodPixelCount: Int

    init(_ item: FoodVolumeItem) {
        id = item.id
        label = item.label
        labelConfidence = item.labelConfidence
        volumeMl = item.volumeMl
        footprintLengthCm = item.footprintLengthCm
        footprintWidthCm = item.footprintWidthCm
        medianHeightCm = item.medianHeightCm
        foodPixelCount = item.foodPixelCount
    }
}

private struct ResultDTO: Encodable {
    var totalVolumeMl: Double
    var items: [VolumeItemDTO]
}

private struct HintsDTO: Encodable {
    var visionLabels: [LabelHintDTO]
    var tableDetected: Bool?
    var volumeItems: [VolumeItemHintDTO]
    var volumeMl: Double?

    init(_ hints: FoodImageOnDeviceHints) {
        visionLabels = hints.visionLabels.map { LabelHintDTO(id: $0.id, confidence: $0.confidence) }
        tableDetected = hints.tableDetected
        volumeItems = hints.volumeItems.map {
            VolumeItemHintDTO(label: $0.label, confidence: $0.confidence, volumeMl: $0.volumeMl)
        }
        volumeMl = hints.volumeMl
    }
}

private struct LabelHintDTO: Encodable {
    var id: String
    var confidence: Float
}

private struct VolumeItemHintDTO: Encodable {
    var label: String
    var confidence: Float
    var volumeMl: Double
}

private struct NutritionResultDTO: Encodable {
    var itemName: String
    var quantityGrams: Int
    var nutrientsPer100g: [String: Double]
    var notes: String?
    var sourceLabel: String?
    var volumeMl: Double?

    init(_ r: FoodImageNutritionResult) {
        itemName = r.itemName
        quantityGrams = r.quantityGrams
        nutrientsPer100g = r.nutrientsPer100g
        notes = r.notes
        sourceLabel = r.sourceLabel
        volumeMl = r.volumeMl
    }
}

private struct FinalDTO: Encodable {
    var analyzedAt: String
    var items: [NutritionResultDTO]
}
