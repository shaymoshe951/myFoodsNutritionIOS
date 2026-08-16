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
                if let overlay = model.liveOverlay {
                    Image(uiImage: overlay)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea()
            .safeAreaInset(edge: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let quality = model.liveQuality {
                            ScanQualityIndicatorView(metrics: quality)
                        }
                        LiveVolumeSidebar(items: model.liveVolumeItems)
                    }
                    .padding(.horizontal, 12)
                }
                .safeAreaInset(edge: .bottom, spacing: 8) {
                    VStack(spacing: 10) {
                        Text("כוונו מעל המזון על שולחן שטוח. נפחים נמדדים לפי איי גובה; ה־AI ישאיר רק מזון (בלי קופסה/צלחת).")
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(10)
                            .frame(maxWidth: .infinity)
                            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))

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
                        .disabled(isProcessing || !model.isReady)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
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
                        .foregroundStyle(.white.opacity(0.8))
                    
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.25))
                        Capsule()
                            .fill(reliabilityBarColor)
                            .frame(width: 60 * CGFloat(max(0, min(1, metrics.reliabilityScore))))
                    }
                    .frame(width: 60, height: 6, alignment: .leading)
                    .clipped()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
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
        case .green: return .white.opacity(0.9)
        case .yellow: return .yellow
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

// MARK: - Live volume sidebar

private struct LiveVolumeSidebar: View {
    let items: [FoodVolumeItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if items.isEmpty {
                Text("אין מזון עדיין")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(LiveIslandPalette.color(index))
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.label)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text(String(format: "%.0f מ״ל", item.volumeMl))
                                .font(.caption.monospacedDigit())
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
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
    @Published private(set) var liveOverlay: UIImage?
    @Published private(set) var liveVolumeItems: [FoodVolumeItem] = []

    private(set) weak var session: ARSession?
    private var latestFrame: ARFrame?
    private var lastQualityUpdate: Date = .distantPast
    private let qualityUpdateInterval: TimeInterval = 0.15
    private var lastLiveAnalysis: Date = .distantPast
    private let liveAnalysisInterval: TimeInterval = 0.45
    private var isLiveAnalysisRunning = false

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
        maybeRunLiveVolumeAnalysis(frame: frame, now: now)
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

    private func maybeRunLiveVolumeAnalysis(frame: ARFrame, now: Date) {
        guard !isLiveAnalysisRunning else { return }
        guard now.timeIntervalSince(lastLiveAnalysis) >= liveAnalysisInterval else { return }
        guard let snapshot = try? Self.makeSnapshot(from: frame) else { return }

        isLiveAnalysisRunning = true
        lastLiveAnalysis = now
        Task {
            let segmented: FoodItemVolumeSegmenter.Output?
            do {
                segmented = try await FoodItemVolumeSegmenter.analyze(
                    colorImage: snapshot.colorSensor,
                    depthMeters: snapshot.depthMeters,
                    depthWidth: snapshot.depthWidth,
                    depthHeight: snapshot.depthHeight,
                    intrinsics: snapshot.intrinsics
                )
            } catch {
                segmented = nil
            }
            let overlay = segmented.flatMap {
                LiveIslandOverlayRenderer.render(
                    labelMap: $0.islandLabelMap,
                    width: $0.depthWidth,
                    height: $0.depthHeight,
                    displayOriented: true
                )
            }
            let items = segmented?.items.filter { !FoodTablewareLexicon.isNonFood($0.label) } ?? []
            await MainActor.run {
                self.isLiveAnalysisRunning = false
                if segmented != nil {
                    self.liveVolumeItems = items
                    self.liveOverlay = overlay
                }
            }
        }
    }

    func captureFoodVolume() async throws -> FoodDepthCaptureResult {
        guard Self.isLiDARSupported else { throw FoodLiDARCaptureError.unsupported }
        guard let frame = latestFrame else { throw FoodLiDARCaptureError.noFrame }
        let snapshot = try Self.makeSnapshot(from: frame)

        let segmented: FoodItemVolumeSegmenter.Output
        do {
            segmented = try await FoodItemVolumeSegmenter.analyze(
                colorImage: snapshot.colorSensor,
                depthMeters: snapshot.depthMeters,
                depthWidth: snapshot.depthWidth,
                depthHeight: snapshot.depthHeight,
                intrinsics: snapshot.intrinsics
            )
        } catch {
            segmented = FoodItemVolumeSegmenter.Output(
                items: [],
                sceneClassifications: [],
                tableDetected: false,
                combinedFoodMask01: nil,
                islandLabelMap: nil,
                depthWidth: snapshot.depthWidth,
                depthHeight: snapshot.depthHeight
            )
        }

        let totalFoodPixels = segmented.items.reduce(0) { $0 + $1.foodPixelCount }
        let scanQuality = ScanQualityAnalyzer.analyzeCapture(
            depthMeters: snapshot.depthMeters,
            width: snapshot.depthWidth,
            height: snapshot.depthHeight,
            intrinsics: snapshot.intrinsics,
            foodPixelCount: totalFoodPixels
        )

        let heightDebugImage = FoodVolumeHeightDebugRenderer.render(
            depthMeters: snapshot.depthMeters,
            width: snapshot.depthWidth,
            height: snapshot.depthHeight,
            intrinsics: snapshot.intrinsics,
            mask01: segmented.combinedFoodMask01
        )

        let debugURL = FoodVolumeScanDebugStore.saveCaptureIfPossible(
            .init(
                colorImage: snapshot.colorDisplay,
                colorSensorImage: snapshot.colorSensor,
                depthMeters: snapshot.depthMeters,
                depthWidth: snapshot.depthWidth,
                depthHeight: snapshot.depthHeight,
                intrinsics: snapshot.intrinsics,
                segmented: segmented,
                scanQuality: scanQuality,
                heightDebugImage: heightDebugImage
            )
        )

        return FoodDepthCaptureResult(
            colorImage: snapshot.colorDisplay,
            items: segmented.items,
            visionLabels: segmented.sceneClassifications,
            tableDetected: segmented.tableDetected,
            scanQuality: scanQuality,
            debugScanDirectoryURL: debugURL,
            heightDebugImage: heightDebugImage
        )
    }

    private struct CaptureSnapshot {
        var colorSensor: UIImage
        var colorDisplay: UIImage
        var depthMeters: [Float]
        var depthWidth: Int
        var depthHeight: Int
        var intrinsics: FoodVolumeEstimator.Intrinsics
    }

    /// Sensor-frame RGB matches `sceneDepth` / intrinsics (landscape buffer).
    /// Display-oriented RGB is only for UI / AI photo — never for mask↔depth.
    private static func makeSnapshot(from frame: ARFrame) throws -> CaptureSnapshot {
        guard let sceneDepth = frame.sceneDepth else { throw FoodLiDARCaptureError.noDepth }
        let colorSensor = try uiImage(from: frame.capturedImage, displayOriented: false)
        let colorDisplay = try uiImage(from: frame.capturedImage, displayOriented: true)
        let depthBuffer = sceneDepth.depthMap
        let depthW = CVPixelBufferGetWidth(depthBuffer)
        let depthH = CVPixelBufferGetHeight(depthBuffer)
        let depth = floatDepthMeters(from: depthBuffer)
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
        return CaptureSnapshot(
            colorSensor: colorSensor,
            colorDisplay: colorDisplay,
            depthMeters: depth,
            depthWidth: depthW,
            depthHeight: depthH,
            intrinsics: K
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

// MARK: - Live island overlay

enum LiveIslandPalette {
    private static let rgbValues: [(UInt8, UInt8, UInt8)] = [
        (0, 210, 255),
        (255, 70, 170),
        (255, 210, 0),
        (50, 230, 110),
        (255, 130, 40),
        (170, 90, 255),
    ]

    static func rgb(_ index: Int) -> (UInt8, UInt8, UInt8) {
        rgbValues[index % rgbValues.count]
    }

    static func color(_ index: Int) -> Color {
        let (r, g, b) = rgb(index)
        return Color(
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255
        )
    }
}

enum LiveIslandOverlayRenderer {
    static func render(
        labelMap: [UInt8]?,
        width: Int,
        height: Int,
        displayOriented: Bool
    ) -> UIImage? {
        guard width > 0, height > 0, let labelMap, labelMap.count == width * height else { return nil }
        guard labelMap.contains(where: { $0 != 0 }) else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let fillA: UInt8 = 110
        for v in 0 ..< height {
            for u in 0 ..< width {
                let i = v * width + u
                let label = labelMap[i]
                guard label > 0 else { continue }
                let (r, g, b) = LiveIslandPalette.rgb(Int(label) - 1)
                let edge =
                    (u == 0 || labelMap[i - 1] != label)
                    || (u == width - 1 || labelMap[i + 1] != label)
                    || (v == 0 || labelMap[i - width] != label)
                    || (v == height - 1 || labelMap[i + width] != label)
                let o = i * 4
                let a: UInt8 = edge ? 230 : fillA
                pixels[o] = UInt8((Int(r) * Int(a)) / 255)
                pixels[o + 1] = UInt8((Int(g) * Int(a)) / 255)
                pixels[o + 2] = UInt8((Int(b) * Int(a)) / 255)
                pixels[o + 3] = a
            }
        }

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
        if displayOriented {
            let oriented = CIImage(cgImage: cg).oriented(.right)
            let ctx = CIContext(options: [.useSoftwareRenderer: false])
            guard let rotated = ctx.createCGImage(oriented, from: oriented.extent) else {
                return UIImage(cgImage: cg)
            }
            return UIImage(cgImage: rotated, scale: 1, orientation: .up)
        }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
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
        let legendGap = 10
        let barW = 22
        let labelW = 52
        let legendW = legendGap + barW + 6 + labelW
        let canvasW = scaledW + legendW + 12
        let canvasH = scaledH + titleH
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvasW, height: canvasH), format: format)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            UIColor(white: 0.12, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))

            scaled.draw(in: CGRect(x: 8, y: titleH, width: scaledW, height: scaledH))

            let title = String(format: "Height above table 0…%.1f cm + mask", hiCm)
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: UIColor.white,
            ]
            (title as NSString).draw(at: CGPoint(x: 8, y: 6), withAttributes: titleAttrs)

            // Vertical color bar (top = max, bottom = 0).
            let barX = CGFloat(8 + scaledW + legendGap)
            let barY = CGFloat(titleH)
            let barRect = CGRect(x: barX, y: barY, width: CGFloat(barW), height: CGFloat(scaledH))
            for row in 0 ..< scaledH {
                let t = 1 - Float(row) / Float(max(scaledH - 1, 1))
                let (r, g, b) = turboLike(t)
                cg.setFillColor(UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1).cgColor)
                cg.fill(CGRect(x: barRect.minX, y: barRect.minY + CGFloat(row), width: barRect.width, height: 1))
            }
            UIColor.white.withAlphaComponent(0.55).setStroke()
            cg.setLineWidth(1)
            cg.stroke(barRect.insetBy(dx: 0.5, dy: 0.5))

            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: UIColor.white,
            ]
            let midCm = hiCm * 0.5
            let labels: [(String, CGFloat)] = [
                (String(format: "%.1f cm", hiCm), barY),
                (String(format: "%.1f cm", midCm), barY + CGFloat(scaledH) * 0.5 - 7),
                ("0 cm", barY + CGFloat(scaledH) - 14),
            ]
            let labelX = barX + CGFloat(barW) + 6
            for (text, y) in labels {
                (text as NSString).draw(at: CGPoint(x: labelX, y: y), withAttributes: labelAttrs)
            }
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
