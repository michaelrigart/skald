import os

public enum PlatformLog {
    public static let engine = Logger(subsystem: "com.michaelrigart.skald", category: "engine")
    public static let spelling = Logger(subsystem: "com.michaelrigart.skald", category: "spelling")
    public static let access = Logger(subsystem: "com.michaelrigart.skald", category: "access")
    public static let probe = Logger(subsystem: "com.michaelrigart.skald", category: "probe")
    public static let eval = Logger(subsystem: "com.michaelrigart.skald", category: "eval")
}
