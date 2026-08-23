import Foundation

extension AppGroupMailbox {
  struct EnvelopeTimestamp: Decodable {
    let enqueuedAt: Date

    private enum CodingKeys: String, CodingKey {
      case enqueuedAt
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let seconds = try container.decode(Double.self, forKey: .enqueuedAt)
      enqueuedAt = AppGroupMailbox.decodeLegacyEnvelopeTimestamp(seconds: seconds)
    }
  }

  func enqueuedAt(from url: URL) -> Date? {
    guard let data = try? safeData(at: url) else { return nil }
    return try? decoder.decode(EnvelopeTimestamp.self, from: data).enqueuedAt
  }
}
