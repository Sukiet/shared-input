# 入站文件拖拽启动回退：边缘只能上下移动

基线 `5cd166d`，分支 `feature-drag-objects`。用户报告比上一版更差：跨屏后没有图标，横向固定，只能纵向移动。

随后用户提供截图：Windows 已显示“跨屏未完成”，错误为 `Mac 未收到有效的文件拖拽启动事件`，并被包装为 `Bad state: PlatformException(...)`。这确认了准备/启动等待超时、跨屏捕获未完成，而非已经持续控制 Mac 后才横向失灵；旧错误仍不能区分来源 down 未到和 AppKit 未启动。

## 已确认的依赖问题

`5cd166d` 把 macOS `receiverBegin` 的 FlutterResult 推迟到 AppKit `willBegin`，但 Windows `_startCapture` 在远端 begin 确认后才调用本机 `start`，真正开始转发输入。同时 Mac 的 `motionAllowed` 只允许已经 dragging 的状态。

这构成了启动依赖环：AppKit 若需要初始拖动来进入 tracking，控制端尚未发送；即便收到了来源 down，starting 阶段的移动仍被丢掉。指针留在来源屏幕边缘时，物理显示边界本身就只允许沿边缘移动，这与报告相符，但仍需 Mac 原始日志确认这次实际停在哪个阶段。

另外，透明的普通 NSView 来源窗口与已注册的拖放接收区域不是同一种鼠标命中路径。空绘制来源面可能无法收到普通 down；本次给临时来源面绘制一个 alpha 量化单位，并在投递 down 前提交显示，避免依赖完全空表面的命中。2×2 点窗口仅服务于本次文件拖拽，不改已有的 Windows 一像素边缘接收区。

## 修正

- 接收端准备完成后立即确认 begin，允许 Windows 开始捕获和转发。AppKit 启动结果走独立状态通知；异步通知不再持有或重复调用这个 FlutterResult。
- 真实来源 down 未收到前仍暂存移动；down 已被来源窗口消费后的 starting 阶段允许启动所需的 Dragged，不再等 willBegin。已取消、异常结束和已结束的会话仍不放行拖拽。
- 来源面保留非激活命中、禁用窗口动画，临时层级与原边缘探针一致，并在种子 down 投递前 `displayIfNeeded()`。
- 启动超时使用加入 `.common` 的主 RunLoop Timer，覆盖 AppKit 跟踪模式；取消与提前结束仍释放按钮并通知 Dart 结束捕获。
- 启动阶段单独显示“来源窗口等待按下”和“已收到按下，正在启动文件拖拽”。超时按实际阶段报告；首个失败原因按 drag id 保留，后续正常取消清理不能改成“文件拖拽已取消”。接收端拒绝使用原生错误的 message，控制端使用独立异常类型，不再叠加 Bad state / PlatformException 包装。
- 仍保留真实 NSEvent 启动、无伪造 down、用户松手授权文件写入、准备期取消检查和旧版诊断兼容。

## 验证边界

新增真实 TCP/UDP 回环检查：文件传输准备确认后，在文件会话尚未激活时，横向和纵向位移都能到达接收器。Swift 原生状态测试相应检查“down 前禁止移动、消费真实 down 后可进行启动移动”。回环只能证明网络及两阶段约定，不能证明 NSPanel 命中、NSDraggingSession 或 Finder 实机行为。

当前工作机为 Windows，不能运行 AppKit 或编译 Swift 原生状态测试。已向用户请求旧版失败时的 `source down` / `ended` 原始日志，以及 Windows 端提示；在收到之前不将这次原因认定为已经实机确认，也不把修改标为已经解决。

本次静态分析、138 项 Flutter 测试通过，包含两轴回环、首个错误保留和拒绝消息去除包装。Windows 同步更新阶段提示和错误展示，Debug 构建通过并启动。Mac 实机仍未验证；候选修正留在本地，尚未提交或推送。

Mac 更新后应观察三条记录：

- `Shared Input incoming file drag transport ready`
- `Shared Input incoming file drag source down`（真实事件编号）
- `Shared Input incoming file drag ended`（操作、耗时与按钮状态）

复测应先确认 Windows 开始捕获、不再沿来源边缘空等；再确认 Mac 收到真实 down、图标持续存在、横纵移动、松手复制和异常退出。
