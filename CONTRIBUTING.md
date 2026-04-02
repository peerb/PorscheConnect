# Contributing to SwiftPorscheConnect

Thanks for your interest in contributing!

## Getting Started

1. Fork the repo
2. Clone your fork: `git clone https://github.com/YOUR_USERNAME/PorscheConnect.git`
3. Create a branch: `git checkout -b my-feature`
4. Make your changes
5. Run tests: `swift test`
6. Push and open a PR

## Development

```bash
# Build
swift build

# Run tests (requires Xcode for XCTest)
swift test

# Or with explicit Xcode selection
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Code Style

- Follow [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
- All public APIs must have doc comments (`///`)
- Use American English spelling in API names
- Keep access control tight — only make things `public` if consumers need them

## Pull Requests

- One feature/fix per PR
- Include tests for new functionality
- Update the README if you add public API
- Keep commits focused and well-described

## Reporting Issues

- Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md) for bugs
- Use the [feature request template](.github/ISSUE_TEMPLATE/feature_request.md) for ideas
- Include Swift version, platform, and steps to reproduce

## Testing Against the Live API

Remote commands (lock, charge, climate) affect real vehicles. **Do not** test these commands in CI or against vehicles you don't own. Unit tests should use canned JSON responses.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
