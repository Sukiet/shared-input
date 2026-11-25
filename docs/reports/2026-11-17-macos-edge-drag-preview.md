# Mac 边缘拖拽识别与两端事件区分

后续更新：此文记录旧版结束 Mac 拖拽的行为。新的双端续接实现见 [Mac 来源拖拽跨屏续接](2026-11-25-macos-drag-continuity.md)，需双方更新并协商新能力。

本次延续 Windows 连续按住跨屏实验，加入 Mac 来源对象的边缘识别。仍是测试版：读取文件列表、同步事件状态，不传输文件，也不在另一台机器创建系统文件拖放。

## 使用

双方都需要更新此版。Mac 按被控端启动并开始接收；Windows 的“显示屏设置”决定位置，再开启“屏幕边缘切换”和“边缘拖拽测试”。连接后 Windows 自动同步测试开关和 Mac 的对应边缘，不必在 Mac 重复设置。离线时可在 Mac 本地手动开启测试；连接后开关由主控机管理。

| 显示屏设置中 Mac 的位置 | Windows 出去的边 | Mac 面向 Windows 的边 |
| --- | --- | --- |
| 右侧 | 右 | 左 |
| 左侧 | 左 | 右 |
| 上方 | 上 | 下 |
| 下方 | 下 | 上 |

两端界面分别显示“主控机拖拽事件”和“被控机拖拽事件”，各有当前状态、状态路径和文件列表。来源按对象在哪个桌面开始拖动区分：使用 Windows 鼠标在 Mac Finder 里按下再拖动，是被控机事件；在 Windows 开始按住后跨到 Mac，仍是主控机事件，不伪造第二个 Mac 对象。清空会通知双方清除本地展示，不操作源文件。

使用 Windows 鼠标在 Mac 内拖 Finder 文件/文件夹到配置边缘，查看被控机列表及返回 Windows 的状态；再从 Windows 拖文件跨过去，核对主控机列表独立。普通鼠标跨屏和持续按住往返保留，不等待文件识别成功。

## 实现

- Mac 新增 AppKit NSPanel/NSView 拖放目标，透明、不激活、不抢主窗口，厚度为一个物理像素；按 NSScreen.backingScaleFactor 换算 Retina 点尺寸，监听全局与本应用鼠标事件。普通状态设置 ignoresMouseEvents，进入拖动手势后接收边缘拖放。
- 采用 NSDraggingDestination 读取 draggingPasteboard 中的 public.file-url 和旧式路径列表，只解析名称、路径和格式；不访问文件属性、别名、文件内容，不生成 file promise。虚拟对象暂只展示可用格式。最多展示 256 项，元数据读取预算 16 MiB。
- draggingEntered/draggingUpdated 始终返回空操作，prepare/perform 均拒绝实际放置。源拖拽还在目标内时，即使关掉测试也保留拒绝目标，等 AppKit 通知退出/结束再销毁，防止提前移走目标。
- 处理 AppKit 左下原点、Quartz 左上原点差异。测试模式中，Mac 内按住拖动的注入事件在回程边缘落到最后一个物理像素内，避免 Retina 下一个逻辑点的原有约束跳过半点宽的目标；预测模式下按住期间的返回反馈读取实际系统指针，不把吸附后的真实落点当成预测点。
- Mac 通过“手势 → 边缘 → 已跨机器 → 结束 / 回原机”记录状态。只有正常边缘返回的 end(reason: edge) 才记录跨机，断线、手动停止和 watchdog 不冒充边缘返回。返回会正常释放 Mac 原有按下，结束本机拖放；Windows 不接管文件，不合成文件拖拽，再回 Mac 也不会恢复原 NSDraggingSession。
- 原有加密控制连接增加 edge-drag-preview-v1 能力，发送配置、状态及清空消息。布局由 Windows 管理，Mac 仅采用相对边，不自己猜左右；receiverBegin 也用相同入口边更新。
- 状态包含可信来源标记和单调修订号，接收时限制数据结构、来源和旧消息；状态 JSON 最大 48 KiB，连同消息包裹和加密开销小于既有 64 KiB 控制帧限制。逐项计算 UTF-8/JSON 转义预算，超出只截断展示，不增加协议帧上限。只在状态变化时同步，不传每帧鼠标坐标副本。
- 断线清除对端旧状态并关闭 Mac 接收条，重连重新同步开关和布局。旧版没有协商能力时不发送新消息，原有输入连接继续工作，界面提示对端需更新。
- Windows 在确认 Mac 新版已成功开启相应边缘后，测试模式允许 Mac 桌面内新按下的鼠标也返回。未更新的 Mac 保留原有返回规则。原来 Windows 开始的按住跨屏不受这个新能力确认影响。
- 钩子同时区分物理按钮、远控归属及实际送进 Windows 的按下。Mac 内按下并被 Windows 拦截的按钮没有 Windows async down，回程及再次跨屏时不能靠 GetAsyncKeyState 把它误当成已释放；真实物理松开仍负责清理，不伪造按下。

## 验证与待测

Windows 已完成 Dart 分析，95 项 Flutter 测试、13 项 Windows 原生测试全部通过，并构建 Debug。Flutter 覆盖双来源面板、Mac 平台 UI、四边配置、双向中文路径、清空、旧消息拒绝、断线重连、旧版兼容及 edge 停止原因。原生补充 Mac 来源按钮返回后继续按住的归属和再次跨屏检查。

Mac 工程已注册新 Swift 文件并新增五项 XCTest：四边 Retina 区域、Quartz 落点转换、来源状态机、中文路径和文件夹元数据、拒绝非文件 URL。**当前是 Windows 环境，没有 macOS SDK/Xcode，未运行 Mac 编译或这些 XCTest，也没有验证实际 Finder 拖拽能否命中透明面板。**

Mac 端沿用该机现有证书先构建 Debug，之后可用 Runner scheme 的测试目标运行 XCTest。实测重点是 Finder 单文件/多选/文件夹、四个方向尤其 Retina 右边和下边、普通点击穿透，以及持续按住返回后再次跨屏。若不能识别，应记录方向、缩放、UI 区域开关和数据格式；不能把 Flutter 平台变体测试通过视为 AppKit 实测通过。

接口依据：[AppKit 拖放目标](https://developer.apple.com/documentation/appkit/nsdraggingdestination)、[draggingPasteboard](https://developer.apple.com/documentation/appkit/nsdragginginfo/draggingpasteboard)、[Quartz 与 AppKit 坐标差异](https://developer.apple.com/documentation/coregraphics/cgevent/unflippedlocation)。
