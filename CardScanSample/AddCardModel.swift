import CardScanKit
import Foundation
import Observation

struct AddCardState {
    var cardNumber = ""
    var month = ""
    var year = ""
    var cvv = ""
    var nickname = ""
    var scanNote: String?
    var scannerPresented = false
}

enum AddCardEvent {
    case cardNumberChanged(String)
    case monthChanged(String)
    case yearChanged(String)
    case cvvChanged(String)
    case nicknameChanged(String)
    case scanRequested
    case scanDismissed
    case scanCompleted(CardScanResult)
}

/// Event reducer for the demo. No card value is persisted or logged.
@MainActor @Observable
final class AddCardModel {
    private(set) var state = AddCardState()

    func send(_ event: AddCardEvent) {
        switch event {
        case .cardNumberChanged(let value):
            let digits = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(19))
            let boundaries = digits.count == 15 ? [4, 10] : [4, 8, 12, 16]
            state.cardNumber = digits.enumerated().map { index, character in
                (boundaries.contains(index) ? " " : "") + String(character)
            }.joined()
        case .monthChanged(let value): state.month = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(2))
        case .yearChanged(let value): state.year = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(2))
        case .cvvChanged(let value): state.cvv = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(4))
        case .nicknameChanged(let value): state.nickname = String(value.prefix(48))
        case .scanRequested: state.scannerPresented = true
        case .scanDismissed: state.scannerPresented = false
        case .scanCompleted(let result):
            send(.cardNumberChanged(result.cardNumber))
            if let expiry = result.expiry, expiry.range(of: #"^[0-9]{2}/[0-9]{2}$"#, options: .regularExpression) != nil {
                state.month = String(expiry.prefix(2))
                state.year = String(expiry.suffix(2))
                state.scanNote = "Card details scanned"
            } else {
                state.month = ""
                state.year = ""
                state.scanNote = "Card number scanned"
            }
            state.scannerPresented = false
        }
    }
}
