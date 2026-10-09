# CardScan for iOS

SwiftUI demo plus a reusable local Swift package, `CardScanKit`, mirroring the Android R&D scanner. The package uses Apple frameworks only: AVFoundation for the camera and torch, Vision for on-device OCR, and SwiftUI/Observation for the UI and event-driven model. It has no third-party dependency or network request.

## Open and run

Open `CardScanSample.xcodeproj` in Xcode and select the `CardScanSample` scheme. The app supports iOS 17 or later. Run on a **physical iPhone** to test card recognition; the iOS Simulator has no usable rear camera and displays the manual-entry fallback. The host app supplies `NSCameraUsageDescription` and presents the scanner from the camera icon on Add card.

The Add card button is deliberately inactive in this R&D sample. A production host must connect reviewed card details to its approved payment tokenization path. No card data is submitted by this demo.

## Modules and responsibilities

| Location | Role |
| --- | --- |
| `Sources/CardScanKit/CardScannerView.swift` | Public SwiftUI scanner UI, card guide, warnings, torch/manual controls. |
| `Sources/CardScanKit/ScannerModel.swift` | Main-actor state and event reducer, repeated-read policy, result effect. |
| `Sources/CardScanKit/CameraService.swift` | AVFoundation capture/preview/focus/torch and Vision OCR adapter. |
| `Sources/CardScanKit/CardScanCore.swift` | Pure number, network, expiry, and partial-fragment parsing. |
| `CardScanSample/AddCardModel.swift` | Demo form state and user/scan-result events. |
| `CardScanSample/ContentView.swift` | Add card and review UI; presents the package screen. |

The camera adapter emits recognized lines and image dimensions. `ScannerModel` filters observations to the same visible guide rectangle used by SwiftUI, parses candidates, and updates a single observable state. The view renders that state and sends user actions back to the model. A confirmed result leaves the package through `CardScannerView(onComplete:onCancel:)`; the demo then fills editable number and expiry fields and dismisses the scanner. Camera frames and card images are never written to disk by this code.

## Recognition behavior

- Accepts Luhn-valid Visa (13/16/19 digits), Mastercard (51–55 or 2221–2720, 16 digits), and Amex (34/37, 15 digits).
- Shows the OCR number and expiry over the live preview. An invalid number, unsupported brand, expired/invalid/conflicting date, or unreadable frame receives user guidance; validation issues are red.
- Confirms a complete number across three reads and an expiry across two reads. The expiry may be found in a later frame after the number leaves view.
- Retains short number fragments while the card is tilted. It joins only fragments seen in separate frames with at least six **exact overlapping digits**, and accepts only one valid completion. It never guesses hidden digits from Luhn.
- Returns a confirmed number without expiry after roughly 12 seconds, allowing manual expiry entry. CVV is never scanned and must be entered by the user.
- Offers tap-to-focus, torch feedback, and a manual-entry exit. Camera permission denial or missing hardware leaves manual entry available.

These are conservative R&D heuristics, not a payment-network verification. Real-device testing is needed for glare, embossing, small type, date placement, camera orientation, focus, and OCR coordinate mapping on supported iPhone models. Keep the returned fields editable for review.

## Install version 1.0.0

In Xcode, choose **File → Add Package Dependencies** and enter:

```text
https://github.com/numesh/cardscan-ios.git
```

Select **Up to Next Major Version** starting at `1.0.0`, then add the `CardScanKit` product to your app target. For `Package.swift` clients:

```swift
dependencies: [
    .package(url: "https://github.com/numesh/cardscan-ios.git", from: "1.0.0")
]
```

## Integrating the package

Import `CardScanKit` and present its public view:

```swift
CardScannerView(
    onComplete: { result in
        // result.cardNumber is digits only; result.expiry is optional MM/YY.
        // Fill editable host fields, then dismiss.
    },
    onCancel: { /* dismiss without changing existing fields */ }
)
```

The host must include an `NSCameraUsageDescription` explaining the scan and handle the returned details under its payment security design. The package intentionally does not contain card submission, storage, analytics, account validation, or a payment SDK.

## Security and release limits

This sample retains PAN and expiry temporarily in process memory and SwiftUI state. It does not save images, PAN, CVV, or OCR text to files, preferences, logs, analytics, or network. It marks sensitive UI and covers it when the scene becomes inactive. **These measures do not establish zero vulnerabilities or PCI compliance.** iOS cannot guarantee that a foreground screen cannot be photographed or captured, and Swift strings cannot be reliably zeroed. Before production use, review the final app's screenshots/app-switcher behavior, crash reporting, accessibility, keyboard/autofill, dependency and privacy declarations, tokenization flow, retention, threat model, and applicable PCI requirements.

Only synthetic test numbers should be used in automated tests or screenshots. Never add a real card image to source control or telemetry.

## Validation

Run pure parser tests with `swift test`. Build the app with the `CardScanSample` scheme for an iOS Simulator or device. The simulator checks UI and manual fallback; camera OCR, focus, and torch must be checked on physical hardware. Unit tests cover Visa/Mastercard/Amex, expiry, invalid-number warnings, and exact-overlap partial merging.

Apple API references: [AVCaptureVideoDataOutput](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput), [VNRecognizeTextRequest](https://developer.apple.com/documentation/vision/vnrecognizetextrequest), [SwiftUI model data](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app/).
