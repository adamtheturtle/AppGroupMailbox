import Foundation

extension AppGroupMailbox {
  func claim(_ entry: Entry) throws -> Claim? {
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
          diagnostic?(.unsafeFileQuarantined)
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
      diagnostic?(.unsafeFileQuarantined)
      return nil
    } catch is DecodingError {
      try quarantine(claimURL)
      diagnostic?(.malformedMessageQuarantined)
      return nil
    } catch {
      // Restore pending so transient read failures do not permanently drop messages.
      do {
        try fileManager.moveItem(at: claimURL, to: entry.url)
      } catch {
        try quarantine(claimURL)
        diagnostic?(.malformedMessageQuarantined)
      }
      return nil
    }
  }

  func finishClaim(at url: URL, originalName: String, acknowledge: Bool) throws {
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
            diagnostic?(.unsafeFileQuarantined)
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
  func maintain(recoveredMessages: inout Bool) throws {
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
      let decoded: Envelope?
      do {
        decoded = try decoder.decode(Envelope.self, from: safeData(at: url))
      } catch {
        decoded = nil
      }
      let enqueuedAt = decoded?.enqueuedAt
      let messageAge = now.timeIntervalSince(enqueuedAt ?? modificationDate)
      if name.hasPrefix("pending-"), messageAge > limits.messageLifetime {
        if decoded == nil {
          try quarantine(url)
          diagnostic?(.malformedMessageQuarantined)
        } else {
          try? fileManager.removeItem(at: url)
          diagnostic?(.expiredMessageRemoved)
        }
      } else if name.hasPrefix("claimed-"), claimAge > limits.claimTimeout,
        let original = claimedOriginalName
      {
        if messageAge > limits.messageLifetime {
          if decoded == nil {
            try quarantine(url)
            diagnostic?(.malformedMessageQuarantined)
          } else {
            try? fileManager.removeItem(at: url)
            diagnostic?(.expiredMessageRemoved)
          }
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

  func activeMessageCount() throws -> Int {
    try contents().count { url in
      Self.isActiveMessageURL(url)
    }
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
      try? fileManager.removeItem(at: url)
    }
  }
}
