<div align="center">

# 🔔 Ntfy for Mac

**A beautiful, native macOS menu-bar client for [ntfy](https://ntfy.sh).**

Subscribe to any ntfy topic — on `ntfy.sh` or your own self-hosted server — and
get rich native macOS notifications the moment a message arrives. Runs quietly
in the background and reconnects automatically.

📖 中文使用说明与注意事项：[**docs/使用说明.md**](docs/使用说明.md)

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
  `since` cursor. Direct connections race IPv4/IPv6 candidates with Happy
  Eyeballs while preserving the hostname for TLS SNI.
- **On-demand connection diagnostics** — the tiny status dot opens the real
  remote IP, address family, resolver source, TLS SNI, latency, keepalive
  timing, retries and the last error.
- **Per-topic filters** — only get notified for chosen priorities / tags.
- **Quiet hours and temporary pause** — suppress macOS alerts without stopping
  message synchronization or changing unread state.
- **Configuration backup and migration** — export/import subscriptions and
  settings without passwords, tokens, history or sync cursors in the file.
- **Publish messages** to a topic right from the app (title, priority, tags,
  click URL, scheduled delivery, attachments, Markdown).
- **Launch at login** via the modern `SMAppService` API.
- **Message history** with search, read/unread state, and mute.

## 🖥 Requirements

- macOS 13 (Ventura) or later
- Xcode 15 or later (to build)

## 📥 Download (prebuilt DMG)

Every push to `main` runs smoke tests, builds the app, and updates the
[Latest build prerelease](https://github.com/wangty163/mac_ntfy/releases/tag/latest)
on the **Releases** page with `NtfyMac.dmg`. After testing locally, just run
`git push origin main`; no version tag or manual release is needed.

The `latest` tag and DMG are replaced by each successful current `main` build.
The release notes link to its source commit and CI run. Failed builds and
reruns of older commits do not replace the download. The app uses ad-hoc
signing, without an Apple Developer ID certificate.

Builds also retain `.app` and `.dmg` artifacts in the **Actions** tab. Pushes
to `claude/**` and pull requests targeting `main` build artifacts only.
Tagged `v*` releases continue to publish separate versioned DMGs and remain
the stable releases.

Because the builds lack a **Developer ID signature**, macOS Gatekeeper may block the first launch.
Right-click (or Control-click) the app → **Open** → **Open**. You only need to
do this once; afterwards it launches normally.

## 🏷 Cutting a release

The steps below are for a stable versioned release. The `latest` development
prerelease is updated automatically by the **Build** workflow.

The **Release** workflow (`.github/workflows/release.yml`) builds a Release
`.app`, packages it into `NtfyMac-<version>.dmg`, and publishes a GitHub
Release with the DMG attached. Trigger it either way:

**A. From the GitHub UI** — *Actions* → **Release** → **Run workflow** → set
`tag` to e.g. `v1.0.0` → **Run workflow**. The tag is created at the chosen
commit automatically (no `git push --tags` needed).

**B. By pushing a tag** — from a clone with push access:

```bash
git pull origin main
git tag v1.0.0
git push origin v1.0.0          # triggers the Release workflow
```

Both produce an identical release. Use [semver](https://semver.org/) tags
(`vMAJOR.MINOR.PATCH`); release notes are generated automatically. The release
workflow also writes that tag into the app bundle, so the same version appears
in **Settings → About** inside the app.

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

> 中文用户可参阅 [**docs/使用说明.md**](docs/使用说明.md)，内含按「核心流程 →
> 进阶功能 → 注意事项」分级整理的完整指南。

## 🛠 Troubleshooting notes

### Browser opens the server, but the app says “The network connection was lost”

Some self-hosted or reverse-proxied ntfy deployments are reachable only because
the Mac has a custom `/etc/hosts` entry, for example mapping an internal ntfy
hostname to a LAN IP. In that situation, Safari/Chrome may open the URL while a
long-lived `URLSession` stream still reports `NSURLErrorNetworkConnectionLost`.

Lessons learned from debugging this case:

- Treat “browser works” as a hint, not proof that every HTTP client resolves and
  routes the hostname the same way. Always check whether `/etc/hosts`, VPN,
  proxy, or split-DNS rules are involved.
- In **Direct** mode, resolve a fresh set of candidate addresses for every
  attempt and race IPv4/IPv6 connections 250 ms apart. An explicit
  `/etc/hosts` mapping is authoritative; otherwise current system-DNS
  candidates are used. The winning socket retains the original hostname for
  TLS SNI, certificate verification, and the HTTP `Host` header.
- Apply the same fallback to all ntfy network paths: subscription streams, the
  add/edit subscription **Test** button, and publishing. Otherwise one action can
  appear fixed while another still fails.
- Keep the configured server URL on the hostname, not the raw IP, especially for
  HTTPS. Certificates and reverse-proxy routing typically expect the hostname
  listed in `/etc/hosts`.
- If the app stays offline after being closed for a long time, also consider a
  stale `since` cursor. ntfy only caches messages for a limited time, so the app
  clears a rejected saved cursor and reconnects without it.

### The server's IP changed but the app stays offline (browser still works)

When a self-hosted server changes IP (dynamic DNS, failover, ISP reassignment),
the system resolver can temporarily return a mixture of old/new A and AAAA
records. Browsers usually hide that with fast IPv4/IPv6 racing, while a
long-lived client can remain stuck on one unreachable address.

Keep the configured server URL on the hostname, including any non-standard port
(e.g. `https://ntfy.example.com:8443`). If `/etc/hosts` contains that hostname,
the app treats those addresses as authoritative while keeping the hostname for
TLS SNI and certificate checks. The app also watches `/etc/hosts` and reconnects
when it changes. Without a hosts mapping, it freshly resolves all system-DNS
candidates and races the two address families.

Click the small status dot beside a subscription to see which address actually
won, whether it came from `/etc/hosts` or DNS, and the most recent keepalive or
retry error. **Copy Report** produces a credential-free diagnostic summary.

### Topics go offline while Clash/Surge (system proxy) is running

When a proxy tool like Clash Verge enables the macOS **system proxy**,
`URLSession` auto-detects it and forces every request — including the
long-lived notification stream — through the local proxy. That breaks in ways a
browser test won't show: the proxy may buffer or stall streaming responses, and
it resolves hostnames itself, so local `/etc/hosts` overrides are lost. A
DIRECT rule for the ntfy server in the proxy's config does **not** help,
because the connection still enters the proxy first.

The app therefore controls proxying explicitly via **Settings → General →
Proxy** instead of relying on system-proxy auto-detection:

- **Direct (ignore system proxy)** — the default. Connects straight to the
  server even while a system proxy is active.
- **System proxy** — the old auto-detect behavior, for setups where it works.
- **Custom proxy** — route all ntfy traffic through an explicit HTTP (CONNECT)
  or SOCKS5 proxy that is known to handle streaming, e.g. Clash's mixed/SOCKS
  port. This is the reliable choice when the ntfy server itself must be
  reached through the proxy.

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
│  ├─ HostsMappedHTTPClient.swift  direct HTTP transport + IPv4/IPv6 racing
│  ├─ ProxyConfig.swift      explicit proxy mode (direct/system/custom)
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
