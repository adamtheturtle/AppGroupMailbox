import AppGroupMailbox
import Foundation

private struct Message: Codable, Sendable {
  let value: String
}

@main
private enum MailboxTestWorker {
  static func main() throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 5, arguments[1] == "enqueue",
      let start = Int(arguments[3]), let count = Int(arguments[4])
    else {
      throw WorkerError.invalidArguments
    }

    let mailbox = try AppGroupMailbox<Message>(
      containerURL: URL(fileURLWithPath: arguments[2], isDirectory: true),
      namespace: "multiprocess",
      limits: .init(maxMessages: 200)
    )
    for value in start..<(start + count) {
      try mailbox.enqueue(Message(value: String(value)))
    }
  }
}

private enum WorkerError: Error {
  case invalidArguments
}
