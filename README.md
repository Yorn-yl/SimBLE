# SimBLE

English | [简体中文](README.zh-CN.md)

SimBLE is a Mac app that gives apps in the iOS Simulator real Bluetooth: they scan, connect and talk GATT to physical devices through the Mac's radio. Every exchange is logged, and pluggable decoders turn the bytes into protocol fields. It is a debugging tool only: nothing is linked into the apps you debug, and their Xcode projects stay untouched.

```
app in the Simulator ── loader ─(asks: am I switched on?)─┐
                     └─ shim ──(127.0.0.1:50505, JSON lines)── SimBLE.app ── CoreBluetooth ── device
                                                                     └─ decoder plugins (Heart Rate, your own…)
```

## Requirements

- macOS 14.4 or later on Apple Silicon
- Xcode with an iOS Simulator runtime (the simulator itself, and `xcrun` for building)

## Install

Download `SimBLE-<version>.dmg` from [Releases](../../releases), open it and drag SimBLE to Applications. The app is signed for development and not notarized, so the first time macOS blocks it: right-click the app and choose Open.

Or build it yourself from the repository root:

```bash
./build.sh
open .build/SimBLE.app
```

`./make-dmg.sh` builds and packages `.build/SimBLE-<version>.dmg`, with the version taken from `CFBundleShortVersionString` in `App/Info.plist`.

## Quick start

1. **Allow Bluetooth** when macOS asks on first launch. `build.sh` signs with your first Apple Development identity (or `SIGN_IDENTITY`) so the permission survives rebuilds; with ad-hoc signing macOS asks again after every build.
2. **Pick apps:** the sidebar lists booted iOS simulators and their installed apps. Switch an app on and it uses the bridge from its **next launch**; ↻ relaunches it.
3. **Launch the app** any way you like: Xcode Run, the simulator home screen or `simctl launch`. Apps connected to the bridge get a green dot.
4. **Quit SimBLE** to undo everything it set up in the simulators; apps launched afterwards get the simulator's normal (unsupported) Bluetooth.

Pair devices again from the simulator app the first time: pairings stored on a phone do not carry over (see [Differences from a phone](#differences-from-a-phone)).

## Decoders

Raw bytes are always kept as they are; decoders add a **decoded view** and **table columns** on top. Each decoder is a separate dynamic-library plugin, so adding or changing one never touches the app.

### Included decoders

| Plugin | Kind | Source | Decodes | Columns (hidden by default in parentheses) |
|---|---|---|---|---|
| Heart Rate | Built-in | `Decoders/HeartRate/`, self-contained, also the minimal example | Characteristic `2A37` (Heart Rate Measurement), device → app | BPM, (RR (ms)) |

`build.sh` builds into the app only the plugins in `Decoders/` that need no outside code (no `sources` file). Decoders for private protocols, or ones compiling code from another repository, can live outside this repository and be installed as user plugins (see [Adding a decoder](#adding-a-decoder)). Private code then never enters this repository, and building the app or the DMG does not need it.

### Which decoder handles a stream

- **Per stream:** a stream is one peripheral + one characteristic + one direction. On a stream's **first packet** the app asks the plugins' `accepts(_:)` in order, and the **first that returns true** decodes the stream until the peripheral disconnects or you press Reload.
- **Order:** by plugin file name, alphabetically; `Foo.dylib` comes before `HeartRate.dylib`.
- **Built-in and user plugins:** built-in ones are in the app's `Contents/PlugIns/`, user ones in `~/Library/Application Support/SimBLE/Decoders/`. **A user plugin replaces a built-in one with the same file name.**
- **No plugin accepts a stream:** it shows raw bytes only, with empty plugin columns.
- **Which plugin decoded an entry:** the inspector says "Decoded · <plugin>"; the Columns menu groups columns by plugin.
- **Two plugins accept the same stream:** the alphabetically first wins and the other never sees it, so keep `accepts` to the services or characteristics you actually decode.
- **Plugin names must be unique.** A duplicate is not loaded, and the sidebar says why.

The **Decoders** section of the sidebar:
- **List:** loaded plugins marked Built-in or User, and load problems. Built-in plugins live inside the app, so the user plugin folder stays empty until you add your own.
- **Add Plugin:** copies one or more `.dylib` files into the user plugin folder and loads them, replacing files with the same name.
- **Reload:** rescans both folders and loads what is there.
- **Open Folder:** opens the user plugin folder.
- **Right-click a plugin:** Show in Finder; user plugins can also be removed. A removed plugin stops decoding new data, but its code stays loaded until the app quits.

### Adding a decoder

1. **Create a folder** named after the plugin file, for example `Foo/`:
   - `Decoders/Foo/` in this repository: committed with it, and built into the app when self-contained.
   - Anywhere else, such as `~/Code/MyDecoders/Foo/`: suits private protocols and stays out of this repository.
2. **Write the adapter** in `*.swift` files; start from the template below or `Decoders/HeartRate/`.
3. **(Optional) Reuse existing decoding code** from another project with a `sources` file in the folder:
   ```
   # Root for relative paths; without this line it is the plugin folder, and SOURCES_ROOT overrides it
   root ~/Code/SomeProject
   Sources/Protocol/FrameDecoder.swift
   Sources/Protocol/Header.swift
   ```
   - One Swift file per line: relative paths resolve against the root above, absolute ones are used as they are, and lines starting with `#` are comments.
   - The files compile into the same module as the adapter, so `internal` types are usable without changing the other project. Rebuild the plugin after that project changes branch and decoding follows.
   - They must build for macOS. Foundation-only protocol and model code usually does; code that needs UIKit or iOS-only binary SDKs does not.
4. **Build and install:**
   ```bash
   ./make-decoder.sh Foo                         # a plugin under Decoders/, by name
   ./make-decoder.sh ~/Code/MyDecoders/Foo       # a plugin elsewhere, by path
   ```
   This writes `~/Library/Application Support/SimBLE/Decoders/Foo.dylib`; press **Reload** in the sidebar and each stream switches to it on its next packet, no restart needed. Pass an output folder (`./make-decoder.sh Foo ~/Desktop`) to only build the dylib and install it with Add Plugin.
5. **(Optional) Make it built-in:** a plugin under `Decoders/` without a `sources` file is built into the app by `build.sh`.

`make-decoder.sh` compiles in Swift 6 mode; set `DECODER_SWIFT_VERSION=5` for sources that only build in Swift 5. Run `build.sh` once before the first `make-decoder.sh`: it builds the interface library plugins link against.

Template:

```swift
import Foundation
import SimBLEDecoderKit

// Fixed entry point; keep the name.
@_cdecl("simble_make_decoder_plugin")
public func makeDecoderPlugin() -> UnsafeMutableRawPointer {
    exportDecoderPlugin(FooDecoderPlugin())
}

final class FooDecoderPlugin: DecoderPlugin {
    let name = "Foo"                                   // shown in the UI and keys the saved column layout; keep it stable
    let columns: [DecoderColumn] = [
        DecoderColumn(id: "command", title: "Command"),
        DecoderColumn(id: "length", title: "Length", isVisibleByDefault: false),
    ]

    func accepts(_ context: PacketContext) -> Bool {
        context.service == "12345678-1234-1234-1234-123456789ABC"   // only your own traffic
    }

    func makeDecoder(for context: PacketContext) -> PacketDecoder {
        FooStreamDecoder()                             // one instance per stream
    }
}

final class FooStreamDecoder: PacketDecoder {
    private var buffer = Data()                        // reassembly state lives in the instance

    func decode(_ data: Data) -> [DecodedMessage] {
        buffer.append(data)
        guard buffer.count >= 2 else { return [] }     // frame not complete yet
        let frame = buffer
        buffer.removeAll()
        return [DecodedMessage(
            columns: ["command": String(format: "0x%02X", frame[0]), "length": "\(frame.count)"],
            fields: [DecodedField("Command", String(format: "0x%02X", frame[0])), DecodedField("Payload", frame.simbleHex)],
            isError: false
        )]
    }
}
```

### Interface (`DecoderKit/DecoderKit.swift`)

- **`PacketContext`** describes a stream.
  - `service` and `characteristic` are uppercase UUID strings as CoreBluetooth's `uuidString` prints them: the full 128-bit form for custom UUIDs, 4 hex digits for SIG ones such as `2A37`.
  - `direction` is `.toDevice` (app → device: writes) or `.fromDevice` (device → app: notifications and read responses).
- **`PacketDecoder.decode(_:)`**
  - Called once per packet; returns every message that packet **completes**, or an empty array while a frame is still arriving.
  - An instance is only called from one queue at a time. Keep it fast: notification streams can reach hundreds of packets per second.
- **`DecodedMessage`**
  - `columns`: short table values keyed by `DecoderColumn.id`. The table shows the first message of each packet.
  - `fields`: inspector lines in order; values may span lines.
  - `isError`: when true, the row's plugin columns turn red, for example for a failure status.
- **`DecoderColumn.id`:** the user's column visibility, order and widths are stored by plugin name + column ID, so **renaming one adds a new column**. Same-titled columns from two plugins get the plugin name appended.
- **`Data.simbleHex`:** space-separated lowercase hex, handy for `fields`.
- **Compatibility:** the interface library is built with library evolution, so additive changes keep existing plugins loading; removing or changing existing API needs plugins rebuilt.
- **Crashes:** plugins run inside the app process, so a crashing decoder takes the app down with it.

## Logs

- **What is logged:** per app, everything: app connect and disconnect, scans and advertisements, connections, service and characteristic discovery, notification changes, reads, writes and notifications, with their raw bytes.
- **Table:** a native `NSTableView`, newest first by default, showing the newest N matching entries (50/100/200/500/1000 from the toolbar, 200 by default). Filtering, search and export always cover the whole history.
  - Select an app in the sidebar to see only its entries, or All Apps for everything.
  - Click a header to sort: numbers sort numerically, `0x…` values as hex, and empty cells last either way.
  - Choose columns from the Columns menu or by right-clicking the header; drag a header to reorder.
  - Follow keeps the newest entry in view while sorted by time and while you are at that end; scroll away or select an older row to pause it. A selected row stays listed while newer entries arrive.
- **Inspector:** switches between Raw (hex), Decoded (fields) and Both.
- **History:**
  - Accumulates across launches in `~/Library/Application Support/SimBLE/logs.sqlite`, with the raw bytes and the decoded messages as they were logged. The newest 1,000,000 entries are kept and the newest 200,000 are loaded.
  - Clear deletes the history too, after a confirmation; it cannot be undone.
- **Text log:**
  - The same entries are appended as text to `~/Library/Logs/SimBLE/bridge.log`, which moves to `bridge.1.log` past 50 MB.
  - Export saves every entry matching the current filters, not only the rows shown, in the same format, with full raw bytes and decoded fields.
- **Pause:** freezes the table while entries keep being collected.

## How apps get the bridge

- **Loader (`Loader/SimBLELoader.c`):**
  - While SimBLE runs, it sets `DYLD_INSERT_LIBRARIES` in every booted simulator's launchd to this small C library.
  - Every new simulator process loads it. Apple processes return immediately; other apps ask the Mac app whether this simulator + bundle ID is switched on, and only then load the shim.
- **LLDB hook (`lldb/sim_ble_inject.py`):**
  - Xcode sets `DYLD_INSERT_LIBRARIES` itself for Run, which hides the simulator-wide value.
  - So `~/.lldbinit` imports this hook, which loads the loader at `UIApplicationMain`, before the app creates a central.
  - It does nothing when SimBLE is not running or the target is not a simulator app.
- **Shim (`Shim/SimBLEShim.m`):**
  - Turns every `CBCentralManager` the app allocates into a subclass that forwards to the Mac app.
  - Peripherals, services and characteristics are local stand-ins filled from bridge events.
  - Delegate callbacks arrive on the queue the app passed.
- **Setup on launch:** the Mac app copies the loader, shim and hook to `~/Library/Application Support/SimBLE/` and points `~/.lldbinit` there, so moving or rebuilding the app keeps working. Delete the `sim_ble_inject.py` line from `~/.lldbinit` to remove the hook.

## Differences from a phone

- **Peripheral identifiers** are the Mac's, not the phone's. Pairings stored on a phone do not carry over; bonding happens between the device and the Mac.
- **Not bridged:**
  - Descriptors (notifications still work through `setNotifyValue`).
  - L2CAP, connection events, state restoration, `didModifyServices`.
- **Write flow control:** `canSendWriteWithoutResponse` is always true; the Mac app queues writes against the Mac peripheral's flow control instead.
- **Duplicate UUIDs:** services and characteristics are matched by UUID, so a peripheral exposing the same UUID twice is not supported.
- **Timing and background:** timing, MTU and throughput are the Mac's plus a localhost hop, and background behavior is not represented.

## Troubleshooting

- **The sidebar says the port is in use:** another process holds port 50505; stop it and relaunch SimBLE.
- **Mac Bluetooth is not On:** allow SimBLE in System Settings › Privacy & Security › Bluetooth.
- **An app has no green dot:**
  1. Check that its switch is on for that simulator, then relaunch it with ↻.
  2. For Xcode Run, look for `[SimBLE]` lines in the Xcode console; if there are none, restart Xcode so it rereads `~/.lldbinit`.
- **A decoder does not apply:**
  1. Check the sidebar's Decoders section for the plugin and any load problem.
  2. Compare `accepts` with the service / characteristic in the log's Detail column (enable it from the Columns menu). Custom UUIDs appear as they are; SIG ones appear by name there, such as `Heart Rate` for `180D`, while `accepts` receives the 4-digit hex.
  3. Make sure no alphabetically earlier plugin accepts the stream first.

## Repository layout

```
App/                 the Mac app (SwiftUI and AppKit)
DecoderKit/          decoder interface shared by the app and plugins
Decoders/<Name>/     decoder plugins kept in this repository: adapter + optional sources list
Loader/  Shim/       the loader and shim injected into the simulator
lldb/                LLDB hook for Xcode Run
build.sh             builds the app, the interface library and the self-contained plugins
make-decoder.sh      builds one plugin and installs it into the user plugin folder
make-dmg.sh          builds and packages .build/SimBLE-<version>.dmg
Icon/                app icon: draw-icon.swift draws it, make-icon.sh rebuilds AppIcon.icns (committed)
```

## License

[MIT](LICENSE)
