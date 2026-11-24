import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Flutter
import ImageIO
import PhotosUI
import UIKit
import UniformTypeIdentifiers

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
  static let gradingContext: CIContext = {
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
    var options: [CIContextOption: Any] = [
      .useSoftwareRenderer: false,
      // 16-bit half-float working precision eliminates 8-bit colour banding
      // across skies, deep shadows, halation glows, and smooth vignettes.
      .workingFormat: CIFormat.RGBAh,
      .highQualityDownsample: true,
    ]
    if let sRGB = sRGB {
      options[.workingColorSpace] = sRGB
      options[.outputColorSpace] = sRGB
    }
    return CIContext(options: options)
  }()

  /// Active Process Zero RAW capture delegate held for the duration of one shot.
  private var rawPhotoDelegate: ProcessZeroPhotoDelegate?

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
        let anamorphicCrop = (args["anamorphicCrop"] as? Bool) ?? false
        let desqueeze = (args["desqueeze"] as? NSNumber)?.doubleValue ?? 1.0
        let appleLogInput = (args["appleLogInput"] as? Bool) ?? false
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
          anamorphicCrop: anamorphicCrop,
          desqueeze: desqueeze,
          appleLogInput: appleLogInput,
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
        let appleLogInput = (args["appleLogInput"] as? Bool) ?? false
        let desqueeze = (args["desqueeze"] as? NSNumber)?.doubleValue ?? 1.0
        self?.bakeLookIntoProRes(
          inputPath: inputPath,
          matrix: matrix,
          toneId: toneId,
          intensity: intensity,
          effects: FilmEffects.from(args),
          importedLut: ImportedLut.from(args),
          appleLogInput: appleLogInput,
          desqueeze: desqueeze,
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
        let anamorphicCrop = (args["anamorphicCrop"] as? Bool) ?? false
        let desqueeze = (args["desqueeze"] as? NSNumber)?.doubleValue ?? 1.0
        let appleLogInput = (args["appleLogInput"] as? Bool) ?? false
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
          anamorphicCrop: anamorphicCrop,
          desqueeze: desqueeze,
          appleLogInput: appleLogInput,
          quality: quality,
          result: result
        )

      case "captureProcessZeroPhoto":
        let args = call.arguments as? [String: Any] ?? [:]
        self?.captureProcessZeroPhoto(args: args, result: result)

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

      case "editorLoadPreview":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterMethodNotImplemented)
          return
        }
        let isVideo = (args["isVideo"] as? Bool) ?? false
        let maxDimension = (args["maxDimension"] as? NSNumber)?.intValue ?? 1600
        self?.editorLoadPreview(
          path: path,
          isVideo: isVideo,
          maxDimension: maxDimension,
          result: result
        )

      case "editorRenderPreview":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterMethodNotImplemented)
          return
        }
        let isVideo = (args["isVideo"] as? Bool) ?? false
        let maxDimension = (args["maxDimension"] as? NSNumber)?.intValue ?? 1600
        self?.editorRenderPreview(
          args: args,
          path: path,
          isVideo: isVideo,
          maxDimension: maxDimension,
          result: result
        )

      case "editorExportPhoto":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.editorExportPhoto(args: args, path: path, result: result)

      case "editorExportVideo":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterMethodNotImplemented)
          return
        }
        let fps = (args["fps"] as? NSNumber)?.int32Value ?? 30
        self?.editorExportVideo(args: args, path: path, fps: fps, result: result)

      case "importMediaFromPhotos":
        let args = call.arguments as? [String: Any] ?? [:]
        let limit = (args["limit"] as? NSNumber)?.intValue ?? 40
        self?.importMediaFromPhotos(limit: limit, result: result)

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
    disableAutomaticVideoHDRIfNeeded(on: device)
    if changed {
      reapplyManualControls()
    }
  }

  /// Prevents iOS from silently recording 10-bit HLG HDR video when the user is
  /// shooting standard Rec.709/sRGB LUT footage (HLG fed into an sRGB LUT makes
  /// highlights & midtones look muddy and strangely colored).
  private func disableAutomaticVideoHDRIfNeeded(on device: AVCaptureDevice) {
    guard device.activeFormat.isVideoHDRSupported else { return }
    do {
      try device.lockForConfiguration()
      defer { device.unlockForConfiguration() }
      if device.automaticallyAdjustsVideoHDREnabled || device.isVideoHDREnabled {
        device.automaticallyAdjustsVideoHDREnabled = false
        device.isVideoHDREnabled = false
      }
    } catch {
      // Best effort: session may still be settling.
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

  // MARK: - Still photography & Process Zero RAW

  /// Captures a true Process Zero Bayer RAW photo directly from the active
  /// `AVCaptureSession` (bypassing Apple Smart HDR & Deep Fusion shadow-lifting),
  /// decodes it via `CIRAWFilter` with `localToneMapAmount = 0.0` and deep shadow
  /// preservation, then grades it through the exact same 16-bit FilmEngine chain.
  ///
  /// Returns `nil` cleanly when the active camera/format cannot shoot Bayer RAW
  /// (e.g. front camera or simulator), allowing Dart to fall back seamlessly.
  private func captureProcessZeroPhoto(
    args: [String: Any],
    result: @escaping FlutterResult
  ) {
    let done = ReplyOnce(result)
    guard let session = activeSession,
          let photoOutput = session.outputs.compactMap({ $0 as? AVCapturePhotoOutput }).first,
          let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first(where: {
            AVCapturePhotoOutput.isBayerRAWPixelFormat($0)
          }) else {
      done.send(nil)
      return
    }

    let matrix = (args["matrix"] as? [Double]) ?? [
      1, 0, 0, 0, 0,
      0, 1, 0, 0, 0,
      0, 0, 1, 0, 0,
      0, 0, 0, 1, 0,
    ]
    let anamorphic = (args["anamorphic"] as? Bool) ?? false
    let anamorphicCrop = (args["anamorphicCrop"] as? Bool) ?? false
    let desqueeze = (args["desqueeze"] as? NSNumber)?.doubleValue ?? 1.0
    let quality = (args["quality"] as? NSNumber)?.doubleValue ?? 0.98
    let toneId = args["toneId"] as? String
    let intensity = (args["intensity"] as? NSNumber)?.doubleValue ?? 1.0
    let effects = FilmEffects.from(args)
    let importedLut = ImportedLut.from(args)

    let settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
    settings.photoQualityPrioritization = .speed

    let delegate = ProcessZeroPhotoDelegate { [weak self] rawData in
      self?.rawPhotoDelegate = nil
      guard let self = self, let rawData = rawData else {
        done.send(nil)
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        let decoded: CIImage?
        if let rawFilter = CIRAWFilter(imageData: rawData, identifierHint: nil) {
          if rawFilter.isLocalToneMapSupported {
            rawFilter.localToneMapAmount = 0.0
          }
          // Keep natural photographic tone curve while disabling Smart HDR shadow
          // boosting. Near-zero luminance NR prevents watercolor/oil-painting
          // smearing on foliage and fine textures.
          rawFilter.boostAmount = 0.72
          rawFilter.boostShadowAmount = 0.0
          if rawFilter.isLuminanceNoiseReductionSupported {
            rawFilter.luminanceNoiseReductionAmount = 0.02
          }
          if rawFilter.isColorNoiseReductionSupported {
            rawFilter.colorNoiseReductionAmount = 0.15
          }
          if rawFilter.isSharpnessSupported {
            rawFilter.sharpnessAmount = 0.10
          }
          decoded = rawFilter.outputImage
        } else {
          decoded = CIImage(data: rawData, options: [.applyOrientationProperty: true])
        }

        guard let source = decoded else {
          DispatchQueue.main.async { done.send(nil) }
          return
        }

        let jpegData = self.renderGradedStill(
          source: source,
          sourceMetadataBytes: rawData,
          matrix: matrix,
          toneId: toneId,
          intensity: intensity,
          effects: effects,
          importedLut: importedLut,
          anamorphic: anamorphic,
          anamorphicCrop: anamorphicCrop,
          desqueeze: desqueeze,
          appleLogInput: false,
          quality: quality
        )
        DispatchQueue.main.async {
          if let data = jpegData {
            done.send(FlutterStandardTypedData(bytes: data))
          } else {
            done.send(nil)
          }
        }
      }
    }

    self.rawPhotoDelegate = delegate
    photoOutput.capturePhoto(with: settings, delegate: delegate)

    // Watchdog so Dart never hangs if iOS drops the photo callback.
    DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) { [weak self] in
      if self?.rawPhotoDelegate === delegate {
        self?.rawPhotoDelegate = nil
        done.send(nil)
      }
    }
  }

  /// Applies the LUT at the still's native resolution and returns JPEG bytes
  /// while preserving original EXIF / TIFF / GPS metadata.
  private func exportGradedPhoto(
    inputBytes: Data,
    matrix: [Double],
    toneId: String?,
    intensity: Double,
    effects: FilmEffects?,
    importedLut: ImportedLut?,
    anamorphic: Bool,
    anamorphicCrop: Bool = false,
    desqueeze: Double = 1.0,
    appleLogInput: Bool = false,
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

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self,
            let source = CIImage(
              data: inputBytes,
              options: [.applyOrientationProperty: true]
            ) else {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "decode_failed",
              message: "The captured photo could not be decoded.",
              details: nil
            )
          )
        }
        return
      }

      let jpegData = self.renderGradedStill(
        source: source,
        sourceMetadataBytes: inputBytes,
        matrix: matrix,
        toneId: toneId,
        intensity: intensity,
        effects: effects,
        importedLut: importedLut,
        anamorphic: anamorphic,
        anamorphicCrop: anamorphicCrop,
        desqueeze: desqueeze,
        appleLogInput: appleLogInput,
        quality: quality
      )

      DispatchQueue.main.async {
        guard let data = jpegData else {
          result(
            FlutterError(
              code: "encode_failed",
              message: "The graded photo could not be encoded.",
              details: nil
            )
          )
          return
        }
        result(FlutterStandardTypedData(bytes: data))
      }
    }
  }

  /// Shared 16-bit Core Image still renderer used by both normal captures and
  /// Process Zero RAW captures. Preserves EXIF/TIFF/GPS metadata.
  private func renderGradedStill(
    source: CIImage,
    sourceMetadataBytes: Data,
    matrix: [Double],
    toneId: String?,
    intensity: Double,
    effects: FilmEffects?,
    importedLut: ImportedLut?,
    anamorphic: Bool,
    anamorphicCrop: Bool,
    desqueeze: Double,
    appleLogInput: Bool,
    quality: Double
  ) -> Data? {
    var working = source
    if appleLogInput {
      working = FilmEngine.applyAppleLogIDT(to: working)
    }

    var output: CIImage
    if let imported = importedLut,
       let look = FilmEngine.importedLook(imported, effects: effects) {
      output = look.apply(to: working, frameIndex: Int.random(in: 0..<4096))
    } else if let look = FilmEngine.look(
      toneId: toneId,
      intensity: intensity,
      effects: effects
    ) {
      output = look.apply(to: working, frameIndex: Int.random(in: 0..<4096))
    } else {
      var graded = AppDelegate.colorMatrixImage(matrix, to: working)
      if let effects = effects, !effects.isNeutral {
        graded = FilmEngine.effectsLook(effects).apply(
          to: graded,
          frameIndex: Int.random(in: 0..<4096)
        )
      }
      output = graded
    }

    // Optional anamorphic adapter desqueeze (1.33x / 1.55x horizontal stretch).
    if desqueeze > 1.02 && desqueeze <= 2.0 {
      let isPortrait = output.extent.height > output.extent.width
      let sx: CGFloat = isPortrait ? 1.0 : CGFloat(desqueeze)
      let sy: CGFloat = isPortrait ? CGFloat(desqueeze) : 1.0
      output = output.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
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
        if anamorphicCrop {
          // True 2.39:1 cinema crop without dead black bars.
          output = output.cropped(to: activeRect)
        } else {
          let blackBackground = CIImage(color: .black).cropped(to: frame)
          output = output.cropped(to: activeRect)
            .composited(over: blackBackground)
        }
      }
    }

    // JPEG encoders require extent origin at (0, 0).
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
      return nil
    }

    let context = AppDelegate.gradingContext
    let clampedQuality = min(max(quality, 0.5), 1.0)

    guard let cgImage = context.createCGImage(
      output,
      from: output.extent,
      format: .RGBA8,
      colorSpace: colorSpace
    ) else {
      return nil
    }

    let jpeg = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      jpeg as CFMutableData,
      "public.jpeg" as CFString,
      1,
      nil
    ) else {
      return nil
    }

    // Preserve EXIF, GPS, and TIFF metadata from the original capture while
    // resetting orientation to 1 (upright, since Core Image already baked it).
    var properties: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: clampedQuality
    ]
    if let imgSource = CGImageSourceCreateWithData(sourceMetadataBytes as CFData, nil),
       let srcProps = CGImageSourceCopyPropertiesAtIndex(imgSource, 0, nil) as? [CFString: Any] {
      if let exif = srcProps[kCGImagePropertyExifDictionary] {
        properties[kCGImagePropertyExifDictionary] = exif
      }
      if let gps = srcProps[kCGImagePropertyGPSDictionary] {
        properties[kCGImagePropertyGPSDictionary] = gps
      }
      if var tiff = srcProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
        tiff[kCGImagePropertyTIFFOrientation] = 1
        tiff[kCGImagePropertyTIFFSoftware] = "CineLens Pro"
        properties[kCGImagePropertyTIFFDictionary] = tiff
      }
      properties[kCGImagePropertyOrientation] = 1
    }

    CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return jpeg as Data
  }

  // MARK: - Video

  /// Builds the Core Image composition shared by the H.264 export and the
  /// ProRes bake, so both produce the same orientation, look and colour tags.
  ///
  /// Returning `nil` means the asset has no usable video track; the caller then
  /// answers with the untouched input instead of leaving Flutter waiting.
  /// Picks HEVC Highest Quality (10-bit capable, sharper 4K detail & cleaner
  /// dark shadows) when the asset & hardware support it, falling back cleanly
  /// to standard Highest Quality.
  private static func bestVideoExportPreset(for asset: AVAsset) -> String {
    let presets = AVAssetExportSession.exportPresets(compatibleWith: asset)
    if presets.contains(AVAssetExportPresetHEVCHighestQuality) {
      return AVAssetExportPresetHEVCHighestQuality
    }
    return AVAssetExportPresetHighestQuality
  }

  private static func gradedVideoComposition(
    asset: AVURLAsset,
    matrix: [Double],
    filmLook: FilmLook?,
    effectLook: FilmLook?,
    anamorphic: Bool,
    anamorphicCrop: Bool = false,
    desqueeze: Double = 1.0,
    appleLogInput: Bool = false,
    frameRate: Int32,
    edit: PhotoEditor.Params? = nil
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
    let baseWidth = abs(orientedRect.width).rounded()
    let baseHeight = abs(orientedRect.height).rounded()
    let validDesqueeze = (desqueeze > 1.02 && desqueeze <= 2.0) ? desqueeze : 1.0
    let isPortrait = baseHeight > baseWidth
    let desqueezedWidth = isPortrait ? baseWidth : (baseWidth * validDesqueeze).rounded()
    let desqueezedHeight = isPortrait ? (baseHeight * validDesqueeze).rounded() : baseHeight

    var finalRenderWidth = desqueezedWidth
    var finalRenderHeight = desqueezedHeight
    if anamorphic && anamorphicCrop {
      let targetH = (desqueezedWidth / 2.39).rounded()
      if desqueezedHeight > targetH + 1.0 {
        // Video encoders require even dimensions.
        finalRenderHeight = max(2, floor(targetH / 2.0) * 2.0)
      }
    }
    finalRenderWidth = max(2, floor(finalRenderWidth / 2.0) * 2.0)
    finalRenderHeight = max(2, floor(finalRenderHeight / 2.0) * 2.0)
    let renderSize = CGSize(width: finalRenderWidth, height: finalRenderHeight)
    let fps = max(detectedRate, 1)
    let gradingContext = AppDelegate.gradingContext

    let composition = AVMutableVideoComposition(asset: asset) { request in
      let sourceExtent = request.sourceImage.extent
      let sourceImg = appleLogInput
        ? FilmEngine.applyAppleLogIDT(to: request.sourceImage)
        : request.sourceImage
      var output: CIImage

      // The gallery editor owns its own colour chain, so it runs first and then
      // hands over to the film look and the editor's grain/vignette.
      if let edit = edit {
        let frameIndex = Int(
          (request.compositionTime.seconds * Double(fps)).rounded()
        )
        output = PhotoEditor.applyColor(edit, to: sourceImg)
        if let look = filmLook {
          output = look.apply(to: output, frameIndex: frameIndex, isVideo: true)
        } else if let look = effectLook {
          let graded = matrix.count == 20
            ? AppDelegate.colorMatrixImage(matrix, to: output)
            : output
          output = look.apply(to: graded, frameIndex: frameIndex, isVideo: true)
        } else if matrix.count == 20 {
          output = AppDelegate.colorMatrixImage(matrix, to: output)
        }
        output = PhotoEditor.applyFinish(edit, to: output, frameIndex: frameIndex)
      } else if let look = filmLook {
        // The compositor time gives every frame its own grain pattern.
        let frameIndex = Int(
          (request.compositionTime.seconds * Double(fps)).rounded()
        )
        output = look.apply(to: sourceImg, frameIndex: frameIndex, isVideo: true)
          .cropped(to: sourceExtent)
      } else if let effectLook = effectLook {
        // Effects-only: the tone matrix still owns the colour.
        let frameIndex = Int(
          (request.compositionTime.seconds * Double(fps)).rounded()
        )
        let graded = AppDelegate.colorMatrixImage(
          matrix,
          to: sourceImg
        )
        output = effectLook
          .apply(to: graded, frameIndex: frameIndex, isVideo: true)
          .cropped(to: sourceExtent)
      } else {
        output = AppDelegate.colorMatrixImage(matrix, to: sourceImg)
          .cropped(to: sourceExtent)
      }

      // Some iOS versions hand the compositor an already oriented image.
      // Only rotate when the frame is still in the sensor's native space.
      let alreadyOriented =
        abs(sourceExtent.width - baseWidth) < 1.0
        && abs(sourceExtent.height - baseHeight) < 1.0

      if !preferredTransform.isIdentity && !alreadyOriented {
        output = output.transformed(by: preferredTransform)
      }

      if validDesqueeze > 1.02 {
        let sx: CGFloat = isPortrait ? 1.0 : CGFloat(validDesqueeze)
        let sy: CGFloat = isPortrait ? CGFloat(validDesqueeze) : 1.0
        output = output.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
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
        let targetHeight = anamorphicCrop ? finalRenderHeight : (frameExtent.width / 2.39)
        if frameExtent.height > targetHeight + 0.5 {
          let barHeight = (frameExtent.height - targetHeight) / 2.0
          let activeRect = CGRect(
            x: frameExtent.origin.x,
            y: frameExtent.origin.y + barHeight,
            width: frameExtent.width,
            height: targetHeight
          )
          if anamorphicCrop {
            output = output.cropped(to: activeRect).transformed(
              by: CGAffineTransform(translationX: 0, y: -activeRect.origin.y)
            )
          } else {
            let blackBackground = CIImage(color: .black).cropped(to: frameExtent)
            output = output.cropped(to: activeRect)
              .composited(over: blackBackground)
          }
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
    anamorphicCrop: Bool = false,
    desqueeze: Double = 1.0,
    appleLogInput: Bool = false,
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
        anamorphicCrop: anamorphicCrop,
        desqueeze: desqueeze,
        appleLogInput: appleLogInput,
        frameRate: frameRate
      ) else {
        done.send(inputPath)
        return
      }

      guard let exportSession = AVAssetExportSession(
        asset: asset,
        presetName: AppDelegate.bestVideoExportPreset(for: asset)
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
    appleLogInput: Bool = false,
    desqueeze: Double = 1.0,
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

    if look == nil && effectLook == nil && isIdentityMatrix && !appleLogInput && desqueeze <= 1.02 {
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
        anamorphicCrop: false,
        desqueeze: desqueeze,
        appleLogInput: appleLogInput,
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

  // MARK: - Gallery editor bridge

  /// Resolves the film emulation sent by the editor.
  ///
  /// `look` present means the user chose the manual film-effect sliders (or an
  /// imported `.cube`), so those values replace the stock's own grain/halation.
  /// Without it the stock keeps its built-in effects, which is the editor's
  /// default "efek bawaan stok".
  private static func editorLooks(
    args: [String: Any]
  ) -> (FilmLook?, FilmLook?) {
    let toneId = args["toneId"] as? String
    let intensity = (args["intensity"] as? NSNumber)?.doubleValue ?? 1.0
    let effects = FilmEffects.from(args)
    let imported = ImportedLut.from(args)

    let filmLook = imported.flatMap {
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
    return (filmLook, effectLook)
  }

  /// The controller to present the Photos picker from.
  private func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
    let window = scenes
      .flatMap { $0.windows }
      .first { $0.isKeyWindow } ?? scenes.first?.windows.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }

  private func importMediaFromPhotos(
    limit: Int,
    result: @escaping FlutterResult
  ) {
    guard let presenter = topViewController() else {
      result(
        FlutterError(
          code: "no_presenter",
          message: "Tidak ada layar untuk membuka Apple Photos.",
          details: nil
        )
      )
      return
    }
    MediaImporter.shared.present(from: presenter, limit: limit, result: result)
  }

  private func editorLoadPreview(
    path: String,
    isVideo: Bool,
    maxDimension: Int,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let image = PhotoEditor.previewImage(
        path: path,
        isVideo: isVideo,
        maxDimension: maxDimension
      )
      let data = image.flatMap { PhotoEditor.jpegData(from: $0, quality: 0.9) }
      DispatchQueue.main.async {
        guard let data = data else {
          result(
            FlutterError(
              code: "preview_failed",
              message: "Pratinjau editor tidak dapat dibuat.",
              details: nil
            )
          )
          return
        }
        result(FlutterStandardTypedData(bytes: data))
      }
    }
  }

  private func editorRenderPreview(
    args: [String: Any],
    path: String,
    isVideo: Bool,
    maxDimension: Int,
    result: @escaping FlutterResult
  ) {
    let params = PhotoEditor.Params.from(args)
    let (filmLook, effectLook) = AppDelegate.editorLooks(args: args)
    let matrix = args["matrix"] as? [Double]

    DispatchQueue.global(qos: .userInitiated).async {
      var output: CIImage?
      if let source = PhotoEditor.previewImage(
        path: path,
        isVideo: isVideo,
        maxDimension: maxDimension
      ) {
        output = PhotoEditor.render(
          params,
          look: filmLook ?? effectLook,
          matrix: filmLook == nil ? matrix : nil,
          source: source
        )
      }
      let data = output.flatMap { PhotoEditor.jpegData(from: $0, quality: 0.9) }
      DispatchQueue.main.async {
        guard let data = data else {
          result(
            FlutterError(
              code: "preview_failed",
              message: "Render pratinjau gagal.",
              details: nil
            )
          )
          return
        }
        result(FlutterStandardTypedData(bytes: data))
      }
    }
  }

  private func editorExportPhoto(
    args: [String: Any],
    path: String,
    result: @escaping FlutterResult
  ) {
    let params = PhotoEditor.Params.from(args)
    let (filmLook, effectLook) = AppDelegate.editorLooks(args: args)
    let matrix = args["matrix"] as? [Double]
    let quality = (args["quality"] as? NSNumber)?.doubleValue ?? 0.95

    DispatchQueue.global(qos: .userInitiated).async {
      var output: CIImage?
      if let source = PhotoEditor.loadFullImage(path: path) {
        output = PhotoEditor.render(
          params,
          look: filmLook ?? effectLook,
          matrix: filmLook == nil ? matrix : nil,
          source: source
        )
      }
      let data = output.flatMap {
        PhotoEditor.jpegData(from: $0, quality: quality)
      }
      DispatchQueue.main.async {
        guard let data = data else {
          result(
            FlutterError(
              code: "export_failed",
              message: "Foto hasil edit tidak dapat dirender.",
              details: nil
            )
          )
          return
        }
        result(FlutterStandardTypedData(bytes: data))
      }
    }
  }

  private func editorExportVideo(
    args: [String: Any],
    path: String,
    fps: Int32,
    result: @escaping FlutterResult
  ) {
    let params = PhotoEditor.Params.from(args)
    let (filmLook, effectLook) = AppDelegate.editorLooks(args: args)
    let identity: [Double] = [
      1, 0, 0, 0, 0,
      0, 1, 0, 0, 0,
      0, 0, 1, 0, 0,
      0, 0, 0, 1, 0,
    ]
    let customMatrix = (args["matrix"] as? [Double])
    let activeMatrix = (filmLook == nil && customMatrix?.count == 20) ? (customMatrix ?? identity) : identity
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "CINELENS_EDIT_\(Int(Date().timeIntervalSince1970)).mov"
      )
    let done = ReplyOnce(result)

    Task {
      guard let composition = await AppDelegate.gradedVideoComposition(
        asset: asset,
        matrix: activeMatrix,
        filmLook: filmLook,
        effectLook: effectLook,
        anamorphic: false,
        frameRate: fps,
        edit: params
      ) else {
        done.send(
          FlutterError(
            code: "export_failed",
            message: "Video tidak dapat dibaca untuk diedit.",
            details: nil
          )
        )
        return
      }

      guard let exportSession = AVAssetExportSession(
        asset: asset,
        presetName: AppDelegate.bestVideoExportPreset(for: asset)
      ) else {
        done.send(
          FlutterError(
            code: "export_unavailable",
            message: "Perangkat ini tidak bisa mengekspor video hasil edit.",
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
      let timeout = min(max(600.0, duration * 30.0), 2100.0)
      AppDelegate.finishExport(
        exportSession,
        outputURL: outputURL,
        inputPath: path,
        timeout: timeout,
        channel: self.nativeChannel,
        done: done
      )
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
  /// When true, built-in stocks keep their authentic halation, bloom, grain and
  /// vignette instead of being overwritten by the manual sliders; `shadowDepth`
  /// and `acutance` still apply on top.
  let useStockEffects: Bool
  /// Deep Film Toe / Chiaroscuro shadow depth (0…1). Deepens shadows below luma
  /// 0.34 into clean velvety blacks while preserving sunlit highlight texture.
  let shadowDepth: Double
  /// Optical film micro-contrast / edge sharpness (0…1).
  let acutance: Double

  /// True when every manual effect is off, so the renderer can skip the passes.
  var isNeutral: Bool {
    grain <= 0.001
      && halation <= 0.001
      && bloom <= 0.001
      && vignette <= 0.001
      && shadowDepth <= 0.001
      && acutance <= 0.001
  }

  static func from(_ args: [String: Any]) -> FilmEffects? {
    guard let raw = args["look"] as? [String: Any] else { return nil }

    func unit(_ key: String, fallback: Double = 0) -> Double {
      let value = (raw[key] as? NSNumber)?.doubleValue ?? fallback
      return min(max(value, 0), 1)
    }

    let useStock = (raw["useStockEffects"] as? Bool) ?? false

    return FilmEffects(
      grain: unit("grain"),
      grainSize: unit("grainSize"),
      halation: unit("halation"),
      bloom: unit("bloom"),
      vignette: unit("vignette"),
      useStockEffects: useStock,
      shadowDepth: unit("shadowDepth"),
      acutance: unit("acutance")
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
    if effects.useStockEffects {
      // Keep the stock's authentic tuned halation, bloom, grain and vignette!
      return self
    }
    return FilmStockParams(
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

  /// Chiaroscuro deep shadow toe strength (0…1).
  var shadowDepth: Double = 0.0

  /// Optical micro-contrast acutance sharpness (0…1). Defaults to 0 so native
  /// lens optical detail is never double-sharpened into oily halos.
  var acutance: Double = 0.0

  /// Renders the full look: colour cube, deep shadow toe, optional micro-radius
  /// acutance, specular-only halation/bloom, full-resolution fine grain and vignette.
  func apply(to image: CIImage, frameIndex: Int, isVideo: Bool = false) -> CIImage {
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

    // 1b. Chiaroscuro Deep Shadow Toe: carves rich ink-black directional
    //     shadows without crushing sunlit highlights.
    if shadowDepth > 0.005 {
      output = FilmEngine.applyShadowDepth(to: output, strength: shadowDepth)
        .cropped(to: extent)
    }

    // 2. Optical crispness: NEVER apply global Gaussian softening (which turns
    //    foliage and micro-textures into mush). Apply only a single micro-radius
    //    luminance acutance pass when the user explicitly dials acutance > 0.
    if acutance > 0.005 {
      output = output.applyingFilter(
        "CISharpenLuminance",
        parameters: [
          "inputSharpness": CGFloat(acutance * 0.35),
          "inputRadius": CGFloat(min(0.9, max(0.45, 0.55 * scale)))
        ]
      ).cropped(to: extent)
    }

    // 3. Halation & Bloom: strictly gated to true specular highlights (> 0.86)
    //    so daytime skies, sunlit foliage, and pavement stay razor sharp
    //    instead of getting washed in milky low-res haze.
    let halation = p.halation * fx
    let bloom = p.bloom * fx
    var glowLayers: [FilmLook.GlowLayer] = []
    if halation > 0.001 {
      glowLayers.append(
        FilmLook.GlowLayer(
          threshold: 0.88,
          tint: [1.0, 0.32, 0.10],
          amount: halation * 0.70,
          sigma: 9.0 * scale
        )
      )
    }
    if bloom > 0.001 {
      glowLayers.append(
        FilmLook.GlowLayer(
          threshold: 0.86,
          tint: [1.0, 1.0, 1.0],
          amount: bloom * 0.45,
          sigma: 22.0 * scale
        )
      )
    }
    if !glowLayers.isEmpty {
      output = FilmLook.glow(over: output, extent: extent, layers: glowLayers)
    }

    // 4. Grain: full-resolution fine monochrome silver-halide grain. Scaled
    //    lighter on video so temporal HEVC/H.264 compression preserves crisp
    //    foliage and fine detail instead of burning bitrate on random noise.
    let grain = p.grain * fx * (isVideo ? 0.42 : 1.0)
    if grain > 0.001 {
      output = FilmLook.addGrain(
        to: output,
        extent: extent,
        amount: grain,
        size: p.grainSize,
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

  static func addGrain(
    to base: CIImage,
    extent: CGRect,
    amount: Double,
    size: Double,
    frameIndex: Int
  ) -> CIImage {
    guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else {
      return base
    }

    // Render grain at native full resolution (no half-res downscale/upscale)
    // so grain stays crisp 1-2px silver-halide texture instead of turning into
    // blotchy 4-8px oil-painting smears.
    let offsetX = CGFloat((frameIndex &* 7919) % 2048)
    let offsetY = CGFloat((frameIndex &* 104729) % 2048)
    let shifted = noise
      .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
      .cropped(to: extent)
      .settingAlphaOne(in: extent)

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

    // Keep fine grain unblurred at native 1px; only soften slightly for coarser
    // stocks (> 0.65) with a tight sigma so texture remains sharp and organic.
    let clampedSize = min(max(size, 0.3), 1.6)
    let softened: CIImage
    let effectiveSigma: Double
    if clampedSize > 0.65 {
      effectiveSigma = 0.22 + (clampedSize - 0.65) * 0.28
      softened = mono.clampedToExtent()
        .applyingGaussianBlur(sigma: effectiveSigma)
        .cropped(to: extent)
    } else {
      effectiveSigma = 0.0
      softened = mono
    }

    let rawDeviation = effectiveSigma > 0.0
      ? 0.1667 / max(1.0, 2.0 * effectiveSigma * Double.pi.squareRoot())
      : 0.1667
    let gain = CGFloat((amount * 0.14) / rawDeviation)
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

    // Tight soft-light safety clamp keeps grain delicate and natural.
    let limited = centred.applyingFilter(
      "CIColorClamp",
      parameters: [
        "inputMinComponents": CIVector(x: 0.34, y: 0.34, z: 0.34, w: 0),
        "inputMaxComponents": CIVector(x: 0.66, y: 0.66, z: 0.66, w: 1)
      ]
    )

    return limited
      .applyingFilter(
        "CISoftLightBlendMode",
        parameters: [kCIInputBackgroundImageKey: base]
      )
      .cropped(to: extent)
  }

  static func addVignette(
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
    let shadowDepth = effects?.shadowDepth ?? 0.0
    let acutance = effects?.acutance ?? 0.0

    let key = "\(toneId)-\(Int((clamped * 100.0).rounded()))"

    cacheLock.lock()
    let cached = cubeCache[key]
    cacheLock.unlock()

    let cube = cached ?? makeCube(params: stock, intensity: clamped)
    if cached == nil {
      cacheLock.lock()
      cubeCache[key] = cube
      cacheLock.unlock()
    }

    let useStock = effects == nil || effects?.useStockEffects == true
    return FilmLook(
      params: params,
      intensity: clamped,
      cubeData: cube,
      effectScale: useStock ? nil : 1.0,
      shadowDepth: shadowDepth,
      acutance: acutance
    )
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
      effectScale: effects == nil ? nil : 1.0,
      shadowDepth: effects?.shadowDepth ?? 0.0,
      acutance: effects?.acutance ?? 0.0
    )
  }

  /// Effects-only look, used for custom colour matrices that have no cube.
  static func effectsLook(_ effects: FilmEffects) -> FilmLook {
    FilmLook(
      params: neutralParams.withEffects(effects),
      intensity: 1.0,
      cubeData: Data(),
      usesCube: false,
      effectScale: 1.0,
      shadowDepth: effects.shadowDepth,
      acutance: effects.acutance
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

  // MARK: Apple Log IDT & Chiaroscuro Deep Shadow Toe

  private static var appleLogCubeCache: Data?
  private static var shadowDepthCubeCache: [Int: Data] = [:]

  /// Decodes Apple Log (per Apple Log Profile White Paper) into display-ready
  /// sRGB/Rec.709 with smooth highlight roll-off so 3D film LUTs grade properly
  /// instead of looking flat/washed out.
  private static func appleLogToSrgb(_ x: Double) -> Double {
    let r0 = -0.05641088
    let rt = 0.01
    let c = 47.28711236
    let beta = 0.00964052
    let gamma = 0.08550479
    let delta = 0.69336945
    let pt = c * pow(rt - r0, 2.0)

    let lin: Double
    if x < 0.0 {
      lin = r0
    } else if x < pt {
      lin = sqrt(x / c) + r0
    } else {
      lin = pow(2.0, (x - delta) / gamma) - beta
    }
    // Filmic shoulder compression (Reinhard-inspired) keeps Apple Log's extra
    // highlight latitude from hard-clipping when entering Rec.709 / sRGB.
    let exposed = max(0.0, lin * 2.2)
    let toneMapped = exposed / (1.0 + exposed * 0.72) * 1.18
    return min(max(linearToSrgb(toneMapped), 0.0), 1.0)
  }

  static func applyAppleLogIDT(to image: CIImage) -> CIImage {
    cacheLock.lock()
    var cube = appleLogCubeCache
    cacheLock.unlock()

    if cube == nil {
      let n = 33
      let last = Double(n - 1)
      var values = [Float]()
      values.reserveCapacity(n * n * n * 4)
      for bi in 0..<n {
        for gi in 0..<n {
          for ri in 0..<n {
            values.append(Float(appleLogToSrgb(Double(ri) / last)))
            values.append(Float(appleLogToSrgb(Double(gi) / last)))
            values.append(Float(appleLogToSrgb(Double(bi) / last)))
            values.append(1.0)
          }
        }
      }
      let built = values.withUnsafeBufferPointer { Data(buffer: $0) }
      cacheLock.lock()
      appleLogCubeCache = built
      cacheLock.unlock()
      cube = built
    }

    guard let cubeData = cube else { return image }
    if let filter = CIFilter(name: "CIColorCubeWithColorSpace"),
       let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
      filter.setValue(image, forKey: kCIInputImageKey)
      filter.setValue(33, forKey: "inputCubeDimension")
      filter.setValue(cubeData, forKey: "inputCubeData")
      filter.setValue(srgb, forKey: "inputColorSpace")
      if let out = filter.outputImage {
        return out.cropped(to: image.extent)
      }
    }
    guard let filter = CIFilter(name: "CIColorCube") else { return image }
    filter.setValue(image, forKey: kCIInputImageKey)
    filter.setValue(33, forKey: "inputCubeDimension")
    filter.setValue(cubeData, forKey: "inputCubeData")
    return filter.outputImage?.cropped(to: image.extent) ?? image
  }

  /// Sculpted Deep Film Toe: deepens shadows below luma 0.40 toward velvety
  /// ink-black using a smooth monotonic gamma curve that preserves gradation
  /// instead of crushing dark foliage into flat black blobs.
  static func applyShadowDepth(to image: CIImage, strength: Double) -> CIImage {
    let clamped = min(max(strength, 0.0), 1.0)
    guard clamped > 0.005 else { return image }
    let bucket = Int((clamped * 50.0).rounded())

    cacheLock.lock()
    var cube = shadowDepthCubeCache[bucket]
    cacheLock.unlock()

    if cube == nil {
      let s = Double(bucket) / 50.0
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
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            // Smooth monotonic shadow mask: 1.0 in deep shadows, 0.0 above midtones (0.40)
            let mask = 1.0 - smoothstep(0.0, 0.40, y)
            let toeExponent = 1.0 + s * 0.85 * mask
            let factor = y > 0.0001 ? pow(y, toeExponent - 1.0) : 1.0
            let nr = min(max(r * factor, 0.0), 1.0)
            let ng = min(max(g * factor, 0.0), 1.0)
            let nb = min(max(b * factor, 0.0), 1.0)
            values.append(Float(nr))
            values.append(Float(ng))
            values.append(Float(nb))
            values.append(1.0)
          }
        }
      }
      let built = values.withUnsafeBufferPointer { Data(buffer: $0) }
      cacheLock.lock()
      if shadowDepthCubeCache.count > 16 { shadowDepthCubeCache.removeAll() }
      shadowDepthCubeCache[bucket] = built
      cacheLock.unlock()
      cube = built
    }

    guard let cubeData = cube else { return image }
    if let filter = CIFilter(name: "CIColorCubeWithColorSpace"),
       let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
      filter.setValue(image, forKey: kCIInputImageKey)
      filter.setValue(33, forKey: "inputCubeDimension")
      filter.setValue(cubeData, forKey: "inputCubeData")
      filter.setValue(srgb, forKey: "inputColorSpace")
      if let out = filter.outputImage {
        return out.cropped(to: image.extent)
      }
    }
    guard let filter = CIFilter(name: "CIColorCube") else { return image }
    filter.setValue(image, forKey: kCIInputImageKey)
    filter.setValue(33, forKey: "inputCubeDimension")
    filter.setValue(cubeData, forKey: "inputCubeData")
    return filter.outputImage?.cropped(to: image.extent) ?? image
  }

  // MARK: Stocks

  private static let stocks: [String: FilmStockParams] = [
      "leica_chiaroscuro": FilmStockParams(
        mix: [1.04, -0.02, -0.02, -0.01, 1.02, -0.01, -0.02, 0.0, 1.02],
        ev: -0.06,
        k: [6.4, 6.3, 6.2], pivot: [0.50, 0.50, 0.51],
        sat: 0.96, hlDesat: 0.18, shDesat: 0.25,
        shadowTint: [-0.005, -0.005, -0.002], hlTint: [0.020, 0.014, -0.006],
        black: 0.0, white: 0.99, mono: nil,
        grain: 0.08, grainSize: 0.55,
        halation: 0.08, bloom: 0.0,
        vignette: 0.18, soften: 0.0
      ),
      "arri_alexa_709": FilmStockParams(
        mix: [1.05, -0.03, -0.02, -0.01, 1.03, -0.02, -0.02, 0.01, 1.01],
        ev: -0.02,
        k: [5.9, 5.8, 5.6], pivot: [0.52, 0.52, 0.53],
        sat: 1.04, hlDesat: 0.22, shDesat: 0.08,
        shadowTint: [-0.006, 0.004, 0.014], hlTint: [0.020, 0.012, -0.010],
        black: 0.006, white: 0.985, mono: nil,
        grain: 0.10, grainSize: 0.60,
        halation: 0.16, bloom: 0.05,
        vignette: 0.12, soften: 0.0
      ),
      "kodak_trix_400": FilmStockParams(
        mix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
        ev: -0.05,
        k: [6.6, 6.6, 6.6], pivot: [0.51, 0.51, 0.51],
        sat: 1.0, hlDesat: 0.0, shDesat: 0.0,
        shadowTint: [0.0, 0.0, 0.0], hlTint: [0.0, 0.0, 0.0],
        black: 0.0, white: 0.99, mono: [0.36, 0.54, 0.10],
        grain: 0.26, grainSize: 0.85,
        halation: 0.12, bloom: 0.04,
        vignette: 0.24, soften: 0.0
      ),
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
      ),
      // MARK: Expired & cult stocks
      //
      // Colour models tuned by eye for each emulsion: the expired Agfas keep
      // their age casts and lifted blacks, the CineStills their halation-prone
      // highlights, the Eterna/print pairs the difference between the warm
      // Kodak 2383 and the cooler Fuji 3513 print.
      "agfa_xrs_200": FilmStockParams(
        mix: [1.02, 0.02, -0.04, 0.0, 1.0, 0.0, -0.02, 0.05, 0.97],
        ev: 0.02,
        k: [4.9, 4.7, 4.4], pivot: [0.52, 0.51, 0.55],
        sat: 0.86, hlDesat: 0.3, shDesat: 0.22,
        shadowTint: [0.004, 0.022, 0.028], hlTint: [0.05, 0.03, -0.035],
        black: 0.045, white: 0.945, mono: nil,
        grain: 0.42, grainSize: 1.35,
        halation: 0.3, bloom: 0.16,
        vignette: 0.26, soften: 0.22
      ),
      "agfa_rsx_ii_200": FilmStockParams(
        mix: [1.08, -0.02, -0.06, -0.02, 1.04, -0.02, -0.01, -0.03, 1.04],
        ev: -0.06,
        k: [6.6, 6.3, 6.0], pivot: [0.53, 0.53, 0.55],
        sat: 1.1, hlDesat: 0.14, shDesat: 0.06,
        shadowTint: [0.032, -0.006, 0.028], hlTint: [-0.008, 0.012, 0.012],
        black: 0.012, white: 0.985, mono: nil,
        grain: 0.2, grainSize: 1.0,
        halation: 0.22, bloom: 0.08,
        vignette: 0.24, soften: 0.06
      ),
      "cinestill_50d": FilmStockParams(
        mix: [1.05, -0.02, -0.03, -0.01, 1.03, -0.02, -0.03, -0.01, 1.04],
        ev: 0.0,
        k: [6.0, 5.8, 5.5], pivot: [0.52, 0.53, 0.54],
        sat: 1.06, hlDesat: 0.22, shDesat: 0.08,
        shadowTint: [-0.008, 0.0, 0.026], hlTint: [0.045, 0.02, -0.026],
        black: 0.014, white: 0.975, mono: nil,
        grain: 0.14, grainSize: 0.85,
        halation: 0.55, bloom: 0.14,
        vignette: 0.18, soften: 0.05
      ),
      "cinestill_800t": FilmStockParams(
        mix: [1.04, -0.02, -0.02, -0.03, 1.06, -0.02, -0.04, 0.02, 1.02],
        ev: 0.02,
        k: [5.6, 5.5, 5.2], pivot: [0.52, 0.53, 0.55],
        sat: 1.0, hlDesat: 0.3, shDesat: 0.14,
        shadowTint: [0.004, 0.006, 0.042], hlTint: [0.06, -0.004, -0.03],
        black: 0.028, white: 0.96, mono: nil,
        grain: 0.36, grainSize: 1.2,
        halation: 0.62, bloom: 0.18,
        vignette: 0.24, soften: 0.12
      ),
      "eterna_vivid_500_2383": FilmStockParams(
        mix: [1.08, -0.03, -0.04, -0.02, 1.05, -0.02, -0.05, 0.02, 1.02],
        ev: -0.05,
        k: [6.4, 6.1, 5.8], pivot: [0.53, 0.53, 0.55],
        sat: 1.12, hlDesat: 0.26, shDesat: 0.1,
        shadowTint: [-0.02, 0.018, 0.052], hlTint: [0.055, 0.024, -0.048],
        black: 0.02, white: 0.96, mono: nil,
        grain: 0.32, grainSize: 1.1,
        halation: 0.44, bloom: 0.16,
        vignette: 0.22, soften: 0.1
      ),
      "eterna_vivid_500_3513": FilmStockParams(
        mix: [1.06, -0.03, -0.02, -0.03, 1.05, -0.03, -0.04, 0.0, 1.05],
        ev: -0.04,
        k: [6.2, 6.1, 5.9], pivot: [0.53, 0.53, 0.54],
        sat: 1.1, hlDesat: 0.16, shDesat: 0.08,
        shadowTint: [-0.024, 0.006, 0.05], hlTint: [0.02, 0.012, -0.006],
        black: 0.016, white: 0.975, mono: nil,
        grain: 0.3, grainSize: 1.1,
        halation: 0.38, bloom: 0.14,
        vignette: 0.2, soften: 0.08
      ),
      "eterna_vivid_500d_2383": FilmStockParams(
        mix: [1.07, -0.02, -0.04, -0.01, 1.05, -0.02, -0.05, 0.02, 1.03],
        ev: -0.03,
        k: [6.3, 6.1, 5.8], pivot: [0.53, 0.53, 0.54],
        sat: 1.12, hlDesat: 0.26, shDesat: 0.1,
        shadowTint: [-0.014, 0.024, 0.044], hlTint: [0.052, 0.024, -0.042],
        black: 0.02, white: 0.965, mono: nil,
        grain: 0.28, grainSize: 1.05,
        halation: 0.42, bloom: 0.15,
        vignette: 0.2, soften: 0.09
      ),
      "eterna_vivid_500d_3513": FilmStockParams(
        mix: [1.05, -0.02, -0.02, -0.02, 1.06, -0.03, -0.04, 0.0, 1.05],
        ev: -0.03,
        k: [6.2, 6.2, 6.0], pivot: [0.53, 0.53, 0.54],
        sat: 1.09, hlDesat: 0.15, shDesat: 0.07,
        shadowTint: [-0.02, 0.01, 0.048], hlTint: [0.014, 0.014, 0.0],
        black: 0.014, white: 0.98, mono: nil,
        grain: 0.26, grainSize: 1.05,
        halation: 0.36, bloom: 0.13,
        vignette: 0.19, soften: 0.07
      ),
      "provia_100f": FilmStockParams(
        mix: [1.06, -0.03, -0.03, -0.02, 1.06, -0.03, -0.02, -0.04, 1.06],
        ev: -0.05,
        k: [6.8, 6.8, 6.6], pivot: [0.54, 0.54, 0.54],
        sat: 1.14, hlDesat: 0.1, shDesat: 0.0,
        shadowTint: [-0.006, 0.002, 0.02], hlTint: [0.008, 0.006, -0.006],
        black: 0.004, white: 0.99, mono: nil,
        grain: 0.1, grainSize: 0.8,
        halation: 0.16, bloom: 0.06,
        vignette: 0.15, soften: 0.0
      ),
      "velvia_50_2383": FilmStockParams(
        mix: [1.12, -0.06, -0.05, -0.06, 1.14, -0.07, -0.03, -0.09, 1.12],
        ev: -0.08,
        k: [7.2, 7.3, 7.0], pivot: [0.54, 0.54, 0.55],
        sat: 1.24, hlDesat: 0.18, shDesat: 0.02,
        shadowTint: [0.006, -0.004, 0.036], hlTint: [0.05, 0.024, -0.04],
        black: 0.018, white: 0.975, mono: nil,
        grain: 0.16, grainSize: 0.85,
        halation: 0.3, bloom: 0.1,
        vignette: 0.18, soften: 0.02
      ),
      "c200_endura": FilmStockParams(
        mix: [1.04, 0.0, -0.04, 0.0, 1.02, -0.02, -0.03, 0.03, 0.98],
        ev: 0.0,
        k: [5.4, 5.2, 4.9], pivot: [0.52, 0.52, 0.54],
        sat: 1.02, hlDesat: 0.28, shDesat: 0.1,
        shadowTint: [-0.006, 0.018, 0.018], hlTint: [0.05, 0.03, -0.03],
        black: 0.02, white: 0.965, mono: nil,
        grain: 0.26, grainSize: 1.15,
        halation: 0.3, bloom: 0.12,
        vignette: 0.2, soften: 0.12
      ),
      // MARK: Portraits, consumer film & motion picture
      "kodak_portra_400": FilmStockParams(
        mix: [1.04, -0.01, -0.03, 0.0, 1.02, -0.02, -0.02, 0.01, 1.01],
        ev: 0.0,
        k: [5.6, 5.4, 5.1], pivot: [0.52, 0.52, 0.54],
        sat: 1.02, hlDesat: 0.28, shDesat: 0.12,
        shadowTint: [-0.004, 0.012, 0.016], hlTint: [0.045, 0.028, -0.022],
        black: 0.018, white: 0.968, mono: nil,
        grain: 0.22, grainSize: 1.0,
        halation: 0.3, bloom: 0.12,
        vignette: 0.18, soften: 0.1
      ),
      "kodak_gold_200": FilmStockParams(
        mix: [1.05, 0.01, -0.05, 0.0, 1.02, -0.02, -0.04, 0.03, 0.99],
        ev: 0.0,
        k: [5.8, 5.5, 5.2], pivot: [0.52, 0.52, 0.54],
        sat: 1.08, hlDesat: 0.24, shDesat: 0.1,
        shadowTint: [0.008, 0.018, -0.006], hlTint: [0.07, 0.04, -0.05],
        black: 0.016, white: 0.97, mono: nil,
        grain: 0.26, grainSize: 1.1,
        halation: 0.34, bloom: 0.14,
        vignette: 0.2, soften: 0.1
      ),
      "kodak_ektar_100": FilmStockParams(
        mix: [1.08, -0.03, -0.05, -0.02, 1.06, -0.04, -0.03, -0.05, 1.08],
        ev: -0.03,
        k: [6.6, 6.5, 6.3], pivot: [0.53, 0.53, 0.54],
        sat: 1.16, hlDesat: 0.14, shDesat: 0.04,
        shadowTint: [-0.006, 0.0, 0.024], hlTint: [0.03, 0.018, -0.014],
        black: 0.008, white: 0.985, mono: nil,
        grain: 0.12, grainSize: 0.85,
        halation: 0.2, bloom: 0.07,
        vignette: 0.16, soften: 0.02
      ),
      "fuji_pro_400h": FilmStockParams(
        mix: [1.02, 0.0, -0.02, -0.01, 1.04, -0.02, -0.01, 0.02, 1.02],
        ev: 0.03,
        k: [5.0, 5.0, 4.8], pivot: [0.52, 0.52, 0.54],
        sat: 0.95, hlDesat: 0.3, shDesat: 0.14,
        shadowTint: [-0.004, 0.014, 0.022], hlTint: [0.012, 0.032, 0.006],
        black: 0.03, white: 0.955, mono: nil,
        grain: 0.2, grainSize: 1.0,
        halation: 0.26, bloom: 0.16,
        vignette: 0.17, soften: 0.16
      ),
      "fuji_superia_400": FilmStockParams(
        mix: [1.03, 0.01, -0.03, -0.01, 1.05, -0.03, -0.03, 0.03, 1.01],
        ev: 0.0,
        k: [5.9, 5.8, 5.5], pivot: [0.52, 0.52, 0.54],
        sat: 1.08, hlDesat: 0.22, shDesat: 0.1,
        shadowTint: [-0.014, 0.016, 0.026], hlTint: [0.03, 0.02, -0.012],
        black: 0.02, white: 0.965, mono: nil,
        grain: 0.34, grainSize: 1.2,
        halation: 0.32, bloom: 0.13,
        vignette: 0.22, soften: 0.12
      ),
      "kodak_vision3_250d": FilmStockParams(
        mix: [1.04, -0.02, -0.02, -0.02, 1.04, -0.02, -0.03, 0.01, 1.02],
        ev: -0.02,
        k: [5.8, 5.7, 5.4], pivot: [0.52, 0.53, 0.54],
        sat: 1.05, hlDesat: 0.24, shDesat: 0.1,
        shadowTint: [-0.012, 0.006, 0.03], hlTint: [0.028, 0.02, -0.016],
        black: 0.014, white: 0.975, mono: nil,
        grain: 0.28, grainSize: 1.1,
        halation: 0.34, bloom: 0.12,
        vignette: 0.19, soften: 0.08
      ),
      "ilford_hp5": FilmStockParams(
        mix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
        ev: -0.02,
        k: [6.2, 6.2, 6.2], pivot: [0.53, 0.53, 0.53],
        sat: 1.0, hlDesat: 0.0, shDesat: 0.0,
        shadowTint: [0.0, 0.0, 0.0], hlTint: [0.0, 0.0, 0.0],
        black: 0.02, white: 0.96, mono: [0.3, 0.56, 0.14],
        grain: 0.5, grainSize: 1.3,
        halation: 0.28, bloom: 0.1,
        vignette: 0.26, soften: 0.12
      )
  ]
}

// MARK: - Gallery editor

/// Non-destructive editor for media opened from the CineLens gallery.
///
/// The pipeline is a single Core Image chain so a preview and the final export
/// can never drift apart: white balance, exposure, a 256-step tone-curve LUT
/// (basic sliders + the four point curves), an HSL colour cube, vibrance,
/// saturation, clarity/texture, noise reduction, sharpening, then the chosen
/// film look and finally grain/vignette.
///
/// The film look is the exact same `FilmEngine` cube the camera uses, so every
/// built-in stock (plus imported `.cube` files) can be applied to photos and
/// clips imported from the iPhone camera roll.
enum PhotoEditor {
  struct CurvePoint {
    let x: Double
    let y: Double
  }

  struct Params {
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0
    var clarity: Double = 0
    var texture: Double = 0
    var dehaze: Double = 0
    var fade: Double = 0
    var grain: Double = 0
    var vignette: Double = 0
    var sharpen: Double = 0
    var noiseReduction: Double = 0
    var curveRgb: [CurvePoint] = []
    var curveRed: [CurvePoint] = []
    var curveGreen: [CurvePoint] = []
    var curveBlue: [CurvePoint] = []
    var hsl: [[Double]] = Array(repeating: [0, 0, 0], count: 8)

    static func from(_ args: [String: Any]) -> Params {
      var params = Params()
      guard let raw = args["edit"] as? [String: Any] else { return params }

      func number(_ key: String) -> Double {
        (raw[key] as? NSNumber)?.doubleValue ?? 0
      }
      func signed(_ key: String) -> Double {
        min(max(number(key), -1), 1)
      }
      func positive(_ key: String) -> Double {
        min(max(number(key), 0), 1)
      }
      func curve(_ value: Any?) -> [CurvePoint] {
        guard let rows = value as? [Any] else { return [] }
        var points: [CurvePoint] = []
        for row in rows {
          guard let values = row as? [Any], values.count >= 2,
                let x = (values[0] as? NSNumber)?.doubleValue,
                let y = (values[1] as? NSNumber)?.doubleValue else { continue }
          points.append(
            CurvePoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
          )
        }
        points.sort { $0.x < $1.x }
        return points.count >= 2 ? points : []
      }

      params.exposure = min(max(number("exposure"), -2), 2)
      params.contrast = signed("contrast")
      params.highlights = signed("highlights")
      params.shadows = signed("shadows")
      params.whites = signed("whites")
      params.blacks = signed("blacks")
      params.temperature = signed("temperature")
      params.tint = signed("tint")
      params.vibrance = signed("vibrance")
      params.saturation = signed("saturation")
      params.clarity = signed("clarity")
      params.texture = signed("texture")
      params.dehaze = signed("dehaze")
      params.fade = positive("fade")
      params.grain = positive("grain")
      params.vignette = positive("vignette")
      params.sharpen = positive("sharpen")
      params.noiseReduction = positive("noiseReduction")
      params.curveRgb = curve(raw["curveRgb"])
      params.curveRed = curve(raw["curveRed"])
      params.curveGreen = curve(raw["curveGreen"])
      params.curveBlue = curve(raw["curveBlue"])

      if let rows = raw["hsl"] as? [Any] {
        for index in 0..<min(rows.count, 8) {
          guard let values = rows[index] as? [Any] else { continue }
          let triple = values.compactMap { ($0 as? NSNumber)?.doubleValue }
          guard triple.count >= 3 else { continue }
          params.hsl[index] = [
            min(max(triple[0], -1), 1),
            min(max(triple[1], -1), 1),
            min(max(triple[2], -1), 1)
          ]
        }
      }
      return params
    }
  }

  // MARK: Pipeline

  /// Colour and detail half of the edit. Used directly by the video
  /// compositor, which then layers the film look and the grain itself.
  static func applyColor(_ params: Params, to image: CIImage) -> CIImage {
    let extent = image.extent
    guard extent.width > 1, extent.height > 1 else { return image }
    let scale = Double(max(extent.width, extent.height)) / 1920.0
    var output = image

    // 1. White balance as channel gains, which keeps the slider predictable.
    if abs(params.temperature) > 0.001 || abs(params.tint) > 0.001 {
      let t = params.temperature
      let ti = params.tint
      let red = max(1.0 + 0.20 * t + 0.05 * ti, 0.05)
      let green = max(1.0 - 0.02 * t - 0.12 * ti, 0.05)
      let blue = max(1.0 - 0.24 * t + 0.05 * ti, 0.05)
      output = output.applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: CGFloat(red), y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: CGFloat(green), z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(blue), w: 0)
        ]
      )
    }

    // 2. Exposure in stops.
    if abs(params.exposure) > 0.001 {
      output = output.applyingFilter(
        "CIExposureAdjust",
        parameters: ["inputEV": params.exposure]
      )
    }

    // 3. Basic sliders + point curves, baked into a 33³ colour cube.
    //    CIColorCurves silently misread the 32-bit float curve data on iOS and
    //    turned contrast/shadow/fade into random channel values (the "broken
    //    TV" colours). CIColorCube uses the same RGBA-float layout as the HSL
    //    cube below, so preview and export decode it identically everywhere.
    if let cube = toneCube(params) {
      output = output.applyingFilter(
        "CIColorCube",
        parameters: [
          "inputCubeDimension": 33,
          "inputCubeData": cube
        ]
      )
    }

    // 4. Colour Mix (HSL) as a 17³ cube.
    if let cube = hslCube(params) {
      output = output.applyingFilter(
        "CIColorCube",
        parameters: [
          "inputCubeDimension": 17,
          "inputCubeData": cube
        ]
      )
    }

    // 5. Vibrance then saturation.
    if abs(params.vibrance) > 0.001 {
      output = output.applyingFilter(
        "CIVibrance",
        parameters: ["inputAmount": params.vibrance]
      )
    }
    if abs(params.saturation) > 0.001 {
      output = output.applyingFilter(
        "CIColorControls",
        parameters: ["inputSaturation": 1.0 + params.saturation]
      )
    }

    // 6. Clarity and texture: local contrast with opposite signs softening.
    if abs(params.clarity) > 0.001 {
      if params.clarity > 0 {
        output = output.applyingFilter(
          "CIUnsharpMask",
          parameters: [
            "inputRadius": 9.0 * scale + 1.0,
            "inputIntensity": 0.9 * params.clarity
          ]
        )
      } else {
        let blurred = output.clampedToExtent()
          .applyingGaussianBlur(sigma: 2.0 * scale + 0.4)
          .cropped(to: extent)
        output = mix(
          blurred,
          over: output,
          amount: -params.clarity * 0.55,
          extent: extent
        )
      }
    }

    if abs(params.texture) > 0.001 {
      if params.texture > 0 {
        output = output.applyingFilter(
          "CIUnsharpMask",
          parameters: [
            "inputRadius": 1.6 * scale + 0.6,
            "inputIntensity": 0.7 * params.texture
          ]
        )
      } else {
        let blurred = output.clampedToExtent()
          .applyingGaussianBlur(sigma: 0.8 * scale + 0.3)
          .cropped(to: extent)
        output = mix(
          blurred,
          over: output,
          amount: -params.texture * 0.5,
          extent: extent
        )
      }
    }

    // 7. Detail: noise reduction first, then sharpening.
    if params.noiseReduction > 0.001 {
      output = output.applyingFilter(
        "CINoiseReduction",
        parameters: [
          "inputNoiseLevel": 0.02 + params.noiseReduction * 0.05,
          "inputSharpness": 0.4
        ]
      )
    }
    if params.sharpen > 0.001 {
      output = output.applyingFilter(
        "CISharpenLuminance",
        parameters: ["inputSharpness": params.sharpen * 1.2]
      )
    }

    return output.cropped(to: extent)
  }

  /// Grain and vignette, layered after the film look so they act on the final
  /// graded image just like a light leak or a lens would.
  static func applyFinish(
    _ params: Params,
    to image: CIImage,
    frameIndex: Int = 0
  ) -> CIImage {
    let extent = image.extent
    guard extent.width > 1, extent.height > 1 else { return image }
    var output = image

    if params.grain > 0.001 {
      output = FilmLook.addGrain(
        to: output,
        extent: extent,
        amount: params.grain,
        size: 0.75,
        frameIndex: frameIndex
      )
    }
    if params.vignette > 0.001 {
      output = FilmLook.addVignette(
        to: output,
        extent: extent,
        amount: params.vignette * 0.9
      )
    }
    return output.cropped(to: extent)
  }

  /// Full still pipeline: manual edit, film look, then grain/vignette.
  static func render(
    _ params: Params,
    look: FilmLook?,
    matrix: [Double]?,
    source: CIImage,
    frameIndex: Int = 0
  ) -> CIImage {
    let extent = source.extent
    var output = applyColor(params, to: source)

    if let look = look, look.usesCube {
      output = look.apply(to: output, frameIndex: frameIndex)
    } else {
      if let matrix = matrix, matrix.count == 20 {
        output = AppDelegate.colorMatrixImage(matrix, to: output)
      }
      if let look = look {
        output = look.apply(to: output, frameIndex: frameIndex)
      }
    }

    output = applyFinish(params, to: output, frameIndex: frameIndex)
    return output.cropped(to: extent)
  }

  // MARK: Curve LUT

  private static func needsCurve(_ params: Params) -> Bool {
    abs(params.contrast) > 0.001
      || abs(params.highlights) > 0.001
      || abs(params.shadows) > 0.001
      || abs(params.whites) > 0.001
      || abs(params.blacks) > 0.001
      || abs(params.fade) > 0.001
      || abs(params.dehaze) > 0.001
      || !params.curveRgb.isEmpty
      || !params.curveRed.isEmpty
      || !params.curveGreen.isEmpty
      || !params.curveBlue.isEmpty
  }

  private static let toneLock = NSLock()
  private static var toneCache: [String: Data] = [:]

  /// Tone shaping as a 33³ `CIColorCube`.
  ///
  /// The previous implementation fed a 256×3 float table to `CIColorCurves`.
  /// On iOS that filter interprets `inputCurvesData` with a different element
  /// size, so contrast/shadows/fade produced scrambled RGB values. A cube uses
  /// the same data layout as the HSL stage and is interpolated by Core Image,
  /// which is why it renders correctly on every device and stays identical
  /// between the live preview and the exported file.
  private static func toneCube(_ params: Params) -> Data? {
    guard needsCurve(params) else { return nil }

    func curveKey(_ points: [CurvePoint]) -> String {
      points
        .map { String(format: "%.4f:%.4f", $0.x, $0.y) }
        .joined(separator: ";")
    }

    let key = [
      params.contrast, params.highlights, params.shadows, params.whites,
      params.blacks, params.fade, params.dehaze,
    ].map { String(format: "%.4f", $0) }.joined(separator: ",")
      + "|" + curveKey(params.curveRgb)
      + "|" + curveKey(params.curveRed)
      + "|" + curveKey(params.curveGreen)
      + "|" + curveKey(params.curveBlue)

    toneLock.lock()
    let cached = toneCache[key]
    toneLock.unlock()
    if let cached = cached { return cached }

    let dimension = 33
    let last = Double(dimension - 1)
    var values = [Float](
      repeating: 0,
      count: dimension * dimension * dimension * 4
    )

    for blueIndex in 0..<dimension {
      for greenIndex in 0..<dimension {
        for redIndex in 0..<dimension {
          let masterRed = sample(
            params.curveRgb,
            basic(Double(redIndex) / last, params)
          )
          let masterGreen = sample(
            params.curveRgb,
            basic(Double(greenIndex) / last, params)
          )
          let masterBlue = sample(
            params.curveRgb,
            basic(Double(blueIndex) / last, params)
          )
          let offset = ((blueIndex * dimension + greenIndex) * dimension
            + redIndex) * 4
          values[offset] = Float(sample(params.curveRed, masterRed))
          values[offset + 1] = Float(sample(params.curveGreen, masterGreen))
          values[offset + 2] = Float(sample(params.curveBlue, masterBlue))
          values[offset + 3] = 1
        }
      }
    }

    let data = values.withUnsafeBytes { Data($0) }
    toneLock.lock()
    if toneCache.count > 5 { toneCache.removeAll() }
    toneCache[key] = data
    toneLock.unlock()
    return data
  }

  private static func basic(_ input: Double, _ params: Params) -> Double {
    var value = min(max(input, 0), 1)

    let contrast = 1.0 + params.contrast * 0.9 + params.dehaze * 0.35
    if abs(contrast - 1.0) > 0.0001 {
      value = 0.5 + (value - 0.5) * contrast
    }
    value -= params.dehaze * 0.02

    let highlightWeight = smoothstep(0.45, 1.0, value) * (1.0 - value) * 0.9
    let shadowWeight = (1.0 - smoothstep(0.0, 0.55, value)) * value * 0.9
    value += (params.whites + params.highlights) * highlightWeight
    value += (params.blacks + params.shadows) * shadowWeight
    value = value * (1.0 - params.fade * 0.20) + params.fade * 0.07
    return min(max(value, 0), 1)
  }

  private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3.0 - 2.0 * t)
  }

  private static func sample(_ points: [CurvePoint], _ x: Double) -> Double {
    guard points.count >= 2 else { return min(max(x, 0), 1) }
    let value = min(max(x, 0), 1)
    if value <= points[0].x { return points[0].y }
    if value >= points[points.count - 1].x { return points[points.count - 1].y }

    for index in 0..<(points.count - 1) {
      let a = points[index]
      let b = points[index + 1]
      if value >= a.x && value <= b.x {
        let span = b.x - a.x
        if abs(span) < 0.00001 { return b.y }
        let t = (value - a.x) / span
        return min(max(a.y + (b.y - a.y) * t, 0), 1)
      }
    }
    return points[points.count - 1].y
  }

  // MARK: Colour Mix cube

  private static let hslLock = NSLock()
  private static var hslCache: [String: Data] = [:]

  private static func hslCube(_ params: Params) -> Data? {
    guard params.hsl.count == 8 else { return nil }
    let active = params.hsl.contains { band in
      band.contains { abs($0) > 0.001 }
    }
    guard active else { return nil }

    let key = params.hsl
      .map { $0.map { String(format: "%.3f", $0) }.joined(separator: ",") }
      .joined(separator: "|")

    hslLock.lock()
    let cached = hslCache[key]
    hslLock.unlock()
    if let cached = cached { return cached }

    let dimension = 17
    let last = Double(dimension - 1)
    let centers: [Double] = [0, 30, 60, 120, 180, 240, 280, 320]
    let sigma = 30.0
    var values = [Float](repeating: 0, count: dimension * dimension * dimension * 4)

    for blueIndex in 0..<dimension {
      for greenIndex in 0..<dimension {
        for redIndex in 0..<dimension {
          let red = Double(redIndex) / last
          let green = Double(greenIndex) / last
          let blue = Double(blueIndex) / last
          var (hue, saturation, lightness) = rgbToHsl(red, green, blue)

          var hueShift = 0.0
          var saturationShift = 0.0
          var luminanceShift = 0.0
          var weightSum = 0.0

          for (index, center) in centers.enumerated() {
            var distance = abs(hue - center)
            distance = min(distance, 360.0 - distance)
            let weight = exp(-(distance * distance) / (2.0 * sigma * sigma))
            if weight < 0.0005 { continue }
            weightSum += weight
            hueShift += weight * params.hsl[index][0]
            saturationShift += weight * params.hsl[index][1]
            luminanceShift += weight * params.hsl[index][2]
          }

          if weightSum > 0.0001 {
            hueShift /= weightSum
            saturationShift /= weightSum
            luminanceShift /= weightSum

            if abs(hueShift) > 0.001 {
              hue += hueShift * 32.0
              hue = hue.truncatingRemainder(dividingBy: 360.0)
              if hue < 0 { hue += 360.0 }
            }
            if abs(saturationShift) > 0.001 {
              saturation = min(max(saturation * (1.0 + saturationShift), 0), 1)
            }
            if abs(luminanceShift) > 0.001 {
              let midtone = 1.0 - abs(2.0 * lightness - 1.0)
              lightness = min(
                max(lightness + luminanceShift * 0.18 * midtone, 0),
                1
              )
            }
          }

          let (outRed, outGreen, outBlue) = hslToRgb(hue, saturation, lightness)
          let offset = ((blueIndex * dimension + greenIndex) * dimension + redIndex) * 4
          values[offset] = Float(outRed)
          values[offset + 1] = Float(outGreen)
          values[offset + 2] = Float(outBlue)
          values[offset + 3] = 1
        }
      }
    }

    let data = values.withUnsafeBytes { Data($0) }
    hslLock.lock()
    if hslCache.count > 60 { hslCache.removeAll() }
    hslCache[key] = data
    hslLock.unlock()
    return data
  }

  private static func rgbToHsl(
    _ red: Double,
    _ green: Double,
    _ blue: Double
  ) -> (Double, Double, Double) {
    let maximum = max(red, max(green, blue))
    let minimum = min(red, min(green, blue))
    let lightness = (maximum + minimum) / 2.0
    let delta = maximum - minimum
    if delta < 0.00001 { return (0, 0, lightness) }

    let saturation = lightness > 0.5
      ? delta / max(2.0 - maximum - minimum, 0.00001)
      : delta / max(maximum + minimum, 0.00001)

    var hue: Double
    if maximum == red {
      hue = (green - blue) / delta + (green < blue ? 6.0 : 0.0)
    } else if maximum == green {
      hue = (blue - red) / delta + 2.0
    } else {
      hue = (red - green) / delta + 4.0
    }
    return (hue * 60.0, saturation, lightness)
  }

  private static func hslToRgb(
    _ hue: Double,
    _ saturation: Double,
    _ lightness: Double
  ) -> (Double, Double, Double) {
    guard saturation > 0.00001 else {
      return (lightness, lightness, lightness)
    }
    let q = lightness < 0.5
      ? lightness * (1.0 + saturation)
      : lightness + saturation - lightness * saturation
    let p = 2.0 * lightness - q

    func channel(_ input: Double) -> Double {
      var value = input
      if value < 0 { value += 1 }
      if value > 1 { value -= 1 }
      if value < 1.0 / 6.0 { return p + (q - p) * 6.0 * value }
      if value < 1.0 / 2.0 { return q }
      if value < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - value) * 6.0 }
      return p
    }

    let normalized = hue / 360.0
    return (
      channel(normalized + 1.0 / 3.0),
      channel(normalized),
      channel(normalized - 1.0 / 3.0)
    )
  }

  // MARK: Image IO

  private static func mix(
    _ top: CIImage,
    over bottom: CIImage,
    amount: Double,
    extent: CGRect
  ) -> CIImage {
    let alpha = CGFloat(min(max(amount, 0), 1))
    let scaled = top.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(x: alpha, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: alpha, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: alpha, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
      ]
    )
    return scaled.composited(over: bottom).cropped(to: extent)
  }

  private static let previewLock = NSLock()
  private static var previewCache: [String: CIImage] = [:]

  /// Decodes (or reuses) the preview-resolution image. Stills are scaled with
  /// Core Image, clips are sampled from their first frame.
  static func previewImage(
    path: String,
    isVideo: Bool,
    maxDimension: Int
  ) -> CIImage? {
    let key = "\(path)|\(isVideo)|\(maxDimension)"

    previewLock.lock()
    let cached = previewCache[key]
    previewLock.unlock()
    if let cached = cached { return cached }

    let image: CIImage?
    if isVideo {
      let asset = AVURLAsset(url: URL(fileURLWithPath: path))
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(
        width: maxDimension,
        height: maxDimension
      )
      if let frame = try? generator.copyCGImage(at: .zero, actualTime: nil) {
        image = CIImage(cgImage: frame)
      } else {
        image = nil
      }
    } else {
      image = loadFullImage(path: path).map { original in
        let extent = original.extent
        let longest = Double(max(extent.width, extent.height))
        guard longest > Double(maxDimension) else { return original }
        let factor = CGFloat(Double(maxDimension) / longest)
        return original.transformed(
          by: CGAffineTransform(scaleX: factor, y: factor)
        )
      }
    }

    guard let image = image else { return nil }
    previewLock.lock()
    if previewCache.count > 3 { previewCache.removeAll() }
    previewCache[key] = image
    previewLock.unlock()
    return image
  }

  /// Decodes the original file at full resolution with its orientation applied.
  static func loadFullImage(path: String) -> CIImage? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
      return nil
    }
    return CIImage(
      data: data,
      options: [.applyOrientationProperty: true]
    )
  }

  static func jpegData(from image: CIImage, quality: Double) -> Data? {
    let extent = image.extent
    guard extent.width > 1, extent.height > 1,
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let cgImage = AppDelegate.gradingContext.createCGImage(
            image,
            from: extent,
            format: .RGBA8,
            colorSpace: colorSpace
          ) else {
      return nil
    }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      data as CFMutableData,
      "public.jpeg" as CFString,
      1,
      nil
    ) else {
      return nil
    }
    CGImageDestinationAddImage(
      destination,
      cgImage,
      [kCGImageDestinationLossyCompressionQuality: min(max(quality, 0.4), 1.0)]
        as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }
}

// MARK: - Photos library import

/// Copies photos and videos picked from Apple Photos into the app's own media
/// folder.
///
/// `PHPickerViewController` runs out of process, so importing never asks for
/// photo-library permission. Stills are re-encoded as JPEG (Flutter's decoder
/// cannot read HEIC), keeping the original orientation and full resolution.
final class MediaImporter: NSObject, PHPickerViewControllerDelegate {
  static let shared = MediaImporter()

  private var pending: FlutterResult?

  func present(
    from presenter: UIViewController,
    limit: Int,
    result: @escaping FlutterResult
  ) {
    guard pending == nil else {
      result(
        FlutterError(
          code: "busy",
          message: "Impor lain sedang berjalan. Tunggu sampai selesai.",
          details: nil
        )
      )
      return
    }

    var configuration = PHPickerConfiguration()
    configuration.filter = .any(of: [.images, .videos])
    configuration.selectionLimit = max(1, min(limit, 50))
    configuration.preferredAssetRepresentationMode = .current

    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    pending = result
    presenter.present(picker, animated: true)
  }

  func picker(
    _ picker: PHPickerViewController,
    didFinishPicking results: [PHPickerResult]
  ) {
    picker.dismiss(animated: true)
    guard let result = pending else { return }
    pending = nil

    guard !results.isEmpty else {
      result([])
      return
    }

    let directory = MediaImporter.mediaDirectory()
    var outputs = Array<[String: Any]?>(repeating: nil, count: results.count)
    let group = DispatchGroup()
    let lock = NSLock()

    for (index, item) in results.enumerated() {
      group.enter()
      let provider = item.itemProvider
      let identifier = UUID().uuidString.prefix(8).lowercased()

      if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
        provider.loadFileRepresentation(
          forTypeIdentifier: UTType.movie.identifier
        ) { url, _ in
          defer { group.leave() }
          guard let url = url else { return }
          let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
          let target = directory.appendingPathComponent(
            "import_\(identifier)_\(index).\(ext)"
          )
          do {
            try FileManager.default.copyItem(at: url, to: target)
            lock.lock()
            outputs[index] = ["path": target.path, "type": "video"]
            lock.unlock()
          } catch {
            // A failed item is simply skipped; the caller reports the count.
          }
        }
      } else {
        provider.loadFileRepresentation(
          forTypeIdentifier: UTType.image.identifier
        ) { url, _ in
          defer { group.leave() }
          guard let url = url else { return }
          let target = directory.appendingPathComponent(
            "import_\(identifier)_\(index).jpg"
          )
          if MediaImporter.writeJPEG(from: url, to: target) {
            lock.lock()
            outputs[index] = ["path": target.path, "type": "photo"]
            lock.unlock()
          }
        }
      }
    }

    group.notify(queue: .main) {
      result(outputs.compactMap { $0 })
    }
  }

  private static func mediaDirectory() -> URL {
    let documents = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    )[0]
    // Keep in sync with AppConstants.mediaFolderName.
    let directory = documents.appendingPathComponent(
      "cinelens_media",
      isDirectory: true
    )
    if !FileManager.default.fileExists(atPath: directory.path) {
      try? FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
    }
    return directory
  }

  private static func writeJPEG(from source: URL, to target: URL) -> Bool {
    guard let imageSource = CGImageSourceCreateWithURL(
      source as CFURL,
      nil
    ) else {
      return false
    }
    let properties = CGImageSourceCopyPropertiesAtIndex(
      imageSource,
      0,
      nil
    ) as? [CFString: Any]

    let options: [CFString: Any] = [
      kCGImageSourceShouldCacheImmediately: true
    ]
    guard let image = CGImageSourceCreateImageAtIndex(
      imageSource,
      0,
      options as CFDictionary
    ) else {
      return false
    }

    guard let destination = CGImageDestinationCreateWithURL(
      target as CFURL,
      UTType.jpeg.identifier as CFString,
      1,
      nil
    ) else {
      return false
    }

    var destinationOptions: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: 0.95
    ]
    if let orientation = properties?[kCGImagePropertyOrientation] as? NSNumber {
      destinationOptions[kCGImagePropertyOrientation] = orientation
    }
    CGImageDestinationAddImage(
      destination,
      image,
      destinationOptions as CFDictionary
    )
    return CGImageDestinationFinalize(destination)
  }
}

/// Captures a single Bayer RAW photo for Process Zero (zero Apple Smart HDR).
final class ProcessZeroPhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
  private let lock = NSLock()
  private var finished = false
  private let completion: (Data?) -> Void

  init(completion: @escaping (Data?) -> Void) {
    self.completion = completion
    super.init()
  }

  private func deliver(_ data: Data?) {
    lock.lock()
    if finished {
      lock.unlock()
      return
    }
    finished = true
    lock.unlock()
    completion(data)
  }

  func photoOutput(
    _ output: AVCapturePhotoOutput,
    didFinishProcessingPhoto photo: AVCapturePhoto,
    error: Error?
  ) {
    if error != nil {
      deliver(nil)
      return
    }
    deliver(photo.fileDataRepresentation())
  }
}
