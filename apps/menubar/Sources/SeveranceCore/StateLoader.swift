import Foundation

// Pure, headlessly-testable loading + normalization (PRD §9.6). The
// ObservableObject SeveranceStore wraps these.
public enum StateLoader {
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    // usage.json — nil on missing or corrupt.
    public static func loadUsage(at url: URL) -> UsageCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(UsageCache.self, from: data)
    }

    // projects/<slug>/<session_id>.json — one lifecycle record per session (issue
    // #15). Recurse exactly one level: each entry under projects/ is a <slug>/
    // directory whose *.json files are the per-session records. Corrupt files are
    // skipped; result sorted by priority desc, then name.
    public static func loadProjects(in stateDir: URL) -> [ProjectState] {
        let fm = FileManager.default
        let dir = stateDir.appendingPathComponent("projects")
        guard let slugs = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        var out: [ProjectState] = []
        for slug in slugs {
            let isDir = (try? slug.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir, let files = try? fm.contentsOfDirectory(
                at: slug, includingPropertiesForKeys: nil
            ) else { continue }
            for f in files where f.pathExtension == "json" {
                if let data = try? Data(contentsOf: f),
                   let p = try? decoder.decode(ProjectState.self, from: data) {
                    out.append(p)
                }
            }
        }
        return out.sorted { a, b in
            a.priority != b.priority ? a.priority > b.priority : a.name < b.name
        }
    }

    // Severed projects with a resume time, highest priority first — the timers
    // the macOS scheduler re-derives at launch (stateless; AC9).
    public static func resumeSchedule(
        _ projects: [ProjectState]
    ) -> [(project: ProjectState, fireAt: Date)] {
        projects
            .compactMap { p -> (project: ProjectState, fireAt: Date)? in
                guard p.status == .severed, let when = p.resumeAtDate else { return nil }
                return (p, when)
            }
            .sorted { a, b in
                a.project.priority != b.project.priority
                    ? a.project.priority > b.project.priority
                    : a.fireAt < b.fireAt
            }
    }
}

// Tier-2 normalization in Swift, mirroring severance-lib.sh sev_normalize: probe
// both the statusline shape (rate_limits.<w>.used_percentage + epoch resets_at)
// and the OAuth shape (<w>.utilization + ISO resets_at); extra_usage is OAuth-only.
public enum Normalizer {
    public static func normalize(rawJSON data: Data) -> Normalized? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return normalize(object: obj)
    }

    public static func normalize(object obj: [String: Any]) -> Normalized {
        Normalized(
            session: window("five_hour", in: obj),
            weekly: window("seven_day", in: obj),
            extraUsage: extra(in: obj)
        )
    }

    private static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        return nil
    }

    private static func window(_ key: String, in obj: [String: Any]) -> RateWindow {
        let rl = obj["rate_limits"] as? [String: Any]
        let w = (rl?[key] as? [String: Any]) ?? (obj[key] as? [String: Any])
        let util = number(w?["used_percentage"]) ?? number(w?["utilization"])
        var resets: String?
        if let r = w?["resets_at"] {
            if let epoch = number(r) {
                resets = SeveranceDate.iso(from: epoch)
            } else if let s = r as? String {
                resets = s
            }
        }
        return RateWindow(utilization: util, resetsAt: resets)
    }

    private static func extra(in obj: [String: Any]) -> ExtraUsage {
        let eu = obj["extra_usage"] as? [String: Any]
        return ExtraUsage(isEnabled: eu?["is_enabled"] as? Bool,
                          usedCredits: number(eu?["used_credits"]))
    }
}
