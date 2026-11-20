// ClaudeUsageBar — shows remaining weekly Claude budget and remaining week time in the menu bar.
import AppKit
import ServiceManagement

// MARK: - API model

struct UsageWindow: Decodable {
    let utilization: Double?   // percent USED, 0–100
    let resets_at: String?
}

struct UsageResponse: Decodable {
    let five_hour: UsageWindow?
    let seven_day: UsageWindow?
}

enum FetchError: Error, CustomStringConvertible {
    case noCredentials, expired, http(Int), decode
    var description: String {
        switch self {
        case .noCredentials: return "No Claude Code login found"
        case .expired: return "Token expired — use Claude Code once to refresh"
        case .http(let c): return c == 401 ? "Unauthorized — use Claude Code once to refresh" : "HTTP \(c)"
        case .decode: return "Unexpected response"
        }
    }
}

// MARK: - Credentials (same place Claude Code stores them)

func readCredentialsJSON() -> Data? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    if (try? p.run()) != nil {
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus == 0, !data.isEmpty { return data }
    }
    let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
    return try? Data(contentsOf: file)
}

func readAccessToken() throws -> String {
    guard let data = readCredentialsJSON(),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = obj["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String else { throw FetchError.noCredentials }
    if let exp = oauth["expiresAt"] as? Double, Date(timeIntervalSince1970: exp / 1000) < Date() {
        throw FetchError.expired
    }
    return token
}

func fetchUsage() async throws -> UsageResponse {
    let token = try readAccessToken()
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 20
    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else { throw FetchError.http(code) }
    guard let decoded = try? JSONDecoder().decode(UsageResponse.self, from: data) else { throw FetchError.decode }
    return decoded
}

func parseDate(_ s: String?) -> Date? {
    guard var s = s else { return nil }
    // Drop fractional seconds (API may send microseconds, which ISO8601DateFormatter dislikes).
    if let r = s.range(of: #"\.\d+"#, options: .regularExpression) { s.removeSubrange(r) }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let budgetLine = NSMenuItem(title: "Weekly budget: …", action: nil, keyEquivalent: "")
    let weekLine = NSMenuItem(title: "Week: …", action: nil, keyEquivalent: "")
    let sessionLine = NSMenuItem(title: "Session (5h): …", action: nil, keyEquivalent: "")
    let statusLine = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    let autoResetItem = NSMenuItem(title: "Automatic (from Claude)", action: #selector(useAutoReset), keyEquivalent: "")
    let customResetItem = NSMenuItem(title: "Custom…", action: #selector(setCustomReset), keyEquivalent: "")

    var budgetLeft: Double?
    var lastError: String?

    // MARK: Reset-time settings (persisted)
    let defaults = UserDefaults.standard
    let week: TimeInterval = 7 * 24 * 3600

    /// Last reset time reported by the API; persisted so it survives restarts and missing values.
    var detectedReset: Date? {
        get { defaults.object(forKey: "detectedReset") as? Date }
        set { defaults.set(newValue, forKey: "detectedReset") }
    }
    var customMode: Bool {
        get { defaults.bool(forKey: "customMode") }
        set { defaults.set(newValue, forKey: "customMode") }
    }
    /// Calendar weekday: 1 = Sunday … 7 = Saturday.
    var customWeekday: Int {
        get { defaults.object(forKey: "customWeekday") as? Int ?? 7 }
        set { defaults.set(newValue, forKey: "customWeekday") }
    }
    var customHour: Int {
        get { defaults.object(forKey: "customHour") as? Int ?? 17 }
        set { defaults.set(newValue, forKey: "customHour") }
    }
    var customMinute: Int {
        get { defaults.object(forKey: "customMinute") as? Int ?? 0 }
        set { defaults.set(newValue, forKey: "customMinute") }
    }

    /// The reset time actually used: custom, or the detected one rolled forward past "now".
    var effectiveReset: Date? {
        if customMode {
            let c = DateComponents(hour: customHour, minute: customMinute, weekday: customWeekday)
            return Calendar.current.nextDate(after: Date(), matching: c, matchingPolicy: .nextTime)
        }
        guard var r = detectedReset else { return nil }
        while r <= Date() { r += week }
        return r
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        for i in [budgetLine, weekLine, sessionLine, statusLine] { i.isEnabled = false; menu.addItem(i) }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r"))
        let resetMenu = NSMenu()
        for i in [autoResetItem, customResetItem] { i.target = self; resetMenu.addItem(i) }
        let resetParent = NSMenuItem(title: "Week Reset Time", action: nil, keyEquivalent: "")
        resetParent.submenu = resetMenu
        menu.addItem(resetParent)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { if $0.action == #selector(refresh) { $0.target = self } }
        item.menu = menu
        updateLoginState()
        render()
        refresh()
        // Usage every 5 min; the time-of-week number every minute.
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in Task { @MainActor in self.refresh() } }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task { @MainActor in self.render() } }
    }

    var weekLeft: Double? {
        guard let reset = effectiveReset else { return nil }
        let pct = reset.timeIntervalSinceNow / week * 100
        return min(100, max(0, pct))
    }

    @objc func refresh() {
        Task {
            do {
                let u = try await fetchUsage()
                budgetLeft = u.seven_day?.utilization.map { max(0, 100 - $0) }
                if let r = parseDate(u.seven_day?.resets_at) { detectedReset = r }
                let df = DateFormatter(); df.dateFormat = "EEE HH:mm"
                if let s = u.five_hour, let used = s.utilization {
                    let reset = parseDate(s.resets_at).map { " — resets \(df.string(from: $0))" } ?? ""
                    sessionLine.title = String(format: "Session (5h) left: %.0f%%", max(0, 100 - used)) + reset
                }
                lastError = nil
                let tf = DateFormatter(); tf.timeStyle = .short
                statusLine.title = "Updated \(tf.string(from: Date()))"
            } catch {
                lastError = "\(error)"
                statusLine.title = "⚠︎ \(error)"
            }
            render()
        }
    }

    func render() {
        let b = budgetLeft.map { String(format: "%.0f%%", $0) } ?? "–"
        let w = weekLeft.map { String(format: "%.0f%%", $0) } ?? "–"

        // Orange when you have less budget left than time left (burning faster than pace).
        let behind = (budgetLeft ?? 100) < (weekLeft ?? 0)
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let title = NSMutableAttributedString()
        title.append(NSAttributedString(string: "✳︎ \(b)", attributes: [
            .font: font, .foregroundColor: behind ? NSColor.systemOrange : NSColor.labelColor]))
        title.append(NSAttributedString(string: "  ◷ \(w)", attributes: [.font: font]))
        if lastError != nil { title.append(NSAttributedString(string: " ⚠︎", attributes: [.font: font])) }
        item.button?.attributedTitle = title
        item.button?.toolTip = "✳︎ weekly Claude budget left · ◷ week left until reset"

        if let bl = budgetLeft { budgetLine.title = String(format: "Weekly budget left: %.0f%% (%.0f%% used)", bl, 100 - bl) }
        if let r = effectiveReset, let wl = weekLeft {
            let df = DateFormatter(); df.dateFormat = "EEE d MMM, HH:mm"
            let source = customMode ? "custom" : "auto"
            weekLine.title = String(format: "Week left: %.1f%%", wl) + " — resets \(df.string(from: r)) (\(source))"
        } else {
            weekLine.title = "Week left: unknown — set a custom reset time"
        }

        autoResetItem.state = customMode ? .off : .on
        customResetItem.state = customMode ? .on : .off
        let df = DateFormatter(); df.dateFormat = "EEE HH:mm"
        let c = DateComponents(hour: customHour, minute: customMinute, weekday: customWeekday)
        let sample = Calendar.current.nextDate(after: Date(), matching: c, matchingPolicy: .nextTime)
        customResetItem.title = customMode ? "Custom: \(sample.map(df.string(from:)) ?? "")…" : "Custom…"
    }

    // MARK: Reset time selection
    @objc func useAutoReset() {
        customMode = false
        render()
    }

    @objc func setCustomReset() {
        // Prefill from the current custom value, or from the detected reset if there is none yet.
        var weekday = customWeekday, hour = customHour, minute = customMinute
        if defaults.object(forKey: "customWeekday") == nil, let r = effectiveReset {
            let c = Calendar.current.dateComponents([.weekday, .hour, .minute], from: r)
            weekday = c.weekday ?? weekday; hour = c.hour ?? hour; minute = c.minute ?? minute
        }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 32, width: 220, height: 26))
        popup.addItems(withTitles: Calendar.current.weekdaySymbols)   // index 0 = Sunday
        popup.selectItem(at: weekday - 1)
        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 120, height: 26))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        picker.dateValue = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 60))
        box.addSubview(popup); box.addSubview(picker)

        let alert = NSAlert()
        alert.messageText = "Weekly reset time"
        alert.informativeText = "Day and time (local) your Claude week resets. Tip: check claude.ai → Settings → Usage."
        alert.accessoryView = box
        alert.addButton(withTitle: "Use Custom Time")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let t = Calendar.current.dateComponents([.hour, .minute], from: picker.dateValue)
        customWeekday = popup.indexOfSelectedItem + 1
        customHour = t.hour ?? 17
        customMinute = t.minute ?? 0
        customMode = true
        render()
    }

    // MARK: Launch at login
    func updateLoginState() {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            statusLine.title = "⚠︎ Login item: \(error.localizedDescription)"
        }
        updateLoginState()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
