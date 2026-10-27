# Clipsight

A macOS clipboard manager that understands what you copied. It keeps your clipboard history, and it also decodes tokens, cleans links, guards secrets and finds things by what they mean. Everything stays on your Mac.

Press **⇧⌘V** anywhere to open it.

## What makes it different

- **X-ray.** Clipsight works out what each clip is and shows what's inside:
  - JWTs: claims, expiry and whether the token is still valid.
  - Timestamps: local time, UTC and relative time, for Unix seconds, milliseconds and ISO 8601.
  - Colours: a swatch, plus Hex, RGB, HSL and SwiftUI values.
  - Links: host, path and every query parameter.
  - JSON: formatted. Base64: decoded.
  - Every value has a copy button.
- **Secret Shield.** API keys (AWS, GitHub, GitLab, Slack, Stripe, OpenAI, Anthropic, Google, npm and more), private keys, JWTs, card numbers, passwords in URLs and credentials in `.env` lines are:
  - masked, and never written to disk;
  - forgotten after 90 seconds, and also cleared from the system clipboard if they're still on it.
- **Clean Links.** Tracking parameters such as `utm_*`, `fbclid` and `gclid` are removed the moment you copy a link.
- **Search by meaning.** Type "restart the server" to find `kubectl rollout restart deployment/api`. This uses Apple's on-device language model.
- **Searchable screenshots.** Text in copied images is recognised on the Mac, so a screenshot can be found by its words.
- **Transforms.** Change case (camelCase, snake_case, kebab-case and more), sort or dedupe lines, URL- and Base64-encode or decode, and format or minify JSON. Only transforms that would change something are offered.

## Install

1. Download **Clipsight-1.0.dmg** from the [latest release](https://github.com/Debarghya-Banerjee/clipsight/releases/latest).
2. Open it and drag Clipsight onto the Applications folder.
3. Open Clipsight from Applications. It lives in the menu bar.

Clipsight isn't notarised by Apple, so the first time you open it macOS says it can't verify the developer. Go to **System Settings › Privacy & Security**, scroll down, and click **Open Anyway** next to Clipsight. You only need to do this once.

If you're comfortable with Terminal, this removes the warning instead:

```sh
xattr -dr com.apple.quarantine /Applications/Clipsight.app
```

Clipsight needs macOS 15 or later and runs natively on Apple silicon and Intel Macs.

## Using it

| Key | Action |
| --- | --- |
| ⇧⌘V | Open or close Clipsight (changeable in Settings) |
| ↩ | Paste into the app you were using |
| ⌘↩ | Copy without pasting |
| ⌘1 to ⌘9 | Paste that result |
| ⌘P | Pin or unpin |
| ⌘⌫ | Delete |
| ⌘R | Reveal a secret |
| ⇥ | Next filter |

Pasting straight into the app you were using needs Accessibility permission. Without it, Clipsight copies the clip and you press ⌘V yourself.

Clipsight respects the [nspasteboard.org](http://nspasteboard.org) markers that password managers use, and never records from apps on its ignore list.

## Build

Requires macOS 15+ and the Swift toolchain. The Xcode Command Line Tools are enough.

```sh
./build.sh            # builds build/Clipsight.app
./build.sh --install  # also copies it to ~/Applications and launches it
scripts/make-dmg.sh   # packages build/Clipsight-<version>.dmg for release
```

An app you build yourself opens without the warning above.

History is kept in `~/Library/Application Support/Clipsight`.

## License

[MIT](LICENSE)
