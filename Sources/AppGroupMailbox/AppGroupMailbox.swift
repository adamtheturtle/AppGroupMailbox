import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// A bounded, file-backed mailbox for moving values between processes that share a container.
public final class AppGroupMailbox<Message: Codable & Sendable>: @unchecked Sendable {
  /// Resource limits and retention policy for a mailbox.
  public struct Limits: Sendable, Equatable {
    public var maxMessages: Int
    public var maxPayloadBytes: Int
    public var messageLifetime: TimeInterval
    public var claimTimeout: TimeInterval
    public var maxQuarantinedFiles: Int

    public init(
      maxMessages: Int = 100,
      maxPayloadBytes: Int = 65_536,
      messageLifetime: TimeInterval = 24 * 60 * 60,
      claimTimeout: TimeInterval = 10 * 60,
      maxQuarantinedFiles: Int = 20
    ) {
      self.maxMessages = maxMessages
      self.maxPayloadBytes = maxPayloadBytes
      self.messageLifetime = messageLifetime
      self.claimTimeout = claimTimeout
      self.maxQuarantinedFiles = maxQuarantinedFiles
    }

    fileprivate func validate() throws {
      guard maxMessages > 0 else { throw MailboxError.invalidLimit("maxMessages") }
      guard maxPayloadBytes > 0 else { throw MailboxError.invalidLimit("maxPayloadBytes") }
      guard messageLifetime > 0 else { throw MailboxError.invalidLimit("messageLifetime") }
      guard claimTimeout > 0 else { throw MailboxError.invalidLimit("claimTimeout") }
      guard maxQuarantinedFiles >= 0 else { throw MailboxError.invalidLimit("maxQuarantinedFiles") }
    }
  }

  /// What to do when enqueueing into a full mailbox.
  public enum OverflowPolicy: Sendable {
    case rejectNewest
    case discardOldest
  }

  /// Non-sensitive events suitable for application logging.
  public enum Diagnostic: Sendable, Equatable {
    case expiredMessageRemoved
    case abandonedClaimRecovered
    case unsafeFileQuarantined
    case malformedMessageQuarantined
    case oldestMessageDiscarded
  }

  /// Failures produced by mailbox operations. No case contains message contents.
  public enum MailboxError: Error, Sendable, Equatable {
    case invalidNamespace
    case invalidLimit(String)
    case containerUnavailable
    case mailboxFull
    case payloadTooLarge(actualBytes: Int, maximumBytes: Int)
    case unsafeFile
    case claimNoLongerExists
    case ordinalExhausted
    case ioFailure
    case encodingFailure
    case decodingFailure
  }

  /// An atomically claimed message. A claim remains on disk until acknowledged or released.
  public final class Claim: @unchecked Sendable {
    public let id: UUID
    public let message: Message
    public let enqueuedAt: Date

    private let mailbox: AppGroupMailbox
    private let claimedURL: URL
    private let originalName: String

    fileprivate init(
      id: UUID,
      message: Message,
      enqueuedAt: Date,
      mailbox: AppGroupMailbox,
      claimedURL: URL,
      originalName: String
    ) {
      self.id = id
      self.message = message
      self.enqueuedAt = enqueuedAt
      self.mailbox = mailbox
      self.claimedURL = claimedURL
      self.originalName = originalName
    }

    /// Permanently removes the claimed message.
    public func acknowledge() throws {
      try mailbox.finishClaim(at: claimedURL, originalName: originalName, acknowledge: true)
    }

    /// Returns the message to the pending queue at its original position.
    public func release() throws {
      try mailbox.finishClaim(at: claimedURL, originalName: originalName, acknowledge: false)
    }
  }

  struct Envelope: Codable, Sendable {
    let id: UUID
    let enqueuedAt: Date
    let message: Message
  }

  struct Entry {
    let url: URL
    let originalName: String
    let enqueuedAt: Date?
  }

  let directory: URL
  let limits: Limits
  private let overflowPolicy: OverflowPolicy
  let notificationName: String?
  private let diagnostic: (@Sendable (Diagnostic) -> Void)?
  private let fileManager: FileManager
  private let encoder = JSONEncoder()
  let decoder = JSONDecoder()

  /// Creates a mailbox inside `containerURL/AppGroupMailbox/<namespace>`.
  public init(
    containerURL: URL,
    namespace: String,
    limits: Limits = .init(),
    overflowPolicy: OverflowPolicy = .rejectNewest,
    notificationName: String? = nil,
    diagnostic: (@Sendable (Diagnostic) -> Void)? = nil
  ) throws {
    guard Self.isValidNamespace(namespace) else { throw MailboxError.invalidNamespace }
    try limits.validate()

    let fileManager = FileManager.default
    let root =
      containerURL
      .appendingPathComponent("AppGroupMailbox", isDirectory: true)
      .appendingPathComponent(namespace, isDirectory: true)
    do {
      try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
      let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw MailboxError.containerUnavailable
      }
    } catch let error as MailboxError {
      throw error
    } catch {
      throw MailboxError.containerUnavailable
    }

    self.directory = root
    self.limits = limits
    self.overflowPolicy = overflowPolicy
    self.notificationName = notificationName
    self.diagnostic = diagnostic
    self.fileManager = fileManager
  }

  /// Resolves an App Group container and creates a mailbox inside it.
  public convenience init(
    appGroupIdentifier: String,
    namespace: String,
    limits: Limits = .init(),
    overflowPolicy: OverflowPolicy = .rejectNewest,
    notificationName: String? = nil,
    diagnostic: (@Sendable (Diagnostic) -> Void)? = nil
  ) throws {
    #if canImport(Darwin)
      guard
        let container = FileManager.default.containerURL(
          forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
      else { throw MailboxError.containerUnavailable }
      try self.init(
        containerURL: container,
        namespace: namespace,
        limits: limits,
        overflowPolicy: overflowPolicy,
        notificationName: notificationName,
        diagnostic: diagnostic
      )
    #else
      throw MailboxError.containerUnavailable
    #endif
  }

  /// Atomically adds a message and returns its stable identifier.
  @discardableResult
  public func enqueue(_ message: Message) throws -> UUID {
    try enqueue(message, id: UUID(), enqueuedAt: Date())
  }

  /// Atomically adds a message with a caller-supplied stable identifier.
  ///
  /// If an active pending or claimed message already has `id`, this operation succeeds without
  /// writing a duplicate. This makes importing an external durable queue safe to retry after a
  /// process terminates between enqueueing and removing the source record.
  @discardableResult
  public func enqueue(_ message: Message, id: UUID) throws -> UUID {
    try enqueue(message, id: id, enqueuedAt: Date())
  }

  /// Atomically imports a message at its original chronological position.
  ///
  /// Messages with the same enqueue date retain their mailbox insertion order.
  /// Pending or claimed messages with the same `id` are not duplicated.
  @discardableResult
  public func enqueue(_ message: Message, id: UUID, enqueuedAt: Date) throws -> UUID {
    var shouldNotify = false
    defer { if shouldNotify { postNotification() } }
    try withLock {
      let envelope = Envelope(id: id, enqueuedAt: enqueuedAt, message: message)
      let data: Data
      do {
        data = try encoder.encode(envelope)
      } catch {
        throw MailboxError.encodingFailure
      }
      guard data.count <= limits.maxPayloadBytes else {
        throw MailboxError.payloadTooLarge(
          actualBytes: data.count, maximumBytes: limits.maxPayloadBytes)
      }

      try maintain(recoveredMessages: &shouldNotify)
      if try containsMessage(id: id) { return }
      var pending = try pendingEntries()
      while try activeMessageCount() >= limits.maxMessages,
        let malformedIndex = pending.firstIndex(where: { $0.enqueuedAt == nil })
      {
        let malformed = pending.remove(at: malformedIndex)
        try quarantine(malformed.url)
        diagnostic?(.malformedMessageQuarantined)
      }
      if try activeMessageCount() >= limits.maxMessages {
        switch overflowPolicy {
        case .rejectNewest:
          throw MailboxError.mailboxFull
        case .discardOldest:
          guard !pending.isEmpty else { throw MailboxError.mailboxFull }
          try fileManager.removeItem(at: pending.removeFirst().url)
          diagnostic?(.oldestMessageDiscarded)
        }
      }

      let ordinal = try nextOrdinal(from: pending)
      let name = String(format: "pending-%020llu-%@.json", ordinal, id.uuidString)
      let destination = directory.appendingPathComponent(name, isDirectory: false)
      do {
        try data.write(to: destination, options: writeOptions)
      } catch {
        throw MailboxError.ioFailure
      }
    }

    shouldNotify = true
    return id
  }

  /// Claims pending messages in FIFO order. Concurrent consumers cannot claim the same file.
  public func claimPending(limit: Int? = nil) throws -> [Claim] {
    if let limit, limit < 0 { throw MailboxError.invalidLimit("claim limit") }
    var recoveredMessages = false
    defer { if recoveredMessages { postNotification() } }
    return try withLock {
      try maintain(recoveredMessages: &recoveredMessages)
      let entries = try pendingEntries()
      let selected = limit.map { Array(entries.prefix($0)) } ?? entries
      var claims: [Claim] = []
      for entry in selected {
        if let claim = try claim(entry) {
          claims.append(claim)
        }
      }
      return claims
    }
  }

  /// Performs expiry, abandoned-claim recovery, and bounded quarantine cleanup.
  public func performMaintenance() throws {
    var recoveredMessages = false
    defer { if recoveredMessages { postNotification() } }
    try withLock { try maintain(recoveredMessages: &recoveredMessages) }
  }

  private func claim(_ entry: Entry) throws -> Claim? {
    let claimName = "claimed-\(UUID().uuidString)-\(entry.originalName)"
    let claimURL = directory.appendingPathComponent(claimName, isDirectory: false)
    do {
      try fileManager.moveItem(at: entry.url, to: claimURL)
      try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: claimURL.path)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return nil
    } catch {
      if fileManager.fileExists(atPath: claimURL.path) {
        try? fileManager.moveItem(at: claimURL, to: entry.url)
      }
      throw MailboxError.ioFailure
    }

    do {
      let data = try safeData(at: claimURL)
      let envelope = try decoder.decode(Envelope.self, from: data)
      return Claim(
        id: envelope.id,
        message: envelope.message,
        enqueuedAt: envelope.enqueuedAt,
        mailbox: self,
        claimedURL: claimURL,
        originalName: entry.originalName
      )
    } catch let error as MailboxError where error == .unsafeFile {
      try quarantine(claimURL)
      diagnostic?(.unsafeFileQuarantined)
      return nil
    } catch {
      try quarantine(claimURL)
      diagnostic?(.malformedMessageQuarantined)
      return nil
    }
  }

  private func finishClaim(at url: URL, originalName: String, acknowledge: Bool) throws {
    try withLock {
      guard fileManager.fileExists(atPath: url.path) else { throw MailboxError.claimNoLongerExists }
      do {
        if acknowledge {
          try fileManager.removeItem(at: url)
        } else {
          let destination = directory.appendingPathComponent(originalName, isDirectory: false)
          try fileManager.moveItem(at: url, to: destination)
        }
      } catch {
        throw MailboxError.ioFailure
      }
    }
    if !acknowledge { postNotification() }
  }

  private func maintain(recoveredMessages: inout Bool) throws {
    let now = Date()
    let urls = try contents()
    for url in urls {
      let name = url.lastPathComponent
      guard name.hasPrefix("pending-") || name.hasPrefix("claimed-") else { continue }
      let values = try? url.resourceValues(forKeys: [
        .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
      ])
      guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
        try quarantine(url)
        diagnostic?(.unsafeFileQuarantined)
        continue
      }
      let claimedOriginalName: String?
      if name.hasPrefix("claimed-") {
        guard let originalName = Self.originalName(fromClaimName: name) else {
          try quarantine(url)
          diagnostic?(.unsafeFileQuarantined)
          continue
        }
        claimedOriginalName = originalName
      } else {
        claimedOriginalName = nil
      }
      let modificationDate = values?.contentModificationDate ?? now
      let claimAge = now.timeIntervalSince(modificationDate)
      let enqueuedAt = try? decoder.decode(Envelope.self, from: safeData(at: url)).enqueuedAt
      let messageAge = now.timeIntervalSince(enqueuedAt ?? modificationDate)
      if name.hasPrefix("pending-"), messageAge > limits.messageLifetime {
        try? fileManager.removeItem(at: url)
        diagnostic?(.expiredMessageRemoved)
      } else if name.hasPrefix("claimed-"), claimAge > limits.claimTimeout,
        let original = claimedOriginalName
      {
        if messageAge > limits.messageLifetime {
          try? fileManager.removeItem(at: url)
          diagnostic?(.expiredMessageRemoved)
          continue
        }
        let destination = directory.appendingPathComponent(original, isDirectory: false)
        if !fileManager.fileExists(atPath: destination.path) {
          if (try? fileManager.moveItem(at: url, to: destination)) != nil {
            recoveredMessages = true
            diagnostic?(.abandonedClaimRecovered)
          }
        } else {
          try quarantine(url)
          diagnostic?(.unsafeFileQuarantined)
        }
      }
    }
    try trimQuarantine()
  }

  private func activeMessageCount() throws -> Int {
    try contents().count { url in
      let name = url.lastPathComponent
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      return (name.hasPrefix("pending-") || name.hasPrefix("claimed-"))
        && values?.isRegularFile == true
        && values?.isSymbolicLink != true
    }
  }

  private func containsMessage(id: UUID) throws -> Bool {
    for url in try contents() {
      let name = url.lastPathComponent
      if let fileID = Self.messageID(fromFileName: name), fileID == id {
        return true
      }
      guard name.hasPrefix("pending-") || name.hasPrefix("claimed-") else { continue }
      guard let data = try? safeData(at: url),
        let envelope = try? decoder.decode(Envelope.self, from: data)
      else { continue }
      if envelope.id == id { return true }
    }
    return false
  }

  private func quarantine(_ url: URL, messageID: UUID? = nil) throws {
    guard limits.maxQuarantinedFiles > 0 else {
      try? fileManager.removeItem(at: url)
      return
    }
    let idComponent =
      messageID?.uuidString
      ?? Self.messageID(fromFileName: url.lastPathComponent)?.uuidString
      ?? UUID().uuidString
    let destination = directory.appendingPathComponent(
      "quarantine-\(UInt64(Date().timeIntervalSince1970 * 1_000))-\(idComponent).bin",
      isDirectory: false
    )
    do {
      try fileManager.moveItem(at: url, to: destination)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    } catch {
      throw MailboxError.ioFailure
    }
    try trimQuarantine()
  }

  func contents() throws -> [URL] {
    do {
      return try fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [
          .contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
        ],
        options: [.skipsHiddenFiles]
      )
    } catch {
      throw MailboxError.ioFailure
    }
  }

  private func trimQuarantine() throws {
    let quarantined = try contents()
      .filter { $0.lastPathComponent.hasPrefix("quarantine-") }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    for url in quarantined.dropLast(limits.maxQuarantinedFiles) {
      try? fileManager.removeItem(at: url)
    }
  }
}

extension AppGroupMailbox {
  private static func isValidNamespace(_ namespace: String) -> Bool {
    guard (1...64).contains(namespace.count) else { return false }
    return namespace.utf8.allSatisfy { byte in
      (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        || byte == 45 || byte == 95 || byte == 46
    } && namespace != "." && namespace != ".."
  }

  /// Extracts a message UUID embedded in pending-, claimed-, or quarantine- filenames.
  static func messageID(fromFileName name: String) -> UUID? {
    if name.hasPrefix("pending-") {
      let remainder = name.dropFirst("pending-".count)
      let afterOrdinal = remainder.drop(while: { $0.isNumber }).drop(while: { $0 == "-" })
      let uuidPart = afterOrdinal.prefix(36)
      return UUID(uuidString: String(uuidPart))
    }
    if name.hasPrefix("claimed-"), let original = originalName(fromClaimName: name) {
      return messageID(fromFileName: original)
    }
    if name.hasPrefix("quarantine-") {
      // quarantine-<millis>-<uuid>.bin
      let parts = name.split(separator: "-")
      guard parts.count >= 3 else { return nil }
      let uuidPart = parts.dropFirst(2).joined(separator: "-").replacingOccurrences(
        of: ".bin", with: "")
      return UUID(uuidString: uuidPart)
    }
    return nil
  }

  static func ordinal(from name: String) -> UInt64? {
    guard name.hasPrefix("pending-") else { return nil }
    return UInt64(name.dropFirst("pending-".count).prefix(while: \Character.isNumber))
  }

  static func originalName(fromClaimName name: String) -> String? {
    guard name.hasPrefix("claimed-") else { return nil }
    let remainder = name.dropFirst("claimed-".count)
    guard remainder.count > 37,
      UUID(uuidString: String(remainder.prefix(36))) != nil,
      remainder.dropFirst(36).first == "-"
    else { return nil }
    let original = String(remainder.dropFirst(37))
    guard original.hasPrefix("pending-"), original.hasSuffix(".json"), !original.contains("/")
    else {
      return nil
    }
    return original
  }

  private var writeOptions: Data.WritingOptions {
    #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
      [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    #else
      [.atomic]
    #endif
  }
}

// Lint CI verification marker
