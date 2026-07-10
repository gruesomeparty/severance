import Combine
import Foundation

// The reader + macOS scheduler over ~/.claude/severance. The state files are the
// source of truth; this class watches them, re-derives resume timers statelessly
// on launch (AC9), and shells out to the plugin scripts for actions.
@MainActor
public final class SeveranceStore: ObservableObject {
    @Published public private(set) var usage: UsageCache?
    @Published public private(set) var projects: [ProjectState] = []
    @Published public private(set) var lastRefresh: Date = .distantPast

    // One-shot easter-egg signals the UI observes (auto-clear like the mockup).
    @Published public var waffleParty: Bool = false {
        didSet { if waffleParty { scheduleEggClear(9) { [weak self] in self?.waffleParty = false } } }
    }
    @Published public var musicDanceExperience: Bool = false {
        didSet { if musicDanceExperience { scheduleEggClear(5) { [weak self] in self?.musicDanceExperience = false } } }
    }

    public let stateDir: URL
    private var source: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?
    private var resumeTimers: [Timer] = []
    private var lastSessionReset: Date?
    private var lastWeeklyReset: Date?
    private var seededResets = false
    private var started = false

    public var onWaffleParty: (() -> Void)?

    public init(stateDir: URL? = nil) {
        if let stateDir {
            self.stateDir = stateDir
        } else if let env = ProcessInfo.processInfo.environment["SEVERANCE_STATE_DIR"], !env.isEmpty {
            self.stateDir = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        } else {
            self.stateDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/severance")
        }
    }

    // MARK: lifecycle

    public func start() {
        guard !started else { return }
        started = true
        refresh()
        seededResets = true
        startWatching()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    public func refresh() {
        let newUsage = StateLoader.loadUsage(at: stateDir.appendingPathComponent("usage.json"))
        detectResets(newUsage)
        usage = newUsage
        projects = StateLoader.loadProjects(in: stateDir)
        lastRefresh = Date()
        rescheduleResumes()
        maybeFetchTier2()
    }

    private func scheduleEggClear(_ after: TimeInterval, _ clear: @escaping () -> Void) {
        Timer.scheduledTimer(withTimeInterval: after, repeats: false) { _ in
            Task { @MainActor in clear() }
        }
    }

    // Watch projects/ rather than the top state dir: per-session records now live
    // at projects/<slug>/<session_id>.json (issue #15), and a session appearing or
    // ending adds/removes its <slug>/ dir entry, firing this source. A single
    // non-recursive DispatchSource can't observe writes *inside* each <slug>/ dir,
    // so edits to an existing record (e.g. a sever/resume flip) are caught by the
    // 30s pollTimer, which remains the safety net. Fall back to the state dir if
    // projects/ does not exist yet (first run); the poll picks it up regardless.
    private func startWatching() {
        let projects = stateDir.appendingPathComponent("projects")
        let target = FileManager.default.fileExists(atPath: projects.path) ? projects : stateDir
        let fd = open(target.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main
        )
        src.setEventHandler { [weak self] in self?.refresh() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    // MARK: derived state

    public var signalIsEstimate: Bool { usage?.signalTier != nil && usage?.signalTier != .statusline }

    public var staleness: TimeInterval? {
        guard let usage else { return nil }
        return Date().timeIntervalSince(usage.updatedAt)
    }

    // MARK: easter eggs (reset detection)

    private func detectResets(_ next: UsageCache?) {
        guard let next else { return }
        let s = next.normalized.session.resetsAtDate
        let w = next.normalized.weekly.resetsAtDate
        if seededResets {
            if let s, let last = lastSessionReset, s > last { musicDanceExperience = true }
            if let w, let last = lastWeeklyReset, w > last {
                waffleParty = true
                onWaffleParty?()
            }
        }
        if let s { lastSessionReset = s }
        if let w { lastWeeklyReset = w }
    }

    // MARK: resume scheduler (macOS replacement for systemd)

    private func rescheduleResumes() {
        resumeTimers.forEach { $0.invalidate() }
        resumeTimers.removeAll()
        let stagger = staggerSeconds()
        for (index, entry) in StateLoader.resumeSchedule(projects).enumerated() {
            let base = max(entry.fireAt.timeIntervalSinceNow, 0)
            let delay = base + Double(index) * stagger // priority-ordered bands, staggered
            let slug = entry.project.name
            let sessionId = entry.project.sessionId
            let t = Timer.scheduledTimer(withTimeInterval: max(delay, 0.5), repeats: false) { _ in
                Task { @MainActor [weak self] in self?.runResume(slug: slug, sessionId: sessionId) }
            }
            resumeTimers.append(t)
        }
    }

    private func staggerSeconds() -> Double {
        let cfg = stateDir.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: cfg),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let m = obj["resume_stagger_minutes"] as? Double {
            return m * 60
        }
        return 15 * 60
    }

    // MARK: actions

    public func severNow(_ project: ProjectState) {
        mergeState(slug: project.name, sessionId: project.sessionId, [
            "paused": true, "status": "paused", "reason": "manual",
            "ts": Int(Date().timeIntervalSince1970),
        ])
        refresh()
    }

    public func resumeNow(_ project: ProjectState) {
        // A severed project with a live pane gets the tmux continuation via resume.sh;
        // a manual/preempted pause (usually no pane) just has its flag cleared.
        if let pane = project.tmuxPane, !pane.isEmpty {
            runResume(slug: project.name, sessionId: project.sessionId)
        } else {
            mergeState(slug: project.name, sessionId: project.sessionId, [
                "status": "active", "paused": false, "reason": NSNull(),
                "preempted_by": NSNull(), "resume_at": NSNull(),
                "ts": Int(Date().timeIntervalSince1970),
            ])
            refresh()
        }
    }

    private func runResume(slug: String, sessionId: String?) {
        let sf = projectStateURL(slug: slug, sessionId: sessionId)
        if let resume = scriptPath("resume.sh") {
            runDetached(resume, [sf.path])
        } else {
            // No plugin scripts found: best-effort clear without a tmux prompt.
            mergeState(slug: slug, sessionId: sessionId, [
                "status": "active", "paused": false, "resume_at": NSNull(),
                "ts": Int(Date().timeIntervalSince1970),
            ])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }
    }

    public func openHandover(_ project: ProjectState) {
        let handover = URL(fileURLWithPath: project.cwd).appendingPathComponent(".severance/handover.md")
        runDetached("/usr/bin/open", [handover.path])
    }

    // MARK: helpers

    // Locate a plugin script: explicit override, then the plugin cache. The
    // installed layout is …/plugins/cache/<market>/severance/<version>/scripts/<name>,
    // so match any severance path ending in /scripts/<name> and prefer the newest.
    private func scriptPath(_ name: String) -> String? {
        let fm = FileManager.default
        if let dir = ProcessInfo.processInfo.environment["SEVERANCE_SCRIPTS_DIR"] {
            let p = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: p) { return p }
        }
        let plugins = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/plugins")
        guard let subs = try? fm.subpathsOfDirectory(atPath: plugins.path) else { return nil }
        let hit = subs
            .filter { $0.hasSuffix("/scripts/\(name)") && $0.contains("severance") }
            .sorted() // ascending → newest version last
            .last
        return hit.map { plugins.appendingPathComponent($0).path }
    }

    // A GUI-launched app inherits a minimal PATH (no /opt/homebrew/bin), so tmux/jq
    // won't resolve. Give child scripts a usable PATH and point resume.sh's tmux at
    // an absolute path so `send-keys` can actually reach the session's pane.
    nonisolated static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = env["PATH"].map { "\(extra):\($0)" } ?? extra
        if env["SEVERANCE_TMUX"] == nil {
            for t in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            where FileManager.default.isExecutableFile(atPath: t) {
                env["SEVERANCE_TMUX"] = t
                break
            }
        }
        return env
    }

    private func runDetached(_ launchPath: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.environment = Self.childEnvironment()
        try? p.run()
    }

    // The per-session lifecycle path projects/<slug>/<session_id>.json (issue #15).
    // The session_id keys the file and is sanitized to the plugin's A-Za-z0-9._-
    // class (mirrors sev_session_cost_file); the slug is already a sanitized dir
    // name. Fall back to the slug as the file stem when sessionId is absent.
    private func projectStateURL(slug: String, sessionId: String?) -> URL {
        let stem = Self.sanitizeSessionId(sessionId ?? slug)
        return stateDir.appendingPathComponent("projects/\(slug)/\(stem).json")
    }

    private static func sanitizeSessionId(_ id: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return String(id.map { allowed.contains($0) ? $0 : "-" })
    }

    private func mergeState(slug: String, sessionId: String?, _ patch: [String: Any]) {
        let sf = projectStateURL(slug: slug, sessionId: sessionId)
        var obj = (try? Data(contentsOf: sf))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        for (k, v) in patch { obj[k] = v }
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        let tmp = sf.deletingLastPathComponent().appendingPathComponent(".sev.\(UUID().uuidString)")
        try? out.write(to: tmp)
        _ = try? FileManager.default.replaceItemAt(sf, withItemAt: tmp)
    }

    // MARK: Tier-2 fallback fetch (opt-in, §7.6)

    private var lastTier2Attempt: Date = .distantPast

    // When the cache is stale (>5min) and the user opted in, refresh the signal
    // by shelling out to oauth-usage.sh (token via Keychain, in the shell — never
    // in Swift) and normalizing its output with the same probe list as the plugin.
    private func maybeFetchTier2() {
        guard UserDefaults.standard.bool(forKey: "severance.tier2Fallback") else { return }
        guard let s = staleness, s > 300 else { return }
        guard Date().timeIntervalSince(lastTier2Attempt) > 60 else { return }
        guard let oauth = scriptPath("oauth-usage.sh") else { return }
        lastTier2Attempt = Date()
        DispatchQueue.global(qos: .utility).async {
            guard let out = Self.capture(oauth, []),
                  let norm = Normalizer.normalize(rawJSON: Data(out.utf8)) else { return }
            Task { @MainActor in self.writeUsage(norm) }
        }
    }

    private func writeUsage(_ normalized: Normalized) {
        let cache = UsageCache(
            ts: Int(Date().timeIntervalSince1970), signalTier: .oauth,
            normalized: normalized, cost: nil, sessionId: nil, model: nil, cwd: nil
        )
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(cache) else { return }
        let dest = stateDir.appendingPathComponent("usage.json")
        let tmp = stateDir.appendingPathComponent(".sev.\(UUID().uuidString)")
        try? data.write(to: tmp)
        _ = try? FileManager.default.replaceItemAt(dest, withItemAt: tmp)
        refresh()
    }

    private nonisolated static func capture(_ launchPath: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.environment = childEnvironment()
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
