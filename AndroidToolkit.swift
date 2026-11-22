import SwiftUI
import AppKit
import Combine

let envPrefix = "export PATH=/opt/local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin; "
let tetherCLI = "/usr/local/libexec/tetherkit/tetherkit-cli"

@discardableResult
func sh(_ cmd: String) -> (out: String, code: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", envPrefix + cmd]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return ("\(error)", -1) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let s = String(data: data, encoding: .utf8) ?? ""
    return (s.trimmingCharacters(in: .whitespacesAndNewlines), p.terminationStatus)
}

/// Runs a shell command as root through the standard macOS admin password dialog.
/// Returns an error message, or nil on success.
func shAdmin(_ cmd: String) -> String? {
    let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    guard let script = NSAppleScript(source: "do shell script \"\(esc)\" with administrator privileges") else {
        return "Could not build script"
    }
    var err: NSDictionary?
    script.executeAndReturnError(&err)
    if let err = err {
        let msg = (err[NSAppleScript.errorMessage] as? String) ?? "Unknown error"
        return msg.lowercased().contains("cancel") ? "" : msg
    }
    return nil
}

final class Model: ObservableObject {
    // device
    @Published var phoneName = ""
    @Published var phoneConnected = false

    // mirror
    @Published var mirrorRunning = false
    @Published var noAudio = true
    @Published var stayAwake = false
    @Published var screenOff = false
    @Published var onTop = false
    @Published var showTouches = false
    @Published var maxSize = 0

    // tether
    @Published var tetherRunning = false
    @Published var rndisFound = false
    @Published var cliInstalled = true
    @Published var tetherIP = ""
    @Published var tetherLog = ""
    @Published var busy = false
    @Published var note = ""
    @Published var testResult = ""

    private let q = DispatchQueue(label: "poll")
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        q.async {
            let serial = sh("adb devices | grep -w device | cut -f1 | head -1").out
            var name = ""
            if !serial.isEmpty {
                name = sh("adb -s \(serial) shell getprop ro.product.model").out
            }
            let mirror = sh("pgrep -x scrcpy").code == 0
            let installed = FileManager.default.isExecutableFile(atPath: tetherCLI)
            let tether = sh("pgrep -x tetherkit-cli").code == 0
            var rndis = tether
            if !tether && installed {
                rndis = sh("\(tetherCLI) --list 2>&1 | grep -c 'control interface'").out != "0"
            }
            let ip = tether ? sh("ipconfig getifaddr feth0").out : ""
            let log = tether ? sh("tail -n 12 /tmp/tetherkit.log 2>/dev/null").out : ""
            DispatchQueue.main.async {
                self.phoneConnected = !serial.isEmpty
                self.phoneName = name
                self.mirrorRunning = mirror
                self.cliInstalled = installed
                self.tetherRunning = tether
                self.rndisFound = rndis
                self.tetherIP = ip.hasPrefix("ipconfig") ? "" : ip
                self.tetherLog = log
            }
        }
    }

    // MARK: Mirror

    func startMirror() {
        var a = ["scrcpy"]
        if noAudio { a.append("--no-audio") }
        if stayAwake { a.append("--stay-awake") }
        if screenOff { a.append("--turn-screen-off") }
        if onTop { a.append("--always-on-top") }
        if showTouches { a.append("--show-touches") }
        if maxSize > 0 { a.append("--max-size=\(maxSize)") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", envPrefix + "exec " + a.joined(separator: " ") + " >/tmp/scrcpy.log 2>&1 </dev/null"]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
    }

    func stopMirror() {
        q.async {
            sh("pkill -x scrcpy")
            DispatchQueue.main.async { self.refresh() }
        }
    }

    // MARK: Tether

    func startTether() {
        busy = true
        note = ""
        testResult = ""
        q.async {
            let cmd = "(\(tetherCLI) >/tmp/tetherkit.log 2>&1 </dev/null &) ; "
                + "for i in 1 2 3 4 5 6 7 8 9 10; do /sbin/ifconfig feth0 >/dev/null 2>&1 && break; sleep 1; done; "
                + "/usr/sbin/ipconfig set feth0 DHCP"
            let err = shAdmin(cmd)
            DispatchQueue.main.async {
                self.busy = false
                if let err = err, !err.isEmpty { self.note = "Could not start: \(err)" }
                self.refresh()
            }
        }
    }

    func stopTether() {
        busy = true
        note = ""
        testResult = ""
        q.async {
            let err = shAdmin("/usr/bin/pkill -x tetherkit-cli")
            DispatchQueue.main.async {
                self.busy = false
                if let err = err, !err.isEmpty { self.note = "Could not stop: \(err)" }
                self.refresh()
            }
        }
    }

    func testInternet() {
        testResult = "Testing…"
        q.async {
            let r = sh("ping -c 3 -t 6 -b feth0 1.1.1.1 | tail -2")
            DispatchQueue.main.async {
                self.testResult = r.code == 0 ? "Internet via phone works\n" + r.out : "No internet via phone\n" + r.out
            }
        }
    }
}

// MARK: - Views

struct StatusDot: View {
    let on: Bool
    var body: some View {
        Circle().fill(on ? Color.green : Color.gray.opacity(0.5)).frame(width: 10, height: 10)
    }
}

struct MirrorTab: View {
    @ObservedObject var m: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox(label: Text("Options").font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Mute (don't forward audio)", isOn: $m.noAudio)
                    Toggle("Keep phone awake while mirroring", isOn: $m.stayAwake)
                    Toggle("Turn phone screen off while mirroring", isOn: $m.screenOff)
                    Toggle("Keep mirror window on top", isOn: $m.onTop)
                    Toggle("Show touches on phone", isOn: $m.showTouches)
                    Picker("Max resolution", selection: $m.maxSize) {
                        Text("Original").tag(0)
                        Text("1024").tag(1024)
                        Text("1280").tag(1280)
                        Text("1920").tag(1920)
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260)
                }
                .disabled(m.mirrorRunning)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            HStack {
                StatusDot(on: m.mirrorRunning)
                Text(m.mirrorRunning ? "Mirroring" : "Not mirroring").foregroundColor(.secondary)
                Spacer()
                if m.mirrorRunning {
                    Button("Stop mirroring") { m.stopMirror() }
                        .controlSize(.large)
                } else {
                    Button("Start mirroring") { m.startMirror() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!m.phoneConnected)
                }
            }
            if !m.phoneConnected && !m.mirrorRunning {
                Text("Plug in the phone and allow USB debugging.").font(.footnote).foregroundColor(.secondary)
            }
        }
        .padding(20)
    }
}

struct TetherTab: View {
    @ObservedObject var m: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox(label: Text("Status").font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    row("Phone USB tethering", on: m.rndisFound, text: m.rndisFound ? "Detected" : "Not detected")
                    row("Driver", on: m.tetherRunning, text: m.tetherRunning ? "Running" : "Stopped")
                    row("Address", on: !m.tetherIP.isEmpty, text: m.tetherIP.isEmpty ? "—" : m.tetherIP)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !m.cliInstalled {
                Text("Driver not installed at /usr/local/libexec/tetherkit/. Run the install script first.")
                    .font(.footnote).foregroundColor(.red)
            } else if !m.rndisFound && !m.tetherRunning {
                Text("Plug in the phone and switch on USB tethering (Settings > Hotspot > USB tethering).")
                    .font(.footnote).foregroundColor(.secondary)
            }

            HStack {
                if m.tetherRunning {
                    Button("Stop tethering") { m.stopTether() }
                        .controlSize(.large)
                        .disabled(m.busy)
                    Button("Test internet") { m.testInternet() }
                        .controlSize(.large)
                        .disabled(m.busy)
                } else {
                    Button("Start tethering") { m.startTether() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(m.busy || !m.rndisFound || !m.cliInstalled)
                }
                if m.busy { ProgressView().controlSize(.small) }
            }

            if !m.note.isEmpty {
                Text(m.note).font(.footnote).foregroundColor(.red)
            }
            if !m.testResult.isEmpty {
                Text(m.testResult).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            }

            if m.tetherRunning && !m.tetherLog.isEmpty {
                GroupBox(label: Text("Driver log").font(.subheadline)) {
                    ScrollView {
                        Text(m.tetherLog)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 90)
                }
            }

            Spacer()

            Text("The Mac keeps using Wi-Fi by default. Turn Wi-Fi off to use only the phone's connection.")
                .font(.footnote).foregroundColor(.secondary)
        }
        .padding(20)
    }

    func row(_ label: String, on: Bool, text: String) -> some View {
        HStack {
            StatusDot(on: on)
            Text(label)
            Spacer()
            Text(text).foregroundColor(.secondary)
        }
    }
}

struct ContentView: View {
    @ObservedObject var m: Model
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StatusDot(on: m.phoneConnected)
                Text(m.phoneConnected ? (m.phoneName.isEmpty ? "Phone connected" : m.phoneName) : "No phone connected")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            TabView {
                MirrorTab(m: m).tabItem { Label("Mirror", systemImage: "iphone") }
                TetherTab(m: m).tabItem { Label("Tether", systemImage: "antenna.radiowaves.left.and.right") }
            }
        }
        .frame(width: 440, height: 560)
    }
}

struct MenuView: View {
    @ObservedObject var m: Model
    let openWindow: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusDot(on: m.phoneConnected)
                Text(m.phoneConnected ? (m.phoneName.isEmpty ? "Phone connected" : m.phoneName) : "No phone connected")
                    .font(.headline)
            }
            Divider()
            Button(m.mirrorRunning ? "Stop mirroring" : "Start mirroring") {
                if m.mirrorRunning { m.stopMirror() } else { m.startMirror() }
            }
            .disabled(!m.phoneConnected && !m.mirrorRunning)
            Button(m.tetherRunning ? "Stop tethering" : "Start tethering") {
                if m.tetherRunning { m.stopTether() } else { m.startTether() }
            }
            .disabled(m.busy || (!m.tetherRunning && (!m.rndisFound || !m.cliInstalled)))
            if m.tetherRunning {
                Text(m.tetherIP.isEmpty ? "Tether on, waiting for IP…" : "Tether on · \(m.tetherIP)")
                    .font(.footnote).foregroundColor(.secondary)
            } else if !m.rndisFound {
                Text("Turn on USB tethering on the phone to enable it.")
                    .font(.footnote).foregroundColor(.secondary)
            }
            if !m.note.isEmpty { Text(m.note).font(.footnote).foregroundColor(.red) }
            Divider()
            HStack {
                Button("Open window…") { openWindow() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 270)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    var window: NSWindow?
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuView(m: model, openWindow: { [weak self] in self?.showWindow() }))
        updateIcon()
        model.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateIcon() } }
            .store(in: &cancellables)
        showWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func showWindow() {
        popover.performClose(nil)
        if window == nil {
            let host = NSHostingView(rootView: ContentView(m: model))
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Android Toolkit"
            w.isReleasedWhenClosed = false
            w.contentView = host
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func symbol(_ names: [String]) -> NSImage? {
        for n in names {
            if let img = NSImage(systemSymbolName: n, accessibilityDescription: nil) {
                img.isTemplate = true
                return img
            }
        }
        return nil
    }

    func setDot(_ color: NSColor?) {
        guard let b = statusItem.button else { return }
        if let c = color {
            b.attributedTitle = NSAttributedString(string: " ●",
                attributes: [.foregroundColor: c, .font: NSFont.systemFont(ofSize: 9)])
        } else {
            b.attributedTitle = NSAttributedString(string: "")
        }
    }

    func updateIcon() {
        statusItem.button?.image = symbol(["iphone.radiowaves.left.and.right", "iphone"])
        let active = model.tetherRunning || model.mirrorRunning
        setDot(active ? NSColor.systemGreen : nil)
    }
}

@main
struct AndroidToolkitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}
