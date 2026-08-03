# ``AppGroupMailbox``

Pass caller-owned messages safely between Apple app processes that share an App Group container.

## Overview

`AppGroupMailbox` is a bounded, file-backed FIFO mailbox. Each enqueue is an atomic write. A
consumer atomically renames a pending file into a claim, ensuring that concurrent consumers cannot
both receive it. The consumer then acknowledges the claim or releases it for retry. Claims left by
a terminated process return to the pending queue after a configurable timeout.

```swift
let mailbox = try AppGroupMailbox<MyMessage>(
    appGroupIdentifier: "group.com.example.product",
    namespace: "widget-actions"
)

try mailbox.enqueue(.refresh)

for claim in try mailbox.claimPending() {
    try await handle(claim.message)
    try claim.acknowledge()
}
```

The package rejects symbolic links, non-regular files, oversized payloads, malformed envelopes,
and namespaces that could alter a path. Diagnostics never contain message contents.

## Topics

### Creating a mailbox

- ``AppGroupMailbox/init(containerURL:namespace:limits:overflowPolicy:notificationName:diagnostic:)``
- ``AppGroupMailbox/init(appGroupIdentifier:namespace:limits:overflowPolicy:notificationName:diagnostic:)``
- ``AppGroupMailbox/Limits``
- ``AppGroupMailbox/OverflowPolicy``

### Sending and receiving

- ``AppGroupMailbox/enqueue(_:)``
- ``AppGroupMailbox/claimPending(limit:)``
- ``AppGroupMailbox/Claim``

### Maintenance and diagnostics

- ``AppGroupMailbox/performMaintenance()``
- ``AppGroupMailbox/Diagnostic``
- ``AppGroupMailbox/MailboxError``
