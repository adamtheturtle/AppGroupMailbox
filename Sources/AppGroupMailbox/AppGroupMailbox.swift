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
      // Cap payload size so remaining+1 arithmetic in safeData cannot overflow Int,
      // and so callers cannot request unbounded in-memory reads.
      guard maxPayloadBytes > 0, maxPayloadBytes <= 64 * 1024 * 1024 else {
        throw MailboxError.invalidLimit("maxPayloadBytes")
      }
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
  public enum MailboxError: Error, Sendable, Equatable, Hashable, LocalizedError {
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

    public var errorDescription: String? {
      switch self {
      case .invalidNamespace:
        return "The mailbox namespace is invalid."
      case .invalidLimit(let name):
        return "The mailbox limit '\(name)' is invalid."
      case .containerUnavailable:
        return "The App Group container is unavailable."
      case .mailboxFull:
        return "The mailbox is full."
      case .payloadTooLarge(let actualBytes, let maximumBytes):
        return
          "The encoded message is \(actualBytes) bytes, which exceeds the limit of \(maximumBytes) bytes."
      case .unsafeFile:
        return "A mailbox file failed safety checks."
      case .claimNoLongerExists:
        return "The claim no longer exists."
      case .ioFailure:
        return "A mailbox file operation failed."
      case .encodingFailure:
        return "Encoding the message failed."
      case .decodingFailure:
        return "Decoding the message failed."
      case .ordinalExhausted:
        return "The mailbox ordinal space is exhausted."
      }
    }
  }

  /// An atomically claimed message. A claim remains on disk until acknowledged or released.
  public final class Claim: @unchecked Sendable {
    public let id: UUID
    public let message: Message
    public let enqueuedAt: Date

    private let mailbox: AppGroupMailbox
    private let claimedURL: URL
    private let originalName: String

    init(
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
  let overflowPolicy: OverflowPolicy
  let notificationName: String?
  let diagnostic: (@Sendable (Diagnostic) -> Void)?
  let fileManager: FileManager
  let encoder = JSONEncoder()
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
      shouldNotify = true
    }

    return id
  }

  /// Claims pending messages in FIFO order. Concurrent consumers cannot claim the same file.
  public func claimPending(limit: Int? = nil) throws -> [Claim] {
    if let limit, limit <= 0 { throw MailboxError.invalidLimit("claim limit") }
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
}
