#if canImport(Darwin)
  import Foundation
  import Testing

  @testable import AppGroupMailbox

  @Suite("Darwin notifications")
  struct NotificationTests {
    @Test("Idempotent duplicate enqueue does not notify")
    func idempotentEnqueueDoesNotNotify() async throws {
      let fixture = try Fixture()
      let recorder = DarwinNotificationRecorder()
      let mailbox = try fixture.mailbox(notificationName: recorder.name)
      let id = UUID()
      try mailbox.enqueue(.init(value: "original"), id: id)
      #expect(await recorder.receivedNotification(after: 0))
      let baseline = recorder.count

      try mailbox.enqueue(.init(value: "retry"), id: id)

      try? await Task.sleep(for: .milliseconds(50))
      #expect(recorder.count == baseline)
      #expect(try mailbox.claimPending().count == 1)
    }

    @Test("Idempotent enqueue while claimed does not notify")
    func idempotentEnqueueWhileClaimedDoesNotNotify() async throws {
      let fixture = try Fixture()
      let recorder = DarwinNotificationRecorder()
      let mailbox = try fixture.mailbox(notificationName: recorder.name)
      let id = UUID()
      try mailbox.enqueue(.init(value: "original"), id: id)
      #expect(await recorder.receivedNotification(after: 0))
      _ = try #require(try mailbox.claimPending(limit: 1).first)
      let baseline = recorder.count

      try mailbox.enqueue(.init(value: "retry"), id: id)

      try? await Task.sleep(for: .milliseconds(50))
      #expect(recorder.count == baseline)
    }

    @Test("Releasing a claim notifies after making it pending")
    func releaseNotification() async throws {
      let fixture = try Fixture()
      let recorder = DarwinNotificationRecorder()
      let mailbox = try fixture.mailbox(notificationName: recorder.name)
      try mailbox.enqueue(.init(value: "release"))
      let claim = try #require(try mailbox.claimPending(limit: 1).first)
      let baseline = recorder.count

      try claim.release()

      #expect(await recorder.receivedNotification(after: baseline))
      #expect(try mailbox.claimPending(limit: 1).first?.message.value == "release")
    }

    @Test("Recovering an abandoned claim notifies after making it pending")
    func recoveryNotification() async throws {
      let fixture = try Fixture()
      let recorder = DarwinNotificationRecorder()
      let mailbox = try fixture.mailbox(
        limits: .init(claimTimeout: 1),
        notificationName: recorder.name
      )
      try mailbox.enqueue(.init(value: "recover"))
      _ = try #require(try mailbox.claimPending(limit: 1).first)
      let claimed = try #require(
        try FileManager.default.contentsOfDirectory(
          at: fixture.mailboxDirectory,
          includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix("claimed-") }
      )
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -2)],
        ofItemAtPath: claimed.path
      )
      let baseline = recorder.count

      try mailbox.performMaintenance()

      #expect(await recorder.receivedNotification(after: baseline))
      #expect(try mailbox.claimPending(limit: 1).first?.message.value == "recover")
    }

    @Test("Recovery still notifies when later maintenance fails")
    func recoveryNotificationAfterFailure() async throws {
      let fixture = try Fixture()
      let recorder = DarwinNotificationRecorder()
      let directory = fixture.mailboxDirectory
      let mailbox = try fixture.mailbox(
        limits: .init(claimTimeout: 1),
        notificationName: recorder.name
      )
      try mailbox.enqueue(.init(value: "recover"))
      _ = try #require(try mailbox.claimPending(limit: 1).first)
      let claimed = try #require(try fixture.claimedURL())
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -2)],
        ofItemAtPath: claimed.path
      )
      let baseline = recorder.count

      try mailbox.performMaintenance()
      try FileManager.default.setAttributes(
        [.posixPermissions: 0],
        ofItemAtPath: directory.path
      )
      #expect(throws: AppGroupMailbox<AppGroupMailboxTests.Message>.MailboxError.ioFailure) {
        try mailbox.performMaintenance()
      }
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directory.path
      )

      #expect(await recorder.receivedNotification(after: baseline))
    }
  }

  private final class DarwinNotificationRecorder: @unchecked Sendable {
    let name = "AppGroupMailboxTests.\(UUID().uuidString)"

    private let lock = NSLock()
    private var notificationCount = 0

    init() {
      CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        Unmanaged.passUnretained(self).toOpaque(),
        { _, observer, _, _, _ in
          guard let observer else { return }
          let recorder = Unmanaged<DarwinNotificationRecorder>
            .fromOpaque(observer)
            .takeUnretainedValue()
          recorder.record()
        },
        name as CFString,
        nil,
        .deliverImmediately
      )
    }

    deinit {
      CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        Unmanaged.passUnretained(self).toOpaque(),
        CFNotificationName(name as CFString),
        nil
      )
    }

    var count: Int {
      lock.withLock { notificationCount }
    }

    func receivedNotification(after baseline: Int) async -> Bool {
      for _ in 0..<100 {
        if count > baseline { return true }
        try? await Task.sleep(for: .milliseconds(10))
      }
      return false
    }

    private func record() {
      lock.withLock { notificationCount += 1 }
    }
  }
#endif
