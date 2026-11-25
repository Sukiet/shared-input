# Windows → Mac 文件拖拽交付

基线 `504d70c`，分支 `feature-drag-objects`。保留此前本地测试修正：`receiver_drag_hold_test.dart` 的 if 花括号；本次因 Begin 新参数更新该测试替身。

## 调研结论

- 使用真实 AppKit `NSDraggingSession` 和 `NSFilePromiseProvider`。每个文件或文件夹是一个 promise，Finder/接收应用决定能否放置，并在接受后给出写入目标 URL。仅模拟 MouseDown 无法携带文件对象。`writePromiseTo` 的完成回调必须等实际写入完成才调用。
- 普通文件使用 `NSWorkspace.icon(for:)` 按 Mac 的 UTType 取类型图标，并使用拖拽图像的 icon、label 组件显示文件名。图片可用源机生成的受限缩略图，完整原始字节仍在松手后传输；GIF 预览只取第一帧，缺少解码器时使用 Mac 类型图标。这里支持的是已经存在的图片文件，不是从网页或邮件拖出的虚拟数据对象。
- 用 `Progress.kind = .file`、目标 `fileURL`、`.copying`、实际字节数和 `publish()` 向系统发布进度。目录先统计总字节数；统计期间进度不确定，之后按字节推进。此机制允许系统接收并展示进度，不能在 Windows 上证明 Finder 必定显示某种图标进度条。Finder 版本、目标应用和 AppKit 拖拽循环需要 Mac 实测；不以 Flutter 自绘进度冒充系统状态。

## 流程

1. Windows 原有 OLE 边缘目标继续返回 `DROPEFFECT_NONE`，不会通知资源管理器删除或移动源文件。取得实际本地路径只用于本机授权清单，网络接收端不能传任意路径要求源机读取。
2. OLE 元数据绑定物理左键按下编号；跨屏前最多等 180 ms 接收迟到的当前拖拽元数据。旧预览仍在 UI 中，但不参与下一次拖拽。只有已协商的新版本才建立文件对象，旧版本继续原有预览行为。
3. 准备期仅检查根对象和创建小缩略图；不读取完整文件、不遍历目录。控制 Begin 携带随机 drag/item 标识、名称、类型、大小和可选缩略图，不含源路径。
4. Mac 创建透明、不激活应用的微小来源窗口，使用 AppKit 文件承诺拖拽。保留左键按住，后续注入 Dragged；Windows 原始按钮释放通过可靠输入流发送，钩子的独立手势结束通知也可补齐漏掉的 raw up，并去重。Mac 的来源探针在这一会话中忽略入站文件，避免把它错误归为“被控机拖拽”。
5. Finder 接受松手后，promise delegate 在后台队列通过 `NSFileCoordinator` 持有写协调并发布 Progress，再通知 Dart 使用独立文件通道。完成后解除发布并调用系统完成回调。文件传输独立于鼠标 capture，放下后继续移动、切回 Windows 不会终止已经接受的复制。
6. 未放置前的边缘返回、退出或断线先发送 Escape 取消 AppKit 会话，再释放按钮，避免把安全释放当成文件落下。普通拖拽松手标记为用户释放，不误取消已经落下的 promise。

## 通道与限制

主输入连接协商 `file-drag-v1`，按来源/目标能力区分角色。Mac 开临时 TCP 端口，随机秘密通过原有加密控制连接发送，文件通道独立握手、派生方向密钥并校验计数；只接受当前主控的 IP。文件数据、加解密、遍历和磁盘写入运行在独立 Dart isolate，TCP 设置 NoDelay。每块 48 KiB，最多 8 块未确认，防止发送端无限排队。

授权清单最多 8 轮、每轮最多 128 个真实根对象，10 分钟内可开始请求；传输中的请求继续完成。按目标独占创建文件，拒绝覆盖已有目标。目录相对路径验证每一段，拒绝绝对路径、`..`、空段、反斜杠、冒号和控制字符；最多 128 层、10 万项、32 MiB 路径元数据。符号链接/目录链接拒绝，传输前检查路径仍在授权根下。传输中的源文件大小或修改时间改变会报错；这不是文件系统快照，不保证同时被其他程序写入的目录一致性。

取消、断线或失败时关闭写句柄，再删除本次创建的半成品；取消和写入在接收端串行，避免并发 close 导致句柄泄漏。原文件始终保留。AppKit 写请求最多等待 30 分钟。文件通道失败不关闭键鼠，界面提示重新连接；首版没有断点续传。目标应用要支持文件 promises，Finder 是第一验证目标。

## 验证

本机 Flutter 静态分析通过，132 项 Flutter 测试、16 项 Windows 原生测试通过，Windows Debug 构建通过。

回环测试覆盖多窗口大小的数据流、Unicode 文件名、实际字节进度、多根对象、目录/空目录/空文件、取消清理、原文件保留、既有目标不覆盖、未授权标识和相对路径攻击。协调测试覆盖认证主连接协商独立端口、真实文件落盘与原生完成通知、旧元数据拒绝、迟到元数据和虚拟附件拒绝。Windows 原生测试覆盖 OLE 元数据绑定物理按下、小 PNG 真实文件缩略图和源句柄释放。

当前工作机为 Windows。即便 Windows 构建和所有自动检查通过，也没有在这里编译 AppKit，不能宣称 Finder 拖拽、AppKit tracking loop 中输入持续响应或图标进度已实测成功。

Mac 更新构建后的实测顺序：

1. 双方开启边缘切换和跨屏拖拽。先拖单个 txt 到 Mac 桌面，确认有 Mac 类型图标、文件名和复制徽标；松手后比对内容，Windows 原件保留。
2. 拖 png/jpg，检查缩略图，落下后确认原始图片格式和字节不变；再拖多文件、嵌套文件夹和空目录。
3. 用较大文件观察 Finder 目标图标、系统复制状态和 Progress 更新，同时移动鼠标、敲键确认输入不被 AppKit 拖拽循环或传输阻塞。
4. 未松手返回 Windows、快捷键、Escape、断线、锁屏分别验证没有误放置；已松手开始复制后切回 Windows，确认复制继续。复制期间取消或断线，确认目标半成品清理和原文件保留。
5. 重名目标确认不被覆盖。快速释放、连续往返、松手重按验证不借用旧预览和旧按下编号。

参考：[文件 promises](https://developer.apple.com/documentation/appkit/nsfilepromiseprovider)、[写入完成回调](https://developer.apple.com/documentation/appkit/nsfilepromiseproviderdelegate/filepromiseprovider(_:writepromiseto:completionhandler:))、[AppKit 拖拽会话](https://developer.apple.com/documentation/appkit/nsview/begindraggingsession(with:event:source:))、[Mac 类型图标](https://developer.apple.com/documentation/appkit/nsworkspace/icon(for:))、[跨进程发布 Progress](https://developer.apple.com/documentation/foundation/progress/publish())。
