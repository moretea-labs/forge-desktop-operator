import CoreGraphics
import Foundation
import ImageIO

public enum ScreenshotDriver {
    enum NativeCaptureTarget: Equatable {
        case display
        case window(UInt32)
    }

    static func resolveCaptureTarget(scope: String, windowId: UInt32?) throws -> NativeCaptureTarget {
        switch scope {
        case "window":
            guard let windowId else { throw PluginError.invalidArguments("window screenshot requires an exact window_id") }
            return .window(windowId)
        case "display":
            return .display
        default:
            throw PluginError.invalidArguments("screenshot scope must be display or window")
        }
    }
    public static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    public static func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public static func capture(scope: String, windowId: UInt32?, label: String?) throws -> ScreenshotResult {
        let target = try resolveCaptureTarget(scope: scope, windowId: windowId)
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
        let image: CGImage
        switch target {
        case .window(let exactWindowId):
            guard let captured = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                CGWindowID(exactWindowId),
                [.boundsIgnoreFraming, .bestResolution]
            ) else {
                throw PluginError(code: "SCREENSHOT_WINDOW_UNAVAILABLE", message: "CoreGraphics could not capture the requested window", retryable: true, domain: "capture")
            }
            image = captured
        case .display:
            guard let captured = CGWindowListCreateImage(
                .infinite,
                .optionOnScreenOnly,
                kCGNullWindowID,
                [.bestResolution]
            ) else {
                throw PluginError(code: "SCREENSHOT_FAILED", message: "CoreGraphics could not capture the on-screen desktop", retryable: true, domain: "capture")
            }
            image = captured
        }

        try PluginPaths.ensureRuntimeDirectories()
        let sanitized = sanitize(label ?? scope)
        let fileName = "\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))-\(sanitized)-\(UUID().uuidString.prefix(8)).png"
        let url = URL(fileURLWithPath: PluginPaths.artifactDirectory).appendingPathComponent(fileName)
        let data = try pngData(for: image)
        try data.write(to: url, options: [.atomic])
        return ScreenshotResult(artifactPath: url.path, scope: scope, windowId: windowId, capturedAt: Date(), byteCount: data.count)
    }

    static func captureRegionPNG(x: Int, y: Int, width: Int, height: Int) throws -> Data {
        guard screenRecordingGranted else {
            throw PluginError(
                code: "SCREEN_RECORDING_NOT_GRANTED",
                message: "Grant Screen & System Audio Recording access to Forge Desktop Operator (com.moretea.forge.desktop-operator) in System Settings > Privacy & Security",
                retryable: true,
                domain: "tcc",
                details: try? JSONValue.encode(DesktopPermissions.screenRecording(granted: false))
            )
        }
        let rect = CGRect(x: x, y: y, width: width, height: height)
        guard let image = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) else {
            throw PluginError(code: "SCREENSHOT_FAILED", message: "CoreGraphics could not capture the requested desktop region", retryable: true, domain: "capture")
        }
        return try pngData(for: image)
    }

    private static func pngData(for image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw PluginError(code: "SCREENSHOT_FAILED", message: "Could not create native PNG destination", retryable: true, domain: "capture")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PluginError(code: "SCREENSHOT_FAILED", message: "Could not finalize native PNG capture", retryable: true, domain: "capture")
        }
        return data as Data
    }

    private static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        return String(mapped).prefix(80).lowercased()
    }
}
