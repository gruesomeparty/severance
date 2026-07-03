import Foundation

// Mirrors the JSON contracts in ../../schemas. Decoded with
// .convertFromSnakeCase, so JSON keys like `signal_tier` map to `signalTier`.
// Enum *values* (e.g. "session_util") are matched verbatim via rawValue.

public enum SignalTier: String, Codable {
    case statusline, oauth, ccusage
}

public enum ProjectStatus: String, Codable {
    case active, severed, orphaned, paused
}

public enum Priority: String, Codable, Comparable {
    case low, normal, high, critical

    public var rank: Int {
        switch self {
        case .low: return 0
        case .normal: return 1
        case .high: return 2
        case .critical: return 3
        }
    }

    public var chipLabel: String {
        switch self {
        case .low: return "LOW"
        case .normal: return "NORM"
        case .high: return "HIGH"
        case .critical: return "CRIT"
        }
    }

    public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rank < rhs.rank }
}

public enum TripReason: String, Codable {
    case sessionUtil = "session_util"
    case weeklyUtil = "weekly_util"
    case costLimit = "cost_limit"
    case extraUsage = "extra_usage"
    case manual
    case preempted
}

public struct RateWindow: Codable {
    public var utilization: Double?
    public var resetsAt: String?

    public var resetsAtDate: Date? { resetsAt.flatMap(SeveranceDate.parse) }

    public init(utilization: Double?, resetsAt: String?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

public struct ExtraUsage: Codable {
    public var isEnabled: Bool?
    public var usedCredits: Double?

    public init(isEnabled: Bool?, usedCredits: Double?) {
        self.isEnabled = isEnabled
        self.usedCredits = usedCredits
    }
}

public struct Normalized: Codable {
    public var session: RateWindow
    public var weekly: RateWindow
    public var extraUsage: ExtraUsage

    public init(session: RateWindow, weekly: RateWindow, extraUsage: ExtraUsage) {
        self.session = session
        self.weekly = weekly
        self.extraUsage = extraUsage
    }
}

public struct Cost: Codable {
    public var totalCostUsd: Double?
}

public struct UsageCache: Codable {
    public var ts: Int
    public var signalTier: SignalTier
    public var normalized: Normalized
    public var cost: Cost?
    public var sessionId: String?
    public var model: String?
    public var cwd: String?

    public var updatedAt: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
}

public struct ProjectState: Codable, Identifiable {
    public var name: String
    public var cwd: String
    public var status: ProjectStatus
    public var reason: TripReason?
    public var priority: Priority
    public var preemptedBy: String?
    public var sessionCostUsd: Double?
    public var limitUsd: Double?
    public var utilizationAtTrip: Double?
    public var signalTier: SignalTier?
    public var tmuxPane: String?
    public var sessionId: String?
    public var severedAt: String?
    public var resumeAt: String?
    public var resumeCount: Int?
    public var blockedCount: Int?
    public var paused: Bool

    public var id: String { name }
    public var resumeAtDate: Date? { resumeAt.flatMap(SeveranceDate.parse) }
}

// Parse/format the ISO-8601 forms Severance emits: "…Z" and "…+00:00".
public enum SeveranceDate {
    private static let internet: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func parse(_ s: String) -> Date? {
        internet.date(from: s) ?? fractional.date(from: s)
    }

    public static func iso(from epoch: Double) -> String {
        internet.string(from: Date(timeIntervalSince1970: epoch))
    }
}
