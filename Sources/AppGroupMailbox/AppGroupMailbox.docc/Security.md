# Security and recovery

Understand the mailbox's filesystem boundary and failure model.

## Filesystem boundary

The package creates `AppGroupMailbox/<namespace>` below the caller-provided container. A namespace
contains only ASCII letters, numbers, `.`, `_`, and `-`, and cannot be `.`, `..`, or made only of
dots. Queue discovery and capacity accounting only accept regular, non-symbolic-link files whose
pending names match `pending-<20-digit-ordinal>-<uuid>.json` (lowercase `.json`).

The file size is checked before reading. A payload cannot exceed
``AppGroupMailbox/AppGroupMailbox/Limits/maxPayloadBytes``.
Malformed and unsafe inputs are quarantined without exposing their bytes to diagnostics. Quarantine
storage is bounded by ``AppGroupMailbox/AppGroupMailbox/Limits/maxQuarantinedFiles``.

On iOS-family platforms, queue files use `completeFileProtectionUntilFirstUserAuthentication`.
Mailbox operations that touch the queue can fail until the user unlocks the device once after
reboot.

## Delivery model

Enqueue writes a complete envelope atomically while holding a cross-process advisory lock. Claiming
atomically renames the pending file. This provides at-least-once delivery: an acknowledged claim is
removed, a released claim is immediately retried, and a crash-abandoned claim is retried after
``AppGroupMailbox/AppGroupMailbox/Limits/claimTimeout``. Handlers therefore should be idempotent.

On iOS-family platforms, queue files use `completeFileProtectionUntilFirstUserAuthentication`.
Mailbox operations that touch the queue can fail until the user unlocks the device once after
reboot.

Darwin notifications posted after enqueue or recovery are payload-free and may be coalesced.
Treat each delivery as a hint to drain pending messages rather than a 1:1 mapping to individual
enqueues.
