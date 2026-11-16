# Mac → Windows 音频回传首版

日期：2026-11-16。工作基线：302833a。本报告对应音频回传首版，Mac 构建与双机验收待完成。

## 已确认的行为

- Windows 控制端有“不同步 / 同步 / 耳机插入时自动同步”三档，默认不同步，保存到原设置存储。位置在剪贴板同步与断联日志之间。
- 同步期间只在 Windows 播放，Mac 本机不播放被捕获的系统声音。音频跟随已连接的会话，鼠标切回 Windows 不停止音频。
- 自动档依据 Windows **当前默认播放设备**的类型。系统报告 Headphones / Headset 才开启；切回扬声器、输出不可用或关闭连接时停止。设备未插入但不是默认输出不触发。
- 驱动报告的形态是识别依据，不猜设备名称。有的模拟耳机插孔仍报告 Speakers；这种情况需要选“同步”。
- 音频出错只停止音频，不主动断开键鼠连接。失败后可点“重试音频同步”。

## Mac 方案与权限

用户机器为 macOS 27.0.1，首版采用 Core Audio Process Tap 与应用私有 Aggregate Device。它是应用创建并清理的私有音频设备，不额外安装 BlackHole 等 HAL 驱动，也不改系统默认输出。

Apple 的[官方示例](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)说明：Tap 可捕获进程输出并作为聚合设备输入，同时能够静音原输出；示例要求 macOS 14.2 或以上。实现使用全局立体声 Tap 与 `mutedWhenTapped`，停止 IO 并销毁 Tap 后恢复本机声音。

Info.plist 增加 `NSAudioCaptureUsageDescription`。首次开始从含 Tap 的设备录音会弹系统音频录制授权。拒绝权限会返回音频错误；首次授权较慢导致启动超时时，允许后再在 Windows 点重试。保留固定签名证书构建，避免更新后权限身份变化。

## 数据与恢复机制

- Mac 原生采集、AVAudioConverter 转换为 48 kHz / 双声道 / 有符号 16 位小端 PCM；每包 240 帧，即 5 ms。
- 音频独立 UDP 端口，PCM 不经过 Flutter MethodChannel，也不复用键鼠数据队列。约 1.59 Mbps 应用层数据，不含 IP/UDP 开销。实际延迟没有双机测量。
- 每次开启/重试生成独立随机 AES-256-GCM 密钥，通过既有认证加密 TCP 通道交付；对端地址来自已配对连接，不接受消息任意指定目标主机。
- 数据包：`SIA1` 4 字节 + 大端序号 uint64 + 大端帧数 uint32 + 960 字节密文 + 16 字节认证标签，总长 992 字节。头部前 12 字节为 nonce，整个头部为 AAD，序号从 1 开始。同密钥不可重启计数器。
- Windows 校验来源 IP、长度、认证标签、帧数、序号与重复包。乱序预缓冲 3 包 / 15 ms；超过 12 包时丢弃陈旧积压并保留最近 3 包。丢包补静音，不重传。首版通过丢弃积压/重新缓冲限制时钟漂移，未实现自适应重采样。
- WASAPI 共享模式固定打开指定设备 ID，提供系统格式转换。耳机失效时不由原生模块擅自退回扬声器；设备通知交给同步策略重新决定。
- Windows 首次 20 秒无包或已收到音频后 1.2 秒无有效新包，停止播放并报告错误；Dart 启动等待另有 15 秒上限。
- Windows 每 400 ms 查询一次原生接收状态，只有近期收到有效新包才通过认证 TCP 发送音频续租。Mac 独立原生队列每 100 ms 检查，2 秒未续租则停止 IO、销毁私有设备和 Tap，恢复本机输出。它不依赖键鼠控制或 Flutter UI 帧刷新。
- 正常关闭、连接断开、关闭同步、设备切换、退出应用均清理音频会话。音频状态包含会话 ID，旧会话停止/错误不能结束新会话。
- 能力协商使用 `audio-capture-pcm-v1` / `audio-render-pcm-v1`，旧版对端继续使用键鼠和剪贴板，界面提示更新后才允许回传。

## 当前验证与限制

Windows Debug 构建成功；静态分析无问题，76 项 Flutter 测试和 9 项 Windows 原生测试全部通过。自动测试覆盖设置、模式切换、原生设备通知、旧版对端、独立音频控制消息、随机新密钥、会话取消、加密认证/篡改、乱序/重放、队列延迟上限。

Windows 本机默认音频输出已执行**静音 PCM**集成测试，真实路径为 UDP → GCM 解密 → WASAPI；覆盖接收、断流超时、旧会话停止、失败后重启和资源释放，不改变系统输出或播放测试音。

本开发环境是 Windows，未运行 Xcode/Swift 的 Mac 构建，未验证实际 Mac 捕获、TCC 权限与静音行为，也未测量跨机延迟/音质。不能据此声明双机功能已经验收。首版仅支持 IPv4 局域网，固定双声道，不传麦克风。蓝牙链路自身缓冲和丢包听感需要实测。

## Mac 验证步骤

1. 用原固定证书构建新版 Mac 应用，先执行 `flutter analyze`、`flutter test` 和 Debug 构建，检查新 Swift 文件已编入 Runner。Release 的原 Flutter SDK AOT 问题另行处理，不宣称本次解决。
2. 可独立检查 CryptoKit 协议兼容性：

   ```sh
   swiftc macos/Runner/AudioPacket.swift test/native/mac_audio_packet_test.swift -o /tmp/shared-input-audio-packet-test
   /tmp/shared-input-audio-packet-test test/fixtures/audio_packet.txt
   ```

   fixture 由 Python cryptography AESGCM 独立生成，Windows CNG 已通过同一 fixture。

3. 两端更新后连接，Windows 先选“同步”，Mac 允许系统音频录制。播放一段声音，验证只在 Windows 出声；鼠标切回 Windows 后仍播放。
4. 选择“不同步”，确认 Mac 恢复本机出声。再开启并测试断网、关闭 Windows 应用和停止 Mac 接收，确认 Mac 恢复声音。暂停 Dart isolate（不暂停整个进程）验证原生续租超时恢复。
5. 自动档：耳机设为 Windows 默认输出后同步；改为扬声器或拔掉耳机后停止并恢复 Mac 输出；耳机插入但默认输出仍为扬声器时不启用。
6. 快速切换三档/设备，确认旧请求不会结束新会话；记录系统音频权限拒绝、静音/设备状态、断线恢复与听感延迟。长时间播放检查漂移、偶发静音和资源增长。
