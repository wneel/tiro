# Contributing to Tiro

Thank you for helping. Bug reports, fixes and translations are all welcome.

## Reporting a bug

Open an issue with your macOS version, your Mac (Apple silicon or Intel), the call app you used, and what happened. Attach `~/Library/Logs/Tiro.log` if you can: it holds no audio and no transcript, but read it first in case it names a file or folder you would rather keep private.

## Making a change

1. Fork the repository and create a branch.

2. Build with `make app SIGN_IDENTITY=-` and try your change in `dist/Tiro.app`.

3. Open a pull request that says what changed and why.

Please keep pull requests focused on one change. For anything larger than a fix, open an issue first so we can agree on the approach.

## Code style

- Tabs for indentation.
- Comments only where the code cannot speak for itself.
- Every string a user sees goes through `String(localized:)` or a SwiftUI string literal, with the English text as the key. Run `make strings` to add new keys to `Resources/Localizable.xcstrings`.

## Translations

Tiro ships in English and French. To add a language, add it to `CFBundleLocalizations` in `Resources/Info.plist` and translate `Resources/Localizable.xcstrings` and `Resources/InfoPlist.xcstrings` (Xcode opens both).

## License

By contributing, you agree that your contribution is released under the MIT License.
