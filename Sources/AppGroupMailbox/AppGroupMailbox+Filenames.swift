import Foundation

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

  var writeOptions: Data.WritingOptions {
    #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
      [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    #else
      [.atomic]
    #endif
  }
}

// Lint CI verification marker (80)
