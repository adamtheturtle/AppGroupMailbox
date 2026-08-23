import Foundation
import Testing

@testable import AppGroupMailbox

var mailboxTestWorkerURL: URL? {
  let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  guard
    let enumerator = FileManager.default.enumerator(
      at: repository.appendingPathComponent(".build"),
      includingPropertiesForKeys: [.isExecutableKey],
      options: [.skipsHiddenFiles]
    )
  else { return nil }
  for case let candidate as URL in enumerator
  where candidate.lastPathComponent == "MailboxTestWorker" {
    if (try? candidate.resourceValues(forKeys: [.isExecutableKey]))?.isExecutable == true {
      return candidate
    }
  }
  return nil
}

func setEnqueuedAt(_ date: Date, in url: URL) throws {
  let data = try Data(contentsOf: url)
  var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  object["enqueuedAt"] = date.timeIntervalSinceReferenceDate
  try JSONSerialization.data(withJSONObject: object).write(to: url)
}

final class DiagnosticRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValues: [AppGroupMailbox<AppGroupMailboxTests.Message>.Diagnostic] = []

  func record(_ diagnostic: AppGroupMailbox<AppGroupMailboxTests.Message>.Diagnostic) {
    lock.lock()
    storedValues.append(diagnostic)
    lock.unlock()
  }

  var values: [AppGroupMailbox<AppGroupMailboxTests.Message>.Diagnostic] {
    lock.lock()
    defer { lock.unlock() }
    return storedValues
  }
}

final class Fixture {
  let root: URL
  let mailboxDirectory: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AppGroupMailboxTests-\(UUID().uuidString)", isDirectory: true)
    mailboxDirectory =
      root
      .appendingPathComponent("AppGroupMailbox", isDirectory: true)
      .appendingPathComponent("tests", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  func mailbox(
    limits: AppGroupMailbox<AppGroupMailboxTests.Message>.Limits = .init(),
    overflowPolicy: AppGroupMailbox<AppGroupMailboxTests.Message>.OverflowPolicy = .rejectNewest,
    notificationName: String? = nil,
    diagnostic:
      (@Sendable (AppGroupMailbox<AppGroupMailboxTests.Message>.Diagnostic) -> Void)? = nil
  ) throws -> AppGroupMailbox<AppGroupMailboxTests.Message> {
    try AppGroupMailbox(
      containerURL: root,
      namespace: "tests",
      limits: limits,
      overflowPolicy: overflowPolicy,
      notificationName: notificationName,
      diagnostic: diagnostic
    )
  }

  func claimedURL() throws -> URL? {
    try FileManager.default.contentsOfDirectory(
      at: mailboxDirectory,
      includingPropertiesForKeys: nil
    ).first { $0.lastPathComponent.hasPrefix("claimed-") }
  }
}
