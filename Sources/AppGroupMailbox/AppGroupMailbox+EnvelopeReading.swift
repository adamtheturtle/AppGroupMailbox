import Foundation

extension AppGroupMailbox {
  struct EnvelopeTimestamp: Decodable {
    let enqueuedAt: Date
  }

  func enqueuedAt(from url: URL) -> Date? {
    guard let data = try? safeData(at: url) else { return nil }
    return try? decoder.decode(EnvelopeTimestamp.self, from: data).enqueuedAt
  }
}
