import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Flutter
import ImageIO
import UIKit

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
        self?.exportGradedVideo(
          inputPath: inputPath,
          matrix: matrix,
          anamorphic: anamorphic,
          fps: fps,
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
        self?.exportGradedPhoto(
          inputBytes: inputBytes,
          matrix: matrix,
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
    if proResOutput?.isRecording == true {
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

  private func stopProResRecording(result: @escaping FlutterResult) {
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

    guard let colorFilter = CIFilter(name: "CIColorMatrix") else {
      result(
        FlutterError(
          code: "filter_unavailable",
          message: "CIColorMatrix is not available on this device.",
          details: nil
        )
      )
      return
    }

    colorFilter.setValue(source, forKey: kCIInputImageKey)
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

    var output = colorFilter.outputImage?.cropped(to: source.extent)
      ?? source

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

  private func exportGradedVideo(
    inputPath: String,
    matrix: [Double],
    anamorphic: Bool,
    fps: Int32,
    result: @escaping FlutterResult
  ) {
    guard matrix.count == 20 else {
      result(inputPath)
      return
    }

    let frameRate = fps > 0 ? fps : 24
    let asset = AVURLAsset(url: URL(fileURLWithPath: inputPath))
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("CINELENS_24FPS_\(Int(Date().timeIntervalSince1970)).mov")

    Task {
      // Read the track orientation first: the recorder may store portrait
      // footage in landscape sensor space plus a rotation transform, and a
      // video composition does not apply that transform on its own. Ignoring
      // it is what makes the exported clip look tilted.
      var preferredTransform = CGAffineTransform.identity
      var naturalSize = CGSize.zero

      if let track = try? await asset.loadTracks(withMediaType: .video).first {
        if let transform = try? await track.load(.preferredTransform) {
          preferredTransform = transform
        }
        if let size = try? await track.load(.naturalSize) {
          naturalSize = size
        }
      }

      let orientedRect = CGRect(origin: .zero, size: naturalSize)
        .applying(preferredTransform)
      let renderSize = CGSize(
        width: abs(orientedRect.width).rounded(),
        height: abs(orientedRect.height).rounded()
      )
      let gradingContext = AppDelegate.gradingContext

      let composition = AVMutableVideoComposition(asset: asset) { request in
        let sourceExtent = request.sourceImage.extent
        let source = request.sourceImage.clampedToExtent()

        guard let colorFilter = CIFilter(name: "CIColorMatrix") else {
          request.finish(with: request.sourceImage, context: nil)
          return
        }

        colorFilter.setValue(source, forKey: kCIInputImageKey)
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

        var output = colorFilter.outputImage?.cropped(to: sourceExtent)
          ?? request.sourceImage

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
            output = output.cropped(to: activeRect).composited(over: blackBackground)
          }
        }

        request.finish(with: output, context: gradingContext)
      }

      if renderSize.width > 0, renderSize.height > 0 {
        composition.renderSize = renderSize
      }
      composition.frameDuration = CMTime(value: 1, timescale: frameRate)
      // Tag the result as Rec.709 so players and the Photos app interpret the
      // graded frames exactly like the live preview does.
      composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
      composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
      composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

      guard let exportSession = AVAssetExportSession(
        asset: asset,
        presetName: AVAssetExportPresetHighestQuality
      ) else {
        DispatchQueue.main.async { result(inputPath) }
        return
      }

      exportSession.outputURL = outputURL
      exportSession.outputFileType = .mov
      exportSession.videoComposition = composition
      exportSession.shouldOptimizeForNetworkUse = true
      exportSession.exportAsynchronously {
        DispatchQueue.main.async {
          if exportSession.status == .completed {
            result(outputURL.path)
          } else {
            result(inputPath)
          }
        }
      }
    }
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
