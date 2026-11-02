import os
import SkaldCore

enum Log {
    static let app = Logger(subsystem: SkaldCore.bundleID, category: "app")
    static let ui = Logger(subsystem: SkaldCore.bundleID, category: "ui")
}
