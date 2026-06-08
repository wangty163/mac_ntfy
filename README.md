<div align="center">

# 🔔 Ntfy for Mac

**A beautiful, native macOS menu-bar client for [ntfy](https://ntfy.sh).**

Subscribe to any ntfy topic — on `ntfy.sh` or your own self-hosted server — and
get rich native macOS notifications the moment a message arrives. Runs quietly
in the background and reconnects automatically.

</div>

---

## ✨ Features

- **Native menu-bar app** — lives in the menu bar (no Dock clutter), shows an
  unread badge, and opens a polished management window on demand.
- **Subscribe to any topic** on any ntfy server, public or self-hosted.
- **Authentication** — Basic auth (username/password) and access tokens.
- **Rich native notifications** with:
  - ntfy **priority** (1–5) mapped to macOS interruption levels & sound
  - **tags → emoji** rendering (`warning` → ⚠️, `rotating_light` → 🚨, …)
  - **click actions** (open a URL when the notification is tapped)
  - **attachments** (inline image previews + download)
  - **action buttons** (`view`, `http`; `broadcast` is Android-only)
  - **Markdown** message bodies
- **Reliable background delivery** — long-lived streaming connections with
  exponential-backoff reconnect, plus automatic reconnect when the network
  returns or the Mac wakes from sleep. Missed messages are recovered via the
  `since` cursor.
- **Per-topic filters** — only get notified for chosen priorities / tags.
- **Publish messages** to a topic right from the app (title, priority, tags,
  click URL, scheduled delivery, attachments, Markdown).
- **Launch at login** via the modern `SMAppService` API.
- **Message history** with search, read/unread state, and mute.

## 🖥 Requirements

- macOS 13 (Ventura) or later
- Xcode 15 or later (to build)

## 📥 Download (prebuilt DMG)

Every push builds an unsigned `.app` **and** a `.dmg` as CI artifacts (see the
**Actions** tab → latest **Build** run → *Artifacts*). Tagged releases publish
the DMG on the **Releases** page:

```bash
git tag v1.0.0 && git push origin v1.0.0   # triggers the Release workflow
```

Because the builds are **unsigned**, macOS Gatekeeper blocks the first launch.
Either right-click the app → **Open** → **Open**, or clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine "/Applications/NtfyMac.app"
```

## 🚀 Build & Run

```bash
git clone <this-repo>
cd mac_ntfy
open NtfyMac.xcodeproj
```

In Xcode:

1. Select the **NtfyMac** scheme.
2. Set your own **Team** under *Signing & Capabilities* (any free Apple ID works
   for local running). The app uses the App Sandbox with the
   *Outgoing Network Connections* entitlement only.
3. Press **⌘R**.

Or from the command line:

```bash
xcodebuild -project NtfyMac.xcodeproj -scheme NtfyMac -configuration Release build
```

On first launch the app asks for **Notification** permission — allow it so
messages can appear as banners.

## 📲 Quick start

1. Click the 🔔 icon in the menu bar → **Open Ntfy**.
2. Click **Add Subscription**.
3. Enter a server (default `https://ntfy.sh`) and a topic name, then **Test** and
   **Subscribe**.
4. Send yourself a message to verify:

   ```bash
   curl -d "Hello from ntfy 👋" ntfy.sh/<your-topic>
   ```

   …or use the in-app **Publish** button (paper-plane icon).

## 🏗 Architecture

```
NtfyMac/
├─ NtfyMacApp.swift          App entry, MenuBarExtra + Window + Settings scenes
├─ Models/                   Wire models & app state
│  ├─ NtfyMessage.swift      ntfy JSON message + actions + attachment
│  ├─ Subscription.swift     subscription, auth, filters, stored message
│  ├─ ConnectionState.swift  per-topic connection status
│  └─ AppSettings.swift      user preferences (UserDefaults)
├─ Services/
│  ├─ NtfyConnection.swift   one streaming /json connection + auto-reconnect
│  ├─ SubscriptionManager.swift   owns subscriptions, history, monitors net/sleep
│  ├─ NotificationService.swift   UserNotifications bridge
│  ├─ NtfyPublisher.swift    publish + connection test
│  ├─ ActionRunner.swift     executes view/http action buttons
│  ├─ PersistenceStore.swift JSON persistence
│  ├─ LaunchAtLogin.swift    SMAppService wrapper
│  └─ EmojiMap.swift         tag → emoji shortcodes
└─ Views/                    SwiftUI UI + design system
```

### How background delivery works

Each subscription opens a streaming HTTP request to
`<server>/<topic>/json`, which the ntfy server keeps open and feeds
newline-delimited JSON. The client:

- reads each line, decodes it, and surfaces `message` events as notifications;
- treats `open`/`keepalive` events as health signals;
- reconnects with exponential backoff (1s → 30s, jittered) on any drop;
- reconnects immediately when `NWPathMonitor` reports the network is back or the
  workspace posts `didWakeNotification`;
- remembers the last message id per topic and reconnects with `?since=<id>` so
  nothing is missed while offline.

## 🔐 Privacy

All data (subscriptions + message history) is stored locally under
`~/Library/Application Support/NtfyMac/`. The app talks only to the ntfy
servers you configure.

## 📝 License

MIT — see headers in source files.
