# ThinkerChat Remote Controller

A Flutter mobile app for controlling a remote PC over a WebSocket relay. It provides
a multi-shell terminal, a file browser with upload/download/preview, a live system
dashboard, and screen sharing with remote mouse/keyboard input.

## Features

- **Terminal** — multiple shells (xterm), an input bar or raw-keyboard mode, persistent
  command history with up/down recall, a special-keys toolbar (Ctrl/arrows/Tab/Esc…),
  adjustable font size, local session-history restore, and automatic shell re-attach
  after a reconnect.
- **Files** — browse, filter/sort (type, name, size) with a hidden-file toggle, upload
  (streamed in 512 KB chunks, with an overwrite prompt), download (streamed straight to
  disk, with timeout, integrity check and one-tap retry), inline preview of images and
  UTF-8 text, live transfer speed/ETA, and a downloads manager.
- **System** — CPU/memory/disk/network/GPU cards polled every 3 s while the tab is visible,
  with rolling sparkline history for CPU, memory and network, plus a staleness notice when
  the agent stops answering.
- **Screen** — JPEG-frame screen share with tap/double-tap/scroll input, a remote keyboard
  bar, adjustable FPS/quality, a live fps/bitrate readout with stall detection, and
  one-tap screenshot capture.
- **Security** — username/password login with optional TOTP 2FA; tokens stored in the
  platform secure storage (Android `EncryptedSharedPreferences`, iOS keychain); HTTPS/WSS
  enforced for public servers; automatic session-expiry detection with guided re-login.

## Architecture

- **State**: `provider` (`ChangeNotifier`) — `AuthService`, `WsService`, `ThemeService`.
- **Transport**: a single `WsService` WebSocket with auto-reconnect (exponential backoff),
  heartbeat, a connect timeout, and a staleness watchdog. Tabs subscribe to typed messages
  via `ws.on(type, cb)`; every tab re-syncs its server-side state on `_connected`.
- **Auth/REST**: `AuthService` talks to `/api/login`, `/api/login/2fa`, `/api/change-password`,
  and `/api/2fa/*`; the bearer token is then used to open `wss://<host>/ws/client`.
  A 401 from any REST call, an already-expired JWT, or repeated WS rejections all route the
  app back to the login screen with a "session expired" notice instead of an endless
  reconnect loop.
- **UI**: `HomeScreen` hosts four tabs in an `IndexedStack`; theming is data-driven
  (`AppThemeData`) with five built-in palettes.

```
lib/
  main.dart                 App root, providers, routes, session-expiry wiring
  screens/                  splash, login, home
  services/                 auth, ws, theme, terminal_history, command_history, server_history
  widgets/                  terminal / files / dashboard / screen tabs, settings,
                            banner, sparkline, downloads sheet
```

## Requirements

- Flutter **3.24.5** (stable), Dart SDK **^3.5.4**
- Android **compileSdk/targetSdk 35**, AGP **8.3.2**, Gradle **8.4**
  (`file_picker` pulls in a plugin compiled against SDK 35; SDK 34 fails to build)

## Build & Run

```bash
flutter pub get
flutter run                 # debug on a connected device/emulator
flutter analyze             # static analysis (should report no issues)
flutter test                # widget/unit tests
flutter build apk --release # or: flutter build ipa --release
```

On first launch, enter your relay **Server URL** (HTTPS is assumed if no scheme is given),
then your username/password (and TOTP code if 2FA is enabled). Previously used servers are
offered from the history icon in the Server URL field.

## Session persistence

Auth tokens live in `flutter_secure_storage`. Two Android-specific settings keep sessions
from being silently lost:

- `AndroidOptions(encryptedSharedPreferences: true)` — the legacy Keystore-wrapped path
  intermittently fails to decrypt (`BAD_DECRYPT`), which used to log the user out at random.
  Values written by older app versions are migrated on first read.
- `android:allowBackup="false"` + `data_extraction_rules.xml` — auto-backup restores the
  encrypted prefs *without* the Keystore key that decrypts them, so a restored install would
  start with undecryptable data.

Storage reads are retried and never throw into the splash screen: any failure degrades to
"logged out" rather than a stuck launch.

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
  cleared from Settings, as can the command history.
- Server-coordinated hardening still recommended: move the WS bearer token out of the URL
  query string into a header/subprotocol, add a server-side logout/token-revocation endpoint,
  certificate pinning, and server-side rollback of aborted uploads.
