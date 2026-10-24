## What changed

<!-- Describe the behavior changed and the affected modules. -->

## Validation

- [ ] `python3 scripts/test-state.py`
- [ ] `swift test`
- [ ] `swiftc -swift-version 5 -parse-as-library -typecheck Sources/*.swift`
- [ ] UI or package verification when applicable

## Compatibility

- [ ] Existing task history and media-library data remain compatible.
- [ ] Low-memory and global download budgets remain enforced.
- [ ] No credentials, personal paths, media files, build products, or signing
      material are included.
