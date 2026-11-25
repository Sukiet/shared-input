# Mac 入站文件图标短暂显示后变成普通拖拽

基线 `3f2e3a7`，分支 `feature-drag-objects`。用户实测：Windows 文件按住跨到 Mac 后，文件图标显示不到半秒就消失；继续按住移动会拖起 Mac 文件或框选桌面。

## 定位

旧代码先构造 `eventNumber = 0` 的 NSEvent，立即调用 `beginDraggingSession`，同时将真正的 CGEvent MouseDown 异步 post 到 HID；随后在真正按下尚未交付时，将来源窗口设为 `ignoresMouseEvents = true`。这两个事件不处于同一次正常 NSView 鼠标事件处理流程：AppKit 的文件会话可能先启动，迟到的真正 MouseDown 再路由至 Finder，打断文件会话。

第二个已确认的代码问题是结束回调只关闭来源窗口和恢复探针，不通知输入接收器清除 `incomingFileActive` 和左键按下。文件会话消失后继续注入 Dragged，正好对应用户看见的 Finder 拖动/桌面框选。

以上启动顺序、鼠标穿透和结束后继续转发是代码可直接确认的缺陷。尚没有收集到用户这一次原始 AppKit ended 回调的操作值和按钮状态，不能断言所有提前结束都只有这一原因。

## 修正

- 来源改为真正的 `IncomingDragView.mouseDown(with:)`：只 post 一次带远程标记的 CGEvent down，保留非激活来源窗口的鼠标命中，由窗口服务器交付的真实 NSEvent 发起 NSDraggingSession。移除伪造 NSEvent、启动时立刻穿透和额外的初始 formation 调整。不会激活或聚焦 Shared Input 窗口。
- 捕获按下和松开的 clickCount 基线统一为 1。来源 down 明确设置压力和标记。
- 引入准备、来源按下、AppKit 启动、跟踪、用户释放、取消和结束的原生状态策略。准备阶段不转发移动，不将文件会话当作已经启动；收到 `willBegin` 才完成 Flutter 的 receiverBegin，刷新看门狗时钟和放行移动。启动等待上限 1 秒。
- 即使图标生成较慢，也在投递来源 down 前检查捕获仍属于当前会话；投递与取消互斥，防止看门狗已经发过 Up 之后又迟到投递 Down。异步取消绑定原 drag id，不能取消之后的新会话。
- 如果文件会话在用户松手前结束，原生先阻止后续 Dragged、释放按钮并清理 capture，再恢复来源探针和关闭窗口。Dart 同步结束远控捕获，保持配对连接；不允许继续解释为普通桌面拖动。
- 仅真实松手后的有效复制才授权 promise 写入。取消后的安全 Up、准备中提前释放和原生提前结束都不能触发文件复制。
- 增加启动真实 eventNumber/windowNumber 的 Console 记录，以及 ended 的操作、耗时、HID/combined 左键状态。界面同步显示“Mac 文件拖拽进行中”或“提前结束”。诊断 TCP 帧另协商 `file-drag-state-v1`，未更新的主控不接收新消息类型，避免兼容性断线。

## 验证

Windows 静态分析通过，135 项 Flutter 测试通过。新增回环测试检查原生会话状态/诊断送到 Windows、旧版不收到未知消息；Mac 平台变体的界面回环测试确认原生失败通知结束捕获但保持连接。

纯 Swift 状态测试 `test/native/mac_incoming_drag_lifecycle_test.swift` 覆盖真实 down 前不能启动、重复 down 拒绝、willBegin 前不放行、松手前结束、真实释放后写入、迟到 down/begin、取消和安全 Up。当前工作机是 Windows，没有 Swift/macOS SDK，尚未编译运行此测试或 AppKit 修复。

Mac 可先执行：

```sh
mkdir -p build/native
xcrun swiftc macos/Runner/IncomingDragLifecycle.swift test/native/mac_incoming_drag_lifecycle_test.swift -o build/native/mac_incoming_drag_lifecycle_test
build/native/mac_incoming_drag_lifecycle_test
```

再使用原固定证书构建 Debug，实测单文件跨屏后保持按住并移动数秒，确认图标持续存在、文件名正确、经过 Finder 文件/空白桌面不变成普通拖动；最后松手验证复制。随后验证无效目标、退出快捷键、断线、快速松手、连续往返。AppKit 真实跟踪循环中的输入响应及 Finder 落下效果必须实机确认，Windows 回环测试不能证明它们已修复。

若仍提前结束，查看应用的 `Shared Input incoming file drag source down` 和 `Shared Input incoming file drag ended` Console 记录，包含真实事件编号、耗时、操作值和两种按钮状态；不再只凭图标消失推断原因。

参考：[AppKit 拖拽启动事件](https://developer.apple.com/documentation/appkit/nsview/begindraggingsession(with:event:source:))、[NSDraggingSession 生命周期](https://developer.apple.com/documentation/appkit/nsdraggingsession)、[CGEventSource 状态](https://developer.apple.com/documentation/coregraphics/cgeventsource)。
