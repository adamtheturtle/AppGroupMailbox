import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

extension AppGroupMailbox {
  func nextOrdinal(from entries: [Entry]) throws -> UInt64 {
    let now = UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
    let pendingOrdinals = entries.compactMap { Self.ordinal(from: $0.originalName) }
    let claimedOrdinals = try contents().compactMap { url -> UInt64? in
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values?.isRegularFile == true, values?.isSymbolicLink != true,
        let originalName = Self.originalName(fromClaimName: url.lastPathComponent)
      else { return nil }

      return Self.ordinal(from: originalName)
    }
    let highest = (pendingOrdinals + claimedOrdinals).max() ?? 0
    let (incremented, overflow) = highest.addingReportingOverflow(1)
    guard !overflow else { throw MailboxError.ordinalExhausted }
    return max(now, incremented)
  }

  func withLock<T>(_ body: () throws -> T) throws -> T {
    let lockURL = directory.appendingPathComponent(".mailbox.lock", isDirectory: false)
    let descriptor = open(
      lockURL.path,
      O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else { throw MailboxError.ioFailure }
    defer { close(descriptor) }

    var descriptorStatus = stat()
    var pathStatus = stat()
    guard fstat(descriptor, &descriptorStatus) == 0,
      lstat(lockURL.path, &pathStatus) == 0,
      descriptorStatus.st_uid == geteuid(),
      descriptorStatus.st_nlink == 1,
      descriptorStatus.st_dev == pathStatus.st_dev,
      descriptorStatus.st_ino == pathStatus.st_ino,
      descriptorStatus.st_mode & S_IFMT == S_IFREG,
      pathStatus.st_mode & S_IFMT == S_IFREG
    else { throw MailboxError.ioFailure }

    guard flock(descriptor, LOCK_EX) == 0 else { throw MailboxError.ioFailure }
    beginLockedDiagnostics()
    defer { endLockedDiagnostics() }
    defer { flock(descriptor, LOCK_UN) }
    return try body()
  }
}
