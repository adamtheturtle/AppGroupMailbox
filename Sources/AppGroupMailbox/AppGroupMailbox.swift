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

    private weak var mailbox: AppGroupMailbox?
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
      guard let mailbox else { throw MailboxError.claimNoLongerExists }
      try mailbox.finishClaim(at: claimedURL, originalName: originalName, acknowledge: true)
    }

    /// Returns the message to the pending queue at its original position.
    public func release() throws {
      guard let mailbox else { throw MailboxError.claimNoLongerExists }
      try mailbox.finishClaim(at: claimedURL, originalName: originalName, acknowledge: false)
    }

    /// Extends the claim lease so abandoned-claim recovery waits another ``Limits/claimTimeout``.
    public func renew() throws {
      guard let mailbox else { throw MailboxError.claimNoLongerExists }
      try mailbox.renewClaim(at: claimedURL)
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
  private var lockedDiagnostics: [Diagnostic] = []
  private var isLockedForDiagnostics = false

  /// Creates a mailbox inside `containerURL/AppGroupMailbox/<namespace>`.
  ///
  /// - Parameter notificationName: On Darwin platforms, posts a payload-free Darwin notification
  ///   after enqueueing and when messages become pending again. On other platforms this parameter
  ///   is accepted for API compatibility but notifications are not delivered.
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
    encoder.dateEncodingStrategy = .secondsSince1970
    decoder.dateDecodingStrategy = .secondsSince1970
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
        emitDiagnostic(.malformedMessageQuarantined)
      }
      if try activeMessageCount() >= limits.maxMessages {
        switch overflowPolicy {
        case .rejectNewest:
          throw MailboxError.mailboxFull
        case .discardOldest:
          guard !pending.isEmpty else { throw MailboxError.mailboxFull }
          try fileManager.removeItem(at: pending.removeFirst().url)
          emitDiagnostic(.oldestMessageDiscarded)
          shouldNotify = true
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
        do {
          try fileManager.moveItem(at: claimURL, to: entry.url)
        } catch {
          // Avoid split-brain (pending gone, claim present) when rollback fails.
          try quarantine(claimURL)
          emitDiagnostic(.unsafeFileQuarantined)
        }
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
      emitDiagnostic(.unsafeFileQuarantined)
      return nil
    } catch is DecodingError {
      try quarantine(claimURL)
      emitDiagnostic(.malformedMessageQuarantined)
      return nil
    } catch {
      // Restore pending so transient read failures do not permanently drop messages.
      do {
        try fileManager.moveItem(at: claimURL, to: entry.url)
      } catch {
        try quarantine(claimURL)
        emitDiagnostic(.malformedMessageQuarantined)
      }
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
          if fileManager.fileExists(atPath: destination.path) {
            // Conflicting pending file blocks release; quarantine it so the claim can return.
            try quarantine(destination)
            emitDiagnostic(.unsafeFileQuarantined)
          }
          try fileManager.moveItem(at: url, to: destination)
        }
      } catch let error as MailboxError {
        throw error
      } catch {
        throw MailboxError.ioFailure
      }
    }
    if !acknowledge { postNotification() }
  }

  // swiftlint:disable:next cyclomatic_complexity
  fileprivate func renewClaim(at url: URL) throws {
    try withLock {
      guard fileManager.fileExists(atPath: url.path) else { throw MailboxError.claimNoLongerExists }
      try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }
  }

  private func maintain(recoveredMessages: inout Bool) throws {
    let now = Date()
    let urls = try contents()
    for url in urls {
      let name = url.lastPathComponent
      guard name.hasPrefix("pending-") || name.hasPrefix("claimed-") else { continue }
      let values = try? url.resourceValues(forKeys: [
        .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey,
      ])
      if values?.isDirectory == true {
        // Orphan directories with mailbox prefixes are not messages; remove them.
        try? fileManager.removeItem(at: url)
        emitDiagnostic(.unsafeFileQuarantined)
        continue
      }
      guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
        try quarantine(url)
        emitDiagnostic(.unsafeFileQuarantined)
        continue
      }
      let claimedOriginalName: String?
      if name.hasPrefix("claimed-") {
        guard let originalName = Self.originalName(fromClaimName: name) else {
          try quarantine(url)
          emitDiagnostic(.unsafeFileQuarantined)
          continue
        }
        claimedOriginalName = originalName
      } else {
        claimedOriginalName = nil
      }
      let modificationDate = values?.contentModificationDate ?? now
      let claimAge = now.timeIntervalSince(modificationDate)
      let decoded: Envelope?
      do {
        decoded = try decoder.decode(Envelope.self, from: safeData(at: url))
      } catch {
        decoded = nil
      }
      let enqueuedAt = decoded?.enqueuedAt
      if name.hasPrefix("pending-"), decoded == nil {
        try quarantine(url)
        emitDiagnostic(.malformedMessageQuarantined)
        continue
      }
      let messageAge = now.timeIntervalSince(enqueuedAt ?? modificationDate)
      if name.hasPrefix("pending-"), messageAge > limits.messageLifetime {
        if decoded == nil {
          try quarantine(url)
          emitDiagnostic(.malformedMessageQuarantined)
        } else {
          do {
            try fileManager.removeItem(at: url)
            emitDiagnostic(.expiredMessageRemoved)
            recoveredMessages = true
          } catch let error as CocoaError where error.code == .fileNoSuchFile {
            continue
          }
        }
      } else if name.hasPrefix("claimed-"), claimAge > limits.claimTimeout,
        let original = claimedOriginalName
      {
        if messageAge > limits.messageLifetime {
          if decoded == nil {
            try quarantine(url)
            emitDiagnostic(.malformedMessageQuarantined)
          } else {
            do {
              try fileManager.removeItem(at: url)
              emitDiagnostic(.expiredMessageRemoved)
              recoveredMessages = true
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
              continue
            }
          }
          continue
        }
        let destination = directory.appendingPathComponent(original, isDirectory: false)
        if !fileManager.fileExists(atPath: destination.path) {
          if (try? fileManager.moveItem(at: url, to: destination)) != nil {
            recoveredMessages = true
            emitDiagnostic(.abandonedClaimRecovered)
          }
        } else {
          try quarantine(url)
          emitDiagnostic(.unsafeFileQuarantined)
        }
      }
    }
    try trimQuarantine()
  }

  private func activeMessageCount() throws -> Int {
    var seen: Set<FileIdentity> = []
    var count = 0
    for url in try contents() {
      guard Self.isActiveMessageURL(url) else { continue }
      if let identity = FileIdentity(url: url) {
        if seen.insert(identity).inserted {
          count += 1
        }
      } else {
        count += 1
      }
    }
    return count
  }

  /// Pending and claimed regular files that count toward capacity and can participate
  /// in claim/idempotency flows. Requires a lowercase `.json` pending name so ghost
  /// capacity slots from alternate extensions cannot accumulate.
  static func isPendingMessageName(_ name: String) -> Bool {
    name.hasPrefix("pending-") && name.hasSuffix(".json") && !name.contains("/")
  }

  static func isActiveMessageName(_ name: String) -> Bool {
    if name.hasPrefix("claimed-") { return true }
    return isPendingMessageName(name)
  }

  static func isActiveMessageURL(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    guard isActiveMessageName(name) else { return false }
    do {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      return values.isRegularFile == true && values.isSymbolicLink != true
    } catch {
      // Fail closed: treat unreadable entries as active so capacity cannot be bypassed.
      return true
    }
  }

  private struct FileIdentity: Hashable {
    let device: Int
    let inode: Int

    init?(url: URL) {
      #if canImport(Darwin)
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return nil }
        self.device = Int(status.st_dev)
        self.inode = Int(status.st_ino)
      #else
        return nil
      #endif
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
      String(
        format: "quarantine-%020llu-%@.bin",
        UInt64(Date().timeIntervalSince1970 * 1_000),
        idComponent
      ),
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
      .sorted {
        Self.quarantineTimestamp(from: $0.lastPathComponent)
          < Self.quarantineTimestamp(from: $1.lastPathComponent)
      }
    for url in quarantined.dropLast(limits.maxQuarantinedFiles) {
      do {
        try fileManager.removeItem(at: url)
      } catch let error as CocoaError where error.code == .fileNoSuchFile {
        continue
      }
    }
  }
}

extension AppGroupMailbox {
  static func quarantineTimestamp(from name: String) -> UInt64 {
    guard name.hasPrefix("quarantine-") else { return 0 }
    let remainder = name.dropFirst("quarantine-".count)
    let digits = remainder.prefix(while: \Character.isNumber)
    return UInt64(digits) ?? 0
  }

  private static func isValidNamespace(_ namespace: String) -> Bool {
    guard (1...64).contains(namespace.count) else { return false }
    guard
      namespace.utf8.allSatisfy({ byte in
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
          || byte == 45 || byte == 95 || byte == 46
      })
    else { return false }
    // Reject ".", "..", and any name made only of dots (e.g. "...") which can be
    // surprising path components even when they are not classic traversal tokens.
    return namespace.contains(where: { $0 != "." })
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
    let remainder = name.dropFirst("pending-".count)
    let digits = remainder.prefix(while: \Character.isNumber)
    guard digits.count == 20,
      remainder.dropFirst(20).first == "-",
      let value = UInt64(digits)
    else { return nil }
    return value
  }

  static func originalName(fromClaimName name: String) -> String? {
    guard name.hasPrefix("claimed-") else { return nil }
    let remainder = name.dropFirst("claimed-".count)
    guard remainder.count > 37,
      UUID(uuidString: String(remainder.prefix(36))) != nil,
      remainder.dropFirst(36).first == "-"
    else { return nil }
    let original = String(remainder.dropFirst(37))
    guard original.hasPrefix("pending-"),
      original.hasSuffix(".json"),
      !original.contains("/"),
      ordinal(from: original) != nil,
      messageID(fromPendingName: original) != nil
    else {
      return nil
    }
    return original
  }

  /// Extracts the message UUID from a package-written `pending-<20 digits>-<uuid>.json` name.
  static func messageID(fromPendingName name: String) -> UUID? {
    guard name.hasPrefix("pending-"), name.hasSuffix(".json") else { return nil }
    let body = name.dropFirst("pending-".count).dropLast(".json".count)
    guard body.count == 20 + 1 + 36,
      ordinal(from: name) != nil,
      body.dropFirst(20).first == "-"
    else { return nil }
    return UUID(uuidString: String(body.suffix(36)))
  }

  func beginLockedDiagnostics() {
    isLockedForDiagnostics = true
    lockedDiagnostics.removeAll(keepingCapacity: true)
  }

  func endLockedDiagnostics() {
    isLockedForDiagnostics = false
    guard let diagnostic, !lockedDiagnostics.isEmpty else {
      lockedDiagnostics.removeAll(keepingCapacity: false)
      return
    }
    let batch = lockedDiagnostics
    lockedDiagnostics.removeAll(keepingCapacity: false)
    for event in batch {
      diagnostic(event)
    }
  }

  func emitDiagnostic(_ event: Diagnostic) {
    if isLockedForDiagnostics {
      lockedDiagnostics.append(event)
    } else {
      diagnostic?(event)
    }
  }

  private var writeOptions: Data.WritingOptions {
    #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
      [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    #else
      [.atomic]
    #endif
  }
}

// Lint CI verification marker (80)
