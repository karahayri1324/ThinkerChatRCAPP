# ThinkerChat Remote Controller

A Flutter mobile app for controlling a remote PC over a WebSocket relay. It provides
a multi-shell terminal, a file browser with upload/download/preview, a live system
dashboard, and screen sharing with remote mouse/keyboard input.

## Features

- **Terminal** — multiple shells (xterm), an input bar or raw-keyboard mode, a special-keys
  toolbar (Ctrl/arrows/Tab/Esc…), adjustable font size, and local session-history restore.
- **Files** — browse, upload (chunked), download (chunked, with timeout + integrity check),
  and inline preview of images and UTF-8 text.
- **System** — CPU/memory/disk/network/GPU cards polled every 3 s while the tab is visible.
- **Screen** — JPEG-frame screen share with tap/double-tap/scroll input, a remote keyboard
  bar, and adjustable FPS/quality.
- **Security** — username/password login with optional TOTP 2FA; tokens stored in the
  platform secure storage; HTTPS/WSS enforced for public servers.

## Architecture

- **State**: `provider` (`ChangeNotifier`) — `AuthService`, `WsService`, `ThemeService`.
- **Transport**: a single `WsService` WebSocket with auto-reconnect (exponential backoff),
  heartbeat, and a staleness watchdog. Tabs subscribe to typed messages via `ws.on(type, cb)`.
- **Auth/REST**: `AuthService` talks to `/api/login`, `/api/login/2fa`, `/api/change-password`,
  and `/api/2fa/*`; the bearer token is then used to open `wss://<host>/ws/client`.
- **UI**: `HomeScreen` hosts four tabs in an `IndexedStack`; theming is data-driven
  (`AppThemeData`) with five built-in palettes.

```
lib/
  main.dart                 App root, providers, routes
  screens/                  splash, login, home
  services/                 auth, ws, theme, terminal_history
  widgets/                  terminal / files / dashboard / screen tabs, settings, banner
```

## Requirements

- Flutter **3.24.5** (stable), Dart SDK **^3.5.4**

## Build & Run

```bash
flutter pub get
flutter run                 # debug on a connected device/emulator
flutter analyze             # static analysis (should report no issues)
flutter test                # widget/unit tests
flutter build apk --release # or: flutter build ipa --release
```

On first launch, enter your relay **Server URL** (HTTPS is assumed if no scheme is given),
then your username/password (and TOTP code if 2FA is enabled).

## Transport security

Public servers must use **HTTPS/WSS**. Cleartext `http://`/`ws://` is permitted only for
local development hosts (`localhost`, `127.0.0.1`, and the Android emulator host `10.0.2.2`)
via `android/app/src/main/res/xml/network_security_config.xml` and the iOS ATS exceptions
in `ios/Runner/Info.plist`.

## Release signing (Android)

Release builds use the debug keystore unless you provide a real one. To sign properly,
create `android/key.properties` (git-ignored):

```properties
storeFile=/absolute/path/to/release.jks
storePassword=********
keyAlias=********
keyPassword=********
```

The build automatically picks it up; with no `key.properties` present it falls back to debug
signing so `flutter run --release` keeps working.

## Notes

- Terminal output is cached locally (`shared_preferences`) for session restore and can be
  cleared from Settings.
- Server-coordinated hardening still recommended: move the WS bearer token out of the URL
  query string into a header/subprotocol, add a server-side logout/token-revocation endpoint,
  certificate pinning, and server-side rollback of aborted uploads.
