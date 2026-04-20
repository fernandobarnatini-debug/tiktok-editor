import Foundation

struct KeepRange: Codable {
    let start: Double
    let end: Double
}

struct LabeledRange: Codable {
    let start: Double
    let end: Double
    let text: String
}
