# 剪贴板同步第一版

## 使用范围

Windows 和 macOS 连接后，开启双方的“剪贴板同步”即可双向复制纯文字和单张图片；无需进入键鼠控制，也无需将应用保持在前台。开关默认开启并保存在现有设置中。

同步开始时控制端提供当前剪贴板；被控端的初始内容作为基线，不与控制端争抢。之后两端的新复制通过逻辑时钟和来源 ID 排序，竞争时确定同一个最新版本。新复制、关闭开关、断开及重新连接都会使旧传输失效。实际写入前还有系统版本号检查，用户在图片传输中更新本机剪贴板时不会被旧内容覆盖。

| 内容 | Windows 原生 | Mac 原生 | 传输 |
|---|---|---|---|
| 纯文字 | CF_UNICODETEXT | NSPasteboard.string | UTF-8，网络换行为 LF |
| 单张图片 | PNG、DIB / DIBV5 / BITMAP；写回 PNG + DIBV5 | 读取 PNG / TIFF；写回 PNG | PNG，保留透明度 |

文字上限 1 MiB；PNG 上限 32 MiB；解码前限制到 32 × 1024 × 1024 像素。超限或不支持的内容只更新版本以阻止过时写入，不清空另一端。文件、富文本和多项内容不在第一版范围内。

## 通道与调度

- 主连接通过 capability `clipboard-v1` 协商；旧端没有此能力时仍可控制键鼠，界面提示更新。
- 已认证的控制通道只传递开关、版本元数据、请求和临时端口。被控端监听临时 TCP 端口，通过加密主连接给控制端提供一次会话使用的随机密钥。
- 第二个 TCP 连接重新执行双向随机握手，使用 HKDF 和 ChaCha20-Poly1305；不复用键鼠通道的密钥或 nonce。只接受主连接对应的远端地址。
- 大数据的网络、哈希、加密、解密在独立 Dart isolate 执行；二进制帧携带传输 ID 和偏移，单块 32 KiB，发送之间间隔 4 ms。长度、偏移、哈希、图片尺寸及文字编码均校验后才交付原生层。
- Windows 由独立原生线程处理剪贴板和 WIC 转换，使用消息回到 Flutter 主线程完成调用；Mac 的 Pasteboard API 在主线程使用，ImageIO 在独立队列转换，均不持有键鼠注入锁。
- 每 200 ms 检查一次变化，仅在系统版本改变时读取内容。Windows 使用系统剪贴板序号并注册变化监听，Mac 使用 changeCount。来源标记阻止自己写入的内容再次发布。
- 权限不足、剪贴板连接失败等不解除主连接。开关关闭或主连接结束会禁用原生读写并取消未完成工作。

## 主要文件

- `lib/clipboard_content.dart`：内容大小、编码和版本元数据。
- `lib/clipboard_sync.dart`：同步开关、系统版本检查、回传抑制、最新内容选择和串行写入。
- `lib/remote/clipboard_channel.dart`：后台 isolate、握手、分块与重组。
- `lib/remote/wire.dart`：从原连接抽出的加密分帧 TCP 实现，键鼠与剪贴板复用代码、使用各自连接。
- `windows/runner/clipboard_bridge.*`、`clipboard_image.*`：Windows 工作线程、Unicode、WIC 与 DIBV5。
- `macos/Runner/ClipboardBridge.swift`：Mac Pasteboard、授权处理与 ImageIO。

## 验证

Windows 已通过静态检查、54 项 Flutter 测试、5 项原生测试和 Debug 构建。

自动测试覆盖双向 Unicode、超过控制帧上限的 PNG、循环回传抑制、本机新复制和远端新复制取消旧图片、同时复制收敛、开关取消及持久化、重连、临时占用重试、旧端兼容和权限失败时保持键鼠连接。Windows 原生测试检查 PNG / DIBV5 像素顺序和透明度，拒绝无效图像和过大尺寸。

Mac 的 RunnerTests 新增 TIFF 转 PNG 的透明度测试和非法图像测试，已加入测试构建目标；Windows 环境无法执行这些测试或构建 macOS。双机实测应包含两向中文 / Emoji / 多行文字、系统截图、浏览器复制图片、透明 PNG，以及传大图时继续移动鼠标和键入。Mac 端读取授权和目标应用的粘贴兼容性需在实机验证。

原先未解决的晃动退出问题保持独立，见 [问题记录](issues/mouse-shake-exit-unresolved.md)。

## 原生接口参考

- [Microsoft 标准剪贴板格式](https://learn.microsoft.com/en-us/windows/win32/dataxchg/standard-clipboard-formats)
- [Microsoft SetClipboardData 所有权约定](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setclipboarddata)
- [Apple NSPasteboard](https://developer.apple.com/documentation/appkit/nspasteboard)
- [Apple 剪贴板访问策略](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum)
