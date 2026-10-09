# CardScan for iOS

On-device Visa, Mastercard, and Amex scanning using AVFoundation, Apple Vision, and SwiftUI. Includes the reusable `CardScanKit` Swift package and a separate demo with interactive scanner settings. No third-party runtime dependency or network OCR.

**Current release: 1.1.0.** See the [configuration guide](docs/CONFIGURATION.md) for every option, UI slots, platform differences, and migration details.

## Install

In Xcode choose **File → Add Package Dependencies**, enter `https://github.com/numesh/cardscan-ios.git`, and select version `1.1.0` or later. Add the `CardScanKit` product to your target. Package clients can use:

```swift
.package(url: "https://github.com/numesh/cardscan-ios.git", from: "1.1.0")
```

Requires iOS 17+. Include `NSCameraUsageDescription` in the host Info.plist.

## Present the scanner

```swift
var configuration = CardScannerConfiguration.balanced
configuration.controls.retryVisible = true
configuration.timing.expiryWaitTimeout = 15

CardScannerView(configuration: configuration, onOutcome: { outcome in
    // On .completed, fill editable fields; dismiss for every terminal outcome.
})
```

The original `CardScannerView(onComplete:onCancel:)` initializer remains supported. Terminal outcomes distinguish completion, manual entry, cancellation, timeout and failure. Result metadata includes brand, validation status, and missing expiry. Hosts own the Add card form, CVV entry, dismissal, and payment integration.

## Architecture

`CardScannerConfiguration` provides a validated session snapshot. `CardScannerView` renders observable state and dispatches typed actions, with optional header/controls/status/detected-value slots. `ScannerModel` handles lifecycle, the active-time clock, progress codes and exactly-once results. `ScanEngine` owns deterministic confirmation and completion policy. `CameraService` handles AVFoundation/Vision; `CardScanCore` and `PartialPANTracker` parse observations. The demo's `AddCardModel` owns form state and events independently of the scanner.

## Build and test

Open `CardScanSample.xcodeproj` and run the sample. Its Settings button changes scanner configuration before presentation.

```sh
swift test
xcodebuild -project CardScanSample.xcodeproj -scheme CardScanSample \
  -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Package tests cover parser and configurable session policy without a camera. Simulator builds check compilation and integration; use physical iPhones to evaluate OCR, focus, torch, rotation, glare and accuracy. The simulator has no usable rear camera and reports camera unavailability.

## Data handling

The scanner retains PAN/expiry temporarily in memory and never writes images, PAN, CVV or OCR text to files, preferences, logs or network. The UI marks previews sensitive and covers the screen while inactive. Masking changes preview presentation only. iOS cannot block all foreground screenshots, and Swift strings cannot be reliably zeroed. This release does not establish zero vulnerabilities or PCI compliance; evaluate the final host app's protected-field/tokenization flow and retention. Automated tests use synthetic numbers.

## Release process

Update changelog and installation examples, run tests/build, push `main`, and wait for CI. Tag the verified commit `vMAJOR.MINOR.PATCH`; release CI tests and builds before creating the release. Swift Package Manager resolves the root manifest at the tag. Never move published tags or add real card data to tests or screenshots.

MIT licensed. The Android companion is [cardscan-android](https://github.com/numesh/cardscan-android).
