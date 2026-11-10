import os
import SkaldCore

nonisolated enum Log {
    static let app = Logger(subsystem: SkaldCore.bundleID, category: "app")
    static let ui = Logger(subsystem: SkaldCore.bundleID, category: "ui")
}
