import Foundation

extension AppGroupMailbox {
  func postNotification() {
    #if canImport(Darwin)
      guard let notificationName else { return }
      CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(notificationName as CFString),
        nil,
        nil,
        true
      )
    #endif
  }
}
