import Foundation
import Testing

@testable import AppGroupMailbox

@Suite("AppGroupMailbox")
struct AppGroupMailboxTests {
  struct Message: Codable, Sendable, Equatable {
    let value: String
  }

  @Test("Messages are claimed in enqueue order and acknowledged")
  func fifoAndAcknowledgement() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox()
    let ids = try ["one", "two", "three"].map { try mailbox.enqueue(Message(value: $0)) }

    let claims = try mailbox.claimPending()
    #expect(claims.map(\.message.value) == ["one", "two", "three"])
    #expect(claims.map(\.id) == ids)
    for claim in claims { try claim.acknowledge() }
    #expect(try mailbox.claimPending().isEmpty)
  }

  @Test("A released claim returns to its original queue position")
  func release() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox()
    try mailbox.enqueue(Message(value: "first"))
    try mailbox.enqueue(Message(value: "second"))

    let first = try #require(try mailbox.claimPending(limit: 1).first)
    try first.release()
    #expect(try mailbox.claimPending().map(\.message.value) == ["first", "second"])
  }

  @Test("A caller-supplied ID makes a retried enqueue idempotent")
  func idempotentEnqueue() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox()
    let id = UUID()

    try mailbox.enqueue(Message(value: "original"), id: id)
    try mailbox.enqueue(Message(value: "retry"), id: id)

    let claims = try mailbox.claimPending()
    #expect(claims.count == 1)
    #expect(claims.first?.id == id)
    #expect(claims.first?.message.value == "original")
  }

  @Test("A full mailbox can reject the newest message")
  func rejectOverflow() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox(limits: .init(maxMessages: 2))
    try mailbox.enqueue(Message(value: "one"))
    try mailbox.enqueue(Message(value: "two"))

    #expect(throws: AppGroupMailbox<Message>.MailboxError.mailboxFull) {
      try mailbox.enqueue(Message(value: "three"))
    }
  }

  @Test("A full mailbox can discard its oldest message")
  func discardOverflow() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox(limits: .init(maxMessages: 2), overflowPolicy: .discardOldest)
    try mailbox.enqueue(Message(value: "one"))
    try mailbox.enqueue(Message(value: "two"))
    try mailbox.enqueue(Message(value: "three"))

    #expect(try mailbox.claimPending().map(\.message.value) == ["two", "three"])
  }

  @Test("Encoded payload size is bounded before writing")
  func payloadBound() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox(limits: .init(maxPayloadBytes: 80))

    #expect(throws: AppGroupMailbox<Message>.MailboxError.self) {
      try mailbox.enqueue(Message(value: String(repeating: "x", count: 100)))
    }
    #expect(try mailbox.claimPending().isEmpty)
  }

  @Test("Malformed and symbolic-link inputs are not decoded")
  func unsafeInputs() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox()
    let directory = fixture.mailboxDirectory
    try Data("not json".utf8).write(
      to: directory.appendingPathComponent("pending-00000000000000000001-bad.json"))
    let outside = fixture.root.appendingPathComponent("outside.json")
    try Data("{}".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent("pending-00000000000000000002-link.json"),
      withDestinationURL: outside
    )

    #expect(try mailbox.claimPending().isEmpty)
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(names.filter { $0.hasPrefix("quarantine-") }.count == 2)
  }

  @Test("Expired messages are removed")
  func expiration() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox(limits: .init(messageLifetime: 1))
    try mailbox.enqueue(Message(value: "old"))
    let pending = try #require(
      try FileManager.default.contentsOfDirectory(
        at: fixture.mailboxDirectory,
        includingPropertiesForKeys: nil
      ).first { $0.lastPathComponent.hasPrefix("pending-") })
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -2)],
      ofItemAtPath: pending.path
    )

    try mailbox.performMaintenance()
    #expect(try mailbox.claimPending().isEmpty)
  }

  @Test("An abandoned claim is recovered after its timeout")
  func abandonedClaimRecovery() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox(limits: .init(claimTimeout: 1))
    try mailbox.enqueue(Message(value: "recover me"))
    let claim = try #require(try mailbox.claimPending(limit: 1).first)
    let claimed = try #require(
      try FileManager.default.contentsOfDirectory(
        at: fixture.mailboxDirectory,
        includingPropertiesForKeys: nil
      ).first { $0.lastPathComponent.hasPrefix("claimed-") })
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -2)],
      ofItemAtPath: claimed.path
    )

    #expect(try mailbox.claimPending(limit: 1).first?.message.value == "recover me")
    #expect(throws: AppGroupMailbox<Message>.MailboxError.claimNoLongerExists) {
      try claim.acknowledge()
    }
  }

  @Test("Concurrent consumers claim each message once")
  func concurrentConsumers() async throws {
    let fixture = try Fixture()
    let first = try fixture.mailbox()
    let second = try fixture.mailbox()
    for value in 0..<40 { try first.enqueue(Message(value: String(value))) }

    let claimed = try await withThrowingTaskGroup(of: [String].self) { group in
      for mailbox in [first, second] {
        group.addTask {
          let claims = try mailbox.claimPending()
          for claim in claims { try claim.acknowledge() }
          return claims.map(\.message.value)
        }
      }
      return try await group.reduce(into: []) { $0 += $1 }
    }
    #expect(claimed.count == 40)
    #expect(Set(claimed).count == 40)
  }

  @Test("Concurrent producers do not overwrite messages")
  func concurrentProducers() async throws {
    let fixture = try Fixture()
    let mailboxes = try (0..<4).map { _ in
      try fixture.mailbox(limits: .init(maxMessages: 100))
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for (producer, mailbox) in mailboxes.enumerated() {
        group.addTask {
          for value in 0..<20 {
            try mailbox.enqueue(Message(value: "\(producer)-\(value)"))
          }
        }
      }
      try await group.waitForAll()
    }
    let claims = try mailboxes[0].claimPending()
    #expect(claims.count == 80)
    #expect(Set(claims.map(\.message.value)).count == 80)
  }

  @Test("Separate producer processes do not overwrite messages")
  func multiprocessProducers() throws {
    let fixture = try Fixture()
    let executable = try #require(mailboxTestWorkerURL)
    let workers = (0..<4).map { producer in
      let process = Process()
      process.executableURL = executable
      process.arguments = ["enqueue", fixture.root.path, String(producer * 20), "20"]
      return process
    }
    for worker in workers { try worker.run() }
    for worker in workers {
      worker.waitUntilExit()
      #expect(worker.terminationStatus == 0)
    }

    let mailbox = try AppGroupMailbox<Message>(
      containerURL: fixture.root,
      namespace: "multiprocess",
      limits: .init(maxMessages: 200)
    )
    let claims = try mailbox.claimPending()
    #expect(claims.count == 80)
    #expect(Set(claims.map(\.message.value)).count == 80)
  }

  @Test(
    "Namespaces cannot escape the mailbox root", arguments: ["", ".", "..", "../escape", "a/b"])
  func invalidNamespace(namespace: String) throws {
    let fixture = try Fixture()
    #expect(throws: AppGroupMailbox<Message>.MailboxError.invalidNamespace) {
      try AppGroupMailbox<Message>(containerURL: fixture.root, namespace: namespace)
    }
  }
}

private var mailboxTestWorkerURL: URL? {
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

private final class Fixture {
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
    overflowPolicy: AppGroupMailbox<AppGroupMailboxTests.Message>.OverflowPolicy = .rejectNewest
  ) throws -> AppGroupMailbox<AppGroupMailboxTests.Message> {
    try AppGroupMailbox(
      containerURL: root,
      namespace: "tests",
      limits: limits,
      overflowPolicy: overflowPolicy
    )
  }
}
