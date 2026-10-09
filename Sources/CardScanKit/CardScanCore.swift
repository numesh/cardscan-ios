import CoreGraphics
import Foundation

/// Only these values leave the scanner. CVV is deliberately never read by the camera.
public struct CardScanResult: Equatable {
  public let validationStatus: CardValidationStatus
  public var brand: CardBrand? { cardBrand(cardNumber) }
  public var requiresManualExpiry: Bool { expiry == nil }
  public let cardNumber: String
  public let expiry: String?

  public init(cardNumber: String, expiry: String?, validationStatus: CardValidationStatus = .valid)
  {
    self.validationStatus = validationStatus
    self.cardNumber = cardNumber
    self.expiry = expiry
  }
}

/// A Vision observation in portrait, bottom-left normalized image coordinates.
struct OCRLine {
  let text: String
  let top: CGFloat
  let left: CGFloat
  let boundingBox: CGRect
}

enum ExpiryIssue: Int, Comparable {
  case none = 0
  case invalid = 1
  case expired = 2
  case ambiguous = 3

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct ScanCandidate {
  var number: String?
  var detectedNumber: String?
  var expiry: String?
  var detectedExpiry: String?
  var hasText: Bool
  var unsupportedNetwork: Bool
  var invalidNumber: Bool
  var expiryIssue: ExpiryIssue
}

/// Pure OCR parsing. No camera, UI, persistence, network calls, or guessed digits.
enum CardTextExtractor {
  private static let numberPattern = try! NSRegularExpression(
    pattern: #"(?<![0-9])([0-9][0-9 -]{11,30}[0-9])(?![0-9])"#)
  private static let expiryPattern = try! NSRegularExpression(
    pattern: #"(?<![0-9])([0-9]{1,2})\s*[/.-]\s*([0-9]{2}|20[0-9]{2})(?![0-9])"#)
  private static let spacedExpiryPattern = try! NSRegularExpression(
    pattern: #"(?<![0-9])([0-9]{1,2})\s+([0-9]{2}|20[0-9]{2})(?![0-9])"#)
  private static let compactExpiryPattern = try! NSRegularExpression(
    pattern: #"(?<![0-9])([0-9]{2})([0-9]{2})(?![0-9])"#)
  private static let labelPattern = try! NSRegularExpression(pattern: "EXP|VALID|THRU|GOOD")

  private struct ExpiryHit {
    let value: String
    let distance: CGFloat
    let labelled: Bool
  }

  static func extract(
    _ lines: [OCRLine], now: Date = Date(), calendar: Calendar = .current,
    options: ValidationOptions = ValidationOptions()
  ) -> ScanCandidate {
    let currentYear = calendar.component(.year, from: now)
    let currentMonth = calendar.component(.month, from: now)
    let rows = joinedRows(lines)
    var number: String?
    var detectedNumber: String?
    var numberTop: CGFloat = 0
    var unsupported = false
    var invalidNumber = false

    for line in rows {
      for match in numberPattern.matches(in: line.text, range: line.text.fullNSRange) {
        let digits = line.text.capture(match, 1).filter(\.isNumber)
        guard (13...19).contains(digits.count) else { continue }
        if detectedNumber == nil { detectedNumber = digits }
        guard luhn(digits) else {
          invalidNumber = true
          continue
        }
        guard supportedNetwork(digits), let brand = cardBrand(digits),
          options.supportedBrands.contains(brand)
        else {
          unsupported = true
          continue
        }
        if let number, number != digits {
          return ScanCandidate(
            number: nil, detectedNumber: detectedNumber, expiry: nil,
            detectedExpiry: nil, hasText: true, unsupportedNetwork: false,
            invalidNumber: true, expiryIssue: .none)
        }
        number = digits
        detectedNumber = digits
        numberTop = line.top
      }
    }

    var hits: [ExpiryHit] = []
    var detectedExpiry: String?
    var issue: ExpiryIssue = .none
    for line in rows {
      let labelled = options.expiryLabels.contains {
        line.text.localizedCaseInsensitiveContains($0)
      }
      let distance = number == nil ? 0 : abs(line.top - numberTop)
      if options.expiryFormats.contains(.separated) {
        addDates(
          from: line.text, pattern: expiryPattern, labelled: labelled, distance: distance,
          currentYear: currentYear, currentMonth: currentMonth,
          hits: &hits, detected: &detectedExpiry, issue: &issue, options: options)
      }
      let digitCount = line.text.filter(\.isNumber).count
      if options.expiryFormats.contains(.spaced) && (labelled || digitCount <= 6) {
        addDates(
          from: line.text, pattern: spacedExpiryPattern, labelled: labelled, distance: distance,
          currentYear: currentYear, currentMonth: currentMonth,
          hits: &hits, detected: &detectedExpiry, issue: &issue, options: options)
      }
      if options.expiryFormats.contains(.labelledCompact) && labelled {
        addDates(
          from: line.text, pattern: compactExpiryPattern, labelled: true, distance: distance,
          currentYear: currentYear, currentMonth: currentMonth,
          hits: &hits, detected: &detectedExpiry, issue: &issue, options: options)
      }
    }
    hits.sort { $0.labelled == $1.labelled ? $0.distance < $1.distance : $0.labelled }
    var expiry: String?
    if let first = hits.first {
      let competing = hits.first { $0.value != first.value }
      if let competing, competing.labelled == first.labelled,
        abs(competing.distance - first.distance) < 0.04
      {
        issue = .ambiguous
      } else {
        expiry = first.value
      }
    }
    if let expiry {
      detectedExpiry = expiry
      issue = .none
    }
    return ScanCandidate(
      number: number, detectedNumber: detectedNumber, expiry: expiry,
      detectedExpiry: detectedExpiry, hasText: !lines.isEmpty,
      unsupportedNetwork: number == nil && unsupported,
      invalidNumber: number == nil && invalidNumber, expiryIssue: issue)
  }

  static func joinedRows(_ lines: [OCRLine]) -> [OCRLine] {
    var rows = lines
    for anchor in lines {
      let group = lines.filter { abs($0.top - anchor.top) <= 0.025 }.sorted { $0.left < $1.left }
      guard group.count >= 2, let first = group.first else { continue }
      rows.append(
        OCRLine(
          text: group.map(\.text).joined(separator: " "), top: anchor.top,
          left: first.left, boundingBox: .null))
    }
    return rows
  }

  static func isAcceptedNumber(_ digits: String) -> Bool {
    (13...19).contains(digits.count) && digits.allSatisfy(\.isNumber) && luhn(digits)
      && supportedNetwork(digits)
  }

  private static func addDates(
    from text: String, pattern: NSRegularExpression,
    labelled: Bool, distance: CGFloat, currentYear: Int, currentMonth: Int,
    hits: inout [ExpiryHit], detected: inout String?, issue: inout ExpiryIssue,
    options: ValidationOptions
  ) {
    for match in pattern.matches(in: text, range: text.fullNSRange) {
      guard let month = Int(text.capture(match, 1)),
        let printedYear = Int(text.capture(match, 2))
      else { continue }
      let yearText = text.capture(match, 2)
      if detected == nil { detected = String(format: "%02d/%@", month, String(yearText.suffix(2))) }
      guard (1...12).contains(month) else {
        issue = max(issue, .invalid)
        continue
      }
      var year = printedYear
      if yearText.count == 2 {
        year += currentYear / 100 * 100
        if year < currentYear && currentYear % 100 >= 80 && printedYear <= 20 { year += 100 }
      }
      if year < currentYear || (year == currentYear && month < currentMonth) {
        issue = max(issue, .expired)
        if options.expiredCardPolicy == .returnForReview {
          hits.append(
            ExpiryHit(
              value: String(format: "%02d/%02d", month, year % 100), distance: distance,
              labelled: labelled))
        }
      } else if year > currentYear + options.maximumFutureYears {
        issue = max(issue, .invalid)
      } else {
        hits.append(
          ExpiryHit(
            value: String(format: "%02d/%02d", month, year % 100),
            distance: distance, labelled: labelled))
      }
    }
  }

  private static func luhn(_ digits: String) -> Bool {
    var sum = 0
    for (index, character) in digits.reversed().enumerated() {
      guard var value = character.wholeNumberValue else { return false }
      if index.isMultiple(of: 2) == false {
        value *= 2
        if value > 9 { value -= 9 }
      }
      sum += value
    }
    return sum.isMultiple(of: 10)
  }

  private static func supportedNetwork(_ digits: String) -> Bool {
    if digits.hasPrefix("4") { return [13, 16, 19].contains(digits.count) }
    guard digits.count >= 4, let two = Int(digits.prefix(2)), let four = Int(digits.prefix(4))
    else { return false }
    if (51...55).contains(two) || (2221...2720).contains(four) { return digits.count == 16 }
    return (two == 34 || two == 37) && digits.count == 15
  }
}

/// Merges only repeatedly observed fragments with an exact six-digit overlap.
final class PartialPANTracker {
  let options: PartialNumberOptions
  let validation: ValidationOptions
  init(
    options: PartialNumberOptions = PartialNumberOptions(),
    validation: ValidationOptions = ValidationOptions()
  ) {
    self.options = options
    self.validation = validation
  }
  private static let fragmentPattern = try! NSRegularExpression(
    pattern: #"(?<![0-9])([0-9][0-9 -]{6,28}[0-9])(?![0-9])"#)
  private var seen: [String: Int] = [:]
  private var lastSeen: TimeInterval = 0
  private var times: [String: TimeInterval] = [:]
  private(set) var bestFragment: String?

  func clear() {
    times.removeAll()
    seen.removeAll()
    bestFragment = nil
    lastSeen = 0
  }

  func observe(_ lines: [OCRLine], at time: TimeInterval) -> String? {
    guard options.enabled else { return nil }
    if lastSeen > 0 && time - lastSeen > options.retention { clear() }
    let stale = times.filter { time - $0.value > options.retention }.map(\.key)
    stale.forEach {
      seen.removeValue(forKey: $0)
      times.removeValue(forKey: $0)
    }
    bestFragment = seen.keys.max { $0.count < $1.count }
    var frame: Set<String> = []
    for line in CardTextExtractor.joinedRows(lines) {
      for match in Self.fragmentPattern.matches(in: line.text, range: line.text.fullNSRange) {
        let digits = line.text.capture(match, 1).filter(\.isNumber)
        if (8...14).contains(digits.count) { frame.insert(digits) }
      }
    }
    guard !frame.isEmpty else { return nil }
    if Set(seen.keys).union(frame).count > options.maxFragments {
      clear()
      return nil
    }
    lastSeen = time
    for fragment in frame {
      times[fragment] = time
      seen[fragment] = min(options.readsPerFragment, (seen[fragment] ?? 0) + 1)
      if fragment.count > (bestFragment?.count ?? 0) { bestFragment = fragment }
    }
    let stable = seen.filter { $0.value >= options.readsPerFragment }.map(\.key)
    var completions: Set<String> = []
    for first in stable {
      for second in stable where first != second {
        guard options.minimumOverlap < min(first.count, second.count) else { continue }
        for overlap in options.minimumOverlap..<min(first.count, second.count) {
          guard first.suffix(overlap) == second.prefix(overlap) else { continue }
          let joined = first + String(second.dropFirst(overlap))
          if CardTextExtractor.isAcceptedNumber(joined), let brand = cardBrand(joined),
            validation.supportedBrands.contains(brand)
          {
            completions.insert(joined)
          }
        }
      }
    }
    return completions.count == 1 ? completions.first : nil
  }
}

extension String {
  fileprivate var fullNSRange: NSRange { NSRange(startIndex..<endIndex, in: self) }
  fileprivate func capture(_ match: NSTextCheckingResult, _ group: Int) -> String {
    guard let range = Range(match.range(at: group), in: self) else { return "" }
    return String(self[range])
  }
}
