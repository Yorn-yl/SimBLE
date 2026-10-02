# SimBLE

[English](README.md) | 简体中文

SimBLE 是一个 Mac App,让 iOS 模拟器里的 App 用上真实的蓝牙：通过 Mac 的蓝牙扫描、连接真实设备，并进行 GATT 通信。所有交互都会被记录下来，可插拔的解析器负责把字节解析成协议字段。它只用于调试，不会链接进被调试的 App,也不需要改动它的 Xcode 工程。

```
模拟器里的 App ── loader ─(询问：我的开关打开了吗?)─┐
               └─ shim ──(127.0.0.1:50505,JSON 行)── SimBLE.app ── CoreBluetooth ── 设备
                                                                 └─ 解析器插件(Heart Rate、你自己的协议…)
```

## 运行要求

- macOS 14.4 或更高版本，Apple Silicon
- Xcode 及 iOS 模拟器运行时(需要用到模拟器本身，以及编译用的 `xcrun`)

## 安装

从 [Releases](../../releases) 下载 `SimBLE-<版本>.dmg`,打开后把 SimBLE 拖进 Applications。App 用的是开发证书签名，没有经过公证，第一次打开会被 macOS 拦截，需要右键 App 选"打开"。

也可以在仓库根目录自己编译：

```bash
./build.sh
open .build/SimBLE.app
```

`./make-dmg.sh` 会编译并打包出 `.build/SimBLE-<版本>.dmg`,版本号取自 `App/Info.plist` 的 `CFBundleShortVersionString`。

## 快速开始

1. **授权蓝牙：** 第一次启动时 macOS 会请求蓝牙权限，点允许。`build.sh` 会用第一个 Apple Development 证书签名(可以用 `SIGN_IDENTITY` 指定)，这样重新编译后权限还在;如果是 ad-hoc 签名，每次编译后都要重新授权。
2. **选择 App:** 左侧栏按模拟器列出所有已启动的 iOS 模拟器和上面装的 App。打开某个 App 的开关，它**下次启动**时就会接上桥。点 ↻ 可以直接重启这个 App。
3. **启动 App:** Xcode Run、模拟器主屏幕、`simctl launch` 都可以。接上桥的 App 前面会显示绿点。
4. **退出：** 退出 SimBLE 时，它在模拟器里做的设置会全部撤销，之后启动的 App 恢复成模拟器原本的状态，也就是不支持蓝牙。

第一次在模拟器里连接设备时，要在 App 里重新配对，因为手机上存的配对记录用不了，见[与真机的差别](#与真机的差别)。

## 解析器

原始字节始终原样保留，解析器负责在这之上提供**解析视图**和**表格列**。每个解析器都是一个独立的动态库插件，新增或修改都不需要改动 App 本身。

### 自带的解析器

| 插件 | 形式 | 源码 | 负责的流量 | 提供的列(括号内为默认隐藏) |
|---|---|---|---|---|
| Heart Rate | 内置 | `Decoders/HeartRate/`,不依赖外部代码，也是最小示例 | 特征 `2A37`(心率测量)，只解析设备 → App 方向 | BPM、(RR (ms)) |

`build.sh` 只把 `Decoders/` 下不依赖外部源码的插件(目录里没有 `sources` 文件)编进 App。私有协议的解析器，或者要引用其他仓库源码的解析器，可以放在这个仓库外面，作为用户插件单独安装，见[新增一个解析器](#新增一个解析器)。这样私有代码不会进入本仓库，编译 App、打包 DMG 也不需要它们。

### 每路数据用哪个解析器

- **按"数据流"选择：** 一路数据流指"一台设备 + 一个特征 + 一个方向"。某路数据流收到**第一个包**时，App 按顺序依次询问各插件的 `accepts(_:)`,**第一个返回 true 的插件**负责这路数据流。之后这路数据流一直用它，直到设备断开或点了 Reload。
- **插件顺序：** 按插件文件名的字母顺序排，比如 `Foo.dylib` 排在 `HeartRate.dylib` 前面。
- **内置与用户插件：** 内置插件在 App 里的 `Contents/PlugIns/`,用户插件在 `~/Library/Application Support/SimBLE/Decoders/`。**文件名相同时，用户插件覆盖内置插件。**
- **没有插件接收的数据流：** 只显示原始字节，插件列为空。
- **查看某条日志用了哪个解析器：** 看检查器标题 "Decoded · 插件名";Columns 菜单里也按插件分组列出了各自的列。
- **两个插件接收了同一路数据：** 字母序靠前的会生效，另一个永远轮不到。所以 `accepts` 应该只匹配自己真正要解析的 service 或 characteristic。
- **插件名不能重复。** 名字重复的插件不会被加载，侧栏会显示原因。

侧栏的 **Decoders** 分区：
- **列表：** 列出已加载的插件，标注 Built-in(内置)或 User(用户),以及加载失败的原因。内置插件在 App 包里，所以用户插件目录在你自己添加插件之前是空的。
- **Add Plugin:** 选择一个或多个 `.dylib`,复制进用户插件目录并立即加载，文件名相同的会被替换。
- **Reload:** 重新扫描两个目录并加载。
- **Open Folder:** 打开用户插件目录。
- **右键插件：** Show in Finder;用户插件还可以选 Remove 移除。移除后该插件不再解析新数据，但已经加载进内存的代码要等 App 退出后才会释放。

### 新增一个解析器

1. **建目录：** 目录名就是插件的文件名，比如 `Foo/`。
   - 放在本仓库的 `Decoders/Foo/`:随仓库提交，不依赖外部源码时会被编成内置插件。
   - 放在仓库外的任意位置，比如 `~/Code/MyDecoders/Foo/`:适合私有协议，不会进入本仓库。
2. **写适配代码：** 在目录里写 `*.swift`,参考下面的模板或 `Decoders/HeartRate/`。
3. **(可选)引用已有的解析代码：** 如果要直接用别的项目里现成的源码，就在目录里放一个 `sources` 文件：
   ```
   # 相对路径的根目录；不写这一行时以插件目录为根，环境变量 SOURCES_ROOT 优先于它
   root ~/Code/SomeProject
   Sources/Protocol/FrameDecoder.swift
   Sources/Protocol/Header.swift
   ```
   - 每行一个 Swift 文件：相对路径按上面的规则找根目录，绝对路径原样使用，`#` 开头的行是注释。
   - 这些文件会和适配代码编进同一个模块，所以能直接访问 `internal` 类型，不用改原项目的访问级别。原项目切换分支后重新编译插件，解析就会跟着更新。
   - 这些文件必须能在 macOS 上编译。只依赖 Foundation 的协议或模型代码一般没问题;依赖 UIKit 或只提供 iOS 版本二进制 SDK 的，不能引用。
4. **编译并安装：**
   ```bash
   ./make-decoder.sh Foo                         # Decoders/ 下的插件，写插件名
   ./make-decoder.sh ~/Code/MyDecoders/Foo       # 仓库外的插件，写目录路径
   ```
   默认会生成 `~/Library/Application Support/SimBLE/Decoders/Foo.dylib`,然后点侧栏的 **Reload**,不用重启 App,各路数据流收到下一个包时就会换用新插件。也可以多传一个输出目录，比如 `./make-decoder.sh Foo ~/Desktop`,只编译出 dylib,再用 Add Plugin 安装。
5. **(可选)做成内置插件：** 放在 `Decoders/` 下、没有 `sources` 文件的插件，执行 `build.sh` 时会被编进 App。

`make-decoder.sh` 默认用 Swift 6 语言模式编译，如果引用的源码只能在 Swift 5 下编译，就设置 `DECODER_SWIFT_VERSION=5`。第一次用 `make-decoder.sh` 之前，要先执行一次 `build.sh`,它会生成插件依赖的接口库。

模板：

```swift
import Foundation
import SimBLEDecoderKit

// 固定的入口，名字不能改。
@_cdecl("simble_make_decoder_plugin")
public func makeDecoderPlugin() -> UnsafeMutableRawPointer {
    exportDecoderPlugin(FooDecoderPlugin())
}

final class FooDecoderPlugin: DecoderPlugin {
    let name = "Foo"                                   // 显示名，也是列设置的存储键，保持不变
    let columns: [DecoderColumn] = [
        DecoderColumn(id: "command", title: "Command"),
        DecoderColumn(id: "length", title: "Length", isVisibleByDefault: false),
    ]

    func accepts(_ context: PacketContext) -> Bool {
        context.service == "12345678-1234-1234-1234-123456789ABC"   // 只匹配自己的流量
    }

    func makeDecoder(for context: PacketContext) -> PacketDecoder {
        FooStreamDecoder()                             // 每路数据流一个实例
    }
}

final class FooStreamDecoder: PacketDecoder {
    private var buffer = Data()                        // 跨包拼帧的状态放在实例里

    func decode(_ data: Data) -> [DecodedMessage] {
        buffer.append(data)
        guard buffer.count >= 2 else { return [] }     // 帧还没收完就返回空
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

### 接口说明(`DecoderKit/DecoderKit.swift`)

- **`PacketContext`:** 描述一路数据流。
  - `service`、`characteristic` 是大写的 UUID 字符串，格式和 CoreBluetooth 的 `uuidString` 一致：自定义 UUID 是 128 位完整形式，SIG 标准 UUID 是 4 位十六进制，比如 `2A37`。
  - `direction` 是 `.toDevice`(App → 设备：写入)或 `.fromDevice`(设备 → App:通知和读取响应)。
- **`PacketDecoder.decode(_:)`:**
  - 每收到一个包调用一次，返回这个包**拼完整的**所有消息;帧还没收完就返回空数组。
  - 同一个实例只会在同一个队列上被调用。解析要快，通知流可能每秒上百包。
- **`DecodedMessage`:**
  - `columns`:以 `DecoderColumn.id` 为键，值是表格里显示的短文本。表格只显示每个包的第一条消息。
  - `fields`:检查器里依次显示的字段，值可以有多行。
  - `isError`:为 true 时，该行的插件列标红，比如状态码不是成功。
- **`DecoderColumn.id`:** 用户调好的列显示、顺序、宽度都按"插件名 + 列 id"保存，**改名等于新增一列**。两个插件的列标题相同时，标题后面会自动加上插件名来区分。
- **`Data.simbleHex`:** 以空格分隔的小写十六进制，方便写 `fields`。
- **兼容性：** 接口库用 library evolution 编译，新增式的改动不会让已有插件失效;删除或修改已有接口后，要重新编译插件。
- **崩溃风险：** 插件运行在 App 进程里，插件崩溃会导致整个 App 崩溃。

## 日志

- **记录内容：** 按 App 记录所有交互：App 连接和断开、扫描和广播、设备连接和断开、服务和特征发现、notify 开关、读、写、通知，以及它们的原始字节。
- **表格：** 原生 `NSTableView`,默认最新的在最上面，只显示过滤后最新的 N 条(工具栏可选 50/100/200/500/1000,默认 200)。过滤、搜索和导出始终覆盖全部历史。
  - 左侧选中某个 App 就只看它的日志，选 All Apps 看全部。
  - 点表头排序：数字按数值排，`0x…` 按十六进制排，空值始终排在最后。
  - Columns 菜单可以勾选要显示的列，右键表头也可以;拖动表头可以调整顺序。
  - Follow 在按时间排序、并且你停在最新一端时，保持显示最新的一条;往下滚或者选中较早的一行就会暂停。选中的行在新日志进来时会一直保留在列表里。
- **检查器：** 在 Raw(原始十六进制)、Decoded(解析字段)和 Both 之间切换。
- **累计存储：**
  - 日志跨启动累计保存在 `~/Library/Application Support/SimBLE/logs.sqlite`,原始字节和当时的解析结果一起保存。最多保留最新的 100 万条，表格加载最新的 20 万条。
  - Clear 会连历史一起删除，点击后会先弹框确认，删除后无法恢复。
- **文本日志：**
  - 同样的内容以文本形式追加到 `~/Library/Logs/SimBLE/bridge.log`,超过 50 MB 时轮换成 `bridge.1.log`。
  - Export 导出所有匹配当前过滤条件的日志，不只是表格里显示的那些，格式和文本日志一样，包含完整原始字节和解析字段。
- **Pause:** 冻结表格显示，期间的日志仍然会记录。

## 注入原理

- **loader(`Loader/SimBLELoader.c`):**
  - SimBLE 运行期间，会给每台已启动模拟器的 launchd 设置 `DYLD_INSERT_LIBRARIES`,指向这个很小的 C 库。
  - 模拟器里的新进程都会加载它。Apple 自己的进程直接跳过;其他 App 会问 Mac App"这台模拟器上的这个 bundle ID 有没有打开开关",打开了才加载 shim。
- **LLDB 钩子(`lldb/sim_ble_inject.py`):**
  - Xcode Run 时，Xcode 会自己设置 `DYLD_INSERT_LIBRARIES`,把模拟器级别的设置覆盖掉。
  - 所以通过 `~/.lldbinit` 引入这个钩子，在 `UIApplicationMain` 处加载 loader,这个时机早于 App 创建 central。
  - SimBLE 没运行，或目标不是模拟器 App 时，钩子什么都不做。
- **shim(`Shim/SimBLEShim.m`):**
  - 把 App 创建的每个 `CBCentralManager` 换成一个子类，操作转发给 Mac App。
  - peripheral、service、characteristic 都是按桥事件填充的本地替身。
  - delegate 回调在 App 指定的队列上触发。
- **启动时的安装步骤：** Mac App 会把 loader、shim、钩子复制到 `~/Library/Application Support/SimBLE/`,并让 `~/.lldbinit` 指向那里，所以移动或重新编译 App 都不影响注入。删掉 `~/.lldbinit` 里含 `sim_ble_inject.py` 的那一行，就能卸载钩子。

## 与真机的差别

- **设备 identifier 不同：** 是 Mac 那边的，和手机上的不一样。手机上存的配对记录用不了，绑定关系建立在设备和 Mac 之间。
- **没有桥接的功能：**
  - descriptor(notify 仍然通过 `setNotifyValue` 正常工作)。
  - L2CAP、connection events、状态恢复、`didModifyServices`。
- **写入流控：** `canSendWriteWithoutResponse` 始终返回 true,流控改由 Mac App 按 Mac 那边外设的状态排队处理。
- **同 UUID 的服务或特征：** service 和 characteristic 按 UUID 匹配，同一设备上出现重复 UUID 的情况不支持。
- **时序和后台：** 时序、MTU、吞吐以 Mac 为准，还多了一跳本机网络;后台行为也模拟不出来。

## 故障排查

- **侧栏显示端口被占用：** 有其他进程占用了 50505 端口，停掉它后重启 SimBLE。
- **Mac Bluetooth 不是 On:** 到「系统设置 → 隐私与安全性 → 蓝牙」里允许 SimBLE。
- **App 没有绿点：**
  1. 确认它在对应模拟器下的开关是开的，然后点 ↻ 重启。
  2. 如果是 Xcode Run 没接上，看 Xcode 控制台有没有 `[SimBLE]` 开头的输出;没有的话，重启一次 Xcode,让它重新读取 `~/.lldbinit`。
- **解析器没生效：**
  1. 看侧栏 Decoders 分区里有没有它，有没有报错。
  2. 确认 `accepts` 匹配的 UUID 和日志 Detail 列里的 service / characteristic 一致(Detail 列可以在 Columns 菜单里打开)。自定义 UUID 原样显示;SIG 标准 UUID 在 Detail 里显示成名称，比如 `Heart Rate` 对应 `180D`,但 `accepts` 收到的是 4 位十六进制。
  3. 确认没有字母序更靠前的插件先接收了这路数据。

## 目录结构

```
App/                 Mac App(SwiftUI 和 AppKit)
DecoderKit/          解析器接口库，App 和插件共用
Decoders/<Name>/     随仓库提交的解析器插件：适配代码 + 可选的 sources 清单
Loader/  Shim/       注入模拟器的 loader 和 shim
lldb/                Xcode Run 用的 LLDB 钩子
build.sh             编译 App、接口库和不依赖外部源码的插件
make-decoder.sh      单独编译一个插件并安装到用户插件目录
make-dmg.sh          编译并打包成 .build/SimBLE-<版本>.dmg
Icon/                App 图标:draw-icon.swift 绘制，make-icon.sh 生成 AppIcon.icns(已提交)
```

## 许可证

[MIT](LICENSE)
