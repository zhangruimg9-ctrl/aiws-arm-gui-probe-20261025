import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

// Public, self-owned test UI only. No products, credentials, model calls,
// screen capture, permission requests, TCC changes, or hidden input fallback.
func emit(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) { print(text) }
}

func writePublic(_ value: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    try data.write(to: url, options: .atomic)
}

final class FormDelegate: NSObject, NSApplicationDelegate {
    let output: URL
    var window: NSWindow!
    var input: NSTextField!
    var saved = 0
    init(output: URL) { self.output = output }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 580, height: 220),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AIWS public input capability probe"
        let title = NSTextField(labelWithString: "Public input marker")
        title.frame = NSRect(x: 24, y: 155, width: 500, height: 24)
        input = NSTextField(string: "") // The application never assigns the marker.
        input.frame = NSRect(x: 24, y: 110, width: 520, height: 28)
        input.isEditable = true
        input.isSelectable = true
        let button = NSButton(title: "Save public marker", target: self, action: #selector(saveByButton))
        button.frame = NSRect(x: 24, y: 52, width: 220, height: 32)
        window.contentView?.addSubview(title)
        window.contentView?.addSubview(input)
        window.contentView?.addSubview(button)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        do { try writePublic(["appPid": ProcessInfo.processInfo.processIdentifier,
              "initialValue": input.stringValue, "buttonActionCount": saved],
              to: output.appendingPathExtension("ready.json")) }
        catch { emit(["status": "APP_READY_WRITE_FAILED"]); NSApplication.shared.terminate(nil) }
    }
    @objc func saveByButton(_ sender: NSButton) {
        saved += 1
        do { try writePublic(["appPid": ProcessInfo.processInfo.processIdentifier,
              "savedMarker": input.stringValue, "buttonActionCount": saved,
              "writePath": "NSButton.targetAction"], to: output) }
        catch { emit(["status": "APP_SAVE_WRITE_FAILED"]) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
}

func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String {
    return attribute(element, name) as? String ?? ""
}

func performInput(pid: pid_t, marker: String, resultURL: URL) -> (Int32, [String: Any]) {
    let axTrusted = AXIsProcessTrusted() // Read only: no prompt option.
    let captureAvailable = CGPreflightScreenCaptureAccess() // Read only: never capture/request.
    var result: [String: Any] = ["schema": 1, "probe": "PUBLIC_SELF_OWNED_FORM_EXTERNAL_INPUT",
        "architecture": "arm64", "accessibilityTrusted": axTrusted,
        "screenCapturePreflight": captureAvailable, "inputAttempted": false,
        "productOrModelTested": false, "permissionRequested": false, "tccModified": false]
    guard let target = NSRunningApplication(processIdentifier: pid),
          target.bundleIdentifier == "local.aiws.publicinputprobe",
          target.executableURL?.standardizedFileURL == URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    else { result["status"] = "OWNED_APP_IDENTITY_MISMATCH"; return (1, result) }

    var exitCode: Int32 = 0
    if !axTrusted || !captureAvailable {
        result["status"] = "UNAVAILABLE"
        result["reason"] = "READ_ONLY_PERMISSION_PREFLIGHT_FALSE_NO_INPUT_OR_PROMPT"
        exitCode = 78
    } else {
        let app = AXUIElementCreateApplication(pid)
        var fields: [AXUIElement] = []
        var buttons: [AXUIElement] = []
        var visited = 0
        var exceeded = false
        func visit(_ element: AXUIElement, depth: Int) {
            visited += 1
            if depth > 8 || visited > 256 { exceeded = true; return }
            let role = stringAttribute(element, kAXRoleAttribute as CFString)
            if role == (kAXTextFieldRole as String) { fields.append(element) }
            if role == (kAXButtonRole as String) && stringAttribute(element, kAXTitleAttribute as CFString) == "Save public marker" {
                buttons.append(element)
            }
            if let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
                if children.count > 64 { exceeded = true; return }
                for child in children { visit(child, depth: depth + 1) }
            }
        }
        visit(app, depth: 0)
        result["inspectedNodeCount"] = visited
        result["matchingFieldCount"] = fields.count
        result["matchingSaveButtonCount"] = buttons.count
        if exceeded || fields.count != 1 || buttons.count != 1 {
            result["status"] = "BOUNDED_FORM_IDENTITY_NOT_UNIQUE"; exitCode = 1
        } else {
            result["inputAttempted"] = true
            var settable = DarwinBoolean(false)
            let canSet = AXUIElementIsAttributeSettable(fields[0], kAXValueAttribute as CFString, &settable)
            let setResult = (canSet == .success && settable.boolValue)
                ? AXUIElementSetAttributeValue(fields[0], kAXValueAttribute as CFString, marker as CFString)
                : AXError.attributeUnsupported
            let readBack = stringAttribute(fields[0], kAXValueAttribute as CFString)
            result["setValueError"] = setResult.rawValue
            result["fieldReadbackMatches"] = readBack == marker
            if setResult != .success || readBack != marker {
                result["status"] = "EXTERNAL_FIELD_INPUT_FAILED"; exitCode = 1
            } else {
                let pressResult = AXUIElementPerformAction(buttons[0], kAXPressAction as CFString)
                result["pressError"] = pressResult.rawValue
                let deadline = Date().addingTimeInterval(5)
                while !FileManager.default.fileExists(atPath: resultURL.path) && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                let savedData = try? Data(contentsOf: resultURL)
                let saved = savedData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let saveMatches = saved?["savedMarker"] as? String == marker
                let actionOnce = (saved?["buttonActionCount"] as? NSNumber)?.intValue == 1
                let writerMatches = (saved?["appPid"] as? NSNumber)?.int32Value == pid
                result["buttonSavedValueMatches"] = saveMatches
                result["buttonActionExactlyOnce"] = actionOnce
                result["savedWriterMatchesOwnedPid"] = writerMatches
                result["status"] = pressResult == .success && saveMatches && actionOnce && writerMatches ? "GENERIC_EXTERNAL_INPUT_PASS" : "EXTERNAL_BUTTON_SAVE_FAILED"
                if result["status"] as? String != "GENERIC_EXTERNAL_INPUT_PASS" { exitCode = 1 }
            }
        }
    }
    result["normalQuitRequested"] = target.terminate()
    let deadline = Date().addingTimeInterval(5)
    while !target.isTerminated && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    result["normalExitObserved"] = target.isTerminated
    if !target.isTerminated { result["status"] = "OWNED_APP_NORMAL_QUIT_NOT_OBSERVED"; exitCode = 1 }
    return (exitCode, result)
}

let arguments = CommandLine.arguments
if arguments.count == 5 && arguments[1] == "--drive", let pid = Int32(arguments[2]), pid > 0 {
    let marker = arguments[3]
    guard marker.range(of: "^AIWS_PUBLIC_INPUT_PROBE_[A-Z0-9_-]{1,80}$", options: .regularExpression) != nil
    else { emit(["status": "PUBLIC_MARKER_FORMAT_REJECTED"]); exit(1) }
    let url = URL(fileURLWithPath: arguments[4]).standardizedFileURL
    let temp = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RUNNER_TEMP"] ?? "").standardizedFileURL
    guard url.path.hasPrefix(temp.path + "/"), !FileManager.default.fileExists(atPath: url.path)
    else { emit(["status": "FRESH_OWNED_RESULT_REQUIRED"]); exit(1) }
    let (code, result) = performInput(pid: pid, marker: marker, resultURL: url)
    emit(result); exit(code)
} else if arguments.count == 2 {
    let url = URL(fileURLWithPath: arguments[1]).standardizedFileURL
    let temp = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RUNNER_TEMP"] ?? "").standardizedFileURL
    guard url.path.hasPrefix(temp.path + "/"), !FileManager.default.fileExists(atPath: url.path)
    else { emit(["status": "FRESH_OWNED_RESULT_REQUIRED"]); exit(1) }
    let application = NSApplication.shared
    let delegate = FormDelegate(output: url)
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { application.run() }
} else { emit(["status": "INVALID_PUBLIC_PROBE_ARGUMENTS"]); exit(1) }
