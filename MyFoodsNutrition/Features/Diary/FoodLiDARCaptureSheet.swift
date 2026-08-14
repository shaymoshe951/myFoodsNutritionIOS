import ARKit
import SceneKit
import SwiftUI
import UIKit
import simd

struct FoodDepthCaptureResult: Equatable {
    var colorImage: UIImage
    var items: [FoodVolumeItem]
    var visionLabels: [VisionFoodSceneAnalyzer.Classification]
    var tableDetected: Bool
    /// Scan quality assessment - nil if not computed.
    var scanQuality: ScanQualityAnalyzer.CaptureQuality?
    /// Documents debug folder for this scan (`FoodVolumeScans/...`), if persistence succeeded.
    var debugScanDirectoryURL: URL?
    /// Height-above-table heatmap (0…max cm) with food mask — debug UI.
    var heightDebugImage: UIImage?

    var totalVolumeMl: Double { items.reduce(0) { $0 + $1.volumeMl } }
}

/// Captures one LiDAR scene-depth frame, segments food with Vision, estimates volume above the table plane.
struct FoodLiDARCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onCapture: (FoodDepthCaptureResult) -> Void

    @StateObject private var model = FoodLiDARCaptureModel()
    @State private var isProcessing = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ZStack {
                FoodARSCNView(model: model)
                    .ignoresSafeArea()

                VStack {
                    // Live scan quality indicator at top
                    if let quality = model.liveQuality {
                        ScanQualityIndicatorView(metrics: quality)
                            .padding(.top, 60)
                            .padding(.horizontal)
                    }
                    
                    Spacer()
                    Text("כוונו מעל המזון על שולחן שטוח. צלחת/קערה יוסרו כשאפשר; כמה פריטים → נפח לכל אחד.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .padding()

                    if let errorText {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }

                    Button {
                        Task { await capture() }
                    } label: {
                        if isProcessing {
                            ProgressView()
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                        } else {
                            Label("צלם נפח", systemImage: "cube.transparent")
                                .font(.headline)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isProcessing || !model.isReady || !isScanQualityAcceptable)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("סריקת נפח (LiDAR)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("ביטול") { dismiss() }
                }
            }
        }
    }
    
    private var isScanQualityAcceptable: Bool {
        guard let quality = model.liveQuality else { return true }
        return quality.indicatorColor != .red
    }

    private func capture() async {
        isProcessing = true
        errorText = nil
        defer { isProcessing = false }
        do {
            let result = try await model.captureFoodVolume()
            onCapture(result)
            dismiss()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Scan Quality Indicator

private struct ScanQualityIndicatorView: View {
    let metrics: ScanQualityAnalyzer.LiveMetrics
    
    var body: some View {
        VStack(spacing: 8) {
            // Distance and guidance
            HStack(spacing: 12) {
                // Color indicator circle
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 16, height: 16)
                    .shadow(color: indicatorColor.opacity(0.5), radius: 4)
                
                VStack(alignment: .leading, spacing: 2) {
                    // Distance display
                    if metrics.medianDistanceM > 0 {
                        Text(distanceText)
                            .font(.subheadline.monospacedDigit())
                            .fontWeight(.medium)
                    }
                    
                    // Guidance message
                    if let message = metrics.guidanceMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(guidanceTextColor)
                    }
                }
                
                Spacer()
                
                // Reliability score bar
                VStack(alignment: .trailing, spacing: 2) {
                    Text("איכות")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.secondary.opacity(0.3))
                            
                            RoundedRectangle(cornerRadius: 3)
                                .fill(reliabilityBarColor)
                                .frame(width: geo.size.width * CGFloat(metrics.reliabilityScore))
                        }
                    }
                    .frame(width: 60, height: 6)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .animation(.easeInOut(duration: 0.2), value: metrics.indicatorColor)
    }
    
    private var distanceText: String {
        let cm = Int(metrics.medianDistanceM * 100)
        return "\(cm) ס״מ"
    }
    
    private var indicatorColor: Color {
        switch metrics.indicatorColor {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        }
    }
    
    private var guidanceTextColor: Color {
        switch metrics.indicatorColor {
        case .green: return .secondary
        case .yellow: return .orange
        case .red: return .red
        }
    }
    
    private var reliabilityBarColor: Color {
        if metrics.reliabilityScore >= 0.7 {
            return .green
        } else if metrics.reliabilityScore >= 0.4 {
            return .yellow
        } else {
            return .red
        }
    }
}

// MARK: - AR view

private struct FoodARSCNView: UIViewRepresentable {
    @ObservedObject var model: FoodLiDARCaptureModel

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.delegate = context.coordinator
        model.attach(session: view.session)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    final class Coordinator: NSObject, ARSCNViewDelegate {
        let model: FoodLiDARCaptureModel
        init(model: FoodLiDARCaptureModel) { self.model = model }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let sceneView = renderer as? ARSCNView,
                  let frame = sceneView.session.currentFrame
            else { return }
            Task { @MainActor in
                model.handle(frame: frame)
            }
        }
    }
}

// MARK: - Model

@MainActor
final class FoodLiDARCaptureModel: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var liveQuality: ScanQualityAnalyzer.LiveMetrics?

    private(set) weak var session: ARSession?
    private var latestFrame: ARFrame?
    private var lastQualityUpdate: Date = .distantPast
    private let qualityUpdateInterval: TimeInterval = 0.15

    static var isLiDARSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    func attach(session: ARSession) {
        self.session = session
        guard Self.isLiDARSupported else {
            isReady = false
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics.insert(.sceneDepth)
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func handle(frame: ARFrame) {
        latestFrame = frame
        isReady = frame.sceneDepth != nil
        
        // Update live quality metrics at throttled rate
        let now = Date()
        if now.timeIntervalSince(lastQualityUpdate) >= qualityUpdateInterval,
           let sceneDepth = frame.sceneDepth {
            lastQualityUpdate = now
            updateLiveQuality(depthBuffer: sceneDepth.depthMap)
        }
    }
    
    private func updateLiveQuality(depthBuffer: CVPixelBuffer) {
        let depthW = CVPixelBufferGetWidth(depthBuffer)
        let depthH = CVPixelBufferGetHeight(depthBuffer)
        let depth = Self.floatDepthMeters(from: depthBuffer)
        
        liveQuality = ScanQualityAnalyzer.analyzeLive(
            depthMeters: depth,
            width: depthW,
            height: depthH
        )
    }

    func captureFoodVolume() async throws -> FoodDepthCaptureResult {
        guard Self.isLiDARSupported else { throw FoodLiDARCaptureError.unsupported }
        guard let frame = latestFrame else { throw FoodLiDARCaptureError.noFrame }
        guard let sceneDepth = frame.sceneDepth else { throw FoodLiDARCaptureError.noDepth }

        // Sensor-frame RGB matches `sceneDepth` / intrinsics (landscape buffer).
        // Display-oriented RGB is only for UI / AI photo — never for mask↔depth.
        let colorSensor = try Self.uiImage(from: frame.capturedImage, displayOriented: false)
        let colorDisplay = try Self.uiImage(from: frame.capturedImage, displayOriented: true)

        let depthBuffer = sceneDepth.depthMap
        let depthW = CVPixelBufferGetWidth(depthBuffer)
        let depthH = CVPixelBufferGetHeight(depthBuffer)
        let depth = Self.floatDepthMeters(from: depthBuffer)

        let colorW = CVPixelBufferGetWidth(frame.capturedImage)
        let colorH = CVPixelBufferGetHeight(frame.capturedImage)
        let sx = Float(depthW) / Float(max(colorW, 1))
        let sy = Float(depthH) / Float(max(colorH, 1))
        let m = frame.camera.intrinsics
        let K = FoodVolumeEstimator.Intrinsics(
            fx: m.columns.0.x * sx,
            fy: m.columns.1.y * sy,
            cx: m.columns.2.x * sx,
            cy: m.columns.2.y * sy
        )

        let segmented = try await FoodItemVolumeSegmenter.analyze(
            colorImage: colorSensor,
            depthMeters: depth,
            depthWidth: depthW,
            depthHeight: depthH,
            intrinsics: K
        )
        guard !segmented.items.isEmpty else {
            throw FoodVolumeEstimator.EstimateError.noFoodPixels
        }
        
        // Compute scan quality assessment
        let totalFoodPixels = segmented.items.reduce(0) { $0 + $1.foodPixelCount }
        let scanQuality = ScanQualityAnalyzer.analyzeCapture(
            depthMeters: depth,
            width: depthW,
            height: depthH,
            intrinsics: K,
            foodPixelCount: totalFoodPixels
        )

        let heightDebugImage = FoodVolumeHeightDebugRenderer.render(
            depthMeters: depth,
            width: depthW,
            height: depthH,
            intrinsics: K,
            mask01: segmented.combinedFoodMask01
        )

        let debugURL = FoodVolumeScanDebugStore.saveCaptureIfPossible(
            .init(
                colorImage: colorDisplay,
                colorSensorImage: colorSensor,
                depthMeters: depth,
                depthWidth: depthW,
                depthHeight: depthH,
                intrinsics: K,
                segmented: segmented,
                scanQuality: scanQuality,
                heightDebugImage: heightDebugImage
            )
        )

        return FoodDepthCaptureResult(
            colorImage: colorDisplay,
            items: segmented.items,
            visionLabels: segmented.sceneClassifications,
            tableDetected: segmented.tableDetected,
            scanQuality: scanQuality,
            debugScanDirectoryURL: debugURL,
            heightDebugImage: heightDebugImage
        )
    }

    /// - Parameter displayOriented: When true, rotates the ARKit buffer for portrait UI
    ///   (`.right`). When false, keeps sensor orientation so RGB aligns with depth.
    private static func uiImage(from pixelBuffer: CVPixelBuffer, displayOriented: Bool) throws -> UIImage {
        var ci = CIImage(cvPixelBuffer: pixelBuffer)
        if displayOriented {
            ci = ci.oriented(.right)
        }
        let context = CIContext(options: nil)
        guard let cg = context.createCGImage(ci, from: ci.extent) else {
            throw FoodLiDARCaptureError.noFrame
        }
        return UIImage(cgImage: cg)
    }

    private static func floatDepthMeters(from buffer: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return Array(repeating: 0, count: w * h)
        }
        var out = Array(repeating: Float(0), count: w * h)
        for y in 0 ..< h {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float.self)
            for x in 0 ..< w {
                out[y * w + x] = row[x]
            }
        }
        return out
    }
}

enum FoodLiDARCaptureError: LocalizedError {
    case noFrame
    case noDepth
    case unsupported

    var errorDescription: String? {
        switch self {
        case .noFrame:
            return "אין פריים מוכן עדיין. נסו שוב בעוד רגע."
        case .noDepth:
            return "אין נתוני עומק LiDAR בפריים הזה."
        case .unsupported:
            return "המכשיר לא תומך ב־LiDAR scene depth."
        }
    }
}

// MARK: - Height + mask debug heatmap

/// Builds a debug heatmap of height-above-table with the food mask outline.
enum FoodVolumeHeightDebugRenderer {

    /// - Parameters:
    ///   - clipMaxHeightCm: Upper end of the color scale. If `nil`, uses the max
    ///     positive height in the frame (at least 1 cm).
    static func render(
        depthMeters: [Float],
        width: Int,
        height: Int,
        intrinsics: FoodVolumeEstimator.Intrinsics,
        mask01: [Float]?,
        maskThreshold: Float = 0.35,
        clipMaxHeightCm: Double? = nil,
        scale: Int = 4
    ) -> UIImage? {
        guard width > 0, height > 0, depthMeters.count == width * height else { return nil }
        if let mask01, mask01.count != width * height { return nil }

        guard let plane = fitTablePlane(
            depthMeters: depthMeters,
            width: width,
            height: height,
            intrinsics: intrinsics
        ) else { return nil }

        var heightCm = [Float](repeating: .nan, count: width * height)
        var maxH: Float = 0
        for v in 0 ..< height {
            for u in 0 ..< width {
                let i = v * width + u
                let z = depthMeters[i]
                guard z.isFinite, z > 0.05, z < 3.5 else { continue }
                let x = (Float(u) - intrinsics.cx) * z / intrinsics.fx
                let y = (Float(v) - intrinsics.cy) * z / intrinsics.fy
                let p = SIMD3<Float>(x, y, z)
                let h = dot(plane.normal, p) + plane.d
                let cm = h * 100
                heightCm[i] = cm
                if h > 0, h < 0.35 {
                    maxH = max(maxH, cm)
                }
            }
        }

        let hiCm = Float(clipMaxHeightCm ?? Double(max(1, maxH)))
        guard hiCm > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0 ..< (width * height) {
            let o = i * 4
            let cm = heightCm[i]
            if !cm.isFinite {
                pixels[o] = 20; pixels[o + 1] = 20; pixels[o + 2] = 20; pixels[o + 3] = 255
                continue
            }
            if cm < 0 {
                pixels[o] = 10; pixels[o + 1] = 10; pixels[o + 2] = 40; pixels[o + 3] = 255
                continue
            }
            let t = max(0, min(1, cm / hiCm))
            let (r, g, b) = turboLike(t)
            pixels[o] = r; pixels[o + 1] = g; pixels[o + 2] = b; pixels[o + 3] = 255
        }

        if let mask01 {
            for v in 0 ..< height {
                for u in 0 ..< width {
                    let i = v * width + u
                    guard mask01[i] >= maskThreshold else { continue }
                    let o = i * 4
                    let a: Float = 0.30
                    pixels[o] = UInt8(Float(pixels[o]) * (1 - a) + 255 * a)
                    pixels[o + 1] = UInt8(Float(pixels[o + 1]) * (1 - a) * 0.85)
                    pixels[o + 2] = UInt8(Float(pixels[o + 2]) * (1 - a) * 0.85)

                    let edge =
                        (u == 0 || mask01[i - 1] < maskThreshold)
                        || (u == width - 1 || mask01[i + 1] < maskThreshold)
                        || (v == 0 || mask01[i - width] < maskThreshold)
                        || (v == height - 1 || mask01[i + width] < maskThreshold)
                    if edge {
                        pixels[o] = 255; pixels[o + 1] = 255; pixels[o + 2] = 0
                    }
                }
            }
        }

        guard let base = rgbaImage(pixels: pixels, width: width, height: height) else { return nil }
        let scaledW = max(1, width * max(1, scale))
        let scaledH = max(1, height * max(1, scale))
        let scaled = resized(base, width: scaledW, height: scaledH) ?? base

        let titleH = 28
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: scaledW, height: scaledH + titleH), format: format)
        return renderer.image { ctx in
            UIColor(white: 0.12, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: scaledW, height: scaledH + titleH))
            scaled.draw(in: CGRect(x: 0, y: titleH, width: scaledW, height: scaledH))
            let title = String(format: "Height above table 0…%.1f cm + mask", hiCm)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: UIColor.white,
            ]
            (title as NSString).draw(at: CGPoint(x: 8, y: 6), withAttributes: attrs)
        }
    }

    private struct Plane {
        var normal: SIMD3<Float>
        var d: Float
    }

    private static func fitTablePlane(
        depthMeters: [Float],
        width: Int,
        height: Int,
        intrinsics: FoodVolumeEstimator.Intrinsics
    ) -> Plane? {
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(width * height / 4)
        for v in 0 ..< height {
            for u in 0 ..< width {
                let z = depthMeters[v * width + u]
                guard z.isFinite, z > 0.05, z < 3.5 else { continue }
                let x = (Float(u) - intrinsics.cx) * z / intrinsics.fx
                let y = (Float(v) - intrinsics.cy) * z / intrinsics.fy
                points.append(SIMD3(x, y, z))
            }
        }
        guard points.count > 200 else { return nil }

        var best: Plane?
        var bestCount = 0
        let n = points.count
        for _ in 0 ..< 160 {
            let i0 = Int.random(in: 0 ..< n)
            let i1 = Int.random(in: 0 ..< n)
            let i2 = Int.random(in: 0 ..< n)
            guard i0 != i1, i1 != i2, i0 != i2 else { continue }
            let a = points[i0], b = points[i1], c = points[i2]
            let raw = cross(b - a, c - a)
            let len = length(raw)
            guard len > 1e-8 else { continue }
            var normal = raw / len
            var d = -dot(normal, a)
            if normal.z > 0 {
                normal = -normal
                d = -d
            }
            var count = 0
            for p in points where abs(dot(normal, p) + d) <= 0.005 {
                count += 1
            }
            if count > bestCount {
                bestCount = count
                best = Plane(normal: normal, d: d)
            }
        }
        guard var plane = best, bestCount > 80 else { return nil }
        if plane.normal.z > 0 {
            plane.normal = -plane.normal
            plane.d = -plane.d
        }
        return plane
    }

    private static func turboLike(_ t: Float) -> (UInt8, UInt8, UInt8) {
        let r = UInt8(max(0, min(255, Int((1.5 * t - 0.2) * 255))))
        let g = UInt8(max(0, min(255, Int((1.5 - abs(2 * t - 1) * 1.5) * 255))))
        let b = UInt8(max(0, min(255, Int((1.2 - 1.5 * t) * 255))))
        return (r, g, b)
    }

    private static func rgbaImage(pixels: [UInt8], width: Int, height: Int) -> UIImage? {
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        guard let cg = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }
        return UIImage(cgImage: cg)
    }

    private static func resized(_ image: UIImage, width: Int, height: Int) -> UIImage? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
}
