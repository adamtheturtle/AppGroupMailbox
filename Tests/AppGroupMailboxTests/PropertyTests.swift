import Foundation
import Testing

@testable import AppGroupMailbox

@Suite("Property-based invariants")
struct PropertyTests {
  @Test("Repeated enqueue with the same ID is idempotent", arguments: 0..<25)
  func idempotentEnqueue(seed: Int) throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox(limits: .init(maxMessages: 1))
    let id = UUID()

    for attempt in 0..<10 {
      try mailbox.enqueue(
        AppGroupMailboxTests.Message(value: "first-\(seed)-\(attempt)"), id: id)
      try mailbox.enqueue(
        AppGroupMailboxTests.Message(value: "retry-\(seed)-\(attempt)"), id: id)
    }

    let claims = try mailbox.claimPending()
    #expect(claims.count == 1)
    #expect(claims.first?.id == id)
    #expect(claims.first?.message.value == "first-\(seed)-0")
    try claims.first?.acknowledge()
  }

  @Test("Pending depth never exceeds maxMessages", arguments: 0..<25)
  func capacityInvariant(seed: Int) throws {
    var generator = SeededGenerator(seed: UInt64(truncatingIfNeeded: seed))
    let fixture = try Fixture()
    let maxMessages = Int.random(in: 1...6, using: &generator)
    let mailbox = try fixture.mailbox(limits: .init(maxMessages: maxMessages))

    for index in 0..<maxMessages {
      try mailbox.enqueue(AppGroupMailboxTests.Message(value: "\(seed)-\(index)"))
      let names = try FileManager.default.contentsOfDirectory(atPath: fixture.mailboxDirectory.path)
      let pendingCount = names.count {
        $0.hasPrefix("pending-") && $0.hasSuffix(".json")
      }
      #expect(pendingCount <= maxMessages)
    }

    #expect(throws: AppGroupMailbox<AppGroupMailboxTests.Message>.MailboxError.mailboxFull) {
      try mailbox.enqueue(AppGroupMailboxTests.Message(value: "overflow"))
    }
  }

  @Test("Hard-linked duplicates never exceed maxMessages capacity")
  func hardLinkCapacityInvariant() throws {
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox(limits: .init(maxMessages: 2))
    let first = try mailbox.enqueue(AppGroupMailboxTests.Message(value: "one"))
    _ = try mailbox.enqueue(AppGroupMailboxTests.Message(value: "two"))
    let pending = try #require(
      try FileManager.default.contentsOfDirectory(
        at: fixture.mailboxDirectory,
        includingPropertiesForKeys: nil
      ).first { $0.lastPathComponent.hasPrefix("pending-") && $0.lastPathComponent.contains(first.uuidString) }
    )
    let link = fixture.mailboxDirectory.appendingPathComponent(
      "pending-00000000000000000099-\(UUID().uuidString).json"
    )
    try FileManager.default.linkItem(at: pending, to: link)

    #expect(throws: AppGroupMailbox<AppGroupMailboxTests.Message>.MailboxError.mailboxFull) {
      try mailbox.enqueue(AppGroupMailboxTests.Message(value: "three"))
    }
  }
}

private struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed == 0 ? 0xDEAD_BEEF : seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
