#if os(iOS)
import CoreGraphics
import Foundation
import Observation

struct ScannerState {
    var status = "Hold steady and avoid reflections."
    var warningVisible = false
    var numberPreview: String?
    var expiryPreview: String?
    var expiryPreviewInvalid = false
    var torchEnabled = false
    var focusPoint: CGPoint?
}

/// All scanner decisions enter this reducer; the camera adapter only supplies OCR lines.
@MainActor @Observable
final class ScannerModel {
    private(set) var state = ScannerState()
    private(set) var previewSize: CGSize = .zero
    let onComplete: (CardScanResult) -> Void

    @ObservationIgnored lazy var camera = CameraService(
        onFrame: { [weak self] lines, imageSize in self?.receive(lines, imageSize: imageSize) },
        onStatus: { [weak self] message, warning in self?.setStatus(message, warning: warning) },
        onTorch: { [weak self] enabled in self?.state.torchEnabled = enabled }
    )
    private var tracker = PartialPANTracker()
    private var active = false
    private var completed = false
    private var recentWarning: String?
    private var warningUntil: TimeInterval = 0
    private var lastNumberPreviewAt: TimeInterval = 0
    private var lastExpiryPreviewAt: TimeInterval = 0
    private var observedNumber: String?
    private var numberReads = 0
    private var firstNumberAt: TimeInterval = 0
    private var lastValidNumberAt: TimeInterval = 0
    private var observedExpiry: String?
    private var expiryReads = 0
    private var lastExpiryAt: TimeInterval = 0
    private var firstExpiryIssueAt: TimeInterval = 0

    init(onComplete: @escaping (CardScanResult) -> Void) { self.onComplete = onComplete }

    func start() async {
        guard !active else { return }
        resetSession()
        active = true
        await camera.start()
        // Permission can resolve after dismissal; never leave that session running.
        if !active { camera.stop() }
    }

    func stop() {
        active = false
        camera.stop()
        tracker.clear()
        observedNumber = nil
        observedExpiry = nil
        state.numberPreview = nil
        state.expiryPreview = nil
    }

    private func resetSession() {
        tracker.clear()
        state = ScannerState()
        completed = false
        recentWarning = nil
        warningUntil = 0
        lastNumberPreviewAt = 0
        lastExpiryPreviewAt = 0
        observedNumber = nil
        numberReads = 0
        firstNumberAt = 0
        lastValidNumberAt = 0
        observedExpiry = nil
        expiryReads = 0
        lastExpiryAt = 0
        firstExpiryIssueAt = 0
    }

    func toggleTorch() { camera.toggleTorch() }

    func focus(at point: CGPoint) {
        state.focusPoint = point
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            if state.focusPoint == point { state.focusPoint = nil }
        }
    }

    func updatePreviewSize(_ size: CGSize) { previewSize = size }

    /// The same guide geometry is used for the overlay and for OCR filtering.
    func guide(in size: CGSize) -> CGRect {
        let width = max(0, size.width - 48)
        let height = width * 0.67
        let top = max(0, min(size.height * 0.25, size.height - height - 280))
        return CGRect(x: 24, y: top, width: width, height: height)
    }

    private func receive(_ lines: [OCRLine], imageSize: CGSize) {
        guard active, !completed, previewSize.width > 0, previewSize.height > 0 else { return }
        let guideRect = guide(in: previewSize).insetBy(dx: -24, dy: -24)
        let scale = max(previewSize.width / imageSize.width, previewSize.height / imageSize.height)
        let xOffset = (previewSize.width - imageSize.width * scale) / 2
        let yOffset = (previewSize.height - imageSize.height * scale) / 2
        let filtered = lines.filter { line in
            let center = CGPoint(x: xOffset + line.boundingBox.midX * imageSize.width * scale,
                                 y: yOffset + (1 - line.boundingBox.midY) * imageSize.height * scale)
            return guideRect.contains(center)
        }
        process(filtered, at: ProcessInfo.processInfo.systemUptime)
    }

    private func process(_ lines: [OCRLine], at now: TimeInterval) {
        var candidate = CardTextExtractor.extract(lines)
        var merged = false
        if candidate.number == nil && observedNumber == nil {
            if let completedNumber = tracker.observe(lines, at: now) {
                candidate.number = completedNumber
                candidate.detectedNumber = completedNumber
                candidate.hasText = true
                candidate.unsupportedNetwork = false
                candidate.invalidNumber = false
                merged = true
                tracker.clear()
            } else if (candidate.detectedNumber?.count ?? 0) >= 15 {
                tracker.clear()
            }
        } else if candidate.number != nil { tracker.clear() }

        if let digits = candidate.detectedNumber {
            showNumber(digits, at: now)
        } else if let observedNumber, numberReads >= 3 {
            showNumber(observedNumber, at: now)
        } else if let fragment = tracker.bestFragment {
            state.numberPreview = "Part captured: \(fragment) …"
            lastNumberPreviewAt = now
        } else if now - lastNumberPreviewAt > 1 {
            state.numberPreview = nil
        }
        showExpiry(candidate.detectedExpiry, invalid: candidate.expiryIssue != .none, at: now)

        if candidate.expiryIssue != .none && firstExpiryIssueAt == 0 { firstExpiryIssueAt = now }
        if candidate.expiry != nil { firstExpiryIssueAt = 0 }

        guard let number = candidate.number else {
            handleWithoutNumber(candidate, at: now)
            return
        }
        lastValidNumberAt = now
        if number == observedNumber { numberReads += 1 }
        else {
            observedNumber = number
            numberReads = merged ? 3 : 1
            firstNumberAt = now
            observedExpiry = nil
            expiryReads = 0
            firstExpiryIssueAt = candidate.expiryIssue == .none ? 0 : now
        }
        observeExpiry(candidate.expiry, at: now)
        if candidate.expiry != nil { recentWarning = nil; warningUntil = 0 }

        if candidate.expiryIssue != .none && observedExpiry == nil {
            warnForExpiry(candidate.expiryIssue, at: now)
            if numberReads >= 3 && now - firstNumberAt >= 12 && now - firstExpiryIssueAt >= 1.6 {
                finish(number, expiry: nil)
            }
            return
        }
        if numberReads < 3 {
            setStatus("Card number found. Hold steady to confirm.", at: now)
        } else if let expiry = observedExpiry, expiryReads >= 2 {
            finish(number, expiry: expiry)
        } else if now - firstNumberAt >= 12 &&
                    (firstExpiryIssueAt == 0 || now - firstExpiryIssueAt >= 1.6) {
            finish(number, expiry: nil)
        } else {
            setStatus(observedExpiry == nil ? "Number confirmed. Keep the expiry date inside the frame." :
                "Expiry found. Hold steady to confirm.", at: now)
        }
    }

    private func handleWithoutNumber(_ candidate: ScanCandidate, at now: TimeInterval) {
        if let observedNumber, numberReads >= 3 {
            observeExpiry(candidate.expiry, at: now)
            if let expiry = observedExpiry, expiryReads >= 2 {
                finish(observedNumber, expiry: expiry)
                return
            }
            if now - firstNumberAt >= 12 &&
               (firstExpiryIssueAt == 0 || now - firstExpiryIssueAt >= 1.6) {
                finish(observedNumber, expiry: nil)
                return
            }
        } else if now - lastValidNumberAt > 2 {
            observedNumber = nil
            numberReads = 0
            observedExpiry = nil
            expiryReads = 0
        }
        if candidate.unsupportedNetwork && ((candidate.detectedNumber?.count ?? 0) >= 15 || tracker.bestFragment == nil) {
            warn("Only Visa, Mastercard and Amex can be scanned.", at: now)
        } else if candidate.invalidNumber && ((candidate.detectedNumber?.count ?? 0) >= 15 || tracker.bestFragment == nil) {
            warn("Card number failed validation. Check the card or enter manually.", at: now)
        } else if candidate.expiryIssue != .none && observedExpiry == nil {
            warnForExpiry(candidate.expiryIssue, at: now)
        } else if observedNumber != nil && candidate.expiry != nil {
            setStatus("Expiry found. Hold steady to confirm.", at: now)
        } else if observedNumber != nil && numberReads >= 3 {
            setStatus("Number confirmed. Keep the expiry date inside the frame.", at: now)
        } else if tracker.bestFragment != nil {
            setStatus("Part of the number captured. Tilt the card to reveal the rest.", at: now)
        } else if candidate.hasText {
            setStatus("No valid card number yet. Hold steady and avoid reflections.", at: now)
        } else {
            setStatus("No readable text yet. Move closer or improve lighting.", at: now)
        }
    }

    private func observeExpiry(_ expiry: String?, at now: TimeInterval) {
        guard let expiry else {
            if now - lastExpiryAt > 2 { observedExpiry = nil; expiryReads = 0 }
            return
        }
        expiryReads = expiry == observedExpiry && now - lastExpiryAt <= 3 ? expiryReads + 1 : 1
        observedExpiry = expiry
        lastExpiryAt = now
    }

    private func showNumber(_ digits: String, at now: TimeInterval) {
        lastNumberPreviewAt = now
        let boundaries = digits.count == 15 ? [4, 10] : Array(stride(from: 4, through: 16, by: 4))
        state.numberPreview = digits.enumerated().map { index, character in
            (boundaries.contains(index) ? " " : "") + String(character)
        }.joined()
    }

    private func showExpiry(_ expiry: String?, invalid: Bool, at now: TimeInterval) {
        if let expiry {
            lastExpiryPreviewAt = now
            state.expiryPreview = expiry
            state.expiryPreviewInvalid = invalid
        } else if let observedExpiry, numberReads >= 3 {
            state.expiryPreview = observedExpiry
            state.expiryPreviewInvalid = false
        } else if now - lastExpiryPreviewAt > 1.5 {
            state.expiryPreview = nil
        }
    }

    private func warnForExpiry(_ issue: ExpiryIssue, at now: TimeInterval) {
        switch issue {
        case .expired: warn("This card has expired. Enter expiry manually.", at: now)
        case .ambiguous: warn("Conflicting expiry dates detected. Enter expiry manually.", at: now)
        case .invalid: warn("Expiry date is invalid. Check the card or enter manually.", at: now)
        case .none: break
        }
    }

    private func warn(_ message: String, at now: TimeInterval) {
        recentWarning = message
        warningUntil = now + 1.6
        state.status = message
        state.warningVisible = true
    }

    private func setStatus(_ message: String, warning: Bool = false) {
        if warning { warn(message, at: ProcessInfo.processInfo.systemUptime) }
        else { setStatus(message, at: ProcessInfo.processInfo.systemUptime) }
    }

    private func setStatus(_ message: String, at now: TimeInterval) {
        state.status = now < warningUntil ? recentWarning ?? message : message
        state.warningVisible = now < warningUntil
    }

    private func finish(_ number: String, expiry: String?) {
        guard !completed else { return }
        completed = true
        camera.stop()
        onComplete(CardScanResult(cardNumber: number, expiry: expiry))
    }
}
#endif
