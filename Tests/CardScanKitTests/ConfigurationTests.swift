import XCTest

@testable import CardScanKit

final class ConfigurationTests: XCTestCase {
  let date = ISO8601DateFormatter().date(from: "2026-10-09T00:00:00Z")!
  func lines(_ number: String = "4111 1111 1111 1111", expiry: String? = "12/28") -> [OCRLine] {
    var values = [OCRLine(text: number, top: 0.3, left: 0.1, boundingBox: .zero)]
    if let expiry {
      values.append(OCRLine(text: "EXP " + expiry, top: 0.6, left: 0.1, boundingBox: .zero))
    }
    return values
  }
  func read(_ engine: ScanEngine, _ values: [OCRLine]? = nil) {
    for i in 0..<3 { engine.frame(values ?? lines(), now: Double(i) * 0.25, date: date) }
  }
  func testDefaultAndExactlyOnce() throws {
    let e = try ScanEngine(config: .balanced)
    read(e)
    guard case .completed(let r) = e.outcome else { return XCTFail("No result") }
    XCTAssertEqual(r.cardNumber, "4111111111111111")
    XCTAssertEqual(r.expiry, "12/28")
    e.frame(lines("5555 5555 5555 4444"), now: 1, date: date)
    guard case .completed(let again) = e.outcome else { return XCTFail() }
    XCTAssertEqual(r, again)
  }
  func testRequiredExpiry() throws {
    var c = CardScannerConfiguration()
    c.validation.expiryRequirement = .required
    let e = try ScanEngine(config: c)
    read(e, lines(expiry: nil))
    e.tick(now: 20)
    XCTAssertNil(e.outcome)
  }
  func testFallbackWithoutFrames() throws {
    let e = try ScanEngine(config: .balanced)
    read(e, lines(expiry: nil))
    e.tick(now: 13)
    e.tick(now: 13.05)
    guard case .completed(let result) = e.outcome else { return XCTFail() }
    XCTAssertNil(result.expiry)
  }
  func testTimeoutWithoutFrames() throws {
    var c = CardScannerConfiguration()
    c.timing.sessionTimeout = 1
    let e = try ScanEngine(config: c)
    e.tick(now: 0.99)
    XCTAssertNil(e.outcome)
    e.tick(now: 1)
    guard case .timedOut = e.outcome else { return XCTFail() }
  }
  func testNumberOnlyConfirmation() throws {
    var c = CardScannerConfiguration()
    c.validation.expiryRequirement = .disabled
    c.completionMode = .userConfirmation
    let e = try ScanEngine(config: c)
    read(e)
    XCTAssertTrue(e.state.readyToConfirm)
    XCTAssertNil(e.outcome)
    e.confirm(now: 0.8)
    guard case .completed(let result) = e.outcome else { return XCTFail() }
    XCTAssertNil(result.expiry)
  }
  func testExpiredRequiresReview() throws {
    var c = CardScannerConfiguration()
    c.validation.expiredCardPolicy = .returnForReview
    let e = try ScanEngine(config: c)
    read(e, lines(expiry: "01/20"))
    XCTAssertTrue(e.state.readyToConfirm)
    XCTAssertNil(e.outcome)
    e.confirm(now: 0.8)
    guard case .completed(let result) = e.outcome else { return XCTFail() }
    XCTAssertEqual(result.validationStatus, .expiredRequiresReview)
  }
  func testBrandAndFormats() {
    var options = ValidationOptions()
    options.supportedBrands = [.amex]
    options.expiryFormats = [.labelledCompact]
    let c = CardTextExtractor.extract(lines(), now: date, options: options)
    XCTAssertNil(c.number)
    XCTAssertTrue(c.unsupportedNetwork)
    XCTAssertNil(c.expiry)
  }
  func testCustomValidationAndMasking() throws {
    var c = CardScannerConfiguration()
    c.appearance.numberDisplay = .lastFour
    let e = try ScanEngine(config: c, validator: { _ in false })
    e.frame(lines(), now: 0, date: date)
    XCTAssertEqual(e.state.numberPreview, "1111")
    read(e)
    XCTAssertNil(e.outcome)
    XCTAssertEqual(e.state.message, .hostRejected)
  }
  func testInvalidConfiguration() {
    var c = CardScannerConfiguration()
    c.partial.minimumOverlap = 1
    XCTAssertThrowsError(try c.validate())
    c = .balanced
    c.recognition.minimumConfidence = .nan
    XCTAssertThrowsError(try c.validate())
  }
  func testInterruptedReadsAndRetry() throws {
    let e = try ScanEngine(config: .balanced)
    e.frame(lines(), now: 0, date: date)
    e.frame(lines(), now: 4, date: date)
    XCTAssertNil(e.outcome)
    e.reset()
    XCTAssertNil(e.state.numberPreview)
  }
  func testNewCardCannotInheritExpiry() throws {
    var c = CardScannerConfiguration()
    c.validation.expiryRequirement = .required
    let e = try ScanEngine(config: c)
    e.frame(lines(), now: 0, date: date)
    e.frame(lines(), now: 0.25, date: date)
    for i in 0..<3 {
      e.frame(lines("5555 5555 5555 4444", expiry: nil), now: 0.5 + Double(i) * 0.25, date: date)
    }
    XCTAssertNil(e.outcome)
  }
  func testMinimumStableDuration() throws {
    var c = CardScannerConfiguration()
    c.timing.minimumStableDuration = 1
    let e = try ScanEngine(config: c)
    read(e)
    XCTAssertNil(e.outcome)
    e.frame(lines(), now: 1, date: date)
    guard case .completed = e.outcome else { return XCTFail() }
  }
  func testMergedCandidateConfirmation() throws {
    var c = CardScannerConfiguration()
    c.validation.expiryRequirement = .disabled
    let e = try ScanEngine(config: c)
    let left = lines("45391488034", expiry: nil)
    let right = lines("48803436467", expiry: nil)
    e.frame(left, now: 0, date: date)
    e.frame(left, now: 0.1, date: date)
    e.frame(right, now: 0.2, date: date)
    e.frame(right, now: 0.3, date: date)
    XCTAssertNil(e.outcome)
    e.frame(right, now: 0.4, date: date)
    e.frame(right, now: 0.5, date: date)
    guard case .completed(let result) = e.outcome else { return XCTFail() }
    XCTAssertEqual(result.cardNumber, "4539148803436467")
  }
  func testInvalidExpiryClearsEarlierEvidence() throws {
    var c = CardScannerConfiguration()
    c.validation.expiryRequirement = .required
    let e = try ScanEngine(config: c)
    e.frame(lines(), now: 0, date: date)
    e.frame(lines(), now: 0.25, date: date)
    e.frame(lines(expiry: "13/29"), now: 0.5, date: date)
    XCTAssertNil(e.outcome)
    XCTAssertTrue(e.state.warningVisible)
  }
  func testSuccessDelayAndCancellation() throws {
    var c = CardScannerConfiguration()
    c.timing.successDisplayDuration = 1
    let e = try ScanEngine(config: c)
    read(e)
    XCTAssertNil(e.outcome)
    e.tick(now: 1.499)
    XCTAssertNil(e.outcome)
    e.terminate(.cancelled(.user))
    e.tick(now: 1.5)
    guard case .cancelled = e.outcome else { return XCTFail() }
  }
}
