# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Ordinal overflow throws `ordinalExhausted` instead of a generic I/O failure (#41).
- Idempotent enqueue recognizes malformed and quarantined same-ID files (#21, #22).
- Capacity counting and pending selection agree on lowercase `.json` pending names (#23, #24, #25).
- Idempotent enqueue does not post a Darwin notification when skipping a duplicate (#70).
- `claimPending(limit:)` rejects zero as an invalid limit (#32).
- Namespace validation rejects dot-only names such as `...` (#42).
- Cap `maxPayloadBytes` and avoid overflow in `safeData` byte-limit math (#47, #48).
- `MailboxError` conforms to `LocalizedError` and `Hashable` (#52, #53).

## [0.1.1] - 2026-08-03

### Added

- Idempotent `enqueue(_:id:)` for safely importing records from another durable queue.

## [0.1.0] - 2026-08-03

### Added

- Bounded, generic `Codable` and `Sendable` message queues.
- Atomic enqueue, claim, acknowledgement, and release operations.
- Cross-process locking and crash-abandoned claim recovery.
- Expiration, malformed-input quarantine, symlink rejection, and bounded cleanup.
- Optional Darwin wake-up notification after enqueue.
- DocC documentation and tests for ordering, bounds, recovery, and concurrency.

[Unreleased]: https://github.com/adamtheturtle/AppGroupMailbox/compare/0.1.1...HEAD
[0.1.1]: https://github.com/adamtheturtle/AppGroupMailbox/compare/0.1.0...0.1.1
[0.1.0]: https://github.com/adamtheturtle/AppGroupMailbox/releases/tag/0.1.0
