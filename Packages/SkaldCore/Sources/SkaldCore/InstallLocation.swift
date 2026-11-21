import Foundation

/// Where Skald may check text from. The Accessibility grant belongs to the bundle in `/Applications`, so a copy
/// anywhere else would never be trusted.
public enum InstallLocation {
    public static func isSupported(bundlePath: String) -> Bool {
        URL(fileURLWithPath: bundlePath).standardizedFileURL.deletingLastPathComponent().path == "/Applications"
    }
}
