import ARKit
import SceneKit
import SwiftUI
import UIKit

struct FoodDepthCaptureResult: Equatable {
    var colorImage: UIImage
    var items: [FoodVolumeItem]
    var visionLabels: [VisionFoodSceneAnalyzer.Classification]
    var tableDetected: Bool
    /// Scan quality assessment - nil if not computed.
    var scanQuality: ScanQualityAnalyzer.CaptureQuality?

    var totalVolumeMl: Double { items.reduce(0) { $0 + $1.volumeMl } }
    var totalEstimatedGrams: Int { items.reduce(0) { $0 + $1.estimatedGrams } }
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
            guard let frame = model.session?.currentFrame else { return }
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

        let colorImage = try Self.uiImage(from: frame.capturedImage)

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
            colorImage: colorImage,
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

        return FoodDepthCaptureResult(
            colorImage: colorImage,
            items: segmented.items,
            visionLabels: segmented.sceneClassifications,
            tableDetected: segmented.tableDetected,
            scanQuality: scanQuality
        )
    }

    private static func uiImage(from pixelBuffer: CVPixelBuffer) throws -> UIImage {
        let ci = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
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
