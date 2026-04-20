import Foundation

struct Word: Codable {
    let word: String
    let start: Double
    let end: Double
}

struct Segment: Codable {
    let text: String
    let start: Double
    let end: Double
    let words: [Word]
}
