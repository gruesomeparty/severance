import XCTest

import SeveranceCore

final class StateLoaderTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("projects"), withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ json: String) throws {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    private func project(_ json: String) throws -> ProjectState {
        try StateLoader.decoder.decode(ProjectState.self, from: Data(json.utf8))
    }

    func testLoadUsageHappyPath() throws {
        try write("usage.json", """
        {"ts":1751450000,"signal_tier":"statusline",
         "normalized":{"session":{"utilization":62.0,"resets_at":"2026-07-02T18:00:00Z"},
                       "weekly":{"utilization":41.0,"resets_at":null},
                       "extra_usage":{"is_enabled":false,"used_credits":null}},
         "cost":{"total_cost_usd":1.42},"session_id":"s","model":"m","cwd":"/x"}
        """)
        let u = try XCTUnwrap(StateLoader.loadUsage(at: dir.appendingPathComponent("usage.json")))
        XCTAssertEqual(u.signalTier, .statusline)
        XCTAssertEqual(u.normalized.session.utilization, 62.0)
        XCTAssertEqual(u.cost?.totalCostUsd, 1.42)
        XCTAssertNotNil(u.normalized.session.resetsAtDate)
        XCTAssertNil(u.normalized.weekly.resetsAtDate)
    }

    func testLoadUsageCorruptOrMissingIsNil() throws {
        try write("bad.json", "{ not json")
        XCTAssertNil(StateLoader.loadUsage(at: dir.appendingPathComponent("bad.json")))
        XCTAssertNil(StateLoader.loadUsage(at: dir.appendingPathComponent("missing.json")))
    }

    func testLoadProjectsSkipsCorruptAndSortsByPriority() throws {
        // Per-session layout: projects/<slug>/<session_id>.json (issue #15).
        try write("projects/a-normal/s1.json",
                  #"{"name":"a-normal","cwd":"/x","status":"active","priority":"normal","paused":false,"session_id":"s1"}"#)
        try write("projects/b-crit/s2.json",
                  #"{"name":"b-crit","cwd":"/x","status":"active","priority":"critical","paused":false,"session_id":"s2"}"#)
        try write("projects/a-normal/corrupt.json", "{ nope")
        let ps = StateLoader.loadProjects(in: dir)
        XCTAssertEqual(ps.count, 2, "corrupt file must be skipped")
        XCTAssertEqual(ps.first?.priority, .critical, "highest priority first")
    }

    func testLoadProjectsTwoSessionsOfOneSlugYieldDistinctIds() throws {
        // Two concurrent sessions of the same repo keep independent records and
        // must produce distinct SwiftUI identities so one row per session renders.
        try write("projects/repo/sess-1.json",
                  #"{"name":"repo","cwd":"/x","status":"active","priority":"normal","paused":false,"session_id":"sess-1"}"#)
        try write("projects/repo/sess-2.json",
                  #"{"name":"repo","cwd":"/x","status":"active","priority":"normal","paused":false,"session_id":"sess-2"}"#)
        let ps = StateLoader.loadProjects(in: dir)
        XCTAssertEqual(ps.count, 2, "both session files under one slug must load")
        XCTAssertEqual(Set(ps.map { $0.name }), ["repo"], "both share the slug name")
        XCTAssertEqual(Set(ps.map { $0.id }).count, 2, "sessions of one slug must have distinct ids")
    }

    func testPartialProjectDecodesWithNilOptionals() throws {
        let p = try project(
            #"{"name":"p","cwd":"/x","status":"severed","reason":"session_util","priority":"low","paused":false}"#)
        XCTAssertEqual(p.status, .severed)
        XCTAssertEqual(p.reason, .sessionUtil)
        XCTAssertNil(p.sessionCostUsd)
        XCTAssertNil(p.resumeAt)
    }

    func testNormalizeStatuslineShapeConvertsEpochToISO() throws {
        let data = Data("""
        {"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},
                        "seven_day":{"used_percentage":41.2,"resets_at":1738857600}}}
        """.utf8)
        let n = try XCTUnwrap(Normalizer.normalize(rawJSON: data))
        XCTAssertEqual(n.session.utilization, 23.5)
        XCTAssertEqual(n.weekly.utilization, 41.2)
        XCTAssertNotNil(n.session.resetsAtDate)
        XCTAssertTrue(n.session.resetsAt?.hasSuffix("Z") ?? false)
        XCTAssertNil(n.extraUsage.usedCredits)
    }

    func testNormalizeOAuthShapePassesThroughAndReadsExtraUsage() throws {
        let data = Data("""
        {"five_hour":{"utilization":37.0,"resets_at":"2026-02-08T04:59:59+00:00"},
         "seven_day":{"utilization":26.0,"resets_at":"2026-02-12T14:59:59+00:00"},
         "extra_usage":{"is_enabled":true,"used_credits":12.5}}
        """.utf8)
        let n = try XCTUnwrap(Normalizer.normalize(rawJSON: data))
        XCTAssertEqual(n.session.utilization, 37.0)
        XCTAssertEqual(n.session.resetsAt, "2026-02-08T04:59:59+00:00")
        XCTAssertEqual(n.extraUsage.isEnabled, true)
        XCTAssertEqual(n.extraUsage.usedCredits, 12.5)
    }

    func testResumeScheduleOrdersByPriorityAndExcludesNonSevered() throws {
        let hi = try project(
            #"{"name":"hi","cwd":"/x","status":"severed","priority":"high","paused":false,"resume_at":"2030-01-01T00:00:00Z"}"#)
        let lo = try project(
            #"{"name":"lo","cwd":"/x","status":"severed","priority":"low","paused":false,"resume_at":"2030-01-01T00:00:00Z"}"#)
        let active = try project(
            #"{"name":"act","cwd":"/x","status":"active","priority":"critical","paused":false}"#)
        let sched = StateLoader.resumeSchedule([lo, active, hi])
        XCTAssertEqual(sched.map { $0.project.name }, ["hi", "lo"])
    }
}
