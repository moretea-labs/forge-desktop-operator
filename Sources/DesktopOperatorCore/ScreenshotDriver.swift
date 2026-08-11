import CoreGraphics
import Foundation

public enum ScreenshotDriver {
    public static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    public static func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public static func capture(scope: String, windowId: UInt32?, label: String?) throws -> ScreenshotResult {
        guard screenRecordingGranted else {
            let permission = DesktopPermissions.screenRecording(granted: false)
            throw PluginError(
                code: "SCREEN_RECORDING_NOT_GRANTED",
                message: "Grant Screen & System Audio Recording access to Forge Desktop Operator (com.moretea.forge.desktop-operator) in System Settings > Privacy & Security",
                retryable: true,
                domain: "tcc",
                details: try? JSONValue.encode(permission)
            )
        }
        try PluginPaths.ensureRuntimeDirectories()
        let sanitized = sanitize(label ?? scope)
        let fileName = "\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))-\(sanitized)-\(UUID().uuidString.prefix(8)).png"
        let path = URL(fileURLWithPath: PluginPaths.artifactDirectory).appendingPathComponent(fileName).path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        if scope == "window" {
            guard let windowId else { throw PluginError.invalidArguments("window screenshot requires window_id or a session with an on-screen window") }
            process.arguments = ["-x", "-l", String(windowId), path]
        } else {
            process.arguments = ["-x", path]
        }
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw PluginError(code: "SCREENSHOT_FAILED", message: error.localizedDescription, retryable: true, domain: "capture")
        }
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PluginError(code: "SCREENSHOT_FAILED", message: message ?? "screencapture exited with status \(process.terminationStatus)", retryable: true, domain: "capture")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        return ScreenshotResult(artifactPath: path, scope: scope, windowId: windowId, capturedAt: Date(), byteCount: bytes)
    }

    private static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        return String(mapped).prefix(80).lowercased()
    }
}
