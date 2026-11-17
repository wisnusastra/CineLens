import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Flutter
import ImageIO
import UIKit

/// Sends a Flutter method result exactly once.
///
/// AVFoundation can report completion, fail, or never call back at all. Every
/// export path used to `return` without answering on some errors, which left
/// Dart waiting forever on the "menyimpan" spinner. All replies now go through
/// this guard, so a watchdog and the real completion cannot both fire.
final class ReplyOnce {
  private let lock = NSLock()
  private var sent = false
  private let body: (Any?) -> Void

  init(_ body: @escaping (Any?) -> Void) {
    self.body = body
  }

  func send(_ value: Any?) {
    lock.lock()
    if sent {
      lock.unlock()
      return
    }
    sent = true
    lock.unlock()
    DispatchQueue.main.async { self.body(value) }
  }
}

/// Pushes `AVAssetExportSession.progress` to Dart so the processing overlay can
/// show a percentage instead of an indeterminate spinner.
final class ExportProgressReporter {
  private var timer: Timer?
  private var lastProgress = -1.0

  init(session: AVAssetExportSession, channel: FlutterMethodChannel?) {
    lastProgress = Double(session.progress)
    timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) {
      [weak self] timer in
      guard let self = self else {
        timer.invalidate()
        return
      }
      guard session.status == .exporting || session.status == .waiting else {
        self.stop()
        return
      }
      let progress = Double(session.progress)
      guard progress.isFinite, progress - self.lastProgress >= 0.01 else {
        return
      }
      self.lastProgress = progress
      channel?.invokeMethod("exportProgress", arguments: ["progress": progress])
    }
    timer?.tolerance = 0.1
  }

  func stop() {
    DispatchQueue.main.async { [weak self] in
      self?.timer?.invalidate()
      self?.timer = nil
    }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private static let videoChannelName = "com.cinelens.ios/video_grader"

  /// Kept alive so the capture pipeline can push status (stabilisation) back to
  /// Dart without the Dart side having to poll.
  private var nativeChannel: FlutterMethodChannel?

  /// The device behind the running `AVCaptureSession`, discovered from the
  /// session's own start notification because the `camera` plugin never exposes
  /// it. Manual exposure/white balance/focus and Apple Log are applied to this
  /// device directly.
  private weak var activeSession: AVCaptureSession?
  private var activeDevice: AVCaptureDevice?

  /// Last manual values, re-applied whenever the plugin rebuilds the session
  /// (resolution/frame-rate changes, front/back switch) because reconfiguring
  /// an `AVCaptureDevice` resets it to automatic.
  private var manualExposure: (seconds: Double, iso: Double)?
  private var manualWhiteBalance: (kelvin: Double, tint: Double)?
  private var manualFocusPosition: Double?
  private var appleLogEnabled = false

  /// ProRes recording rides on the plugin's own `AVCaptureSession`.
  ///
  /// iOS refuses a second session for the same camera, and the plugin's
  /// `CameraPreview` is the only preview available to Dart, so a separate
  /// recorder would mean losing the preview entirely. Instead this output is
  /// added to the running session for the duration of the take, then removed
  /// and the previous preset/format restored.
  private var proResOutput: AVCaptureMovieFileOutput?
  private var proResDelegate: ProResRecordingDelegate?
  private var proResStartResult: FlutterResult?
  private var proResStopResult: FlutterResult?
  private var proResPreviousPreset: AVCaptureSession.Preset?
  private var proResPreviousFrameDurations: (min: CMTime, max: CMTime)?
  private var proResAudioInput: AVCaptureDeviceInput?
  private var proResRecordingURL: URL?
  private var proResDidStart = false
  private var proResStartAttempts = 0
  /// ProRes goes through `AVAssetWriter` (see `ProResWriterTake`); the legacy
  /// `AVCaptureMovieFileOutput` path stays only as dead code behind this flag.
  private let proResUsesWriter = true
  // Fallback ProRes path (AVAssetWriter fed by the plugin's video frames).
  private var writerTake: ProResWriterTake?
  private var writerAudioSession: AVCaptureSession?
  private var writerDataOutput: AVCaptureVideoDataOutput?
  private var writerOriginalDelegate: AVCaptureVideoDataOutputSampleBufferDelegate?
  private var writerOriginalQueue: DispatchQueue?
  private var writerStartResult: FlutterResult?
  private var writerTimeout: DispatchWorkItem?
  private var writerDidStart = false

  /// The LUTs shipped with the app were authored for Flutter's
  /// `ColorFilter.matrix`, which runs on gamma-encoded sRGB values with the
  /// offsets expressed in 0…255. Core Image defaults to a linear working space,
  /// so grading there used to look flatter/different from the live preview.
  /// Pinning the working space to sRGB makes preview and export match.
  private static let gradingContext: CIContext = {
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
    var options: [CIContextOption: Any] = [
      .useSoftwareRenderer: false
    ]
    if let sRGB = sRGB {
      options[.workingColorSpace] = sRGB
      options[.outputColorSpace] = sRGB
    }
    return CIContext(options: options)
  }()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// UIScene lifecycle entry point for the implicit engine created by the storyboard.
  ///
  /// Plugins and application level method channels must be registered here instead of in
  /// `application(_:didFinishLaunchingWithOptions:)`: UIKit no longer builds the window
  /// during launch, so the `FlutterViewController` is not available at that point.
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerVideoGraderChannel(with: engineBridge.applicationRegistrar)
  }

  private func registerVideoGraderChannel(with registrar: FlutterApplicationRegistrar) {
    let channel = FlutterMethodChannel(
      name: AppDelegate.videoChannelName,
      binaryMessenger: registrar.messenger()
    )
    nativeChannel = channel
    observeVideoStabilization()

    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "applyCinemaMatrixToVideo":
        guard let args = call.arguments as? [String: Any],
              let inputPath = args["inputPath"] as? String,
              let matrix = args["matrix"] as? [Double] else {
          result(FlutterMethodNotImplemented)
          return
        }

        let anamorphic = (args["anamorphic"] as? Bool) ?? false
        let fps = (args["fps"] as? NSNumber)?.int32Value ?? 24
        let toneId = args["toneId"] as? String
        let intensity = (args["intensity"] as? NSNumber)?.doubleValue ?? 1.0
        self?.exportGradedVideo(
          inputPath: inputPath,
          matrix: matrix,
          toneId: toneId,
          intensity: intensity,
          effects: FilmEffects.from(args),
          importedLut: ImportedLut.from(args),
          anamorphic: anamorphic,
          fps: fps,
          result: result
        )

      case "bakeLookIntoProRes":
        guard let args = call.arguments as? [String: Any],
              let inputPath = args["inputPath"] as? String,
              let matrix = args["matrix"] as? [Double] else {
          result(FlutterMethodNotImplemented)
          return
        }
        let toneId = args["toneId"] as? String
        let intensity = (args["intensity"] as? NSNumber)?.doubleValue ?? 1.0
        self?.bakeLookIntoProRes(
          inputPath: inputPath,
          matrix: matrix,
          toneId: toneId,
          intensity: intensity,
          effects: FilmEffects.from(args),
          importedLut: ImportedLut.from(args),
          result: result
        )

      case "applyCinemaMatrixToPhoto":
        guard let args = call.arguments as? [String: Any],
              let inputBytes = (args["inputBytes"] as? FlutterStandardTypedData)?.data,
              let matrix = args["matrix"] as? [Double] else {
          result(FlutterMethodNotImplemented)
          return
        }

        let anamorphic = (args["anamorphic"] as? Bool) ?? false
        let quality = (args["quality"] as? NSNumber)?.doubleValue ?? 0.98
        let toneId = args["toneId"] as? String
        let intensity = (args["intensity"] as? NSNumber)?.doubleValue ?? 1.0
        self?.exportGradedPhoto(
          inputBytes: inputBytes,
          matrix: matrix,
          toneId: toneId,
          intensity: intensity,
          effects: FilmEffects.from(args),
          importedLut: ImportedLut.from(args),
          anamorphic: anamorphic,
          quality: quality,
          result: result
        )

      case "cameraCapabilities":
        result(self?.cameraCapabilities() ?? ["available": false])

      case "setManualExposure":
        guard let args = call.arguments as? [String: Any],
              let seconds = (args["seconds"] as? NSNumber)?.doubleValue,
              let iso = (args["iso"] as? NSNumber)?.doubleValue else {
          result(
            FlutterError(
              code: "bad_args",
              message: "seconds and iso are required.",
              details: nil
            )
          )
          return
        }
        self?.applyManualExposure(seconds: seconds, iso: iso, result: result)

      case "setAutoExposure":
        self?.applyAutoExposure(result: result)

      case "setManualWhiteBalance":
        guard let args = call.arguments as? [String: Any],
              let kelvin = (args["kelvin"] as? NSNumber)?.doubleValue,
              let tint = (args["tint"] as? NSNumber)?.doubleValue else {
          result(
            FlutterError(
              code: "bad_args",
              message: "kelvin and tint are required.",
              details: nil
            )
          )
          return
        }
        self?.applyManualWhiteBalance(kelvin: kelvin, tint: tint, result: result)

      case "setAutoWhiteBalance":
        self?.applyAutoWhiteBalance(result: result)

      case "setManualFocus":
        guard let args = call.arguments as? [String: Any],
              let position = (args["position"] as? NSNumber)?.doubleValue else {
          result(
            FlutterError(
              code: "bad_args",
              message: "position is required.",
              details: nil
            )
          )
          return
        }
        self?.applyManualFocus(position: position, result: result)

      case "setAutoFocus":
        self?.applyAutoFocus(result: result)

      case "setAppleLog":
        guard let args = call.arguments as? [String: Any],
              let enabled = args["enabled"] as? Bool else {
          result(
            FlutterError(
              code: "bad_args",
              message: "enabled is required.",
              details: nil
            )
          )
          return
        }
        self?.applyAppleLog(enabled, result: result)

      case "startProRes":
        guard let args = call.arguments as? [String: Any] else {
          result(
            FlutterError(
              code: "bad_args",
              message: "ProRes arguments are required.",
              details: nil
            )
          )
          return
        }
        self?.startProResRecording(args: args, result: result)

      case "stopProRes":
        self?.stopProResRecording(result: result)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - Video stabilisation

  /// Turns on hardware/optical stabilisation for every capture session the
  /// camera plugin starts.
  ///
  /// The `camera` plugin never exposes `AVCaptureConnection`, so the session is
  /// reached through its own start notification: by then the plugin has already
  /// configured the format, and setting `preferredVideoStabilizationMode` on a
  /// running connection is supported. `.standard` is used because it adds no
  /// preview latency (see `enableStabilization`).
  private func observeVideoStabilization() {
    let center = NotificationCenter.default

    center.addObserver(
      forName: AVCaptureSession.didStartRunningNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let session = notification.object as? AVCaptureSession,
            AppDelegate.videoDevice(in: session) != nil else { return }
      self?.enableStabilization(on: session)
      self?.captureActiveDevice(from: session)
    }

    center.addObserver(
      forName: AVCaptureSession.didStopRunningNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      // The plugin also runs a separate audio-only session; its start/stop
      // must not reset the video session's stabilisation indicator.
      guard let session = notification.object as? AVCaptureSession,
            AppDelegate.videoDevice(in: session) != nil else { return }
      self?.reportStabilization(active: false, mode: 0)
    }
  }

  /// The video device behind a session, or `nil` for an audio-only session.
  private static func videoDevice(in session: AVCaptureSession) -> AVCaptureDevice? {
    session.inputs
      .compactMap { ($0 as? AVCaptureDeviceInput)?.device }
      .first { $0.hasMediaType(.video) }
  }

  /// Picks `.standard` stabilisation: it has no look-ahead buffer, so the live
  /// preview does not lag behind the camera movement.
  ///
  /// `.auto` used to be requested here, but on 1080p it resolves to
  /// `.cinematic`, which delays frames by several frames and warps the image
  /// while panning (the preview looked late and wobbly). When the active format
  /// cannot do `.standard`, stabilisation is left off rather than letting iOS
  /// choose a higher-latency mode.
  private func enableStabilization(on session: AVCaptureSession) {
    let stabilizable = session.connections.filter { $0.isVideoStabilizationSupported }
    guard let connection = stabilizable.first else {
      reportStabilization(active: false, mode: 0)
      return
    }

    for candidate in stabilizable {
      let device = candidate.inputPorts
        .compactMap { ($0.input as? AVCaptureDeviceInput)?.device }
        .first
      let wanted: AVCaptureVideoStabilizationMode =
        (device?.activeFormat.isVideoStabilizationModeSupported(.standard) ?? false)
        ? .standard
        : .off
      if candidate.preferredVideoStabilizationMode != wanted {
        candidate.preferredVideoStabilizationMode = wanted
      }
    }

    // The active mode settles asynchronously once the connection reconfigures.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak connection] in
      guard let connection = connection else { return }
      let mode = connection.activeVideoStabilizationMode
      self?.reportStabilization(active: mode != .off, mode: Int(mode.rawValue))
    }
  }

  /// `mode` uses the `AVCaptureVideoStabilizationMode` raw values: 0 = off,
  /// 1 = standard, 2 = cinematic.
  private func reportStabilization(active: Bool, mode: Int) {
    nativeChannel?.invokeMethod(
      "stabilizationChanged",
      arguments: ["active": active, "mode": mode]
    )
  }

  // MARK: - Manual camera controls

  /// Remembers the device the plugin is capturing from.
  ///
  /// Every session restart (resolution/frame-rate change, lens switch) can hand
  /// us a different `AVCaptureDevice`, and iOS resets the manual settings while
  /// reconfiguring, so the stored values are replayed here.
  private func captureActiveDevice(from session: AVCaptureSession) {
    // Only the video session may become `activeSession`. The plugin's separate
    // audio session also posts `didStartRunning`; adopting it made ProRes try to
    // attach its movie output to a session without a camera ("no connection").
    guard let device = AppDelegate.videoDevice(in: session) else { return }
    activeSession = session
    let changed = activeDevice !== device
    activeDevice = device
    if changed {
      reapplyManualControls()
    }
  }

  private func cameraCapabilities() -> [String: Any] {
    guard let device = activeDevice else {
      return ["available": false]
    }

    let format = device.activeFormat
    var supportsAppleLog = false
    if #available(iOS 17.0, *) {
      supportsAppleLog = format.supportedColorSpaces.contains(.appleLog)
    }

    // Per TN3104 the prerequisite for ProRes 422 is a 10-bit 4:2:2 sensor
    // format (`x422`). `AVCaptureMovieFileOutput.availableVideoCodecTypes`
    // cannot answer this here: it only reports codecs once the output is
    // attached to the running session, which belongs to the camera plugin.
    let supportsProRes = device.formats.contains { candidate in
      CMFormatDescriptionGetMediaSubType(candidate.formatDescription)
        == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
    }

    return [
      "available": true,
      "deviceName": device.localizedName,
      "minISO": Double(format.minISO),
      "maxISO": Double(format.maxISO),
      "minShutterSeconds": CMTimeGetSeconds(format.minExposureDuration),
      "maxShutterSeconds": CMTimeGetSeconds(format.maxExposureDuration),
      "supportsAppleLog": supportsAppleLog,
      "supportsProRes": supportsProRes,
      "appleLogEnabled": appleLogEnabled,
    ]
  }

  /// Runs `body` while the device is locked for configuration.
  ///
  /// `lockForConfiguration` throwing means the system is reconfiguring the
  /// session (or the hardware cannot be driven manually), which is reported to
  /// Dart instead of silently leaving the preview untouched.
  private func withActiveDevice(
    _ result: @escaping FlutterResult,
    _ body: (AVCaptureDevice) throws -> Any?
  ) {
    guard let device = activeDevice else {
      result(
        FlutterError(
          code: "no_device",
          message: "Kamera belum siap. Coba lagi sebentar.",
          details: nil
        )
      )
      return
    }

    do {
      try device.lockForConfiguration()
    } catch {
      result(
        FlutterError(
          code: "lock_failed",
          message: "Kamera sedang dikonfigurasi sistem. Tunggu sebentar lalu "
            + "coba lagi.",
          details: nil
        )
      )
      return
    }
    defer { device.unlockForConfiguration() }

    do {
      result(try body(device))
    } catch {
      result(
        FlutterError(
          code: "config_failed",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  // MARK: - Manual exposure

  /// Locks exposure to an explicit shutter/ISO pair (real manual exposure, not
  /// an EV offset). Values are clamped to what the active format supports.
  private func applyManualExposure(
    seconds: Double,
    iso: Double,
    result: @escaping FlutterResult
  ) {
    withActiveDevice(result) { device in
      guard device.isExposureModeSupported(.custom) else {
        throw NSError(
          domain: "CineLens",
          code: 1,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Kamera ini tidak mendukung exposure manual."
          ]
        )
      }

      let format = device.activeFormat
      let minSeconds = CMTimeGetSeconds(format.minExposureDuration)
      let maxSeconds = CMTimeGetSeconds(format.maxExposureDuration)
      let clampedSeconds = min(max(seconds, minSeconds), maxSeconds)
      let clampedISO = min(max(Float(iso), format.minISO), format.maxISO)

      device.setExposureModeCustom(
        duration: CMTime(
          seconds: clampedSeconds,
          preferredTimescale: 1_000_000
        ),
        iso: clampedISO,
        completionHandler: nil
      )
      self.manualExposure = (seconds: clampedSeconds, iso: Double(clampedISO))

      return [
        "seconds": clampedSeconds,
        "iso": Double(clampedISO),
      ]
    }
  }

  private func applyAutoExposure(result: @escaping FlutterResult) {
    withActiveDevice(result) { device in
      if device.isExposureModeSupported(.continuousAutoExposure) {
        device.exposureMode = .continuousAutoExposure
      }
      self.manualExposure = nil
      return true
    }
  }

  // MARK: - Manual white balance

  private func applyManualWhiteBalance(
    kelvin: Double,
    tint: Double,
    result: @escaping FlutterResult
  ) {
    withActiveDevice(result) { device in
      guard device.isWhiteBalanceModeSupported(.locked) else {
        throw NSError(
          domain: "CineLens",
          code: 2,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Kamera ini tidak mendukung white balance manual."
          ]
        )
      }

      let clampedKelvin = min(max(kelvin, 1000.0), 14000.0)
      let clampedTint = min(max(tint, -150.0), 150.0)

      // Temperature/tint has to become device gains first: feeding an
      // out-of-range pair straight to `setWhiteBalanceModeLocked` raises an
      // Objective-C exception instead of throwing, which would crash the app.
      let requested = device.deviceWhiteBalanceGains(
        for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
          temperature: Float(clampedKelvin),
          tint: Float(clampedTint)
        )
      )
      let maxGain = device.maxWhiteBalanceGain
      let gains = AVCaptureDevice.WhiteBalanceGains(
        redGain: min(max(requested.redGain, 1.0), maxGain),
        greenGain: min(max(requested.greenGain, 1.0), maxGain),
        blueGain: min(max(requested.blueGain, 1.0), maxGain)
      )

      device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
      self.manualWhiteBalance = (kelvin: clampedKelvin, tint: clampedTint)

      return [
        "kelvin": clampedKelvin,
        "tint": clampedTint,
      ]
    }
  }

  private func applyAutoWhiteBalance(result: @escaping FlutterResult) {
    withActiveDevice(result) { device in
      if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
        device.whiteBalanceMode = .continuousAutoWhiteBalance
      }
      self.manualWhiteBalance = nil
      return true
    }
  }

  // MARK: - Manual focus

  /// `position` is the `AVCaptureDevice` lens position: 0.0 = far, 1.0 = near.
  private func applyManualFocus(
    position: Double,
    result: @escaping FlutterResult
  ) {
    withActiveDevice(result) { device in
      guard device.isFocusModeSupported(.locked) else {
        throw NSError(
          domain: "CineLens",
          code: 3,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Kamera ini tidak mendukung focus manual."
          ]
        )
      }

      let clamped = min(max(position, 0.0), 1.0)
      device.setFocusModeLocked(
        lensPosition: Float(clamped),
        completionHandler: nil
      )
      self.manualFocusPosition = clamped
      return clamped
    }
  }

  private func applyAutoFocus(result: @escaping FlutterResult) {
    withActiveDevice(result) { device in
      if device.isFocusModeSupported(.continuousAutoFocus) {
        device.focusMode = .continuousAutoFocus
      }
      self.manualFocusPosition = nil
      return true
    }
  }

  // MARK: - Apple Log

  /// Switches the device between Apple Log (flat, wide latitude, iOS 17+ and
  /// iPhone 15 Pro or newer) and the normal sRGB pipeline.
  ///
  /// The camera module has to keep its HDR pipeline off, otherwise iOS keeps
  /// tone mapping the Log signal.
  private func applyAppleLog(
    _ enabled: Bool,
    result: @escaping FlutterResult
  ) {
    guard #available(iOS 17.0, *) else {
      result(
        FlutterError(
          code: "unsupported",
          message: "Apple Log membutuhkan iOS 17 atau lebih baru.",
          details: nil
        )
      )
      return
    }

    withActiveDevice(result) { device in
      let supported = device.activeFormat.supportedColorSpaces.contains(.appleLog)
      guard !enabled || supported else {
        throw NSError(
          domain: "CineLens",
          code: 4,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Format aktif tidak mendukung Apple Log. Pilih 4K/30 atau 1080p."
          ]
        )
      }

      if device.activeFormat.isVideoHDRSupported {
        device.automaticallyAdjustsVideoHDREnabled = false
        device.isVideoHDREnabled = false
      }
      device.activeColorSpace = enabled ? .appleLog : .sRGB
      self.appleLogEnabled = device.activeColorSpace == .appleLog
      return self.appleLogEnabled
    }
  }

  /// Replays the manual settings after the plugin rebuilds its session.
  private func reapplyManualControls() {
    let ignored: (Any?) -> Void = { _ in }

    if let exposure = manualExposure {
      applyManualExposure(
        seconds: exposure.seconds,
        iso: exposure.iso,
        result: ignored
      )
    }
    if let whiteBalance = manualWhiteBalance {
      applyManualWhiteBalance(
        kelvin: whiteBalance.kelvin,
        tint: whiteBalance.tint,
        result: ignored
      )
    }
    if let focus = manualFocusPosition {
      applyManualFocus(position: focus, result: ignored)
    }
    if appleLogEnabled {
      applyAppleLog(true, result: ignored)
    }
  }

  // MARK: - ProRes recording

  /// Starts a ProRes 422 take on the plugin's session.
  ///
  /// `AVCaptureMovieFileOutput` can only write ProRes when the device runs a
  /// 10-bit 4:2:2 format, so the active format is swapped for the take and the
  /// previous session preset is restored afterwards. The file is a `.mov`
  /// master: no LUT is baked in, the live preview still shows the selected tone.
  private func startProResRecording(
    args: [String: Any],
    result: @escaping FlutterResult
  ) {
    if proResOutput?.isRecording == true || writerTake != nil {
      result(
        FlutterError(
          code: "busy",
          message: "Rekaman ProRes masih berjalan.",
          details: nil
        )
      )
      return
    }

    guard let session = activeSession, let device = activeDevice else {
      result(
        FlutterError(
          code: "no_session",
          message: "Kamera belum siap untuk ProRes. Coba lagi sebentar.",
          details: nil
        )
      )
      return
    }

    guard session.inputs.contains(where: {
      ($0 as? AVCaptureDeviceInput)?.device === device
    }) else {
      result(
        FlutterError(
          code: "no_session",
          message: "Sesi kamera sedang dibangun ulang. Coba lagi sebentar.",
          details: nil
        )
      )
      return
    }

    guard session.isRunning else {
      result(
        FlutterError(
          code: "session_stopped",
          message: "Sesi kamera sedang berhenti. Tunggu pratinjau hidup lagi.",
          details: nil
        )
      )
      return
    }

    let width = (args["width"] as? NSNumber)?.intValue ?? 1920
    let height = (args["height"] as? NSNumber)?.intValue ?? 1080
    let requestedFrameRate = (args["fps"] as? NSNumber)?.doubleValue ?? 24

    if proResUsesWriter {
      // AVCaptureMovieFileOutput cannot share the plugin's session (iOS fails
      // with -11803 and the preview freezes), so ProRes is written from the
      // plugin's own frames. No format switch, no extra capture output.
      if !startProResWriterFallback(session: session, result: result) {
        result(
          FlutterError(
            code: "no_video_output",
            message: "Output video kamera tidak ditemukan untuk ProRes.",
            details: nil
          )
        )
      }
      return
    }

    guard let format = proResFormat(
      for: device,
      width: width,
      height: height,
      frameRate: requestedFrameRate
    ) else {
      result(
        FlutterError(
          code: "unsupported",
          message: "Sensor ini tidak menyediakan format 10-bit 4:2:2, syarat "
            + "ProRes 422.",
          details: nil
        )
      )
      return
    }

    // `proResFormat` may fall back to a format that cannot honour the requested
    // rate. Setting a frame duration outside the format's range raises an
    // Objective-C exception, so clamp to what the format advertises.
    let ranges = format.videoSupportedFrameRateRanges
    let minRate = ranges.map { $0.minFrameRate }.min() ?? requestedFrameRate
    let maxRate = ranges.map { $0.maxFrameRate }.max() ?? requestedFrameRate
    let frameRate = min(max(requestedFrameRate, minRate), maxRate)

    let output = AVCaptureMovieFileOutput()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CINELENS_PRORES_\(Int(Date().timeIntervalSince1970)).mov"
    )
    try? FileManager.default.removeItem(at: url)

    proResPreviousPreset = session.sessionPreset
    proResPreviousFrameDurations = (
      min: device.activeVideoMinFrameDuration,
      max: device.activeVideoMaxFrameDuration
    )

    session.beginConfiguration()
    // inputPriority stops the session from overriding the 10-bit format we are
    // about to select (`AVCaptureSession.Preset` has no ProRes preset).
    session.sessionPreset = .inputPriority

    if #available(iOS 17.0, *),
       appleLogEnabled,
       !format.supportedColorSpaces.contains(.appleLog) {
      session.commitConfiguration()
      restoreProResConfiguration(session: session)
      result(
        FlutterError(
          code: "log_unsupported",
          message: "Format ProRes ini tidak mendukung Apple Log. Matikan "
            + "Apple Log atau ganti resolusi.",
          details: nil
        )
      )
      return
    }

    do {
      try device.lockForConfiguration()
      device.activeFormat = format
      let duration = CMTime(
        value: 1,
        timescale: CMTimeScale(max(1, Int(frameRate.rounded())))
      )
      device.activeVideoMinFrameDuration = duration
      device.activeVideoMaxFrameDuration = duration
      if #available(iOS 17.0, *), appleLogEnabled {
        // Log must not be tone-mapped by the HDR pipeline.
        if format.isVideoHDRSupported {
          device.automaticallyAdjustsVideoHDREnabled = false
          device.isVideoHDREnabled = false
        }
        device.activeColorSpace = .appleLog
      }
      device.unlockForConfiguration()
    } catch {
      session.commitConfiguration()
      restoreProResConfiguration(session: session)
      reapplyManualControls()
      result(
        FlutterError(
          code: "format_failed",
          message: "Format ProRes tidak dapat diaktifkan: "
            + error.localizedDescription,
          details: nil
        )
      )
      return
    }

    guard session.canAddOutput(output) else {
      session.commitConfiguration()
      restoreProResConfiguration(session: session)
      reapplyManualControls()
      result(
        FlutterError(
          code: "output_failed",
          message: "Sesi kamera menolak output ProRes tambahan.",
          details: nil
        )
      )
      return
    }
    session.addOutput(output)

    // The plugin captures audio in its own session, so the ProRes master would
    // be silent unless the microphone is attached here for the take. The input
    // is removed again when the take ends, before the plugin records its own
    // audio. If iOS refuses it, the take still proceeds as video-only.
    if let audioDevice = AVCaptureDevice.default(for: .audio),
       let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
       session.canAddInput(audioInput) {
      session.addInput(audioInput)
      proResAudioInput = audioInput
    }

    session.commitConfiguration()

    guard let connection = output.connection(with: .video) else {
      detachProResHardware(
        session: session,
        output: output,
        audioInput: proResAudioInput
      )
      proResAudioInput = nil
      result(
        FlutterError(
          code: "no_connection",
          message: "Koneksi video ProRes tidak tersedia.",
          details: nil
        )
      )
      return
    }

    // The codec list only becomes accurate after the new format is committed.
    guard output.availableVideoCodecTypes.contains(.proRes422) else {
      detachProResHardware(
        session: session,
        output: output,
        audioInput: proResAudioInput
      )
      proResAudioInput = nil
      result(
        FlutterError(
          code: "codec_unsupported",
          message: "Format aktif tidak bisa menulis ProRes 422 di perangkat "
            + "ini. Coba 1080p atau turunkan frame rate.",
          details: nil
        )
      )
      return
    }

    if #available(iOS 17.0, *) {
      let angle = videoRotationAngle()
      if connection.isVideoRotationAngleSupported(angle) {
        connection.videoRotationAngle = angle
      }
    } else if connection.isVideoOrientationSupported {
      connection.videoOrientation = currentVideoOrientation()
    }

    output.setOutputSettings(
      [AVVideoCodecKey: AVVideoCodecType.proRes422.rawValue],
      for: connection
    )

    proResStartResult = result
    proResOutput = output
    proResRecordingURL = url
    proResDidStart = false
    proResStartAttempts = 0

    // Switching to the 10-bit format makes the session reconfigure in the
    // background. Starting the movie file output before the connection is
    // active makes iOS fail the take with "Cannot Record", so wait for it.
    waitUntilProResReady(session: session, connection: connection) { [weak self] in
      self?.launchProResRecording()
    }
  }

  /// Polls (max ~2 s) until the session is running and the ProRes connection
  /// is live, then calls `completion` either way so a take is always attempted.
  private func waitUntilProResReady(
    session: AVCaptureSession,
    connection: AVCaptureConnection,
    attempt: Int = 0,
    completion: @escaping () -> Void
  ) {
    let ready = session.isRunning && !session.isInterrupted && connection.isActive
    if ready || attempt >= 14 {
      completion()
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
      self?.waitUntilProResReady(
        session: session,
        connection: connection,
        attempt: attempt + 1,
        completion: completion
      )
    }
  }

  private func launchProResRecording() {
    guard let output = proResOutput, let url = proResRecordingURL else { return }

    let delegate = ProResRecordingDelegate(
      onStart: { [weak self] in
        guard let self = self else { return }
        self.proResDidStart = true
        self.proResStartResult?(true)
        self.proResStartResult = nil
        // Reconfiguring the device drops the manual locks.
        self.reapplyManualControls()
      },
      onFinish: { [weak self] fileURL, error in
        self?.finishProResRecording(url: fileURL, error: error)
      }
    )
    proResDelegate = delegate
    try? FileManager.default.removeItem(at: url)
    output.startRecording(to: url, recordingDelegate: delegate)
  }

  /// Human-readable error including domain, code and reason, so a failure such
  /// as "Cannot Record" can be traced to its actual AVFoundation cause.
  private func describeRecordingError(_ error: Error) -> String {
    let ns = error as NSError
    var text = "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
    if let reason = ns.localizedFailureReason {
      text += " - \(reason)"
    }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
      text += " (\(underlying.domain) \(underlying.code))"
    }
    return text
  }

  // MARK: - ProRes fallback (AVAssetWriter)

  /// Starts a ProRes 422 take by tapping the frames of the plugin's
  /// `AVCaptureVideoDataOutput`. The preview keeps running because every frame
  /// is forwarded to the plugin's own delegate first. Frames are the plugin's
  /// 8-bit BGRA stream, so this is ProRes 422 encoded from 8-bit source, not a
  /// 10-bit sensor capture.
  private func startProResWriterFallback(
    session: AVCaptureSession,
    result: @escaping FlutterResult
  ) -> Bool {
    guard let dataOutput = session.outputs
      .compactMap({ $0 as? AVCaptureVideoDataOutput }).first else {
      return false
    }

    // Without the plugin's own delegate there is nothing to forward frames to,
    // and taking over would freeze the preview.
    guard let original = dataOutput.sampleBufferDelegate,
          let queue = dataOutput.sampleBufferCallbackQueue else {
      return false
    }

    var audioSession: AVCaptureSession?
    var audioOutput: AVCaptureAudioDataOutput?
    if let audioDevice = AVCaptureDevice.default(for: .audio),
       let audioInput = try? AVCaptureDeviceInput(device: audioDevice) {
      let candidateSession = AVCaptureSession()
      let candidateOutput = AVCaptureAudioDataOutput()
      if candidateSession.canAddInput(audioInput),
         candidateSession.canAddOutput(candidateOutput) {
        candidateSession.addInput(audioInput)
        candidateSession.addOutput(candidateOutput)
        audioSession = candidateSession
        audioOutput = candidateOutput
      }
    }

    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CINELENS_PRORES_\(Int(Date().timeIntervalSince1970)).mov"
    )
    let take = ProResWriterTake(
      url: url,
      original: original,
      wantsAudio: audioOutput != nil,
      audioSettings: audioOutput?
        .recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any]
    )
    take.onFirstFrame = { [weak self] in
      DispatchQueue.main.async { self?.writerTakeDidStart() }
    }
    take.onFailure = { [weak self] error in
      DispatchQueue.main.async { self?.writerTakeDidFail(error) }
    }

    writerTake = take
    writerDataOutput = dataOutput
    writerOriginalDelegate = original
    writerOriginalQueue = queue
    writerAudioSession = audioSession
    writerStartResult = result
    writerDidStart = false

    dataOutput.setSampleBufferDelegate(take, queue: queue)
    if let audioOutput = audioOutput, let audioSession = audioSession {
      audioOutput.setSampleBufferDelegate(
        take,
        queue: DispatchQueue(label: "cinelens.prores.audio")
      )
      DispatchQueue.global(qos: .userInitiated).async {
        audioSession.startRunning()
      }
    }

    // The failed attempt may have left the session stopped; frames are needed.
    if !session.isRunning {
      DispatchQueue.global(qos: .userInitiated).async {
        session.startRunning()
      }
    }

    let timeout = DispatchWorkItem { [weak self] in
      guard let self = self, !self.writerDidStart else { return }
      self.writerTakeDidFail(
        NSError(
          domain: "CineLens.ProRes",
          code: 2,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Kamera tidak mengirim frame video untuk ProRes."
          ]
        )
      )
    }
    writerTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: timeout)
    return true
  }

  private func writerTakeDidStart() {
    guard writerTake != nil, !writerDidStart else { return }
    writerDidStart = true
    writerTimeout?.cancel()
    writerTimeout = nil
    writerStartResult?(true)
    writerStartResult = nil
  }

  private func writerTakeDidFail(_ error: Error) {
    guard let take = writerTake else { return }
    // After the take began, the failure is reported when it is stopped.
    guard !writerDidStart else { return }

    writerTimeout?.cancel()
    writerTimeout = nil
    releaseWriterFeeds()
    take.cancel()
    writerTake = nil

    let startResult = writerStartResult
    writerStartResult = nil
    startResult?(
      FlutterError(
        code: "record_failed",
        message: describeRecordingError(error),
        details: nil
      )
    )
  }

  /// Gives the plugin its video delegate back and stops the audio tap.
  private func releaseWriterFeeds() {
    writerDataOutput?.setSampleBufferDelegate(
      writerOriginalDelegate,
      queue: writerOriginalQueue
    )
    writerDataOutput = nil
    writerOriginalDelegate = nil
    writerOriginalQueue = nil

    if let audioSession = writerAudioSession {
      DispatchQueue.global(qos: .userInitiated).async {
        audioSession.stopRunning()
      }
    }
    writerAudioSession = nil
  }

  private func stopProResWriterTake(
    _ take: ProResWriterTake,
    result: @escaping FlutterResult
  ) {
    writerTimeout?.cancel()
    writerTimeout = nil
    releaseWriterFeeds()

    take.finish { [weak self] url, error in
      DispatchQueue.main.async {
        self?.writerTake = nil
        self?.writerDidStart = false
        if let url = url {
          result(url.path)
        } else {
          let message = error.map { self?.describeRecordingError($0) ?? "" }
            ?? "Rekaman ProRes gagal."
          result(
            FlutterError(code: "record_failed", message: message, details: nil)
          )
        }
      }
    }
  }

  private func stopProResRecording(result: @escaping FlutterResult) {
    if let take = writerTake {
      stopProResWriterTake(take, result: result)
      return
    }

    guard let output = proResOutput, output.isRecording else {
      result(
        FlutterError(
          code: "not_recording",
          message: "Tidak ada rekaman ProRes yang aktif.",
          details: nil
        )
      )
      return
    }

    proResStopResult = result
    output.stopRecording()
  }

  /// Removes the temporary ProRes output/microphone input and returns the
  /// plugin's session to its original preset (which re-selects a normal
  /// format). Restoring through the preset is what keeps the plugin's own
  /// photo/video paths working after a take.
  private func detachProResHardware(
    session: AVCaptureSession,
    output: AVCaptureOutput?,
    audioInput: AVCaptureDeviceInput?
  ) {
    session.beginConfiguration()
    if let output = output,
       session.outputs.contains(where: { $0 === output }) {
      session.removeOutput(output)
    }
    if let audioInput = audioInput,
       session.inputs.contains(where: { $0 === audioInput }) {
      session.removeInput(audioInput)
    }
    session.commitConfiguration()
    restoreProResConfiguration(session: session)
    reapplyManualControls()
  }

  /// Called by the recording delegate once the `.mov` is closed on disk.
  private func finishProResRecording(url: URL?, error: Error?) {
    // The take failed before it ever started: retry up to twice. The first
    // retry drops the microphone input (it can clash with the plugin's own
    // audio session); both retries give the session more time to settle.
    if error != nil,
       !proResDidStart,
       proResStartAttempts < 2,
       proResStartResult != nil,
       proResOutput != nil,
       let session = activeSession {
      proResStartAttempts += 1
      if let audioInput = proResAudioInput {
        session.beginConfiguration()
        if session.inputs.contains(where: { $0 === audioInput }) {
          session.removeInput(audioInput)
        }
        session.commitConfiguration()
        proResAudioInput = nil
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
        self?.launchProResRecording()
      }
      return
    }

    let neverStarted = !proResDidStart
    let startResult = proResStartResult
    let stopResult = proResStopResult
    proResStartResult = nil
    proResStopResult = nil

    if let session = activeSession {
      detachProResHardware(
        session: session,
        output: proResOutput,
        audioInput: proResAudioInput
      )
    }
    proResOutput = nil
    proResDelegate = nil
    proResAudioInput = nil
    proResRecordingURL = nil
    proResDidStart = false
    proResStartAttempts = 0

    // AVCaptureMovieFileOutput refused to start (typically -11803 on the
    // plugin's shared session). Fall back to writing ProRes with AVAssetWriter
    // from the frames the plugin already streams, instead of failing the take.
    if error != nil,
       neverStarted,
       let startResult = startResult,
       let session = activeSession,
       startProResWriterFallback(session: session, result: startResult) {
      return
    }

    var failure: Error? = error
    if let error = error,
       (error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey]
         as? Bool == true {
      // iOS reports a "failed" recording that is actually complete (usually
      // because the disk filled after the last frame was written).
      failure = nil
    }

    if let failure = failure {
      let flutterError = FlutterError(
        code: "record_failed",
        message: describeRecordingError(failure),
        details: nil
      )
      startResult?(flutterError)
      stopResult?(flutterError)
      return
    }

    startResult?(true)
    if let stopResult = stopResult {
      stopResult(url?.path)
    } else if let path = url?.path {
      // The take ended without `stopProRes` (call, background): let Dart
      // finalise whatever reached the disk.
      nativeChannel?.invokeMethod("proResFinished", arguments: ["path": path])
    }
  }

  /// Picks the 10-bit 4:2:2 format closest to the requested frame size.
  ///
  /// Per TN3104, ProRes 422 is only writable from an `x422` sensor format, so
  /// the requested 1080p/4K size is a preference, not a guarantee.
  private func proResFormat(
    for device: AVCaptureDevice,
    width: Int,
    height: Int,
    frameRate: Double
  ) -> AVCaptureDevice.Format? {
    let tenBit422 = kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
    let candidates = device.formats.filter {
      CMFormatDescriptionGetMediaSubType($0.formatDescription) == tenBit422
    }
    guard !candidates.isEmpty else { return nil }

    func dimensions(_ format: AVCaptureDevice.Format) -> (Int, Int) {
      let size = CMVideoFormatDescriptionGetDimensions(
        format.formatDescription
      )
      return (Int(size.width), Int(size.height))
    }

    let matchingFrameRate = candidates.filter { format in
      format.videoSupportedFrameRateRanges.contains { range in
        frameRate >= range.minFrameRate - 0.01
          && frameRate <= range.maxFrameRate + 0.01
      }
    }
    let pool = matchingFrameRate.isEmpty ? candidates : matchingFrameRate

    if let exact = pool.first(where: {
      let size = dimensions($0)
      return size.0 == width && size.1 == height
    }) {
      return exact
    }

    let requestedLong = max(width, height)
    let sorted = pool.sorted {
      let lhs = dimensions($0)
      let rhs = dimensions($1)
      return lhs.0 * lhs.1 > rhs.0 * rhs.1
    }
    let fitting = sorted.first {
      let size = dimensions($0)
      return max(size.0, size.1) <= requestedLong
    }
    return fitting ?? sorted.last
  }

  /// Returns the plugin's session to the preset it used before the take.
  ///
  /// Assigning a preset also re-selects a matching device format, which is what
  /// keeps still capture and normal H.264 recording usable afterwards. A new
  /// format resets the frame duration, so the plugin's chosen fps is restored
  /// too — otherwise the next 24 fps take would record at the format default.
  private func restoreProResConfiguration(session: AVCaptureSession) {
    guard let previousPreset = proResPreviousPreset else { return }

    session.beginConfiguration()
    session.sessionPreset = previousPreset
    session.commitConfiguration()

    proResPreviousPreset = nil

    if let device = activeDevice,
       let durations = proResPreviousFrameDurations {
      do {
        try device.lockForConfiguration()
        device.activeVideoMinFrameDuration = durations.min
        device.activeVideoMaxFrameDuration = durations.max
        device.unlockForConfiguration()
      } catch {
        // Left at the format default; the plugin re-applies fps on rebuild.
      }
    }
    proResPreviousFrameDurations = nil
  }

  private func currentVideoOrientation() -> AVCaptureVideoOrientation {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first
    let interface = scene?.interfaceOrientation ?? .portrait
    // UIInterfaceOrientation and AVCaptureVideoOrientation share raw values.
    return AVCaptureVideoOrientation(rawValue: interface.rawValue) ?? .portrait
  }

  /// `AVCaptureConnection.videoRotationAngle` replaces the deprecated
  /// `videoOrientation` on iOS 17; 0° is landscape-right in sensor space.
  @available(iOS 17.0, *)
  private func videoRotationAngle() -> CGFloat {
    switch currentVideoOrientation() {
    case .landscapeRight:
      return 0
    case .portrait:
      return 90
    case .landscapeLeft:
      return 180
    case .portraitUpsideDown:
      return 270
    @unknown default:
      return 90
    }
  }

  // MARK: - Still photography

  /// Applies the LUT at the still's native resolution and returns JPEG bytes.
  ///
  /// Doing this in Core Image keeps the full sensor detail and avoids the huge
  /// PNG that the Dart renderer used to produce for 12–48 MP captures.
  private func exportGradedPhoto(
    inputBytes: Data,
    matrix: [Double],
    toneId: String?,
    intensity: Double,
    effects: FilmEffects?,
    importedLut: ImportedLut?,
    anamorphic: Bool,
    quality: Double,
    result: @escaping FlutterResult
  ) {
    guard matrix.count == 20 else {
      result(
        FlutterError(
          code: "bad_args",
          message: "A colour matrix must have 20 entries.",
          details: nil
        )
      )
      return
    }

    guard let source = CIImage(
      data: inputBytes,
      options: [.applyOrientationProperty: true]
    ) else {
      result(
        FlutterError(
          code: "decode_failed",
          message: "The captured photo could not be decoded.",
          details: nil
        )
      )
      return
    }

    var output: CIImage
    if let imported = importedLut,
       let look = FilmEngine.importedLook(imported, effects: effects) {
      // An imported .cube is used verbatim; the viewfinder only approximates
      // it with a fitted matrix, the export gets the real thing.
      output = look.apply(to: source, frameIndex: Int.random(in: 0..<4096))
    } else if let look = FilmEngine.look(
      toneId: toneId,
      intensity: intensity,
      effects: effects
    ) {
      // Authentic film emulation: colour cube, halation, bloom, grain.
      output = look.apply(to: source, frameIndex: Int.random(in: 0..<4096))
    } else {
      // Custom tones and imported presets keep their matrix, then the film
      // effects are layered on top when the user dialled any in.
      var graded = AppDelegate.colorMatrixImage(matrix, to: source)
      if let effects = effects, !effects.isNeutral {
        graded = FilmEngine.effectsLook(effects).apply(
          to: graded,
          frameIndex: Int.random(in: 0..<4096)
        )
      }
      output = graded
    }

    if anamorphic {
      let frame = output.extent
      let targetHeight = frame.width / 2.39
      if frame.height > targetHeight + 0.5 {
        let barHeight = (frame.height - targetHeight) / 2.0
        let activeRect = CGRect(
          x: frame.minX,
          y: frame.minY + barHeight,
          width: frame.width,
          height: targetHeight
        )
        let blackBackground = CIImage(color: .black).cropped(to: frame)
        output = output.cropped(to: activeRect)
          .composited(over: blackBackground)
      }
    }

    // JPEG encoders are happiest when the extent starts at the origin.
    let extent = output.extent
    if extent.origin != .zero {
      output = output.transformed(
        by: CGAffineTransform(
          translationX: -extent.origin.x,
          y: -extent.origin.y
        )
      )
    }

    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
      result(
        FlutterError(
          code: "colorspace_failed",
          message: "sRGB is not available on this device.",
          details: nil
        )
      )
      return
    }

    let context = AppDelegate.gradingContext
    let clampedQuality = min(max(quality, 0.5), 1.0)

    // `CIContext.jpegRepresentation(of:colorSpace:options:)` and its
    // `lossyCompressionQuality` key were both renamed in recent SDKs, which
    // broke the device build. ImageIO has carried the same JPEG API since
    // iOS 4, so the quality control lives there instead.
    guard let cgImage = context.createCGImage(
      output,
      from: output.extent,
      format: .RGBA8,
      colorSpace: colorSpace
    ) else {
      result(
        FlutterError(
          code: "encode_failed",
          message: "The graded photo could not be rendered.",
          details: nil
        )
      )
      return
    }

    let jpeg = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      jpeg as CFMutableData,
      "public.jpeg" as CFString,
      1,
      nil
    ) else {
      result(
        FlutterError(
          code: "encode_failed",
          message: "The graded photo could not be encoded.",
          details: nil
        )
      )
      return
    }

    CGImageDestinationAddImage(
      destination,
      cgImage,
      [kCGImageDestinationLossyCompressionQuality: clampedQuality] as CFDictionary
    )

    guard CGImageDestinationFinalize(destination) else {
      result(
        FlutterError(
          code: "encode_failed",
          message: "The graded photo could not be encoded.",
          details: nil
        )
      )
      return
    }

    result(FlutterStandardTypedData(bytes: jpeg as Data))
  }

  // MARK: - Video

  /// Builds the Core Image composition shared by the H.264 export and the
  /// ProRes bake, so both produce the same orientation, look and colour tags.
  ///
  /// Returning `nil` means the asset has no usable video track; the caller then
  /// answers with the untouched input instead of leaving Flutter waiting.
  private static func gradedVideoComposition(
    asset: AVURLAsset,
    matrix: [Double],
    filmLook: FilmLook?,
    effectLook: FilmLook?,
    anamorphic: Bool,
    frameRate: Int32
  ) async -> AVMutableVideoComposition? {
    // Read the track orientation first: the recorder may store portrait
    // footage in landscape sensor space plus a rotation transform, and a
    // video composition does not apply that transform on its own. Ignoring
    // it is what makes the exported clip look tilted.
    var preferredTransform = CGAffineTransform.identity
    var naturalSize = CGSize.zero
    var detectedRate = frameRate

    if let track = try? await asset.loadTracks(withMediaType: .video).first {
      if let transform = try? await track.load(.preferredTransform) {
        preferredTransform = transform
      }
      if let size = try? await track.load(.naturalSize) {
        naturalSize = size
      }
      if detectedRate <= 0 {
        let nominal = (try? await track.load(.nominalFrameRate)) ?? 0
        detectedRate = nominal > 1 ? Int32(nominal.rounded()) : 30
      }
    }

    let orientedRect = CGRect(origin: .zero, size: naturalSize)
      .applying(preferredTransform)
    let renderSize = CGSize(
      width: abs(orientedRect.width).rounded(),
      height: abs(orientedRect.height).rounded()
    )
    let fps = max(detectedRate, 1)
    let gradingContext = AppDelegate.gradingContext

    let composition = AVMutableVideoComposition(asset: asset) { request in
      let sourceExtent = request.sourceImage.extent
      var output: CIImage

      if let look = filmLook {
        // The compositor time gives every frame its own grain pattern.
        let frameIndex = Int(
          (request.compositionTime.seconds * Double(fps)).rounded()
        )
        output = look.apply(to: request.sourceImage, frameIndex: frameIndex)
          .cropped(to: sourceExtent)
      } else if let effectLook = effectLook {
        // Effects-only: the tone matrix still owns the colour.
        let frameIndex = Int(
          (request.compositionTime.seconds * Double(fps)).rounded()
        )
        let graded = AppDelegate.colorMatrixImage(
          matrix,
          to: request.sourceImage
        )
        output = effectLook
          .apply(to: graded, frameIndex: frameIndex)
          .cropped(to: sourceExtent)
      } else {
        output = AppDelegate.colorMatrixImage(matrix, to: request.sourceImage)
          .cropped(to: sourceExtent)
      }

      // Some iOS versions hand the compositor an already oriented image.
      // Only rotate when the frame is still in the sensor's native space.
      let alreadyOriented =
        abs(sourceExtent.width - renderSize.width) < 1.0
        && abs(sourceExtent.height - renderSize.height) < 1.0

      if !preferredTransform.isIdentity && !alreadyOriented {
        output = output.transformed(by: preferredTransform)
      }

      // Keep the origin at (0, 0) so the composition renders inside renderSize.
      let rotatedExtent = output.extent
      if rotatedExtent.origin != .zero {
        output = output.transformed(
          by: CGAffineTransform(
            translationX: -rotatedExtent.origin.x,
            y: -rotatedExtent.origin.y
          )
        )
      }

      if anamorphic {
        let frameExtent = output.extent
        let targetHeight = frameExtent.width / 2.39
        if frameExtent.height > targetHeight + 0.5 {
          let barHeight = (frameExtent.height - targetHeight) / 2.0
          let activeRect = CGRect(
            x: frameExtent.origin.x,
            y: frameExtent.origin.y + barHeight,
            width: frameExtent.width,
            height: targetHeight
          )
          let blackBackground = CIImage(color: .black).cropped(to: frameExtent)
          output = output.cropped(to: activeRect)
            .composited(over: blackBackground)
        }
      }

      request.finish(with: output, context: gradingContext)
    }

    if renderSize.width > 0, renderSize.height > 0 {
      composition.renderSize = renderSize
    }
    composition.frameDuration = CMTime(value: 1, timescale: fps)
    // Tag the result as Rec.709 so players and the Photos app interpret the
    // graded frames exactly like the live preview does.
    composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
    composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

    return composition
  }

  /// Runs an export session and guarantees exactly one Flutter reply.
  ///
  /// The watchdog covers the case where AVFoundation never calls the completion
  /// handler (the old reader/writer pair could stall forever when an append
  /// failed), so the spinner can never hang again.
  private static func finishExport(
    _ session: AVAssetExportSession,
    outputURL: URL,
    inputPath: String,
    timeout: TimeInterval,
    channel: FlutterMethodChannel?,
    done: ReplyOnce
  ) {
    DispatchQueue.main.async {
      let reporter = ExportProgressReporter(
        session: session,
        channel: channel
      )

      session.exportAsynchronously {
        reporter.stop()
        switch session.status {
        case .completed:
          done.send(outputURL.path)
        case .failed, .cancelled:
          try? FileManager.default.removeItem(at: outputURL)
          done.send(
            FlutterError(
              code: "export_failed",
              message: session.error?.localizedDescription
                ?? "Video export failed.",
              details: nil
            )
          )
        default:
          done.send(inputPath)
        }
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
        switch session.status {
        case .completed:
          reporter.stop()
          done.send(outputURL.path)
        case .exporting, .waiting:
          // Stuck: cancel and hand back the raw take rather than hang.
          session.cancelExport()
          reporter.stop()
          try? FileManager.default.removeItem(at: outputURL)
          done.send(inputPath)
        default:
          reporter.stop()
          done.send(inputPath)
        }
      }
    }
  }

  private func exportGradedVideo(
    inputPath: String,
    matrix: [Double],
    toneId: String?,
    intensity: Double,
    effects: FilmEffects?,
    importedLut: ImportedLut?,
    anamorphic: Bool,
    fps: Int32,
    result: @escaping FlutterResult
  ) {
    let done = ReplyOnce(result)
    guard matrix.count == 20 else {
      done.send(inputPath)
      return
    }

    let frameRate = fps > 0 ? fps : 24
    let filmLook = importedLut.flatMap {
      FilmEngine.importedLook($0, effects: effects)
    } ?? FilmEngine.look(
      toneId: toneId,
      intensity: intensity,
      effects: effects
    )
    let effectLook: FilmLook? = {
      guard filmLook == nil, let effects = effects, !effects.isNeutral else {
        return nil
      }
      return FilmEngine.effectsLook(effects)
    }()
    let asset = AVURLAsset(url: URL(fileURLWithPath: inputPath))
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "CINELENS_24FPS_\(Int(Date().timeIntervalSince1970)).mov"
      )

    Task {
      guard let composition = await AppDelegate.gradedVideoComposition(
        asset: asset,
        matrix: matrix,
        filmLook: filmLook,
        effectLook: effectLook,
        anamorphic: anamorphic,
        frameRate: frameRate
      ) else {
        done.send(inputPath)
        return
      }

      guard let exportSession = AVAssetExportSession(
        asset: asset,
        presetName: AVAssetExportPresetHighestQuality
      ) else {
        done.send(
          FlutterError(
            code: "export_unavailable",
            message: "Perangkat ini tidak bisa mengekspor video bergrade.",
            details: nil
          )
        )
        return
      }

      exportSession.outputURL = outputURL
      exportSession.outputFileType = .mov
      exportSession.videoComposition = composition
      exportSession.shouldOptimizeForNetworkUse = true

      let duration = (try? await asset.load(.duration))?.seconds ?? 0
      // Generous enough for long 4K takes, short enough that a wedged export
      // still answers while the user is looking at the screen.
      let timeout = min(max(240.0, duration * 12.0), 900.0)
      AppDelegate.finishExport(
        exportSession,
        outputURL: outputURL,
        inputPath: inputPath,
        timeout: timeout,
        channel: self.nativeChannel,
        done: done
      )
    }
  }

  // MARK: - ProRes bake

  /// Re-encodes a ProRes master with the tone + film look burned in.
  ///
  /// The output is written as ProRes 422 10-bit again, so the file is still an
  /// edit-friendly master: only the look is burned in, never the codec. Any
  /// failure returns the untouched path, because losing the take is worse than
  /// a flat master.
  private func bakeLookIntoProRes(
    inputPath: String,
    matrix: [Double],
    toneId: String?,
    intensity: Double,
    effects: FilmEffects?,
    importedLut: ImportedLut?,
    result: @escaping FlutterResult
  ) {
    let done = ReplyOnce(result)
    let identity: [Double] = [
      1, 0, 0, 0, 0,
      0, 1, 0, 0, 0,
      0, 0, 1, 0, 0,
      0, 0, 0, 1, 0,
    ]
    let isIdentityMatrix = matrix.count != 20
      || zip(matrix, identity).allSatisfy { pair in
        abs(pair.0 - pair.1) < 0.0001
      }

    let look = importedLut.flatMap {
      FilmEngine.importedLook($0, effects: effects)
    } ?? FilmEngine.look(
      toneId: toneId,
      intensity: intensity,
      effects: effects
    )
    let effectLook: FilmLook? = {
      guard look == nil, let effects = effects, !effects.isNeutral else {
        return nil
      }
      return FilmEngine.effectsLook(effects)
    }()

    if look == nil && effectLook == nil && isIdentityMatrix {
      done.send(inputPath)
      return
    }

    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "CINELENS_BAKED_\(Int(Date().timeIntervalSince1970)).mov"
      )

    let asset = AVURLAsset(url: URL(fileURLWithPath: inputPath))

    Task {
      guard let composition = await AppDelegate.gradedVideoComposition(
        asset: asset,
        matrix: matrix,
        filmLook: look,
        effectLook: effectLook,
        anamorphic: false,
        frameRate: 0
      ) else {
        done.send(inputPath)
        return
      }

      // Re-encoding an existing ProRes master through AVAssetExportSession
      // keeps the codec (ProRes 422) and, unlike the old reader/writer loop,
      // carries the audio track over and cannot wedge the Flutter call.
      guard let exportSession = AVAssetExportSession(
        asset: asset,
        presetName: AVAssetExportPresetAppleProRes422LPCM
      ) else {
        done.send(
          FlutterError(
            code: "prores_unavailable",
            message: "Perangkat ini tidak bisa menulis ProRes.",
            details: nil
          )
        )
        return
      }

      exportSession.outputURL = outputURL
      exportSession.outputFileType = .mov
      exportSession.videoComposition = composition
      exportSession.shouldOptimizeForNetworkUse = false

      let duration = (try? await asset.load(.duration))?.seconds ?? 0
      let timeout = min(max(300.0, duration * 25.0), 1800.0)
      AppDelegate.finishExport(
        exportSession,
        outputURL: outputURL,
        inputPath: inputPath,
        timeout: timeout,
        channel: self.nativeChannel,
        done: done
      )
    }
  }

  /// Applies the 20-coefficient colour matrix Dart sends.
  ///
  /// The bias comes in 0…255 so it matches the Flutter `ColorFilter.matrix`
  /// the viewfinder uses; Core Image wants 0…1.
  static func colorMatrixImage(_ matrix: [Double], to image: CIImage) -> CIImage {
    guard matrix.count == 20,
          let colorFilter = CIFilter(name: "CIColorMatrix") else {
      return image
    }

    colorFilter.setValue(image, forKey: kCIInputImageKey)
    colorFilter.setValue(
      CIVector(x: matrix[0], y: matrix[1], z: matrix[2], w: matrix[3]),
      forKey: "inputRVector"
    )
    colorFilter.setValue(
      CIVector(x: matrix[5], y: matrix[6], z: matrix[7], w: matrix[8]),
      forKey: "inputGVector"
    )
    colorFilter.setValue(
      CIVector(x: matrix[10], y: matrix[11], z: matrix[12], w: matrix[13]),
      forKey: "inputBVector"
    )
    colorFilter.setValue(
      CIVector(x: matrix[15], y: matrix[16], z: matrix[17], w: matrix[18]),
      forKey: "inputAVector"
    )
    colorFilter.setValue(
      CIVector(
        x: matrix[4] / 255.0,
        y: matrix[9] / 255.0,
        z: matrix[14] / 255.0,
        w: matrix[19] / 255.0
      ),
      forKey: "inputBiasVector"
    )

    return colorFilter.outputImage?.cropped(to: image.extent) ?? image
  }
}

/// Bridges `AVCaptureMovieFileOutput` callbacks back to `AppDelegate`.
///
/// `AVCaptureFileOutputRecordingDelegate` requires an object, and the output
/// keeps only a weak reference, so `AppDelegate` stores it in `proResDelegate`
/// for the duration of the take.
final class ProResRecordingDelegate: NSObject,
  AVCaptureFileOutputRecordingDelegate {
  private let onStart: () -> Void
  private let onFinish: (URL?, Error?) -> Void

  init(
    onStart: @escaping () -> Void,
    onFinish: @escaping (URL?, Error?) -> Void
  ) {
    self.onStart = onStart
    self.onFinish = onFinish
  }

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didStartRecordingTo fileURL: URL,
    from connections: [AVCaptureConnection]
  ) {
    // AVFoundation may call this off the main thread; the Flutter method
    // result and the session reconfiguration must run on the UI thread.
    DispatchQueue.main.async {
      self.onStart()
    }
  }

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection],
    error: Error?
  ) {
    DispatchQueue.main.async {
      self.onFinish(outputFileURL, error)
    }
  }
}


/// Writes ProRes 422 with `AVAssetWriter` from the plugin's video frames.
///
/// It is installed as the sample-buffer delegate of the plugin's
/// `AVCaptureVideoDataOutput` and forwards every callback to the original
/// delegate first, so the live preview is unaffected. Each frame is copied into
/// a buffer from the writer's own pool before it is handed to the encoder:
/// holding on to the capture buffers themselves starves the camera's small
/// buffer pool and freezes the preview (worst at 4K). Frames are dropped, never
/// queued, when the encoder falls behind. Audio comes from a separate
/// audio-only capture session whose buffers share the same clock.
final class ProResWriterTake: NSObject,
  AVCaptureVideoDataOutputSampleBufferDelegate,
  AVCaptureAudioDataOutputSampleBufferDelegate {
  let url: URL
  var onFirstFrame: (() -> Void)?
  var onFailure: ((Error) -> Void)?

  private let original: AVCaptureVideoDataOutputSampleBufferDelegate?
  private let wantsAudio: Bool
  private let audioSettings: [String: Any]?
  private let lock = NSLock()
  private var writer: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var audioInput: AVAssetWriterInput?
  private var sessionStart: CMTime?
  private var frameWidth = 0
  private var frameHeight = 0
  private var finishing = false
  private var failure: Error?

  init(
    url: URL,
    original: AVCaptureVideoDataOutputSampleBufferDelegate?,
    wantsAudio: Bool,
    audioSettings: [String: Any]?
  ) {
    self.url = url
    self.original = original
    self.wantsAudio = wantsAudio
    self.audioSettings = audioSettings
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    if output is AVCaptureVideoDataOutput {
      // The preview must always get the frame first.
      original?.captureOutput?(output, didOutput: sampleBuffer, from: connection)
      handleVideo(sampleBuffer)
    } else {
      handleAudio(sampleBuffer)
    }
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didDrop sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    original?.captureOutput?(output, didDrop: sampleBuffer, from: connection)
  }

  private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
    guard CMSampleBufferDataIsReady(sampleBuffer),
          let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    lock.lock()
    defer { lock.unlock() }
    if finishing || failure != nil { return }

    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let width = CVPixelBufferGetWidth(source)
    let height = CVPixelBufferGetHeight(source)

    if writer == nil {
      do {
        try startWriter(
          width: width,
          height: height,
          pixelFormat: CVPixelBufferGetPixelFormatType(source),
          firstPTS: pts
        )
      } catch {
        failure = error
        onFailure?(error)
        return
      }
      onFirstFrame?()
    }

    guard let writer = writer,
          let input = videoInput,
          let adaptor = adaptor else { return }

    if writer.status == .failed {
      if failure == nil, let writerError = writer.error {
        failure = writerError
        onFailure?(writerError)
      }
      return
    }

    // Drop frames the encoder is not ready for, or whose size changed (for
    // example after a rotation), instead of blocking the camera.
    guard writer.status == .writing,
          input.isReadyForMoreMediaData,
          width == frameWidth,
          height == frameHeight,
          let pool = adaptor.pixelBufferPool else { return }

    var copy: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &copy) == kCVReturnSuccess,
          let destination = copy,
          ProResWriterTake.copyPixels(from: source, to: destination) else {
      return
    }

    if !adaptor.append(destination, withPresentationTime: pts), failure == nil {
      if let writerError = writer.error {
        failure = writerError
        onFailure?(writerError)
      }
    }
  }

  private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

    lock.lock()
    defer { lock.unlock() }
    guard !finishing,
          failure == nil,
          let writer = writer,
          writer.status == .writing,
          let input = audioInput,
          let start = sessionStart else { return }

    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    if CMTimeCompare(pts, start) < 0 { return }
    if input.isReadyForMoreMediaData {
      input.append(sampleBuffer)
    }
  }

  /// Plane-by-plane copy that tolerates different row strides.
  private static func copyPixels(
    from source: CVPixelBuffer,
    to destination: CVPixelBuffer
  ) -> Bool {
    CVPixelBufferLockBaseAddress(source, .readOnly)
    CVPixelBufferLockBaseAddress(destination, [])
    defer {
      CVPixelBufferUnlockBaseAddress(destination, [])
      CVPixelBufferUnlockBaseAddress(source, .readOnly)
    }

    func copyRows(
      _ from: UnsafeMutableRawPointer?,
      _ fromStride: Int,
      _ to: UnsafeMutableRawPointer?,
      _ toStride: Int,
      rows: Int
    ) -> Bool {
      guard let from = from, let to = to else { return false }
      if fromStride == toStride {
        memcpy(to, from, fromStride * rows)
      } else {
        let bytes = min(fromStride, toStride)
        for row in 0..<rows {
          memcpy(to + row * toStride, from + row * fromStride, bytes)
        }
      }
      return true
    }

    if CVPixelBufferIsPlanar(source) {
      let planes = CVPixelBufferGetPlaneCount(source)
      guard planes == CVPixelBufferGetPlaneCount(destination) else { return false }
      for plane in 0..<planes {
        guard copyRows(
          CVPixelBufferGetBaseAddressOfPlane(source, plane),
          CVPixelBufferGetBytesPerRowOfPlane(source, plane),
          CVPixelBufferGetBaseAddressOfPlane(destination, plane),
          CVPixelBufferGetBytesPerRowOfPlane(destination, plane),
          rows: CVPixelBufferGetHeightOfPlane(source, plane)
        ) else { return false }
      }
      return true
    }

    return copyRows(
      CVPixelBufferGetBaseAddress(source),
      CVPixelBufferGetBytesPerRow(source),
      CVPixelBufferGetBaseAddress(destination),
      CVPixelBufferGetBytesPerRow(destination),
      rows: CVPixelBufferGetHeight(source)
    )
  }

  /// Caller must hold `lock`.
  private func startWriter(
    width: Int,
    height: Int,
    pixelFormat: OSType,
    firstPTS: CMTime
  ) throws {
    try? FileManager.default.removeItem(at: url)
    let newWriter = try AVAssetWriter(outputURL: url, fileType: .mov)

    let video = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.proRes422.rawValue,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height
      ]
    )
    video.expectsMediaDataInRealTime = true
    guard newWriter.canAdd(video) else {
      throw NSError(
        domain: "CineLens.ProRes",
        code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Perangkat ini tidak bisa menulis video ProRes 422."
        ]
      )
    }
    newWriter.add(video)

    // Must exist before `startWriting()` so the writer builds its buffer pool.
    let newAdaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: video,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
      ]
    )

    if wantsAudio {
      let settings: [String: Any] = audioSettings ?? [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVNumberOfChannelsKey: 1,
        AVSampleRateKey: 44100,
        AVEncoderBitRateKey: 96000
      ]
      let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
      audio.expectsMediaDataInRealTime = true
      if newWriter.canAdd(audio) {
        newWriter.add(audio)
        audioInput = audio
      }
    }

    guard newWriter.startWriting() else {
      throw newWriter.error ?? NSError(
        domain: "CineLens.ProRes",
        code: 3,
        userInfo: [
          NSLocalizedDescriptionKey: "Writer ProRes tidak bisa dimulai."
        ]
      )
    }
    newWriter.startSession(atSourceTime: firstPTS)

    writer = newWriter
    videoInput = video
    adaptor = newAdaptor
    sessionStart = firstPTS
    frameWidth = width
    frameHeight = height
  }

  /// Abandons the take without producing a file.
  func cancel() {
    lock.lock()
    finishing = true
    let current = writer
    lock.unlock()
    if current?.status == .writing {
      current?.cancelWriting()
    }
    try? FileManager.default.removeItem(at: url)
  }

  func finish(completion: @escaping (URL?, Error?) -> Void) {
    lock.lock()
    finishing = true
    let current = writer
    let video = videoInput
    let audio = audioInput
    let recordedFailure = failure
    lock.unlock()

    guard let writer = current, writer.status == .writing else {
      completion(
        nil,
        recordedFailure ?? current?.error ?? NSError(
          domain: "CineLens.ProRes",
          code: 4,
          userInfo: [
            NSLocalizedDescriptionKey: "Tidak ada frame yang berhasil direkam."
          ]
        )
      )
      return
    }

    video?.markAsFinished()
    audio?.markAsFinished()
    let fileURL = url
    writer.finishWriting {
      if writer.status == .completed {
        completion(fileURL, nil)
      } else {
        completion(nil, writer.error)
      }
    }
  }
}


// MARK: - Film emulation

/// User-facing strength of the optical effects, decoded from the `look`
/// dictionary Dart sends with every capture.
///
/// The colour of a built-in stock still comes from [FilmStockParams]; these
/// values replace its tuned effect amounts so grain, halation, bloom and
/// vignette can be dialled independently.
struct FilmEffects {
  let grain: Double
  let grainSize: Double
  let halation: Double
  let bloom: Double
  let vignette: Double

  /// True when every effect is off, so the renderer can skip the passes.
  var isNeutral: Bool {
    grain <= 0.001
      && halation <= 0.001
      && bloom <= 0.001
      && vignette <= 0.001
  }

  static func from(_ args: [String: Any]) -> FilmEffects? {
    guard let raw = args["look"] as? [String: Any] else { return nil }

    func unit(_ key: String) -> Double {
      let value = (raw[key] as? NSNumber)?.doubleValue ?? 0
      return min(max(value, 0), 1)
    }

    return FilmEffects(
      grain: unit("grain"),
      grainSize: unit("grainSize"),
      halation: unit("halation"),
      bloom: unit("bloom"),
      vignette: unit("vignette")
    )
  }
}

/// An imported `.cube` LUT, already converted by Dart to a raw RGBA float
/// payload next to its dimension and mix.
struct ImportedLut {
  let url: URL
  let dimension: Int
  let mix: Double

  static func from(_ args: [String: Any]) -> ImportedLut? {
    guard let raw = args["look"] as? [String: Any],
          let path = raw["lutPath"] as? String,
          !path.isEmpty,
          let dimension = (raw["lutSize"] as? NSNumber)?.intValue,
          dimension > 1,
          FileManager.default.fileExists(atPath: path) else {
      return nil
    }

    let mix = (raw["lutMix"] as? NSNumber)?.doubleValue ?? 1.0
    return ImportedLut(
      url: URL(fileURLWithPath: path),
      dimension: dimension,
      mix: min(max(mix, 0), 1)
    )
  }
}

/// Parameters of one film look. These are tuned by eye to capture the
/// character of each stock (contrast curve, colour crosstalk, highlight
/// desaturation, tinted shadows/highlights, grain, halation); they are not
/// measured from sensitometric data.
struct FilmStockParams {
  /// 3x3 row-major channel mix applied in linear light (dye crosstalk).
  let mix: [Double]
  /// Exposure shift in stops, applied before the curve.
  let ev: Double
  /// Per-channel S-curve steepness and pivot (differences give colour
  /// separation in shadows and highlights, like the layers of a real film).
  let k: [Double]
  let pivot: [Double]
  let sat: Double
  /// Saturation lost in the highlights / shadows (film desaturates both).
  let hlDesat: Double
  let shDesat: Double
  let shadowTint: [Double]
  let hlTint: [Double]
  /// Output black and white points (a print never reaches pure 0 or 1).
  let black: Double
  let white: Double
  /// Panchromatic channel weights for black and white stocks.
  let mono: [Double]?
  let grain: Double
  let grainSize: Double
  let halation: Double
  let bloom: Double
  let vignette: Double
  let soften: Double
}

extension FilmStockParams {
  /// Swaps the stock's tuned effect strengths for the user's sliders.
  ///
  /// The colour half of the stock (mix, curve, tints, black/white point) is
  /// kept, so the tone still looks like itself; only grain, halation, bloom,
  /// vignette and softness follow the film-emulation panel. Dart sends grain
  /// size as 0…1, which maps onto a 0.45–1.2 px blur so the result stays fine
  /// instead of turning into digital noise blocks.
  func withEffects(_ effects: FilmEffects) -> FilmStockParams {
    FilmStockParams(
      mix: mix,
      ev: ev,
      k: k,
      pivot: pivot,
      sat: sat,
      hlDesat: hlDesat,
      shDesat: shDesat,
      shadowTint: shadowTint,
      hlTint: hlTint,
      black: black,
      white: white,
      mono: mono,
      grain: effects.grain,
      grainSize: max(0.3, 0.45 + effects.grainSize * 0.75),
      halation: effects.halation,
      bloom: effects.bloom,
      vignette: effects.vignette,
      soften: soften
    )
  }
}

/// A film look prepared for one render: the 3D LUT is built once (and cached)
/// and the value is immutable, so video export can use it from every frame
/// thread of the composition.
struct FilmLook {
  let params: FilmStockParams
  let intensity: Double
  let cubeData: Data

  /// Edge length of [cubeData]. Built-in stocks are 33³; an imported `.cube`
  /// keeps its own size (17³, 33³, 65³…).
  var cubeSize: Int = 33

  /// Mix between the ungraded image and the cube result (0…1).
  var cubeMix: Double = 1.0

  /// False when the look is only the film effects over an existing matrix.
  var usesCube: Bool = true

  /// Strength applied to grain/halation/bloom/vignette. `nil` keeps the
  /// legacy behaviour of scaling them with [intensity].
  var effectScale: Double?

  /// Renders the full look: colour cube, softness, halation, bloom, grain and
  /// vignette. `frameIndex` moves the grain so video grain is alive.
  func apply(to image: CIImage, frameIndex: Int) -> CIImage {
    let extent = image.extent
    guard extent.width > 1, extent.height > 1,
          extent.width.isFinite, extent.height.isFinite else {
      return image
    }
    let scale = Double(max(extent.width, extent.height)) / 1920.0
    let p = params
    let fx = effectScale ?? intensity

    // 1. Colour: tone curve, crosstalk, tints, black/white point.
    var output = image
    var cubeApplied = false
    if usesCube, let cube = CIFilter(name: "CIColorCubeWithColorSpace"),
       let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
      cube.setValue(image, forKey: kCIInputImageKey)
      cube.setValue(cubeSize, forKey: "inputCubeDimension")
      cube.setValue(cubeData, forKey: "inputCubeData")
      cube.setValue(srgb, forKey: "inputColorSpace")
      if let graded = cube.outputImage {
        let mixed = FilmLook.scaled(graded, by: cubeMix)
          .composited(over: image)
        output = mixed.cropped(to: extent)
        cubeApplied = true
      }
    }
    if usesCube, !cubeApplied, let cube = CIFilter(name: "CIColorCube") {
      // The working space is sRGB, so the plain cube is equivalent.
      cube.setValue(image, forKey: kCIInputImageKey)
      cube.setValue(cubeSize, forKey: "inputCubeDimension")
      cube.setValue(cubeData, forKey: "inputCubeData")
      if let graded = cube.outputImage {
        output = FilmLook.scaled(graded, by: cubeMix)
          .composited(over: image)
          .cropped(to: extent)
      }
    }

    // 2. Softness: film is never as crisp as a digital sensor.
    let soften = p.soften * fx
    if soften > 0.001 {
      let blurred = output.clampedToExtent()
        .applyingGaussianBlur(sigma: 0.9 * scale)
        .cropped(to: extent)
      output = FilmLook.scaled(blurred, by: soften).composited(over: output)
    }

    // 3. Halation: red-orange glow around highlights (light bouncing off the
    //    film base), and a wide white bloom like a diffusion filter. Both are
    //    low-frequency, so they share one quarter-resolution pass.
    let halation = p.halation * fx
    let bloom = p.bloom * fx
    var glowLayers: [FilmLook.GlowLayer] = []
    if halation > 0.001 {
      glowLayers.append(
        FilmLook.GlowLayer(
          threshold: 0.80,
          tint: [1.0, 0.32, 0.10],
          amount: halation * 1.6,
          sigma: 11.0 * scale
        )
      )
    }
    if bloom > 0.001 {
      glowLayers.append(
        FilmLook.GlowLayer(
          threshold: 0.62,
          tint: [1.0, 1.0, 1.0],
          amount: bloom * 1.4,
          sigma: 30.0 * scale
        )
      )
    }
    if !glowLayers.isEmpty {
      output = FilmLook.glow(over: output, extent: extent, layers: glowLayers)
    }

    // 4. Grain: monochrome noise, soft-light blended so it lives in the
    //    mid-tones, re-seeded every frame.
    let grain = p.grain * fx
    if grain > 0.001 {
      output = FilmLook.addGrain(
        to: output,
        extent: extent,
        amount: grain,
        size: p.grainSize * scale,
        frameIndex: frameIndex
      )
    }

    // 5. Vignette.
    let vignette = p.vignette * fx
    if vignette > 0.001 {
      output = FilmLook.addVignette(to: output, extent: extent, amount: vignette)
    }

    return output.cropped(to: extent)
  }

  /// Premultiplied scale of an opaque image, used for partial mixes.
  private static func scaled(_ image: CIImage, by factor: Double) -> CIImage {
    let f = CGFloat(factor)
    return image.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(x: f, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: f, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: f, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: f)
      ]
    )
  }

  /// One glow request: highlights above [threshold], tinted, added at
  /// [amount] with a blur of [sigma] (in full-resolution pixels).
  private struct GlowLayer {
    let threshold: Double
    let tint: [Double]
    let amount: Double
    let sigma: Double
  }

  /// Screens every requested glow over [base] with a single downscale, blur and
  /// upscale round trip.
  ///
  /// Glow is a low-frequency effect, so evaluating it at a quarter of the
  /// resolution is visually identical but roughly sixteen times cheaper per
  /// pass. Video export used to run two full-resolution Lanczos glows per
  /// frame, which is what made saving slow.
  private static func glow(
    over base: CIImage,
    extent: CGRect,
    layers: [GlowLayer]
  ) -> CIImage {
    let reduction = 4.0
    let downscale = CGAffineTransform(scaleX: 1 / reduction, y: 1 / reduction)
    let smallExtent = extent.applying(downscale)
    let smallBase = base.transformed(by: downscale).cropped(to: smallExtent)

    var combined: CIImage?
    for layer in layers {
      let k = 1.0 / (1.0 - layer.threshold)

      func row(_ t: Double) -> CIVector {
        CIVector(
          x: CGFloat(t * layer.amount * k * 0.2126),
          y: CGFloat(t * layer.amount * k * 0.7152),
          z: CGFloat(t * layer.amount * k * 0.0722),
          w: 0
        )
      }

      // Luma above the threshold, tinted and scaled, clamped to 0...1.
      let extracted = smallBase.applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": row(layer.tint[0]),
          "inputGVector": row(layer.tint[1]),
          "inputBVector": row(layer.tint[2]),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputBiasVector": CIVector(
            x: CGFloat(-layer.tint[0] * layer.amount * k * layer.threshold),
            y: CGFloat(-layer.tint[1] * layer.amount * k * layer.threshold),
            z: CGFloat(-layer.tint[2] * layer.amount * k * layer.threshold),
            w: 1
          )
        ]
      ).applyingFilter(
        "CIColorClamp",
        parameters: [
          "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
        ]
      )

      let blurred = extracted.clampedToExtent()
        .applyingGaussianBlur(sigma: max(layer.sigma / reduction, 0.5))
        .cropped(to: smallExtent)

      if let previous = combined {
        combined = blurred
          .applyingFilter(
            "CIScreenBlendMode",
            parameters: [kCIInputBackgroundImageKey: previous]
          )
          .cropped(to: smallExtent)
      } else {
        combined = blurred
      }
    }

    guard let smallGlow = combined else { return base }

    let upscale = CGAffineTransform(scaleX: reduction, y: reduction)
    let upscaled = smallGlow.transformed(by: upscale).cropped(to: extent)

    return upscaled
      .applyingFilter(
        "CIScreenBlendMode",
        parameters: [kCIInputBackgroundImageKey: base]
      )
      .cropped(to: extent)
  }

  private static func addGrain(
    to base: CIImage,
    extent: CGRect,
    amount: Double,
    size: Double,
    frameIndex: Int
  ) -> CIImage {
    guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else {
      return base
    }

    // Grain is built at half resolution: the blur then costs a quarter of the
    // pixels and the upscale keeps the specks film-sized. The gain below still
    // uses the full-resolution radius, so the slider feels the same.
    let reduction = 2.0
    let downscale = CGAffineTransform(scaleX: 1 / reduction, y: 1 / reduction)
    let smallExtent = extent.applying(downscale)

    // A different offset per frame makes the grain move like real film.
    let offsetX = CGFloat((frameIndex &* 7919) % 2048)
    let offsetY = CGFloat((frameIndex &* 104729) % 2048)
    // CIRandomGenerator also randomises alpha. Colour filters un-premultiply
    // before working, so a tiny random alpha blew the noise up into harsh
    // black and white speckles. Forcing alpha to 1 keeps the raw 0...1 values.
    let shifted = noise
      .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
      .cropped(to: smallExtent)
      .settingAlphaOne(in: smallExtent)

    // Average the three noise channels into one monochrome value.
    let third = CGFloat(1.0 / 3.0)
    let mono = shifted.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(x: third, y: third, z: third, w: 0),
        "inputGVector": CIVector(x: third, y: third, z: third, w: 0),
        "inputBVector": CIVector(x: third, y: third, z: third, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
      ]
    )

    // Blur sets the grain size; the gain restores the contrast the blur
    // removes so the strength stays comparable across sizes.
    let sigma = max(0.55 * size + 0.35, 0.35)
    let softenedSmall = mono.clampedToExtent()
      .applyingGaussianBlur(sigma: max(sigma / reduction, 0.25))
      .cropped(to: smallExtent)
    let softened = softenedSmall
      .transformed(by: CGAffineTransform(scaleX: reduction, y: reduction))
      .cropped(to: extent)

    let rawDeviation = 0.1667 / max(1.0, 2.0 * sigma * Double.pi.squareRoot())
    let gain = CGFloat((amount * 0.30) / rawDeviation)
    let bias = 0.5 - 0.5 * gain
    let centred = softened.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1)
      ]
    )

    // Safety net: whatever the noise statistics turn out to be, the grain can
    // never push a pixel more than a soft-light step away from the picture.
    let limited = centred.applyingFilter(
      "CIColorClamp",
      parameters: [
        "inputMinComponents": CIVector(x: 0.2, y: 0.2, z: 0.2, w: 0),
        "inputMaxComponents": CIVector(x: 0.8, y: 0.8, z: 0.8, w: 1)
      ]
    )

    return limited
      .applyingFilter(
        "CISoftLightBlendMode",
        parameters: [kCIInputBackgroundImageKey: base]
      )
      .cropped(to: extent)
  }

  private static func addVignette(
    to base: CIImage,
    extent: CGRect,
    amount: Double
  ) -> CIImage {
    let corner = Double(hypot(extent.width, extent.height)) / 2.0
    let edge = CGFloat(max(0.0, 1.0 - amount))
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)

    func color(_ value: CGFloat) -> CIColor {
      if let srgb = srgb,
         let c = CIColor(
           red: value, green: value, blue: value, alpha: 1, colorSpace: srgb
         ) {
        return c
      }
      return CIColor(red: value, green: value, blue: value, alpha: 1)
    }

    guard let gradient = CIFilter(
      name: "CIRadialGradient",
      parameters: [
        "inputCenter": CIVector(x: extent.midX, y: extent.midY),
        "inputRadius0": CGFloat(0.30 * corner),
        "inputRadius1": CGFloat(0.95 * corner),
        "inputColor0": color(1.0),
        "inputColor1": color(edge)
      ]
    )?.outputImage else {
      return base
    }

    return gradient.cropped(to: extent)
      .applyingFilter(
        "CIMultiplyBlendMode",
        parameters: [kCIInputBackgroundImageKey: base]
      )
      .cropped(to: extent)
  }
}

enum FilmEngine {
  private static let cacheLock = NSLock()
  private static var cubeCache: [String: Data] = [:]

  /// Returns the film look for a built-in tone id, or `nil` for the neutral
  /// "standard" tone, custom tones and imported presets (those keep the
  /// plain colour-matrix grade).
  ///
  /// [effects] overrides the stock's tuned grain/halation/bloom/vignette:
  /// the cube keeps the stock's colour, but the optical effects follow the
  /// sliders in the film-emulation panel.
  static func look(
    toneId: String?,
    intensity: Double,
    effects: FilmEffects? = nil
  ) -> FilmLook? {
    guard let toneId = toneId, let stock = stocks[toneId] else { return nil }
    let clamped = min(max(intensity, 0.0), 1.0)
    let params = effects.map { stock.withEffects($0) } ?? stock

    if effects != nil {
      // The colour cube does not depend on the effect strengths, so a
      // per-capture cube is cheap; no cache entry is created for it.
      return FilmLook(
        params: params,
        intensity: clamped,
        cubeData: makeCube(params: params, intensity: clamped),
        effectScale: 1.0
      )
    }

    let key = "\(toneId)-\(Int((clamped * 100.0).rounded()))"

    cacheLock.lock()
    let cached = cubeCache[key]
    cacheLock.unlock()

    let cube = cached ?? makeCube(params: params, intensity: clamped)
    if cached == nil {
      cacheLock.lock()
      cubeCache[key] = cube
      cacheLock.unlock()
    }
    return FilmLook(params: params, intensity: clamped, cubeData: cube)
  }

  /// Builds a look around an imported `.cube` payload.
  ///
  /// The cube is used verbatim (with [ImportedLut.mix] as a dissolve), so the
  /// exported file gets the exact look the user authored. The film effects
  /// still come from [effects].
  static func importedLook(
    _ imported: ImportedLut,
    effects: FilmEffects?
  ) -> FilmLook? {
    guard let data = importedCubeData(
      path: imported.url.path,
      dimension: imported.dimension
    ) else { return nil }

    let params = effects.map { neutralParams.withEffects($0) } ?? neutralParams
    return FilmLook(
      params: params,
      intensity: 1.0,
      cubeData: data,
      cubeSize: imported.dimension,
      cubeMix: imported.mix,
      usesCube: true,
      effectScale: effects == nil ? nil : 1.0
    )
  }

  /// Effects-only look, used for custom colour matrices that have no cube.
  static func effectsLook(_ effects: FilmEffects) -> FilmLook {
    FilmLook(
      params: neutralParams.withEffects(effects),
      intensity: 1.0,
      cubeData: Data(),
      usesCube: false,
      effectScale: 1.0
    )
  }

  /// Neutral colour model: the cube (or the caller's matrix) owns the colour.
  static let neutralParams = FilmStockParams(
    mix: [1, 0, 0, 0, 1, 0, 0, 0, 1],
    ev: 0,
    k: [0.01, 0.01, 0.01],
    pivot: [0.5, 0.5, 0.5],
    sat: 1,
    hlDesat: 0,
    shDesat: 0,
    shadowTint: [0, 0, 0],
    hlTint: [0, 0, 0],
    black: 0,
    white: 1,
    mono: nil,
    grain: 0,
    grainSize: 1,
    halation: 0,
    bloom: 0,
    vignette: 0,
    soften: 0
  )

  /// Parsed `.cube` payloads, keyed by path + dimension.
  private static var importedCache: [String: Data] = [:]

  private static func importedCubeData(path: String, dimension: Int) -> Data? {
    let key = "\(path)|\(dimension)"
    cacheLock.lock()
    let cached = importedCache[key]
    cacheLock.unlock()
    if let cached = cached { return cached }

    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
      return nil
    }
    guard data.count >= dimension * dimension * dimension * 16 else {
      return nil
    }

    cacheLock.lock()
    if importedCache.count >= 4 { importedCache.removeAll() }
    importedCache[key] = data
    cacheLock.unlock()
    return data
  }

  // MARK: Colour model

  private static func srgbToLinear(_ c: Double) -> Double {
    let v = max(c, 0.0)
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
  }

  private static func linearToSrgb(_ l: Double) -> Double {
    let v = max(l, 0.0)
    return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055
  }

  private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(max((x - a) / (b - a), 0.0), 1.0)
    return t * t * (3.0 - 2.0 * t)
  }

  /// Normalised logistic S-curve: 0 -> 0 and 1 -> 1, steeper in the middle.
  private static func sCurve(_ v: Double, k: Double, pivot: Double) -> Double {
    func logistic(_ x: Double) -> Double { 1.0 / (1.0 + exp(-k * (x - pivot))) }
    return (logistic(v) - logistic(0.0)) / (logistic(1.0) - logistic(0.0))
  }

  /// Film response for one sRGB-encoded colour.
  static func filmColor(
    r: Double,
    g: Double,
    b: Double,
    params p: FilmStockParams
  ) -> (Double, Double, Double) {
    var lr = srgbToLinear(r)
    var lg = srgbToLinear(g)
    var lb = srgbToLinear(b)

    if let m = p.mono {
      let y = m[0] * lr + m[1] * lg + m[2] * lb
      lr = y
      lg = y
      lb = y
    } else {
      let m = p.mix
      let nr = m[0] * lr + m[1] * lg + m[2] * lb
      let ng = m[3] * lr + m[4] * lg + m[5] * lb
      let nb = m[6] * lr + m[7] * lg + m[8] * lb
      lr = nr
      lg = ng
      lb = nb
    }

    let gain = pow(2.0, p.ev)
    let er = linearToSrgb(min(max(lr * gain, 0.0), 4.0))
    let eg = linearToSrgb(min(max(lg * gain, 0.0), 4.0))
    let eb = linearToSrgb(min(max(lb * gain, 0.0), 4.0))

    var outR = sCurve(er, k: p.k[0], pivot: p.pivot[0])
    var outG = sCurve(eg, k: p.k[1], pivot: p.pivot[1])
    var outB = sCurve(eb, k: p.k[2], pivot: p.pivot[2])

    let luma = 0.2126 * outR + 0.7152 * outG + 0.0722 * outB
    let saturation = p.sat
      * (1.0 - p.hlDesat * smoothstep(0.55, 1.0, luma))
      * (1.0 - p.shDesat * (1.0 - smoothstep(0.0, 0.25, luma)))
    outR = luma + (outR - luma) * saturation
    outG = luma + (outG - luma) * saturation
    outB = luma + (outB - luma) * saturation

    let shadowWeight = (1.0 - luma) * (1.0 - luma)
    let highlightWeight = luma * luma
    outR += p.shadowTint[0] * shadowWeight + p.hlTint[0] * highlightWeight
    outG += p.shadowTint[1] * shadowWeight + p.hlTint[1] * highlightWeight
    outB += p.shadowTint[2] * shadowWeight + p.hlTint[2] * highlightWeight

    let span = p.white - p.black
    func finish(_ v: Double) -> Double {
      min(max(p.black + v * span, 0.0), 1.0)
    }
    return (finish(outR), finish(outG), finish(outB))
  }

  /// 33^3 RGBA float cube, red varying fastest (the layout Core Image expects),
  /// blended towards the identity cube by `intensity`.
  private static func makeCube(params: FilmStockParams, intensity: Double) -> Data {
    let n = 33
    let last = Double(n - 1)
    var values = [Float]()
    values.reserveCapacity(n * n * n * 4)

    for bi in 0..<n {
      for gi in 0..<n {
        for ri in 0..<n {
          let r = Double(ri) / last
          let g = Double(gi) / last
          let b = Double(bi) / last
          let film = filmColor(r: r, g: g, b: b, params: params)
          values.append(Float(r + (film.0 - r) * intensity))
          values.append(Float(g + (film.1 - g) * intensity))
          values.append(Float(b + (film.2 - b) * intensity))
          values.append(1.0)
        }
      }
    }
    return values.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  // MARK: Stocks

  private static let stocks: [String: FilmStockParams] = [
      "kodak_2383": FilmStockParams(
        mix: [1.06, -0.03, -0.03, -0.02, 1.04, -0.02, -0.04, -0.01, 1.05],
        ev: -0.04,
        k: [6.2, 5.9, 5.6], pivot: [0.53, 0.53, 0.54],
        sat: 1.06, hlDesat: 0.3, shDesat: 0.1,
        shadowTint: [-0.016, 0.018, 0.046], hlTint: [0.052, 0.022, -0.046],
        black: 0.02, white: 0.96, mono: nil,
        grain: 0.3, grainSize: 1.0,
        halation: 0.45, bloom: 0.16,
        vignette: 0.2, soften: 0.12
      ),
      "teal_orange": FilmStockParams(
        mix: [1.12, -0.06, -0.06, -0.04, 1.04, 0.0, -0.12, 0.06, 1.06],
        ev: -0.02,
        k: [6.0, 5.6, 5.6], pivot: [0.52, 0.54, 0.55],
        sat: 1.1, hlDesat: 0.18, shDesat: 0.05,
        shadowTint: [-0.065, 0.032, 0.1], hlTint: [0.095, 0.034, -0.085],
        black: 0.012, white: 0.97, mono: nil,
        grain: 0.24, grainSize: 1.0,
        halation: 0.4, bloom: 0.14,
        vignette: 0.22, soften: 0.08
      ),
      "fuji_velvia": FilmStockParams(
        mix: [1.1, -0.06, -0.04, -0.05, 1.12, -0.07, -0.04, -0.08, 1.12],
        ev: -0.05,
        k: [7.0, 7.2, 7.0], pivot: [0.54, 0.54, 0.54],
        sat: 1.18, hlDesat: 0.08, shDesat: 0.0,
        shadowTint: [-0.012, 0.0, 0.03], hlTint: [0.012, 0.006, -0.016],
        black: 0.0, white: 0.985, mono: nil,
        grain: 0.12, grainSize: 0.8,
        halation: 0.18, bloom: 0.06,
        vignette: 0.16, soften: 0.0
      ),
      "noir_bw": FilmStockParams(
        mix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
        ev: -0.04,
        k: [7.2, 7.2, 7.2], pivot: [0.54, 0.54, 0.54],
        sat: 1.0, hlDesat: 0.0, shDesat: 0.0,
        shadowTint: [0.0, 0.0, 0.0], hlTint: [0.0, 0.0, 0.0],
        black: 0.014, white: 0.975, mono: [0.34, 0.52, 0.14],
        grain: 0.42, grainSize: 1.2,
        halation: 0.3, bloom: 0.12,
        vignette: 0.36, soften: 0.1
      ),
      "cinelens_flat": FilmStockParams(
        mix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
        ev: 0.0,
        k: [2.2, 2.2, 2.2], pivot: [0.5, 0.5, 0.5],
        sat: 0.8, hlDesat: 0.12, shDesat: 0.12,
        shadowTint: [0.0, 0.0, 0.0], hlTint: [0.0, 0.0, 0.0],
        black: 0.1, white: 0.9, mono: nil,
        grain: 0.0, grainSize: 1.0,
        halation: 0.0, bloom: 0.0,
        vignette: 0.0, soften: 0.0
      ),
      "golden_hour": FilmStockParams(
        mix: [1.08, -0.04, -0.04, 0.0, 1.02, -0.02, -0.1, 0.0, 1.1],
        ev: 0.04,
        k: [5.4, 5.2, 4.8], pivot: [0.5, 0.51, 0.54],
        sat: 1.1, hlDesat: 0.18, shDesat: 0.05,
        shadowTint: [0.034, 0.012, -0.03], hlTint: [0.09, 0.038, -0.078],
        black: 0.016, white: 0.965, mono: nil,
        grain: 0.22, grainSize: 1.0,
        halation: 0.55, bloom: 0.24,
        vignette: 0.22, soften: 0.12
      ),
      "vintage_16mm": FilmStockParams(
        mix: [1.02, 0.07, -0.07, 0.04, 1.02, -0.04, -0.05, 0.09, 0.94],
        ev: 0.03,
        k: [4.6, 4.4, 4.0], pivot: [0.52, 0.52, 0.54],
        sat: 0.82, hlDesat: 0.28, shDesat: 0.22,
        shadowTint: [0.03, 0.04, -0.018], hlTint: [0.05, 0.03, -0.05],
        black: 0.075, white: 0.925, mono: nil,
        grain: 0.55, grainSize: 1.5,
        halation: 0.4, bloom: 0.2,
        vignette: 0.42, soften: 0.3
      )
  ]
}
