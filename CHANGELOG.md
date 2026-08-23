# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Quarantine pending files with undecodable messages before overflow handling (#117).
- Ignore in-flight claims when reporting unclaimable capacity on rejectNewest (#105).
- Defer unclaimableFilesPresent diagnostics until after the mailbox lock is released (#106).
- Ordinal overflow throws `ordinalExhausted` instead of a generic I/O failure (#41).
- Idempotent enqueue recognizes malformed and quarantined same-ID files (#21, #22).
- Capacity counting and pending selection agree on lowercase `.json` pending names (#23, #24, #25).
- Idempotent enqueue does not post a Darwin notification when skipping a duplicate (#70).
- `claimPending(limit:)` rejects zero as an invalid limit (#32).
- Namespace validation rejects dot-only names such as `...` (#42).
- Cap `maxPayloadBytes` and avoid overflow in `safeData` byte-limit math (#47, #48).
- `MailboxError` conforms to `LocalizedError` and `Hashable` (#52, #53).
- Claim rollback, release conflicts, and transient claim-read failures are handled without split-brain or stuck claims (#38, #39, #40).
- `activeMessageCount` fails closed when `resourceValues` fails so capacity cannot be bypassed (#49).
- Expired malformed messages are quarantined with `malformedMessageQuarantined` instead of looking like normal expiry (#26).
- Document Darwin notifications for release and recovery in the README (#44).
- Record 0.2.0 and 0.2.1 release notes in the changelog (#45).
- Clarify Security.md pending filename and namespace rules (#43).
- Post recovery notifications even when later mailbox maintenance fails.
- Quarantine malformed pending files before applying overflow eviction so valid FIFO messages are preserved.
- Include claimed messages when allocating FIFO ordinals.
- Preserve imported-message chronology with deterministic tie ordering.
- Anchor message expiry to enqueue time rather than claim modification time.
- Harden mailbox lock opening against symbolic links and ownership mismatches.
- Read message payloads through validated file descriptors.
- Notify consumers when messages become pending again after release or recovery.
- Quarantine malformed claimed filenames with bounded retention.
- Require exact 20-digit ordinals and package pending shape in claim-name parsing (#64, #65).
- Surface deletion failures during expiry cleanup and quarantine trimming (#35, #36).
- Give multiprocess test workers an isolated namespace per run.
- Decode only envelope timestamps when ordering pending files for claim.
- Defer diagnostic callbacks until after the mailbox lock is released.
- Add `Claim.renew()` and use a weak mailbox reference so claims do not pin mailbox instances.
- Quarantine malformed pending files during maintenance instead of leaving them until claim.
- Use fixed-width quarantine timestamps so retention order stays chronological.
- Encode and decode envelope dates as Unix seconds for cross-process consistency.
- Document non-Darwin notification behavior and notify when discardOldest evicts a message.
- Emit a diagnostic when rejectNewest fails because unclaimable files consume capacity.
- Tag envelopes with schema version and message type to prevent cross-type namespace corruption.
- Allocate 21-digit pending ordinals so millisecond timestamps remain encodable.
- Read only envelope timestamps during maintenance instead of decoding full messages.
- Abandoned-claim recovery quarantines conflicting pending files and surfaces failed restore moves (#27, #28).
- Count hard-linked pending/claimed files once toward maxMessages (#50).
- Remove orphan pending-/claimed- directories during maintenance (#51).
- Notify consumers when expired messages are removed during maintenance (#34).

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

[Unreleased]: https://github.com/adamtheturtle/AppGroupMailbox/compare/0.2.1...HEAD
[0.2.1]: https://github.com/adamtheturtle/AppGroupMailbox/compare/0.2.0...0.2.1
[0.2.0]: https://github.com/adamtheturtle/AppGroupMailbox/compare/0.1.1...0.2.0
[0.1.1]: https://github.com/adamtheturtle/AppGroupMailbox/compare/0.1.0...0.1.1
[0.1.0]: https://github.com/adamtheturtle/AppGroupMailbox/releases/tag/0.1.0
