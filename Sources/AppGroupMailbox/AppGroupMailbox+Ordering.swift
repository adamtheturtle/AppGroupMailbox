import Foundation

extension AppGroupMailbox {
  func pendingEntries() throws -> [Entry] {
    try contents()
      .filter { Self.isPendingMessageName($0.lastPathComponent) }
      .compactMap { url in
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else { return nil }
        let envelope: EnvelopeTimestamp?
        if let data = try? safeData(at: url) {
          envelope = try? decoder.decode(EnvelopeTimestamp.self, from: data)
        } else {
          envelope = nil
        }
        return Entry(
          url: url,
          originalName: url.lastPathComponent,
          enqueuedAt: envelope?.enqueuedAt
        )
      }
      .sorted { lhs, rhs in
        guard let lhsDate = lhs.enqueuedAt, let rhsDate = rhs.enqueuedAt else {
          if lhs.enqueuedAt != nil, rhs.enqueuedAt == nil { return true }
          if lhs.enqueuedAt == nil, rhs.enqueuedAt != nil { return false }
          return lhs.originalName < rhs.originalName
        }
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return lhs.originalName < rhs.originalName
      }
  }
}
