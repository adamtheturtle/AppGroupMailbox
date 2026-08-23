import Foundation
import Testing

@testable import AppGroupMailbox

@Suite("Property-based invariants")
struct PropertyTests {
  @Test("Repeated enqueue with the same ID is idempotent", arguments: 0..<25)
  func idempotentEnqueue(seed: Int) throws {
    var generator = SeededGenerator(seed: UInt64(truncatingIfNeeded: seed))
    let fixture = try Fixture()
    let mailbox = try fixture.mailbox(limits: .init(maxMessages: 10))
    var ids: [UUID] = []

    for _ in 0..<15 {
      let id = UUID()
      ids.append(id)
      try mailbox.enqueue(AppGroupMailboxTests.Message(value: "first-\(seed)"), id: id)
      try mailbox.enqueue(AppGroupMailboxTests.Message(value: "retry-\(seed)"), id: id)
    }

    let claims = try mailbox.claimPending()
    #expect(claims.count == ids.count)
    #expect(Set(claims.map(\.id)) == Set(ids))
    for claim in claims {
      #expect(claim.message.value == "first-\(seed)")
      try claim.acknowledge()
    }
  }

  @Test("Pending depth never exceeds maxMessages", arguments: 0..<25)
  func capacityInvariant(seed: Int) throws {
    var generator = SeededGenerator(seed: UInt64(truncatingIfNeeded: seed))
    let fixture = try Fixture()
    let maxMessages = Int.random(in: 1...6, using: &generator)
    let mailbox = try fixture.mailbox(limits: .init(maxMessages: maxMessages))

    var inserted = 0
    while inserted < maxMessages {
      try mailbox.enqueue(AppGroupMailboxTests.Message(value: "\(seed)-\(inserted)"))
      inserted += 1
      #expect(try mailbox.claimPending().count <= maxMessages)
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
