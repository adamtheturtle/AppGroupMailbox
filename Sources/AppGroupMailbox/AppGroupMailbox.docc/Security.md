# Security and recovery

Understand the mailbox's filesystem boundary and failure model.

## Filesystem boundary

The package creates `AppGroupMailbox/<namespace>` below the caller-provided container. A namespace
contains only ASCII letters, numbers, `.`, `_`, and `-`, and cannot be `.` or `..`. Queue discovery
only accepts regular, non-symbolic-link files with the package's pending filename shape.

The file size is checked before reading. A payload cannot exceed
``AppGroupMailbox/AppGroupMailbox/Limits/maxPayloadBytes``.
Malformed and unsafe inputs are quarantined without exposing their bytes to diagnostics. Quarantine
storage is bounded by ``AppGroupMailbox/AppGroupMailbox/Limits/maxQuarantinedFiles``.

## Delivery model

Enqueue writes a complete envelope atomically while holding a cross-process advisory lock. Claiming
atomically renames the pending file. This provides at-least-once delivery: an acknowledged claim is
removed, a released claim is immediately retried, and a crash-abandoned claim is retried after
``AppGroupMailbox/AppGroupMailbox/Limits/claimTimeout``. Handlers therefore should be idempotent.
