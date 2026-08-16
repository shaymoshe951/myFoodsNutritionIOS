import Foundation
import simd

/// Single-view food volume from a depth map: fit table plane → integrate height × footprint (optionally masked).
enum FoodVolumeEstimator {

    struct Intrinsics: Equatable {
        var fx: Float
        var fy: Float
        var cx: Float
        var cy: Float
    }

    struct Result: Equatable {
        /// Cubic centimeters / milliliters.
        var volumeMl: Double
        var footprintWidthCm: Double
        var footprintLengthCm: Double
        var medianHeightCm: Double
        var maxHeightCm: Double
        var foodPixelCount: Int
        /// True if any contributing pixel is on the depth-map border (box wall / lid).
        var touchesImageBorder: Bool
    }

    struct Island: Equatable {
        var result: Result
        /// Depth-grid indices (`v * width + u`) contributing to this island.
        var pixelIndices: [Int]
    }

    enum EstimateError: LocalizedError {
        case insufficientDepth
        case planeFitFailed
        case noFoodPixels

        var errorDescription: String? {
            switch self {
            case .insufficientDepth:
                return "אין מספיק נקודות עומק לחישוב נפח."
            case .planeFitFailed:
                return "לא הצלחתי לזהות את מישור השולחן."
            case .noFoodPixels:
                return "לא זוהה מזון מעל השולחן (סגמנטציה/גובה)."
            }
        }
    }

    /// One contributing depth pixel (quad origin) after mask + height gates.
    private struct Contrib {
        var u: Int
        var v: Int
        var height: Float
        var volumeM3: Float
        var footPoint: SIMD3<Float>
    }

    /// - Parameters:
    ///   - depthMeters: row-major depth in meters; non-finite / ≤0 ignored.
    ///   - width/height: depth map size.
    ///   - mask01: optional soft mask same size (values in 0...1). If nil, uses height threshold only.
    ///   - maskThreshold: minimum mask value to include a pixel when mask is provided.
    ///   - minHeightMeters: food must be at least this high above the table.
    ///   - minIslandPixels: drop connected fragments smaller than this. Island split runs only when `mask01` is set.
    static func estimateVolumeIslands(
        depthMeters: [Float],
        width: Int,
        height: Int,
        intrinsics: Intrinsics,
        mask01: [Float]? = nil,
        maskThreshold: Float = 0.35,
        minHeightMeters: Float = 0.008,
        minIslandPixels: Int = 16,
        ransacIterations: Int = 120,
        planeInlierMeters: Float = 0.005
    ) throws -> [Island] {
        precondition(depthMeters.count == width * height)
        if let mask01 {
            precondition(mask01.count == width * height)
        }

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
        guard points.count > 200 else { throw EstimateError.insufficientDepth }

        guard var plane = fitPlaneRANSAC(
            points: points,
            iterations: ransacIterations,
            inlierThreshold: planeInlierMeters
        ) else {
            throw EstimateError.planeFitFailed
        }
        // Orient normal toward camera (origin).
        if plane.normal.z > 0 {
            plane.normal = -plane.normal
            plane.d = -plane.d
        }

        var contribs: [Contrib] = []
        contribs.reserveCapacity(1024)

        for v in 0 ..< (height - 1) {
            for u in 0 ..< (width - 1) {
                let i = v * width + u
                if let mask01, mask01[i] < maskThreshold { continue }

                guard let p = point(u: u, v: v, width: width, depth: depthMeters, K: intrinsics),
                      let pRight = point(u: u + 1, v: v, width: width, depth: depthMeters, K: intrinsics),
                      let pDown = point(u: u, v: v + 1, width: width, depth: depthMeters, K: intrinsics)
                else { continue }

                let h = signedDistance(p, plane: plane)
                guard h > minHeightMeters, h < 0.35 else { continue }

                // Project neighbors onto plane for footprint parallelogram area.
                let a = projectOntoPlane(p, plane: plane)
                let b = projectOntoPlane(pRight, plane: plane)
                let c = projectOntoPlane(pDown, plane: plane)
                let area = length(cross(b - a, c - a))
                guard area.isFinite, area > 0 else { continue }

                contribs.append(
                    Contrib(u: u, v: v, height: h, volumeM3: area * h, footPoint: a)
                )
            }
        }

        guard !contribs.isEmpty else { throw EstimateError.noFoodPixels }

        // Height islands only when a Vision instance mask labeled the region.
        if mask01 == nil {
            return [islandFromContribs(contribs, width: width, height: height)]
        }

        let groups = connectedComponents(contribs, width: width, height: height)
        var islands: [Island] = []
        islands.reserveCapacity(groups.count)
        for members in groups {
            guard members.count >= minIslandPixels else { continue }
            islands.append(islandFromContribs(members.map { contribs[$0] }, width: width, height: height))
        }
        guard !islands.isEmpty else { throw EstimateError.noFoodPixels }
        islands.sort { $0.result.volumeMl > $1.result.volumeMl }
        return islands
    }

    // MARK: - Plane

    private struct Plane {
        var normal: SIMD3<Float>
        var d: Float // n·x + d = 0 with ||n||=1
    }

    private static func fitPlaneRANSAC(
        points: [SIMD3<Float>],
        iterations: Int,
        inlierThreshold: Float
    ) -> Plane? {
        guard points.count >= 3 else { return nil }
        var best: Plane?
        var bestCount = 0
        let n = points.count

        for _ in 0 ..< iterations {
            let i0 = Int.random(in: 0 ..< n)
            let i1 = Int.random(in: 0 ..< n)
            let i2 = Int.random(in: 0 ..< n)
            guard i0 != i1, i1 != i2, i0 != i2 else { continue }
            guard let plane = planeFrom(points[i0], points[i1], points[i2]) else { continue }
            var count = 0
            for p in points where abs(signedDistance(p, plane: plane)) <= inlierThreshold {
                count += 1
            }
            if count > bestCount {
                bestCount = count
                best = plane
            }
        }
        guard var plane = best, bestCount > 80 else { return nil }

        // Refine with SVD-ish: mean + covariance of inliers (power iteration on normal).
        var inliers: [SIMD3<Float>] = []
        inliers.reserveCapacity(bestCount)
        for p in points where abs(signedDistance(p, plane: plane)) <= inlierThreshold * 1.5 {
            inliers.append(p)
        }
        if let refined = refinePlane(inliers) {
            plane = refined
        }
        return plane
    }

    private static func planeFrom(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Plane? {
        let n = cross(b - a, c - a)
        let len = length(n)
        guard len > 1e-8 else { return nil }
        let normal = n / len
        let d = -dot(normal, a)
        return Plane(normal: normal, d: d)
    }

    private static func refinePlane(_ points: [SIMD3<Float>]) -> Plane? {
        guard points.count >= 3 else { return nil }
        var mean = SIMD3<Float>(repeating: 0)
        for p in points { mean += p }
        mean /= Float(points.count)

        var cxx: Float = 0, cxy: Float = 0, cxz: Float = 0
        var cyy: Float = 0, cyz: Float = 0, czz: Float = 0
        for p in points {
            let d = p - mean
            cxx += d.x * d.x
            cxy += d.x * d.y
            cxz += d.x * d.z
            cyy += d.y * d.y
            cyz += d.y * d.z
            czz += d.z * d.z
        }

        // Smallest eigenvector via inverse iteration-ish: power on (I + cov) inverse approx — use simple cross of two principal dirs.
        // Power iteration on covariance for largest, then deflate — keep it simple: start from (cxx,cxy,cxz) cross.
        var v = SIMD3<Float>(cxz, cyz, czz + 1e-6)
        for _ in 0 ..< 16 {
            let cv = SIMD3(
                cxx * v.x + cxy * v.y + cxz * v.z,
                cxy * v.x + cyy * v.y + cyz * v.z,
                cxz * v.x + cyz * v.y + czz * v.z
            )
            // We want smallest eigenvalue: v <- v - normalize(cov*v) style inverse free: use random and Gram-Schmidt against large ones.
            // Practical approach: normal ≈ normalize of cross of two large eigenvectors from cov*e1, cov*e2.
            _ = cv
            break
        }

        // Build two vectors in plane from covariance action, normal = cross.
        var e1 = SIMD3<Float>(1, 0, 0)
        e1 = SIMD3(cxx * e1.x + cxy * e1.y + cxz * e1.z,
                   cxy * e1.x + cyy * e1.y + cyz * e1.z,
                   cxz * e1.x + cyz * e1.y + czz * e1.z)
        if length(e1) < 1e-8 { e1 = SIMD3(0, 1, 0) }
        e1 = normalize(e1)
        var e2 = SIMD3<Float>(0, 1, 0)
        e2 = SIMD3(cxx * e2.x + cxy * e2.y + cxz * e2.z,
                   cxy * e2.x + cyy * e2.y + cyz * e2.z,
                   cxz * e2.x + cyz * e2.y + czz * e2.z)
        e2 = e2 - dot(e2, e1) * e1
        if length(e2) < 1e-8 { e2 = cross(e1, SIMD3(0, 0, 1)) }
        e2 = normalize(e2)
        var n = cross(e1, e2)
        let nl = length(n)
        guard nl > 1e-8 else { return nil }
        n /= nl
        let d = -dot(n, mean)
        return Plane(normal: n, d: d)
    }

    private static func signedDistance(_ p: SIMD3<Float>, plane: Plane) -> Float {
        dot(plane.normal, p) + plane.d
    }

    private static func projectOntoPlane(_ p: SIMD3<Float>, plane: Plane) -> SIMD3<Float> {
        p - signedDistance(p, plane: plane) * plane.normal
    }

    private static func point(u: Int, v: Int, width: Int, depth: [Float], K: Intrinsics) -> SIMD3<Float>? {
        let z = depth[v * width + u]
        guard z.isFinite, z > 0.05, z < 3.5 else { return nil }
        let x = (Float(u) - K.cx) * z / K.fx
        let y = (Float(v) - K.cy) * z / K.fy
        return SIMD3(x, y, z)
    }

    private static func connectedComponents(
        _ contribs: [Contrib],
        width: Int,
        height: Int
    ) -> [[Int]] {
        var grid = [Int](repeating: -1, count: width * height)
        for (idx, c) in contribs.enumerated() {
            grid[c.v * width + c.u] = idx
        }
        var seen = [Bool](repeating: false, count: contribs.count)
        var islands: [[Int]] = []
        islands.reserveCapacity(4)
        for start in contribs.indices where !seen[start] {
            var stack = [start]
            seen[start] = true
            var members: [Int] = []
            members.reserveCapacity(64)
            while let cur = stack.popLast() {
                members.append(cur)
                let u = contribs[cur].u
                let v = contribs[cur].v
                let neighbors = [(u - 1, v), (u + 1, v), (u, v - 1), (u, v + 1)]
                for (nu, nv) in neighbors {
                    guard nu >= 0, nv >= 0, nu < width, nv < height else { continue }
                    let gi = grid[nv * width + nu]
                    if gi >= 0, !seen[gi] {
                        seen[gi] = true
                        stack.append(gi)
                    }
                }
            }
            islands.append(members)
        }
        return islands
    }

    private static func islandFromContribs(_ contribs: [Contrib], width: Int, height: Int) -> Island {
        Island(
            result: resultFromContribs(contribs, width: width, height: height),
            pixelIndices: contribs.map { $0.v * width + $0.u }
        )
    }

    private static func resultFromContribs(_ contribs: [Contrib], width: Int, height: Int) -> Result {
        var volumeM3: Float = 0
        var heights: [Float] = []
        var foodPoints: [SIMD3<Float>] = []
        heights.reserveCapacity(contribs.count)
        foodPoints.reserveCapacity(contribs.count)
        var touches = false
        let maxU = width - 2
        let maxV = height - 2
        for c in contribs {
            volumeM3 += c.volumeM3
            heights.append(c.height)
            foodPoints.append(c.footPoint)
            if c.u == 0 || c.v == 0 || c.u >= maxU || c.v >= maxV {
                touches = true
            }
        }
        heights.sort()
        let medianH = heights[heights.count / 2]
        let maxH = heights.last ?? medianH
        let (footW, footL) = footprintMeters(foodPoints)
        return Result(
            volumeMl: Double(volumeM3) * 1_000_000.0,
            footprintWidthCm: Double(min(footW, footL)) * 100.0,
            footprintLengthCm: Double(max(footW, footL)) * 100.0,
            medianHeightCm: Double(medianH) * 100.0,
            maxHeightCm: Double(maxH) * 100.0,
            foodPixelCount: heights.count,
            touchesImageBorder: touches
        )
    }

    private static func footprintMeters(_ points: [SIMD3<Float>]) -> (Float, Float) {
        guard points.count >= 2 else { return (0, 0) }
        var mean = SIMD3<Float>(repeating: 0)
        for p in points { mean += p }
        mean /= Float(points.count)
        // PCA in 3D then take two largest extents in plane — approximate with AABB after aligning to principal axes via simple 2D on XZ after rotating by normal is hard; use AABB extents of points.
        var minP = points[0]
        var maxP = points[0]
        for p in points {
            minP = simd_min(minP, p)
            maxP = simd_max(maxP, p)
        }
        let ext = maxP - minP
        let sorted = [ext.x, ext.y, ext.z].sorted()
        return (sorted[1], sorted[2])
    }
}
