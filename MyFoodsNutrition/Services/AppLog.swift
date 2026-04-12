import Foundation
import os

/// Unified logging for debugging (see Console.app / Xcode console). Subsystem = bundle id.
enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "MyFoodsNutrition"

    static let api = Logger(subsystem: subsystem, category: "API")
    static let sync = Logger(subsystem: subsystem, category: "Sync")
}
