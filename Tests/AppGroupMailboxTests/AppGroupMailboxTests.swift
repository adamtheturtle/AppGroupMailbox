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

  @Test("New ordinals sort after active claimed messages")
  func claimedMessagesInfluenceOrdinalAllocation() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox()
    let olderID = try mailbox.enqueue(Message(value: "older"))
    _ = try #require(try mailbox.claimPending(limit: 1).first)
    let claimed = try #require(
      try FileManager.default.contentsOfDirectory(
        at: fixture.mailboxDirectory,
        includingPropertiesForKeys: nil
      ).first { $0.lastPathComponent.hasPrefix("claimed-") }
    )

    // Simulate a claim whose active ordinal is ahead of a wall clock that moved backwards.
    let futureOrdinal = "09000000000000000000"
    let originalName = "pending-\(futureOrdinal)-\(olderID.uuidString).json"
    let renamedClaim = fixture.mailboxDirectory.appendingPathComponent(
      "claimed-\(UUID().uuidString)-\(originalName)"
    )
    try FileManager.default.moveItem(at: claimed, to: renamedClaim)

    // A malformed claimed filename with the maximum ordinal must not force overflow.
    let malformed = fixture.mailboxDirectory.appendingPathComponent(
      "claimed-not-a-uuid-pending-18446744073709551615-\(UUID().uuidString).json"
    )
    try Data().write(to: malformed)

    try mailbox.enqueue(Message(value: "newer"))
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -700)],
      ofItemAtPath: renamedClaim.path
    )

    #expect(try mailbox.claimPending().map(\.message.value) == ["older", "newer"])
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

    try mailbox.enqueue(Message(value: "claimed retry"), id: id)
    #expect(try mailbox.claimPending().isEmpty)
    try claims.first?.acknowledge()
  }

  @Test("Imported messages retain chronology and deterministic tie ordering")
  func importedChronology() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox(limits: .init(maxMessages: 10))
    let now = Date()
    let duplicateID = UUID()

    try mailbox.enqueue(Message(value: "native"))
    try mailbox.enqueue(
      Message(value: "oldest"), id: UUID(), enqueuedAt: now.addingTimeInterval(-2))
    try mailbox.enqueue(
      Message(value: "tie first"), id: UUID(), enqueuedAt: now.addingTimeInterval(-1))
    try mailbox.enqueue(
      Message(value: "tie second"), id: UUID(), enqueuedAt: now.addingTimeInterval(-1))
    try mailbox.enqueue(
      Message(value: "newest"), id: duplicateID, enqueuedAt: now.addingTimeInterval(2))
    try mailbox.enqueue(
      Message(value: "duplicate"), id: duplicateID, enqueuedAt: now.addingTimeInterval(-3))
    try Data("not json".utf8).write(
      to: fixture.mailboxDirectory.appendingPathComponent(
        "pending-00000000000000000000-malformed.json"
      )
    )

    let oldest = try #require(try mailbox.claimPending(limit: 1).first)
    #expect(oldest.message.value == "oldest")
    try oldest.acknowledge()
    #expect(
      try mailbox.claimPending().map(\.message.value)
        == ["tie first", "tie second", "native", "newest"]
    )
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

  @Test("Malformed pending files are quarantined before overflow eviction")
  func malformedPendingDoesNotDisplaceValidMessage() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox(limits: .init(maxMessages: 2), overflowPolicy: .discardOldest)
    try mailbox.enqueue(Message(value: "one"))
    try Data("not json".utf8).write(
      to: fixture.mailboxDirectory.appendingPathComponent(
        "pending-00000000000000000001-malformed.json"
      )
    )

    try mailbox.enqueue(Message(value: "two"))

    #expect(try mailbox.claimPending().map(\.message.value) == ["one", "two"])
    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.mailboxDirectory.path)
    #expect(names.count(where: { $0.hasPrefix("quarantine-") }) == 1)
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

  @Test("The mailbox lock does not follow symbolic links")
  func lockSymlinkIsRejected() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox()
    let outside = fixture.root.appendingPathComponent("outside-lock")
    let original = Data("outside".utf8)
    try original.write(to: outside)
    try FileManager.default.createSymbolicLink(
      at: fixture.mailboxDirectory.appendingPathComponent(".mailbox.lock"),
      withDestinationURL: outside
    )

    #expect(throws: AppGroupMailbox<Message>.MailboxError.ioFailure) {
      try mailbox.enqueue(Message(value: "blocked"))
    }
    #expect(try Data(contentsOf: outside) == original)
  }

  @Test("Reading remains anchored to the validated open file")
  func fileReplacementDuringRead() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox()
    let source = fixture.mailboxDirectory.appendingPathComponent("source.json")
    let openedFile = fixture.root.appendingPathComponent("opened.json")
    let replacement = fixture.root.appendingPathComponent("replacement.json")
    let original = Data("original".utf8)
    try original.write(to: source)
    try Data("replacement".utf8).write(to: replacement)

    let data = try mailbox.safeData(at: source) {
      try FileManager.default.moveItem(at: source, to: openedFile)
      try FileManager.default.createSymbolicLink(at: source, withDestinationURL: replacement)
    }

    #expect(data == original)
  }

  @Test("Malformed claimed filenames are quarantined with bounded retention")
  func malformedClaimNamesAreQuarantined() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox(limits: .init(maxQuarantinedFiles: 2))
    for index in 0..<3 {
      try Data("{}".utf8).write(
        to: fixture.mailboxDirectory.appendingPathComponent(
          "claimed-\(UUID().uuidString)-malformed-\(index).json"
        )
      )
    }

    try mailbox.performMaintenance()

    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.mailboxDirectory.path)
    #expect(!names.contains { $0.hasPrefix("claimed-") })
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
    try setEnqueuedAt(Date(timeIntervalSinceNow: -2), in: pending)

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

  @Test("Releasing a claim does not extend its original lifetime")
  func releasedClaimKeepsOriginalLifetime() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox(limits: .init(messageLifetime: 1))
    try mailbox.enqueue(Message(value: "expire me"))
    let claim = try #require(try mailbox.claimPending(limit: 1).first)
    let claimedURL = try #require(try fixture.claimedURL())
    try setEnqueuedAt(Date(timeIntervalSinceNow: -2), in: claimedURL)

    try claim.release()
    try mailbox.performMaintenance()

    #expect(try mailbox.claimPending().isEmpty)
  }

  @Test("An active claim remains valid after the message lifetime")
  func activeClaimCanOutliveMessageLifetime() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox(limits: .init(messageLifetime: 1))
    try mailbox.enqueue(Message(value: "still processing"))
    let claim = try #require(try mailbox.claimPending(limit: 1).first)
    let claimedURL = try #require(try fixture.claimedURL())
    try setEnqueuedAt(Date(timeIntervalSinceNow: -2), in: claimedURL)

    try mailbox.performMaintenance()

    try claim.acknowledge()
    #expect(try mailbox.claimPending().isEmpty)
  }

  @Test("Expired abandoned claims are discarded instead of recovered")
  func expiredAbandonedClaimIsDiscarded() throws {
    let fixture = try Fixture()
    let diagnostics = DiagnosticRecorder()
    let mailbox = try fixture.mailbox(
      limits: .init(messageLifetime: 1, claimTimeout: 1),
      diagnostic: diagnostics.record
    )
    try mailbox.enqueue(Message(value: "expire me"))
    _ = try #require(try mailbox.claimPending(limit: 1).first)
    let claimedURL = try #require(try fixture.claimedURL())
    try setEnqueuedAt(Date(timeIntervalSinceNow: -2), in: claimedURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -2)],
      ofItemAtPath: claimedURL.path
    )

    try mailbox.performMaintenance()

    #expect(try mailbox.claimPending().isEmpty)
    #expect(diagnostics.values == [.expiredMessageRemoved])
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
      // Shared namespace: workers must write into the same mailbox. Unique Fixture
      // roots already isolate runs (see #68); a UUID default per process would
      // make claims.count == 0.
      process.arguments = [
        "enqueue", fixture.root.path, String(producer * 20), "20", "multiprocess", "MultiprocessTestMessage",
      ]
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
      limits: .init(maxMessages: 200),
      messageType: "MultiprocessTestMessage"
    )
    let claims = try mailbox.claimPending()
    #expect(claims.count == 80)
    #expect(Set(claims.map(\.message.value)).count == 80)
  }

  @Test("Idempotent enqueue skips when a same-ID file is malformed")
  func idempotentEnqueueWithMalformedSameID() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox()
    let id = UUID()
    try Data("not json".utf8).write(
      to: fixture.mailboxDirectory.appendingPathComponent(
        "pending-00000000000000000001-\(id.uuidString).json"
      )
    )

    try mailbox.enqueue(Message(value: "retry"), id: id)

    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.mailboxDirectory.path)
    #expect(names.count(where: { $0.contains(id.uuidString) }) == 1)
  }

  @Test("Idempotent enqueue skips after a same-ID message is quarantined")
  func idempotentEnqueueAfterQuarantine() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox()
    let id = UUID()
    try Data("not json".utf8).write(
      to: fixture.mailboxDirectory.appendingPathComponent(
        "pending-00000000000000000001-\(id.uuidString).json"
      )
    )
    #expect(try mailbox.claimPending().isEmpty)
    let quarantined = try FileManager.default.contentsOfDirectory(
      atPath: fixture.mailboxDirectory.path
    )
    #expect(quarantined.contains { $0.hasPrefix("quarantine-") && $0.contains(id.uuidString) })

    try mailbox.enqueue(Message(value: "retry"), id: id)
    #expect(try mailbox.claimPending().isEmpty)
  }

  @Test("Non-json pending files do not consume capacity")
  func extensionlessPendingDoesNotConsumeCapacity() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox(limits: .init(maxMessages: 1))
    try Data("ghost".utf8).write(
      to: fixture.mailboxDirectory.appendingPathComponent("pending-00000000000000000001-ghost")
    )
    try Data("ghost".utf8).write(
      to: fixture.mailboxDirectory.appendingPathComponent(
        "pending-00000000000000000002-\(UUID().uuidString).JSON"
      )
    )

    try mailbox.enqueue(Message(value: "real"))
    #expect(try mailbox.claimPending().map(\.message.value) == ["real"])
  }

  @Test("claimPending rejects a zero limit")
  func claimPendingRejectsZeroLimit() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox()
    try mailbox.enqueue(Message(value: "one"))

    #expect(throws: AppGroupMailbox<Message>.MailboxError.invalidLimit("claim limit")) {
      try mailbox.claimPending(limit: 0)
    }
    #expect(try mailbox.claimPending(limit: 1).map(\.message.value) == ["one"])
  }

  @Test("Extreme maxPayloadBytes values are rejected")
  func extremePayloadLimitRejected() throws {
    let fixture = try Fixture()
    #expect(throws: AppGroupMailbox<Message>.MailboxError.invalidLimit("maxPayloadBytes")) {
      try fixture.mailbox(limits: .init(maxPayloadBytes: Int.max))
    }
    #expect(throws: AppGroupMailbox<Message>.MailboxError.invalidLimit("maxPayloadBytes")) {
      try fixture.mailbox(limits: .init(maxPayloadBytes: 64 * 1024 * 1024 + 1))
    }
  }

  @Test("MailboxError provides localized descriptions and is Hashable")
  func mailboxErrorProtocols() {
    let errors: Set<AppGroupMailbox<Message>.MailboxError> = [
      .invalidNamespace,
      .mailboxFull,
      .ioFailure,
      .payloadTooLarge(actualBytes: 10, maximumBytes: 5),
    ]
    #expect(errors.count == 4)
    #expect(AppGroupMailbox<Message>.MailboxError.mailboxFull.errorDescription != nil)
    #expect(
      AppGroupMailbox<Message>.MailboxError.invalidLimit("maxMessages").errorDescription?
        .contains("maxMessages") == true
    )
  }

  @Test("Ordinal parsing accepts 20 or 21 digits")
  func ordinalWidthAccepted() {
    let id = UUID()
    #expect(
      AppGroupMailbox<Message>.ordinal(from: "pending-00000000000000000001-\(id.uuidString).json")
        == 1
    )
    #expect(AppGroupMailbox<Message>.ordinal(from: "pending-1-\(id.uuidString).json") == nil)
    #expect(
      AppGroupMailbox<Message>.ordinal(from: "pending-000000000000000000001-\(id.uuidString).json")
        == 1
    )
    #expect(
      AppGroupMailbox<Message>.ordinal(from: "pending-0000000000000000000001-\(id.uuidString).json")
        == nil
    )
  }

  @Test("Hard-linked pending files count once toward capacity")
  func hardLinkedPendingCountsOnce() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox(limits: .init(maxMessages: 1))
    let id = try mailbox.enqueue(Message(value: "only"))
    let pending = try #require(
      try FileManager.default.contentsOfDirectory(
        at: fixture.mailboxDirectory,
        includingPropertiesForKeys: nil
      ).first { $0.lastPathComponent.hasPrefix("pending-") }
    )
    let link = fixture.mailboxDirectory.appendingPathComponent(
      "pending-00000000000000000099-\(UUID().uuidString).json"
    )
    try FileManager.default.linkItem(at: pending, to: link)

    #expect(throws: AppGroupMailbox<Message>.MailboxError.mailboxFull) {
      try mailbox.enqueue(Message(value: "extra"))
    }
    _ = id
  }

  @Test("Rejecting a full mailbox reports unclaimable capacity files")
  func rejectNewestReportsGhostFiles() throws {
    let fixture = try Fixture()
    let diagnostics = DiagnosticRecorder()
    let mailbox = try fixture.mailbox(
      limits: .init(maxMessages: 1),
      diagnostic: diagnostics.record
    )
    try mailbox.enqueue(Message(value: "real"))
    try Data("ghost".utf8).write(
      to: fixture.mailboxDirectory.appendingPathComponent(
        "pending-00000000000000000099-ghost"
      )
    )

    #expect(throws: AppGroupMailbox<Message>.MailboxError.mailboxFull) {
      try mailbox.enqueue(Message(value: "blocked"))
    }
    #expect(diagnostics.values.contains(.unclaimableFilesPresent))
  }

  @Test("Diagnostics are delivered after releasing the mailbox lock")
  func diagnosticReentrancy() throws {
    let fixture = try Fixture()
    final class MaintenanceTrigger: @unchecked Sendable {
      var mailbox: AppGroupMailbox<Message>?
    }
    let trigger = MaintenanceTrigger()
    trigger.mailbox = try fixture.mailbox(
      limits: .init(maxMessages: 2),
      overflowPolicy: .discardOldest,
      diagnostic: { _ in
        try? trigger.mailbox?.performMaintenance()
      }
    )
    try trigger.mailbox?.enqueue(Message(value: "first"))
    try trigger.mailbox?.enqueue(Message(value: "second"))
    try trigger.mailbox?.enqueue(Message(value: "third"))
  }

  @Test("Renewing a claim extends its abandoned-claim timeout")
  func claimRenew() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox(limits: .init(claimTimeout: 1))
    try mailbox.enqueue(Message(value: "renew me"))
    let claim = try #require(try mailbox.claimPending(limit: 1).first)
    let claimedURL = try #require(try fixture.claimedURL())
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -2)],
      ofItemAtPath: claimedURL.path
    )

    try claim.renew()

    try mailbox.performMaintenance()
    #expect(try mailbox.claimPending().isEmpty)
    try claim.acknowledge()
  }

  @Test("Malformed pending files are quarantined during maintenance")
  func malformedPendingQuarantinedDuringMaintenance() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox()
    let id = UUID()
    try Data("not json".utf8).write(
      to: fixture.mailboxDirectory.appendingPathComponent(
        "pending-00000000000000000001-\(id.uuidString).json"
      )
    )

    try mailbox.performMaintenance()

    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.mailboxDirectory.path)
    #expect(!names.contains { $0.contains(id.uuidString) && $0.hasPrefix("pending-") })
    #expect(names.contains { $0.hasPrefix("quarantine-") && $0.contains(id.uuidString) })
  }


  @Test("Different message types cannot share a namespace")
  func messageTypeGuard() throws {
    struct OtherMessage: Codable, Sendable { let value: String }
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox()
    try mailbox.enqueue(Message(value: "typed"))

    let other = try AppGroupMailbox<OtherMessage>(
      containerURL: fixture.root,
      namespace: "tests"
    )
    #expect(try other.claimPending().isEmpty)
    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.mailboxDirectory.path)
    #expect(names.contains { $0.hasPrefix("quarantine-") })
  }


  @Test("Ordinals use 21 digits once millisecond timestamps exceed 20 digits")
  func wideOrdinals() {
    let id = UUID()
    let name = AppGroupMailbox<Message>.pendingFileName(
      ordinal: 10_000_000_000_000_000_000, id: id)
    #expect(name.hasPrefix("pending-"))
    #expect(AppGroupMailbox<Message>.ordinal(from: name) == 10_000_000_000_000_000_000)
    #expect(
      AppGroupMailbox<Message>.ordinal(from: "pending-00000000000000000001-\(id.uuidString).json")
        == 1
    )
  }

  @Test("Pending files with undecodable messages are quarantined before overflow eviction")
  func undecodableMessageQuarantinedBeforeOverflow() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox(limits: .init(maxMessages: 2), overflowPolicy: .discardOldest)
    try mailbox.enqueue(Message(value: "keep"))
    let corruptID = UUID()
    // Valid enqueuedAt / envelope shape but message is the wrong JSON type.
    let payload: [String: Any] = [
      "schemaVersion": 1,
      "messageType": String(reflecting: Message.self),
      "id": corruptID.uuidString,
      "enqueuedAt": Date().timeIntervalSince1970,
      "message": ["value": 123],
    ]
    try JSONSerialization.data(withJSONObject: payload).write(
      to: fixture.mailboxDirectory.appendingPathComponent(
        AppGroupMailbox<Message>.pendingFileName(ordinal: 1, id: corruptID)
      )
    )

    try mailbox.enqueue(Message(value: "new"))

    #expect(try mailbox.claimPending().map(\.message.value) == ["keep", "new"])
    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.mailboxDirectory.path)
    #expect(names.contains { $0.hasPrefix("quarantine-") && $0.contains(corruptID.uuidString) })
  }

  @Test("In-flight claims do not report unclaimableFilesPresent on mailboxFull")
  func claimedCapacityDoesNotReportUnclaimable() throws {
    let fixture = try Fixture()
    let diagnostics = DiagnosticRecorder()
    let mailbox = try fixture.mailbox(
      limits: .init(maxMessages: 1),
      diagnostic: diagnostics.record
    )
    try mailbox.enqueue(Message(value: "only"))
    _ = try #require(try mailbox.claimPending(limit: 1).first)

    #expect(throws: AppGroupMailbox<Message>.MailboxError.mailboxFull) {
      try mailbox.enqueue(Message(value: "extra"))
    }
    #expect(!diagnostics.values.contains(.unclaimableFilesPresent))
  }
  @Test("Legacy reference-date envelopes are not treated as already expired")
  func legacyReferenceDateEnvelopesSurviveUpgrade() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox(limits: .init(messageLifetime: 60))
    let id = UUID()
    let enqueuedAt = Date()
    let payload: [String: Any] = [
      "schemaVersion": 1,
      "messageType": String(reflecting: Message.self),
      "id": id.uuidString,
      "enqueuedAt": enqueuedAt.timeIntervalSinceReferenceDate,
      "message": ["value": "legacy"],
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)
    try data.write(
      to: fixture.mailboxDirectory.appendingPathComponent(
        AppGroupMailbox<Message>.pendingFileName(ordinal: 1, id: id)
      )
    )

    try mailbox.performMaintenance()
    #expect(try mailbox.claimPending().map(\.message.value) == ["legacy"])
  }

  @Test("Legacy reference-date envelopes are readable when claiming")
  func legacyReferenceDateEnvelopesSurviveClaim() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox()
    let id = UUID()
    let payload: [String: Any] = [
      "schemaVersion": 1,
      "messageType": String(reflecting: Message.self),
      "id": id.uuidString,
      "enqueuedAt": Date().timeIntervalSinceReferenceDate,
      "message": ["value": "legacy-claim"],
    ]
    try JSONSerialization.data(withJSONObject: payload).write(
      to: fixture.mailboxDirectory.appendingPathComponent(
        AppGroupMailbox<Message>.pendingFileName(ordinal: 1, id: id)
      )
    )

    #expect(try mailbox.claimPending().map(\.message.value) == ["legacy-claim"])
  }

  @Test("Claim operations after mailbox deallocation throw mailboxDeallocated")
  func claimAfterMailboxDeallocation() throws {
    let fixture = try Fixture()
    let claim: AppGroupMailbox<Message>.Claim
    do {
      let mailbox = try fixture.mailbox()
      try mailbox.enqueue(Message(value: "orphan claim"))
      claim = try #require(try mailbox.claimPending(limit: 1).first)
    }
    #expect(throws: AppGroupMailbox<Message>.MailboxError.mailboxDeallocated) {
      try claim.acknowledge()
    }
    #expect(throws: AppGroupMailbox<Message>.MailboxError.mailboxDeallocated) {
      try claim.release()
    }
    #expect(throws: AppGroupMailbox<Message>.MailboxError.mailboxDeallocated) {
      try claim.renew()
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.mailboxDirectory.path)
    #expect(names.contains { $0.hasPrefix("claimed-") })
  }

  @Test(
    "Namespaces cannot escape the mailbox root",
    arguments: ["", ".", "..", "...", "....", "../escape", "a/b"])
  func invalidNamespace(namespace: String) throws {
    let fixture = try Fixture()
    #expect(throws: AppGroupMailbox<Message>.MailboxError.invalidNamespace) {
      try AppGroupMailbox<Message>(containerURL: fixture.root, namespace: namespace)
    }
  }

  @Test("Custom message decoding failures are quarantined instead of restored")
  func customDecodingFailureIsQuarantined() throws {
    struct StrictMessage: Codable, Sendable {
      let value: String
      init(value: String) { self.value = value }
      init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(String.self, forKey: .value)
        if value == "bad" { throw NSError(domain: "StrictMessage", code: 1) }
        self.value = value
      }
      enum CodingKeys: String, CodingKey { case value }
    }

    let fixture = try Fixture()
    let writer = try AppGroupMailbox<Message>(
      containerURL: fixture.root,
      namespace: "tests"
    )
    try writer.enqueue(Message(value: "bad"))

    let reader = try AppGroupMailbox<StrictMessage>(
      containerURL: fixture.root,
      namespace: "tests",
      messageType: String(reflecting: Message.self)
    )
    #expect(try reader.claimPending().isEmpty)
    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.mailboxDirectory.path)
    #expect(names.contains { $0.hasPrefix("quarantine-") })
    #expect(!names.contains { $0.hasPrefix("pending-") })
  }


  @Test("Abandoned claim recovery keeps the claim when a conflicting pending file exists")
  func abandonedClaimRecoveryPrefersClaimOverConflict() throws {
    let fixture = try Fixture()
    let diagnostics = DiagnosticRecorder()
    let mailbox = try fixture.mailbox(
      limits: .init(messageLifetime: 24 * 60 * 60, claimTimeout: 1),
      diagnostic: diagnostics.record
    )
    try mailbox.enqueue(Message(value: "claimed-good"))
    _ = try #require(try mailbox.claimPending(limit: 1).first)
    let claimedURL = try #require(try fixture.claimedURL())
    let originalName = try #require(
      AppGroupMailbox<Message>.originalName(fromClaimName: claimedURL.lastPathComponent)
    )
    let conflictPayload: [String: Any] = [
      "schemaVersion": 1,
      "messageType": String(reflecting: Message.self),
      "id": UUID().uuidString,
      "enqueuedAt": Date().timeIntervalSince1970,
      "message": ["value": "conflict"],
    ]
    try JSONSerialization.data(withJSONObject: conflictPayload).write(
      to: fixture.mailboxDirectory.appendingPathComponent(originalName)
    )
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -2)],
      ofItemAtPath: claimedURL.path
    )

    try mailbox.performMaintenance()

    #expect(try mailbox.claimPending().map(\.message.value) == ["claimed-good"])
    #expect(diagnostics.values.contains(.abandonedClaimRecovered))
    #expect(diagnostics.values.contains(.unsafeFileQuarantined))
  }


  @Test("Disabled quarantine retention reports discard only after successful removal")
  func zeroQuarantineRetentionEmitsDiscarded() throws {
    let fixture = try Fixture()
    let diagnostics = DiagnosticRecorder()
    let mailbox = try fixture.mailbox(
      limits: .init(maxQuarantinedFiles: 0),
      diagnostic: diagnostics.record
    )
    try Data("not json".utf8).write(
      to: fixture.mailboxDirectory.appendingPathComponent(
        "pending-00000000000000000001-\(UUID().uuidString).json"
      )
    )

    try mailbox.performMaintenance()

    #expect(diagnostics.values == [.quarantinedFileDiscarded])
    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.mailboxDirectory.path)
    #expect(!names.contains { $0.hasPrefix("pending-") || $0.hasPrefix("quarantine-") })
  }

  @Test("Message payload dates before 2001 round-trip as Unix seconds")
  func messageDatesBeforeReferenceDateAreNotRemapped() throws {
    struct DatedMessage: Codable, Sendable, Equatable {
      let value: String
      let createdAt: Date
    }

    let fixture = try Fixture()
    let mailbox = try AppGroupMailbox<DatedMessage>(
      containerURL: fixture.root,
      namespace: "tests"
    )
    let createdAt = Date(timeIntervalSince1970: 946_684_800 - 60)  // 1999-12-31T23:59:00Z
    let id = try mailbox.enqueue(DatedMessage(value: "historical", createdAt: createdAt))

    let claim = try #require(try mailbox.claimPending(limit: 1).first)
    #expect(claim.id == id)
    #expect(claim.message == DatedMessage(value: "historical", createdAt: createdAt))
    try claim.acknowledge()
  }

  @Test("Failed discard under disabled quarantine retention emits no diagnostic")
  func zeroQuarantineRetentionSkipsFailedRemoval() throws {
    let fixture = try Fixture()
    let diagnostics = DiagnosticRecorder()
    let mailbox = try fixture.mailbox(
      limits: .init(maxQuarantinedFiles: 0),
      diagnostic: diagnostics.record
    )
    let unreadable = fixture.mailboxDirectory.appendingPathComponent(
      "pending-00000000000000000001-\(UUID().uuidString).json"
    )
    try Data("not json".utf8).write(to: unreadable)
    #if canImport(Darwin)
      try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: unreadable.path)
    #else
      try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
    #endif

    try mailbox.performMaintenance()

    #expect(diagnostics.values.isEmpty)
    #expect(FileManager.default.fileExists(atPath: unreadable.path))
    #if canImport(Darwin)
      try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: unreadable.path)
    #else
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path)
    #endif
  }

}

#if false
// debug helper - remove before commit
#endif
