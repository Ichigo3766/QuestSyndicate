import SwiftUI

// MARK: - Terminal Line

struct TerminalLine: Identifiable {
    let id = UUID()
    let kind: Kind
    let text: String

    enum Kind {
        case command   // user input echoed back
        case output    // command result
        case info      // system message (connect/disconnect, welcome)
        case error     // error highlight
    }
}

// MARK: - Quick Command

struct QuickCommand: Identifiable {
    let id = UUID()
    let label: String
    let sfSymbol: String
    let shellCommand: String    // non-nil → shell mode; use rawArgs for raw ADB
    let rawArgs: [String]?      // non-nil → raw ADB args (no shell prefix)

    init(_ label: String, _ sfSymbol: String, shell: String) {
        self.label = label
        self.sfSymbol = sfSymbol
        self.shellCommand = shell
        self.rawArgs = nil
    }

    init(_ label: String, _ sfSymbol: String, adb: [String]) {
        self.label = label
        self.sfSymbol = sfSymbol
        self.shellCommand = ""
        self.rawArgs = adb
    }
}

// MARK: - ADB Terminal ViewModel

@Observable
@MainActor
final class ADBTerminalViewModel {

    // MARK: State
    var lines: [TerminalLine] = []
    var inputText: String = ""
    var isRawMode: Bool = false          // raw = full adb cmd, false = adb shell prefix
    var isRunning: Bool = false

    // MARK: History
    private var history: [String] = []
    private var historyIndex: Int = -1   // -1 = at current draft

    // MARK: Service reference (set from view)
    var adb: ADBService?
    var device: DeviceInfo?

    // MARK: Quick Commands
    let quickCommands: [QuickCommand] = [
        QuickCommand("Reboot",        "arrow.counterclockwise",  adb: ["reboot"]),
        QuickCommand("Packages",      "square.stack",            shell: "pm list packages -3"),
        QuickCommand("Storage",       "internaldrive",           shell: "df -h /data /sdcard"),
        QuickCommand("Battery",       "battery.100",             shell: "dumpsys battery | grep -E 'level|status|temperature'"),
        QuickCommand("IP Address",    "network",                 shell: "ip route"),
        QuickCommand("Logcat (10)",   "doc.text.magnifyingglass",shell: "logcat -d -t 10"),
        QuickCommand("Top Procs",     "cpu",                     shell: "top -bn1 | head -20"),
        QuickCommand("Screen Size",   "rectangle.on.rectangle",  shell: "wm size"),
    ]

    // MARK: - Init

    init() {
        appendInfo("ADB Terminal — connect a device to get started.")
        appendInfo("Toggle 'Raw' to send full adb commands (e.g. install, pull).")
    }

    // MARK: - Run Command

    func runCommand() {
        let raw = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        inputText = ""
        historyIndex = -1
        addToHistory(raw)

        guard let adb, let device else {
            appendError("No device connected.")
            return
        }

        let serial = device.id

        if isRawMode {
            // Full adb command — user types e.g. "install /tmp/foo.apk" or "devices"
            let prompt = "$ adb \(raw)"
            appendCommand(prompt)
            let parts = raw.shellComponents()
            isRunning = true
            Task {
                let output = await adb.runADB(serial: serial, args: parts)
                await MainActor.run {
                    appendOutput(output)
                    isRunning = false
                }
            }
        } else {
            // Shell mode — user types shell commands, we prepend "adb -s serial shell"
            let prompt = "[\(device.friendlyModelName ?? serial)]$ \(raw)"
            appendCommand(prompt)
            isRunning = true
            Task {
                let output = await adb.runShell(serial: serial, command: raw)
                await MainActor.run {
                    appendOutput(output)
                    isRunning = false
                }
            }
        }
    }

    func runQuickCommand(_ qc: QuickCommand) {
        guard let adb, let device else {
            appendError("No device connected.")
            return
        }
        let serial = device.id

        if let rawArgs = qc.rawArgs {
            // Raw ADB command (e.g. reboot)
            let prompt = "$ adb \(rawArgs.joined(separator: " "))"
            appendCommand(prompt)
            isRunning = true
            Task {
                let output = await adb.runADB(serial: serial, args: rawArgs)
                await MainActor.run {
                    appendOutput(output)
                    isRunning = false
                }
            }
        } else {
            // Shell command
            let prompt = "[\(device.friendlyModelName ?? serial)]$ \(qc.shellCommand)"
            appendCommand(prompt)
            isRunning = true
            Task {
                let output = await adb.runShell(serial: serial, command: qc.shellCommand)
                await MainActor.run {
                    appendOutput(output)
                    isRunning = false
                }
            }
        }
    }

    func clearTerminal() {
        lines.removeAll()
        appendInfo("Terminal cleared.")
    }

    // MARK: - History Navigation

    func historyUp() {
        guard !history.isEmpty else { return }
        if historyIndex < history.count - 1 {
            historyIndex += 1
        }
        inputText = history[history.count - 1 - historyIndex]
    }

    func historyDown() {
        guard historyIndex > 0 else {
            historyIndex = -1
            inputText = ""
            return
        }
        historyIndex -= 1
        inputText = history[history.count - 1 - historyIndex]
    }

    // MARK: - Helpers

    private func addToHistory(_ cmd: String) {
        if history.last != cmd {
            history.append(cmd)
            if history.count > 200 { history.removeFirst() }
        }
    }

    private func appendCommand(_ text: String) {
        lines.append(TerminalLine(kind: .command, text: text))
    }

    func appendOutput(_ text: String) {
        // Split multiline output into individual lines for nicer display
        let sublines = text.components(separatedBy: "\n")
        for sub in sublines {
            lines.append(TerminalLine(kind: .output, text: sub))
        }
    }

    func appendInfo(_ text: String) {
        lines.append(TerminalLine(kind: .info, text: text))
    }

    func appendError(_ text: String) {
        lines.append(TerminalLine(kind: .error, text: text))
    }
}

// MARK: - String + shellComponents

private extension String {
    /// Very simple shell-like argument splitter (handles quoted strings).
    func shellComponents() -> [String] {
        var result: [String] = []
        var current = ""
        var inQuote: Character? = nil
        for ch in self {
            if let q = inQuote {
                if ch == q { inQuote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                inQuote = ch
            } else if ch == " " {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

// MARK: - ADBTerminalView

struct ADBTerminalView: View {
    @Environment(AppState.self) private var appState
    @State private var vm = ADBTerminalViewModel()
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // ── Header bar ──────────────────────────────────────────────────
            headerBar

            Divider()

            // ── Quick commands ───────────────────────────────────────────────
            quickCommandStrip

            Divider()

            // ── Terminal output ──────────────────────────────────────────────
            terminalOutput

            Divider()

            // ── Input bar ────────────────────────────────────────────────────
            inputBar
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.05))
        .onAppear {
            vm.adb = appState.adb
            vm.device = appState.selectedDevice
            if appState.selectedDevice == nil {
                vm.appendInfo("No device connected — connect a Quest to start running commands.")
            } else {
                vm.appendInfo("Connected to \(appState.selectedDevice?.friendlyModelName ?? appState.selectedDevice?.id ?? "device").")
            }
        }
        .onChange(of: appState.selectedDevice) { _, newDevice in
            vm.device = newDevice
            if let d = newDevice {
                vm.appendInfo("Device changed: \(d.friendlyModelName ?? d.id)")
            } else {
                vm.appendInfo("Device disconnected.")
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            // Device indicator
            if let device = appState.selectedDevice {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text(device.friendlyModelName ?? device.id)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.primary)
                    if device.isWireless {
                        Image(systemName: "wifi")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassCapsule()
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.orange)
                        .frame(width: 8, height: 8)
                    Text("No device")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassCapsule()
            }

            Spacer()

            // Running indicator
            if vm.isRunning {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Running…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Raw mode toggle
            Toggle(isOn: $vm.isRawMode) {
                Label("Raw ADB", systemImage: "terminal.fill")
                    .font(.caption)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Raw mode: type full ADB commands (e.g. \"devices\", \"install path/to.apk\"). Shell mode: commands are auto-prefixed with adb shell.")

            // Clear button
            Button {
                vm.clearTerminal()
            } label: {
                Label("Clear", systemImage: "trash")
                    .font(.caption)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .help("Clear terminal output")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Quick Command Strip

    private var quickCommandStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vm.quickCommands) { qc in
                    Button {
                        vm.runQuickCommand(qc)
                    } label: {
                        Label(qc.label, systemImage: qc.sfSymbol)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(appState.selectedDevice == nil || vm.isRunning)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Terminal Output

    private var terminalOutput: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(vm.lines) { line in
                        TerminalLineView(line: line)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .black).opacity(0.85))
            .onChange(of: vm.lines.count) { _, _ in
                if let last = vm.lines.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            // Prompt label
            Text(promptLabel)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.green)
                .lineLimit(1)
                .layoutPriority(1)

            // Input field
            TextField("", text: $vm.inputText)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.white)
                .focused($inputFocused)
                .disabled(appState.selectedDevice == nil)
                .onSubmit { vm.runCommand() }
                .onKeyPress(.upArrow) {
                    vm.historyUp()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    vm.historyDown()
                    return .handled
                }

            // Run button
            Button {
                vm.runCommand()
            } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title3)
                    .foregroundStyle(
                        (appState.selectedDevice == nil || vm.inputText.isEmpty || vm.isRunning)
                            ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.green)
                    )
            }
            .buttonStyle(.plain)
            .disabled(appState.selectedDevice == nil || vm.inputText.isEmpty || vm.isRunning)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .black).opacity(0.9))
        .onTapGesture { inputFocused = true }
    }

    // MARK: - Prompt Label

    private var promptLabel: String {
        guard let device = appState.selectedDevice else { return "$ " }
        if vm.isRawMode {
            return "adb> "
        } else {
            let name = device.friendlyModelName ?? device.id
            // Truncate long names
            let short = name.count > 16 ? String(name.prefix(14)) + "…" : name
            return "[\(short)]$ "
        }
    }
}

// MARK: - Terminal Line View

private struct TerminalLineView: View {
    let line: TerminalLine

    var body: some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 0.5)
    }

    private var color: Color {
        switch line.kind {
        case .command: return .green
        case .output:  return Color(nsColor: .lightGray)
        case .info:    return Color(nsColor: .systemTeal).opacity(0.9)
        case .error:   return .red
        }
    }
}
