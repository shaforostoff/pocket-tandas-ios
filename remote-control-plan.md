# Two-Phone Remote DJ Control (Pocket Tandas)

## Context

Pocket Tandas is a single-device tango DJ app. The goal is to let **two iPhones running the app cooperate over a wireless link** so one phone (the DJ's, with headphones for monitoring) remotely drives playback on another phone (wired to the venue speakers). Two new modes are introduced:

- **Remote Receive** — extends DJ mode. The speaker phone. It runs the normal DJ engine/queue unchanged, *exposes* its play queue and playback state to the remote, and *accepts* control commands.
- **Remote Send** — extends Explore mode. The DJ's phone. It **hides its local Play Queue** and shows a **Remote Queue** (a live mirror of the receiver's queue). From it the DJ can start playback, stop with fade (with Resume reflected while the fade is active), set the insert anchor, and reorder tracks — all on the receiver. Local prelistening on the sender stays available (headphone monitoring).

The architecture rests on one principle: **the receiver reuses all existing playback/queue logic untouched; the sender drives it by sending the same intents the local UI already issues and renders a mirror of the receiver's broadcast state.** No new playback logic is written.

### Decisions (confirmed with user)
- **Transport: MultipeerConnectivity** (uses Bluetooth + peer-to-peer Wi-Fi automatically; works with no Wi-Fi network; reliable framed `Data` messaging).
- **Sender keeps local prelistening** (browser stays Explore-like; DJ monitors on headphones).
- **Both milestones built in one pass** (Milestone 1 = remote control; Milestone 2 = track add-requests with file matching). Plan is phased for clarity, but all phases will be implemented.

---

## Architecture overview

```
   SENDER (.remoteSend, extends Explore)            RECEIVER (.remoteReceive, extends DJ)
   ┌─────────────────────────────────┐             ┌──────────────────────────────────┐
   │ BrowserView (Explore-like,       │  addTrack   │ RemoteReceiverCoordinator         │
   │   prelisten on; swipe → remote)  │ ──commands→ │   observes PlayQueue + engine.state│
   │ QueueView ← RemoteQueuePresenter │  play/stop/ │   → broadcasts RemoteSnapshot      │
   │ StopResumeBar ← RemoteQueue      │  anchor/move│   applies incoming cmds by calling │
   │ RemoteQueue (mirror)  ←──────────┼─snapshots───┤   the SAME PlayQueue/PlaybackEngine│
   │ PeerLink(role:.sender, browses)  │             │   methods the local DJ UI uses     │
   └─────────────────────────────────┘             │ PeerLink(role:.receiver, advertises)│
                                                    │ (local DJ UI still fully usable)   │
                                                    └──────────────────────────────────┘
```

New code lives in a new `Pocket Tandas/Remote/` group. Existing files get small, surgical edits (AppMode + helpers, 4 `mode ==` checks, MainScreenView wiring, QueueView/StopResumeBar source-abstraction, BrowserView swipe branch).

---

## Phase 0 — Project configuration

Edit [Pocket Tandas/Info.plist](Pocket Tandas/Info.plist) directly (same approach used for the existing `UIBackgroundModes = [audio]`):

- `NSLocalNetworkUsageDescription` (string) — required for MultipeerConnectivity discovery on iOS 14+.
- `NSBonjourServices` (array, 2 entries) — `_pt-djremote._tcp` and `_pt-djremote._udp` (service type `pt-djremote`, 11 chars, valid: ≤15, lowercase/digits/hyphen).
- `NSBluetoothAlwaysUsageDescription` (string) — MPC may use the Bluetooth peer-to-peer transport.

MultipeerConnectivity needs **no entitlement** — only `import MultipeerConnectivity`. **Verify** whether the project lists source files explicitly in `project.pbxproj` (check how `PreListenPlayer.swift`/`BrowserState.swift` appear). If so, every new `.swift` file below must be added to the `PBXFileReference`/`PBXBuildFile`/`PBXGroup`/`PBXSourcesBuildPhase` for the `Pocket Tandas` target; if it uses synchronized file groups, no pbxproj edit is needed.

---

## Phase 1 — Transport: `Remote/PeerLink.swift`

`@Observable final class PeerLink: NSObject` (plain `@Observable`, **not** `@MainActor` — matches the repo's "observable-not-mainactor" rule; MPC delegate callbacks arrive off-main, so hop to `DispatchQueue.main.async` before mutating observed state, exactly like `PlaybackEngine`/`PreListenPlayer` do today).

- Wraps `MCSession` (`encryptionPreference: .required`), `MCNearbyServiceAdvertiser`, `MCNearbyServiceBrowser`. `MCPeerID(displayName: UIDevice.current.name)`. Shared service-type constant `"pt-djremote"`.
- `enum Role { case receiver, sender }`.
- Observed: `connectionState` (`.idle/.advertising/.browsing/.connecting/.connected(name)/.disconnected`), `discoveredPeers: [MCPeerID]`.
- API: `startAdvertising()` / `startBrowsing()` / `invite(_:)` / `disconnect()` / `stop()`; `send(_ message: RemoteMessage)` → JSON-encode → `session.send(data, toPeers: session.connectedPeers, with: .reliable)`.
- `var onReceive: ((RemoteMessage) -> Void)?` — set by the coordinator (receiver) / RemoteQueue (sender). Decode in `session(_:didReceive:fromPeer:)`.
- Implements `MCSessionDelegate`, `MCNearbyServiceAdvertiserDelegate`, `MCNearbyServiceBrowserDelegate`. Receiver auto-accepts a single peer (optionally surfaces the inviter's `displayName` for an accept prompt — a reasonable default is auto-accept first peer, reject additional ones to keep it 1:1).

---

## Phase 2 — Message protocol: `Remote/RemoteMessage.swift` (+ `RemoteWireTypes.swift`)

One `enum RemoteMessage: Codable` carrying both directions; each side ignores messages meant for the other. JSON encoding (debuggable, version-tolerant; snapshots are small).

```swift
enum RemoteMessage: Codable {
    // sender → receiver
    case requestPlay(itemID: UUID)
    case stopWithFade
    case resumeFromFade
    case setAnchor(itemID: UUID?)          // nil clears
    case move(itemIDs: [UUID], toOffset: Int)
    case removeItems(itemIDs: [UUID])
    case addTracks([TrackAddRequest])      // Milestone 2
    case requestSnapshot                   // resync on (re)connect
    // receiver → sender
    case snapshot(RemoteSnapshot)          // on structural change
    case progress(RemoteProgress)          // lightweight, on timer (elapsed/duration)
    case addTrackResult(resolved: Int, failed: Int)   // Milestone 2 feedback
}
```

Wire value types:
```swift
struct RemoteQueueItem: Codable, Identifiable, Hashable {
    let id: UUID; let title: String; let artist: String?
    let detail: String?; let isAnchor: Bool   // detail prebuilt by receiver
}
struct RemotePlaybackState: Codable, Hashable {
    enum Kind: String, Codable { case idle, playing, fadingOut, paused }
    let kind: Kind; let currentItemID: UUID?
}
struct RemoteProgress: Codable, Hashable { let itemID: UUID?; let elapsed: TimeInterval; let duration: TimeInterval; let seq: UInt64 }
struct RemoteSnapshot: Codable, Hashable { let items: [RemoteQueueItem]; let playback: RemotePlaybackState; let seq: UInt64 }
struct TrackAddRequest: Codable, Hashable {   // Milestone 2
    let relativePath: String; let artist: String?; let title: String?; let dateText: String?; let year: Int?
}
```

- Commands use **UUID identity**, never indices — the receiver resolves against its *current* array (it owns truth), mirroring how the local UI passes `QueueItem` identity today.
- The receiver builds `RemoteQueueItem.title/artist/detail` from `MetadataService.snapshot(forKey:)` (filename fallback), reusing the same formatting `TrackDisplay` produces — so the sender needs **no** metadata to render the mirror. Extract a tiny shared detail-formatter so wire format and local rows stay consistent.
- **Split heavy `snapshot` (structural changes) from light `progress` (timer ticks)** so the ~4 Hz countdown updates don't reserialize the whole queue — important for battery/bandwidth. Monotonic `seq` lets the sender drop stale/out-of-order messages.

---

## Phase 3 — Receiver: `Remote/RemoteReceiverCoordinator.swift`

`@Observable final class RemoteReceiverCoordinator`, created screen-scoped only in `.remoteReceive`. Holds the env `PlayQueue`, `PlaybackEngine`, `MetadataService`, `LibraryStore`, and a `PeerLink(role: .receiver)`.

- **Observe → broadcast:** re-arming `withObservationTracking` over `queue.items`, `queue.anchorID`, `engine.state`; build `RemoteSnapshot` (incrementing `seq`) → `link.send(.snapshot(...))`. Debounce bursts (~50 ms / one per runloop turn) to avoid spamming during multi-insert. A repeating timer (~3–4 Hz, while playing/fading) sends `.progress` sampled from `engine.currentElapsed`/`currentDuration` (these are `@ObservationIgnored`, hence the timer).
- **Do not** overwrite `engine.onStateChange` — it's already used by `NowPlayingController`. Observe `engine.state` (an observed `private(set) var`) instead, so both react independently.
- **Apply incoming commands** by calling the same methods the local UI calls, resolving wire UUIDs against the live queue (reuse [PlayQueue.item(withID:)](Pocket Tandas/Models/PlayQueue.swift:134), [index(of:)](Pocket Tandas/Models/PlayQueue.swift:130)):
  - `.requestPlay(id)` → `engine.requestPlay(item)`
  - `.stopWithFade` / `.resumeFromFade` → same on engine (the fade duration is the **receiver's** `UserDefaults` setting — document that the speaker phone's Launcher fade slider governs).
  - `.setAnchor(id)` → `queue.setAnchor(id)`
  - `.move(ids, toOffset)` → map ids → `IndexSet` of current offsets → [queue.move(fromOffsets:toOffset:pinnedID:)](Pocket Tandas/Models/PlayQueue.swift:100) with `pinnedID: engine.state.currentItemID` (existing playing-track protection applies for free).
  - `.removeItems(ids)` → map to offsets → `queue.remove(atOffsets:)` (skip `currentItemID`).
  - `.requestSnapshot` → send a full snapshot immediately.
  - `.addTracks(reqs)` → Milestone 2 (resolve each via `RemoteTrackResolver`, then `queue.enqueue` — anchor honored automatically — and `metadata.scan`).

The receiver's normal DJ UI stays fully usable; the coordinator just *also* broadcasts and applies remote commands.

---

## Phase 4 — Sender mirror: `Remote/RemoteQueue.swift`

`@Observable final class RemoteQueue`, created screen-scoped only in `.remoteSend`; holds a `PeerLink(role: .sender)`.

- Observed: `items: [RemoteQueueItem]`, `playback: RemotePlaybackState`, `progress: RemoteProgress`, `isConnected: Bool`, `lastSeq: UInt64`.
- `apply(_ snapshot:)` / `apply(_ progress:)` — drop if `seq <= lastSeq`, else replace. **Authoritative model:** never mutate the mirror except via received messages.
- Convenience read-throughs the UI needs: `anchorID` (item where `isAnchor`), `currentItemID` (`playback.currentItemID`), `isFadingOut`, `isPlaying`, `isPaused`, `elapsed`/`duration` (from `progress`).
- Intent methods that **send commands** (no local mutation): `requestPlay(id:)`, `stopWithFade()`, `resumeFromFade()`, `setAnchor(id:)`, `move(ids:toOffset:)`, `removeItems(ids:)`, `addTracks(_:)`.

`Remote/RemoteConnectionView.swift` — sender peer-picker (lists `link.discoveredPeers`, tap to invite) + a connection-status banner shown in `MainScreenView` for both remote modes.

---

## Phase 5 — Mode integration & UI

### AppMode + helpers — [Pocket Tandas/Models/AppMode.swift](Pocket Tandas/Models/AppMode.swift)
Add `case remoteSend` (extends explore) and `case remoteReceive` (extends dj), plus computed helpers so existing checks keep working without 4-way switches:
```swift
var isDJLike: Bool       { self == .dj || self == .remoteReceive }
var isExploreLike: Bool  { self == .explore || self == .remoteSend }
var isRemoteSend: Bool   { self == .remoteSend }
var isRemoteReceive: Bool{ self == .remoteReceive }
var isRemote: Bool       { isRemoteSend || isRemoteReceive }
```
(Confirm no `ForEach(AppMode.allCases)` would break — exploration found none.)

### The 4 existing `mode ==` checks
- [StopResumeBar.swift:29](Pocket Tandas/Views/StopResumeBar.swift:29) Save/Clear buttons → keep `mode == .explore` only (hide in remote-send: the local queue is hidden/untouched there).
- [StopResumeBar.swift:33](Pocket Tandas/Views/StopResumeBar.swift:33) EQ button → `mode.isDJLike` (receiver is the speaker phone; EQ applies).
- [BrowserView.swift:208](Pocket Tandas/Views/BrowserView.swift:208) `syncPrelistenListing` guard → `mode.isExploreLike` (prelistening stays in remote-send).
- [BrowserView.swift:290](Pocket Tandas/Views/BrowserView.swift:290) tap-to-audition guard → `mode.isExploreLike`.

### QueueView source-abstraction — [QueueView.swift](Pocket Tandas/Views/QueueView.swift) + [QueueRowView.swift](Pocket Tandas/Views/QueueRowView.swift)
Generalize `QueueView` to render either source via a small presenter. Define a value `QueueRowVM { id, title, artist, detail, isCurrent, isFading, isAnchor }` and a `QueuePresenting` interface: `rows`, `requestPlay(id:)`, `setAnchor(id:)`, `move(ids:toOffset:)`, `remove(ids:)`, `currentItemID`, plus `elapsed`/`duration` for the live row.
- `LocalQueuePresenter` wraps `PlayQueue`+`PlaybackEngine`+`MetadataService` (today's exact logic, including `move(...pinnedID:)`).
- `RemoteQueuePresenter` wraps `RemoteQueue` (rows already carry title/artist/detail/isAnchor; `isCurrent = id == playback.currentItemID`; mutators send commands).
- `QueueRowView` must take elapsed/duration from the presenter instead of pulling `PlaybackEngine` from the environment, so the **remote** row's countdown/progress ticks from broadcast `progress` values.
- Empty-state + header label switches "Play Queue" ↔ "Remote Queue" on `mode.isRemoteSend`.

### StopResumeBar source-abstraction — [StopResumeBar.swift](Pocket Tandas/Views/StopResumeBar.swift)
Introduce `protocol PlaybackControlling { var isPlaying/isFadingOut/isPaused: Bool; func stopWithFade(); func resumeFromFade(); func pause(); func resume() }`.
- `PlaybackEngine` conforms directly (free — it already has all members).
- `RemoteQueue` conforms (state from `playback`; `stopWithFade`/`resumeFromFade` send commands).
- `.remoteSend` renders the **DJ branch** (`djControl`) bound to the `RemoteQueue`. Because the receiver continuously broadcasts `kind == .fadingOut` during its fade, the sender's button shows **Resume** and tapping it sends `.resumeFromFade` — satisfying "Resume reflected while fadeout is active, exactly like local DJ mode."

### MainScreenView wiring — [MainScreenView.swift](Pocket Tandas/Views/MainScreenView.swift)
Screen-scoped `@State` per mode (like the existing `BrowserState`), so radios run only while a remote screen is open and tear down on `onDisappear`:
- `.remoteReceive`: create `RemoteReceiverCoordinator` (bound to env services); `startAdvertising()` on appear, `stop()`/`disconnect()` on disappear. Local `QueueView` uses `LocalQueuePresenter` (receiver's DJ sees its real queue).
- `.remoteSend`: create `RemoteQueue` + `PeerLink(role:.sender)`; `QueueView` uses `RemoteQueuePresenter`; `StopResumeBar` uses `RemoteQueue` as its `PlaybackControlling`; browser stays Explore-like; the env `PlayQueue` is **never read/mutated**.
- Add `RemoteConnectionView` banner at top when `mode.isRemote`.

### LauncherView — [LauncherView.swift](Pocket Tandas/Views/LauncherView.swift)
Add two buttons (a "Remote" section): "Remote Send" → `activeMode = .remoteSend`; "Remote Receive" → `activeMode = .remoteReceive`. The existing `fullScreenCover(item:)` routes any `AppMode` to `MainScreenView(mode:)` — no change there.

---

## Phase 6 — Reorder & anchor over the wire (authoritative)

- **Reorder:** sender `onMove` → translate offsets to dragged-row UUIDs + destination → send `.move(itemIDs:, toOffset:)`. **No optimistic local reorder.** Receiver resolves ids → offsets → `queue.move(...pinnedID: currentItemID)` (rejects relocating the playing track) → observation fires → fresh `snapshot` → sender's `apply` replaces the mirror with the authoritative order. Round-trip is tens of ms; guarantees the mirror can't diverge and avoids `List` double-apply glitches. (Optimistic-with-reconcile is possible later if latency feels bad on-device.)
- **Anchor:** swipe-set on the mirror → `.setAnchor(id)` → receiver `queue.setAnchor(id)` → reflected back via `RemoteQueueItem.isAnchor`; reuse `QueueRowView`'s anchor marker. The receiver auto-dropping the anchor when its track starts ([clearAnchor(ifMatches:)](Pocket Tandas/Models/PlayQueue.swift:118)) propagates to the sender via the next snapshot — marker disappears on its own. Milestone-2 add-requests "respect the remote anchor" for free, since `queue.enqueue` already honors `anchorID`.

---

## Phase 7 — Milestone 2: track add-requests + file resolution

### Sender side — [BrowserView.swift](Pocket Tandas/Views/BrowserView.swift) `add(_:)` (lines ~310–335)
Branch on `mode.isRemoteSend`: instead of `queue.enqueue`, build `TrackAddRequest`(s) from [StableTrackID.relativePath(for:baseURL:)](Pocket Tandas/Support/StableTrackID.swift) + local `metadata.snapshot(for:)` (title/artist/dateText/year) and call `remoteQueue.addTracks(...)`. Folders/playlists expand to multiple requests preserving order (single batched `.addTracks([...])` message). Anchor is respected by the receiver.

### Receiver side — `Remote/RemoteTrackResolver.swift`
`struct RemoteTrackResolver` given `TrackAddRequest`, `LibraryStore.baseURL`, `MetadataService`, the SwiftData `ModelContainer`. Returns `URL?` via 4-step fallback:
1. **Exact relative path:** `baseURL.appending(path: req.relativePath)` if it exists and `AudioFileTypes.isAudio`.
2. **Same stem, other extensions:** for each ext in `AudioFileTypes.audioExtensions`, test `<dir>/<stem>.<ext>`; first hit wins (handles sender `.flac` vs receiver `.m4a`).
3. **Title+artist match (year disambiguates):** fetch `TrackMetadata` candidates from SwiftData, filter in Swift with `compare(options: [.caseInsensitive, .diacriticInsensitive])` (matching `DirectoryLister`'s fold behavior) on title+artist; if >1 match, narrow by `req.year`; convert the matched `trackKey` (a base-relative path) back to `baseURL.appending(path:)` (skip the `"filename|size"` fallback-key form). If the file was never scanned it won't be cached → fall through to step 4.
4. **Recursive filename-stem search:** add a recursive enumerator (new `DirectoryLister.recursiveEnumerator(under:)` or a resolver helper using `FileManager.enumerator(at: baseURL, includingPropertiesForKeys:[.isRegularFileKey], options:[.skipsHiddenFiles,.skipsPackageDescendants])`). Return the first regular file whose **stem** matches and `AudioFileTypes.isAudio` (any supported audio ext matches). Last-resort, O(library); bail on first match.

On resolve: `queue.enqueue(QueueItem(url:, trackKey: StableTrackID.key(for:url, baseURL:)))` (honors anchor) → `metadata.scan(urls:[url], baseURL:)` → broadcast picks it up. Reply `.addTrackResult(resolved:failed:)` so the sender can surface "couldn't find N tracks on receiver." Remote add resolves only within the receiver's base folder (its security-scoped access, held by `LibraryStore` for the session, already covers these).

---

## Edge cases & risks
- **Connection loss / reconnect:** on `.notConnected`, sender shows banner + auto-restarts browsing; on reconnect sends `.requestSnapshot`. Receiver keeps playing (audio is local to it) and resumes advertising. `seq` ignores stale snapshots after reconnect races. 1:1 only.
- **Backgrounding:** receiver has `UIBackgroundModes=[audio]` and keeps playing; sender (no audio bg mode; prelistening is foreground) may suspend in background — on foreground, resync via `.requestSnapshot`. Document: keep the sender app foregrounded for control.
- **Audio-session ownership:** only the receiver activates `AVAudioSession` for queue playback; the sender's `PreListenPlayer` activates the session on its *own* device for headphone monitoring — separate phones, no conflict. The sender never touches its local engine in remote-send.
- **Local queue in remote-send:** hidden and untouched; persists on disk as-is.
- **Snapshot size:** ~tens of KB JSON for 100 tracks over reliable MPC — fine. Heavy/light message split + debounce keep it light.
- **Venue collisions:** two DJ pairs nearby could discover each other — show device names in the picker (optionally a short pairing code in `discoveryInfo`). `encryptionPreference: .required`.

---

## Critical files

New (`Pocket Tandas/Remote/`): `PeerLink.swift`, `RemoteMessage.swift`, `RemoteWireTypes.swift`, `RemoteReceiverCoordinator.swift`, `RemoteQueue.swift`, `RemoteConnectionView.swift`, `RemoteTrackResolver.swift` (M2).

Edited:
- [Pocket Tandas/Info.plist](Pocket Tandas/Info.plist) — privacy strings + Bonjour services.
- [Pocket Tandas/Models/AppMode.swift](Pocket Tandas/Models/AppMode.swift) — 2 cases + helpers.
- [Pocket Tandas/Views/MainScreenView.swift](Pocket Tandas/Views/MainScreenView.swift) — mode-driven wiring, presenter selection, banner, screen-scoped lifetime.
- [Pocket Tandas/Views/QueueView.swift](Pocket Tandas/Views/QueueView.swift) + [Pocket Tandas/Views/QueueRowView.swift](Pocket Tandas/Views/QueueRowView.swift) — `QueuePresenting` adapter; elapsed/duration from presenter.
- [Pocket Tandas/Views/StopResumeBar.swift](Pocket Tandas/Views/StopResumeBar.swift) — `PlaybackControlling` abstraction; remote-send uses DJ branch on the mirror; hide Save/Clear in remote-send.
- [Pocket Tandas/Views/BrowserView.swift](Pocket Tandas/Views/BrowserView.swift) — 2 guards → `isExploreLike`; M2 swipe branch to `addTracks`.
- [Pocket Tandas/Views/LauncherView.swift](Pocket Tandas/Views/LauncherView.swift) — two new entry buttons.
- Possibly `project.pbxproj` — only if the project lists files explicitly (verify in Phase 0).

Reused as-is: [PlayQueue](Pocket Tandas/Models/PlayQueue.swift) (enqueue/move/setAnchor/item lookups), [PlaybackEngine](Pocket Tandas/Audio/PlaybackEngine.swift) (requestPlay/stopWithFade/resumeFromFade), `PlaybackState`, `MetadataService.snapshot`, `StableTrackID`, `AudioFileTypes`, `DirectoryLister`.

---

## Verification

**Two physical iPhones are required** — the iOS Simulator's MultipeerConnectivity/Bluetooth support is unreliable. Phased, each independently verifiable:

1. **Config:** add Info.plist keys; app still launches; local-network prompt appears when MPC starts.
2. **Codec unit tests** (no devices, existing XCTest target alongside `PlayQueueTests`/`PlaylistParserTests`): encode→decode round-trip for every `RemoteMessage` case; `AppMode` helper tests.
3. **Transport smoke test:** two devices discover, connect (`.connected`), round-trip `requestSnapshot`/echo.
4. **Read-only mirror:** receiver broadcasts; sender renders Remote Queue + live countdown; verify it tracks the receiver as it plays. No commands yet.
5. **Commands:** `requestPlay`; `stopWithFade`/`resumeFromFade` (confirm Resume-during-fade on the sender mirrors the receiver's `fadingOut`); `setAnchor`; `move`/`remove` (incl. rejecting a move of the receiver's playing track).
6. **Edge cases:** background/foreground the sender and resync; separate the phones to drop + reconnect; 100+ track queue for snapshot perf.
7. **Milestone 2:** `RemoteTrackResolver` unit-tested with temp dirs (mirror `PlaylistParserTests`) — all 4 fallback steps incl. extension-swap, diacritic-insensitive title/artist, year disambiguation, recursive stem search. Then end-to-end add from the sender browser on devices.
