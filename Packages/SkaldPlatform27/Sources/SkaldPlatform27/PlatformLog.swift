import os
import SkaldCore

public enum PlatformLog {
    public static let engine = Logger(subsystem: SkaldCore.bundleID, category: "engine")
    public static let spelling = Logger(subsystem: SkaldCore.bundleID, category: "spelling")
    public static let access = Logger(subsystem: SkaldCore.bundleID, category: "access")
    public static let probe = Logger(subsystem: SkaldCore.bundleID, category: "probe")
    public static let eval = Logger(subsystem: SkaldCore.bundleID, category: "eval")
}
