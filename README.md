# AppGroupMailbox

A reliable, bounded, file-backed mailbox for passing messages between Apple app processes that
share an App Group container.

[Documentation](https://swiftpackageindex.com/adamtheturtle/AppGroupMailbox/documentation/appgroupmailbox) |
[Swift Package Index](https://swiftpackageindex.com/adamtheturtle/AppGroupMailbox)

## Installation

```swift
.package(url: "https://github.com/adamtheturtle/AppGroupMailbox.git", from: "0.1.0")
```

Add the `AppGroupMailbox` product to the app, widget, intent, extension, or helper targets that
exchange messages.

## Usage

Define a caller-owned message type:

```swift
import AppGroupMailbox

enum WidgetAction: Codable, Sendable {
    case refresh
    case selectItem(id: UUID)
}

let mailbox = try AppGroupMailbox<WidgetAction>(
    appGroupIdentifier: "group.com.example.product",
    namespace: "widget-actions",
    limits: .init(maxMessages: 100, maxPayloadBytes: 65_536),
    notificationName: "group.com.example.product.widget-action-enqueued"
)
```

The producer writes atomically and can optionally nudge an already-running consumer with a
payload-free Darwin notification. The same notification is also posted when a claim is released
back to pending and when an abandoned claim is recovered:

```swift
try mailbox.enqueue(.selectItem(id: itemID))
```

When importing another durable queue, supply its stable record ID. Retrying the import succeeds
without writing a duplicate while that ID is pending or claimed:

```swift
try mailbox.enqueue(action, id: legacyRecordID)
```

Pass the legacy enqueue date as well to preserve its chronological position relative to messages
already in the mailbox. Records with equal dates retain their mailbox insertion order:

```swift
try mailbox.enqueue(action, id: legacyRecordID, enqueuedAt: legacyEnqueuedAt)
```

The consumer claims in FIFO order, handles each value, and acknowledges success:

```swift
for claim in try mailbox.claimPending() {
    do {
        try await handle(claim.message)
        try claim.acknowledge()
    } catch {
        try claim.release()
    }
}
```

## Delivery and recovery

Pending messages are atomically renamed into unique claims. Two concurrent consumers cannot claim
the same file. A successful acknowledgement deletes the claim; release restores its original queue
position. If a process terminates while holding a claim, the next maintenance or claim operation
restores it after `claimTimeout`.

This is at-least-once delivery, so handlers should be idempotent. Stable claim IDs let an application
deduplicate effects when required.

Queue depth, encoded payload size, message age, claim timeout, and quarantine size are bounded.
When full, a mailbox can reject the newest enqueue (the default) or discard its oldest pending
message.

## Security

- Namespaces are validated and cannot traverse out of the mailbox directory.
- Only regular, non-symbolic-link queue files are accepted.
- File size is checked before bytes are read.
- Malformed, unsafe, and oversized inputs are rejected or quarantined.
- Quarantine storage is bounded.
- Diagnostics describe outcomes but never contain message contents.

The App Group container is the trust boundary. Every target that uses the mailbox must have the same
App Group entitlement.

## Requirements

- Swift 6.2+
- macOS 14+, iOS 17+, tvOS 17+, watchOS 10+, or visionOS 1+
- No dependencies

## License

MIT. See [LICENSE](LICENSE).
