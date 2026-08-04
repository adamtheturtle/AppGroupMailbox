import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

extension AppGroupMailbox {
  func safeData(at url: URL, afterOpen: (() throws -> Void)? = nil) throws -> Data {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw MailboxError.unsafeFile }
    defer { close(descriptor) }

    try afterOpen?()

    var status = stat()
    guard fstat(descriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG,
      status.st_size >= 0,
      UInt64(status.st_size) <= UInt64(limits.maxPayloadBytes)
    else { throw MailboxError.unsafeFile }

    var data = Data()
    data.reserveCapacity(Int(status.st_size))
    var buffer = [UInt8](repeating: 0, count: min(16_384, limits.maxPayloadBytes + 1))
    while true {
      let remaining = limits.maxPayloadBytes - data.count
      let requested =
        remaining == Int.max ? buffer.count : min(buffer.count, remaining + 1)
      let count = read(descriptor, &buffer, requested)
      if count == 0 { return data }
      if count < 0 {
        if errno == EINTR { continue }
        throw MailboxError.ioFailure
      }
      guard count <= remaining else { throw MailboxError.unsafeFile }
      data.append(buffer, count: count)
    }
  }
}
