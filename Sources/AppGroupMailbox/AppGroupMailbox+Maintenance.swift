import Foundation

extension AppGroupMailbox {
  func recoverAbandonedClaim(
    at url: URL,
    original: String,
    messageAge: TimeInterval,
    recoveredMessages: inout Bool
  ) throws {
    if messageAge > limits.messageLifetime {
      try? fileManager.removeItem(at: url)
      diagnostic?(.expiredMessageRemoved)
      return
    }
    let destination = directory.appendingPathComponent(original, isDirectory: false)
    if fileManager.fileExists(atPath: destination.path) {
      // Conflicting pending blocks recovery; quarantine the conflict and retry restore.
      do {
        try quarantine(destination)
        diagnostic?(.unsafeFileQuarantined)
      } catch {
        try quarantine(url)
        diagnostic?(.unsafeFileQuarantined)
        return
      }
    }
    do {
      try fileManager.moveItem(at: url, to: destination)
      recoveredMessages = true
      diagnostic?(.abandonedClaimRecovered)
    } catch {
      try quarantine(url)
      diagnostic?(.unsafeFileQuarantined)
    }
  }
}
