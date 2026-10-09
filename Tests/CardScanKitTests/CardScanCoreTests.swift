import XCTest

@testable import CardScanKit

final class CardScanCoreTests: XCTestCase {
  private let date = ISO8601DateFormatter().date(from: "2026-10-09T00:00:00Z")!
  private var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(secondsFromGMT: 0)!
    return value
  }

  private func line(_ text: String, top: CGFloat = 0.4, left: CGFloat = 0.1) -> OCRLine {
    OCRLine(
      text: text, top: top, left: left,
      boundingBox: CGRect(x: left, y: 1 - top - 0.04, width: 0.4, height: 0.04))
  }

  func testSupportedBrandsAndExpiry() {
    let cards = [
      "4111 1111 1111 1111", "5555 5555 5555 4444",
      "2223 0000 4840 0011", "3782 822463 10005",
    ]
    for card in cards {
      let result = CardTextExtractor.extract(
        [line(card), line("VALID THRU 12/28", top: 0.6)],
        now: date, calendar: calendar)
      XCTAssertEqual(result.number, card.filter(\.isNumber))
      XCTAssertEqual(result.expiry, "12/28")
    }
  }

  func testInvalidNumberAndExpiredDateAreWarnings() {
    let result = CardTextExtractor.extract(
      [
        line("4691 0000 1234 5678"),
        line("VALID THRU 08/2019", top: 0.6),
      ],
      now: date, calendar: calendar)
    XCTAssertNil(result.number)
    XCTAssertTrue(result.invalidNumber)
    XCTAssertNil(result.expiry)
    XCTAssertEqual(result.expiryIssue, .expired)
    XCTAssertEqual(result.detectedExpiry, "08/19")
  }

  func testPartialMergeRequiresRepeatedExactOverlap() {
    let tracker = PartialPANTracker()
    let left = [line("45391488034")]
    let right = [line("48803436467")]
    XCTAssertNil(tracker.observe(left, at: 1))
    XCTAssertNil(tracker.observe(left, at: 2))
    XCTAssertNil(tracker.observe(right, at: 3))
    XCTAssertEqual(tracker.observe(right, at: 4), "4539148803436467")
    tracker.clear()
    XCTAssertNil(tracker.bestFragment)
  }

  func testSplitExpiryAndUnsupportedBrand() {
    let split = CardTextExtractor.extract(
      [
        line("4111 1111 1111 1111"),
        line("VALID THRU", top: 0.6, left: 0.10),
        line("12", top: 0.6, left: 0.30),
        line("/", top: 0.6, left: 0.37),
        line("28", top: 0.6, left: 0.40),
      ], now: date, calendar: calendar)
    XCTAssertEqual(split.expiry, "12/28")

    let unsupported = CardTextExtractor.extract(
      [line("6011 1111 1111 1117")],
      now: date, calendar: calendar)
    XCTAssertNil(unsupported.number)
    XCTAssertTrue(unsupported.unsupportedNetwork)
  }

  func testInvalidExpiryNotReturned() {
    let result = CardTextExtractor.extract(
      [
        line("4111 1111 1111 1111"),
        line("EXP 13/29", top: 0.6),
      ],
      now: date, calendar: calendar)
    XCTAssertEqual(result.number, "4111111111111111")
    XCTAssertNil(result.expiry)
    XCTAssertEqual(result.detectedExpiry, "13/29")
    XCTAssertEqual(result.expiryIssue, .invalid)
  }
}
