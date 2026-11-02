import os

enum Log {
    static let app = Logger(subsystem: "com.michaelrigart.skald", category: "app")
    static let ui = Logger(subsystem: "com.michaelrigart.skald", category: "ui")
}
