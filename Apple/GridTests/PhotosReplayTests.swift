import XCTest

/// Every frame of a recorded Photos pinch, replayed through the engine: each photo the
/// recording shows must be where the engine draws it.
///
/// The recordings were made with injected two-finger paths on an iPhone 18 Pro simulator and
/// tracked per frame (tools/track.py → tools/make_fixture.py). The engine is driven with the
/// displayed side of each frame, so this checks layout, anchoring, layer assignment and the
/// cross-fade, independent of finger-to-side timing.
final class PhotosReplayTests: XCTestCase {
    /// Tile positions are measured on a 1/3pt pixel grid with antialiased edges.
    static let medianLimit: CGFloat = 0.6
    static let p95Limit: CGFloat = 2.0
    static let p99Limit: CGFloat = 3.0
    /// Cross-fade blends occasionally match another palette colour; those tiles are either
    /// unmatched or far off. Both stay rare.
    static let unmatchedLimit = 0.03
    static let grossLimit = 0.002

    private func check(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let report = replay(try Fixture.load(name))
        print(report.summary)
        XCTAssertGreaterThan(report.errors.count, 200, "too few tiles compared", file: file, line: line)
        XCTAssertLessThanOrEqual(report.percentile(0.5), Self.medianLimit, report.summary, file: file, line: line)
        XCTAssertLessThanOrEqual(report.percentile(0.95), Self.p95Limit, report.summary, file: file, line: line)
        XCTAssertLessThanOrEqual(report.percentile(0.99), Self.p99Limit, report.summary, file: file, line: line)
        XCTAssertLessThanOrEqual(report.unmatchedFraction, Self.unmatchedLimit, report.summary, file: file, line: line)
        let gross = Double(report.errors.filter { $0 > 10 }.count) / Double(report.errors.count)
        XCTAssertLessThanOrEqual(gross, Self.grossLimit, "\(report.summary), \(gross * 100)% off by >10pt",
                                 file: file, line: line)
    }

    func testFixturesPresent() {
        XCTAssertEqual(Fixture.all.count, 9, "\(Fixture.directory.path): \(Fixture.all)")
    }

    /// 3 → 5 columns, slowly, deep into the rubber band, bottom of the library.
    func testZoomOutSlow() throws { try check("A_zoomout_slow") }
    /// 5 → 1 → 5 columns in one gesture, middle of the library.
    func testMidInOut() throws { try check("B_mid_in_out") }
    /// Stepwise pinch with holds, both directions.
    func testSteps() throws { try check("D_steps") }
    /// 5 → 1, slow, vertical fingers, release and settle.
    func testSlowUpRelease() throws { try check("F1_slow_up_release") }
    /// From 1 column out to 3 and release.
    func testFrom1Release() throws { try check("G1_from1_to300_release") }
    /// From 3 columns up to 1 and back down.
    func testFrom3UpDown() throws { try check("H_from3_up_down") }
    /// Off-centre fingers (x = 110).
    func testOffCentre() throws { try check("I_offcenter_x110") }
    /// Fingers near the left edge, 3 → 5: the anchor drifts to the nearest column.
    func testNearestColumn() throws { try check("J_x95_3to5") }
    /// Near the top: the 5-column layer is top-aligned and its anchor cell changes photo.
    func testTopAligned() throws { try check("TOP_photos") }
}
