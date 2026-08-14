import ARKit
import SceneKit
import SwiftUI
import UIKit

struct FoodDepthCaptureResult: Equatable {
    var colorImage: UIImage
    var items: [FoodVolumeItem]
    var visionLabels: [VisionFoodSceneAnalyzer.Classification]
    var tableDetected: Bool

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
                    .disabled(isProcessing || !model.isReady)
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

    private(set) weak var session: ARSession?
    private var latestFrame: ARFrame?

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

        return FoodDepthCaptureResult(
            colorImage: colorImage,
            items: segmented.items,
            visionLabels: segmented.sceneClassifications,
            tableDetected: segmented.tableDetected
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
