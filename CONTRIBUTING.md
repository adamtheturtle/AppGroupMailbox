# Contributing

Bug reports and pull requests are welcome. Please open an issue before making a substantial API or
storage-format change.

## Development

The package requires Swift 6.2. Before submitting a change, run:

```sh
swift format lint --recursive --strict Sources Tests Package.swift
swiftlint lint --strict
swift test
```

Add tests for observable behaviour and update DocC when changing public API. Do not include real
message contents, App Group identifiers, or container paths in diagnostics or test fixtures.
