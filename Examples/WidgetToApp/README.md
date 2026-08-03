# Widget-to-app example

Both targets add the same App Group entitlement and construct an identical mailbox:

```swift
enum WidgetAction: Codable, Sendable {
    case refresh
}

let actions = try AppGroupMailbox<WidgetAction>(
    appGroupIdentifier: "group.com.example.product",
    namespace: "widget-actions",
    notificationName: "group.com.example.product.widget-action-enqueued"
)
```

The widget calls `try actions.enqueue(.refresh)`. The host app drains on activation and when its
Darwin notification observer fires. It acknowledges only after applying the action successfully.
