# 屏幕与锁屏同步

基线 `10f6533`，分支 `feature-drag-objects`。

## 行为

控制端的“剪贴板同步”下方增加“屏幕与锁屏同步”开关，默认关闭，随设置保存。连接期间生效，与鼠标是否正在控制 Mac 无关。

- Windows 屏幕亮着或变暗时，保持 Mac 显示屏亮屏。开启策略时若 Mac 只是显示屏休眠，发送一次显示唤醒。
- Windows 屏幕关闭、系统睡眠或会话断开时，解除 Mac 的亮屏保持，使用 Mac 原有休眠设置；不强制 Mac 立即熄屏。
- Windows 锁屏时，释放被控端键鼠并发送锁屏指令。锁屏和亮屏是独立条件，Windows 锁屏界面仍亮时，Mac 锁屏界面也继续保持亮屏。
- Windows 解锁不发送 Mac 解锁操作。恢复亮屏保持可能点亮 Mac 登录界面，需要在 Mac 手动解锁。
- 关闭开关、断线或切换角色时释放亮屏保持。关闭策略不能解除已经发生的锁屏。

## 实现

Windows 使用 `GUID_SESSION_DISPLAY_STATUS` 读取当前会话的显示状态，保留初始 OS 通知，未知时不假定亮屏；使用原有 WTS 会话通知监听锁屏、解锁和会话断开。电源通知处理后仍传给 Flutter。唤醒时重新注册显示通知，取得最新状态，重复的恢复通知不覆盖已收到的新状态。

现有认证加密 TCP 连接协商 `screen-policy-v1`，传输 `screenPolicy` 和 `screenPolicyStatus`。控制端每两秒续期，每次状态变化立即发送；锁屏序号防止续期包重复触发锁屏。角色校验禁止被控端反向控制主控；未更新的对端保留键鼠功能并显示升级提示。

Mac 使用 IOKit `PreventUserIdleDisplaySleep` 电源断言，六秒后由 OS 自动释放，每次续期更新超时；另有原生计时器清理本地句柄。断线、退出、初始化时显式释放。防止 App Nap 的活动不包含阻止屏幕或系统休眠的选项。点亮显示使用 `IOPMAssertionDeclareUserActivity`，只在重新启用亮屏保持时调用，释放时同时清理其句柄。

Mac 锁屏使用系统默认的 Control–Command–Q，依赖键鼠共享已有的辅助功能/事件发送权限；先释放远程按键，完整创建并发送组合键按下、松开事件。没有自动解锁和凭据路径。权限缺失回报 Windows 开关下方，不关闭输入连接。用户若自行更改了系统锁屏快捷键，此实现需另行适配。

保持亮屏阻止的是自动显示休眠，不能越过系统主动睡眠、合盖或关机。两端需要更新，Windows 侧不能编译验证 macOS 框架。

## 验证与实测

Flutter 静态分析通过，104 项 Flutter 测试、15 项 Windows 原生测试通过，Windows Debug 构建通过。尚未在 Mac 编译或进行双机实测。

新增 Flutter 回环网络测试覆盖：独立于鼠标控制的亮屏策略、熄屏/未知/睡眠/会话断开释放、重复锁屏去重、锁屏前释放键鼠、主控解锁没有解锁指令、关闭开关和断线释放、无效数据及反向角色拒绝、权限错误和旧版兼容。界面测试检查开关在剪贴板下方且重启后恢复；原生 Windows 测试验证真实通知注册和模拟电源/会话事件解析，不让电脑实际锁屏或睡眠。

双机待测：更新 Mac 后连接，开启开关；等待超过 Mac 显示休眠时长；使用 Win+L，确认 Mac 同时锁屏；解锁 Windows，确认 Mac 仍要求认证；关闭开关后确认 Mac 恢复自身休眠策略；再测试 Windows 自动熄屏和连接断开。需要在 Mac 构建并完成这些实机检查，不能以 Windows 测试替代。

参考：[Windows 显示状态通知](https://learn.microsoft.com/en-us/windows/win32/power/power-setting-guids)、[Apple IOKit 电源 API](https://github.com/apple-oss-distributions/IOKitUser/blob/main/pwr_mgt.subproj/IOPMLib.h)、[Mac 锁屏快捷键](https://support.apple.com/en-ie/102650)。
