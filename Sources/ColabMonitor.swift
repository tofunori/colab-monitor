import AppKit
import SwiftUI
import UserNotifications

// MARK: - Models

enum BarDensity: String, CaseIterable {
    case iconOnly = "icon"
    case rate = "rate"
    case countAndRate = "both"

    var shortLabel: String {
        switch self {
        case .iconOnly:     return "Icon"
        case .rate:         return "Rate"
        case .countAndRate: return "VM + Rate"
        }
    }

    var next: BarDensity {
        switch self {
        case .iconOnly:     return .rate
        case .rate:         return .countAndRate
        case .countAndRate: return .iconOnly
        }
    }
}

enum ColabAuthMode: String, CaseIterable, Identifiable {
    case auto   = "auto"
    case adc    = "adc"
    case oauth2 = "oauth2"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:   return "Auto"
        case .adc:    return "ADC"
        case .oauth2: return "OAuth2"
        }
    }

    var cliArgs: [String] {
        switch self {
        case .adc:
            return ["--auth=adc"]
        case .oauth2:
            return ["--auth=oauth2"]
        case .auto:
            let adcPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/gcloud/application_default_credentials.json").path
            return FileManager.default.fileExists(atPath: adcPath) ? ["--auth=adc"] : []
        }
    }
}

enum PopoverTab: String, CaseIterable {
    case sessions = "Sessions"
    case logs     = "Logs"
    case history  = "History"
}

enum HistorySessionStatus: String, Equatable {
    case active
    case terminated
    case interrupted

    var label: String {
        switch self {
        case .active:      return "Running"
        case .terminated:  return "Completed"
        case .interrupted: return "Ended"
        }
    }
}

struct HistorySession: Identifiable, Equatable {
    let id: String
    let status: HistorySessionStatus
    let firstEvent: Date?
    let lastEvent: Date?
    let durationSeconds: TimeInterval
    let runCount: Int
    let execCount: Int
    let uploadCount: Int
    let downloadCount: Int
    let logs: [String]

    var sortDate: Date {
        lastEvent ?? firstEvent ?? .distantPast
    }

    var dayKey: Date {
        Calendar.current.startOfDay(for: sortDate)
    }

    var daySectionTitle: String {
        guard firstEvent != nil || lastEvent != nil else { return "Undated" }
        let cal = Calendar.current
        if cal.isDateInToday(sortDate) { return "Today" }
        if cal.isDateInYesterday(sortDate) { return "Yesterday" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f.string(from: sortDate)
    }

    var durationLabel: String {
        Self.formatDuration(durationSeconds)
    }

    var timeRangeLabel: String {
        guard let start = firstEvent else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let sStr = f.string(from: start)
        if status == .active {
            return "\(sStr) → live"
        }
        guard let end = lastEvent else { return sStr }
        let eStr = f.string(from: end)
        return (sStr == eStr) ? sStr : "\(sStr) → \(eStr)"
    }

    var activitySummary: String {
        var parts: [String] = []
        if runCount > 1 { parts.append("\(runCount) runs") }
        if execCount > 0 { parts.append("\(execCount) exec") }
        if uploadCount > 0 { parts.append("↑\(uploadCount)") }
        if downloadCount > 0 { parts.append("↓\(downloadCount)") }
        if parts.isEmpty { parts.append("\(logs.count) events") }
        return parts.joined(separator: " · ")
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        let mins = total / 60
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60
        let remM = mins % 60
        return remM == 0 ? "\(h)h" : "\(h)h \(String(format: "%02d", remM))m"
    }

    /// Parses raw `colab log -s <id>` lines into a structured history summary.
    /// Sums active spans across `session_created -> session_terminated` when a session name was reused.
    static func build(id: String, rawOutput: String, isActive: Bool, now: Date = Date()) -> HistorySession {
        let lines = rawOutput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[colab]") }

        var firstDate: Date? = nil
        var lastDate: Date? = nil
        var currentStart: Date? = nil
        var prevDate: Date? = nil
        var totalSeconds: TimeInterval = 0
        var runCount = 0
        var execCount = 0
        var uploadCount = 0
        var downloadCount = 0
        var lastWasTerminated = false

        for line in lines {
            let date = LogSyntax.extractLineDate(line)
            if let d = date {
                if firstDate == nil { firstDate = d }
                lastDate = d
            }

            let parsed = LogSyntax.parse(line)
            switch parsed.kind {
            case .exec:
                execCount += 1
            case .fileUpload:
                uploadCount += 1
            case .fileDownload:
                downloadCount += 1
            case .event:
                let ev = parsed.payload.lowercased()
                if ev == "session_created" {
                    if let openStart = currentStart, let p = prevDate {
                        totalSeconds += max(0, p.timeIntervalSince(openStart))
                    }
                    currentStart = date
                    runCount += 1
                    lastWasTerminated = false
                } else if ev == "session_terminated" {
                    if let openStart = currentStart, let d = date {
                        totalSeconds += max(0, d.timeIntervalSince(openStart))
                        currentStart = nil
                    }
                    lastWasTerminated = true
                }
            default:
                break
            }

            if let d = date { prevDate = d }
        }

        if let openStart = currentStart {
            let endRef = isActive ? now : (lastDate ?? openStart)
            totalSeconds += max(0, endRef.timeIntervalSince(openStart))
        } else if runCount == 0, let f = firstDate, let l = lastDate {
            totalSeconds = max(0, l.timeIntervalSince(f))
            runCount = 1
        }

        let status: HistorySessionStatus
        if isActive {
            status = .active
        } else if lastWasTerminated {
            status = .terminated
        } else {
            status = .interrupted
        }

        return HistorySession(
            id: id,
            status: status,
            firstEvent: firstDate,
            lastEvent: lastDate,
            durationSeconds: totalSeconds,
            runCount: max(1, runCount),
            execCount: execCount,
            uploadCount: uploadCount,
            downloadCount: downloadCount,
            logs: lines
        )
    }
}

enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case ribbon   = "ribbon"
    case orbit    = "orbit"
    case hexcore  = "hexcore"
    case infinity = "infinity"
    case chip     = "chip"
    case spark    = "spark"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ribbon:   return "Ribbon"
        case .orbit:    return "Orbit"
        case .hexcore:  return "Prism"
        case .infinity: return "Infinity"
        case .chip:     return "Chip"
        case .spark:    return "Spark"
        }
    }

    var subtitle: String {
        switch self {
        case .ribbon:   return "3D CO"
        case .orbit:    return "Satellite"
        case .hexcore:  return "GPU Cube"
        case .infinity: return "Loop ∞"
        case .chip:     return "Live Bars"
        case .spark:    return "Glint"
        }
    }
}

enum MenuBarIconColorMode: String, CaseIterable, Identifiable {
    case color = "color"
    case mono  = "mono"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .color: return "Color"
        case .mono:  return "Monochrome"
        }
    }
}

struct ColabSession: Identifiable, Equatable {
    let id: String              // session name, e.g. train-vit-l4
    let endpoint: String        // e.g. gpu-l4-s-...
    let hardware: String        // e.g. CPU, L4, A100, T4
    let shape: String           // e.g. High-RAM, Standard
    let variant: String         // e.g. GPU, DEFAULT
    var status: String          // BUSY or IDLE
    var lastExec: String        // e.g. stdin at 2026-11-22 15:44:54
    var activeTask: String?     // detected from local `colab exec` process if any
    var logs: [String]

    var isGPU: Bool {
        variant.uppercased().contains("GPU") || ["L4", "T4", "A100", "V100", "H100"].contains(hardware.uppercased())
    }

    var tierLabel: String {
        if isGPU { return "\(hardware) GPU" }
        if shape.lowercased().contains("high") { return "CPU-HM" }
        return "CPU"
    }

    var shapeSummary: String {
        if isGPU { return "\(hardware) · \(shape) · GPU" }
        return "\(hardware) · \(shape)"
    }

    var shortEndpoint: String {
        endpoint.count > 22 ? "\(endpoint.prefix(22))…" : endpoint
    }

    var cleanLastExec: String {
        if lastExec.isEmpty { return "" }
        let cleaned = lastExec.replacingOccurrences(of: "stdin at ", with: "")
        let todayPrefix = Self.todayDatePrefix()
        if cleaned.hasPrefix(todayPrefix) {
            return String(cleaned.dropFirst(todayPrefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return cleaned
    }

    var isIdle: Bool {
        status.uppercased() == "IDLE"
    }

    private static func todayDatePrefix() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd "
        f.timeZone = .current
        return f.string(from: Date())
    }
}

// MARK: - Launch at Login (User LaunchAgent)

enum LaunchAgentManager {
    static let label = "com.colabmonitor.app"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        let fm = FileManager.default
        if enabled {
            let dir = plistURL.deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let execPath: String
            if Bundle.main.bundleURL.pathExtension == "app", let p = Bundle.main.executablePath {
                execPath = p
            } else {
                execPath = fm.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications/ColabMonitor.app/Contents/MacOS/ColabMonitor").path
            }
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [execPath],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive"
            ]
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: plistURL, options: .atomic)
                return true
            } catch {
                return false
            }
        } else {
            if fm.fileExists(atPath: plistURL.path) {
                try? fm.removeItem(at: plistURL)
            }
            return true
        }
    }
}

// MARK: - Local Notifications (guarded for ad-hoc .app bundles)

enum NotificationManager {
    private static var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    static func requestAuthorizationIfNeeded() {
        guard isAppBundle else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func send(title: String, body: String, identifier: String) {
        guard isAppBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}

// MARK: - CLI Runner (Sanctioned `colab` CLI commands only)

enum ColabCLI {
    static func resolveBinaryPath() -> String? {
        let fm = FileManager.default
        if let envBin = ProcessInfo.processInfo.environment["COLAB_BIN"],
           !envBin.isEmpty, fm.isExecutableFile(atPath: envBin) {
            return envBin
        }
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/.local/bin/colab",
            "/opt/homebrew/bin/colab",
            "/usr/local/bin/colab",
            "\(home)/miniconda3/bin/colab",
            "\(home)/.pyenv/shims/colab"
        ]
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                candidates.append("\(dir)/colab")
            }
        }
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Runs any executable safely without pipe-buffer deadlocks by draining stdout/stderr
    /// concurrently on a background queue while waiting with timeout.
    static func execRaw(_ executable: String, args: [String], timeout: TimeInterval = 15) -> (code: Int32, out: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.standardInput = FileHandle.nullDevice

        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPath = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = extraPath + ":" + (env["PATH"] ?? "")
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        let termSema = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in termSema.signal() }

        do {
            try proc.run()
        } catch {
            return (-1, "Launch error: \(error.localizedDescription)")
        }

        let readGroup = DispatchGroup()
        var outputData = Data()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        if termSema.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            _ = termSema.wait(timeout: .now() + 1.0)
            try? pipe.fileHandleForReading.close()
            return (-2, "Timeout")
        }

        _ = readGroup.wait(timeout: .now() + 2.0)
        let out = String(data: outputData, encoding: .utf8) ?? ""
        return (proc.terminationStatus, out)
    }

    static func run(_ args: [String], authMode: ColabAuthMode = .auto, timeout: TimeInterval = 15) -> (code: Int32, out: String) {
        guard let bin = resolveBinaryPath() else {
            return (-127, "colab CLI not found in PATH or ~/.local/bin")
        }
        return execRaw(bin, args: authMode.cliArgs + args, timeout: timeout)
    }

    /// Detects active local `colab ... -s <session>` processes (exec/install/upload/download)
    /// to prevent false IDLE alerts when `colab status` lags behind a long-running `exec`.
    static func localActiveSessions() -> [String: String] {
        let res = execRaw("/bin/ps", args: ["-eo", "command"], timeout: 5)
        guard res.code == 0 else { return [:] }
        var active: [String: String] = [:]

        for line in res.out.components(separatedBy: .newlines) {
            guard line.contains("colab"), line.contains(" -s ") else { continue }
            guard line.contains(" exec ") || line.contains(" install ") || line.contains(" upload ") || line.contains(" download ") else { continue }
            let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if let sIdx = tokens.firstIndex(of: "-s"), sIdx + 1 < tokens.count {
                let name = tokens[sIdx + 1]
                if let task = tokens.first(where: { $0.hasPrefix("TASK=") || $0.hasPrefix("JOB=") || $0.hasPrefix("TACHE=") }) {
                    if let eq = task.firstIndex(of: "=") {
                        active[name] = String(task[task.index(after: eq)...])
                    }
                } else if let fIdx = tokens.firstIndex(of: "-f"), fIdx + 1 < tokens.count {
                    active[name] = URL(fileURLWithPath: tokens[fIdx + 1]).lastPathComponent
                } else if let py = tokens.first(where: { $0.hasSuffix(".py") }) {
                    active[name] = URL(fileURLWithPath: py).lastPathComponent
                } else if line.contains(" install ") {
                    active[name] = "installing packages"
                } else if line.contains(" download ") {
                    active[name] = "downloading file"
                } else if line.contains(" upload ") {
                    active[name] = "uploading file"
                } else {
                    active[name] = "running exec"
                }
            }
        }
        return active
    }
}

// MARK: - Store

final class MonitorStore: ObservableObject {
    @Published var email: String = "Google Colab"
    @Published var balance: Double = 0.0
    @Published var usageRate: Double = 0.0
    @Published var activeAssignments: Int = 0
    @Published var sessions: [ColabSession] = []
    @Published var historySessions: [HistorySession] = []
    @Published var isLoadingHistory: Bool = false
    @Published var historyLoaded: Bool = false
    @Published var stoppingIds: Set<String> = []
    @Published var isRefreshing: Bool = false
    @Published var lastUpdated: Date? = nil
    @Published var errorMessage: String? = nil
    @Published var uiResetToken: Int = 0

    @Published var density: BarDensity {
        didSet {
            if persistPrefs { UserDefaults.standard.set(density.rawValue, forKey: "barDensity") }
            onMenuBarUpdate?()
        }
    }

    @Published var iconStyle: MenuBarIconStyle {
        didSet {
            if persistPrefs { UserDefaults.standard.set(iconStyle.rawValue, forKey: "iconStyle") }
            onMenuBarUpdate?()
        }
    }

    @Published var iconColorMode: MenuBarIconColorMode {
        didSet {
            if persistPrefs { UserDefaults.standard.set(iconColorMode.rawValue, forKey: "iconColorMode") }
            onMenuBarUpdate?()
        }
    }

    @Published var authMode: ColabAuthMode {
        didSet {
            if persistPrefs { UserDefaults.standard.set(authMode.rawValue, forKey: "authMode") }
            whoamiLoaded = false
            if persistPrefs { refresh() }
        }
    }

    @Published var notificationsEnabled: Bool {
        didSet {
            if persistPrefs { UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled") }
            if notificationsEnabled && persistPrefs {
                NotificationManager.requestAuthorizationIfNeeded()
            }
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            if persistPrefs {
                LaunchAgentManager.setEnabled(launchAtLogin)
            }
        }
    }

    var onMenuBarUpdate: (() -> Void)?
    private let persistPrefs: Bool
    private var timer: Timer?
    private var whoamiLoaded = false
    private var pollInFlight = false
    private var historyInFlight = false
    private var historyCache: [String: HistorySession] = [:]
    private var previousSessionsById: [String: ColabSession] = [:]
    private var manualStopIds: Set<String> = []
    private var idleSince: [String: Date] = [:]
    private var notifiedIdleIds: Set<String> = []
    private let idleAlertDelay: TimeInterval = 300.0 // 5 minutes
    private let queue = DispatchQueue(label: "com.colabmonitor.poll", qos: .utility)
    private let historyQueue = DispatchQueue(label: "com.colabmonitor.history", qos: .utility)

    init(autoStart: Bool = true) {
        self.persistPrefs = autoStart
        let savedDensity = UserDefaults.standard.string(forKey: "barDensity") ?? BarDensity.rate.rawValue
        self.density = BarDensity(rawValue: savedDensity) ?? .rate
        let savedStyle = UserDefaults.standard.string(forKey: "iconStyle") ?? MenuBarIconStyle.ribbon.rawValue
        self.iconStyle = MenuBarIconStyle(rawValue: savedStyle) ?? .ribbon
        let savedColor = UserDefaults.standard.string(forKey: "iconColorMode") ?? MenuBarIconColorMode.color.rawValue
        self.iconColorMode = MenuBarIconColorMode(rawValue: savedColor) ?? .color
        let savedAuth = UserDefaults.standard.string(forKey: "authMode") ?? ColabAuthMode.auto.rawValue
        self.authMode = ColabAuthMode(rawValue: savedAuth) ?? .auto
        self.notificationsEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        self.launchAtLogin = LaunchAgentManager.isEnabled

        if autoStart {
            if notificationsEnabled {
                NotificationManager.requestAuthorizationIfNeeded()
            }
            refresh()
            scheduleTimer()
        }
    }

    var idleSessions: [ColabSession] {
        sessions.filter { $0.isIdle }
    }

    var hasIdle: Bool {
        !idleSessions.isEmpty
    }

    /// Extra Colab runtimes active outside the CLI (e.g. browser notebooks).
    var externalAssignments: Int {
        max(0, activeAssignments - sessions.count)
    }

    var updatedLabel: String {
        guard let d = lastUpdated else { return "Loading…" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return "Updated \(f.string(from: d))"
    }

    var tooltipSummary: String {
        let count = sessions.count
        let idleNote = hasIdle ? " · IDLE detected" : ""
        let extNote = externalAssignments > 0 ? " (+\(externalAssignments) web)" : ""
        let vmLabel = count == 1 ? "VM" : "VMs"
        return String(format: "ColabMonitor — %.1f u. · %.2f u./hr · %d %@%@%@", balance, usageRate, count, vmLabel, extNote, idleNote)
    }

    func sshCommand(for sessionId: String) -> String {
        let authPart = authMode.cliArgs.joined(separator: " ")
        return authPart.isEmpty ? "colab ssh -s \(sessionId)" : "colab \(authPart) ssh -s \(sessionId)"
    }

    func resetTransientUI() {
        DispatchQueue.main.async {
            self.uiResetToken += 1
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval: TimeInterval = (sessions.isEmpty && activeAssignments == 0) ? 90.0 : 20.0
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let currentAuth = authMode
        queue.async { [weak self] in
            guard let self else { return }
            if self.pollInFlight { return }
            self.pollInFlight = true
            DispatchQueue.main.async { self.isRefreshing = true }

            defer {
                self.pollInFlight = false
                DispatchQueue.main.async { self.isRefreshing = false }
            }

            let topGroup = DispatchGroup()
            var usageRes: (code: Int32, out: String) = (-1, "")
            var sessRes: (code: Int32, out: String) = (-1, "")
            var localActive: [String: String] = [:]
            var fetchedEmail: String? = nil

            if !self.whoamiLoaded {
                topGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    let w = ColabCLI.run(["whoami"], authMode: currentAuth, timeout: 10)
                    if w.code == 0 {
                        for line in w.out.components(separatedBy: .newlines) {
                            if line.lowercased().hasPrefix("email:") {
                                let val = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                                if !val.isEmpty { fetchedEmail = val }
                            }
                        }
                    }
                    topGroup.leave()
                }
            }

            topGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                usageRes = ColabCLI.run(["usage"], authMode: currentAuth, timeout: 15)
                topGroup.leave()
            }
            topGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                sessRes = ColabCLI.run(["sessions"], authMode: currentAuth, timeout: 15)
                topGroup.leave()
            }
            topGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                localActive = ColabCLI.localActiveSessions()
                topGroup.leave()
            }
            topGroup.wait()

            if let mail = fetchedEmail {
                self.whoamiLoaded = true
                DispatchQueue.main.async { self.email = mail }
            }

            var parsedBalance = self.balance
            var parsedRate = self.usageRate
            var parsedActive = self.activeAssignments
            var err: String? = nil

            if usageRes.code == 0 {
                parsedRate = 0.0
                parsedActive = 0
                for line in usageRes.out.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("Current balance:") {
                        let num = trimmed.replacingOccurrences(of: "Current balance:", with: "")
                            .replacingOccurrences(of: "compute units", with: "")
                            .trimmingCharacters(in: .whitespaces)
                        if let v = Double(num) { parsedBalance = v }
                    } else if trimmed.hasPrefix("Usage rate:") {
                        let num = trimmed.replacingOccurrences(of: "Usage rate:", with: "")
                            .replacingOccurrences(of: "/hr", with: "")
                            .trimmingCharacters(in: .whitespaces)
                        if let v = Double(num) { parsedRate = v }
                    } else if trimmed.hasPrefix("Active assignments:") {
                        let num = trimmed.replacingOccurrences(of: "Active assignments:", with: "")
                            .trimmingCharacters(in: .whitespaces)
                        if let v = Int(num) { parsedActive = v }
                    }
                }
            } else if usageRes.code == -127 {
                err = "colab CLI not found — install google-colab-cli"
            } else {
                err = "colab usage failed (exit \(usageRes.code))"
            }

            var parsedSessions: [ColabSession] = []
            if sessRes.code == 0 {
                let rawSessions = sessRes.out
                    .components(separatedBy: .newlines)
                    .compactMap { Self.parseSessionLine($0) }

                let detailGroup = DispatchGroup()
                let lock = NSLock()
                var enriched: [ColabSession] = []

                for base in rawSessions {
                    let sid = base.id
                    detailGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        let subGroup = DispatchGroup()
                        var stRes: (code: Int32, out: String) = (-1, "")
                        var lgRes: (code: Int32, out: String) = (-1, "")

                        subGroup.enter()
                        DispatchQueue.global(qos: .utility).async {
                            stRes = ColabCLI.run(["status", "-s", sid], authMode: currentAuth, timeout: 10)
                            subGroup.leave()
                        }
                        subGroup.enter()
                        DispatchQueue.global(qos: .utility).async {
                            lgRes = ColabCLI.run(["log", "-s", sid, "-n", "25"], authMode: currentAuth, timeout: 10)
                            subGroup.leave()
                        }
                        subGroup.wait()

                        var s = base
                        if stRes.code == 0 {
                            let lines = stRes.out.components(separatedBy: .newlines)
                            if let first = lines.first {
                                if first.contains("Status: BUSY") { s.status = "BUSY" }
                                else if first.contains("Status: IDLE") { s.status = "IDLE" }
                            }
                            if let execLine = lines.first(where: { $0.contains("Last Execution:") }) {
                                s.lastExec = execLine.replacingOccurrences(of: "Last Execution:", with: "")
                                    .trimmingCharacters(in: .whitespaces)
                            }
                        }

                        if let localTask = localActive[sid] {
                            s.status = "BUSY"
                            s.activeTask = localTask
                        }

                        if lgRes.code == 0 {
                            s.logs = lgRes.out
                                .components(separatedBy: .newlines)
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty && !$0.hasPrefix("[colab]") }
                                .suffix(25)
                                .map { $0 }
                        }

                        lock.lock()
                        enriched.append(s)
                        lock.unlock()
                        detailGroup.leave()
                    }
                }
                detailGroup.wait()

                parsedSessions = enriched.sorted { a, b in
                    if a.isGPU != b.isGPU { return a.isGPU && !b.isGPU }
                    return a.id < b.id
                }
            } else if err == nil {
                err = "colab sessions failed (exit \(sessRes.code))"
            }

            DispatchQueue.main.async {
                let wasEmpty = (self.sessions.isEmpty && self.activeAssignments == 0)
                let nowEmpty = (parsedSessions.isEmpty && parsedActive == 0)

                if err == nil {
                    self.evaluateNotifications(newSessions: parsedSessions)
                }

                self.balance = parsedBalance
                self.usageRate = parsedRate
                self.activeAssignments = parsedActive
                self.sessions = parsedSessions
                self.stoppingIds = self.stoppingIds.intersection(Set(parsedSessions.map { $0.id }))
                self.errorMessage = err
                self.lastUpdated = Date()
                self.onMenuBarUpdate?()
                if wasEmpty != nowEmpty { self.scheduleTimer() }
            }
        }
    }

    private func evaluateNotifications(newSessions: [ColabSession]) {
        let now = Date()
        let newById = Dictionary(uniqueKeysWithValues: newSessions.map { ($0.id, $0) })

        if notificationsEnabled && !previousSessionsById.isEmpty {
            // 1. Notify when a previously running VM disappears (unless manually stopped)
            for (oldId, oldSess) in previousSessionsById where newById[oldId] == nil {
                if !manualStopIds.contains(oldId) {
                    NotificationManager.send(
                        title: "Colab session finished",
                        body: "\(oldId) (\(oldSess.tierLabel)) has ended.",
                        identifier: "colab-finished-\(oldId)-\(Int(now.timeIntervalSince1970))"
                    )
                }
                manualStopIds.remove(oldId)
                idleSince.removeValue(forKey: oldId)
                notifiedIdleIds.remove(oldId)
            }
        } else {
            for oldId in previousSessionsById.keys where newById[oldId] == nil {
                manualStopIds.remove(oldId)
                idleSince.removeValue(forKey: oldId)
                notifiedIdleIds.remove(oldId)
            }
        }

        // 2. Notify once when a VM remains IDLE for 5+ minutes
        for s in newSessions {
            if s.isIdle {
                let start = idleSince[s.id] ?? now
                idleSince[s.id] = start
                if notificationsEnabled && !notifiedIdleIds.contains(s.id) && now.timeIntervalSince(start) >= idleAlertDelay {
                    notifiedIdleIds.insert(s.id)
                    NotificationManager.send(
                        title: "Colab VM idle for 5+ min",
                        body: "\(s.id) (\(s.tierLabel)) is idle and still using compute units.",
                        identifier: "colab-idle-\(s.id)"
                    )
                }
            } else {
                idleSince.removeValue(forKey: s.id)
                notifiedIdleIds.remove(s.id)
            }
        }

        previousSessionsById = newById
    }

    func stopSession(_ id: String) {
        let currentAuth = authMode
        DispatchQueue.main.async {
            self.stoppingIds.insert(id)
            self.manualStopIds.insert(id)
        }
        queue.async { [weak self] in
            guard let self else { return }
            _ = ColabCLI.run(["stop", "-s", id], authMode: currentAuth, timeout: 25)
            DispatchQueue.main.async {
                self.stoppingIds.remove(id)
            }
            self.refresh()
        }
    }

    func stopAllSessions() {
        let ids = sessions.map { $0.id }
        let currentAuth = authMode
        guard !ids.isEmpty else { return }
        DispatchQueue.main.async {
            for id in ids {
                self.stoppingIds.insert(id)
                self.manualStopIds.insert(id)
            }
        }
        queue.async { [weak self] in
            guard let self else { return }
            for id in ids {
                _ = ColabCLI.run(["stop", "-s", id], authMode: currentAuth, timeout: 25)
            }
            DispatchQueue.main.async {
                self.stoppingIds.removeAll()
            }
            self.refresh()
        }
    }

    /// Fetches full session history from official `colab log` + `colab log -s <id>`.
    /// Runs on-demand (never during background polling), parallelized with max 4 workers,
    /// and caches completed (`session_terminated`) sessions in memory for instant reopen.
    func loadHistory(force: Bool = false) {
        let activeIds = Set(sessions.map { $0.id })
        let currentAuth = authMode
        historyQueue.async { [weak self] in
            guard let self else { return }
            if self.historyInFlight { return }
            self.historyInFlight = true
            DispatchQueue.main.async { self.isLoadingHistory = true }

            defer {
                self.historyInFlight = false
                DispatchQueue.main.async {
                    self.isLoadingHistory = false
                    self.historyLoaded = true
                }
            }

            let listRes = ColabCLI.run(["log"], authMode: currentAuth, timeout: 15)
            guard listRes.code == 0 else { return }

            let names = Self.parseHistorySessionList(listRes.out)
            let sem = DispatchSemaphore(value: 4)
            let group = DispatchGroup()
            let lock = NSLock()
            var built: [HistorySession] = []

            for name in names {
                let isActive = activeIds.contains(name)
                if !force, !isActive, let cached = self.historyCache[name], cached.status == .terminated {
                    lock.lock()
                    built.append(cached)
                    lock.unlock()
                    continue
                }

                let sessionName = name
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    sem.wait()
                    let res = ColabCLI.run(["log", "-s", sessionName], authMode: currentAuth, timeout: 12)
                    sem.signal()
                    if res.code == 0 {
                        let item = HistorySession.build(id: sessionName, rawOutput: res.out, isActive: isActive)
                        lock.lock()
                        built.append(item)
                        if item.status == .terminated {
                            self.historyCache[sessionName] = item
                        } else {
                            self.historyCache.removeValue(forKey: sessionName)
                        }
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            group.wait()

            let sorted = built.sorted { a, b in
                if a.status == .active && b.status != .active { return true }
                if a.status != .active && b.status == .active { return false }
                if a.sortDate != b.sortDate { return a.sortDate > b.sortDate }
                return a.id < b.id
            }

            DispatchQueue.main.async {
                self.historySessions = sorted
            }
        }
    }

    static func parseHistorySessionList(_ out: String) -> [String] {
        out.components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty,
                      !trimmed.hasPrefix("[colab]"),
                      !trimmed.lowercased().hasPrefix("no ") else { return nil }
                return trimmed
            }
    }

    /// Parses: `[train-vit-l4] gpu-l4-s-... | Hardware: L4 | Shape: Standard | Variant: GPU`
    static func parseSessionLine(_ line: String) -> ColabSession? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let closeBracket = trimmed.firstIndex(of: "]") else { return nil }
        let name = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeBracket])
        if name.lowercased() == "colab" { return nil }

        let rest = String(trimmed[trimmed.index(after: closeBracket)...]).trimmingCharacters(in: .whitespaces)
        let parts = rest.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let endpoint = parts.first, !endpoint.isEmpty else { return nil }

        var hw = "CPU"
        var shape = "Standard"
        var variant = "DEFAULT"
        for p in parts.dropFirst() {
            if p.hasPrefix("Hardware:") { hw = p.replacingOccurrences(of: "Hardware:", with: "").trimmingCharacters(in: .whitespaces) }
            else if p.hasPrefix("Shape:") { shape = p.replacingOccurrences(of: "Shape:", with: "").trimmingCharacters(in: .whitespaces) }
            else if p.hasPrefix("Variant:") { variant = p.replacingOccurrences(of: "Variant:", with: "").trimmingCharacters(in: .whitespaces) }
        }

        return ColabSession(
            id: name,
            endpoint: endpoint,
            hardware: hw,
            shape: shape,
            variant: variant,
            status: "BUSY",
            lastExec: "",
            activeTask: nil,
            logs: []
        )
    }
}

// MARK: - Menu Bar Vector Icons (6 styles × Color / Monochrome, CoreGraphics Retina)

enum MenuBarIconFactory {
    private struct IconColors {
        let primary: NSColor
        let secondary: NSColor
        let tertiary: NSColor
        let neutral: NSColor
        let idleDot: NSColor
    }

    private static func resolveColors(colorMode: MenuBarIconColorMode, isDark: Bool, isTemplate: Bool, activeCount: Int, hasIdle: Bool) -> IconColors {
        let dim: CGFloat = (activeCount == 0 && !hasIdle) ? 0.42 : 1.0

        if isTemplate {
            return IconColors(
                primary:   NSColor.black.withAlphaComponent(1.00 * dim),
                secondary: NSColor.black.withAlphaComponent(0.46 * dim),
                tertiary:  NSColor.black.withAlphaComponent(0.72 * dim),
                neutral:   NSColor.black.withAlphaComponent(1.00 * dim),
                idleDot:   NSColor.black.withAlphaComponent(1.00)
            )
        }

        let fg = isDark
            ? NSColor(srgbRed: 0.957, green: 0.957, blue: 0.965, alpha: 1.0)
            : NSColor(srgbRed: 0.094, green: 0.094, blue: 0.106, alpha: 1.0)

        if colorMode == .color && (activeCount > 0 || hasIdle) {
            if isDark {
                return IconColors(
                    primary:   NSColor(srgbRed: 0.984, green: 0.749, blue: 0.141, alpha: dim),
                    secondary: NSColor(srgbRed: 0.918, green: 0.345, blue: 0.047, alpha: dim),
                    tertiary:  NSColor(srgbRed: 0.961, green: 0.620, blue: 0.043, alpha: dim),
                    neutral:   fg.withAlphaComponent(dim),
                    idleDot:   NSColor(srgbRed: 0.976, green: 0.451, blue: 0.086, alpha: 1.0)
                )
            } else {
                return IconColors(
                    primary:   NSColor(srgbRed: 0.878, green: 0.510, blue: 0.000, alpha: dim),
                    secondary: NSColor(srgbRed: 0.761, green: 0.369, blue: 0.000, alpha: dim),
                    tertiary:  NSColor(srgbRed: 0.851, green: 0.467, blue: 0.024, alpha: dim),
                    neutral:   fg.withAlphaComponent(dim),
                    idleDot:   NSColor(srgbRed: 0.918, green: 0.345, blue: 0.047, alpha: 1.0)
                )
            }
        }

        return IconColors(
            primary:   fg.withAlphaComponent(1.00 * dim),
            secondary: fg.withAlphaComponent((isDark ? 0.48 : 0.42) * dim),
            tertiary:  fg.withAlphaComponent((isDark ? 0.72 : 0.68) * dim),
            neutral:   fg.withAlphaComponent(1.00 * dim),
            idleDot:   NSColor(srgbRed: 0.976, green: 0.451, blue: 0.086, alpha: 1.0)
        )
    }

    static func makeImage(
        style: MenuBarIconStyle,
        colorMode: MenuBarIconColorMode,
        activeCount: Int,
        hasIdle: Bool,
        size: NSSize = NSSize(width: 18, height: 18),
        forcedDark: Bool? = nil
    ) -> NSImage {
        let useTemplate = (colorMode == .mono && forcedDark == nil)
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let isDark = forcedDark ?? (NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let c = resolveColors(colorMode: colorMode, isDark: isDark, isTemplate: useTemplate, activeCount: activeCount, hasIdle: hasIdle)

            ctx.saveGState()
            let s = min(rect.width, rect.height) / 24.0
            let dx = (rect.width - 24.0 * s) * 0.5
            let dy = (rect.height - 24.0 * s) * 0.5
            ctx.translateBy(x: dx, y: rect.height - dy)
            ctx.scaleBy(x: s, y: -s)
            ctx.setShouldAntialias(true)
            ctx.setAllowsAntialiasing(true)

            draw(style: style, in: ctx, colors: c, activeCount: activeCount, hasIdle: hasIdle)

            if hasIdle {
                ctx.setFillColor(c.idleDot.cgColor)
                ctx.fillEllipse(in: CGRect(x: 20.6 - 2.3, y: 3.8 - 2.3, width: 4.6, height: 4.6))
            }

            ctx.restoreGState()
            return true
        }
        img.isTemplate = useTemplate
        return img
    }

    private static func draw(style: MenuBarIconStyle, in ctx: CGContext, colors c: IconColors, activeCount: Int, hasIdle: Bool) {
        switch style {
        case .ribbon:
            ctx.setLineWidth(3.2)
            ctx.setLineCap(.round)
            let c1 = CGPoint(x: 8.46, y: 12.0)
            let c2 = CGPoint(x: 15.54, y: 12.0)
            let r: CGFloat = 5.0

            ctx.setStrokeColor(c.secondary.cgColor)
            ctx.beginPath()
            ctx.addArc(center: c2, radius: r, startAngle: -.pi / 4, endAngle: 3 * .pi / 4, clockwise: true)
            ctx.strokePath()

            ctx.beginPath()
            ctx.addArc(center: c1, radius: r, startAngle: 3 * .pi / 4, endAngle: .pi / 4, clockwise: true)
            ctx.strokePath()

            ctx.setStrokeColor(c.primary.cgColor)
            ctx.beginPath()
            ctx.addArc(center: c1, radius: r, startAngle: -.pi / 4, endAngle: 3 * .pi / 4, clockwise: true)
            ctx.strokePath()

            ctx.beginPath()
            ctx.addArc(center: c2, radius: r, startAngle: 3 * .pi / 4, endAngle: -.pi / 4, clockwise: true)
            ctx.strokePath()

        case .orbit:
            func strokeEllipse(rx: CGFloat, ry: CGFloat, tilt: CGFloat, tStart: CGFloat, tEnd: CGFloat, width: CGFloat, color: NSColor) {
                let steps = 56
                let cosT = cos(tilt), sinT = sin(tilt)
                ctx.beginPath()
                for i in 0...steps {
                    let t = tStart + (tEnd - tStart) * CGFloat(i) / CGFloat(steps)
                    let lx = rx * cos(t), ly = ry * sin(t)
                    let px = 12.0 + lx * cosT - ly * sinT
                    let py = 12.0 + lx * sinT + ly * cosT
                    if i == 0 { ctx.move(to: CGPoint(x: px, y: py)) }
                    else { ctx.addLine(to: CGPoint(x: px, y: py)) }
                }
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(width)
                ctx.setLineCap(.round)
                ctx.strokePath()
            }

            strokeEllipse(rx: 9.2, ry: 4.1, tilt: .pi / 6, tStart: 0, tEnd: 2 * .pi, width: 1.35, color: c.neutral.withAlphaComponent(0.28 * c.neutral.alphaComponent))
            strokeEllipse(rx: 9.2, ry: 4.1, tilt: -.pi / 6, tStart: 0.42, tEnd: 2 * .pi - 0.42, width: 1.85, color: c.secondary)

            ctx.setFillColor(c.primary.cgColor)
            ctx.fillEllipse(in: CGRect(x: 12.0 - 3.0, y: 12.0 - 3.0, width: 6.0, height: 6.0))
            ctx.fillEllipse(in: CGRect(x: 19.95 - 2.1, y: 7.40 - 2.1, width: 4.2, height: 4.2))

        case .hexcore:
            func fillPoly(_ pts: [(CGFloat, CGFloat)], color: NSColor) {
                ctx.beginPath()
                for (idx, pt) in pts.enumerated() {
                    if idx == 0 { ctx.move(to: CGPoint(x: pt.0, y: pt.1)) }
                    else { ctx.addLine(to: CGPoint(x: pt.0, y: pt.1)) }
                }
                ctx.closePath()
                ctx.setFillColor(color.cgColor)
                ctx.fillPath()
            }
            fillPoly([(12.0, 2.4), (19.8, 6.9), (12.0, 11.4), (4.2, 6.9)], color: c.primary)
            fillPoly([(3.6, 8.0), (11.3, 12.45), (11.3, 21.2), (3.6, 16.75)], color: c.secondary)
            fillPoly([(20.4, 8.0), (12.7, 12.45), (12.7, 21.2), (20.4, 16.75)], color: c.tertiary)

        case .infinity:
            ctx.setLineWidth(2.9)
            ctx.setLineCap(.round)
            ctx.setStrokeColor(c.secondary.cgColor)

            ctx.beginPath()
            ctx.move(to: CGPoint(x: 9.7, y: 9.6))
            ctx.addCurve(to: CGPoint(x: 3.5, y: 9.5), control1: CGPoint(x: 7.6, y: 7.5), control2: CGPoint(x: 4.9, y: 7.6))
            ctx.addCurve(to: CGPoint(x: 4.2, y: 15.1), control1: CGPoint(x: 2.2, y: 11.2), control2: CGPoint(x: 2.5, y: 13.7))
            ctx.addCurve(to: CGPoint(x: 9.2, y: 14.8), control1: CGPoint(x: 5.6, y: 16.2), control2: CGPoint(x: 7.6, y: 16.1))
            ctx.strokePath()

            ctx.beginPath()
            ctx.move(to: CGPoint(x: 14.8, y: 9.2))
            ctx.addCurve(to: CGPoint(x: 19.8, y: 8.9), control1: CGPoint(x: 16.4, y: 7.9), control2: CGPoint(x: 18.4, y: 7.8))
            ctx.addCurve(to: CGPoint(x: 20.5, y: 14.5), control1: CGPoint(x: 21.5, y: 10.3), control2: CGPoint(x: 21.8, y: 12.8))
            ctx.addCurve(to: CGPoint(x: 14.3, y: 14.4), control1: CGPoint(x: 19.1, y: 16.4), control2: CGPoint(x: 16.4, y: 16.5))
            ctx.strokePath()

            ctx.setStrokeColor(c.primary.cgColor)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: 7.6, y: 15.6))
            ctx.addCurve(to: CGPoint(x: 12.0, y: 12.0), control1: CGPoint(x: 9.8, y: 15.4), control2: CGPoint(x: 10.9, y: 13.6))
            ctx.addCurve(to: CGPoint(x: 16.4, y: 8.4), control1: CGPoint(x: 13.1, y: 10.4), control2: CGPoint(x: 14.2, y: 8.6))
            ctx.strokePath()

            ctx.setFillColor(c.primary.cgColor)
            ctx.fillEllipse(in: CGRect(x: 17.8 - 1.45, y: 12.0 - 1.45, width: 2.9, height: 2.9))

        case .chip:
            ctx.setStrokeColor(c.secondary.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineCap(.round)
            let pins: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (9.0, 2.4, 9.0, 4.4), (15.0, 2.4, 15.0, 4.4),
                (9.0, 19.6, 9.0, 21.6), (15.0, 19.6, 15.0, 21.6),
                (2.4, 9.0, 4.4, 9.0), (2.4, 15.0, 4.4, 15.0),
                (19.6, 9.0, 21.6, 9.0), (19.6, 15.0, 21.6, 15.0)
            ]
            for p in pins {
                ctx.beginPath()
                ctx.move(to: CGPoint(x: p.0, y: p.1))
                ctx.addLine(to: CGPoint(x: p.2, y: p.3))
                ctx.strokePath()
            }

            let housing = CGPath(roundedRect: CGRect(x: 4.6, y: 4.6, width: 14.8, height: 14.8), cornerWidth: 3.4, cornerHeight: 3.4, transform: nil)
            ctx.addPath(housing)
            ctx.setStrokeColor(c.neutral.cgColor)
            ctx.setLineWidth(1.75)
            ctx.strokePath()

            let b1: CGFloat = (activeCount == 0 && !hasIdle) ? 14.3 : (hasIdle ? 12.6 : (activeCount >= 2 ? 9.8 : 11.4))
            let b2: CGFloat = (activeCount == 0 && !hasIdle) ? 14.3 : (hasIdle ? 11.2 : 8.2)
            let b3: CGFloat = (activeCount == 0 && !hasIdle) ? 14.3 : (hasIdle ? 13.4 : (activeCount >= 2 ? 10.6 : 12.6))
            let barColor = hasIdle ? c.idleDot : c.primary
            ctx.setStrokeColor(barColor.cgColor)
            ctx.setLineWidth(2.1)
            ctx.setLineCap(.round)
            for (x, topY) in [(CGFloat(8.8), b1), (CGFloat(12.0), b2), (CGFloat(15.2), b3)] {
                ctx.beginPath()
                ctx.move(to: CGPoint(x: x, y: 15.4))
                ctx.addLine(to: CGPoint(x: x, y: topY))
                ctx.strokePath()
            }

        case .spark:
            ctx.beginPath()
            ctx.move(to: CGPoint(x: 10.8, y: 2.4))
            ctx.addQuadCurve(to: CGPoint(x: 19.6, y: 12.0), control: CGPoint(x: 11.8, y: 10.8))
            ctx.addQuadCurve(to: CGPoint(x: 10.8, y: 21.6), control: CGPoint(x: 11.8, y: 13.2))
            ctx.addQuadCurve(to: CGPoint(x: 2.0, y: 12.0), control: CGPoint(x: 9.8, y: 13.2))
            ctx.addQuadCurve(to: CGPoint(x: 10.8, y: 2.4), control: CGPoint(x: 9.8, y: 10.8))
            ctx.closePath()
            ctx.setFillColor(c.primary.cgColor)
            ctx.fillPath()

            ctx.beginPath()
            ctx.move(to: CGPoint(x: 18.6, y: 3.0))
            ctx.addQuadCurve(to: CGPoint(x: 21.8, y: 6.4), control: CGPoint(x: 19.1, y: 5.9))
            ctx.addQuadCurve(to: CGPoint(x: 18.6, y: 9.8), control: CGPoint(x: 19.1, y: 6.9))
            ctx.addQuadCurve(to: CGPoint(x: 15.4, y: 6.4), control: CGPoint(x: 18.1, y: 6.9))
            ctx.addQuadCurve(to: CGPoint(x: 18.6, y: 3.0), control: CGPoint(x: 18.1, y: 5.9))
            ctx.closePath()
            ctx.setFillColor(c.secondary.cgColor)
            ctx.fillPath()
        }
    }
}

// MARK: - Log Parsing & Syntax Highlighting

enum SyntaxPalette {
    private static func adaptive(dark: (CGFloat, CGFloat, CGFloat), light: (CGFloat, CGFloat, CGFloat)) -> Color {
        let ns = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1.0)
        }
        return Color(nsColor: ns)
    }

    static let keyword     = adaptive(dark: (1.00, 0.48, 0.70), light: (0.68, 0.24, 0.64))
    static let string      = adaptive(dark: (0.49, 0.83, 0.66), light: (0.11, 0.50, 0.30))
    static let funcCall    = adaptive(dark: (0.42, 0.87, 1.00), light: (0.05, 0.42, 0.66))
    static let param       = adaptive(dark: (0.83, 0.75, 1.00), light: (0.41, 0.25, 0.78))
    static let number      = adaptive(dark: (1.00, 0.72, 0.42), light: (0.71, 0.33, 0.04))
    static let typeName    = adaptive(dark: (0.95, 0.84, 0.55), light: (0.58, 0.38, 0.06))
    static let comment     = adaptive(dark: (0.49, 0.52, 0.57), light: (0.43, 0.47, 0.51))
    static let punctuation = adaptive(dark: (0.56, 0.56, 0.61), light: (0.43, 0.43, 0.46))
    static let dim         = adaptive(dark: (0.44, 0.44, 0.49), light: (0.55, 0.55, 0.58))
    static let execAccent  = adaptive(dark: (0.56, 0.58, 1.00), light: (0.35, 0.34, 0.84))
    static let dlAccent    = adaptive(dark: (0.35, 0.82, 0.78), light: (0.06, 0.52, 0.49))
    static let ulAccent    = adaptive(dark: (0.42, 0.70, 1.00), light: (0.12, 0.44, 0.82))
    static let autoAccent  = adaptive(dark: (0.73, 0.62, 0.96), light: (0.49, 0.32, 0.76))
}

enum LogKind: Equatable {
    case exec
    case fileDownload
    case fileUpload
    case fileOther
    case event
    case auto
    case warn
    case error
    case other

    var badge: String {
        switch self {
        case .exec:         return "EXEC"
        case .fileDownload: return "↓ FILE"
        case .fileUpload:   return "↑ FILE"
        case .fileOther:    return "FILE"
        case .event:        return "EVENT"
        case .auto:         return "AUTO"
        case .warn:         return "WARN"
        case .error:        return "ERR"
        case .other:        return "LOG"
        }
    }

    var accent: Color {
        switch self {
        case .exec:         return SyntaxPalette.execAccent
        case .fileDownload: return SyntaxPalette.dlAccent
        case .fileUpload:   return SyntaxPalette.ulAccent
        case .fileOther:    return SyntaxPalette.funcCall
        case .event:        return Color.secondary
        case .auto:         return SyntaxPalette.autoAccent
        case .warn:         return Color.orange
        case .error:        return Color.red
        case .other:        return Color.secondary
        }
    }

    var isCompactSingleLine: Bool {
        self == .event || self == .auto
    }
}

struct ParsedLogEntry: Equatable {
    let time: String?
    let kind: LogKind
    let payload: String
    let raw: String
}

enum LogSyntax {
    private static let pythonKeywords: Set<String> = [
        "import", "from", "as", "def", "class", "return", "if", "elif", "else",
        "for", "in", "while", "with", "try", "except", "finally", "raise",
        "pass", "break", "continue", "yield", "lambda", "and", "or", "not",
        "is", "del", "global", "nonlocal", "assert", "async", "await",
        "export", "cd", "mkdir", "rm", "cp", "mv", "tar", "pip", "uv",
        "python", "python3", "bash", "sh", "echo", "cat", "grep", "awk", "sed"
    ]

    private static let pythonConstants: Set<String> = [
        "True", "False", "None", "NotImplemented", "Ellipsis"
    ]

    private static let pythonBuiltins: Set<String> = [
        "print", "len", "range", "open", "int", "float", "str", "bool",
        "dict", "list", "set", "tuple", "bytes", "isinstance", "issubclass",
        "enumerate", "zip", "map", "filter", "sum", "min", "max", "abs",
        "round", "sorted", "reversed", "any", "all", "type", "super",
        "getattr", "setattr", "hasattr", "dir", "vars", "id", "hash"
    ]

    private static let compoundExtensions: [String] = [
        ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".csv.gz", ".json.gz", ".jsonl.gz"
    ]

    static func parseUTCDate(_ stamp: String) -> Date? {
        let parts = stamp.split(separator: " ")
        guard parts.count == 2 else { return nil }
        let d = parts[0].split(separator: "-")
        let t = parts[1].split(separator: ":")
        guard d.count == 3, t.count == 3,
              let year = Int(d[0]), let month = Int(d[1]), let day = Int(d[2]),
              let hour = Int(t[0]), let minute = Int(t[1]), let second = Int(t[2]) else {
            return nil
        }
        var comps = DateComponents()
        comps.calendar = Calendar(identifier: .gregorian)
        comps.timeZone = TimeZone(secondsFromGMT: 0)
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        return comps.date
    }

    static func extractLineDate(_ line: String) -> Date? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return nil }
        let inner = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        return parseUTCDate(inner)
    }

    static func utcTimestampToLocalTime(_ stamp: String) -> String? {
        guard let date = parseUTCDate(stamp) else { return nil }
        let local = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", local.hour ?? 0, local.minute ?? 0, local.second ?? 0)
    }

    static func plainLocal(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return trimmed }
        let inner = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        let rest = String(trimmed[trimmed.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        if let local = utcTimestampToLocalTime(inner) {
            return "[\(local)] \(rest)"
        }
        return trimmed
    }

    static func parse(_ line: String) -> ParsedLogEntry {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var timeStr: String? = nil
        var body = trimmed

        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            let inner = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let after = String(trimmed[trimmed.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            if let local = utcTimestampToLocalTime(inner) {
                timeStr = local
                body = after
            } else if inner.count == 8, inner.filter({ $0 == ":" }).count == 2 {
                timeStr = inner
                body = after
            }
        }

        let upper = body.uppercased()
        if upper.hasPrefix("EXEC:") {
            return ParsedLogEntry(time: timeStr, kind: .exec, payload: String(body.dropFirst(5)).trimmingCharacters(in: .whitespaces), raw: trimmed)
        }
        if upper.hasPrefix("FILE:") {
            let rest = String(body.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            let low = rest.lowercased()
            if low.hasPrefix("download ") {
                return ParsedLogEntry(time: timeStr, kind: .fileDownload, payload: String(rest.dropFirst(9)).trimmingCharacters(in: .whitespaces), raw: trimmed)
            }
            if low.hasPrefix("upload ") {
                return ParsedLogEntry(time: timeStr, kind: .fileUpload, payload: String(rest.dropFirst(7)).trimmingCharacters(in: .whitespaces), raw: trimmed)
            }
            return ParsedLogEntry(time: timeStr, kind: .fileOther, payload: rest, raw: trimmed)
        }
        if upper.hasPrefix("EVENT:") {
            return ParsedLogEntry(time: timeStr, kind: .event, payload: String(body.dropFirst(6)).trimmingCharacters(in: .whitespaces), raw: trimmed)
        }
        if upper.hasPrefix("AUTO:") {
            return ParsedLogEntry(time: timeStr, kind: .auto, payload: String(body.dropFirst(5)).trimmingCharacters(in: .whitespaces), raw: trimmed)
        }
        if upper.hasPrefix("ERROR:") || upper.hasPrefix("ERR:") {
            let drop = upper.hasPrefix("ERROR:") ? 6 : 4
            return ParsedLogEntry(time: timeStr, kind: .error, payload: String(body.dropFirst(drop)).trimmingCharacters(in: .whitespaces), raw: trimmed)
        }
        if upper.hasPrefix("WARN:") || upper.hasPrefix("WARNING:") {
            let drop = upper.hasPrefix("WARNING:") ? 8 : 5
            return ParsedLogEntry(time: timeStr, kind: .warn, payload: String(body.dropFirst(drop)).trimmingCharacters(in: .whitespaces), raw: trimmed)
        }
        return ParsedLogEntry(time: timeStr, kind: .other, payload: body, raw: trimmed)
    }

    static func splitFilePath(_ path: String) -> (dir: String, stem: String, ext: String) {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        let dir: String
        let filename: String
        if let slash = trimmed.lastIndex(of: "/") {
            dir = String(trimmed[...slash])
            filename = String(trimmed[trimmed.index(after: slash)...])
        } else {
            dir = ""
            filename = trimmed
        }
        let lowerName = filename.lowercased()
        for ext in compoundExtensions where lowerName.hasSuffix(ext) && filename.count > ext.count {
            let stemEnd = filename.index(filename.endIndex, offsetBy: -ext.count)
            return (dir, String(filename[..<stemEnd]), String(filename[stemEnd...]))
        }
        if let dot = filename.lastIndex(of: "."), dot != filename.startIndex {
            return (dir, String(filename[..<dot]), String(filename[dot...]))
        }
        return (dir, filename, "")
    }

    static func extensionColor(_ ext: String) -> Color {
        switch ext.lowercased() {
        case ".nc", ".npy", ".npz", ".h5", ".hdf5", ".parquet", ".feather", ".zarr",
             ".tif", ".tiff", ".pt", ".pth", ".ckpt", ".safetensors", ".onnx":
            return SyntaxPalette.funcCall
        case ".json", ".jsonl", ".csv", ".tsv", ".yaml", ".yml", ".toml", ".xml", ".md", ".txt", ".log":
            return SyntaxPalette.string
        case ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tgz", ".zip", ".gz", ".bz2", ".xz", ".zst", ".tar":
            return SyntaxPalette.number
        case ".py", ".sh", ".bash", ".zsh", ".r", ".jl", ".sql", ".ipynb", ".swift":
            return SyntaxPalette.keyword
        default:
            return SyntaxPalette.param
        }
    }

    static func highlightFileName(_ path: String) -> AttributedString {
        let (_, stem, ext) = splitFilePath(path)
        var out = AttributedString()

        var sPart = AttributedString(stem.isEmpty ? path : stem)
        sPart.foregroundColor = .primary
        sPart.font = .system(size: 10.5, weight: .semibold, design: .monospaced)
        out.append(sPart)

        if !ext.isEmpty {
            var ePart = AttributedString(ext)
            ePart.foregroundColor = extensionColor(ext)
            ePart.font = .system(size: 10.5, weight: .semibold, design: .monospaced)
            out.append(ePart)
        }
        return out
    }

    static func highlightCode(_ code: String) -> AttributedString {
        let chars = Array(code)
        let n = chars.count
        var out = AttributedString()
        var i = 0

        func emit(_ text: String, color: Color, weight: Font.Weight = .regular, italic: Bool = false) {
            var seg = AttributedString(text)
            seg.foregroundColor = color
            var font = Font.system(size: 10.5, weight: weight, design: .monospaced)
            if italic { font = font.italic() }
            seg.font = font
            out.append(seg)
        }

        while i < n {
            let ch = chars[i]

            if ch.isWhitespace {
                let start = i
                while i < n && chars[i].isWhitespace { i += 1 }
                emit(String(chars[start..<i]), color: .primary)
                continue
            }

            if ch == "." && i + 2 < n && chars[i + 1] == "." && chars[i + 2] == "." {
                emit("...", color: SyntaxPalette.dim)
                i += 3
                continue
            }
            if ch == "…" {
                emit("…", color: SyntaxPalette.dim)
                i += 1
                continue
            }

            if ch == "#" {
                let start = i
                while i < n && chars[i] != "\n" { i += 1 }
                emit(String(chars[start..<i]), color: SyntaxPalette.comment, italic: true)
                continue
            }

            if (ch == "'" || ch == "\"") ||
                ("frbuFRBU".contains(ch) && i + 1 < n && (chars[i + 1] == "'" || chars[i + 1] == "\"")) {
                var quoteStart = i
                if ch != "'" && ch != "\"" {
                    emit(String(ch), color: SyntaxPalette.keyword, weight: .medium)
                    quoteStart = i + 1
                }
                let quote = chars[quoteStart]
                var j = quoteStart + 1
                while j < n {
                    if chars[j] == "\\" && j + 1 < n {
                        j += 2
                        continue
                    }
                    if chars[j] == quote {
                        j += 1
                        break
                    }
                    if chars[j] == "." && j + 2 == n - 1 && chars[j + 1] == "." && chars[j + 2] == "." {
                        break
                    }
                    j += 1
                }
                emit(String(chars[quoteStart..<j]), color: SyntaxPalette.string)
                i = j
                continue
            }

            if ch == "-" && (i == 0 || chars[i - 1].isWhitespace) && i + 1 < n &&
                (chars[i + 1].isLetter || chars[i + 1] == "-") {
                let start = i
                i += 1
                while i < n && (chars[i].isLetter || chars[i].isNumber || chars[i] == "-" || chars[i] == "_") {
                    i += 1
                }
                emit(String(chars[start..<i]), color: SyntaxPalette.param)
                continue
            }

            if ch == "/" && (i == 0 || chars[i - 1].isWhitespace || chars[i - 1] == "=") &&
                i + 1 < n && !chars[i + 1].isWhitespace {
                let start = i
                while i < n && !chars[i].isWhitespace && !",);'\"`".contains(chars[i]) {
                    if chars[i] == "." && i + 2 < n && chars[i + 1] == "." && chars[i + 2] == "." { break }
                    i += 1
                }
                emit(String(chars[start..<i]), color: SyntaxPalette.string)
                continue
            }

            if ch.isNumber {
                let start = i
                i += 1
                while i < n && (chars[i].isNumber || chars[i] == "_" || chars[i] == "x" || chars[i] == "X" ||
                                chars[i] == "e" || chars[i] == "E" ||
                                (chars[i] == "." && i + 1 < n && chars[i + 1].isNumber)) {
                    i += 1
                }
                emit(String(chars[start..<i]), color: SyntaxPalette.number)
                continue
            }

            if ch.isLetter || ch == "_" {
                let start = i
                i += 1
                while i < n && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                    i += 1
                }
                let word = String(chars[start..<i])

                var k = i
                while k < n && chars[k] == " " { k += 1 }
                let nextCh: Character? = k < n ? chars[k] : nil
                let nextNextCh: Character? = (k + 1 < n) ? chars[k + 1] : nil
                let followedByEllipsis = (i + 2 < n && chars[i] == "." && chars[i + 1] == "." && chars[i + 2] == ".")

                if pythonKeywords.contains(word) {
                    emit(word, color: SyntaxPalette.keyword, weight: .medium)
                } else if pythonConstants.contains(word) ||
                            (followedByEllipsis && ("True".hasPrefix(word) || "False".hasPrefix(word) || "None".hasPrefix(word)) && word.count >= 2) {
                    emit(word, color: SyntaxPalette.number, weight: .medium)
                } else if word == "self" || word == "cls" {
                    emit(word, color: SyntaxPalette.param, italic: true)
                } else if pythonBuiltins.contains(word) || nextCh == "(" {
                    emit(word, color: SyntaxPalette.funcCall)
                } else if nextCh == "=" && nextNextCh != "=" {
                    emit(word, color: SyntaxPalette.param)
                } else if word.first?.isUppercase == true {
                    emit(word, color: SyntaxPalette.typeName)
                } else {
                    emit(word, color: .primary)
                }
                continue
            }

            if ";,.()[]{}=:+-*/%<>!&|^~@\\".contains(ch) {
                emit(String(ch), color: SyntaxPalette.punctuation)
                i += 1
                continue
            }

            emit(String(ch), color: .primary)
            i += 1
        }

        return out
    }

    static func highlight(_ entry: ParsedLogEntry) -> AttributedString {
        switch entry.kind {
        case .exec:
            return highlightCode(entry.payload)
        case .fileDownload, .fileUpload, .fileOther:
            return highlightFileName(entry.payload)
        case .event, .auto:
            var s = AttributedString(entry.payload)
            s.foregroundColor = .secondary
            s.font = .system(size: 10.5, weight: .regular, design: .monospaced)
            return s
        case .warn:
            var s = AttributedString(entry.payload)
            s.foregroundColor = .orange
            s.font = .system(size: 10.5, weight: .regular, design: .monospaced)
            return s
        case .error:
            var s = AttributedString(entry.payload)
            s.foregroundColor = .red
            s.font = .system(size: 10.5, weight: .regular, design: .monospaced)
            return s
        case .other:
            return highlightCode(entry.payload)
        }
    }
}

struct LogRowView: View {
    let entry: ParsedLogEntry

    var body: some View {
        if entry.kind.isCompactSingleLine {
            HStack(spacing: 6) {
                badgePill
                Text(entry.payload)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let t = entry.time {
                    Text(t)
                        .font(.system(size: 9.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 7)
            .padding(.vertical, 4)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(entry.kind.accent.opacity(0.45))
                    .frame(width: 2)
                    .padding(.vertical, 3)
            }
        } else {
            VStack(alignment: .leading, spacing: 3.5) {
                HStack(spacing: 6) {
                    badgePill
                    Spacer(minLength: 4)
                    if let t = entry.time {
                        Text(t)
                            .font(.system(size: 9.5, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }

                if entry.kind == .fileDownload || entry.kind == .fileUpload || entry.kind == .fileOther {
                    let parts = LogSyntax.splitFilePath(entry.payload)
                    VStack(alignment: .leading, spacing: 1.5) {
                        Text(LogSyntax.highlightFileName(entry.payload))
                            .lineSpacing(1.5)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if !parts.dir.isEmpty {
                            Text(parts.dir)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(SyntaxPalette.dim)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                } else {
                    Text(LogSyntax.highlight(entry))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 7)
            .padding(.vertical, 5.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                entry.kind == .exec
                    ? Color.primary.opacity(0.035)
                    : Color.primary.opacity(0.02)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(entry.kind.accent.opacity(0.8))
                    .frame(width: 2)
                    .padding(.vertical, 3)
            }
        }
    }

    private var badgePill: some View {
        Text(entry.kind.badge)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(entry.kind.accent)
            .padding(.horizontal, 4.5)
            .padding(.vertical, 1)
            .background(entry.kind.accent.opacity(0.13))
            .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(entry.kind.accent.opacity(0.22), lineWidth: 0.5)
            )
    }
}

// MARK: - SwiftUI Views

struct PopoverRootView: View {
    static let width: CGFloat = 348
    static let height: CGFloat = 436

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: MonitorStore
    @State private var activeTab: PopoverTab
    @State private var showAppearance: Bool
    @State private var expandedId: String? = nil
    @State private var hasAutoExpanded: Bool = false
    @State private var logFilterId: String = "all"
    @State private var historyFilter: String = "all"
    @State private var selectedHistoryId: String? = nil
    @State private var historyNewestFirst: Bool = true
    @State private var copiedHistory: Bool = false
    @State private var confirmStopId: String? = nil
    @State private var confirmStopAll: Bool = false
    @State private var copiedId: String? = nil
    @State private var copiedLogs: Bool = false

    init(
        store: MonitorStore,
        initialTab: PopoverTab = .sessions,
        showAppearance: Bool = false,
        selectedHistoryId: String? = nil,
        expandedId: String? = nil
    ) {
        self.store = store
        self._activeTab = State(initialValue: initialTab)
        self._showAppearance = State(initialValue: showAppearance)
        self._selectedHistoryId = State(initialValue: selectedHistoryId)
        self._expandedId = State(initialValue: expandedId)
        if expandedId != nil {
            self._hasAutoExpanded = State(initialValue: true)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            if let idleFirst = store.idleSessions.first {
                idleBanner(idleFirst)
            }
            if let err = store.errorMessage {
                errorBanner(err)
            }
            segmentedTabs
            contentArea
            footerView
        }
        .frame(width: Self.width, height: Self.height, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
        .onAppear {
            if !hasAutoExpanded, let first = store.sessions.first?.id {
                expandedId = first
                hasAutoExpanded = true
            }
        }
        .onChange(of: store.sessions) { _, newList in
            if !hasAutoExpanded, let first = newList.first?.id {
                expandedId = first
                hasAutoExpanded = true
            } else if let exp = expandedId, !newList.contains(where: { $0.id == exp }) {
                expandedId = newList.first?.id
            }
            if logFilterId != "all", !newList.contains(where: { $0.id == logFilterId }) {
                logFilterId = "all"
            }
        }
        .onChange(of: store.uiResetToken) { _, _ in
            confirmStopId = nil
            confirmStopAll = false
            showAppearance = false
        }
    }

    // MARK: Header
    private var headerView: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(String(format: "%.1f", store.balance))
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                    Text("u.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(String(format: "%.2f u./hr", store.usageRate))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(store.hasIdle ? Color.orange : Color.primary)
                }
                Text(store.email)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Text("\(store.sessions.count) active")
                        .font(.system(size: 11.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if store.externalAssignments > 0 {
                        Text("+\(store.externalAssignments) web")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                }
                HStack(spacing: 3) {
                    ForEach(0..<max(1, min(store.sessions.count, 6)), id: \.self) { idx in
                        let isGpu = idx < store.sessions.count ? store.sessions[idx].isGPU : false
                        Capsule()
                            .fill(store.sessions.isEmpty ? Color.secondary.opacity(0.25) : (isGpu ? Color.orange.opacity(0.85) : Color.primary.opacity(0.65)))
                            .frame(width: store.sessions.isEmpty ? 28 : 11, height: 3.5)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 11)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.45)
        }
    }

    // MARK: IDLE Alert Strip
    private func idleBanner(_ session: ColabSession) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
            Text("\(session.id) idle (\(session.tierLabel))")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.orange)
                .lineLimit(1)
            Spacer()
            Button(confirmStopId == session.id ? "Confirm" : "Stop") {
                if confirmStopId == session.id {
                    confirmStopId = nil
                    store.stopSession(session.id)
                } else {
                    confirmStopId = session.id
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(confirmStopId == session.id ? Color.red : Color.orange.opacity(0.14))
            .foregroundStyle(confirmStopId == session.id ? Color.white : Color.orange)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(confirmStopId == session.id ? Color.clear : Color.orange.opacity(0.45), lineWidth: 0.75)
            )
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.06))
        .overlay(alignment: .bottom) { Divider().opacity(0.45) }
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 11.5))
                .foregroundStyle(.red)
            Text(msg)
                .font(.system(size: 11.5))
                .foregroundStyle(.red)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.red.opacity(0.08))
        .overlay(alignment: .bottom) { Divider().opacity(0.45) }
    }

    // MARK: Segmented Tabs
    private var segmentedTabs: some View {
        HStack(spacing: 2) {
            tabPill(tab: .sessions, label: "Sessions", count: store.sessions.count)
            tabPill(tab: .logs, label: "Logs", count: nil)
            tabPill(tab: .history, label: "History", count: nil)
        }
        .padding(2.5)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func tabPill(tab: PopoverTab, label: String, count: Int?) -> some View {
        let selected = (!showAppearance && activeTab == tab)
        return Button {
            if tab == .history {
                if activeTab == .history && !showAppearance {
                    selectedHistoryId = nil
                }
                store.loadHistory(force: false)
            }
            showAppearance = false
            activeTab = tab
            confirmStopId = nil
            confirmStopAll = false
        } label: {
            HStack(spacing: 3.5) {
                Text(label)
                    .lineLimit(1)
                if let c = count {
                    Text("\(c)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .opacity(0.65)
                }
            }
            .font(.system(size: 11.5, weight: selected ? .medium : .regular))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(selected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
            .foregroundStyle(selected ? .primary : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: selected ? Color.black.opacity(0.14) : .clear, radius: 1.5, y: 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Content (fixed height — zero NSPopover jump)
    private var contentArea: some View {
        Group {
            if showAppearance {
                appearancePane
            } else if activeTab == .sessions {
                sessionsPane
            } else if activeTab == .logs {
                logsPane
            } else {
                historyPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    // MARK: Appearance & Settings Pane
    private var appearancePane: some View {
        let cols = [
            GridItem(.flexible(), spacing: 7),
            GridItem(.flexible(), spacing: 7),
            GridItem(.flexible(), spacing: 7)
        ]
        let isDark = (colorScheme == .dark)

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6.5) {
                HStack {
                    Text("Menu bar icon")
                        .font(.system(size: 11.5, weight: .semibold))
                    Spacer()
                    Button("Done") {
                        showAppearance = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .contentShape(Rectangle())
                }

                LazyVGrid(columns: cols, spacing: 6) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        let isSelected = (store.iconStyle == style)
                        let img = MenuBarIconFactory.makeImage(
                            style: style,
                            colorMode: store.iconColorMode,
                            activeCount: max(1, store.sessions.count),
                            hasIdle: false,
                            size: NSSize(width: 22, height: 22),
                            forcedDark: isDark
                        )
                        Button {
                            store.iconStyle = style
                        } label: {
                            VStack(spacing: 3) {
                                Image(nsImage: img)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: 22, height: 22)
                                Text(style.title)
                                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                                    .foregroundStyle(isSelected ? .primary : .secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 4)
                            .background(
                                isSelected
                                    ? (store.iconColorMode == .color ? Color.orange.opacity(0.11) : Color.primary.opacity(0.09))
                                    : Color.primary.opacity(0.03)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(
                                        isSelected
                                            ? (store.iconColorMode == .color ? Color.orange.opacity(0.75) : Color.primary.opacity(0.55))
                                            : Color.primary.opacity(0.08),
                                        lineWidth: isSelected ? 1.2 : 0.6
                                    )
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Color vs Monochrome
                HStack(spacing: 8) {
                    Text("Finish")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)

                    HStack(spacing: 2) {
                        ForEach(MenuBarIconColorMode.allCases) { mode in
                            let on = (store.iconColorMode == mode)
                            Button {
                                store.iconColorMode = mode
                            } label: {
                                HStack(spacing: 5) {
                                    if mode == .color {
                                        Circle()
                                            .fill(
                                                LinearGradient(
                                                    colors: [Color(red: 0.98, green: 0.75, blue: 0.14), Color(red: 0.92, green: 0.35, blue: 0.05)],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .frame(width: 7.5, height: 7.5)
                                    } else {
                                        Image(systemName: "circle.lefthalf.filled")
                                            .font(.system(size: 9))
                                    }
                                    Text(mode.label)
                                        .font(.system(size: 10.5, weight: on ? .medium : .regular))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 3.5)
                                .background(on ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                                .foregroundStyle(on ? .primary : .secondary)
                                .clipShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
                                .shadow(color: on ? Color.black.opacity(0.12) : .clear, radius: 1, y: 0.5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }

                // Bar density
                HStack(spacing: 8) {
                    Text("Bar")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)

                    HStack(spacing: 2) {
                        ForEach(BarDensity.allCases, id: \.rawValue) { d in
                            let on = (store.density == d)
                            Button {
                                store.density = d
                            } label: {
                                Text(d.shortLabel)
                                    .font(.system(size: 10, weight: on ? .medium : .regular, design: .monospaced))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 3.5)
                                    .background(on ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                                    .foregroundStyle(on ? .primary : .secondary)
                                    .clipShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
                                    .shadow(color: on ? Color.black.opacity(0.12) : .clear, radius: 1, y: 0.5)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }

                // CLI Auth Mode
                HStack(spacing: 8) {
                    Text("Auth")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)

                    HStack(spacing: 2) {
                        ForEach(ColabAuthMode.allCases) { m in
                            let on = (store.authMode == m)
                            Button {
                                store.authMode = m
                            } label: {
                                Text(m.label)
                                    .font(.system(size: 10, weight: on ? .medium : .regular, design: .monospaced))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 3.5)
                                    .background(on ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                                    .foregroundStyle(on ? .primary : .secondary)
                                    .clipShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
                                    .shadow(color: on ? Color.black.opacity(0.12) : .clear, radius: 1, y: 0.5)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }

                // Compact side-by-side Launch at Login & Alerts toggles
                HStack(spacing: 6) {
                    compactToggleChip(icon: "power.circle", title: "At login", isOn: $store.launchAtLogin)
                        .help("Launch ColabMonitor automatically at login")
                    compactToggleChip(icon: "bell", title: "Alerts", isOn: $store.notificationsEnabled)
                        .help("Notify when a VM finishes or stays IDLE for 5+ min")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func compactToggleChip(icon: String, title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 2)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        )
    }

    // MARK: Sessions Pane
    private var sessionsPane: some View {
        Group {
            if store.sessions.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "link")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 2)
                    Text("No active CLI sessions")
                        .font(.system(size: 12.5, weight: .medium))
                    Text(store.externalAssignments > 0
                         ? "\(store.externalAssignments) external session(s) active in browser"
                         : "0.00 u./hr billed · refreshes every 90s")
                        .font(.system(size: 11.5))
                        .foregroundStyle(store.externalAssignments > 0 ? Color.orange : Color.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
            } else {
                ScrollView {
                    VStack(spacing: 7) {
                        ForEach(store.sessions) { s in
                            sessionCard(s)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func sessionCard(_ s: ColabSession) -> some View {
        let isOpen = (expandedId == s.id)
        let isConfirming = (confirmStopId == s.id)
        let isStopping = store.stoppingIds.contains(s.id)

        return VStack(spacing: 0) {
            Button {
                expandedId = isOpen ? nil : s.id
                confirmStopId = nil
                confirmStopAll = false
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(s.isIdle ? Color.orange : Color.green.opacity(0.85))
                        .frame(width: 6.5, height: 6.5)
                        .padding(.top, 5)

                    VStack(alignment: .leading, spacing: 2.5) {
                        HStack(spacing: 6) {
                            Text(s.id)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                            Text(s.tierLabel)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(s.isGPU ? Color.orange : Color.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(s.isGPU ? Color.orange.opacity(0.4) : Color.primary.opacity(0.08), lineWidth: 0.5)
                                )
                            if s.isIdle {
                                Text("IDLE")
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.orange)
                            }
                        }

                        Text(isStopping ? "Stopping…" : (s.activeTask ?? (s.logs.last.map(Self.formatLogLine) ?? s.shapeSummary)))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(isStopping ? Color.orange : Color.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    Divider().opacity(0.4)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(s.shapeSummary)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(s.shortEndpoint)
                                .foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 11, design: .monospaced))

                        if !s.cleanLastExec.isEmpty {
                            Text("Last run: \(s.cleanLastExec)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    HStack(spacing: 6) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(store.sshCommand(for: s.id), forType: .string)
                            copiedId = s.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                                if copiedId == s.id { copiedId = nil }
                            }
                        } label: {
                            Label(copiedId == s.id ? "Copied" : "SSH", systemImage: copiedId == s.id ? "checkmark" : "terminal")
                                .font(.system(size: 11.5))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            logFilterId = s.id
                            confirmStopId = nil
                            activeTab = .logs
                        } label: {
                            Label("Logs", systemImage: "text.alignleft")
                                .font(.system(size: 11.5))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button {
                            guard !isStopping else { return }
                            if isConfirming {
                                confirmStopId = nil
                                store.stopSession(s.id)
                            } else {
                                confirmStopId = s.id
                            }
                        } label: {
                            Label(isStopping ? "Stopping…" : (isConfirming ? "Confirm?" : "Stop"), systemImage: "stop.fill")
                                .font(.system(size: 11.5, weight: isConfirming ? .medium : .regular))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(isConfirming ? Color.red : Color.clear)
                                .foregroundStyle(isConfirming ? Color.white : Color.secondary)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(isConfirming ? Color.clear : Color.primary.opacity(0.12), lineWidth: 0.5)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isStopping)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.bottom, 10)
            }
        }
        .background(isOpen ? Color.primary.opacity(0.05) : Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(s.isIdle ? Color.orange.opacity(0.55) : Color.primary.opacity(0.1), lineWidth: 0.65)
        )
    }

    // MARK: Logs Pane
    private var logsPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.sessions.isEmpty {
                Spacer()
                Text("No active logs.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                HStack(spacing: 6) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            filterChip(id: "all", title: "All")
                            ForEach(store.sessions) { s in
                                filterChip(id: s.id, title: s.id)
                            }
                        }
                    }

                    Button {
                        let text = store.sessions
                            .filter { logFilterId == "all" || $0.id == logFilterId }
                            .map { s in "=== \(s.id) ===\n" + s.logs.map(Self.formatLogLine).joined(separator: "\n") }
                            .joined(separator: "\n\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        copiedLogs = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { copiedLogs = false }
                    } label: {
                        Image(systemName: copiedLogs ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Copy displayed logs")
                }
                .fixedSize(horizontal: false, vertical: true)

                let maxLines = (logFilterId == "all") ? 6 : 25
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(store.sessions.filter { logFilterId == "all" || $0.id == logFilterId }) { s in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(s.isIdle ? Color.orange : Color.green.opacity(0.85))
                                        .frame(width: 5.5, height: 5.5)
                                    Text(s.id)
                                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                    Spacer()
                                    Text("\(s.tierLabel) · \(s.status)")
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(s.isIdle ? Color.orange : Color.secondary)
                                }
                                if s.logs.isEmpty {
                                    Text("(no recent events)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                } else {
                                    VStack(alignment: .leading, spacing: 5) {
                                        ForEach(Array(s.logs.suffix(maxLines).reversed().enumerated()), id: \.offset) { _, line in
                                            LogRowView(entry: LogSyntax.parse(line))
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    static func formatLogLine(_ line: String) -> String {
        LogSyntax.plainLocal(line)
    }

    private func filterChip(id: String, title: String) -> some View {
        let on = (logFilterId == id)
        return Button(title) {
            logFilterId = id
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(on ? Color.primary : Color.primary.opacity(0.05))
        .foregroundStyle(on ? Color(nsColor: .windowBackgroundColor) : Color.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
    }

    // MARK: History Pane
    private var historyPane: some View {
        Group {
            if let selId = selectedHistoryId,
               let item = store.historySessions.first(where: { $0.id == selId }) {
                historyDetailView(item)
            } else {
                historyListView
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var filteredHistory: [HistorySession] {
        switch historyFilter {
        case "today":
            return store.historySessions.filter { Calendar.current.isDateInToday($0.sortDate) }
        case "terminated":
            return store.historySessions.filter { $0.status != .active }
        default:
            return store.historySessions
        }
    }

    private var groupedHistory: [(day: Date, title: String, items: [HistorySession])] {
        var order: [Date] = []
        var map: [Date: [HistorySession]] = [:]
        for item in filteredHistory {
            let key = item.dayKey
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(item)
        }
        return order.map { day in
            let list = map[day] ?? []
            let title = list.first?.daySectionTitle ?? ""
            return (day: day, title: title, items: list)
        }
    }

    private var historyListView: some View {
        let items = filteredHistory
        let totalDur = items.reduce(0.0) { $0 + $1.durationSeconds }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                historyFilterChip(id: "all", title: "All")
                historyFilterChip(id: "today", title: "Today")
                historyFilterChip(id: "terminated", title: "Completed")
                Spacer(minLength: 4)
                if store.isLoadingHistory && !store.historySessions.isEmpty {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.8)
                } else if !items.isEmpty {
                    Text("\(items.count) · \(HistorySession.formatDuration(totalDur))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            if store.isLoadingHistory && store.historySessions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Text("Loading history…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 17, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No sessions in history")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(groupedHistory, id: \.day) { section in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(section.title.uppercased())
                                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                    Text("\(section.items.count) session\(section.items.count > 1 ? "s" : "")")
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 2)

                                ForEach(section.items) { item in
                                    historyRowCard(item)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func historyFilterChip(id: String, title: String) -> some View {
        let on = (historyFilter == id)
        return Button(title) {
            historyFilter = id
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5, weight: on ? .medium : .regular))
        .padding(.horizontal, 7.5)
        .padding(.vertical, 3.5)
        .background(on ? Color.primary : Color.primary.opacity(0.05))
        .foregroundStyle(on ? Color(nsColor: .windowBackgroundColor) : Color.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
    }

    private func historyStatusColor(_ status: HistorySessionStatus) -> Color {
        switch status {
        case .active:      return Color.green.opacity(0.85)
        case .terminated:  return Color.secondary.opacity(0.55)
        case .interrupted: return Color.orange.opacity(0.85)
        }
    }

    private func historyRowCard(_ item: HistorySession) -> some View {
        Button {
            copiedHistory = false
            selectedHistoryId = item.id
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(historyStatusColor(item.status))
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 2.5) {
                    HStack(spacing: 5) {
                        Text(item.id)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if item.status == .active {
                            Text("LIVE")
                                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.green)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 0.5)
                                .background(Color.green.opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                        }
                        Spacer(minLength: 4)
                        Text(item.durationLabel)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    HStack(spacing: 4) {
                        Text(item.timeRangeLabel)
                            .foregroundStyle(.tertiary)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(item.activitySummary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        item.status == .active ? Color.green.opacity(0.32) : Color.primary.opacity(0.08),
                        lineWidth: 0.6
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func historyDetailView(_ item: HistorySession) -> some View {
        let orderedLogs = historyNewestFirst ? Array(item.logs.reversed()) : item.logs

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    selectedHistoryId = nil
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 3.5)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text(item.id)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Button {
                    historyNewestFirst.toggle()
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 10.5))
                        .foregroundStyle(historyNewestFirst ? .secondary : .primary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(historyNewestFirst ? 0.05 : 0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(historyNewestFirst ? "Newest first (click for chronological)" : "Chronological (click for newest first)")

                Button {
                    let text = "=== \(item.id) (\(item.daySectionTitle) · \(item.timeRangeLabel)) ===\n"
                        + item.logs.map(Self.formatLogLine).joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copiedHistory = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { copiedHistory = false }
                } label: {
                    Image(systemName: copiedHistory ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy full session log")
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Circle()
                    .fill(historyStatusColor(item.status))
                    .frame(width: 5.5, height: 5.5)
                Text(item.status.label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.primary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(item.daySectionTitle) \(item.timeRangeLabel)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(item.durationLabel)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5.5)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if orderedLogs.isEmpty {
                        Text("(no events recorded)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(4)
                    } else {
                        ForEach(Array(orderedLogs.enumerated()), id: \.offset) { _, line in
                            LogRowView(entry: LogSyntax.parse(line))
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
            )
        }
    }

    // MARK: Footer
    private var footerView: some View {
        let miniIcon = MenuBarIconFactory.makeImage(
            style: store.iconStyle,
            colorMode: store.iconColorMode,
            activeCount: max(1, store.sessions.count),
            hasIdle: false,
            size: NSSize(width: 13, height: 13),
            forcedDark: colorScheme == .dark
        )

        return HStack(spacing: 9) {
            Text(store.updatedLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                confirmStopId = nil
                confirmStopAll = false
                showAppearance.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(nsImage: miniIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 13, height: 13)
                    Text("Style")
                        .font(.system(size: 11, weight: showAppearance ? .medium : .regular))
                }
                .foregroundStyle(showAppearance ? .primary : .secondary)
                .padding(.horizontal, 6.5)
                .padding(.vertical, 2.5)
                .background(showAppearance ? Color.primary.opacity(0.12) : Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(showAppearance ? Color.primary.opacity(0.25) : Color.clear, lineWidth: 0.6)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Icon style, finish, bar density, auth, login & alerts")

            if store.sessions.count > 1 {
                Button(confirmStopAll ? "Confirm?" : "Stop all") {
                    if confirmStopAll {
                        confirmStopAll = false
                        store.stopAllSessions()
                    } else {
                        confirmStopAll = true
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: confirmStopAll ? .semibold : .regular))
                .foregroundStyle(confirmStopAll ? Color.red : Color.secondary)
                .contentShape(Rectangle())
            }

            Button {
                confirmStopId = nil
                confirmStopAll = false
                store.refresh()
                if activeTab == .history {
                    store.loadHistory(force: true)
                }
            } label: {
                if store.isRefreshing || (activeTab == .history && store.isLoadingHistory) {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help("Refresh now")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help("Quit ColabMonitor")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Divider().opacity(0.45) }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let store = MonitorStore()
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?
    private var lastClosedAt: TimeInterval = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        popover.contentSize = NSSize(width: PopoverRootView.width, height: PopoverRootView.height)

        let hosting = NSHostingController(rootView: PopoverRootView(store: store))
        hosting.sizingOptions = []
        hosting.view.frame = NSRect(x: 0, y: 0, width: PopoverRootView.width, height: PopoverRootView.height)
        popover.contentViewController = hosting

        store.onMenuBarUpdate = { [weak self] in
            self?.updateStatusItem()
        }
        updateStatusItem()

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            let mouseLoc = NSEvent.mouseLocation
            if let btnWin = self.statusItem.button?.window, btnWin.frame.contains(mouseLoc) {
                return
            }
            if let popWin = self.popover.contentViewController?.view.window, popWin.frame.contains(mouseLoc) {
                return
            }
            self.closePopover()
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, let self, self.popover.isShown {
                self.closePopover()
                return nil
            }
            return event
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.closePopover()
        }

        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateStatusItem()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m) }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        if let o = themeObserver { DistributedNotificationCenter.default().removeObserver(o) }
    }

    func popoverDidClose(_ notification: Notification) {
        lastClosedAt = Date().timeIntervalSinceReferenceDate
        store.resetTransientUI()
    }

    private func closePopover() {
        guard popover.isShown else { return }
        popover.performClose(nil)
        lastClosedAt = Date().timeIntervalSinceReferenceDate
        store.resetTransientUI()
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        popover.contentSize = NSSize(width: PopoverRootView.width, height: PopoverRootView.height)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        store.refresh()
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let count = store.sessions.count
        let rate = store.usageRate
        let hasIdle = store.hasIdle

        button.image = MenuBarIconFactory.makeImage(
            style: store.iconStyle,
            colorMode: store.iconColorMode,
            activeCount: count,
            hasIdle: hasIdle
        )
        button.toolTip = store.tooltipSummary

        let title: String
        switch store.density {
        case .iconOnly:
            title = ""
        case .rate:
            title = count == 0 ? " 0.00/hr" : String(format: " %.2f/hr", rate)
        case .countAndRate:
            title = count == 0 ? String(format: " %.0f u.", store.balance) : String(format: " %d · %.2f/hr", count, rate)
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        var attrs: [NSAttributedString.Key: Any] = [.font: font]
        if hasIdle {
            attrs[.foregroundColor] = NSColor.systemOrange
        }
        button.attributedTitle = NSAttributedString(string: title, attributes: attrs)
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            closePopover()
        } else {
            if Date().timeIntervalSinceReferenceDate - lastClosedAt < 0.2 { return }
            openPopover()
        }
    }
}

// MARK: - Self-Test, Screenshot Renderer & Entrypoint

if CommandLine.arguments.contains("--qa-test") {
    // 1. Unit tests with universal synthetic fixtures (zero personal data)
    let s1 = MonitorStore.parseSessionLine("[train-vit-l4] gpu-l4-s-usw2-8a4c1f9b02e | Hardware: L4 | Shape: Standard | Variant: GPU")
    assert(s1?.id == "train-vit-l4" && s1?.isGPU == true && s1?.tierLabel == "L4 GPU", "GPU parse failed")
    let s2 = MonitorStore.parseSessionLine("[eval-batch-cpu] m-hm-use1-3d7e2b6c19a | Hardware: CPU | Shape: High-RAM | Variant: DEFAULT")
    assert(s2?.id == "eval-batch-cpu" && s2?.isGPU == false && s2?.tierLabel == "CPU-HM", "CPU-HM parse failed")
    let s3 = MonitorStore.parseSessionLine("[colab] No active sessions found on server.")
    assert(s3 == nil, "Header line must be ignored")

    let fmt = PopoverRootView.formatLogLine("[2026-11-22 20:44:03] EVENT: session_created")
    assert(fmt.hasPrefix("[") && !fmt.contains("2026-11-22") && fmt.contains("EVENT: session_created"), "Log format failed")

    let pExec = LogSyntax.parse("[2026-11-22 20:44:06] EXEC: import os; os.makedirs('/content/work/checkpoints', exist_ok=Tru...")
    assert(pExec.kind == .exec && pExec.time != nil, "EXEC parse failed")
    let hExec = LogSyntax.highlight(pExec)
    assert(String(hExec.characters) == pExec.payload && hExec.runs.count >= 8, "EXEC highlight failed")

    let pDl = LogSyntax.parse("[2026-11-22 22:10:33] FILE: download /content/work/out/model_vit_b16.safetensors")
    assert(pDl.kind == .fileDownload, "FILE download parse failed")
    let splitSafe = LogSyntax.splitFilePath(pDl.payload)
    assert(splitSafe.dir == "/content/work/out/" && splitSafe.stem == "model_vit_b16" && splitSafe.ext == ".safetensors", "splitFilePath failed")

    let splitTar = LogSyntax.splitFilePath("/content/work/dataset_v2.tar.gz")
    assert(splitTar.dir == "/content/work/" && splitTar.stem == "dataset_v2" && splitTar.ext == ".tar.gz", "Compound ext failed")

    assert(MenuBarIconStyle.allCases.count == 6, "Expected 6 icon styles")
    for style in MenuBarIconStyle.allCases {
        let cImg = MenuBarIconFactory.makeImage(style: style, colorMode: .color, activeCount: 2, hasIdle: false)
        assert(!cImg.isTemplate && cImg.size == NSSize(width: 18, height: 18), "Color icon failed")
        let mImg = MenuBarIconFactory.makeImage(style: style, colorMode: .mono, activeCount: 2, hasIdle: true)
        assert(mImg.isTemplate && mImg.size == NSSize(width: 18, height: 18), "Mono icon failed")
    }

    let multiRunLog = """
    [2026-11-22 13:21:51] EVENT: session_created
    [2026-11-22 13:21:54] EXEC: import torch; print(torch.cuda.get_device_name(0))
    [2026-11-22 13:21:56] FILE: upload /content/work/train.py
    [2026-11-22 13:22:15] EVENT: session_terminated
    [2026-11-22 13:29:59] EVENT: session_created
    [2026-11-22 13:30:05] FILE: download /content/work/out/metrics.json
    [2026-11-22 13:40:28] EVENT: session_terminated
    """
    let histMulti = HistorySession.build(id: "bench-cpu", rawOutput: multiRunLog, isActive: false)
    assert(histMulti.status == .terminated && histMulti.runCount == 2 && Int(histMulti.durationSeconds) == 653, "Multi-run history failed")
    assert(HistorySession.formatDuration(653) == "10m" && HistorySession.formatDuration(5640) == "1h 34m", "Duration format failed")

    // 2. Optional live CLI smoke check (skipped if `--offline` or no colab binary)
    var cliStatus = "offline"
    let t0 = Date()
    if !CommandLine.arguments.contains("--offline"), ColabCLI.resolveBinaryPath() != nil {
        let uRes = ColabCLI.run(["usage"], timeout: 15)
        let sRes = ColabCLI.run(["sessions"], timeout: 15)
        let lRes = ColabCLI.run(["log"], timeout: 15)
        assert(uRes.code == 0, "usage failed: \(uRes.out)")
        assert(sRes.code == 0, "sessions failed: \(sRes.out)")
        assert(lRes.code == 0, "log list failed: \(lRes.out)")
        cliStatus = "live_ok"
    }
    let dt = Date().timeIntervalSince(t0)

    // 3. Optional studio Retina screenshot rendering (`--render-docs <dir>`) using anonymized demo fixtures
    if let idx = CommandLine.arguments.firstIndex(of: "--render-docs"), idx + 1 < CommandLine.arguments.count {
        let outDir = CommandLine.arguments[idx + 1]
        MainActor.assumeIsolated {
            let testApp = NSApplication.shared
            testApp.setActivationPolicy(.accessory)
            try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

            let st = MonitorStore(autoStart: false)
            st.email = "alex@example.com"
            st.balance = 384.6
            st.usageRate = 2.20
            st.activeAssignments = 2
            st.iconStyle = .ribbon
            st.iconColorMode = .color
            st.density = .countAndRate
            st.authMode = .auto
            st.launchAtLogin = true
            st.notificationsEnabled = true
            st.lastUpdated = Date()

            var gpuSess = s1!
            gpuSess.lastExec = "15:44:39"
            gpuSess.activeTask = "train_vit.py"
            gpuSess.logs = [
                "[2026-11-22 20:44:03] EVENT: session_created",
                "[2026-11-22 20:44:06] EXEC: import os; os.makedirs('/content/work/checkpoints', exist_ok=Tru...",
                "[2026-11-22 20:44:10] FILE: upload /content/work/dataset_v2.tar.gz",
                "[2026-11-22 20:44:57] EXEC: import subprocess, sys; subprocess.run(['python3', '-u', '/content/work/train_vit.py', '--epochs', '20'])"
            ]

            var cpuSess = s2!
            cpuSess.status = "BUSY"
            cpuSess.lastExec = "17:10:33"
            cpuSess.logs = [
                "[2026-11-22 21:59:19] EVENT: automation_result",
                "[2026-11-22 22:10:12] EXEC: import pandas as pd; df.to_parquet('/content/work/out/preds.parquet')",
                "[2026-11-22 22:10:14] FILE: download /content/work/out/metrics.json",
                "[2026-11-22 22:10:21] FILE: download /content/work/out/preds.parquet",
                "[2026-11-22 22:10:33] FILE: download /content/work/out/model_vit_b16.safetensors"
            ]
            st.sessions = [gpuSess, cpuSess]

            let nowRef = Date()
            let fmtUTC: (TimeInterval) -> String = { offset in
                let d = nowRef.addingTimeInterval(offset)
                let f = DateFormatter()
                f.calendar = Calendar(identifier: .gregorian)
                f.timeZone = TimeZone(secondsFromGMT: 0)
                f.dateFormat = "yyyy-MM-dd HH:mm:ss"
                return f.string(from: d)
            }

            let hLive = HistorySession.build(id: "train-vit-l4", rawOutput: """
            [\(fmtUTC(-2700))] EVENT: session_created
            [\(fmtUTC(-2680))] FILE: upload /content/work/dataset_v2.tar.gz
            [\(fmtUTC(-2650))] EXEC: import subprocess; subprocess.run(['python3', 'train_vit.py', '--fp16'])
            [\(fmtUTC(-120))] FILE: download /content/work/out/metrics.json
            """, isActive: true, now: nowRef)

            let hDone1 = HistorySession.build(id: "finetune-llama-a100", rawOutput: """
            [\(fmtUTC(-12600))] EVENT: session_created
            [\(fmtUTC(-12580))] EXEC: import os; os.makedirs('/content/work/out', exist_ok=True)
            [\(fmtUTC(-12560))] FILE: upload /content/work/scripts/train_lora.py
            [\(fmtUTC(-7000))] FILE: download /content/work/out/eval_summary.csv
            [\(fmtUTC(-6980))] FILE: download /content/work/out/adapter_model.safetensors
            [\(fmtUTC(-6960))] EVENT: session_terminated
            """, isActive: false, now: nowRef)

            let hDone2 = HistorySession.build(id: "bench-cpu", rawOutput: """
            [\(fmtUTC(-24000))] EVENT: session_created
            [\(fmtUTC(-23980))] EXEC: import numpy as np; print(np.__version__)
            [\(fmtUTC(-23940))] EVENT: session_terminated
            [\(fmtUTC(-22500))] EVENT: session_created
            [\(fmtUTC(-22490))] FILE: upload /content/work/benchmark.py
            [\(fmtUTC(-21870))] FILE: download /content/work/out/profile.json
            [\(fmtUTC(-21860))] EVENT: session_terminated
            """, isActive: false, now: nowRef)

            st.historySessions = [hLive, hDone1, hDone2]
            st.historyLoaded = true

            func renderRetina(_ view: PopoverRootView, appearance: NSAppearance.Name, filename: String) {
                let hv = NSHostingView(rootView: view)
                hv.frame = NSRect(x: 0, y: 0, width: PopoverRootView.width, height: PopoverRootView.height)
                hv.appearance = NSAppearance(named: appearance)
                hv.layoutSubtreeIfNeeded()
                let scale: CGFloat = 2.0
                let w = Int(hv.bounds.width * scale)
                let h = Int(hv.bounds.height * scale)
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: w,
                    pixelsHigh: h,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                ) else { return }
                rep.size = hv.bounds.size
                hv.cacheDisplay(in: hv.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(filename)"))
                }
            }

            renderRetina(PopoverRootView(store: st, initialTab: .sessions, expandedId: "train-vit-l4"), appearance: .darkAqua, filename: "raw_sessions_dark.png")
            renderRetina(PopoverRootView(store: st, initialTab: .sessions, expandedId: "train-vit-l4"), appearance: .aqua, filename: "raw_sessions_light.png")
            renderRetina(PopoverRootView(store: st, initialTab: .logs), appearance: .darkAqua, filename: "raw_logs_dark.png")
            renderRetina(PopoverRootView(store: st, initialTab: .logs), appearance: .aqua, filename: "raw_logs_light.png")
            renderRetina(PopoverRootView(store: st, initialTab: .history), appearance: .darkAqua, filename: "raw_history_list_dark.png")
            renderRetina(PopoverRootView(store: st, initialTab: .history, selectedHistoryId: "finetune-llama-a100"), appearance: .darkAqua, filename: "raw_history_detail_dark.png")
            st.iconColorMode = .color
            renderRetina(PopoverRootView(store: st, initialTab: .sessions, showAppearance: true), appearance: .darkAqua, filename: "raw_style_dark_color.png")
            st.iconColorMode = .mono
            renderRetina(PopoverRootView(store: st, initialTab: .sessions, showAppearance: true), appearance: .aqua, filename: "raw_style_light_mono.png")
        }
    }

    print("QA_PASSED in \(String(format: "%.2f", dt))s | cli=\(cliStatus) | icons=6x2 | syntax_runs=\(hExec.runs.count)")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
