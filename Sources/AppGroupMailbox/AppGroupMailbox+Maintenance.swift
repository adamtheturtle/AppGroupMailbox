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
