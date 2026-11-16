import Foundation
import FlutterMacOS
import AVFoundation
import CoreAudio
import CryptoKit
import Darwin

private struct AudioCaptureFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

/// Native control is asynchronous; no PCM crosses a Flutter platform channel.
final class AudioCaptureBridge {
  private let channel: FlutterMethodChannel
  private let control = DispatchQueue(label: "shared-input.audio.control", qos: .userInitiated)
  private let lock = NSLock()
  private var current: SystemAudioCapture?
  private var generation: UInt64 = 0

  init(channel: FlutterMethodChannel) { self.channel = channel }
  deinit { shutdown() }
  func shutdown() {
    lock.lock(); generation &+= 1
    let source = current; current = nil; source?.cancel()
    lock.unlock()
    source?.stop()
  }
  func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    if call.method == "audioCapabilities" {
      if #available(macOS 14.2, *) { result(["capture": true, "render": false]) }
      else { result(["capture": false, "render": false]) }
      return
    }
    let args = call.arguments as? [String: Any] ?? [:]
    let session = args["session"] as? String ?? ""
    if call.method == "audioCaptureHeartbeat" {
      lock.lock(); let source = current; lock.unlock()
      if source?.session == session { source?.renew() }
      result(nil); return
    }
    if call.method == "audioCaptureStop" {
      lock.lock()
      let source = current?.session == session ? current : nil
      if source != nil { generation &+= 1; current = nil; source?.cancel() }
      lock.unlock()
      control.async { source?.stop() }
      result(nil); return
    }
    guard call.method == "audioCaptureStart" else { result(FlutterMethodNotImplemented); return }
    guard #available(macOS 14.2, *) else {
      result(FlutterError(code: "audio_unsupported", message: "音频回传需要 macOS 14.2 或以上", details: nil)); return
    }
    guard session.count == 32, let text = args["key"] as? String, let key = AudioPacket.key(text),
          let host = args["host"] as? String, let port = args["port"] as? Int,
          (1...65535).contains(port) else {
      result(FlutterError(code: "invalid_audio", message: "音频会话参数无效", details: nil)); return
    }
    lock.lock(); generation &+= 1; let request = generation
    let previous = current; current = nil; previous?.cancel()
    lock.unlock()
    control.async { [weak self] in
      guard let self = self else { return }
      previous?.stop()
      let source = SystemAudioCapture(session: session, host: host, port: port, key: key) { [weak self] message in
        DispatchQueue.main.async { [weak self] in
          self?.channel.invokeMethod("audioCaptureState", arguments: [
            "session": session, "status": "error", "message": message
          ])
        }
      }
      self.lock.lock()
      let allowed = request == self.generation
      if allowed { self.current = source }
      self.lock.unlock()
      guard allowed else {
        DispatchQueue.main.async { result(FlutterError(code: "audio_cancelled", message: "音频启动已取消", details: nil)) }; return
      }
      do {
        try source.start()
        self.lock.lock(); let stillCurrent = request == self.generation; self.lock.unlock()
        if !stillCurrent { source.cancel(); source.stop() }
        DispatchQueue.main.async {
          if stillCurrent { result(nil) }
          else { result(FlutterError(code: "audio_cancelled", message: "音频启动已取消", details: nil)) }
        }
      } catch {
        source.stop()
        self.lock.lock(); if request == self.generation { self.current = nil }; self.lock.unlock()
        DispatchQueue.main.async {
          result(FlutterError(code: "audio_capture_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }
}

private final class SystemAudioCapture {
  let session: String
  private let host: String, port: Int, key: SymmetricKey
  private let onFailure: (String) -> Void
  private let operations = NSRecursiveLock()
  private let leaseLock = NSLock()
  private var cancelled = false, lastLease = 0.0
  private var running = false
  private var tap = AudioObjectID(kAudioObjectUnknown), aggregate = AudioObjectID(kAudioObjectUnknown)
  private var io: AudioDeviceIOProcID?
  private let ioQueue = DispatchQueue(label: "shared-input.audio.io", qos: .userInteractive)
  private let sendQueue = DispatchQueue(label: "shared-input.audio.send", qos: .userInitiated)
  private let safetyQueue = DispatchQueue(label: "shared-input.audio.safety", qos: .userInitiated)
  private var sender: DispatchSourceTimer?, watchdog: DispatchSourceTimer?
  private var socketFD: Int32 = -1
  private var destination = sockaddr_in()
  private var converter: AVAudioConverter?, converted: AVAudioPCMBuffer?, working: AVAudioPCMBuffer?
  private let ringLock = NSLock()
  private var ring: [AVAudioPCMBuffer] = []
  private var readIndex = 0, writeIndex = 0, count = 0
  private var sourceBytesPerFrame: UInt32 = 0
  private var residual = Data()
  private var sequence: UInt64 = 0
  private static let capacity: AVAudioFrameCount = 8192

  init(session: String, host: String, port: Int, key: Data, onFailure: @escaping (String) -> Void) {
    self.session = session; self.host = host; self.port = port
    self.key = SymmetricKey(data: key); self.onFailure = onFailure
  }
  deinit { stop() }
  func cancel() { leaseLock.lock(); cancelled = true; leaseLock.unlock() }
  func renew() { leaseLock.lock(); if !cancelled { lastLease = ProcessInfo.processInfo.systemUptime }; leaseLock.unlock() }
  private func allowed() -> Bool { leaseLock.lock(); defer { leaseLock.unlock() }; return !cancelled }
  private func check(_ status: OSStatus) throws {
    if status != noErr {
      throw AudioCaptureFailure(message: "无法采集 Mac 系统音频（\(status)），请检查系统音频录制权限后重试")
    }
  }
  func start() throws {
    operations.lock(); defer { operations.unlock() }
    guard allowed() else { throw AudioCaptureFailure(message: "音频启动已取消") }
    guard #available(macOS 14.2, *) else { throw AudioCaptureFailure(message: "需要 macOS 14.2 或以上") }
    do {
      try createSocket()
      let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
      description.name = "Shared Input Audio Return"
      description.isPrivate = true
      description.muteBehavior = .mutedWhenTapped
      try check(AudioHardwareCreateProcessTap(description, &tap))
      var tapUID = "" as CFString
      var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID,
          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
      var uidSize = UInt32(MemoryLayout<CFString>.size)
      try check(withUnsafeMutablePointer(to: &tapUID) {
        AudioObjectGetPropertyData(tap, &uidAddress, 0, nil, &uidSize, $0)
      })
      let composition: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Shared Input Private Audio",
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceTapListKey: [[
          kAudioSubTapUIDKey: tapUID,
          kAudioSubTapDriftCompensationKey: true
        ]]
      ]
      try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate))
      var format = AudioStreamBasicDescription()
      var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat,
          mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
      var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      try check(AudioObjectGetPropertyData(aggregate, &address, 0, nil, &size, &format))
      guard let source = AVAudioFormat(streamDescription: &format), source.sampleRate >= 8000, source.sampleRate <= 384000,
            source.channelCount == 2,
            let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true),
            let converter = AVAudioConverter(from: source, to: target),
            let working = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: Self.capacity),
            let converted = AVAudioPCMBuffer(pcmFormat: target,
                frameCapacity: AVAudioFrameCount(ceil(Double(Self.capacity) * 48000 / source.sampleRate)) + 1024) else {
        throw AudioCaptureFailure(message: "Mac 系统音频格式不受支持")
      }
      self.converter = converter; self.working = working; self.converted = converted
      sourceBytesPerFrame = format.mBytesPerFrame
      ring = (0..<8).compactMap { _ in AVAudioPCMBuffer(pcmFormat: source, frameCapacity: Self.capacity) }
      guard ring.count == 8 && sourceBytesPerFrame > 0 else { throw AudioCaptureFailure(message: "无法分配音频缓冲") }
      try check(AudioDeviceCreateIOProcIDWithBlock(&io, aggregate, ioQueue) { [weak self] _, input, _, _, _ in
        self?.enqueue(input)
      })
      guard allowed() else { throw AudioCaptureFailure(message: "音频启动已取消") }
      try check(AudioDeviceStart(aggregate, io))
      running = true; renew()
      guard allowed() else { throw AudioCaptureFailure(message: "音频启动已取消") }
      let sender = DispatchSource.makeTimerSource(queue: sendQueue)
      sender.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(250))
      sender.setEventHandler { [weak self] in self?.pump() }
      self.sender = sender; sender.resume()
      let watchdog = DispatchSource.makeTimerSource(queue: safetyQueue)
      watchdog.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
      watchdog.setEventHandler { [weak self] in self?.checkLease() }
      self.watchdog = watchdog; watchdog.resume()
    } catch { stop(); throw error }
  }
  private func createSocket() throws {
    socketFD = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
    destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    destination.sin_family = sa_family_t(AF_INET)
    destination.sin_port = UInt16(port).bigEndian
    guard socketFD >= 0, inet_pton(AF_INET, host, &destination.sin_addr) == 1,
          fcntl(socketFD, F_SETFL, O_NONBLOCK) == 0 else {
      throw AudioCaptureFailure(message: "无法建立音频回传通道")
    }
  }
  private func enqueue(_ data: UnsafePointer<AudioBufferList>) {
    // The consumer holds this lock only for a bounded preallocated memcpy.
    // A try-lock here discarded complete capture blocks on normal contention,
    // compressing the PCM timeline without creating a detectable UDP gap.
    ringLock.lock()
    defer { ringLock.unlock() }
    guard count < ring.count, sourceBytesPerFrame > 0 else { return }
    let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: data))
    guard let first = input.first else { return }
    let frames = AVAudioFrameCount(first.mDataByteSize / sourceBytesPerFrame)
    guard frames > 0 && frames <= Self.capacity else { return }
    let slot = ring[writeIndex]
    slot.frameLength = frames
    let output = UnsafeMutableAudioBufferListPointer(slot.mutableAudioBufferList)
    guard input.count == output.count else { return }
    for index in 0..<input.count {
      guard let src = input[index].mData, let dst = output[index].mData,
            input[index].mDataByteSize <= output[index].mDataByteSize else { return }
      memcpy(dst, src, Int(input[index].mDataByteSize))
    }
    writeIndex = (writeIndex + 1) % ring.count; count += 1
  }
  private func takeBuffer() -> AVAudioPCMBuffer? {
    guard ringLock.try() else { return nil }
    defer { ringLock.unlock() }
    guard count > 0, let working = working else { return nil }
    let slot = ring[readIndex]
    working.frameLength = slot.frameLength
    let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: slot.audioBufferList))
    let output = UnsafeMutableAudioBufferListPointer(working.mutableAudioBufferList)
    for index in 0..<input.count {
      if let src = input[index].mData, let dst = output[index].mData {
        memcpy(dst, src, Int(input[index].mDataByteSize))
      }
    }
    readIndex = (readIndex + 1) % ring.count; count -= 1
    return working
  }
  private func pump() {
    guard operations.try() else { return }
    defer { operations.unlock() }
    guard running, allowed(), let converter = converter, let converted = converted else { return }
    for _ in 0..<8 {
      guard let input = takeBuffer() else { break }
      var provided = false
      var error: NSError?
      converted.frameLength = 0
      let result = converter.convert(to: converted, error: &error) { _, state in
        if provided { state.pointee = .noDataNow; return nil }
        provided = true; state.pointee = .haveData; return input
      }
      if result == .error || error != nil { fail("Mac 音频格式转换失败"); return }
      let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: converted.audioBufferList))
      if let first = buffers.first, let bytes = first.mData, converted.frameLength > 0 {
        residual.append(bytes.assumingMemoryBound(to: UInt8.self), count: Int(converted.frameLength) * 4)
      }
      while residual.count >= AudioPacket.pcmBytes {
        let pcm = Data(residual.prefix(AudioPacket.pcmBytes)); residual.removeFirst(AudioPacket.pcmBytes)
        sequence &+= 1
        do {
          let packet = try AudioPacket.seal(pcm, sequence: sequence, key: key)
          var addressCopy = destination
          let sent = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &addressCopy) { address in
              address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(socketFD, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
              }
            }
          }
          if sent < 0 && errno != EWOULDBLOCK && errno != EAGAIN { fail("Mac 音频发送中断"); return }
        } catch { fail("Mac 音频加密失败"); return }
      }
    }
  }
  private func checkLease() {
    leaseLock.lock()
    let expired = !cancelled && lastLease > 0 && ProcessInfo.processInfo.systemUptime - lastLease >= 2
    if expired { cancelled = true }
    leaseLock.unlock()
    if expired {
      stop()
      onFailure("音频播放端响应中断，Mac 本机输出已恢复")
    }
  }
  private func fail(_ message: String) {
    leaseLock.lock(); let first = !cancelled; cancelled = true; leaseLock.unlock()
    stop()
    if first { onFailure(message) }
  }
  func stop() {
    operations.lock(); defer { operations.unlock() }
    cancel()
    sender?.cancel(); sender = nil
    watchdog?.cancel(); watchdog = nil
    if running { AudioDeviceStop(aggregate, io) }; running = false
    if let io = io { AudioDeviceDestroyIOProcID(aggregate, io) }; io = nil
    if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }; aggregate = AudioObjectID(kAudioObjectUnknown)
    if tap != kAudioObjectUnknown {
      if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tap) }
    }
    tap = AudioObjectID(kAudioObjectUnknown)
    if socketFD >= 0 { Darwin.close(socketFD); socketFD = -1 }
    ringLock.lock(); ring.removeAll(); count = 0; ringLock.unlock()
    converter = nil; working = nil; converted = nil; residual.removeAll()
  }
}
