import Foundation

enum DigiKeyEnrichResult: Sendable {
    case applied
    case chooseCandidate([DigiKeyCandidate])
}
