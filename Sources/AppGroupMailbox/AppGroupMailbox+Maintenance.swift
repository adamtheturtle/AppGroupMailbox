import Foundation

#if canImport(Darwin)
  import Darwin
#endif

extension AppGroupMailbox {
  func activeMessageCount() throws -> Int {
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

  struct FileIdentity: Hashable {
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

  func containsMessage(id: UUID) throws -> Bool {
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

  func quarantine(_ url: URL, messageID: UUID? = nil) throws {
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

  func trimQuarantine() throws {
    let quarantined = try contents()
      .filter { $0.lastPathComponent.hasPrefix("quarantine-") }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
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
  static func isValidNamespace(_ namespace: String) -> Bool {
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

  var writeOptions: Data.WritingOptions {
    #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
      [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    #else
      [.atomic]
    #endif
  }
}

// Lint CI verification marker (80)
