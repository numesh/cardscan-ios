import Foundation

public enum ScannerMessage: String, CaseIterable, Sendable {
  case ready
  case confirmingNumber
  case lookingForExpiry
  case confirmingExpiry
  case partialNumber
  case noNumber
  case noText
  case invalidNumber
  case unsupportedBrand
  case invalidExpiry
  case expired
  case ambiguousExpiry
  case permissionDenied
  case cameraUnavailable
  case cameraStarting
  case torchUnavailable
  case analysisFailed
  case focusFailed
  case review
  case success
  case hostRejected
  case title
  case instructions
  case close
  case manual
  case retry
  case confirm
  case torchOn
  case torchOff
  case privacy
  case expiryPrefix
  case partialPrefix
  case zoomIn
  case zoomOut
  case numberDetected
  case expiryDetected
  public var defaultText: String {
    switch self {
    case .ready: return "Hold steady and avoid reflections."
    case .confirmingNumber: return "Card number found. Hold steady to confirm."
    case .lookingForExpiry: return "Number confirmed. Keep the expiry date inside the frame."
    case .confirmingExpiry: return "Expiry found. Hold steady to confirm."
    case .partialNumber: return "Part of the number captured. Tilt the card to reveal the rest."
    case .noNumber: return "No valid card number yet. Hold steady and avoid reflections."
    case .noText: return "No readable text yet. Move closer or improve lighting."
    case .invalidNumber: return "Card number failed validation. Check the card or enter manually."
    case .unsupportedBrand: return "This card type is not supported."
    case .invalidExpiry: return "Expiry date is invalid. Check the card or enter manually."
    case .expired: return "This card has expired. Enter expiry manually."
    case .ambiguousExpiry: return "Conflicting expiry dates detected. Enter expiry manually."
    case .permissionDenied:
      return "Camera permission denied. Enter details manually or enable it in Settings."
    case .cameraUnavailable: return "Camera unavailable. Enter details manually."
    case .cameraStarting: return "Camera is starting. Try the flash again in a moment."
    case .torchUnavailable: return "Flash is unavailable on this camera."
    case .analysisFailed: return "Text could not be analyzed. Try more light or enter manually."
    case .focusFailed: return "Could not focus. Hold the card steady."
    case .review: return "Check the scanned details, then confirm."
    case .success: return "Card details scanned."
    case .hostRejected: return "These card details cannot be used. Try another card."
    case .title: return "Scan card"
    case .instructions: return "Position your card number and expiry date inside the frame."
    case .close: return "Close scanner"
    case .manual: return "Enter details manually"
    case .retry: return "Scan again"
    case .confirm: return "Use scanned details"
    case .torchOn: return "Turn torch on"
    case .torchOff: return "Turn torch off"
    case .privacy: return "Your card image is not saved."
    case .expiryPrefix: return "EXP"
    case .partialPrefix: return "Part captured:"
    case .zoomIn: return "Zoom in"
    case .zoomOut: return "Zoom out"
    case .numberDetected: return "Card number detected"
    case .expiryDetected: return "Expiry detected"
    }
  }
}
public enum CardBrand: String, CaseIterable, Sendable { case visa, mastercard, amex }
public enum ExpiryRequirement: Sendable { case disabled, optional, required }
public enum MissingExpiryAction: Sendable { case returnNumber, keepScanning, timeout }
public enum ExpiredCardPolicy: Sendable { case reject, returnForReview }
public enum CompletionMode: Sendable { case automatic, userConfirmation }
public enum NumberDisplay: Sendable { case full, masked, lastFour, hidden }
public enum GuideStyle: Sendable { case corners, outline }
public enum ControlPlacement: Sendable { case bottom, top }
public enum ExpiryFormat: Sendable { case separated, spaced, labelledCompact }
public enum RecognitionLevel: Sendable { case accurate, fast }
public enum CameraResolution: Sendable { case hd720, hd1080, high }

/// A snapshot is validated before capture. All durations are seconds, dimensions points.
public struct CardScannerConfiguration: Sendable {
  public var controls = ScannerControls()
  public var recognition = RecognitionOptions()
  public var validation = ValidationOptions()
  public var timing = ScannerTiming()
  public var partial = PartialNumberOptions()
  public var appearance = ScannerAppearance()
  public var messages: [ScannerMessage: String] = [:]
  public var completionMode: CompletionMode = .automatic
  public init() {}
  public func text(_ key: ScannerMessage) -> String { messages[key] ?? key.defaultText }
  public func validate() throws {
    func check(_ condition: Bool, _ message: String) throws {
      if !condition { throw ScannerConfigurationError.invalid(message) }
    }
    try check(
      (2...20).contains(recognition.numberConfirmationReads)
        && (2...20).contains(recognition.expiryConfirmationReads),
      "Confirmation reads must be 2...20")
    try check(
      (0...1).contains(recognition.minimumConfidence)
        && (0...0.2).contains(recognition.minimumTextHeight), "Invalid recognition threshold")
    try check(
      !recognition.languages.isEmpty && recognition.languages.allSatisfy { !$0.isEmpty },
      "Recognition languages cannot be empty")
    try check(
      !validation.supportedBrands.isEmpty && (1...50).contains(validation.maximumFutureYears),
      "Invalid validation policy")
    try check(
      !validation.expiryFormats.isEmpty && validation.expiryLabels.allSatisfy { !$0.isEmpty },
      "Invalid expiry parsing options")
    try check(
      (0...5).contains(timing.analysisInterval) && (0...10).contains(timing.minimumStableDuration),
      "Invalid analysis timing")
    try check(
      (0.1...30).contains(timing.confirmationWindow)
        && (0.1...30).contains(timing.candidateResetDelay), "Invalid confirmation timing")
    try check(
      (0...120).contains(timing.expiryWaitTimeout)
        && (timing.sessionTimeout == nil || (1...600).contains(timing.sessionTimeout!)),
      "Invalid timeout")
    try check(
      [
        timing.warningDisplayDuration, timing.previewRetentionDuration,
        timing.expiryPreviewRetentionDuration,
      ].allSatisfy { (0...10).contains($0) }, "Invalid display duration")
    try check(
      (0...5).contains(timing.successDisplayDuration)
        && (0...5).contains(timing.focusMarkerDuration)
        && (1...600).contains(timing.confirmedNumberRetention), "Invalid retention")
    try check(
      (6...13).contains(partial.minimumOverlap) && (2...20).contains(partial.readsPerFragment)
        && (2...32).contains(partial.maxFragments) && (0.5...30).contains(partial.retention),
      "Invalid fragment policy")
    try check((1...10).contains(controls.initialZoom), "Invalid zoom")
    try check(
      (0.4...0.98).contains(appearance.guideWidthFraction)
        && (1...2.5).contains(appearance.guideAspectRatio)
        && (0.15...0.6).contains(appearance.guideVerticalPosition), "Invalid guide geometry")
    try check(
      (0...40).contains(appearance.analysisPadding) && (0...1).contains(appearance.shadeOpacity),
      "Invalid guide padding")
    try check(
      (16...48).contains(appearance.iconSize) && (48...96).contains(appearance.buttonSize)
        && (0...32).contains(appearance.spacing), "Invalid control dimensions")
    try check(
      (0...48).contains(appearance.cornerRadius) && (1...8).contains(appearance.guideStroke),
      "Invalid decoration")
    try check(
      [
        appearance.titleSize, appearance.bodySize, appearance.buttonTextSize,
        appearance.previewSize,
      ].allSatisfy { (12...32).contains($0) }, "Invalid text size")
  }
  public static var balanced: Self { Self() }
  public static var fast: Self {
    var c = Self()
    c.recognition.numberConfirmationReads = 2
    c.timing.analysisInterval = 0.15
    c.recognition.level = .fast
    return c
  }
  public static var strict: Self {
    var c = Self()
    c.recognition.numberConfirmationReads = 5
    c.recognition.expiryConfirmationReads = 3
    c.timing.minimumStableDuration = 0.6
    c.validation.expiryRequirement = .required
    return c
  }
}
public enum ScannerConfigurationError: Error { case invalid(String) }
public struct ScannerControls: Sendable {
  public var torchVisible = true
  public var initialTorchEnabled = false
  public var hideTorchWhenUnavailable = false
  public var tapToFocusEnabled = true
  public var focusMarkerVisible = true
  public var manualEntryVisible = true
  public var closeVisible = true
  public var retryVisible = false
  public var zoomVisible = false
  public var initialZoom: CGFloat = 1
  public var hapticsEnabled = false
  public var placement: ControlPlacement = .bottom
  public init() {}
}
public struct RecognitionOptions: Sendable {
  public var numberConfirmationReads = 3
  public var expiryConfirmationReads = 2
  public var minimumConfidence: Float = 0
  public var minimumTextHeight: Float = 0
  public var level: RecognitionLevel = .accurate
  public var resolution: CameraResolution = .high
  public var languages = ["en-US"]
  public init() {}
}
public struct ValidationOptions: Sendable {
  public var supportedBrands: Set<CardBrand> = Set(CardBrand.allCases)
  public var expiryRequirement: ExpiryRequirement = .optional
  public var missingExpiryAction: MissingExpiryAction = .returnNumber
  public var expiredCardPolicy: ExpiredCardPolicy = .reject
  public var maximumFutureYears = 20
  public var expiryFormats: Set<ExpiryFormat> = [.separated, .spaced, .labelledCompact]
  public var expiryLabels = ["EXP", "VALID", "THRU", "GOOD"]
  public init() {}
}
public struct ScannerTiming: Sendable {
  public var analysisInterval: TimeInterval = 0.25
  public var minimumStableDuration: TimeInterval = 0
  public var confirmationWindow: TimeInterval = 3
  public var candidateResetDelay: TimeInterval = 2
  public var expiryWaitTimeout: TimeInterval = 12
  public var sessionTimeout: TimeInterval? = nil
  public var warningDisplayDuration: TimeInterval = 1.6
  public var previewRetentionDuration: TimeInterval = 1
  public var expiryPreviewRetentionDuration: TimeInterval = 1.5
  public var focusMarkerDuration: TimeInterval = 0.9
  public var successDisplayDuration: TimeInterval = 0
  public var confirmedNumberRetention: TimeInterval = 60
  public init() {}
}
public struct PartialNumberOptions: Sendable {
  public var enabled = true
  public var previewVisible = true
  public var readsPerFragment = 2
  public var minimumOverlap = 6
  public var retention: TimeInterval = 5
  public var maxFragments = 12
  public init() {}
}
/// Colors are ARGB integers; icons are SF Symbol names. Use view slots for custom assets/fonts.
public struct ScannerAppearance: Sendable {
  public var backgroundColor: UInt32 = 0xFF00_0000
  public var textColor: UInt32 = 0xFFFF_FFFF
  public var guideColor: UInt32 = 0xFFFF_D522
  public var warningColor: UInt32 = 0xFFAE_2525
  public var successColor: UInt32 = 0xFF16_883B
  public var focusColor: UInt32 = 0xFFFF_C83D
  public var buttonColor: UInt32 = 0xFF22_2222
  public var previewColor: UInt32 = 0xDD00_0000
  public var titleSize: CGFloat = 20
  public var bodySize: CGFloat = 15
  public var buttonTextSize: CGFloat = 15
  public var previewSize: CGFloat = 17
  public var iconSize: CGFloat = 28
  public var buttonSize: CGFloat = 72
  public var spacing: CGFloat = 12
  public var cornerRadius: CGFloat = 16
  public var guideWidthFraction: CGFloat = 0.88
  public var guideAspectRatio: CGFloat = 1.5
  public var guideVerticalPosition: CGFloat = 0.25
  public var guideStroke: CGFloat = 3
  public var analysisPadding: CGFloat = 24
  public var shadeOpacity: Double = 0.67
  public var guideStyle: GuideStyle = .corners
  public var guideVisible = true
  public var numberDisplay: NumberDisplay = .full
  public var expiryPreviewVisible = true
  public var privacyVisible = true
  public var announceStatus = true
  public var closeIcon = "xmark"
  public var torchOnIcon = "flashlight.on.fill"
  public var torchOffIcon = "flashlight.off.fill"
  public var manualIcon = "pencil"
  public var privacyIcon = "shield.lefthalf.filled"
  public init() {}
}
func cardBrand(_ digits: String) -> CardBrand? {
  if digits.hasPrefix("4") && [13, 16, 19].contains(digits.count) { return .visa }
  guard let two = Int(digits.prefix(2)), let four = Int(digits.prefix(4)) else { return nil }
  if ((51...55).contains(two) || (2221...2720).contains(four)) && digits.count == 16 {
    return .mastercard
  }
  if (two == 34 || two == 37) && digits.count == 15 { return .amex }
  return nil
}
