import Foundation
import Testing
@testable import DesktopOperatorCore

@Test func repositoryManifestMatchesRuntimeIdentity() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let root = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("forge-plugin.json"))
    let json = try JSONDecoder.repoHarness.decode(JSONValue.self, from: data)
    #expect(json["id"]?.stringValue == PluginManifest.current.id)
    #expect(json["version"]?.stringValue == PluginManifest.current.version)
    #expect(json["protocolVersion"]?.stringValue == PluginManifest.current.protocolVersion)
    #expect(json["scope"]?.stringValue == "controller")
    #expect(Set(json["actions"]?.arrayValue?.compactMap(\.stringValue) ?? []) == Set(PluginManifest.current.actions))
    #expect(Set(json["capabilities"]?.arrayValue?.compactMap(\.stringValue) ?? []) == Set(PluginManifest.current.capabilities))
    #expect(Set(ComputerProviderProtocol.allCapabilities).isSubset(of: Set(PluginManifest.current.capabilities)))
    #expect(PluginManifest.current.name == "Forge Desktop Operator")
    #expect(PluginManifest.current.capabilities.contains("desktop.clipboard"))
    #expect(Set(["desktop_clipboard_read", "desktop_clipboard_write", "desktop_copy", "desktop_paste"]).isSubset(of: Set(PluginManifest.current.actions)))
}

@Test func tccPermissionReadinessUsesStableInstalledAppIdentity() throws {
    let accessibility = DesktopPermissions.accessibility(granted: false)
    let capture = DesktopPermissions.screenRecording(granted: false)
    #expect(accessibility.bundleIdentifier == "com.moretea.forge.desktop-operator")
    #expect(accessibility.applicationName == "Forge Desktop Operator")
    #expect(accessibility.settingsPath.contains("Accessibility"))
    #expect(accessibility.requiredFor.contains("desktop_observe"))
    #expect(capture.settingsPath.contains("Screen"))
    #expect(capture.requiredFor == ["desktop_screenshot"])
}

@Test func runtimeHealthCarriesStructuredPermissionMetadata() throws {
    let runtime = PluginRuntime(socketPath: "/tmp/desktop-operator-test.sock")
    let health = runtime.health()
    #expect(health.providerBundleIdentifier == "com.moretea.forge.desktop-operator")
    #expect(health.permissions.count == 2)
    #expect(Set(health.permissions.map(\.service)) == Set(["accessibility", "screen_recording"]))
    #expect(health.internalCapabilities.contains("macos_browser_automation.v1"))
    #expect(health.browserAutomationActions.contains("list_tabs"))
}

@Test func launchAgentUsesASecretFreeEnvironmentAllowlist() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let root = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let installScript = try String(contentsOf: root.appendingPathComponent("scripts/install.sh"), encoding: .utf8)
    #expect(installScript.contains("<string>/usr/bin/env</string>"))
    #expect(installScript.contains("<string>-i</string>"))
    #expect(installScript.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"))
}

@Test func screenshotFailsClosedBeforeLaunchingCaptureWithoutPermission() throws {
    guard !ScreenshotDriver.screenRecordingGranted else { return }
    do {
        _ = try ScreenshotDriver.capture(scope: "display", windowId: nil, label: "permission-test")
        Issue.record("capture unexpectedly succeeded without Screen Recording permission")
    } catch let error as PluginError {
        #expect(error.code == "SCREEN_RECORDING_NOT_GRANTED")
        #expect(error.domain == "tcc")
        #expect(error.details?["bundleIdentifier"]?.stringValue == "com.moretea.forge.desktop-operator")
    }
}

@Test func permissionRequestShortCircuitsWhenPermissionIsAlreadyGranted() {
    var requestCount = 0
    let granted = PluginRuntime.requestPermissionIfNeeded(granted: true) {
        requestCount += 1
        return false
    }
    #expect(granted)
    #expect(requestCount == 0)

    let requested = PluginRuntime.requestPermissionIfNeeded(granted: false) {
        requestCount += 1
        return true
    }
    #expect(requested)
    #expect(requestCount == 1)
}

@Test func permissionRequestIsDeclaredAndRejectsUnknownServicesBeforePrompting() throws {
    #expect(PluginManifest.current.capabilities.contains("desktop.permissions"))
    #expect(PluginManifest.current.actions.contains("desktop_permissions_request"))
    let runtime = PluginRuntime(socketPath: "/tmp/desktop-operator-permission-test.sock")
    do {
        _ = try runtime.execute(action: "desktop_permissions_request", arguments: .object(["services": .array([.string("camera")])]))
        Issue.record("unknown permission service unexpectedly accepted")
    } catch let error as PluginError {
        #expect(error.code == "INVALID_ARGUMENTS")
        #expect(error.message.contains("unsupported desktop permission service"))
    }
}
@Test func providerInstallerDerivesReleaseIdentityFromInstalledManifest() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let root = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let installer = try String(contentsOf: root.appendingPathComponent("forge-plugin-install.mjs"), encoding: .utf8)
    let installScript = try String(contentsOf: root.appendingPathComponent("scripts/install.sh"), encoding: .utf8)
    #expect(installer.contains("installedManifest.version"))
    #expect(installer.contains("installedManifest.protocolVersion"))
    #expect(installer.contains("launchAgentLabel: installed.launchAgentLabel"))
    #expect(installer.contains("expectedProgramContains: installed.expectedProgramContains"))
    #expect(!installer.contains("pluginVersion: '0.2.3'"))
    #expect(installScript.contains("forge-plugin.json"))
    #expect(installScript.contains("\"launchAgentLabel\": \"$LABEL\""))
    #expect(installScript.contains("\"expectedProgramContains\": \"$APP_NAME.app\""))
    #expect(installScript.contains("request --socket \"$SOCKET\" --method health"))
    #expect(installScript.contains("attempt<100"))
    #expect(!installScript.contains("VERSION=\"0.2.3\""))
}
