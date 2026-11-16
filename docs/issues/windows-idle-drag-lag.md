# Windows 未控制时桌面框选、拖文件卡顿

日期：2026-11-15。状态：升级 Windows 构建 SDK 后，用户已实测确认桌面框选、拖文件恢复流畅。

## 复现与排除

软件开启、未控制 Mac 时，Windows 桌面框选与拖拽文件明显卡顿。用户确认完全退出 Shared Input 后立即恢复流畅。

以下对照均由用户确认仍然卡顿：

- 缩小后台 Raw Input 监听范围，并仅在控制期间安装全局键鼠钩子。
- render-only 诊断：完全不创建 InputBridge，输入采集、剪贴板和看门狗模块均未加载。
- 传入软件渲染参数；但 Flutter 3.41.1 的 Windows 引擎仍初始化 ANGLE，此项不能排除图形组件交互。
- 同源码 Release 构建，排除仅由 Debug/JIT 开销引起。
- 强制分离 Dart UI 和 Windows 平台消息线程。

未改善问题的原生输入重构已撤回，保留原来的输入切换实现。诊断过程没有修改系统驱动、音频服务或注册表。

## 捕获的异常

本机原 SDK 为 Flutter 3.41.1 / Dart 3.11.0。消息计数显示，在分离线程的诊断窗口中，每 5 秒出现约 44,000–115,000 条 WM_NULL 唤醒，空闲时仍有两个线程持续消耗 CPU。此诊断仅记录消息类型与次数，不记录输入内容、连接码或剪贴板。

Flutter 上游已确认 TaskRunnerWindow 计时溢出造成空闲线程持续唤醒，并在 Flutter 3.41.3 修复。3.41.4 同样包含修复。本次使用独立安装的 Flutter 3.41.4 / Dart 3.11.1，恢复默认线程、渲染策略和原有输入逻辑后重建。

参考：

- [Flutter #182501：High idle CPU usage on Windows](https://github.com/flutter/flutter/issues/182501)
- [Flutter #182822：Fix overflow in TaskRunnerWindow](https://github.com/flutter/flutter/pull/182822)
- [Flutter 3.41.4 changelog（包含 3.41.3 修复说明）](https://github.com/flutter/flutter/blob/3.41.4/CHANGELOG.md)
- [Flutter #183262：WM_NULL 空转复现与升级结果](https://github.com/flutter/flutter/issues/183262)

## 修复与验证结果

- 用户已确认 Flutter 3.41.4 对照版开启时，桌面框选、拖拽文件恢复流畅。
- 新引擎的空闲 5 秒采样仅有 33–37 条 WM_NULL；旧引擎分离线程对照为约 44,000–115,000 条。存在鼠标和窗口操作时，新版采样为数百条，两组均未进行限流。
- 新版的一次 3 秒 CPU 采样累计消耗约 0.11 秒 CPU 时间；此前旧 SDK 的 Release 对照采样约 1.81 秒。采样期间的实际操作不同，因此这些数值是观测记录，不作为精确性能基准。
- 已核对程序目录 flutter_windows.dll 的 SHA-256 与独立 SDK 的 Debug 引擎一致。
- 新 SDK 下静态分析通过、59 项 Flutter 测试和 5 项原生测试全部通过。
- 临时诊断入口、消息计数及线程策略覆盖均已移除；保留 Flutter 最低版本约束 >=3.41.3，以及检查脚本的 -FlutterPath 参数。
- 清理诊断代码后，Windows Debug、Release 均已重新构建成功；已启动正常标题的 Debug 程序，原快捷方式仍指向该程序。正常窗口的一次 3 秒采样累计 CPU 时间约 0.047 秒。

本机 SDK 安装在父目录 `.toolchains/flutter-3.41.4`，未替换全局 SDK。后续 Windows 构建需使用该 SDK 或其他包含修复的版本；只更新源码、继续启动旧 SDK 构建的 exe 不会生效。Mac 无需为本次 Windows 引擎修复更新。
