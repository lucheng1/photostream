# Mac Photos LAN Streamer

Browse your Mac’s Apple Photos library on iPhone over Wi‑Fi — no iCloud upload, no Docker, no second archive.

## What’s included

| Piece | Role |
|---|---|
| **PhotoStreamServer** | macOS menu bar app: reads System Photo Library via Photos.framework, HTTP + Bonjour, PIN pairing |
| **PhotoStream iOS** | Native UICollectionView grid (2×5), flick-aware thumbs, pinch-zoom full viewer |

## Requirements

- Mac with Photos library (System Photo Library), macOS 14+
- iPhone on the **same Wi‑Fi**, iOS 17+
- **Full Xcode** to build/install the iPhone app (Command Line Tools alone are not enough for iOS)

## Continuous integration (GitHub Actions)

Workflows build both targets on `macos-15`:

| Workflow | When |
|---|---|
| [`.github/workflows/photostream.yml`](../.github/workflows/photostream.yml) | Monorepo root (`ideas`) — path filter on `photostream/**` |
| [`photostream/.github/workflows/build.yml`](.github/workflows/build.yml) | If this folder is its own GitHub repo |

Each run uploads artifacts:

- `PhotoStream-macOS` — ad-hoc signed `PhotoStream.app` zip
- `PhotoStream-iOS-Simulator` — unsigned simulator `.app` zip (device install still needs local Xcode signing)

Trigger manually: Actions → **PhotoStream** → **Run workflow**.

## 1. Start the Mac server

```bash
cd photostream
chmod +x scripts/run-mac-server.sh
./scripts/run-mac-server.sh
```

- Allow **Photos** access when prompted (System Settings → Privacy & Security → Photos).
- Click the **PS** menu bar item and note the **PIN**.
- Optionally **Copy PIN**.
- PIN is also written to `~/Library/Application Support/PhotoStream/pin.txt` for CLI testing.

Server listens on port **8787** and advertises Bonjour service `_photostream._tcp`.

### Smoke test (after pairing once)

```bash
# Pair
curl -s -X POST http://127.0.0.1:8787/v1/pair \
  -H 'Content-Type: application/json' \
  -d '{"pin":"YOUR_PIN"}'

# Use returned token
export TOKEN=...
curl -s http://127.0.0.1:8787/v1/info -H "X-PhotoStream-Token: $TOKEN"
curl -s 'http://127.0.0.1:8787/v1/assets?limit=10' -H "X-PhotoStream-Token: $TOKEN" | head
```

## 2. Build the iPhone client

```bash
./scripts/generate-ios-project.sh
```

In Xcode:

1. Select your Team under Signing & Capabilities.
2. Plug in your iPhone (Developer Mode on).
3. Run **PhotoStreamiOS**.
4. Allow **Local Network** when prompted.

On the phone: pick your Mac (or enter its LAN IP), enter the PIN, Connect.

## Client UX (v1)

- **Grid:** 2 columns; ~5 rows per screen; metadata pages ahead of images.
- **Flick:** high velocity → placeholders only; in-flight thumbs cancelled; date scrubber shows position.
- **Settle:** loads thumbs only for visible cells (+ small buffer).
- **Tap:** full-size image, pinch zoom, double-tap zoom, swipe down / Close back to grid.
- **Cache:** in-memory session only; cleared when the app goes away.

## API

- `POST /v1/pair` `{ "pin": "1234" }` → `{ "token": "..." }`
- `GET /v1/info` (auth)
- `GET /v1/assets?cursor=&limit=` (auth)
- `GET /v1/assets/{base64url(localId)}/thumb?w&h&scale` (auth)
- `GET /v1/assets/{base64url(localId)}/full` (auth)

Header: `X-PhotoStream-Token: …`

## Project layout

```
photostream/
  Package.swift          # Shared + Mac server (SwiftPM)
  Shared/                # Codable models, Bonjour constants, ID coding
  MacServer/             # Menu bar + HTTP + Photos
  iOSClient/             # SwiftUI shell + UIKit grid/viewer
  project.yml            # XcodeGen for iOS
  scripts/
```

## Out of scope (v1)

Albums, search, people, edits, internet exposure, Android.

## Troubleshooting

- **PIN DENIED / no photos:** grant Photos permission to `PhotoStream.app`, then Reload Library from the menu.
- **iPhone can’t find Mac:** enter the Mac’s IP manually; check same Wi‑Fi / client isolation on the router; allow Local Network for the app.
- **Empty library:** ensure the System Photo Library is the one on your external drive (open it once in Photos.app).
- **Port in use:** quit other PhotoStream instances; default port is 8787.
