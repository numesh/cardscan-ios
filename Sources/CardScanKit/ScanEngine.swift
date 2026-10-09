import Foundation

public enum CardValidationStatus: Sendable { case valid, expiredRequiresReview }
public enum ScannerFailure: Sendable { case cameraUnavailable, invalidConfiguration }
public enum CancelReason: Sendable { case user, systemBack }
public enum ScanOutcome {
  case completed(CardScanResult)
  case manualEntryRequested
  case cancelled(CancelReason)
  case timedOut
  case failed(ScannerFailure)
}
public struct ScannerProgress {
  public let message: ScannerMessage
  public let warning: Bool
}
public enum ScannerAction { case close, manualEntry, retry, confirm, toggleTorch, zoomIn, zoomOut }
public struct ScannerState {
  public internal(set) var message: ScannerMessage = .ready
  public internal(set) var warningVisible = false
  public internal(set) var numberPreview: String?
  public internal(set) var expiryPreview: String?
  public internal(set) var expiryPreviewInvalid = false
  public internal(set) var readyToConfirm = false
  public internal(set) var torchEnabled = false
  public internal(set) var torchAvailable = false
  public internal(set) var focusPoint: CGPoint?
}

/// Pure session policy, also exercised by macOS package tests. Time counts active seconds.
final class ScanEngine {
  let config: CardScannerConfiguration
  let validator: ((CardScanResult) -> Bool)?
  var state = ScannerState()
  private(set) var outcome: ScanOutcome?
  private var tracker: PartialPANTracker
  private var number: String?
  private var numberReads = 0
  private var firstNumber: TimeInterval = 0
  private var lastNumber: TimeInterval = 0
  private var confirmedAt: TimeInterval?
  private var expiry: String?
  private var expiryReads = 0
  private var lastExpiry: TimeInterval = 0
  private var lastNumberPreview: TimeInterval = 0
  private var lastExpiryPreview: TimeInterval = 0
  private var warningUntil: TimeInterval = 0
  private var pending: CardScanResult?
  private var deliverAt: TimeInterval?
  private var expired = false

  init(config: CardScannerConfiguration, validator: ((CardScanResult) -> Bool)? = nil) throws {
    try config.validate()
    self.config = config
    self.validator = validator
    tracker = PartialPANTracker(options: config.partial, validation: config.validation)
  }
  func reset() {
    tracker.clear()
    number = nil
    numberReads = 0
    confirmedAt = nil
    expiry = nil
    expiryReads = 0
    pending = nil
    deliverAt = nil
    expired = false
    warningUntil = 0
    state = ScannerState()
    outcome = nil
  }
  func terminate(_ value: ScanOutcome) {
    guard outcome == nil else { return }
    outcome = value
    pending = nil
    tracker.clear()
    number = nil
    expiry = nil
    state = ScannerState()
  }
  func status(_ key: ScannerMessage, warning: Bool, now: TimeInterval) {
    guard outcome == nil else { return }
    if warning && state.message != key { warningUntil = now + config.timing.warningDisplayDuration }
    if warning || now >= warningUntil {
      state.message = key
      state.warningVisible = warning
    }
  }
  func confirm(now: TimeInterval) {
    if pending != nil && deliverAt == nil { deliverAt = now + config.timing.successDisplayDuration }
    tick(now: now)
  }
  func frame(
    _ lines: [OCRLine], now: TimeInterval, date: Date = Date(), calendar: Calendar = .current
  ) {
    guard outcome == nil, pending == nil else { return }
    let t = config.timing
    var c = CardTextExtractor.extract(
      lines, now: date, calendar: calendar, options: config.validation)
    if let value = c.number, value != number {
      number = value
      numberReads = 0
      firstNumber = now
      confirmedAt = nil
      expiry = nil
      expiryReads = 0
      tracker.clear()
    }
    if c.number == nil && (c.detectedNumber?.count ?? 0) >= 15 { tracker.clear() }
    if c.number == nil && confirmedAt == nil && (c.detectedNumber?.count ?? 0) < 15,
      let value = tracker.observe(lines, at: now)
    {
      c.number = value
      c.detectedNumber = value
      c.invalidNumber = false
      c.unsupportedNetwork = false
    }
    if let value = c.detectedNumber {
      state.numberPreview = displayNumber(value)
      lastNumberPreview = now
    }
    if c.detectedNumber == nil && number == nil && config.partial.previewVisible,
      let fragment = tracker.bestFragment, let value = displayNumber(fragment)
    {
      state.numberPreview = config.text(.partialPrefix) + " " + value + " …"
      lastNumberPreview = now
    }
    if config.validation.expiryRequirement != .disabled, let value = c.detectedExpiry {
      state.expiryPreview = value
      state.expiryPreviewInvalid = c.expiryIssue != .none
      lastExpiryPreview = now
    }
    if let value = c.number {
      if number != value || (confirmedAt == nil && now - lastNumber > t.confirmationWindow) {
        number = value
        numberReads = 0
        firstNumber = now
        expiry = nil
        expiryReads = 0
      }
      numberReads += 1
      lastNumber = now
      if numberReads >= config.recognition.numberConfirmationReads
        && now - firstNumber >= t.minimumStableDuration && confirmedAt == nil
      {
        confirmedAt = now
      }
    }
    if number != nil && config.validation.expiryRequirement != .disabled {
      if let value = c.expiry {
        expiryReads =
          value == expiry && now - lastExpiry <= t.confirmationWindow ? expiryReads + 1 : 1
        expiry = value
        lastExpiry = now
        let parts = value.split(separator: "/").compactMap { Int($0) }
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        expired = 2000 + parts[1] < year || (2000 + parts[1] == year && parts[0] < month)
        state.expiryPreviewInvalid = expired
      } else if c.expiryIssue != .none || now - lastExpiry > t.candidateResetDelay {
        expiry = nil
        expiryReads = 0
      }
    }
    if c.unsupportedNetwork {
      status(.unsupportedBrand, warning: true, now: now)
    } else if c.invalidNumber && tracker.bestFragment == nil {
      status(.invalidNumber, warning: true, now: now)
    } else if config.validation.expiryRequirement != .disabled && c.expiryIssue != .none {
      status(
        c.expiryIssue == .expired
          ? .expired : c.expiryIssue == .ambiguous ? .ambiguousExpiry : .invalidExpiry,
        warning: true, now: now)
    } else if confirmedAt != nil {
      status(expiry == nil ? .lookingForExpiry : .confirmingExpiry, warning: false, now: now)
    } else if number != nil {
      status(.confirmingNumber, warning: false, now: now)
    } else if tracker.bestFragment != nil {
      status(.partialNumber, warning: false, now: now)
    } else {
      status(c.hasText ? .noNumber : .noText, warning: false, now: now)
    }
    if confirmedAt != nil {
      if config.validation.expiryRequirement == .disabled {
        prepare(nil, now: now)
      } else if expiry != nil && expiryReads >= config.recognition.expiryConfirmationReads {
        prepare(expiry, now: now)
      }
    }
    tick(now: now)
  }
  func tick(now: TimeInterval) {
    guard outcome == nil else { return }
    if let deadline = deliverAt, now >= deadline, let result = pending {
      terminate(.completed(result))
      return
    }
    if let timeout = config.timing.sessionTimeout, now >= timeout {
      terminate(.timedOut)
      return
    }
    guard pending == nil else { return }
    let t = config.timing
    if number != nil && confirmedAt == nil && now - lastNumber > t.candidateResetDelay {
      number = nil
      numberReads = 0
      expiry = nil
      expiryReads = 0
    }
    if let at = confirmedAt {
      if now - at >= t.confirmedNumberRetention {
        number = nil
        confirmedAt = nil
        expiry = nil
        expiryReads = 0
        tracker.clear()
        state = ScannerState()
        return
      }
      if now - at >= t.expiryWaitTimeout && now >= warningUntil {
        switch config.validation.missingExpiryAction {
        case .returnNumber:
          if config.validation.expiryRequirement == .optional { prepare(nil, now: now) }
        case .timeout: terminate(.timedOut)
        case .keepScanning: break
        }
      }
    }
    if now - lastNumberPreview > t.previewRetentionDuration {
      state.numberPreview = confirmedAt != nil ? number.flatMap(displayNumber) : nil
    }
    if now - lastExpiryPreview > t.expiryPreviewRetentionDuration { state.expiryPreview = nil }
  }
  private func prepare(_ value: String?, now: TimeInterval) {
    guard pending == nil, let number else { return }
    let result = CardScanResult(
      cardNumber: number, expiry: value,
      validationStatus: value != nil && expired ? .expiredRequiresReview : .valid)
    if let validator, !validator(result) {
      reset()
      status(.hostRejected, warning: true, now: now)
      return
    }
    pending = result
    state.numberPreview = displayNumber(number)
    state.expiryPreview = value
    state.readyToConfirm =
      config.completionMode == .userConfirmation || result.validationStatus != .valid
    state.message = .review
    state.warningVisible = result.validationStatus != .valid
    if !state.readyToConfirm {
      state.message = .success
      deliverAt = now + config.timing.successDisplayDuration
    }
  }
  private func displayNumber(_ digits: String) -> String? {
    switch config.appearance.numberDisplay {
    case .hidden: return nil
    case .lastFour: return String(digits.suffix(4))
    case .masked: return String(repeating: "•", count: max(0, digits.count - 4)) + digits.suffix(4)
    case .full:
      let boundaries = digits.count == 15 ? [4, 10] : [4, 8, 12, 16]
      return digits.enumerated().map {
        (boundaries.contains($0.offset) ? " " : "") + String($0.element)
      }.joined()
    }
  }
}
