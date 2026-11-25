# Mac 来源拖拽跨屏续接

分支：`feature-drag-objects`。此前指针退出修复已单独提交为 `14b9e60`。

## 目标与原问题

用户使用 Windows 鼠标在 Mac Finder 中拖文件，保持按住跨回 Windows，再回 Mac，继续同一次拖拽。旧实现把每次 `end(reason: edge)` 都当作完整结束，注入 MouseUp；再次 Begin 又清理按钮，因此系统原拖拽已取消。只同步状态或重新补 MouseDown 不能作为原手势续接。

## 实现

- 新增 `receiver-drag-hold-v1` 双方能力协商。仅在测试开关已启用、正常边缘返回、已有拖动手势（至少 4 点位移）、没有键盘按键且持有一个远程左/右按钮时挂起。文件元数据和 AppKit 回调可以迟到，不能作为保留手势的前置门槛。没有协商或缺少原始按下编号时沿用旧版行为。
- Mac 控制 capture 与挂起拖拽分离：暂停运动和预测，冻结在原边缘的拒绝放置区域，隐藏指针，保留原 CGEventSource、按钮和 AppKit 会话。最后补一个带标记的 Dragged，覆盖此前排队的位置；Retina 落点仍吸附到最后一个物理像素。挂起期间不执行左上角归位。
- Windows Raw Input 为每次真实按下生成递增编号，写入可靠的按钮事件。该编号跨 capture 保留。松开再按下同一个按钮会产生新编号，不能复用旧拖拽。
- Mac 为每次挂起产生随机 token；Windows 通过认证 TCP 接收它，每 250ms 在原生层查询物理按钮和按下编号，再发送保活或释放。挂起时捕获已经结束，仍会查询松手；没有转发 Windows 普通指针移动到 Mac。
- 续接前重新查询 Windows 实际状态，Begin 携带 token、按钮和按下编号。Mac 核对新鲜的保活、原按钮及 token；匹配后沿用原按下，只注入 Dragged。Windows 接管时把原按钮继续归给 Mac，不当作 Windows 来源按钮放行，并在新的输入 capture 中恢复按钮记录，保证之后的 Up 仍送到 Mac。
- 续接有准备和确认两个阶段。Begin 验证后先保留原边缘位置及隐藏状态；Windows 原生接管成功发送确认，或收到该 capture 的真实输入后，才移动至入口并显示。准备阶段同样受 1.5 秒期限限制。若 Windows 接管失败或条件改变，用 `resume_cancelled` 重新挂起，不向 Mac 补 Up；未完成的准备不重置原先 60 秒上限。
- 快速往返时若 token 尚未到达，Mac 拒绝无 token 的 Begin，保留原拖拽；控制端拿到先于拒绝通知发送的 token 后，在同一流程内重新验证并重试一次，不无限重试。错误或旧 token 不会清除另一轮挂起。退出消息发送顺序串联，新的 Begin 等前一轮 End 完成，避免越过结束通知。
- Mac 来源展示状态在续接后仍保持 gestureActive，保留同一 flow 和路径。现有 Windows 来源文件预览保持独立；没有传输文件内容或在 Windows 创建系统文件拖拽。

## 结束和保护

真实释放、按下编号变化、额外鼠标按钮、钩子不健康、Escape/退出快捷键、锁屏/睡眠、断线或设备移除使 Windows 停止续期/发送释放。短促紧急键会在原生层锁存取消，不要求恰好落在轮询时刻。Windows 普通失焦不结束已经挂起的 Mac 拖拽。

Mac 原生独立计时器在 1.5 秒没有有效续期或单次挂起达到 60 秒时释放。来自旧连接、旧 token 的结果不续期新拖拽。Mac 本机鼠标操作、AppKit 来源会话结束、关闭测试或退出程序也释放。结束后按原有指针隐藏/归位设置清理；本机接管时恢复显示并不归位。

保留已有 `SharedHooksBegin` 两参数 DLL 接口，另加远程按钮接管入口。部署 Windows 新版本时仍需更新完整构建目录，包含新 DLL。

## 验证范围

自动检查包括 Dart 协调/网络回环、原生五次连续往返状态、按下身份、松开重按、按钮归属、保活超时、60 秒上限、本机恢复及旧版兼容。此处的“五次往返”是状态机检查，不能作为真实 Finder 五次往返的证明。

当前工作机为 Mac，不能执行 Windows Flutter 构建或 Windows 专用钩子测试。必须在 Windows 编译这批改动，再将双方更新后联调真实 Finder：持续按住往返、在 Windows 松手、松开后重按、Escape/快捷键、断网、超过保活期限和 Mac 本机接管。单独替换 Mac 程序不会启用续接。

本机结果：静态分析无问题；Flutter 全量 117 项通过，3 项仍为 Windows 显示器布局和键盘例外界面的语义断言失败；新拖拽测试通过。Mac 状态/保活检查、原有指针检查、跨平台 C++ 按下身份和按钮归属检查通过。固定开发证书 Mac Debug 构建及签名校验通过，尚未重启当前程序进行实机操作。

```sh
xcrun swiftc macos/Runner/EdgeDragProbe.swift test/native/mac_receiver_drag_hold_test.swift -o build/native/mac_receiver_drag_hold_test
build/native/mac_receiver_drag_hold_test
```

Windows 端更新源码后执行 `tool/check.ps1 -BuildWindows`，并部署完整 Debug 目录及新的钩子 DLL，再做双机验证。
