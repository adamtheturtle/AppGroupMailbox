import AppGroupMailbox
import Foundation

private struct Message: Codable, Sendable {
  let value: String
}

@main
private enum MailboxTestWorker {
  static func main() throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 5 || arguments.count == 6 || arguments.count == 7,
      arguments[1] == "enqueue",
      let start = Int(arguments[3]), let count = Int(arguments[4])
    else {
      throw WorkerError.invalidArguments
    }

    let namespace = arguments.count >= 6 ? arguments[5] : "multiprocess-\(UUID().uuidString)"
    let messageType = arguments.count == 7 ? arguments[6] : nil
    let mailbox = try AppGroupMailbox<Message>(
      containerURL: URL(fileURLWithPath: arguments[2], isDirectory: true),
      namespace: namespace,
      limits: .init(maxMessages: 200),
      messageType: messageType
    )
    for value in start..<(start + count) {
      try mailbox.enqueue(Message(value: String(value)))
    }
  }
}

private enum WorkerError: Error {
  case invalidArguments
}
