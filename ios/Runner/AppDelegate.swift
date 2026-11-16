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
          look: AppDelegate.filmLook(from: args),
          result: result
        )

      case "bakeLookIntoProRes":
        guard let args = call.arguments as? [String: Any],
              let inputPath = args["inputPath"] as? String,
              let matrix = args["matrix"] as? [Double] else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.bakeLookIntoProRes(
          inputPath: inputPath,
          matrix: matrix,
          look: AppDelegate.filmLook(from: args),
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
          look: AppDelegate.filmLook(from: args),
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
  /// running connection is supported. `.auto` asks iOS for the best mode the
  /// active format can sustain (cinematic at 1080p, standard at 4K) instead of
  /// forcing a mode the format would reject.
  private func observeVideoStabilization() {
    let center = NotificationCenter.default

    center.addObserver(
      forName: AVCaptureSession.didStartRunningNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let session = notification.object as? AVCaptureSession else { return }
      // The plugin runs a second, audio-only session; it must not be treated as
      // the camera session or it would reset the stabilisation readout.
      guard session.connections.contains(where: {
        $0.output is AVCaptureVideoDataOutput
      }) else { return }
      self?.enableStabilization(on: session)
      self?.captureActiveDevice(from: session)
    }

    center.addObserver(
      forName: AVCaptureSession.didStopRunningNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self = self,
            let session = notification.object as? AVCaptureSession,
            session === self.activeSession else { return }
      self.reportStabilization(active: false, mode: 0)
    }
  }

  /// Turns on low-latency stabilisation for the plugin's capture pipeline.
  ///
  /// The `camera` plugin previews through an `AVCaptureVideoDataOutput` that is
  /// blitted into a Flutter texture, not an `AVCaptureVideoPreviewLayer`.
  /// Cinematic mode buffers several frames before stabilising, which through
  /// that path shows up as heavy panning lag and erratic, pulsating motion, so
  /// only `.standard` is requested: it steadies the frame from the gyro without
  /// the extra buffering.
  private func enableStabilization(on session: AVCaptureSession) {
    let connections = stabilizableConnections(in: session)
    guard let connection = connections.first else {
      reportStabilization(active: false, mode: 0)
      return
    }

    for candidate in connections {
      candidate.preferredVideoStabilizationMode = .standard
    }

    // The active mode settles asynchronously once the connection reconfigures.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak connection] in
      guard let connection = connection else { return }
      let mode = connection.activeVideoStabilizationMode
      self?.reportStabilization(active: mode != .off, mode: Int(mode.rawValue))
    }
  }

  /// The connections stabilisation may touch: the plugin's preview/record data
  /// output only. The ProRes movie output gets its own connection, which must
  /// stay untouched or the 10-bit format negotiations start fighting.
  private func stabilizableConnections(
    in session: AVCaptureSession
  ) -> [AVCaptureConnection] {
    session.connections.filter {
      $0.isVideoStabilizationSupported && $0.output is AVCaptureVideoDataOutput
    }
  }

  /// Enables/disables stabilisation around a ProRes take.
  ///
  /// A stabilisation mode the 10-bit 4:2:2 format cannot sustain makes iOS
  /// reject the format switch, which is what broke ProRes recording, so it is
  /// parked while the recorder owns the session and restored afterwards.
  private func setStabilizationEnabled(
    _ enabled: Bool,
    on session: AVCaptureSession
  ) {
    for connection in stabilizableConnections(in: session) {
      connection.preferredVideoStabilizationMode = enabled ? .standard : .off
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
    activeSession = session

    let device = session.inputs
      .compactMap { ($0 as? AVCaptureDeviceInput)?.device }
      .first { $0.hasMediaType(.video) }

    guard let device = device else { return }
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

    // ProRes 422 needs a 10-bit sensor format to encode from.
    // `AVCaptureMovieFileOutput.availableVideoCodecTypes` cannot answer this
    // here: it only reports codecs once the output is attached to the running
    // session, which belongs to the camera plugin. `proResFormat` is the single
    // source of truth so the switch and the recorder never disagree.
    let supportsProRes = proResFormat(
      for: device,
      width: 1920,
      height: 1080,
      frameRate: 24
    ) != nil

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

    // A stabilisation mode the 10-bit 4:2:2 format cannot sustain makes iOS
    // refuse the format switch, which is the known "ProRes gagal merekam" case.
    setStabilizationEnabled(false, on: session)

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

    session.commitConfiguration()

    guard let connection = output.connection(with: .video) else {
      detachProResHardware(session: session, output: output)
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
    guard let codec = preferredProResCodec(
      from: output.availableVideoCodecTypes
    ) else {
      detachProResHardware(session: session, output: output)
      result(
        FlutterError(
          code: "codec_unsupported",
          message: "Format aktif tidak bisa menulis ProRes di perangkat ini. "
            + "Coba 1080p atau turunkan frame rate.",
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
      [AVVideoCodecKey: codec.rawValue],
      for: connection
    )

    let delegate = ProResRecordingDelegate(
      onStart: { [weak self] in
        guard let self = self else { return }
        self.proResStartResult?(true)
        self.proResStartResult = nil
        // Reconfiguring the device drops the manual locks.
        self.reapplyManualControls()
      },
      onFinish: { [weak self] fileURL, error in
        self?.finishProResRecording(url: fileURL, error: error)
      }
    )

    proResStartResult = result
    proResOutput = output
    proResDelegate = delegate
    output.startRecording(to: url, recordingDelegate: delegate)
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
    output: AVCaptureOutput?
  ) {
    session.beginConfiguration()
    if let output = output,
       session.outputs.contains(where: { $0 === output }) {
      session.removeOutput(output)
    }
    session.commitConfiguration()
    restoreProResConfiguration(session: session)
    reapplyManualControls()
    // Stabilisation is restored only once the plugin's normal format is back.
    setStabilizationEnabled(true, on: session)
  }

  /// Called by the recording delegate once the `.mov` is closed on disk.
  private func finishProResRecording(url: URL?, error: Error?) {
    let startResult = proResStartResult
    let stopResult = proResStopResult
    proResStartResult = nil
    proResStopResult = nil

    if let session = activeSession {
      detachProResHardware(session: session, output: proResOutput)
    }
    proResOutput = nil
    proResDelegate = nil

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
        message: failure.localizedDescription,
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

  /// Picks the 10-bit format to record ProRes from, preferring full-range
  /// 4:2:2 and falling back to the (identical-bit-depth) video-range variant.
  ///
  /// ProRes 422 is only writable from a 10-bit sensor format, so the requested
  /// 1080p/4K size is a preference, not a guarantee. Full-range is preferred
  /// because it keeps the most headroom for grading.
  private func proResFormat(
    for device: AVCaptureDevice,
    width: Int,
    height: Int,
    frameRate: Double
  ) -> AVCaptureDevice.Format? {
    let fullRange422 = kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
    let videoRange422 = kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
    let fullRange420 = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    let videoRange420 = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

    /// 4:2:2 first: it is the format ProRes 422 officially records from. The
    /// 4:2:0 variant is a last-resort fallback for hardware/HDR modes that only
    /// advertise 10-bit 4:2:0.
    func rank(_ format: AVCaptureDevice.Format) -> Int {
      let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
      if subtype == fullRange422 || subtype == videoRange422 { return 2 }
      if subtype == fullRange420 || subtype == videoRange420 { return 1 }
      return 0
    }

    let candidates = device.formats.filter { rank($0) > 0 }
    guard let bestRank = candidates.map(rank).max() else { return nil }

    // Drop the lower-quality variants as soon as a 4:2:2 format exists.
    let preferred = candidates.filter { rank($0) == bestRank }

    func dimensions(_ format: AVCaptureDevice.Format) -> (Int, Int) {
      let size = CMVideoFormatDescriptionGetDimensions(
        format.formatDescription
      )
      return (Int(size.width), Int(size.height))
    }

    let matchingFrameRate = preferred.filter { format in
      format.videoSupportedFrameRateRanges.contains { range in
        frameRate >= range.minFrameRate - 0.01
          && frameRate <= range.maxFrameRate + 0.01
      }
    }
    let pool = matchingFrameRate.isEmpty ? preferred : matchingFrameRate

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

  // MARK: - Film look

  /// Film emulation parameters shared by the photo, video and ProRes graders.
  ///
  /// Flutter sends this as a dictionary with every render so the exported
  /// stills and clips keep matching the viewfinder. All strengths are 0…1.
  struct FilmLook {
    let lutURL: URL?
    let lutDimension: Int
    let lutMix: Double
    let grain: Double
    let grainSize: Double
    let halation: Double
    let bloom: Double
    let vignette: Double

    static let none = FilmLook(
      lutURL: nil,
      lutDimension: 0,
      lutMix: 0,
      grain: 0,
      grainSize: 0,
      halation: 0,
      bloom: 0,
      vignette: 0
    )

    var isNeutral: Bool {
      lutURL == nil
        && grain <= 0.001
        && halation <= 0.001
        && bloom <= 0.001
        && vignette <= 0.001
    }
  }

  /// Decodes the `look` dictionary sent by Dart.
  ///
  /// A `.cube` LUT is imported by Dart, converted to a raw RGBA float cube and
  /// handed over as a file path, so only a cheap file read happens here.
  static func filmLook(from args: [String: Any]) -> FilmLook {
    let raw = (args["look"] as? [String: Any]) ?? [:]

    func unit(_ key: String) -> Double {
      let value = (raw[key] as? NSNumber)?.doubleValue ?? 0
      return min(max(value, 0), 1)
    }

    let dimension = (raw["lutSize"] as? NSNumber)?.intValue ?? 0
    var lutURL: URL?
    if let path = raw["lutPath"] as? String,
       !path.isEmpty,
       dimension > 1,
       FileManager.default.fileExists(atPath: path) {
      lutURL = URL(fileURLWithPath: path)
    }

    return FilmLook(
      lutURL: lutURL,
      lutDimension: dimension,
      lutMix: unit("lutMix"),
      grain: unit("grain"),
      grainSize: unit("grainSize"),
      halation: unit("halation"),
      bloom: unit("bloom"),
      vignette: unit("vignette")
    )
  }

  /// Parsed `.cube` payloads, keyed by path + dimension.
  ///
  /// A 33³ cube is ~575 KB, so reading it for every video frame would stall the
  /// render loop. The cache keeps the current look in memory instead.
  private static var cubeCache: [String: Data] = [:]

  private static func cubeData(for url: URL, dimension: Int) -> Data? {
    let key = "\(url.path)|\(dimension)"
    if let cached = cubeCache[key] { return cached }
    guard let data = try? Data(contentsOf: url) else { return nil }
    let expected = dimension * dimension * dimension * 16
    guard data.count >= expected else { return nil }
    if cubeCache.count >= 4 { cubeCache.removeAll() }
    cubeCache[key] = data
    return data
  }

  /// Applies the imported LUT plus the film effects (grain, halation, bloom,
  /// vignette) to one frame.
  ///
  /// Everything here is Core Image, so photos (one frame) and videos (one call
  /// per frame) share the exact same look instead of drifting apart.
  private func applyFilmLook(
    to image: CIImage,
    look: FilmLook,
    extent: CGRect
  ) -> CIImage {
    guard !look.isNeutral, extent.width > 1, extent.height > 1 else {
      return image
    }

    var output = image

    if let lutURL = look.lutURL,
       let data = AppDelegate.cubeData(for: lutURL, dimension: look.lutDimension),
       let cube = CIFilter(name: "CIColorCubeWithColorSpace") {
      cube.setValue(look.lutDimension, forKey: "inputCubeDimension")
      cube.setValue(data, forKey: "inputCubeData")
      cube.setValue(image, forKey: kCIInputImageKey)
      if let space = CGColorSpace(name: CGColorSpace.sRGB) {
        cube.setValue(space, forKey: "inputColorSpace")
      }
      if let graded = cube.outputImage?.cropped(to: extent) {
        output = AppDelegate.dissolve(
          from: output,
          to: graded,
          amount: look.lutMix
        )
      }
    }

    let shortSide = min(extent.width, extent.height)
    let longSide = max(extent.width, extent.height)

    // Halation: warm glow that bleeds out of the brightest areas, the way light
    // scatters through the film base. Bloom is the neutral, wider version.
    if look.halation > 0.001,
       let glow = highlightGlow(
         of: output,
         extent: extent,
         threshold: 0.62,
         radius: max(2, longSide * 0.010),
         tint: CIVector(x: 1.0, y: 0.45, z: 0.30, w: 1),
         intensity: look.halation * 0.85
       ) {
      output = glow
    }

    if look.bloom > 0.001,
       let glow = highlightGlow(
         of: output,
         extent: extent,
         threshold: 0.70,
         radius: max(3, longSide * 0.024),
         tint: CIVector(x: 1.0, y: 1.0, z: 1.0, w: 1),
         intensity: look.bloom * 0.5
       ) {
      output = glow
    }

    if look.vignette > 0.001 {
      output = output.applyingFilter("CIVignette", parameters: [
        kCIInputIntensityKey: look.vignette * 2.0,
        kCIInputRadiusKey: shortSide * 0.62,
      ]).cropped(to: extent)
    }

    if look.grain > 0.001,
       let noise = CIFilter(name: "CIRandomGenerator")?.outputImage {
      // Film grain has to read as texture, not as blocky digital noise: the
      // generator runs at 1 px, and `grainSize` only nudges it up to 2.2 px.
      let scale = 1.0 + look.grainSize * 1.2
      let mono = noise
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        .cropped(to: extent)
        .applyingFilter("CIColorMatrix", parameters: [
          "inputRVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
          "inputGVector": CIVector(x: 0.59, y: 0.59, z: 0.59, w: 0),
          "inputBVector": CIVector(x: 0.11, y: 0.11, z: 0.11, w: 0),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
      let blended = mono.applyingFilter(
        "CISoftLightBlendMode",
        parameters: [kCIInputBackgroundImageKey: output]
      ).cropped(to: extent)
      // Soft light already lands gently, so the dissolve amount is the grain
      // dial itself: "1.0" is heavy texture, never a snowstorm.
      output = AppDelegate.dissolve(
        from: output,
        to: blended,
        amount: look.grain
      )
    }

    return output.cropped(to: extent)
  }

  /// Blurs the highlights of [image] and adds the glow back on top.
  private func highlightGlow(
    of image: CIImage,
    extent: CGRect,
    threshold: CGFloat,
    radius: CGFloat,
    tint: CIVector,
    intensity: Double
  ) -> CIImage? {
    guard intensity > 0.001 else { return nil }

    let isolated = image.applyingFilter("CIColorMatrix", parameters: [
      "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
      "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
      "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
      "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
      "inputBiasVector": CIVector(
        x: -threshold,
        y: -threshold,
        z: -threshold,
        w: 0
      ),
    ]).cropped(to: extent)

    let blurred = isolated
      .clampedToExtent()
      .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
      .cropped(to: extent)

    let gain = CGFloat(intensity)
    let tinted = blurred.applyingFilter("CIColorMatrix", parameters: [
      "inputRVector": CIVector(x: tint.x * gain, y: 0, z: 0, w: 0),
      "inputGVector": CIVector(x: 0, y: tint.y * gain, z: 0, w: 0),
      "inputBVector": CIVector(x: 0, y: 0, z: tint.z * gain, w: 0),
      "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
    ]).cropped(to: extent)

    return tinted
      .applyingFilter(
        "CIAdditionCompositing",
        parameters: [kCIInputBackgroundImageKey: image]
      )
      .cropped(to: extent)
  }

  /// Linear-style mix between two graded versions of the same frame.
  private static func dissolve(
    from base: CIImage,
    to target: CIImage,
    amount: Double
  ) -> CIImage {
    let clamped = min(max(amount, 0), 1)
    if clamped <= 0.001 { return base }
    if clamped >= 0.999 { return target }
    guard let filter = CIFilter(name: "CIDissolveTransition") else {
      return target
    }
    filter.setValue(base, forKey: kCIInputImageKey)
    filter.setValue(target, forKey: "inputTargetImage")
    filter.setValue(clamped, forKey: "inputTime")
    return filter.outputImage?.cropped(to: base.extent) ?? target
  }

  /// Re-encodes a ProRes master with the tone + film look baked in.
  ///
  /// The output stays ProRes 422 10-bit so the file is still an edit-friendly
  /// master: only the look is burned in, never the codec. Any failure returns
  /// the untouched path, because losing the take is worse than a flat master.
  private func bakeLookIntoProRes(
    inputPath: String,
    matrix: [Double],
    look: FilmLook,
    result: @escaping FlutterResult
  ) {
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
    if look.isNeutral && isIdentityMatrix {
      result(inputPath)
      return
    }

    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "CINELENS_BAKED_\(Int(Date().timeIntervalSince1970)).mov"
      )

    let asset = AVURLAsset(url: URL(fileURLWithPath: inputPath))

    Task {
      guard let track = try? await asset.loadTracks(withMediaType: .video).first,
            let naturalSize = try? await track.load(.naturalSize),
            let transform = try? await track.load(.preferredTransform),
            naturalSize.width > 0,
            naturalSize.height > 0 else {
        DispatchQueue.main.async { result(inputPath) }
        return
      }

      let oriented = CGRect(origin: .zero, size: naturalSize)
        .applying(transform)
      let width = Int(abs(oriented.width).rounded())
      let height = Int(abs(oriented.height).rounded())
      guard width > 0, height > 0 else {
        DispatchQueue.main.async { result(inputPath) }
        return
      }

      guard let reader = try? AVAssetReader(asset: asset) else {
        DispatchQueue.main.async { result(inputPath) }
        return
      }
      let readerOutput = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
          kCVPixelBufferPixelFormatTypeKey as String:
            kCVPixelFormatType_32BGRA
        ]
      )
      readerOutput.alwaysCopiesSampleData = false
      guard reader.canAdd(readerOutput) else {
        DispatchQueue.main.async { result(inputPath) }
        return
      }
      reader.add(readerOutput)

      guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mov) else {
        DispatchQueue.main.async { result(inputPath) }
        return
      }
      let writerInput = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
          AVVideoCodecKey: AVVideoCodecType.proRes422,
          AVVideoWidthKey: width,
          AVVideoHeightKey: height,
        ]
      )
      writerInput.expectsMediaDataInRealTime = false
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: writerInput,
        sourcePixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String:
            kCVPixelFormatType_32BGRA,
          kCVPixelBufferWidthKey as String: width,
          kCVPixelBufferHeightKey as String: height,
        ]
      )
      guard writer.canAdd(writerInput) else {
        DispatchQueue.main.async { result(inputPath) }
        return
      }
      writer.add(writerInput)

      guard writer.startWriting() else {
        DispatchQueue.main.async { result(inputPath) }
        return
      }
      writer.startSession(atSourceTime: .zero)
      reader.startReading()

      let context = AppDelegate.gradingContext
      let renderQueue = DispatchQueue(label: "com.cinelens.proresBake")

      writerInput.requestMediaDataWhenReady(on: renderQueue) {
        while writerInput.isReadyForMoreMediaData {
          guard let sample = readerOutput.copyNextSampleBuffer() else {
            writerInput.markAsFinished()
            reader.cancelReading()
            writer.finishWriting {
              let ok = writer.status == .completed
              DispatchQueue.main.async {
                result(ok ? outputURL.path : inputPath)
              }
            }
            return
          }

          guard let buffer = CMSampleBufferGetImageBuffer(sample),
                let pool = adaptor.pixelBufferPool else {
            continue
          }

          var source = CIImage(cvPixelBuffer: buffer)
          if matrix.count == 20 {
            source = self.applyColorMatrix(matrix, to: source)
          }
          var graded = self.applyFilmLook(
            to: source,
            look: look,
            extent: source.extent
          )
          if !transform.isIdentity {
            graded = graded.transformed(by: transform)
          }
          let extent = graded.extent
          if extent.origin != .zero {
            graded = graded.transformed(
              by: CGAffineTransform(
                translationX: -extent.origin.x,
                y: -extent.origin.y
              )
            )
          }

          var outputBuffer: CVPixelBuffer?
          guard CVPixelBufferPoolCreatePixelBuffer(
            nil,
            pool,
            &outputBuffer
          ) == kCVReturnSuccess, let outputBuffer = outputBuffer else {
            continue
          }
          context.render(
            graded,
            to: outputBuffer,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
          )

          let time = CMSampleBufferGetPresentationTimeStamp(sample)
          if !adaptor.append(outputBuffer, withPresentationTime: time) {
            break
          }
        }
      }
    }
  }

  /// Shared `CIColorMatrix` application used by the photo/video/ProRes paths.
  private func applyColorMatrix(_ matrix: [Double], to image: CIImage) -> CIImage {
    guard matrix.count == 20,
          let filter = CIFilter(name: "CIColorMatrix") else { return image }

    filter.setValue(image, forKey: kCIInputImageKey)
    filter.setValue(
      CIVector(x: matrix[0], y: matrix[1], z: matrix[2], w: matrix[3]),
      forKey: "inputRVector"
    )
    filter.setValue(
      CIVector(x: matrix[5], y: matrix[6], z: matrix[7], w: matrix[8]),
      forKey: "inputGVector"
    )
    filter.setValue(
      CIVector(x: matrix[10], y: matrix[11], z: matrix[12], w: matrix[13]),
      forKey: "inputBVector"
    )
    filter.setValue(
      CIVector(x: matrix[15], y: matrix[16], z: matrix[17], w: matrix[18]),
      forKey: "inputAVector"
    )
    filter.setValue(
      CIVector(
        x: matrix[4] / 255.0,
        y: matrix[9] / 255.0,
        z: matrix[14] / 255.0,
        w: matrix[19] / 255.0
      ),
      forKey: "inputBiasVector"
    )
    return filter.outputImage?.cropped(to: image.extent) ?? image
  }

  /// Picks the best ProRes codec the current output accepts.
  ///
  /// `.proRes422` is the baseline every ProRes-capable iPhone writes; the LT/HQ
  /// variants are preferred when offered so the master keeps more bitrate.
  private func preferredProResCodec(
    from available: [AVVideoCodecType]
  ) -> AVVideoCodecType? {
    let order: [AVVideoCodecType] = [
      .proRes4444,
      .proRes422HQ,
      .proRes422,
      .proRes422LT,
      .proRes422Proxy,
    ]
    return order.first { available.contains($0) }
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
    look: FilmLook,
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

    // Film emulation runs on the graded frame, but before the letterbox is
    // added so the bars stay perfectly black.
    output = applyFilmLook(to: output, look: look, extent: source.extent)

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
    look: FilmLook,
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

        // Film emulation is part of the look, so it is applied before the
        // frame is rotated/letterboxed (grain must not cover the black bars).
        output = self.applyFilmLook(
          to: output,
          look: look,
          extent: sourceExtent
        )

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
