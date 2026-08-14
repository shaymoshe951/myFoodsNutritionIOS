import Foundation
import simd

/// Analyzes LiDAR depth data quality for food volume scanning.
/// Provides distance feedback and reliability scoring to guide the user.
enum ScanQualityAnalyzer {
    
    /// Real-time metrics computed each frame for live UI feedback.
    struct LiveMetrics: Equatable {
        /// Median depth in the center region of interest (meters).
        var medianDistanceM: Float
        /// Fraction of valid depth pixels in usable range (0...1).
        var depthCoverage: Float
        /// Number of valid depth points.
        var validPointCount: Int
        /// True if median distance is below minimum reliable range (~15cm).
        var isTooClose: Bool
        /// True if median distance is above maximum reliable range (~1.2m for food).
        var isTooFar: Bool
        /// Overall reliability score (0...1), composite of distance and coverage.
        var reliabilityScore: Float
        /// User-friendly guidance message in Hebrew.
        var guidanceMessage: String?
        /// Color indicator: green (good), yellow (marginal), red (poor).
        var indicatorColor: IndicatorColor
        
        enum IndicatorColor: Equatable {
            case green, yellow, red
        }
    }
    
    /// Post-capture quality assessment stored with results.
    struct CaptureQuality: Equatable {
        /// Median scan distance in centimeters.
        var medianDistanceCm: Double
        /// Fraction of depth pixels that were valid and in range (0...1).
        var depthCoverage: Float
        /// RANSAC plane fit quality - ratio of inliers (0...1).
        var planeFitQuality: Float
        /// Number of valid depth points used.
        var validPointCount: Int
        /// Overall reliability score (0...1).
        var reliabilityScore: Float
        /// True if any part of the scan was unreliable (too close/far/sparse).
        var hasReliabilityWarning: Bool
        /// Warning message for user, if any.
        var warningMessage: String?
    }
    
    // MARK: - Configuration
    
    /// Minimum reliable distance for LiDAR (meters).
    static let minReliableDistanceM: Float = 0.15
    /// Maximum reliable distance for food scanning (meters).
    static let maxReliableDistanceM: Float = 1.2
    /// Optimal distance range for best accuracy.
    static let optimalMinDistanceM: Float = 0.25
    static let optimalMaxDistanceM: Float = 0.60
    /// Minimum depth coverage for reliable scan.
    static let minDepthCoverage: Float = 0.3
    /// Minimum valid points for reliable scan.
    static let minValidPoints: Int = 500
    
    // MARK: - Live Analysis
    
    /// Compute real-time quality metrics from a depth frame.
    /// - Parameters:
    ///   - depthMeters: Row-major depth values in meters.
    ///   - width: Depth map width.
    ///   - height: Depth map height.
    ///   - centerROIFraction: Fraction of image to use as center ROI (0.4 = center 40%).
    /// - Returns: Live metrics for UI display.
    static func analyzeLive(
        depthMeters: [Float],
        width: Int,
        height: Int,
        centerROIFraction: Float = 0.4
    ) -> LiveMetrics {
        let totalPixels = width * height
        guard totalPixels > 0, depthMeters.count == totalPixels else {
            return LiveMetrics(
                medianDistanceM: 0,
                depthCoverage: 0,
                validPointCount: 0,
                isTooClose: false,
                isTooFar: true,
                reliabilityScore: 0,
                guidanceMessage: "אין נתוני עומק",
                indicatorColor: .red
            )
        }
        
        // Define center ROI
        let roiMarginX = Int(Float(width) * (1 - centerROIFraction) / 2)
        let roiMarginY = Int(Float(height) * (1 - centerROIFraction) / 2)
        let roiMinX = roiMarginX
        let roiMaxX = width - roiMarginX
        let roiMinY = roiMarginY
        let roiMaxY = height - roiMarginY
        
        // Collect valid depths in center ROI
        var centerDepths: [Float] = []
        centerDepths.reserveCapacity((roiMaxX - roiMinX) * (roiMaxY - roiMinY))
        
        var totalValidCount = 0
        var tooCloseCount = 0
        var tooFarCount = 0
        
        for y in 0 ..< height {
            for x in 0 ..< width {
                let z = depthMeters[y * width + x]
                let isInROI = x >= roiMinX && x < roiMaxX && y >= roiMinY && y < roiMaxY
                
                if z.isFinite && z > 0.01 {
                    if z < minReliableDistanceM {
                        tooCloseCount += 1
                    } else if z > maxReliableDistanceM {
                        tooFarCount += 1
                    } else {
                        totalValidCount += 1
                        if isInROI {
                            centerDepths.append(z)
                        }
                    }
                }
            }
        }
        
        // Compute median distance in center ROI
        let medianDistance: Float
        if centerDepths.isEmpty {
            medianDistance = 0
        } else {
            let sorted = centerDepths.sorted()
            medianDistance = sorted[sorted.count / 2]
        }
        
        // Compute coverage
        let usablePixels = totalPixels - tooCloseCount - tooFarCount
        let depthCoverage = Float(totalValidCount) / Float(max(1, usablePixels))
        
        // Determine distance status
        let isTooClose = medianDistance > 0 && medianDistance < minReliableDistanceM
        let isTooFar = medianDistance == 0 || medianDistance > maxReliableDistanceM
        let isOptimalDistance = medianDistance >= optimalMinDistanceM && medianDistance <= optimalMaxDistanceM
        
        // Compute reliability score
        let distanceScore: Float
        if medianDistance == 0 {
            distanceScore = 0
        } else if isOptimalDistance {
            distanceScore = 1.0
        } else if medianDistance < minReliableDistanceM {
            distanceScore = max(0, medianDistance / minReliableDistanceM * 0.5)
        } else if medianDistance > maxReliableDistanceM {
            distanceScore = max(0, 1.0 - (medianDistance - maxReliableDistanceM) / 0.5)
        } else if medianDistance < optimalMinDistanceM {
            let t = (medianDistance - minReliableDistanceM) / (optimalMinDistanceM - minReliableDistanceM)
            distanceScore = 0.5 + t * 0.5
        } else {
            let t = (medianDistance - optimalMaxDistanceM) / (maxReliableDistanceM - optimalMaxDistanceM)
            distanceScore = 1.0 - t * 0.3
        }
        
        let coverageScore = min(1.0, depthCoverage / minDepthCoverage)
        let pointsScore = min(1.0, Float(totalValidCount) / Float(minValidPoints))
        
        let reliabilityScore = distanceScore * 0.5 + coverageScore * 0.3 + pointsScore * 0.2
        
        // Generate guidance message and color
        let (message, color) = generateGuidance(
            medianDistance: medianDistance,
            isTooClose: isTooClose,
            isTooFar: isTooFar,
            depthCoverage: depthCoverage,
            validPointCount: totalValidCount,
            tooCloseRatio: Float(tooCloseCount) / Float(max(1, totalPixels)),
            reliabilityScore: reliabilityScore
        )
        
        return LiveMetrics(
            medianDistanceM: medianDistance,
            depthCoverage: depthCoverage,
            validPointCount: totalValidCount,
            isTooClose: isTooClose,
            isTooFar: isTooFar,
            reliabilityScore: reliabilityScore,
            guidanceMessage: message,
            indicatorColor: color
        )
    }
    
    // MARK: - Post-Capture Analysis
    
    /// Compute quality assessment after capture, including plane fit quality.
    /// - Parameters:
    ///   - depthMeters: Row-major depth values in meters.
    ///   - width: Depth map width.
    ///   - height: Depth map height.
    ///   - intrinsics: Camera intrinsics for 3D projection.
    ///   - foodPixelCount: Number of pixels identified as food (from volume estimation).
    /// - Returns: Capture quality assessment.
    static func analyzeCapture(
        depthMeters: [Float],
        width: Int,
        height: Int,
        intrinsics: FoodVolumeEstimator.Intrinsics,
        foodPixelCount: Int
    ) -> CaptureQuality {
        let live = analyzeLive(depthMeters: depthMeters, width: width, height: height)
        
        // Estimate plane fit quality by computing inlier ratio
        let planeFitQuality = estimatePlaneFitQuality(
            depthMeters: depthMeters,
            width: width,
            height: height,
            intrinsics: intrinsics
        )
        
        // Combine into capture quality
        let overallScore = live.reliabilityScore * 0.6 + planeFitQuality * 0.4
        
        // Determine if there's a warning
        let hasWarning = live.isTooClose || live.isTooFar || 
                         live.depthCoverage < minDepthCoverage ||
                         planeFitQuality < 0.5 ||
                         overallScore < 0.6
        
        let warningMessage: String?
        if live.isTooClose {
            warningMessage = "הסריקה קרובה מדי – הדיוק עלול להיות נמוך"
        } else if live.isTooFar {
            warningMessage = "הסריקה רחוקה מדי – הדיוק עלול להיות נמוך"
        } else if live.depthCoverage < minDepthCoverage {
            warningMessage = "כיסוי עומק חלקי – חלק מהמזון לא נסרק"
        } else if planeFitQuality < 0.5 {
            warningMessage = "זיהוי שולחן חלש – וודאו משטח שטוח"
        } else if overallScore < 0.6 {
            warningMessage = "איכות סריקה בינונית"
        } else {
            warningMessage = nil
        }
        
        return CaptureQuality(
            medianDistanceCm: Double(live.medianDistanceM) * 100,
            depthCoverage: live.depthCoverage,
            planeFitQuality: planeFitQuality,
            validPointCount: live.validPointCount,
            reliabilityScore: overallScore,
            hasReliabilityWarning: hasWarning,
            warningMessage: warningMessage
        )
    }
    
    // MARK: - Private Helpers
    
    private static func generateGuidance(
        medianDistance: Float,
        isTooClose: Bool,
        isTooFar: Bool,
        depthCoverage: Float,
        validPointCount: Int,
        tooCloseRatio: Float,
        reliabilityScore: Float
    ) -> (String?, LiveMetrics.IndicatorColor) {
        
        // Priority 1: Distance issues
        if isTooClose || tooCloseRatio > 0.3 {
            return ("קרוב מדי – הרחיקו את המכשיר", .red)
        }
        
        if isTooFar || medianDistance == 0 {
            return ("רחוק מדי – קרבו את המכשיר", .red)
        }
        
        // Priority 2: Coverage issues
        if depthCoverage < 0.15 {
            return ("נתוני עומק חלשים – נסו תאורה טובה יותר", .red)
        }
        
        if validPointCount < 200 {
            return ("מעט נקודות – כוונו למזון", .red)
        }
        
        // Priority 3: Marginal conditions
        if medianDistance < optimalMinDistanceM {
            return ("קצת קרוב – הרחיקו מעט", .yellow)
        }
        
        if medianDistance > optimalMaxDistanceM {
            return ("קצת רחוק – קרבו מעט", .yellow)
        }
        
        if depthCoverage < minDepthCoverage {
            return ("כיסוי עומק חלקי", .yellow)
        }
        
        // Good conditions
        if reliabilityScore >= 0.8 {
            return ("מרחק מצוין", .green)
        }
        
        return ("מרחק תקין", .green)
    }
    
    private static func estimatePlaneFitQuality(
        depthMeters: [Float],
        width: Int,
        height: Int,
        intrinsics: FoodVolumeEstimator.Intrinsics
    ) -> Float {
        // Build 3D points
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
        
        guard points.count > 100 else { return 0 }
        
        // Simple RANSAC to estimate plane inlier ratio
        let iterations = 60
        let inlierThreshold: Float = 0.008
        var bestInlierCount = 0
        let n = points.count
        
        for _ in 0 ..< iterations {
            let i0 = Int.random(in: 0 ..< n)
            let i1 = Int.random(in: 0 ..< n)
            let i2 = Int.random(in: 0 ..< n)
            guard i0 != i1, i1 != i2, i0 != i2 else { continue }
            
            let a = points[i0]
            let b = points[i1]
            let c = points[i2]
            
            let normal = simd_normalize(simd_cross(b - a, c - a))
            guard simd_length(normal) > 0.001 else { continue }
            let d = -simd_dot(normal, a)
            
            var inlierCount = 0
            for p in points {
                let dist = abs(simd_dot(normal, p) + d)
                if dist <= inlierThreshold {
                    inlierCount += 1
                }
            }
            
            bestInlierCount = max(bestInlierCount, inlierCount)
        }
        
        return Float(bestInlierCount) / Float(n)
    }
}
