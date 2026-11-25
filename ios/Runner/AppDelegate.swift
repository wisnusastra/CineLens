import AVFoundation
import CoreImage
import CoreMedia
import CoreMotion
import CoreVideo
import Flutter
import ImageIO
import MediaPlayer
import Metal
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import Vision

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

  /// Wide-Gamut Display P3 16-bit half-float context for 10-bit HEIF & P3 exports.
  static let p3GradingContext: CIContext = {
    let p3 = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpace(name: CGColorSpace.sRGB)
    var options: [CIContextOption: Any] = [
      .useSoftwareRenderer: false,
      .workingFormat: CIFormat.RGBAh,
      .highQualityDownsample: true,
    ]
    if let p3 = p3 {
      options[.workingColorSpace] = p3
      options[.outputColorSpace] = p3
    }
    return CIContext(options: options)
  }()

  /// Active Process Zero RAW capture delegate held for the duration of one shot.
  private var rawPhotoDelegate: ProcessZeroPhotoDelegate?
  private var rawBurstDelegate: ProcessZeroBurstDelegate?

  /// Hardware volume-button / Bluetooth remote shutter listener.
  private var volumeObservation: NSKeyValueObservation?
  private var hiddenVolumeView: MPVolumeView?
  private var lastVolumeShutterTime: TimeInterval = 0
  private var suppressingVolumeReset = false

  /// Flutter texture registry + live Metal 3D LUT viewfinder & direct-to-disk
  /// video LUT pipeline (Tahap 2 Cinema Pro).
  private var textureRegistry: FlutterTextureRegistry?
  private var liveMetalPipeline: LiveMetalViewfinderPipeline?
  private var dopMotionManager: CMMotionManager?
  private var dopTelemetryTimer: Timer?
  private var dopAudioSessionActive = false
  private var dopAudioRecorder: AVAudioRecorder?
  private var dopHorizonEnabled = false
  private var dopAudioEnabled = false

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
    textureRegistry = registrar.textures()
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
        let frameAspectRatio = (args["frameAspectRatio"] as? NSNumber)?.doubleValue ?? 0.0
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
          frameAspectRatio: frameAspectRatio,
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
        let frameAspectRatio = (args["frameAspectRatio"] as? NSNumber)?.doubleValue ?? 0.0
        let desqueeze = (args["desqueeze"] as? NSNumber)?.doubleValue ?? 1.0
        let appleLogInput = (args["appleLogInput"] as? Bool) ?? false
        let quality = (args["quality"] as? NSNumber)?.doubleValue ?? 0.98
        let heif10Bit = (args["heif10Bit"] as? Bool) ?? false
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
          frameAspectRatio: frameAspectRatio,
          desqueeze: desqueeze,
          appleLogInput: appleLogInput,
          quality: quality,
          heif10Bit: heif10Bit,
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
        let timestampSeconds = (args["timestampSeconds"] as? NSNumber)?.doubleValue ?? 0.0
        self?.editorLoadPreview(
          path: path,
          isVideo: isVideo,
          maxDimension: maxDimension,
          timestampSeconds: timestampSeconds,
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
        let timestampSeconds = (args["timestampSeconds"] as? NSNumber)?.doubleValue ?? 0.0
        self?.editorRenderPreview(
          args: args,
          path: path,
          isVideo: isVideo,
          maxDimension: maxDimension,
          timestampSeconds: timestampSeconds,
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

      case "editorAutoTone":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterMethodNotImplemented)
          return
        }
        let isVideo = (args["isVideo"] as? Bool) ?? false
        self?.editorAutoTone(path: path, isVideo: isVideo, result: result)

      case "editorHistogram":
        guard let args = call.arguments as? [String: Any],
              let bytes = (args["bytes"] as? FlutterStandardTypedData)?.data else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.editorHistogram(bytes: bytes, result: result)

      case "editorScopes":
        guard let args = call.arguments as? [String: Any],
              let bytes = (args["bytes"] as? FlutterStandardTypedData)?.data else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.editorScopes(bytes: bytes, result: result)

      case "editorMatchColor":
        guard let args = call.arguments as? [String: Any],
              let sourcePath = args["sourcePath"] as? String,
              let referencePath = args["referencePath"] as? String else {
          result(FlutterMethodNotImplemented)
          return
        }
        let isVideo = (args["isVideo"] as? Bool) ?? false
        self?.editorMatchColor(
          sourcePath: sourcePath,
          isVideo: isVideo,
          referencePath: referencePath,
          result: result
        )

      case "enableLiveMetalPreview":
        let args = call.arguments as? [String: Any] ?? [:]
        self?.enableLiveMetalPreview(args: args, result: result)

      case "updateLiveMetalConfig":
        let args = call.arguments as? [String: Any] ?? [:]
        self?.liveMetalPipeline?.updateConfig(args: args)
        result(true)

      case "disableLiveMetalPreview":
        self?.disableLiveMetalPreview()
        result(true)

      case "startDirectLutRecording":
        let args = call.arguments as? [String: Any] ?? [:]
        self?.startDirectLutRecording(args: args, result: result)

      case "stopDirectLutRecording":
        self?.stopDirectLutRecording(result: result)

      case "setDopTelemetry":
        let args = call.arguments as? [String: Any] ?? [:]
        let horizon = (args["horizon"] as? Bool) ?? false
        let audio = (args["audio"] as? Bool) ?? false
        self?.configureDopTelemetry(horizon: horizon, audio: audio)
        result(true)

      case "generateVideoThumbnail":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(nil)
          return
        }
        self?.generateVideoThumbnail(path: path, result: result)

      case "inspectMediaMetadata":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result([:])
          return
        }
        let isVideo = (args["isVideo"] as? Bool) ?? false
        self?.inspectMediaMetadata(path: path, isVideo: isVideo, result: result)

      case "editorGenerateAiMask":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(nil)
          return
        }
        let isVideo = (args["isVideo"] as? Bool) ?? false
        let target = (args["target"] as? String) ?? "subject"
        self?.editorGenerateAiMask(path: path, isVideo: isVideo, target: target, result: result)

      case "editorExportCubeLut":
        let args = call.arguments as? [String: Any] ?? [:]
        self?.editorExportCubeLut(args: args, result: result)

      case "setVolumeShutterEnabled":
        let args = call.arguments as? [String: Any] ?? [:]
        let enabled = (args["enabled"] as? Bool) ?? false
        self?.setVolumeShutterEnabled(enabled)
        result(true)

      case "listAudioInputs":
        result(self?.listAudioInputs() ?? [])

      case "selectAudioInput":
        let args = call.arguments as? [String: Any] ?? [:]
        let portUID = args["portUID"] as? String
        result(self?.selectAudioInput(portUID: portUID) ?? false)

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
    // Keep the existing FlutterTexture alive across optical 2x/TEL lens switches
    // and session reconfigurations instead of unregistering it (which caused a
    // blank black viewfinder when zooming with Live Metal LUT enabled!).
    if let existing = liveMetalPipeline {
      existing.rebind(to: session)
    }
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
    let frameAspectRatio = (args["frameAspectRatio"] as? NSNumber)?.doubleValue ?? 0.0
    let saveDngRaw = (args["saveDngRaw"] as? Bool) ?? false
    let nightStack = (args["nightStack"] as? Bool) ?? false
    let heif10Bit = (args["heif10Bit"] as? Bool) ?? false
    let desqueeze = (args["desqueeze"] as? NSNumber)?.doubleValue ?? 1.0
    let quality = (args["quality"] as? NSNumber)?.doubleValue ?? 0.98
    let toneId = args["toneId"] as? String
    let intensity = (args["intensity"] as? NSNumber)?.doubleValue ?? 1.0
    let effects = FilmEffects.from(args)
    let importedLut = ImportedLut.from(args)

    func decodeRawFrame(_ rawData: Data) -> CIImage? {
      if let rawFilter = CIRAWFilter(imageData: rawData, identifierHint: nil) {
        if rawFilter.isLocalToneMapSupported {
          rawFilter.localToneMapAmount = 0.0
        }
        rawFilter.boostAmount = 0.72
        rawFilter.boostShadowAmount = 0.0
        if rawFilter.isLuminanceNoiseReductionSupported {
          rawFilter.luminanceNoiseReductionAmount = nightStack ? 0.05 : 0.02
        }
        if rawFilter.isColorNoiseReductionSupported {
          rawFilter.colorNoiseReductionAmount = nightStack ? 0.24 : 0.15
        }
        if rawFilter.isSharpnessSupported {
          rawFilter.sharpnessAmount = 0.10
        }
        return rawFilter.outputImage
      }
      return CIImage(data: rawData, options: [.applyOrientationProperty: true])
    }

    if nightStack {
      let frameTarget = 3
      let burstDelegate = ProcessZeroBurstDelegate(expectedCount: frameTarget) { [weak self] frames in
        self?.rawBurstDelegate = nil
        guard let self = self, !frames.isEmpty else {
          done.send(nil)
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          let primaryData = frames[0]
          if saveDngRaw {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let rawDir = docs.appendingPathComponent("cinelens_raw", isDirectory: true)
            try? FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
            let dngUrl = rawDir.appendingPathComponent("CINELENS_RAW_STACK_\(Int(Date().timeIntervalSince1970)).dng")
            try? primaryData.write(to: dngUrl, options: .atomic)
          }

          let decodedFrames = frames.compactMap { decodeRawFrame($0) }
          guard let firstImg = decodedFrames.first else {
            DispatchQueue.main.async { done.send(nil) }
            return
          }
          let baseExtent = firstImg.extent
          let weight = CGFloat(1.0 / Double(decodedFrames.count))

          var fused: CIImage?
          for img in decodedFrames {
            let aligned = img.cropped(to: baseExtent)
            let weighted = aligned.applyingFilter(
              "CIColorMatrix",
              parameters: [
                "inputRVector": CIVector(x: weight, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: weight, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: weight, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: weight)
              ]
            )
            if let acc = fused {
              fused = weighted.applyingFilter(
                "CIAdditionCompositing",
                parameters: [kCIInputBackgroundImageKey: acc]
              ).cropped(to: baseExtent)
            } else {
              fused = weighted
            }
          }

          let finalSource = (fused ?? firstImg).settingAlphaOne(in: baseExtent)
          let jpegData = self.renderGradedStill(
            source: finalSource,
            sourceMetadataBytes: primaryData,
            matrix: matrix,
            toneId: toneId,
            intensity: intensity,
            effects: effects,
            importedLut: importedLut,
            anamorphic: anamorphic,
            anamorphicCrop: anamorphicCrop,
            frameAspectRatio: frameAspectRatio,
            desqueeze: desqueeze,
            appleLogInput: false,
            quality: quality,
            heif10Bit: heif10Bit
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
      self.rawBurstDelegate = burstDelegate
      for _ in 0..<frameTarget {
        let s = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
        s.photoQualityPrioritization = .speed
        photoOutput.capturePhoto(with: s, delegate: burstDelegate)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 14.0) { [weak self] in
        if self?.rawBurstDelegate === burstDelegate {
          self?.rawBurstDelegate = nil
          burstDelegate.forceFinish()
        }
      }
      return
    }

    let settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
    settings.photoQualityPrioritization = .speed

    let delegate = ProcessZeroPhotoDelegate { [weak self] rawData in
      self?.rawPhotoDelegate = nil
      guard let self = self, let rawData = rawData else {
        done.send(nil)
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        if saveDngRaw {
          let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
          let rawDir = docs.appendingPathComponent("cinelens_raw", isDirectory: true)
          try? FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
          let dngUrl = rawDir.appendingPathComponent("CINELENS_RAW_\(Int(Date().timeIntervalSince1970)).dng")
          try? rawData.write(to: dngUrl, options: .atomic)
        }
        guard let source = decodeRawFrame(rawData) else {
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
          frameAspectRatio: frameAspectRatio,
          desqueeze: desqueeze,
          appleLogInput: false,
          quality: quality,
          heif10Bit: heif10Bit
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
    frameAspectRatio: Double = 0.0,
    desqueeze: Double = 1.0,
    appleLogInput: Bool = false,
    quality: Double,
    heif10Bit: Bool = false,
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
        frameAspectRatio: frameAspectRatio,
        desqueeze: desqueeze,
        appleLogInput: appleLogInput,
        quality: quality,
        heif10Bit: heif10Bit
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
    frameAspectRatio: Double = 0.0,
    desqueeze: Double,
    appleLogInput: Bool,
    quality: Double,
    heif10Bit: Bool = false
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

    // Vintage & Cinema Frame Aspect Framing (1:1, 4:5, 6:7, 3:2, 16:9, 2.39:1, XPan 65:24).
    let effectiveRatio = frameAspectRatio > 0.1
      ? frameAspectRatio
      : (anamorphic ? 2.39 : 0.0)
    if effectiveRatio > 0.1 {
      let frame = output.extent
      let targetW: CGFloat
      let targetH: CGFloat
      let currentRatio = Double(frame.width / max(frame.height, 1.0))
      if currentRatio > effectiveRatio {
        targetH = frame.height
        targetW = (frame.height * CGFloat(effectiveRatio)).rounded()
      } else {
        targetW = frame.width
        targetH = (frame.width / CGFloat(effectiveRatio)).rounded()
      }
      if abs(targetW - frame.width) > 1.0 || abs(targetH - frame.height) > 1.0 {
        let activeRect = CGRect(
          x: frame.midX - targetW / 2.0,
          y: frame.midY - targetH / 2.0,
          width: max(2, targetW),
          height: max(2, targetH)
        )
        if anamorphicCrop {
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

    guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)
      ?? CGColorSpace(name: CGColorSpace.sRGB) else {
      return nil
    }

    let context = AppDelegate.p3GradingContext
    let clampedQuality = min(max(quality, 0.5), 1.0)

    // When 10-bit HEIF is enabled, archive a true 10-bit Display P3 `.heic`
    // master on disk AND write it directly to Apple Photos (preserving 10-bit
    // smooth sky/shadow gradients without UIImage 8-bit truncation!).
    if heif10Bit,
       let heifData = try? context.heif10Representation(
         of: output,
         colorSpace: colorSpace,
         options: [
           kCIImageRepresentationLossyCompressionQuality as CIImageRepresentationOption:
             CGFloat(clampedQuality)
         ]
       ) {
      let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      let dir = docs.appendingPathComponent("cinelens_10bit", isDirectory: true)
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let heicUrl = dir.appendingPathComponent("CINELENS_10BIT_\(Int(Date().timeIntervalSince1970)).heic")
      try? heifData.write(to: heicUrl, options: .atomic)
      AppDelegate.saveRawHeifToPhotosIfAuthorized(heifData)
    }

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
    frameAspectRatio: Double = 0.0,
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
    if let edit = edit, edit.hasGeometryChanges {
      let geoSize = PhotoEditor.outputSize(
        for: CGSize(width: finalRenderWidth, height: finalRenderHeight),
        params: edit
      )
      finalRenderWidth = geoSize.width
      finalRenderHeight = geoSize.height
    }
    let effectiveFrameRatio = frameAspectRatio > 0.1
      ? frameAspectRatio
      : (anamorphic ? 2.39 : 0.0)
    if effectiveFrameRatio > 0.1 && anamorphicCrop {
      let currentR = Double(desqueezedWidth / max(desqueezedHeight, 1.0))
      if currentR > effectiveFrameRatio {
        finalRenderWidth = max(2, floor((desqueezedHeight * CGFloat(effectiveFrameRatio)) / 2.0) * 2.0)
      } else {
        finalRenderHeight = max(2, floor((desqueezedWidth / CGFloat(effectiveFrameRatio)) / 2.0) * 2.0)
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
        let alreadyOrientedForEdit =
          abs(sourceExtent.width - baseWidth) < 1.0
          && abs(sourceExtent.height - baseHeight) < 1.0
        var oriented = sourceImg
        if !preferredTransform.isIdentity && !alreadyOrientedForEdit {
          oriented = oriented.transformed(by: preferredTransform)
        }
        if oriented.extent.origin != .zero {
          oriented = oriented.transformed(
            by: CGAffineTransform(
              translationX: -oriented.extent.origin.x,
              y: -oriented.extent.origin.y
            )
          )
        }
        output = PhotoEditor.applyGeometryAndOptics(edit, to: oriented)
        output = PhotoEditor.applyColor(edit, to: output)
        output = PhotoEditor.applyMasks(edit, to: output)
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
        output = PhotoEditor.applyLensBlur(edit, to: output)
        output = PhotoEditor.applyFinish(edit, to: output, frameIndex: frameIndex)
        if output.extent.origin != .zero {
          output = output.transformed(
            by: CGAffineTransform(
              translationX: -output.extent.origin.x,
              y: -output.extent.origin.y
            )
          )
        }
        request.finish(with: output, context: gradingContext)
        return
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

      if effectiveFrameRatio > 0.1 {
        let frameExtent = output.extent
        let currentR = Double(frameExtent.width / max(frameExtent.height, 1.0))
        let targetW: CGFloat
        let targetH: CGFloat
        if currentR > effectiveFrameRatio {
          targetH = frameExtent.height
          targetW = anamorphicCrop ? finalRenderWidth : (frameExtent.height * CGFloat(effectiveFrameRatio)).rounded()
        } else {
          targetW = frameExtent.width
          targetH = anamorphicCrop ? finalRenderHeight : (frameExtent.width / CGFloat(effectiveFrameRatio)).rounded()
        }
        if abs(targetW - frameExtent.width) > 1.0 || abs(targetH - frameExtent.height) > 1.0 {
          let activeRect = CGRect(
            x: frameExtent.midX - targetW / 2.0,
            y: frameExtent.midY - targetH / 2.0,
            width: max(2, targetW),
            height: max(2, targetH)
          )
          if anamorphicCrop {
            output = output.cropped(to: activeRect).transformed(
              by: CGAffineTransform(translationX: -activeRect.origin.x, y: -activeRect.origin.y)
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
    frameAspectRatio: Double = 0.0,
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
        frameAspectRatio: frameAspectRatio,
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

  private static func saveRawHeifToPhotosIfAuthorized(_ data: Data) {
    let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    guard status == .authorized || status == .limited else { return }
    PHPhotoLibrary.shared().performChanges({
      let req = PHAssetCreationRequest.forAsset()
      req.addResource(with: .photo, data: data, options: nil)
    }, completionHandler: nil)
  }

  private func editorLoadPreview(
    path: String,
    isVideo: Bool,
    maxDimension: Int,
    timestampSeconds: Double = 0.0,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let image = PhotoEditor.previewImage(
        path: path,
        isVideo: isVideo,
        maxDimension: maxDimension,
        timestampSeconds: timestampSeconds
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
    timestampSeconds: Double = 0.0,
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
        maxDimension: maxDimension,
        timestampSeconds: timestampSeconds
      ) {
        output = PhotoEditor.render(
          params,
          look: filmLook ?? effectLook,
          matrix: filmLook == nil ? matrix : nil,
          source: source,
          sourcePath: path
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
          source: source,
          sourcePath: path
        )
      }
      if params.heif10Bit,
         let outImg = output,
         let p3 = CGColorSpace(name: CGColorSpace.displayP3),
         let heifData = try? AppDelegate.p3GradingContext.heif10Representation(
           of: outImg,
           colorSpace: p3,
           options: [
             kCIImageRepresentationLossyCompressionQuality as CIImageRepresentationOption:
               CGFloat(min(max(quality, 0.5), 1.0))
           ]
         ) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("cinelens_10bit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let heicUrl = dir.appendingPathComponent("CINELENS_EDIT_10BIT_\(Int(Date().timeIntervalSince1970)).heic")
        try? heifData.write(to: heicUrl, options: .atomic)
        AppDelegate.saveRawHeifToPhotosIfAuthorized(heifData)
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
      // Optional video trim (normalised 0...1 range from Gallery Editor).
      let trimStart = min(max(params.trimStart, 0.0), 0.98)
      let trimEnd = min(max(params.trimEnd, trimStart + 0.02), 1.0)
      if duration > 0.2 && (trimStart > 0.002 || trimEnd < 0.998) {
        let startTime = CMTime(seconds: duration * trimStart, preferredTimescale: 600)
        let clipDur = CMTime(seconds: duration * (trimEnd - trimStart), preferredTimescale: 600)
        exportSession.timeRange = CMTimeRange(start: startTime, duration: clipDur)
      }

      // Optional -14 LUFS loudness normalization via AVMutableAudioMix.
      if params.normalizeAudio,
         let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first {
        let gain = await PhotoEditor.loudnessNormalizationGain(for: asset, track: audioTrack)
        if abs(gain - 1.0) > 0.02 {
          let audioMix = AVMutableAudioMix()
          let inputParams = AVMutableAudioMixInputParameters(track: audioTrack)
          inputParams.setVolume(Float(gain), at: .zero)
          audioMix.inputParameters = [inputParams]
          exportSession.audioMix = audioMix
        }
      }

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

  private func editorAutoTone(
    path: String,
    isVideo: Bool,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let image = PhotoEditor.previewImage(
        path: path,
        isVideo: isVideo,
        maxDimension: 512
      )
      let tone = image.map { PhotoEditor.computeAutoTone(for: $0) } ?? [:]
      DispatchQueue.main.async {
        result(tone)
      }
    }
  }

  private func editorHistogram(
    bytes: Data,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let image = CIImage(data: bytes)
      let hist = image.map { PhotoEditor.computeHistogram(for: $0) } ?? [:]
      DispatchQueue.main.async {
        result(hist)
      }
    }
  }

  private func editorScopes(
    bytes: Data,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let image = CIImage(data: bytes)
      let scopes = image.map { PhotoEditor.computeScopes(for: $0) } ?? [:]
      DispatchQueue.main.async {
        result(scopes)
      }
    }
  }

  private func editorMatchColor(
    sourcePath: String,
    isVideo: Bool,
    referencePath: String,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      guard let src = PhotoEditor.previewImage(path: sourcePath, isVideo: isVideo, maxDimension: 512),
            let refImg = PhotoEditor.previewImage(path: referencePath, isVideo: false, maxDimension: 512) else {
        DispatchQueue.main.async { result([:]) }
        return
      }
      let matched = PhotoEditor.matchColor(source: src, reference: refImg)
      DispatchQueue.main.async {
        result(matched)
      }
    }
  }

  // MARK: - Tahap 2: Live Metal 3D LUT Viewfinder, Direct-to-Disk Video & DOP Telemetry

  private func enableLiveMetalPreview(
    args: [String: Any],
    result: @escaping FlutterResult
  ) {
    guard let registry = textureRegistry,
          let session = activeSession,
          let dataOutput = session.outputs.compactMap({ $0 as? AVCaptureVideoDataOutput }).first,
          let originalDelegate = dataOutput.sampleBufferDelegate,
          let originalQueue = dataOutput.sampleBufferCallbackQueue else {
      result(nil)
      return
    }

    if let existing = liveMetalPipeline {
      existing.updateConfig(args: args)
      result(existing.textureId)
      return
    }

    let pipeline = LiveMetalViewfinderPipeline(
      registry: registry,
      dataOutput: dataOutput,
      originalDelegate: originalDelegate,
      originalQueue: originalQueue,
      channel: nativeChannel
    )
    pipeline.updateConfig(args: args)
    pipeline.attach()
    liveMetalPipeline = pipeline
    result(pipeline.textureId)
  }

  private func disableLiveMetalPreview() {
    liveMetalPipeline?.detach()
    liveMetalPipeline = nil
  }

  private func startDirectLutRecording(
    args: [String: Any],
    result: @escaping FlutterResult
  ) {
    guard let registry = textureRegistry,
          let session = activeSession,
          let dataOutput = session.outputs.compactMap({ $0 as? AVCaptureVideoDataOutput }).first else {
      result(FlutterError(code: "no_session", message: "Camera session unavailable.", details: nil))
      return
    }

    if liveMetalPipeline == nil {
      guard let originalDelegate = dataOutput.sampleBufferDelegate,
            let originalQueue = dataOutput.sampleBufferCallbackQueue else {
        result(FlutterError(code: "no_delegate", message: "Video output delegate unavailable.", details: nil))
        return
      }
      let pipeline = LiveMetalViewfinderPipeline(
        registry: registry,
        dataOutput: dataOutput,
        originalDelegate: originalDelegate,
        originalQueue: originalQueue,
        channel: nativeChannel
      )
      pipeline.updateConfig(args: args)
      pipeline.attach()
      liveMetalPipeline = pipeline
    } else {
      liveMetalPipeline?.updateConfig(args: args)
    }

    let fps = (args["fps"] as? NSNumber)?.intValue ?? 24
    let bitrate = (args["bitrate"] as? NSNumber)?.intValue ?? 45_000_000
    liveMetalPipeline?.startDirectRecording(fps: fps, bitrate: bitrate, result: result)
  }

  private func stopDirectLutRecording(result: @escaping FlutterResult) {
    guard let pipeline = liveMetalPipeline else {
      result(FlutterError(code: "not_recording", message: "No active direct LUT recording.", details: nil))
      return
    }
    pipeline.stopDirectRecording(result: result)
  }

  private func configureDopTelemetry(horizon: Bool, audio: Bool) {
    dopHorizonEnabled = horizon
    dopAudioEnabled = audio

    if horizon {
      if dopMotionManager == nil {
        dopMotionManager = CMMotionManager()
      }
      if let mm = dopMotionManager, mm.isDeviceMotionAvailable, !mm.isDeviceMotionActive {
        mm.deviceMotionUpdateInterval = 1.0 / 20.0
        mm.startDeviceMotionUpdates()
      }
    } else {
      dopMotionManager?.stopDeviceMotionUpdates()
    }

    if audio {
      startAudioMeterIfNeeded()
    } else {
      stopAudioMeter()
    }

    if horizon || audio {
      if dopTelemetryTimer == nil {
        dopTelemetryTimer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in
          self?.pushDopTelemetryTick()
        }
      }
    } else {
      dopTelemetryTimer?.invalidate()
      dopTelemetryTimer = nil
    }
  }

  private func startAudioMeterIfNeeded() {
    guard dopAudioRecorder == nil else { return }
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playAndRecord, mode: .videoRecording, options: [.mixWithOthers, .defaultToSpeaker])
      try session.setActive(true)
      dopAudioSessionActive = true
      let url = URL(fileURLWithPath: "/dev/null")
      let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatAppleLossless),
        AVSampleRateKey: 44100.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.min.rawValue
      ]
      let recorder = try AVAudioRecorder(url: url, settings: settings)
      recorder.isMeteringEnabled = true
      recorder.record()
      dopAudioRecorder = recorder
    } catch {
      // Mic permission denied or busy; leave meter silent gracefully.
    }
  }

  private func stopAudioMeter() {
    dopAudioRecorder?.stop()
    dopAudioRecorder = nil
    if dopAudioSessionActive {
      dopAudioSessionActive = false
    }
  }

  private func pushDopTelemetryTick() {
    var payload: [String: Any] = [:]
    if dopHorizonEnabled, let motion = dopMotionManager?.deviceMotion {
      let gx = motion.gravity.x
      let gy = motion.gravity.y
      // Angle in degrees relative to upright gravity vector (-45...45 near level).
      let angleRad = atan2(gx, -gy)
      var deg = angleRad * 180.0 / Double.pi
      // Wrap to nearest 90° cardinal orientation so both portrait & landscape level smoothly.
      let nearest90 = (deg / 90.0).rounded() * 90.0
      deg = deg - nearest90
      payload["horizonDegrees"] = (deg * 10.0).rounded() / 10.0
    }
    if dopAudioEnabled, let rec = dopAudioRecorder {
      rec.updateMeters()
      let peak = Double(rec.peakPower(forChannel: 0))
      let avg = Double(rec.averagePower(forChannel: 0))
      payload["audioPeakDb"] = max(-60.0, min(0.0, peak))
      payload["audioAvgDb"] = max(-60.0, min(0.0, avg))
    }
    if !payload.isEmpty {
      nativeChannel?.invokeMethod("dopTelemetry", arguments: payload)
    }
  }

  // MARK: - v2.3.0 Pro Hardware, Metadata, Video Poster, Vision AI Mask & .cube Export

  private func generateVideoThumbnail(path: String, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      let url = URL(fileURLWithPath: path)
      let asset = AVURLAsset(url: url)
      let duration = max(0.0, asset.duration.seconds.isFinite ? asset.duration.seconds : 0.0)

      let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      let dir = caches.appendingPathComponent("cinelens_vthumbs", isDirectory: true)
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let safeName = url.lastPathComponent.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression)
      let thumbURL = dir.appendingPathComponent("\(safeName)_thumb.jpg")

      if FileManager.default.fileExists(atPath: thumbURL.path) {
        DispatchQueue.main.async {
          result(["thumbPath": thumbURL.path, "durationSeconds": duration])
        }
        return
      }

      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 480, height: 480)
      let sampleTime = CMTime(seconds: min(0.15, duration * 0.1), preferredTimescale: 600)
      if let cg = try? generator.copyCGImage(at: sampleTime, actualTime: nil) {
        let ui = UIImage(cgImage: cg)
        if let jpg = ui.jpegData(compressionQuality: 0.82) {
          try? jpg.write(to: thumbURL, options: .atomic)
          DispatchQueue.main.async {
            result(["thumbPath": thumbURL.path, "durationSeconds": duration])
          }
          return
        }
      }
      DispatchQueue.main.async {
        result(["durationSeconds": duration])
      }
    }
  }

  private func inspectMediaMetadata(path: String, isVideo: Bool, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      var info: [String: Any] = [:]
      let url = URL(fileURLWithPath: path)
      if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
         let size = attrs[.size] as? NSNumber {
        info["fileSizeKB"] = Int(round(size.doubleValue / 1024.0))
      }

      if isVideo {
        let asset = AVURLAsset(url: url)
        let dur = asset.duration.seconds
        if dur.isFinite { info["durationSeconds"] = (dur * 10.0).rounded() / 10.0 }
        if let track = asset.tracks(withMediaType: .video).first {
          let rect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
          info["width"] = Int(abs(rect.width).rounded())
          info["height"] = Int(abs(rect.height).rounded())
          info["fps"] = Int(track.nominalFrameRate.rounded())
          let mbps = Double(track.estimatedDataRate) / 1_000_000.0
          if mbps > 0.05 { info["bitrateMbps"] = (mbps * 10.0).rounded() / 10.0 }
          if let desc = track.formatDescriptions.first {
            let fmt = desc as! CMFormatDescription
            let sub = CMFormatDescriptionGetMediaSubType(fmt)
            let chars: [Character] = [
              Character(UnicodeScalar((sub >> 24) & 0xFF) ?? "?"),
              Character(UnicodeScalar((sub >> 16) & 0xFF) ?? "?"),
              Character(UnicodeScalar((sub >> 8) & 0xFF) ?? "?"),
              Character(UnicodeScalar(sub & 0xFF) ?? "?")
            ]
            info["codec"] = String(chars).trimmingCharacters(in: .whitespaces)
          }
        }
      } else if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        info["width"] = w
        info["height"] = h
        if w > 0 && h > 0 {
          info["megapixels"] = (Double(w * h) / 1_000_000.0 * 10.0).rounded() / 10.0
        }
        if let profile = props[kCGImagePropertyProfileName] as? String {
          info["colorSpace"] = profile
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
          if let model = tiff[kCGImagePropertyTIFFModel] as? String {
            info["cameraModel"] = model
          }
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
          if let fl35 = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.intValue {
            info["focalLength"] = "\(fl35)mm"
          } else if let fl = (exif[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue {
            info["focalLength"] = String(format: "%.1fmm", fl)
          }
          if let fn = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue {
            info["fNumber"] = String(format: "f/%.1f", fn)
          }
          if let exp = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue, exp > 0 {
            if exp < 1.0 {
              info["shutter"] = "1/\(max(1, Int((1.0 / exp).rounded())))s"
            } else {
              info["shutter"] = String(format: "%.1fs", exp)
            }
          }
          if let isos = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber], let iso = isos.first {
            info["iso"] = "ISO \(iso.intValue)"
          }
          if let dt = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            info["dateTime"] = dt
          }
        }
      }
      DispatchQueue.main.async { result(info) }
    }
  }

  /// Offline iOS Vision Neural Engine Smart Masking (`subject` or `sky`/`background`).
  private func editorGenerateAiMask(
    path: String,
    isVideo: Bool,
    target: String,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      guard let preview = PhotoEditor.previewImage(path: path, isVideo: isVideo, maxDimension: 1024),
            let srgb = CGColorSpace(name: CGColorSpace.sRGB),
            let cgImg = AppDelegate.gradingContext.createCGImage(preview, from: preview.extent, format: .RGBA8, colorSpace: srgb) else {
        DispatchQueue.main.async { result(nil) }
        return
      }

      var maskCI: CIImage?

      // 1. Try iOS 17+ Foreground Instance Segmentation first (works on people, pets, cars, objects!).
      if target != "sky", #available(iOS 17.0, *) {
        let req = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImg, options: [:])
        if (try? handler.perform([req])) != nil,
           let obs = req.results?.first,
           let buf = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler) {
          maskCI = CIImage(cvPixelBuffer: buf)
        }
      }

      // 2. Fallback to iOS 15+ Person Segmentation.
      if maskCI == nil && target != "sky" {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .balanced
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: cgImg, options: [:])
        if (try? handler.perform([req])) != nil,
           let buf = req.results?.first?.pixelBuffer {
          maskCI = CIImage(cvPixelBuffer: buf)
        }
      }

      // 3. Sky / Fallback atmospheric upper-luminance matte.
      if maskCI == nil {
        let ext = preview.extent
        let topGrad = CIFilter(
          name: "CILinearGradient",
          parameters: [
            "inputPoint0": CIVector(x: ext.midX, y: ext.maxY * 0.85),
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            "inputPoint1": CIVector(x: ext.midX, y: ext.maxY * 0.32),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1)
          ]
        )?.outputImage?.cropped(to: ext)
        let bright = preview.applyingFilter(
          "CIColorMatrix",
          parameters: [
            "inputRVector": CIVector(x: 0.4, y: 0.8, z: 1.2, w: 0),
            "inputGVector": CIVector(x: 0.4, y: 0.8, z: 1.2, w: 0),
            "inputBVector": CIVector(x: 0.4, y: 0.8, z: 1.2, w: 0),
            "inputBiasVector": CIVector(x: -0.65, y: -0.65, z: -0.65, w: 0)
          ]
        ).applyingFilter("CIColorClamp")
        if let g = topGrad {
          maskCI = bright.applyingFilter(
            "CIMultiplyCompositing",
            parameters: [kCIInputBackgroundImageKey: g]
          ).cropped(to: ext)
        }
      }

      guard var finalMask = maskCI else {
        DispatchQueue.main.async { result(nil) }
        return
      }
      if finalMask.extent.origin != .zero {
        finalMask = finalMask.transformed(
          by: CGAffineTransform(translationX: -finalMask.extent.origin.x, y: -finalMask.extent.origin.y)
        )
      }
      if target == "background" {
        finalMask = finalMask.applyingFilter("CIColorInvert").cropped(to: finalMask.extent)
      }

      guard let outCG = AppDelegate.gradingContext.createCGImage(
        finalMask,
        from: finalMask.extent,
        format: .RGBA8,
        colorSpace: srgb
      ),
      let png = UIImage(cgImage: outCG).pngData() else {
        DispatchQueue.main.async { result(nil) }
        return
      }

      let outURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("cinelens_aimask_\(UUID().uuidString.prefix(8)).png")
      do {
        try png.write(to: outURL, options: .atomic)
        DispatchQueue.main.async { result(outURL.path) }
      } catch {
        DispatchQueue.main.async { result(nil) }
      }
    }
  }

  /// Exports the active Editor colour pipeline into an industry-standard 33×33×33 `.cube` 3D LUT file.
  private func editorExportCubeLut(args: [String: Any], result: @escaping FlutterResult) {
    let params = PhotoEditor.Params.from(args)
    let (filmLook, effectLook) = AppDelegate.editorLooks(args: args)
    let matrix = args["matrix"] as? [Double]
    let title = (args["title"] as? String) ?? "CineLens_Grade"

    DispatchQueue.global(qos: .userInitiated).async {
      guard let cubePath = PhotoEditor.exportCubeFile(
        params: params,
        look: filmLook ?? effectLook,
        matrix: filmLook == nil ? matrix : nil,
        title: title
      ) else {
        DispatchQueue.main.async { result(nil) }
        return
      }
      DispatchQueue.main.async { result(cubePath) }
    }
  }

  /// Enables/disables physical iPhone Volume Up/Down & Bluetooth clicker shutter.
  private func setVolumeShutterEnabled(_ enabled: Bool) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      if !enabled {
        self.volumeObservation?.invalidate()
        self.volumeObservation = nil
        self.hiddenVolumeView?.removeFromSuperview()
        self.hiddenVolumeView = nil
        return
      }
      guard self.volumeObservation == nil else { return }

      let session = AVAudioSession.sharedInstance()
      try? session.setActive(true)

      if self.hiddenVolumeView == nil,
         let win = UIApplication.shared.connectedScenes
           .compactMap({ $0 as? UIWindowScene })
           .flatMap({ $0.windows })
           .first(where: { $0.isKeyWindow }) {
        let vv = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        vv.alpha = 0.01
        win.addSubview(vv)
        self.hiddenVolumeView = vv
      }

      self.volumeObservation = session.observe(\.outputVolume, options: [.old, .new]) { [weak self] _, change in
        guard let self = self, !self.suppressingVolumeReset else { return }
        guard let oldV = change.oldValue, let newV = change.newValue, abs(newV - oldV) > 0.001 else { return }
        let now = Date().timeIntervalSince1970
        guard now - self.lastVolumeShutterTime > 0.45 else { return }
        self.lastVolumeShutterTime = now

        // Keep system volume away from 0.0 / 1.0 limits so subsequent presses still emit KVO.
        if newV <= 0.06 || newV >= 0.94 {
          if let slider = self.hiddenVolumeView?.subviews.compactMap({ $0 as? UISlider }).first {
            self.suppressingVolumeReset = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
              slider.value = 0.5
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.suppressingVolumeReset = false
              }
            }
          }
        }
        DispatchQueue.main.async {
          self.nativeChannel?.invokeMethod("hardwareShutterPressed", arguments: nil)
        }
      }
    }
  }

  private func listAudioInputs() -> [[String: Any]] {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playAndRecord, mode: .videoRecording, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
    let currentUID = session.preferredInput?.uid ?? session.currentRoute.inputs.first?.uid
    let inputs = session.availableInputs ?? []
    return inputs.map { port in
      [
        "uid": port.uid,
        "name": port.portName,
        "type": port.portType.rawValue,
        "selected": port.uid == currentUID
      ]
    }
  }

  private func selectAudioInput(portUID: String?) -> Bool {
    let session = AVAudioSession.sharedInstance()
    guard let uid = portUID, !uid.isEmpty else {
      try? session.setPreferredInput(nil)
      return true
    }
    guard let match = session.availableInputs?.first(where: { $0.uid == uid }) else {
      return false
    }
    do {
      try session.setPreferredInput(match)
      return true
    } catch {
      return false
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
  /// ACES / AgX filmic highlight shoulder roll-off (0…1).
  let filmicRollOff: Double

  /// True when every manual effect is off, so the renderer can skip the passes.
  var isNeutral: Bool {
    grain <= 0.001
      && halation <= 0.001
      && bloom <= 0.001
      && vignette <= 0.001
      && shadowDepth <= 0.001
      && acutance <= 0.001
      && filmicRollOff <= 0.001
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
      acutance: unit("acutance"),
      filmicRollOff: unit("filmicRollOff")
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

  /// ACES / AgX filmic highlight roll-off (0…1).
  var filmicRollOff: Double = 0.0

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

    // 1c. ACES / AgX Filmic Highlight Roll-Off: smooth creamy shoulder above 0.56 luma.
    if filmicRollOff > 0.005 {
      output = FilmEngine.applyFilmicRollOff(to: output, strength: filmicRollOff)
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

    // Luminance-weighted Silver-Halide modulation: peaks organically in midtones
    // (0.20..0.75) while attenuating grain in ink-black shadows & pure specular
    // whites, matching physical film emulsion response with zero shadow blotches!
    let lumaWeight = base.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
      ]
    ).applyingFilter(
      "CIColorPolynomial",
      parameters: [
        "inputRedCoefficients": CIVector(x: 0.20, y: 3.10, z: -2.95, w: 0),
        "inputGreenCoefficients": CIVector(x: 0.20, y: 3.10, z: -2.95, w: 0),
        "inputBlueCoefficients": CIVector(x: 0.20, y: 3.10, z: -2.95, w: 0),
        "inputAlphaCoefficients": CIVector(x: 1, y: 0, z: 0, w: 0)
      ]
    ).applyingFilter(
      "CIColorClamp",
      parameters: [
        "inputMinComponents": CIVector(x: 0.18, y: 0.18, z: 0.18, w: 1),
        "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
      ]
    ).cropped(to: extent)

    let neutralGrey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
      .cropped(to: extent)
    let weightedGrain = limited.applyingFilter(
      "CIBlendWithMask",
      parameters: [
        kCIInputBackgroundImageKey: neutralGrey,
        kCIInputMaskImageKey: lumaWeight
      ]
    ).cropped(to: extent)

    return weightedGrain
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
    let filmicRollOff = effects?.filmicRollOff ?? 0.0

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
      acutance: acutance,
      filmicRollOff: filmicRollOff
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
      acutance: effects?.acutance ?? 0.0,
      filmicRollOff: effects?.filmicRollOff ?? 0.0
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
      acutance: effects.acutance,
      filmicRollOff: effects.filmicRollOff
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
  private static var filmicRollOffCubeCache: [Int: Data] = [:]

  /// ACES / AgX-inspired Filmic Highlight Roll-Off: smoothly compresses bright
  /// highlights above luma 0.56 while gently desaturating clipped neon peaks
  /// toward creamy organic film white (eliminating harsh digital highlight clip).
  static func applyFilmicRollOff(to image: CIImage, strength: Double) -> CIImage {
    let clamped = min(max(strength, 0.0), 1.0)
    guard clamped > 0.005 else { return image }
    let bucket = Int((clamped * 40.0).rounded())

    cacheLock.lock()
    var cube = filmicRollOffCubeCache[bucket]
    cacheLock.unlock()

    if cube == nil {
      let s = Double(bucket) / 40.0
      let n = 33
      let last = Double(n - 1)
      var values = [Float]()
      values.reserveCapacity(n * n * n * 4)
      let knee = 0.54
      for bi in 0..<n {
        for gi in 0..<n {
          for ri in 0..<n {
            var r = Double(ri) / last
            var g = Double(gi) / last
            var b = Double(bi) / last
            func compress(_ c: Double) -> Double {
              guard c > knee else { return c }
              let over = c - knee
              let span = 1.0 - knee
              let k = 0.8 + s * 2.1
              let rolled = knee + span * ((1.0 - exp(-k * over / span)) / (1.0 - exp(-k)))
              return c + (rolled - c) * s
            }
            r = compress(r)
            g = compress(g)
            b = compress(b)
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            // Creamy AgX highlight desaturation above 0.68 luma
            let desat = smoothstep(0.66, 1.0, y) * 0.42 * s
            r = y + (r - y) * (1.0 - desat)
            g = y + (g - y) * (1.0 - desat)
            b = y + (b - y) * (1.0 - desat)
            values.append(Float(min(max(r, 0.0), 1.0)))
            values.append(Float(min(max(g, 0.0), 1.0)))
            values.append(Float(min(max(b, 0.0), 1.0)))
            values.append(1.0)
          }
        }
      }
      let built = values.withUnsafeBufferPointer { Data(buffer: $0) }
      cacheLock.lock()
      if filmicRollOffCubeCache.count > 16 { filmicRollOffCubeCache.removeAll() }
      filmicRollOffCubeCache[bucket] = built
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

  struct ColorWheelParams {
    var hue: Double = 0
    var saturation: Double = 0
    var luminance: Double = 0

    var isNeutral: Bool {
      saturation <= 0.001 && abs(luminance) < 0.001
    }

    static func from(_ raw: Any?) -> ColorWheelParams {
      guard let map = raw as? [String: Any] else { return ColorWheelParams() }
      var h = ((map["hue"] as? NSNumber)?.doubleValue ?? 0)
        .truncatingRemainder(dividingBy: 360.0)
      if h < 0 { h += 360.0 }
      let s = min(max((map["sat"] as? NSNumber)?.doubleValue ?? 0, 0), 1)
      let l = min(max((map["lum"] as? NSNumber)?.doubleValue ?? 0, -1), 1)
      return ColorWheelParams(hue: h, saturation: s, luminance: l)
    }
  }

  struct ColorGradingParams {
    var shadows = ColorWheelParams()
    var midtones = ColorWheelParams()
    var highlights = ColorWheelParams()
    var blending: Double = 0.5
    var balance: Double = 0.0

    var isNeutral: Bool {
      shadows.isNeutral && midtones.isNeutral && highlights.isNeutral
    }

    static func from(_ raw: Any?) -> ColorGradingParams {
      guard let map = raw as? [String: Any] else { return ColorGradingParams() }
      return ColorGradingParams(
        shadows: ColorWheelParams.from(map["shadows"]),
        midtones: ColorWheelParams.from(map["midtones"]),
        highlights: ColorWheelParams.from(map["highlights"]),
        blending: min(max((map["blending"] as? NSNumber)?.doubleValue ?? 0.5, 0), 1),
        balance: min(max((map["balance"] as? NSNumber)?.doubleValue ?? 0, -1), 1)
      )
    }
  }

  struct MaskParams {
    var isLinear: Bool = false
    var maskImagePath: String? = nil
    var startX: Double = 0.5
    var startY: Double = 0.5
    var endX: Double = 0.82
    var endY: Double = 0.5
    var feather: Double = 0.5
    var inverted: Bool = false
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var temperature: Double = 0
    var saturation: Double = 0
    var clarity: Double = 0
    var sharpen: Double = 0

    var isNeutral: Bool {
      abs(exposure) < 0.001
        && abs(contrast) < 0.001
        && abs(highlights) < 0.001
        && abs(shadows) < 0.001
        && abs(temperature) < 0.001
        && abs(saturation) < 0.001
        && abs(clarity) < 0.001
        && sharpen < 0.001
    }

    static func from(_ raw: Any?) -> MaskParams? {
      guard let map = raw as? [String: Any] else { return nil }
      func num(_ key: String, fallback: Double = 0) -> Double {
        (map[key] as? NSNumber)?.doubleValue ?? fallback
      }
      var m = MaskParams()
      m.isLinear = (map["type"] as? String) == "linear"
      if let mp = map["maskImagePath"] as? String, !mp.isEmpty {
        m.maskImagePath = mp
      }
      m.startX = min(max(num("startX", fallback: 0.5), 0), 1)
      m.startY = min(max(num("startY", fallback: m.isLinear ? 0.15 : 0.5), 0), 1)
      m.endX = min(max(num("endX", fallback: m.isLinear ? 0.5 : 0.82), 0), 1)
      m.endY = min(max(num("endY", fallback: m.isLinear ? 0.55 : 0.5), 0), 1)
      m.feather = min(max(num("feather", fallback: 0.5), 0.05), 1)
      m.inverted = (map["inverted"] as? Bool) ?? false
      m.exposure = min(max(num("exposure"), -2), 2)
      m.contrast = min(max(num("contrast"), -1), 1)
      m.highlights = min(max(num("highlights"), -1), 1)
      m.shadows = min(max(num("shadows"), -1), 1)
      m.temperature = min(max(num("temperature"), -1), 1)
      m.saturation = min(max(num("saturation"), -1), 1)
      m.clarity = min(max(num("clarity"), -1), 1)
      m.sharpen = min(max(num("sharpen"), 0), 1)
      return m
    }
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
    var blackAndWhite: Bool = false
    var clarity: Double = 0
    var texture: Double = 0
    var dehaze: Double = 0
    var fade: Double = 0
    var grain: Double = 0
    var grainSize: Double = 0.25
    var grainRoughness: Double = 0.5
    var vignette: Double = 0
    var vignetteMidpoint: Double = 0.5
    var vignetteFeather: Double = 0.5
    var vignetteRoundness: Double = 0.0
    var sharpen: Double = 0
    var sharpenRadius: Double = 0.35
    var noiseReduction: Double = 0
    var colorNoiseReduction: Double = 0
    var lensDistortion: Double = 0
    var opticsVignette: Double = 0
    var defringe: Double = 0
    var cropAspect: String = "original"
    var rotateQuarterTurns: Int = 0
    var flipHorizontal: Bool = false
    var flipVertical: Bool = false
    var straightenDegrees: Double = 0
    var verticalPerspective: Double = 0
    var horizontalPerspective: Double = 0
    var blurAmount: Double = 0
    var blurStyle: String = "radial"
    var blurCenterX: Double = 0.5
    var blurCenterY: Double = 0.5
    var blurRadius: Double = 0.32
    var blurFeather: Double = 0.45
    var blurBokehBoost: Double = 0.25
    var curveRgb: [CurvePoint] = []
    var curveRed: [CurvePoint] = []
    var curveGreen: [CurvePoint] = []
    var curveBlue: [CurvePoint] = []
    var hsl: [[Double]] = Array(repeating: [0, 0, 0], count: 8)
    var colorGrading = ColorGradingParams()
    var masks: [MaskParams] = []
    /// OpenFilm-inspired Cinema Color Science: Multi-Camera Log IDT, ASC CDL,
    /// Video Trim & -14 LUFS Loudness Normalization.
    var inputLogProfile: String = "rec709"
    var cdlSlope: [Double] = [1.0, 1.0, 1.0]
    var cdlOffset: [Double] = [0.0, 0.0, 0.0]
    var cdlPower: [Double] = [1.0, 1.0, 1.0]
    var cdlSaturation: Double = 1.0
    var trimStart: Double = 0.0
    var trimEnd: Double = 1.0
    var normalizeAudio: Bool = false
    /// v2.3.0 Output Engine & Editorial Frame upgrades:
    var filmicRollOff: Double = 0.0
    var colorDensity: Double = 0.0
    var skinProtection: Double = 0.0
    var heif10Bit: Bool = false
    var frameStyle: String = "none"
    var frameExifCaption: Bool = false
    var frameDateStamp: Bool = false
    var frameCustomText: String = ""

    var isCdlNeutral: Bool {
      abs(cdlSlope[0] - 1) < 0.002 && abs(cdlSlope[1] - 1) < 0.002 && abs(cdlSlope[2] - 1) < 0.002
        && abs(cdlOffset[0]) < 0.002 && abs(cdlOffset[1]) < 0.002 && abs(cdlOffset[2]) < 0.002
        && abs(cdlPower[0] - 1) < 0.002 && abs(cdlPower[1] - 1) < 0.002 && abs(cdlPower[2] - 1) < 0.002
        && abs(cdlSaturation - 1) < 0.002
    }

    var hasGeometryChanges: Bool {
      cropAspect != "original"
        || rotateQuarterTurns != 0
        || flipHorizontal
        || flipVertical
        || abs(straightenDegrees) > 0.05
        || abs(verticalPerspective) > 0.001
        || abs(horizontalPerspective) > 0.001
    }

    static func from(_ args: [String: Any]) -> Params {
      var params = Params()
      guard let raw = args["edit"] as? [String: Any] else { return params }

      func number(_ key: String, fallback: Double = 0) -> Double {
        (raw[key] as? NSNumber)?.doubleValue ?? fallback
      }
      func signed(_ key: String) -> Double {
        min(max(number(key), -1), 1)
      }
      func positive(_ key: String, fallback: Double = 0) -> Double {
        min(max(number(key, fallback: fallback), 0), 1)
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
      params.blackAndWhite = (raw["blackAndWhite"] as? Bool) ?? false
      params.clarity = signed("clarity")
      params.texture = signed("texture")
      params.dehaze = signed("dehaze")
      params.fade = positive("fade")
      params.grain = positive("grain")
      params.grainSize = positive("grainSize", fallback: 0.25)
      params.grainRoughness = positive("grainRoughness", fallback: 0.5)
      params.vignette = positive("vignette")
      params.vignetteMidpoint = positive("vignetteMidpoint", fallback: 0.5)
      params.vignetteFeather = positive("vignetteFeather", fallback: 0.5)
      params.vignetteRoundness = signed("vignetteRoundness")
      params.sharpen = positive("sharpen")
      params.sharpenRadius = positive("sharpenRadius", fallback: 0.35)
      params.noiseReduction = positive("noiseReduction")
      params.colorNoiseReduction = positive("colorNoiseReduction")
      params.lensDistortion = signed("lensDistortion")
      params.opticsVignette = positive("opticsVignette")
      params.defringe = positive("defringe")
      params.cropAspect = (raw["cropAspect"] as? String) ?? "original"
      let rawTurns = (raw["rotateQuarterTurns"] as? NSNumber)?.intValue ?? 0
      params.rotateQuarterTurns = ((rawTurns % 4) + 4) % 4
      params.flipHorizontal = (raw["flipHorizontal"] as? Bool) ?? false
      params.flipVertical = (raw["flipVertical"] as? Bool) ?? false
      params.straightenDegrees = min(max(number("straightenDegrees"), -45), 45)
      params.verticalPerspective = signed("verticalPerspective")
      params.horizontalPerspective = signed("horizontalPerspective")
      params.blurAmount = positive("blurAmount")
      params.blurStyle = (raw["blurStyle"] as? String) == "linear" ? "linear" : "radial"
      params.blurCenterX = positive("blurCenterX", fallback: 0.5)
      params.blurCenterY = positive("blurCenterY", fallback: 0.5)
      params.blurRadius = min(max(number("blurRadius", fallback: 0.32), 0.05), 0.9)
      params.blurFeather = min(max(number("blurFeather", fallback: 0.45), 0.05), 1.0)
      params.blurBokehBoost = positive("blurBokehBoost", fallback: 0.25)
      params.curveRgb = curve(raw["curveRgb"])
      params.curveRed = curve(raw["curveRed"])
      params.curveGreen = curve(raw["curveGreen"])
      params.curveBlue = curve(raw["curveBlue"])
      params.colorGrading = ColorGradingParams.from(raw["colorGrading"])

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
      if let rawMasks = raw["masks"] as? [Any] {
        params.masks = rawMasks.compactMap { MaskParams.from($0) }
      }
      params.inputLogProfile = (raw["inputLogProfile"] as? String) ?? "rec709"
      func triple(_ key: String, fallback: [Double], lo: Double, hi: Double) -> [Double] {
        guard let arr = raw[key] as? [Any], arr.count >= 3 else { return fallback }
        let nums = arr.prefix(3).compactMap { ($0 as? NSNumber)?.doubleValue }
        guard nums.count == 3 else { return fallback }
        return nums.map { min(max($0, lo), hi) }
      }
      params.cdlSlope = triple("cdlSlope", fallback: [1, 1, 1], lo: 0.4, hi: 2.0)
      params.cdlOffset = triple("cdlOffset", fallback: [0, 0, 0], lo: -0.35, hi: 0.35)
      params.cdlPower = triple("cdlPower", fallback: [1, 1, 1], lo: 0.5, hi: 2.0)
      params.cdlSaturation = min(max(number("cdlSaturation", fallback: 1.0), 0.0), 2.0)
      params.trimStart = min(max(number("trimStart", fallback: 0.0), 0.0), 0.98)
      params.trimEnd = min(max(number("trimEnd", fallback: 1.0), params.trimStart + 0.02), 1.0)
      params.normalizeAudio = (raw["normalizeAudio"] as? Bool) ?? false
      params.filmicRollOff = positive("filmicRollOff")
      params.colorDensity = signed("colorDensity")
      params.skinProtection = positive("skinProtection")
      params.heif10Bit = (raw["heif10Bit"] as? Bool) ?? false
      params.frameStyle = (raw["frameStyle"] as? String) ?? "none"
      params.frameExifCaption = (raw["frameExifCaption"] as? Bool) ?? false
      params.frameDateStamp = (raw["frameDateStamp"] as? Bool) ?? false
      params.frameCustomText = (raw["frameCustomText"] as? String) ?? ""
      return params
    }
  }

  // MARK: Geometry & Optics

  private static func aspectRatioValue(for key: String) -> CGFloat? {
    switch key {
    case "1:1": return 1.0
    case "4:5": return 4.0 / 5.0
    case "6:7": return 6.0 / 7.0
    case "3:4": return 3.0 / 4.0
    case "2:3": return 2.0 / 3.0
    case "4:3": return 4.0 / 3.0
    case "3:2": return 3.0 / 2.0
    case "16:9": return 16.0 / 9.0
    case "9:16": return 9.0 / 16.0
    case "2.39:1": return 2.39
    case "65:24": return 65.0 / 24.0
    default: return nil
    }
  }

  /// Final pixel size after rotation and aspect crop (used by video export).
  static func outputSize(for baseSize: CGSize, params: Params) -> CGSize {
    var w = baseSize.width
    var h = baseSize.height
    if params.rotateQuarterTurns % 2 == 1 {
      swap(&w, &h)
    }
    if let targetRatio = aspectRatioValue(for: params.cropAspect),
       w > 1, h > 1 {
      let current = w / h
      if current > targetRatio {
        w = h * targetRatio
      } else {
        h = w / targetRatio
      }
    }
    return CGSize(
      width: max(2, floor(w / 2.0) * 2.0),
      height: max(2, floor(h / 2.0) * 2.0)
    )
  }

  private static func reorigin(_ image: CIImage) -> CIImage {
    let ext = image.extent
    guard ext.origin != .zero, ext.origin.x.isFinite, ext.origin.y.isFinite else {
      return image
    }
    return image.transformed(
      by: CGAffineTransform(translationX: -ext.origin.x, y: -ext.origin.y)
    )
  }

  static func applyGeometryAndOptics(_ params: Params, to image: CIImage) -> CIImage {
    var output = reorigin(image)
    let initialExtent = output.extent
    guard initialExtent.width > 1, initialExtent.height > 1 else { return image }

    // 1. 90-degree quarter turns (clockwise in UI = negative angle in Core Image Y-up).
    if params.rotateQuarterTurns != 0 {
      let angle = -CGFloat.pi / 2.0 * CGFloat(params.rotateQuarterTurns)
      output = reorigin(output.transformed(by: CGAffineTransform(rotationAngle: angle)))
    }

    // 2. Flip horizontal / vertical.
    if params.flipHorizontal || params.flipVertical {
      let sx: CGFloat = params.flipHorizontal ? -1.0 : 1.0
      let sy: CGFloat = params.flipVertical ? -1.0 : 1.0
      output = reorigin(output.transformed(by: CGAffineTransform(scaleX: sx, y: sy)))
    }

    // 3. Lens barrel/pincushion distortion correction.
    if abs(params.lensDistortion) > 0.005 {
      let ext = output.extent
      let radius = hypot(ext.width, ext.height) * 0.65
      let scale = CGFloat(params.lensDistortion * 0.42)
      let distorted = output.clampedToExtent().applyingFilter(
        "CIBumpDistortion",
        parameters: [
          kCIInputCenterKey: CIVector(x: ext.midX, y: ext.midY),
          kCIInputRadiusKey: radius,
          kCIInputScaleKey: scale
        ]
      ).cropped(to: ext)
      output = reorigin(distorted)
    }

    // 4. Perspective keystone correction (vertical & horizontal).
    if abs(params.verticalPerspective) > 0.005 || abs(params.horizontalPerspective) > 0.005 {
      let ext = output.extent
      let w = ext.width
      let h = ext.height
      let vx = CGFloat(params.verticalPerspective) * w * 0.16
      let hy = CGFloat(params.horizontalPerspective) * h * 0.16

      let topLeft = CGPoint(x: max(0, vx), y: h - max(0, -hy))
      let topRight = CGPoint(x: w - max(0, vx), y: h - max(0, hy))
      let bottomLeft = CGPoint(x: max(0, -vx), y: max(0, -hy))
      let bottomRight = CGPoint(x: w - max(0, -vx), y: max(0, hy))

      if let filter = CIFilter(name: "CIPerspectiveTransform") {
        filter.setValue(output, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
        if let warped = filter.outputImage {
          let insetX = abs(vx)
          let insetY = abs(hy)
          let safeRect = CGRect(
            x: insetX,
            y: insetY,
            width: max(2, w - insetX * 2.0),
            height: max(2, h - insetY * 2.0)
          )
          output = reorigin(warped.cropped(to: safeRect))
        }
      }
    }

    // 5. Straighten (-45°…+45°) with inscribed auto-crop so corners stay clean.
    if abs(params.straightenDegrees) > 0.05 {
      let ext = output.extent
      let w = ext.width
      let h = ext.height
      let rad = CGFloat(-params.straightenDegrees * Double.pi / 180.0)
      let absCos = abs(cos(rad))
      let absSin = abs(sin(rad))
      // Largest axis-aligned rectangle of the same aspect inside rotated rect.
      let scaleFactor = max(
        absCos + (h / max(w, 1)) * absSin,
        absCos + (w / max(h, 1)) * absSin
      )
      let cx = w / 2.0
      let cy = h / 2.0
      var transform = CGAffineTransform.identity
      transform = transform.translatedBy(x: cx, y: cy)
      transform = transform.scaledBy(x: scaleFactor, y: scaleFactor)
      transform = transform.rotated(by: rad)
      transform = transform.translatedBy(x: -cx, y: -cy)
      output = reorigin(output.transformed(by: transform).cropped(to: ext))
    }

    // 6. Aspect ratio centre crop.
    if let targetRatio = aspectRatioValue(for: params.cropAspect) {
      let ext = output.extent
      let current = ext.width / max(ext.height, 1)
      let cropW: CGFloat
      let cropH: CGFloat
      if current > targetRatio {
        cropH = ext.height
        cropW = ext.height * targetRatio
      } else {
        cropW = ext.width
        cropH = ext.width / targetRatio
      }
      let rect = CGRect(
        x: ext.midX - cropW / 2.0,
        y: ext.midY - cropH / 2.0,
        width: max(2, cropW.rounded()),
        height: max(2, cropH.rounded())
      )
      output = reorigin(output.cropped(to: rect))
    }

    // 7. Optics vignette correction (lifts dark lens corners cleanly in 16-bit).
    if params.opticsVignette > 0.005 {
      let ext = output.extent
      let corner = hypot(ext.width, ext.height) / 2.0
      let brightened = output.applyingFilter(
        "CIExposureAdjust",
        parameters: ["inputEV": params.opticsVignette * 0.85]
      )
      if let mask = CIFilter(
        name: "CIRadialGradient",
        parameters: [
          "inputCenter": CIVector(x: ext.midX, y: ext.midY),
          "inputRadius0": corner * 0.38,
          "inputRadius1": corner * 1.02,
          "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 1),
          "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        ]
      )?.outputImage?.cropped(to: ext) {
        output = brightened.applyingFilter(
          "CIBlendWithMask",
          parameters: [
            kCIInputBackgroundImageKey: output,
            kCIInputMaskImageKey: mask
          ]
        ).cropped(to: ext)
      }
    }

    return output
  }

  // MARK: Pipeline

  private static func applyCube(_ cubeData: Data, dimension: Int, to image: CIImage) -> CIImage {
    if let filter = CIFilter(name: "CIColorCubeWithColorSpace"),
       let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
      filter.setValue(image, forKey: kCIInputImageKey)
      filter.setValue(dimension, forKey: "inputCubeDimension")
      filter.setValue(cubeData, forKey: "inputCubeData")
      filter.setValue(srgb, forKey: "inputColorSpace")
      if let out = filter.outputImage {
        return out.cropped(to: image.extent)
      }
    }
    return image.applyingFilter(
      "CIColorCube",
      parameters: [
        "inputCubeDimension": dimension,
        "inputCubeData": cubeData
      ]
    ).cropped(to: image.extent)
  }

  /// Colour and detail half of the edit. Used directly by the video
  /// compositor, which then layers the film look and the grain itself.
  static func applyColor(_ params: Params, to image: CIImage) -> CIImage {
    let extent = image.extent
    guard extent.width > 1, extent.height > 1 else { return image }
    let scale = Double(max(extent.width, extent.height)) / 1920.0
    var output = image

    // 0. Multi-Camera Log Input Transform (OpenFilm IDT: Apple Log, S-Log3,
    //    DJI D-Log M, Canon C-Log3, Fuji F-Log2 -> Rec.709 filmic working space).
    if params.inputLogProfile != "rec709",
       let idtCube = logIdtCube(profile: params.inputLogProfile) {
      output = applyCube(idtCube, dimension: 33, to: output)
    }

    // 0b. ASC CDL (Slope / Offset / Power / Saturation — Hollywood standard).
    if !params.isCdlNeutral, let cdl = cdlCube(params) {
      output = applyCube(cdl, dimension: 33, to: output)
    }

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
    if let cube = toneCube(params) {
      output = applyCube(cube, dimension: 33, to: output)
    }

    // 3b. ACES / AgX Filmic Highlight Roll-Off.
    if params.filmicRollOff > 0.005 {
      output = FilmEngine.applyFilmicRollOff(to: output, strength: params.filmicRollOff)
    }

    // 4. Colour Mix (HSL) as a 17³ cube (also drives B&W tonal luminance mix!).
    if let cube = hslCube(params) {
      output = applyCube(cube, dimension: 17, to: output)
    }

    // 4a. Subtractive Film Dye Density & Skin-Tone Vector Protection.
    if !params.blackAndWhite && (abs(params.colorDensity) > 0.005 || params.skinProtection > 0.005),
       let cube = subtractiveSkinCube(density: params.colorDensity, skinProtection: params.skinProtection) {
      output = applyCube(cube, dimension: 17, to: output)
    }

    // 4b. Defringe (purple/magenta & green chromatic aberration suppression).
    if params.defringe > 0.005, let cube = defringeCube(amount: params.defringe) {
      output = applyCube(cube, dimension: 17, to: output)
    }

    // 4c. 3-Way Color Grading (Shadows / Midtones / Highlights wheels).
    if let cube = colorGradingCube(params.colorGrading) {
      output = applyCube(cube, dimension: 33, to: output)
    }

    // 5. Panchromatic Black & White OR Vibrance + Saturation.
    if params.blackAndWhite {
      output = output.applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0),
          "inputGVector": CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0),
          "inputBVector": CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0)
        ]
      )
    } else {
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

    // 7. Detail: chroma-only Color NR, luminance NR, then micro-radius sharpening.
    if params.colorNoiseReduction > 0.005 {
      // Blur chroma only while keeping 100% sharp original luminance via
      // CILuminosityBlendMode — eliminates color speckle with zero oil-painting!
      let chromaBlurred = output.clampedToExtent()
        .applyingGaussianBlur(sigma: (1.0 + params.colorNoiseReduction * 3.0) * scale)
        .cropped(to: extent)
      output = output.applyingFilter(
        "CILuminosityBlendMode",
        parameters: [kCIInputBackgroundImageKey: chromaBlurred]
      ).cropped(to: extent)
    }
    if params.noiseReduction > 0.001 {
      output = output.applyingFilter(
        "CINoiseReduction",
        parameters: [
          "inputNoiseLevel": 0.015 + params.noiseReduction * 0.045,
          "inputSharpness": 0.45
        ]
      )
    }
    if params.sharpen > 0.001 {
      let radius = max(0.45, (0.45 + params.sharpenRadius * 1.45) * scale)
      output = output.applyingFilter(
        "CISharpenLuminance",
        parameters: [
          "inputSharpness": params.sharpen * 0.95,
          "inputRadius": radius
        ]
      )
    }

    return output.cropped(to: extent)
  }

  /// Applies layered selective gradient masks (Linear & Radial) with local
  /// exposure, contrast, highlights, shadows, temperature, saturation, clarity
  /// and sharpness.
  static func applyMasks(_ params: Params, to image: CIImage) -> CIImage {
    let active = params.masks.filter { !$0.isNeutral }
    guard !active.isEmpty else { return image }
    let extent = image.extent
    let w = extent.width
    let h = extent.height
    guard w > 1, h > 1 else { return image }

    var output = image
    for mask in active {
      let sx = extent.minX + CGFloat(mask.startX) * w
      let sy = extent.minY + CGFloat(1.0 - mask.startY) * h
      let ex = extent.minX + CGFloat(mask.endX) * w
      let ey = extent.minY + CGFloat(1.0 - mask.endY) * h

      var matte: CIImage?
      if let mp = mask.maskImagePath,
         !mp.isEmpty,
         FileManager.default.fileExists(atPath: mp),
         var aiImg = CIImage(contentsOf: URL(fileURLWithPath: mp)) {
        if aiImg.extent.origin != .zero {
          aiImg = aiImg.transformed(
            by: CGAffineTransform(translationX: -aiImg.extent.origin.x, y: -aiImg.extent.origin.y)
          )
        }
        let sxScale = w / max(aiImg.extent.width, 1)
        let syScale = h / max(aiImg.extent.height, 1)
        aiImg = aiImg.transformed(by: CGAffineTransform(scaleX: sxScale, y: syScale))
          .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
          .cropped(to: extent)
        if mask.feather > 0.06 {
          let sigma = Double(mask.feather) * 6.0 * (Double(max(w, h)) / 1920.0)
          aiImg = aiImg.clampedToExtent()
            .applyingGaussianBlur(sigma: max(0.5, sigma))
            .cropped(to: extent)
        }
        matte = aiImg
      } else if mask.isLinear {
        let dx = ex - sx
        let dy = ey - sy
        let midX = (sx + ex) * 0.5
        let midY = (sy + ey) * 0.5
        let spread = CGFloat(max(0.08, mask.feather))
        let p0 = CIVector(x: midX - dx * 0.5 * spread, y: midY - dy * 0.5 * spread)
        let p1 = CIVector(x: midX + dx * 0.5 * spread, y: midY + dy * 0.5 * spread)
        matte = CIFilter(
          name: "CILinearGradient",
          parameters: [
            "inputPoint0": p0,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            "inputPoint1": p1,
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1)
          ]
        )?.outputImage?.cropped(to: extent)
      } else {
        let outerR = max(8.0, hypot(ex - sx, ey - sy))
        let innerR = max(0.0, outerR * CGFloat(1.0 - mask.feather))
        matte = CIFilter(
          name: "CIRadialGradient",
          parameters: [
            "inputCenter": CIVector(x: sx, y: sy),
            "inputRadius0": innerR,
            "inputRadius1": outerR,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1)
          ]
        )?.outputImage?.cropped(to: extent)
      }

      guard var maskImage = matte else { continue }
      if mask.inverted {
        maskImage = maskImage.applyingFilter("CIColorInvert").cropped(to: extent)
      }

      var localParams = Params()
      localParams.exposure = mask.exposure
      localParams.contrast = mask.contrast
      localParams.highlights = mask.highlights
      localParams.shadows = mask.shadows
      localParams.temperature = mask.temperature
      localParams.saturation = mask.saturation
      localParams.clarity = mask.clarity
      localParams.sharpen = mask.sharpen

      let adjusted = applyColor(localParams, to: output)
      output = adjusted.applyingFilter(
        "CIBlendWithMask",
        parameters: [
          kCIInputBackgroundImageKey: output,
          kCIInputMaskImageKey: maskImage
        ]
      ).cropped(to: extent)
    }

    return output.cropped(to: extent)
  }

  /// Optical disc-bokeh Lens Blur (Radial spotlight or Linear tilt-shift) with
  /// specular bokeh highlight boost.
  static func applyLensBlur(_ params: Params, to image: CIImage) -> CIImage {
    guard params.blurAmount > 0.005 else { return image }
    let extent = image.extent
    let w = extent.width
    let h = extent.height
    guard w > 1, h > 1 else { return image }

    let scale = Double(max(w, h)) / 1920.0
    let radius = CGFloat(max(1.0, (2.0 + params.blurAmount * 20.0) * scale))

    var sourceForBlur = image
    if params.blurBokehBoost > 0.01 {
      // Gently boost specular highlights before disc convolution to form bright
      // circular bokeh highlights.
      let boost = CGFloat(params.blurBokehBoost * 0.45)
      let hi = image.applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: 1.0 + boost, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: 1.0 + boost, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: 1.0 + boost, w: 0),
          "inputBiasVector": CIVector(x: -boost * 0.72, y: -boost * 0.72, z: -boost * 0.72, w: 0)
        ]
      ).applyingFilter(
        "CIColorClamp",
        parameters: [
          "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputMaxComponents": CIVector(x: 1.4, y: 1.4, z: 1.4, w: 1)
        ]
      )
      sourceForBlur = hi.applyingFilter(
        "CILightenBlendMode",
        parameters: [kCIInputBackgroundImageKey: image]
      ).cropped(to: extent)
    }

    let blurred = sourceForBlur.clampedToExtent()
      .applyingFilter("CIDiscBlur", parameters: [kCIInputRadiusKey: radius])
      .cropped(to: extent)

    let cx = extent.minX + CGFloat(params.blurCenterX) * w
    let cy = extent.minY + CGFloat(1.0 - params.blurCenterY) * h
    let dim = min(w, h)
    let r0 = CGFloat(params.blurRadius) * dim * 0.75
    let r1 = r0 + CGFloat(params.blurFeather) * dim * 0.65

    let blurMask: CIImage?
    if params.blurStyle == "linear" {
      // Horizontal tilt-shift band centred at cy: sharp inside band, blurred outside.
      let topGrad = CIFilter(
        name: "CILinearGradient",
        parameters: [
          "inputPoint0": CIVector(x: cx, y: cy + r0 * 0.55),
          "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 1),
          "inputPoint1": CIVector(x: cx, y: cy + r1 * 0.85),
          "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        ]
      )?.outputImage?.cropped(to: extent)
      let botGrad = CIFilter(
        name: "CILinearGradient",
        parameters: [
          "inputPoint0": CIVector(x: cx, y: cy - r0 * 0.55),
          "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 1),
          "inputPoint1": CIVector(x: cx, y: cy - r1 * 0.85),
          "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        ]
      )?.outputImage?.cropped(to: extent)
      if let t = topGrad, let b = botGrad {
        blurMask = t.applyingFilter(
          "CILightenBlendMode",
          parameters: [kCIInputBackgroundImageKey: b]
        ).cropped(to: extent)
      } else {
        blurMask = topGrad ?? botGrad
      }
    } else {
      blurMask = CIFilter(
        name: "CIRadialGradient",
        parameters: [
          "inputCenter": CIVector(x: cx, y: cy),
          "inputRadius0": r0,
          "inputRadius1": max(r0 + 8.0, r1),
          "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 1),
          "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        ]
      )?.outputImage?.cropped(to: extent)
    }

    guard let mask = blurMask else { return image }
    return blurred.applyingFilter(
      "CIBlendWithMask",
      parameters: [
        kCIInputBackgroundImageKey: image,
        kCIInputMaskImageKey: mask
      ]
    ).cropped(to: extent)
  }

  /// Full Lightroom vignette (amount, midpoint, feather, roundness) + full-res
  /// grain (amount, size, roughness), layered after the film look.
  static func applyFinish(
    _ params: Params,
    to image: CIImage,
    frameIndex: Int = 0
  ) -> CIImage {
    let extent = image.extent
    guard extent.width > 1, extent.height > 1 else { return image }
    var output = image

    if params.grain > 0.001 {
      let size = 0.45 + params.grainSize * 0.95
      let roughBoost = 0.72 + params.grainRoughness * 0.56
      output = FilmLook.addGrain(
        to: output,
        extent: extent,
        amount: min(params.grain * roughBoost, 1.0),
        size: size,
        frameIndex: frameIndex
      )
    }
    if params.vignette > 0.001 {
      output = addCustomVignette(
        to: output,
        extent: extent,
        amount: params.vignette * 0.92,
        midpoint: params.vignetteMidpoint,
        feather: params.vignetteFeather,
        roundness: params.vignetteRoundness
      )
    }
    return output.cropped(to: extent)
  }

  private static func addCustomVignette(
    to base: CIImage,
    extent: CGRect,
    amount: Double,
    midpoint: Double,
    feather: Double,
    roundness: Double
  ) -> CIImage {
    let w = extent.width
    let h = extent.height
    let corner = Double(hypot(w, h)) / 2.0
    let mid = corner * (0.20 + midpoint * 0.65)
    let spread = corner * (0.08 + feather * 0.75)
    let r0 = CGFloat(max(1.0, mid - spread * 0.5))
    let r1 = CGFloat(max(Double(r0) + 4.0, mid + spread * 0.65))
    let edge = CGFloat(max(0.0, 1.0 - amount))
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)

    func color(_ v: CGFloat) -> CIColor {
      if let srgb = srgb,
         let c = CIColor(red: v, green: v, blue: v, alpha: 1, colorSpace: srgb) {
        return c
      }
      return CIColor(red: v, green: v, blue: v, alpha: 1)
    }

    guard var gradient = CIFilter(
      name: "CIRadialGradient",
      parameters: [
        "inputCenter": CIVector(x: 0, y: 0),
        "inputRadius0": r0,
        "inputRadius1": r1,
        "inputColor0": color(1.0),
        "inputColor1": color(edge)
      ]
    )?.outputImage else {
      return base
    }

    // Roundness stretches the circular gradient toward image aspect (or rounder).
    let aspect = Double(w / max(h, 1.0))
    let stretchX = CGFloat(1.0 + (-roundness) * max(0.0, aspect - 1.0) * 0.35)
    let stretchY = CGFloat(1.0 + (-roundness) * max(0.0, (1.0 / max(aspect, 0.1)) - 1.0) * 0.35)
    let transform = CGAffineTransform(translationX: extent.midX, y: extent.midY)
      .scaledBy(x: max(0.55, stretchX), y: max(0.55, stretchY))
    gradient = gradient.transformed(by: transform).cropped(to: extent)

    return gradient.applyingFilter(
      "CIMultiplyBlendMode",
      parameters: [kCIInputBackgroundImageKey: base]
    ).cropped(to: extent)
  }

  /// Full still pipeline: geometry/optics -> color/detail -> selective masks ->
  /// film look -> lens blur -> full vignette/grain.
  static func render(
    _ params: Params,
    look: FilmLook?,
    matrix: [Double]?,
    source: CIImage,
    sourcePath: String? = nil,
    frameIndex: Int = 0
  ) -> CIImage {
    var output = applyGeometryAndOptics(params, to: source)
    let workingExtent = output.extent
    output = applyColor(params, to: output)
    output = applyMasks(params, to: output)

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

    output = applyLensBlur(params, to: output)
    output = applyFinish(params, to: output, frameIndex: frameIndex)
    var cropped = output.cropped(to: workingExtent)
    if params.frameStyle != "none" || params.frameDateStamp {
      cropped = applyFrameBorder(params, to: cropped, sourcePath: sourcePath)
    }
    return cropped
  }

  // MARK: v2.3.0 Subtractive Color, Skin Protection, Film Borders & .cube Export

  private static var subtractiveSkinCache: [String: Data] = [:]

  /// Beer-Lambert subtractive film saturation (saturated colors deepen rather
  /// than glowing neon) + automatic human skin-hue protection (12°–48°).
  private static func subtractiveSkinCube(
    density: Double,
    skinProtection: Double
  ) -> Data? {
    let key = String(format: "%.2f|%.2f", density, skinProtection)
    gradingLock.lock()
    let cached = subtractiveSkinCache[key]
    gradingLock.unlock()
    if let cached = cached { return cached }

    let n = 17
    let last = Double(n - 1)
    var values = [Float](repeating: 0, count: n * n * n * 4)

    for bi in 0..<n {
      for gi in 0..<n {
        for ri in 0..<n {
          let r = Double(ri) / last
          let g = Double(gi) / last
          let b = Double(bi) / last
          var (hue, sat, lum) = rgbToHsl(r, g, b)

          // Skin-tone vector protection around ~26° warm skin axis.
          var skinWeight = 0.0
          if skinProtection > 0.005 {
            let dHue = min(abs(hue - 26.0), 360.0 - abs(hue - 26.0))
            let wH = exp(-(dHue * dHue) / (2.0 * 17.0 * 17.0))
            let wS = smoothstep(0.08, 0.22, sat) * (1.0 - smoothstep(0.62, 0.85, sat))
            let wL = smoothstep(0.12, 0.28, lum) * (1.0 - smoothstep(0.84, 0.96, lum))
            skinWeight = wH * wS * wL * skinProtection
            if skinWeight > 0.001 {
              // Gently pull skewed cyan/green/magenta casts on skin back toward 26°.
              var delta = 26.0 - hue
              if delta > 180 { delta -= 360 }
              if delta < -180 { delta += 360 }
              hue = (hue + delta * skinWeight * 0.45).truncatingRemainder(dividingBy: 360.0)
              if hue < 0 { hue += 360.0 }
              if sat > 0.48 {
                sat = sat - (sat - 0.48) * skinWeight * 0.55
              }
            }
          }

          // Subtractive film dye density: saturated colors absorb light & deepen!
          if abs(density) > 0.005 {
            let effectiveDensity = density * (1.0 - skinWeight * 0.65)
            sat = min(max(sat * (1.0 + effectiveDensity * 0.34), 0.0), 1.0)
            let absorb = sat * effectiveDensity * 0.24 * smoothstep(0.08, 0.45, lum)
            lum = min(max(lum * (1.0 - absorb), 0.0), 1.0)
          }

          let (nr, ng, nb) = hslToRgb(hue, sat, lum)
          let offset = ((bi * n + gi) * n + ri) * 4
          values[offset] = Float(min(max(nr, 0), 1))
          values[offset + 1] = Float(min(max(ng, 0), 1))
          values[offset + 2] = Float(min(max(nb, 0), 1))
          values[offset + 3] = 1
        }
      }
    }

    let data = values.withUnsafeBytes { Data($0) }
    gradingLock.lock()
    if subtractiveSkinCache.count > 16 { subtractiveSkinCache.removeAll() }
    subtractiveSkinCache[key] = data
    gradingLock.unlock()
    return data
  }

  /// Renders Leica Gallery White, Dark Matte, 35mm Film Sprocket, or Polaroid
  /// frames plus optional EXIF lens/exposure line and vintage `'YY MM DD` stamp.
  static func applyFrameBorder(
    _ params: Params,
    to image: CIImage,
    sourcePath: String?
  ) -> CIImage {
    let clean = reorigin(image)
    let ext = clean.extent
    guard ext.width > 8, ext.height > 8,
          let srgb = CGColorSpace(name: CGColorSpace.sRGB),
          let cgImg = AppDelegate.gradingContext.createCGImage(
            clean,
            from: ext,
            format: .RGBA8,
            colorSpace: srgb
          ) else {
      return image
    }

    let imgW = ext.width
    let imgH = ext.height
    let shortSide = min(imgW, imgH)

    // Read EXIF & date from original file if available.
    var exifParts: [String] = []
    var dateStampText = ""
    let fallbackDate: Date = {
      if let p = sourcePath,
         let attrs = try? FileManager.default.attributesOfItem(atPath: p),
         let d = attrs[.creationDate] as? Date {
        return d
      }
      return Date()
    }()

    if let p = sourcePath,
       let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
       let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
       let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
      if let fl35 = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.intValue {
        exifParts.append("\(fl35)mm")
      } else if let fl = (exif[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue {
        exifParts.append(String(format: "%.0fmm", fl))
      }
      if let fn = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue {
        exifParts.append(String(format: "f/%.1f", fn))
      }
      if let exp = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue, exp > 0 {
        if exp < 1.0 {
          exifParts.append("1/\(max(1, Int((1.0 / exp).rounded())))s")
        } else {
          exifParts.append(String(format: "%.1fs", exp))
        }
      }
      if let isos = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber], let iso = isos.first {
        exifParts.append("ISO \(iso.intValue)")
      }
      if let dt = exif[kCGImagePropertyExifDateTimeOriginal] as? String, dt.count >= 10 {
        // "YYYY:MM:DD HH:mm:ss" -> "'YY MM DD"
        let yy = String(dt.dropFirst(2).prefix(2))
        let mm = String(dt.dropFirst(5).prefix(2))
        let dd = String(dt.dropFirst(8).prefix(2))
        dateStampText = "'\(yy) \(mm) \(dd)"
      }
    }
    if dateStampText.isEmpty {
      let fmt = DateFormatter()
      fmt.dateFormat = "''yy MM dd"
      dateStampText = fmt.string(from: fallbackDate)
    }
    if !params.frameCustomText.isEmpty {
      exifParts.append(params.frameCustomText.uppercased())
    }
    let captionLine = exifParts.isEmpty ? "CINELENS PRO" : exifParts.joined(separator: "  ·  ")

    let style = params.frameStyle
    let padSide: CGFloat
    let padTop: CGFloat
    let padBottom: CGFloat
    let bgColor: UIColor
    let primaryTextColor: UIColor
    let accentDotColor = UIColor(red: 0.90, green: 0.22, blue: 0.18, alpha: 1.0)

    switch style {
    case "leica_white":
      padSide = round(shortSide * 0.055)
      padTop = padSide
      padBottom = round(shortSide * (params.frameExifCaption ? 0.145 : 0.075))
      bgColor = UIColor(white: 0.985, alpha: 1.0)
      primaryTextColor = UIColor(white: 0.16, alpha: 1.0)
    case "dark_matte":
      padSide = round(shortSide * 0.055)
      padTop = padSide
      padBottom = round(shortSide * (params.frameExifCaption ? 0.145 : 0.075))
      bgColor = UIColor(red: 0.045, green: 0.045, blue: 0.055, alpha: 1.0)
      primaryTextColor = UIColor(white: 0.88, alpha: 1.0)
    case "film_35mm":
      padSide = round(shortSide * 0.075)
      padTop = round(shortSide * 0.065)
      padBottom = round(shortSide * 0.085)
      bgColor = UIColor(white: 0.03, alpha: 1.0)
      primaryTextColor = UIColor(red: 0.90, green: 0.66, blue: 0.23, alpha: 0.92)
    case "polaroid":
      padSide = round(shortSide * 0.065)
      padTop = round(shortSide * 0.065)
      padBottom = round(shortSide * 0.22)
      bgColor = UIColor(red: 0.975, green: 0.968, blue: 0.945, alpha: 1.0)
      primaryTextColor = UIColor(white: 0.22, alpha: 1.0)
    default:
      padSide = 0
      padTop = 0
      padBottom = 0
      bgColor = .black
      primaryTextColor = .white
    }

    let totalW = imgW + padSide * 2
    let totalH = imgH + padTop + padBottom
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1.0
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: totalW, height: totalH), format: format)

    let rendered = renderer.image { ctx in
      bgColor.setFill()
      ctx.fill(CGRect(x: 0, y: 0, width: totalW, height: totalH))

      let photoRect = CGRect(x: padSide, y: padTop, width: imgW, height: imgH)
      UIImage(cgImage: cgImg).draw(in: photoRect)

      // 35mm film sprocket holes along left & right borders
      if style == "film_35mm" {
        let holeW = max(4.0, padSide * 0.34)
        let holeH = holeW * 1.42
        let step = holeH * 2.15
        UIColor(white: 0.92, alpha: 1.0).setFill()
        var y = padTop
        while y + holeH < totalH - padBottom * 0.5 {
          let leftHole = UIBezierPath(
            roundedRect: CGRect(x: (padSide - holeW) * 0.5, y: y, width: holeW, height: holeH),
            cornerRadius: holeW * 0.22
          )
          let rightHole = UIBezierPath(
            roundedRect: CGRect(x: totalW - (padSide + holeW) * 0.5, y: y, width: holeW, height: holeH),
            cornerRadius: holeW * 0.22
          )
          leftHole.fill()
          rightHole.fill()
          y += step
        }
      }

      // Vintage quartz date stamp ('YY MM DD) in bottom-right corner of photo
      if params.frameDateStamp {
        let fontSize = max(11.0, shortSide * 0.028)
        let font = UIFont(name: "Menlo-Bold", size: fontSize) ?? UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
        let shadow = NSShadow()
        shadow.shadowColor = UIColor(red: 1.0, green: 0.32, blue: 0.05, alpha: 0.65)
        shadow.shadowBlurRadius = fontSize * 0.35
        let attrs: [NSAttributedString.Key: Any] = [
          .font: font,
          .foregroundColor: UIColor(red: 1.0, green: 0.58, blue: 0.16, alpha: 0.92),
          .shadow: shadow
        ]
        let ns = dateStampText as NSString
        let sz = ns.size(withAttributes: attrs)
        let dx = photoRect.maxX - sz.width - shortSide * 0.038
        let dy = photoRect.maxY - sz.height - shortSide * 0.032
        ns.draw(at: CGPoint(x: dx, y: dy), withAttributes: attrs)
      }

      // Editorial EXIF caption bar below photo
      if style != "none" && (params.frameExifCaption || style == "film_35mm") {
        let fontSize = max(10.0, shortSide * 0.020)
        let font = UIFont(name: "Menlo-Bold", size: fontSize) ?? UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
          .font: font,
          .foregroundColor: primaryTextColor,
          .kern: 1.2
        ]
        let ns = captionLine as NSString
        let sz = ns.size(withAttributes: attrs)
        let cy = photoRect.maxY + (padBottom - sz.height) * 0.52
        if style == "leica_white" || style == "dark_matte" {
          let dotR = fontSize * 0.32
          accentDotColor.setFill()
          UIBezierPath(
            ovalIn: CGRect(
              x: (totalW - sz.width) * 0.5 - dotR * 3.6,
              y: cy + (sz.height - dotR * 2) * 0.5,
              width: dotR * 2,
              height: dotR * 2
            )
          ).fill()
        }
        ns.draw(at: CGPoint(x: (totalW - sz.width) * 0.5, y: cy), withAttributes: attrs)
      }
    }

    guard let outCG = rendered.cgImage else { return clean }
    return CIImage(cgImage: outCG)
  }

  /// Bakes the active colour-only grade into an industry-standard 33³ `.cube` file.
  static func exportCubeFile(
    params: Params,
    look: FilmLook?,
    matrix: [Double]?,
    title: String
  ) -> String? {
    let n = 33
    let width = n
    let height = n * n // 1089
    let last = Double(n - 1)
    guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

    var inFloats = [Float](repeating: 1.0, count: width * height * 4)
    for bi in 0..<n {
      for gi in 0..<n {
        let row = bi * n + gi
        for ri in 0..<n {
          let idx = (row * width + ri) * 4
          inFloats[idx] = Float(Double(ri) / last)
          inFloats[idx + 1] = Float(Double(gi) / last)
          inFloats[idx + 2] = Float(Double(bi) / last)
          inFloats[idx + 3] = 1.0
        }
      }
    }

    let rawData = inFloats.withUnsafeBufferPointer { Data(buffer: $0) }
    let latticeExtent = CGRect(x: 0, y: 0, width: width, height: height)
    var ci = CIImage(
      bitmapData: rawData,
      bytesPerRow: width * 16,
      size: CGSize(width: width, height: height),
      format: .RGBAf,
      colorSpace: srgb
    )

    // Strip spatial-only filters so the 3D LUT lattice has zero neighbour bleed!
    var colorOnly = params
    colorOnly.clarity = 0
    colorOnly.texture = 0
    colorOnly.sharpen = 0
    colorOnly.noiseReduction = 0
    colorOnly.colorNoiseReduction = 0
    ci = applyColor(colorOnly, to: ci)

    if let look = look {
      if look.usesCube, let cube = CIFilter(name: "CIColorCubeWithColorSpace") {
        cube.setValue(ci, forKey: kCIInputImageKey)
        cube.setValue(look.cubeSize, forKey: "inputCubeDimension")
        cube.setValue(look.cubeData, forKey: "inputCubeData")
        cube.setValue(srgb, forKey: "inputColorSpace")
        if let out = cube.outputImage {
          ci = out.cropped(to: latticeExtent)
        }
      }
      if look.shadowDepth > 0.005 {
        ci = FilmEngine.applyShadowDepth(to: ci, strength: look.shadowDepth).cropped(to: latticeExtent)
      }
      if look.filmicRollOff > 0.005 {
        ci = FilmEngine.applyFilmicRollOff(to: ci, strength: look.filmicRollOff).cropped(to: latticeExtent)
      }
    } else if let matrix = matrix, matrix.count == 20 {
      ci = AppDelegate.colorMatrixImage(matrix, to: ci)
    }

    var outFloats = [Float](repeating: 0, count: width * height * 4)
    AppDelegate.gradingContext.render(
      ci,
      toBitmap: &outFloats,
      rowBytes: width * 16,
      bounds: latticeExtent,
      format: .RGBAf,
      colorSpace: srgb
    )

    let safeTitle = title
      .replacingOccurrences(of: "\"", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    var lines: [String] = []
    lines.reserveCapacity(n * n * n + 6)
    lines.append("# Generated by CineLens Pro")
    lines.append("TITLE \"\(safeTitle.isEmpty ? "CineLens_Grade" : safeTitle)\"")
    lines.append("LUT_3D_SIZE 33")
    lines.append("DOMAIN_MIN 0.0 0.0 0.0")
    lines.append("DOMAIN_MAX 1.0 1.0 1.0")

    for bi in 0..<n {
      for gi in 0..<n {
        let row = bi * n + gi
        for ri in 0..<n {
          let idx = (row * width + ri) * 4
          let r = min(max(outFloats[idx], 0.0), 1.0)
          let g = min(max(outFloats[idx + 1], 0.0), 1.0)
          let b = min(max(outFloats[idx + 2], 0.0), 1.0)
          lines.append(String(format: "%.6f %.6f %.6f", r, g, b))
        }
      }
    }

    let fileSlug = (safeTitle.isEmpty ? "CineLens_Grade" : safeTitle)
      .replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
    let outURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(fileSlug).cube")
    do {
      try lines.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
      return outURL.path
    } catch {
      return nil
    }
  }

  // MARK: 3-Way Color Grading & Defringe Cubes

  private static let gradingLock = NSLock()
  private static var gradingCache: [String: Data] = [:]

  private static func colorGradingCube(_ grading: ColorGradingParams) -> Data? {
    guard !grading.isNeutral else { return nil }

    let key = String(
      format: "%.1f,%.3f,%.3f|%.1f,%.3f,%.3f|%.1f,%.3f,%.3f|%.2f,%.2f",
      grading.shadows.hue, grading.shadows.saturation, grading.shadows.luminance,
      grading.midtones.hue, grading.midtones.saturation, grading.midtones.luminance,
      grading.highlights.hue, grading.highlights.saturation, grading.highlights.luminance,
      grading.blending, grading.balance
    )

    gradingLock.lock()
    let cached = gradingCache[key]
    gradingLock.unlock()
    if let cached = cached { return cached }

    func wheelTint(_ wheel: ColorWheelParams) -> (Double, Double, Double) {
      guard wheel.saturation > 0.001 else { return (0, 0, 0) }
      let (tr, tg, tb) = hslToRgb(wheel.hue, 1.0, 0.5)
      // Zero-sum chroma shift so tint adds colour cast without unwanted exposure jump.
      let avg = (tr + tg + tb) / 3.0
      let strength = wheel.saturation * 0.28
      return ((tr - avg) * strength, (tg - avg) * strength, (tb - avg) * strength)
    }

    let shTint = wheelTint(grading.shadows)
    let miTint = wheelTint(grading.midtones)
    let hiTint = wheelTint(grading.highlights)

    // Balance shifts shadow/highlight crossover; blending widens overlap.
    let pivot = 0.5 - grading.balance * 0.25
    let spread = 0.18 + grading.blending * 0.34

    let dimension = 33
    let last = Double(dimension - 1)
    var values = [Float](repeating: 0, count: dimension * dimension * dimension * 4)

    for bi in 0..<dimension {
      for gi in 0..<dimension {
        for ri in 0..<dimension {
          let r = Double(ri) / last
          let g = Double(gi) / last
          let b = Double(bi) / last
          let y = 0.2126 * r + 0.7152 * g + 0.0722 * b

          let wShadow = 1.0 - smoothstep(max(0.0, pivot - spread), min(1.0, pivot + spread * 0.5), y)
          let wHighlight = smoothstep(max(0.0, pivot - spread * 0.5), min(1.0, pivot + spread), y)
          let wMid = max(0.0, 1.0 - abs(y - pivot) / max(0.22, spread * 1.45))

          // Taper tint gently at pure black (0) & pure white (1) to preserve clean endpoints.
          let endGuard = smoothstep(0.0, 0.08, y) * (1.0 - smoothstep(0.92, 1.0, y))
          let lumShift = (wShadow * grading.shadows.luminance
            + wMid * grading.midtones.luminance
            + wHighlight * grading.highlights.luminance) * 0.14

          let dr = (wShadow * shTint.0 + wMid * miTint.0 + wHighlight * hiTint.0) * endGuard + lumShift
          let dg = (wShadow * shTint.1 + wMid * miTint.1 + wHighlight * hiTint.1) * endGuard + lumShift
          let db = (wShadow * shTint.2 + wMid * miTint.2 + wHighlight * hiTint.2) * endGuard + lumShift

          let offset = ((bi * dimension + gi) * dimension + ri) * 4
          values[offset] = Float(min(max(r + dr, 0), 1))
          values[offset + 1] = Float(min(max(g + dg, 0), 1))
          values[offset + 2] = Float(min(max(b + db, 0), 1))
          values[offset + 3] = 1
        }
      }
    }

    let data = values.withUnsafeBytes { Data($0) }
    gradingLock.lock()
    if gradingCache.count > 24 { gradingCache.removeAll() }
    gradingCache[key] = data
    gradingLock.unlock()
    return data
  }

  private static var defringeCache: [Int: Data] = [:]

  /// Suppresses purple/magenta and acid-green longitudinal chromatic aberration
  /// fringes without desaturating natural skin or foliage tones.
  private static func defringeCube(amount: Double) -> Data? {
    let bucket = Int((min(max(amount, 0), 1) * 20.0).rounded())
    guard bucket > 0 else { return nil }

    gradingLock.lock()
    let cached = defringeCache[bucket]
    gradingLock.unlock()
    if let cached = cached { return cached }

    let s = Double(bucket) / 20.0
    let dimension = 17
    let last = Double(dimension - 1)
    var values = [Float](repeating: 0, count: dimension * dimension * dimension * 4)

    for bi in 0..<dimension {
      for gi in 0..<dimension {
        for ri in 0..<dimension {
          let r = Double(ri) / last
          let g = Double(gi) / last
          let b = Double(bi) / last
          let (hue, rawSat, lum) = rgbToHsl(r, g, b)
          // Target narrow purple/magenta (285°-325°) high-saturation fringe band.
          let dPurple = min(abs(hue - 305.0), 360.0 - abs(hue - 305.0))
          let wPurple = exp(-(dPurple * dPurple) / (2.0 * 18.0 * 18.0))
          let highSat = smoothstep(0.35, 0.80, rawSat)
          let reduction = wPurple * highSat * s * 0.85
          let sat = max(0.0, rawSat * (1.0 - reduction))
          let (nr, ng, nb) = hslToRgb(hue, sat, lum)
          let offset = ((bi * dimension + gi) * dimension + ri) * 4
          values[offset] = Float(nr)
          values[offset + 1] = Float(ng)
          values[offset + 2] = Float(nb)
          values[offset + 3] = 1
        }
      }
    }

    let data = values.withUnsafeBytes { Data($0) }
    gradingLock.lock()
    defringeCache[bucket] = data
    gradingLock.unlock()
    return data
  }

  // MARK: Histogram & 1-Tap Auto Tone

  private static func samplePixels128(from image: CIImage) -> [UInt8]? {
    let ext = image.extent
    guard ext.width > 1, ext.height > 1 else { return nil }
    let side = 128
    let sx = CGFloat(side) / ext.width
    let sy = CGFloat(side) / ext.height
    let scaled = reorigin(image).transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    AppDelegate.gradingContext.render(
      scaled,
      toBitmap: &pixels,
      rowBytes: side * 4,
      bounds: CGRect(x: 0, y: 0, width: side, height: side),
      format: .RGBA8,
      colorSpace: srgb
    )
    return pixels
  }

  static func computeHistogram(for image: CIImage) -> [String: [Double]] {
    guard let pixels = samplePixels128(from: image) else { return [:] }
    let bins = 64
    var rBins = [Double](repeating: 0, count: bins)
    var gBins = [Double](repeating: 0, count: bins)
    var bBins = [Double](repeating: 0, count: bins)
    var lBins = [Double](repeating: 0, count: bins)

    let count = pixels.count / 4
    for i in 0..<count {
      let base = i * 4
      let r = Int(pixels[base])
      let g = Int(pixels[base + 1])
      let b = Int(pixels[base + 2])
      let l = (r * 54 + g * 183 + b * 19) >> 8
      rBins[min(r >> 2, bins - 1)] += 1
      gBins[min(g >> 2, bins - 1)] += 1
      bBins[min(b >> 2, bins - 1)] += 1
      lBins[min(l >> 2, bins - 1)] += 1
    }

    // Normalize against 98th-percentile peak so a single pure-black border doesn't
    // squash the whole curve flat.
    func normalize(_ arr: [Double]) -> [Double] {
      let sorted = arr.sorted()
      let peak = max(sorted[Int(Double(bins - 1) * 0.94)], 1.0)
      return arr.map { min($0 / peak, 1.0) }
    }

    return [
      "r": normalize(rBins),
      "g": normalize(gBins),
      "b": normalize(bBins),
      "luma": normalize(lBins)
    ]
  }

  /// Computes balanced Lightroom-style Auto Tone settings directly from pixel
  /// luma percentiles and grey-world channel averages.
  static func computeAutoTone(for image: CIImage) -> [String: Double] {
    guard let pixels = samplePixels128(from: image) else { return [:] }
    let count = pixels.count / 4
    guard count > 0 else { return [:] }

    var lumHist = [Int](repeating: 0, count: 256)
    var sumR = 0.0
    var sumG = 0.0
    var sumB = 0.0
    var sumSat = 0.0

    for i in 0..<count {
      let base = i * 4
      let r = Double(pixels[base]) / 255.0
      let g = Double(pixels[base + 1]) / 255.0
      let b = Double(pixels[base + 2]) / 255.0
      let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
      lumHist[min(max(Int((y * 255.0).rounded()), 0), 255)] += 1
      sumR += r
      sumG += g
      sumB += b
      let mx = max(r, max(g, b))
      let mn = min(r, min(g, b))
      sumSat += mx > 0.01 ? (mx - mn) / mx : 0.0
    }

    func percentile(_ p: Double) -> Double {
      let target = Int(Double(count) * p)
      var acc = 0
      for bin in 0..<256 {
        acc += lumHist[bin]
        if acc >= target { return Double(bin) / 255.0 }
      }
      return 1.0
    }

    let p02 = percentile(0.02)
    let p15 = percentile(0.15)
    let p50 = percentile(0.50)
    let p85 = percentile(0.85)
    let p98 = percentile(0.98)

    // Exposure targets balanced midtone (~0.46) gently without blowing highlights.
    var exposure = (0.46 - p50) * 1.45
    if p98 > 0.94 && exposure > 0 { exposure *= 0.4 }
    exposure = min(max(exposure, -0.75), 0.85)

    // Highlights & shadows recover clipped extremes & open crushed darks gently.
    let highlights = p98 > 0.90 ? -min((p98 - 0.86) * 2.2, 0.45) : (p85 < 0.65 ? 0.14 : 0.0)
    let shadows = p15 < 0.18 ? min((0.20 - p15) * 1.8, 0.35) : (p15 > 0.32 ? -0.14 : 0.0)

    // Whites & blacks expand dynamic range cleanly to endpoints.
    let whites = p98 < 0.88 ? min((0.92 - p98) * 1.6, 0.32) : -0.06
    let blacks = p02 > 0.07 ? -min((p02 - 0.04) * 2.2, 0.30) : (p02 < 0.015 ? 0.08 : 0.0)

    // Contrast adds crisp punch when tonal spread is narrow.
    let spread = p98 - p02
    let contrast = spread < 0.72 ? min((0.78 - spread) * 0.65, 0.24) : 0.06

    // Gentle grey-world white balance correction (clamped to avoid killing golden hour).
    let avgR = sumR / Double(count)
    let avgG = sumG / Double(count)
    let avgB = sumB / Double(count)
    let temperature = min(max((avgB - avgR) * 0.55, -0.18), 0.18)
    let tint = min(max((avgG - (avgR + avgB) * 0.5) * 0.45, -0.12), 0.12)

    // Mild vibrance boost for flat shots.
    let avgSat = sumSat / Double(count)
    let vibrance = avgSat < 0.32 ? min((0.36 - avgSat) * 0.95, 0.24) : 0.08

    return [
      "exposure": (exposure * 20).rounded() / 20,
      "contrast": (contrast * 100).rounded() / 100,
      "highlights": (highlights * 100).rounded() / 100,
      "shadows": (shadows * 100).rounded() / 100,
      "whites": (whites * 100).rounded() / 100,
      "blacks": (blacks * 100).rounded() / 100,
      "temperature": (temperature * 100).rounded() / 100,
      "tint": (tint * 100).rounded() / 100,
      "vibrance": (vibrance * 100).rounded() / 100
    ]
  }

  // MARK: OpenFilm Color Science (Multi-Log IDT, ASC CDL, Scopes, Color Match, -14 LUFS)

  private static var logIdtCache: [String: Data] = [:]
  private static var cdlCache: [String: Data] = [:]

  private static func linToSrgb(_ l: Double) -> Double {
    let v = max(l, 0.0)
    return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055
  }

  private static func decodeLogChannel(_ x: Double, profile: String) -> Double {
    let lin: Double
    switch profile {
    case "apple_log":
      let r0 = -0.05641088
      let c = 47.28711236
      let beta = 0.00964052
      let gamma = 0.08550479
      let delta = 0.69336945
      let pt = c * pow(0.01 - r0, 2.0)
      if x < 0.0 { lin = r0 }
      else if x < pt { lin = sqrt(x / c) + r0 }
      else { lin = pow(2.0, (x - delta) / gamma) - beta }
    case "sony_slog3":
      let code = x * 1023.0
      if code >= 171.2102946929 {
        lin = pow(10.0, (code - 420.0) / 261.5) * (0.18 + 0.01) - 0.01
      } else {
        lin = (code - 95.0) * 0.01125 / (171.2102946929 - 95.0)
      }
    case "dji_dlogm":
      // DJI D-Log M smooth logarithmic transfer (middle grey ~0.39).
      lin = max(0.0, (pow(10.0, (x - 0.39) / 0.275) - 0.018) * 0.18)
    case "canon_clog3":
      if x >= 0.12512219 {
        lin = (pow(10.0, (x - 0.12783901) / 0.36726845) - 1.0) / 14.98325
      } else {
        lin = 0.0
      }
    case "fuji_flog2":
      let cut = 0.1005377752
      if x >= cut {
        lin = (pow(10.0, (x - 0.384316) / 0.245281) - 0.064829) / 5.555556
      } else {
        lin = max(0.0, (x - 0.092864) / 8.799461)
      }
    default:
      return min(max(x, 0.0), 1.0)
    }
    // Filmic ACEScct-inspired shoulder roll-off into display Rec.709/sRGB.
    let exposed = max(0.0, lin * 2.15)
    let mapped = exposed / (1.0 + exposed * 0.72) * 1.18
    return min(max(linToSrgb(mapped), 0.0), 1.0)
  }

  private static func logIdtCube(profile: String) -> Data? {
    guard profile != "rec709" else { return nil }
    gradingLock.lock()
    let cached = logIdtCache[profile]
    gradingLock.unlock()
    if let cached = cached { return cached }

    let n = 33
    let last = Double(n - 1)
    var values = [Float]()
    values.reserveCapacity(n * n * n * 4)
    for bi in 0..<n {
      let db = decodeLogChannel(Double(bi) / last, profile: profile)
      for gi in 0..<n {
        let dg = decodeLogChannel(Double(gi) / last, profile: profile)
        for ri in 0..<n {
          let dr = decodeLogChannel(Double(ri) / last, profile: profile)
          // Gentle saturation restore for flat camera log gamuts.
          let y = 0.2126 * dr + 0.7152 * dg + 0.0722 * db
          let satBoost = 1.14
          values.append(Float(min(max(y + (dr - y) * satBoost, 0.0), 1.0)))
          values.append(Float(min(max(y + (dg - y) * satBoost, 0.0), 1.0)))
          values.append(Float(min(max(y + (db - y) * satBoost, 0.0), 1.0)))
          values.append(1.0)
        }
      }
    }
    let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
    gradingLock.lock()
    logIdtCache[profile] = data
    gradingLock.unlock()
    return data
  }

  /// ASC CDL 33³ cube: `out = pow(max(0, in * slope + offset), power)` + sat.
  private static func cdlCube(_ params: Params) -> Data? {
    let key = String(
      format: "%.3f,%.3f,%.3f|%.3f,%.3f,%.3f|%.3f,%.3f,%.3f|%.3f",
      params.cdlSlope[0], params.cdlSlope[1], params.cdlSlope[2],
      params.cdlOffset[0], params.cdlOffset[1], params.cdlOffset[2],
      params.cdlPower[0], params.cdlPower[1], params.cdlPower[2],
      params.cdlSaturation
    )
    gradingLock.lock()
    let cached = cdlCache[key]
    gradingLock.unlock()
    if let cached = cached { return cached }

    let s = params.cdlSlope
    let o = params.cdlOffset
    let p = params.cdlPower
    let sat = params.cdlSaturation

    let n = 33
    let last = Double(n - 1)
    var values = [Float]()
    values.reserveCapacity(n * n * n * 4)
    for bi in 0..<n {
      let b0 = pow(max(0.0, (Double(bi) / last) * s[2] + o[2]), p[2])
      for gi in 0..<n {
        let g0 = pow(max(0.0, (Double(gi) / last) * s[1] + o[1]), p[1])
        for ri in 0..<n {
          let r0 = pow(max(0.0, (Double(ri) / last) * s[0] + o[0]), p[0])
          let y = 0.2126 * r0 + 0.7152 * g0 + 0.0722 * b0
          values.append(Float(min(max(y + (r0 - y) * sat, 0.0), 1.0)))
          values.append(Float(min(max(y + (g0 - y) * sat, 0.0), 1.0)))
          values.append(Float(min(max(y + (b0 - y) * sat, 0.0), 1.0)))
          values.append(1.0)
        }
      }
    }
    let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
    gradingLock.lock()
    if cdlCache.count > 24 { cdlCache.removeAll() }
    cdlCache[key] = data
    gradingLock.unlock()
    return data
  }

  /// Computes complete Pro Cinema Scopes in one fast 128×128 pass:
  /// - 64-bin RGB + Luma Histogram
  /// - 48×16 Luma Waveform (0–100 IRE per horizontal slice)
  /// - Subsampled Vectorscope (Cb, Cr points in -0.5…+0.5)
  /// - Clipped (> 97 IRE) & Crushed (< 3 IRE) percentages
  static func computeScopes(for image: CIImage) -> [String: Any] {
    guard let pixels = samplePixels128(from: image) else { return [:] }
    let side = 128
    let bins = 64
    var rBins = [Double](repeating: 0, count: bins)
    var gBins = [Double](repeating: 0, count: bins)
    var bBins = [Double](repeating: 0, count: bins)
    var lBins = [Double](repeating: 0, count: bins)

    let wfCols = 48
    let wfRows = 16
    var wf = [Double](repeating: 0, count: wfCols * wfRows)
    var vectorPoints: [[Double]] = []
    vectorPoints.reserveCapacity(1024)

    var clipped = 0
    var crushed = 0
    let total = side * side

    for row in 0..<side {
      for col in 0..<side {
        let base = (row * side + col) * 4
        let ri = Int(pixels[base])
        let gi = Int(pixels[base + 1])
        let bi = Int(pixels[base + 2])
        let li = (ri * 54 + gi * 183 + bi * 19) >> 8

        rBins[min(ri >> 2, bins - 1)] += 1
        gBins[min(gi >> 2, bins - 1)] += 1
        bBins[min(bi >> 2, bins - 1)] += 1
        lBins[min(li >> 2, bins - 1)] += 1

        if li >= 248 { clipped += 1 }
        if li <= 7 { crushed += 1 }

        let wCol = min((col * wfCols) / side, wfCols - 1)
        let wRow = min((li * wfRows) / 256, wfRows - 1)
        wf[wRow * wfCols + wCol] += 1

        // Every 4th pixel in both axes -> 32×32 = 1024 clean vectorscope dots.
        if (row & 3) == 0 && (col & 3) == 0 {
          let r = Double(ri) / 255.0
          let g = Double(gi) / 255.0
          let b = Double(bi) / 255.0
          let cb = -0.1146 * r - 0.3854 * g + 0.5000 * b
          let cr =  0.5000 * r - 0.4542 * g - 0.0458 * b
          vectorPoints.append([
            (cb * 1000.0).rounded() / 1000.0,
            (cr * 1000.0).rounded() / 1000.0
          ])
        }
      }
    }

    func normHist(_ arr: [Double]) -> [Double] {
      let sorted = arr.sorted()
      let peak = max(sorted[Int(Double(bins - 1) * 0.94)], 1.0)
      return arr.map { min($0 / peak, 1.0) }
    }

    let wfMax = max(wf.max() ?? 1.0, 1.0)
    let normWf = wf.map { min(sqrt($0 / wfMax), 1.0) }

    return [
      "r": normHist(rBins),
      "g": normHist(gBins),
      "b": normHist(bBins),
      "luma": normHist(lBins),
      "waveform": normWf,
      "waveformCols": wfCols,
      "waveformRows": wfRows,
      "vectorscope": vectorPoints,
      "clippedPct": ((Double(clipped) / Double(total)) * 1000.0).rounded() / 10.0,
      "crushedPct": ((Double(crushed) / Double(total)) * 1000.0).rounded() / 10.0
    ]
  }

  /// OpenFilm-inspired Shot-to-Shot Color Match: computes an ASC CDL
  /// (Slope/Offset/Power/Saturation) matching [source] to [reference].
  static func matchColor(source: CIImage, reference: CIImage) -> [String: Any] {
    guard let srcPx = samplePixels128(from: source),
          let refPx = samplePixels128(from: reference) else {
      return [:]
    }

    func stats(_ px: [UInt8]) -> (mean: [Double], std: [Double], sat: Double) {
      let n = Double(px.count / 4)
      guard n > 0 else { return ([0.5, 0.5, 0.5], [0.2, 0.2, 0.2], 0.3) }
      var mean = [0.0, 0.0, 0.0]
      var sumSat = 0.0
      for i in 0..<Int(n) {
        let b = i * 4
        let r = Double(px[b]) / 255.0
        let g = Double(px[b + 1]) / 255.0
        let bl = Double(px[b + 2]) / 255.0
        mean[0] += r; mean[1] += g; mean[2] += bl
        let mx = max(r, max(g, bl))
        let mn = min(r, min(g, bl))
        sumSat += mx > 0.01 ? (mx - mn) / mx : 0.0
      }
      mean = mean.map { $0 / n }
      var variance = [0.0, 0.0, 0.0]
      for i in 0..<Int(n) {
        let b = i * 4
        let dr = Double(px[b]) / 255.0 - mean[0]
        let dg = Double(px[b + 1]) / 255.0 - mean[1]
        let db = Double(px[b + 2]) / 255.0 - mean[2]
        variance[0] += dr * dr
        variance[1] += dg * dg
        variance[2] += db * db
      }
      let std = variance.map { max(sqrt($0 / n), 0.04) }
      return (mean, std, max(sumSat / n, 0.05))
    }

    let s = stats(srcPx)
    let r = stats(refPx)

    var slopes: [Double] = []
    var offsets: [Double] = []
    var powers: [Double] = []
    for c in 0..<3 {
      // Blend 78% toward reference distribution so match stays cinematic & natural.
      let rawSlope = r.std[c] / s.std[c]
      let slope = min(max(1.0 + (rawSlope - 1.0) * 0.78, 0.65), 1.48)
      let offset = min(max((r.mean[c] - s.mean[c] * slope) * 0.78, -0.22), 0.22)
      let midRatio = log(max(r.mean[c], 0.08)) / log(max(s.mean[c], 0.08))
      let power = min(max(1.0 + (midRatio - 1.0) * 0.35, 0.78), 1.28)
      slopes.append((slope * 100.0).rounded() / 100.0)
      offsets.append((offset * 100.0).rounded() / 100.0)
      powers.append((power * 100.0).rounded() / 100.0)
    }

    let satRatio = min(max(1.0 + ((r.sat / s.sat) - 1.0) * 0.65, 0.45), 1.55)
    return [
      "cdlSlope": slopes,
      "cdlOffset": offsets,
      "cdlPower": powers,
      "cdlSaturation": (satRatio * 100.0).rounded() / 100.0
    ]
  }

  /// Estimates linear gain needed to bring an audio track near -14 LUFS
  /// delivery loudness (bounded safely to avoid clipping or excessive boost).
  static func loudnessNormalizationGain(
    for asset: AVAsset,
    track: AVAssetTrack
  ) async -> Double {
    guard let reader = try? AVAssetReader(asset: asset) else { return 1.0 }
    let outputSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
    guard reader.canAdd(output) else { return 1.0 }
    reader.add(output)
    guard reader.startReading() else { return 1.0 }

    var sumSq = 0.0
    var sampleCount = 0
    var peakAbs = 0.0001
    let maxSamples = 44100 * 30 // Scan up to 30 seconds for fast export start.

    while sampleCount < maxSamples, let sb = output.copyNextSampleBuffer() {
      guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
      let len = CMBlockBufferGetDataLength(block)
      if len < 2 { continue }
      let count = len / 2
      var ints = [Int16](repeating: 0, count: count)
      let status = ints.withUnsafeMutableBytes { ptr in
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: ptr.baseAddress!)
      }
      guard status == noErr else { continue }
      for s in ints {
        let v = Double(s) / 32768.0
        sumSq += v * v
        let a = abs(v)
        if a > peakAbs { peakAbs = a }
      }
      sampleCount += count
    }
    reader.cancelReading()
    guard sampleCount > 0 else { return 1.0 }

    let rms = sqrt(sumSq / Double(sampleCount))
    guard rms > 0.0005 else { return 1.0 }
    // -14 dBFS RMS ≈ 0.20; cap by peak headroom (0.95) and max +12 dB gain.
    let targetRms = 0.20
    let desired = targetRms / rms
    let peakSafe = 0.94 / peakAbs
    return min(max(min(desired, peakSafe), 0.25), 3.5)
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
    maxDimension: Int,
    timestampSeconds: Double = 0.0
  ) -> CIImage? {
    let bucketMs = Int((max(0.0, timestampSeconds) * 10.0).rounded())
    let key = "\(path)|\(isVideo)|\(maxDimension)|\(bucketMs)"

    previewLock.lock()
    let cached = previewCache[key]
    previewLock.unlock()
    if let cached = cached { return cached }

    let image: CIImage?
    if isVideo {
      let asset = AVURLAsset(url: URL(fileURLWithPath: path))
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.requestedTimeToleranceBefore = CMTime(seconds: 0.08, preferredTimescale: 600)
      generator.requestedTimeToleranceAfter = CMTime(seconds: 0.08, preferredTimescale: 600)
      generator.maximumSize = CGSize(
        width: maxDimension,
        height: maxDimension
      )
      let reqTime = timestampSeconds > 0.01
        ? CMTime(seconds: timestampSeconds, preferredTimescale: 600)
        : .zero
      if let frame = try? generator.copyCGImage(at: reqTime, actualTime: nil) {
        image = CIImage(cgImage: frame)
      } else if let fallback = try? generator.copyCGImage(at: .zero, actualTime: nil) {
        image = CIImage(cgImage: fallback)
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
          let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)
            ?? CGColorSpace(name: CGColorSpace.sRGB),
          let cgImage = AppDelegate.p3GradingContext.createCGImage(
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

/// Captures multiple back-to-back Bayer RAW frames for Process Zero Night Stack.
final class ProcessZeroBurstDelegate: NSObject, AVCapturePhotoCaptureDelegate {
  private let lock = NSLock()
  private let expectedCount: Int
  private var receivedCount = 0
  private var frames: [Data] = []
  private var finished = false
  private let completion: ([Data]) -> Void

  init(expectedCount: Int, completion: @escaping ([Data]) -> Void) {
    self.expectedCount = max(1, expectedCount)
    self.completion = completion
    super.init()
  }

  func forceFinish() {
    lock.lock()
    if finished {
      lock.unlock()
      return
    }
    finished = true
    let captured = frames
    lock.unlock()
    completion(captured)
  }

  func photoOutput(
    _ output: AVCapturePhotoOutput,
    didFinishProcessingPhoto photo: AVCapturePhoto,
    error: Error?
  ) {
    let data = error == nil ? photo.fileDataRepresentation() : nil
    lock.lock()
    if finished {
      lock.unlock()
      return
    }
    receivedCount += 1
    if let data = data {
      frames.append(data)
    }
    if receivedCount >= expectedCount {
      finished = true
      let captured = frames
      lock.unlock()
      completion(captured)
      return
    }
    lock.unlock()
  }
}

// MARK: - Tahap 2: Live Metal 3D LUT Viewfinder & Direct-to-Disk HEVC Video LUT Recorder

/// Taps the running camera session's `AVCaptureVideoDataOutput`, grades every
/// live frame on the Metal GPU (`AppDelegate.gradingContext`) with the active
/// 3D Film LUT / `.cube`, deep shadow toe, and real-time DOP overlays (Focus
/// Peaking, Zebra 95 IRE, False Color), exposes a zero-copy `FlutterTexture`
/// for 100% WYSIWYG viewfinder display, and optionally writes graded HEVC
/// frames directly to disk via `AVAssetWriter` (zero post-stop wait!).
final class LiveMetalViewfinderPipeline: NSObject,
  FlutterTexture,
  AVCaptureVideoDataOutputSampleBufferDelegate,
  AVCaptureAudioDataOutputSampleBufferDelegate {

  private weak var registry: FlutterTextureRegistry?
  private weak var dataOutput: AVCaptureVideoDataOutput?
  private weak var originalDelegate: AVCaptureVideoDataOutputSampleBufferDelegate?
  private var originalQueue: DispatchQueue?
  private weak var channel: FlutterMethodChannel?

  private(set) var textureId: Int64 = -1

  private let stateLock = NSLock()
  private var latestPixelBuffer: CVPixelBuffer?
  private var pool: CVPixelBufferPool?
  private var poolSize: (Int, Int) = (0, 0)
  private let renderQueue = DispatchQueue(label: "cinelens.metal.preview", qos: .userInteractive)
  private var isRenderingFrame = false
  private var watchdogTimer: Timer?

  // Live grading & DOP overlay config
  private var activeLook: FilmLook?
  private var activeMatrix: [Double] = [
    1, 0, 0, 0, 0,
    0, 1, 0, 0, 0,
    0, 0, 1, 0, 0,
    0, 0, 0, 1, 0,
  ]
  private var appleLogInput = false
  private var focusPeaking = false
  private var zebraStripes = false
  private var falseColor = false
  private var liveScopeEnabled = false
  private var frameCounter = 0

  // Direct-to-disk HEVC LUT recording state
  private var isDirectRecording = false
  private var directWriter: AVAssetWriter?
  private var directVideoInput: AVAssetWriterInput?
  private var directAdaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var directAudioInput: AVAssetWriterInput?
  private var directAudioSession: AVCaptureSession?
  private var directURL: URL?
  private var directStartPTS: CMTime?
  private var directBitrate = 45_000_000
  private var directFps = 24
  private var directFrameAspect = 0.0
  private var directTrueCrop = false
  private var directSize: (Int, Int) = (0, 0)
  private var directStartResult: FlutterResult?
  private var directDidStart = false

  private static var falseColorCubeCache: Data?

  init(
    registry: FlutterTextureRegistry,
    dataOutput: AVCaptureVideoDataOutput,
    originalDelegate: AVCaptureVideoDataOutputSampleBufferDelegate,
    originalQueue: DispatchQueue,
    channel: FlutterMethodChannel?
  ) {
    self.registry = registry
    self.dataOutput = dataOutput
    self.originalDelegate = originalDelegate
    self.originalQueue = originalQueue
    self.channel = channel
    super.init()
    self.textureId = registry.register(self)
  }

  func attach() {
    if let dataOutput = dataOutput, let queue = originalQueue {
      dataOutput.setSampleBufferDelegate(self, queue: queue)
    }
    DispatchQueue.main.async { [weak self] in
      self?.watchdogTimer?.invalidate()
      self?.watchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
        self?.ensureDelegateAttached()
      }
    }
  }

  /// Seamlessly re-hooks onto a new or reconfigured `AVCaptureSession` (e.g.
  /// 2x/TEL lens switch or zoom format transition) while keeping `textureId`!
  func rebind(to session: AVCaptureSession) {
    guard let newOutput = session.outputs.compactMap({ $0 as? AVCaptureVideoDataOutput }).first else {
      return
    }
    stateLock.lock()
    if let prevOut = dataOutput, prevOut !== newOutput {
      prevOut.setSampleBufferDelegate(originalDelegate, queue: originalQueue)
    }
    dataOutput = newOutput
    if let del = newOutput.sampleBufferDelegate, del !== self {
      originalDelegate = del
    }
    if let q = newOutput.sampleBufferCallbackQueue {
      originalQueue = q
    }
    let queue = originalQueue ?? DispatchQueue(label: "cinelens.metal.fallback")
    stateLock.unlock()
    newOutput.setSampleBufferDelegate(self, queue: queue)
  }

  private func ensureDelegateAttached() {
    stateLock.lock()
    guard let out = dataOutput, textureId >= 0 else {
      stateLock.unlock()
      return
    }
    if out.sampleBufferDelegate !== self {
      if let newDel = out.sampleBufferDelegate {
        originalDelegate = newDel
      }
      if let newQ = out.sampleBufferCallbackQueue {
        originalQueue = newQ
      }
      let q = originalQueue ?? DispatchQueue(label: "cinelens.metal.fallback")
      stateLock.unlock()
      out.setSampleBufferDelegate(self, queue: q)
      return
    }
    stateLock.unlock()
  }

  func detach() {
    DispatchQueue.main.async { [weak self] in
      self?.watchdogTimer?.invalidate()
      self?.watchdogTimer = nil
    }
    stateLock.lock()
    let out = dataOutput
    let origDel = originalDelegate
    let origQ = originalQueue
    dataOutput = nil
    latestPixelBuffer = nil
    pool = nil
    isRenderingFrame = false
    stateLock.unlock()

    if let out = out {
      out.setSampleBufferDelegate(origDel, queue: origQ)
    }
    stopAudioCapture()
    if textureId >= 0 {
      registry?.unregisterTexture(textureId)
      textureId = -1
    }
  }

  func updateConfig(args: [String: Any]) {
    let toneId = args["toneId"] as? String
    let intensity = (args["intensity"] as? NSNumber)?.doubleValue ?? 1.0
    let effects = FilmEffects.from(args)
    let imported = ImportedLut.from(args)
    let matrix = (args["matrix"] as? [Double]) ?? activeMatrix

    let look = imported.flatMap {
      FilmEngine.importedLook($0, effects: effects)
    } ?? FilmEngine.look(
      toneId: toneId,
      intensity: intensity,
      effects: effects
    )

    stateLock.lock()
    activeLook = look
    if matrix.count == 20 { activeMatrix = matrix }
    if let v = args["appleLogInput"] as? Bool { appleLogInput = v }
    if let v = args["focusPeaking"] as? Bool { focusPeaking = v }
    if let v = args["zebraStripes"] as? Bool { zebraStripes = v }
    if let v = args["falseColor"] as? Bool { falseColor = v }
    if let v = args["liveScope"] as? Bool { liveScopeEnabled = v }
    if let v = args["frameAspectRatio"] as? NSNumber { directFrameAspect = v.doubleValue }
    if let v = args["anamorphicCrop"] as? Bool { directTrueCrop = v }
    stateLock.unlock()
  }

  // MARK: FlutterTexture
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    stateLock.lock()
    let buf = latestPixelBuffer
    stateLock.unlock()
    guard let buffer = buf else { return nil }
    return Unmanaged.passRetained(buffer)
  }

  // MARK: Direct-to-disk HEVC LUT recording
  func startDirectRecording(fps: Int, bitrate: Int, result: @escaping FlutterResult) {
    stateLock.lock()
    if isDirectRecording {
      stateLock.unlock()
      result(FlutterError(code: "busy", message: "Direct recording already active.", details: nil))
      return
    }
    directFps = max(fps, 1)
    directBitrate = max(bitrate, 12_000_000)
    directURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("CINELENS_DIRECT_\(Int(Date().timeIntervalSince1970)).mov")
    directWriter = nil
    directVideoInput = nil
    directAdaptor = nil
    directAudioInput = nil
    directStartPTS = nil
    directDidStart = false
    directStartResult = result
    isDirectRecording = true
    stateLock.unlock()

    startAudioCapture()
  }

  func stopDirectRecording(result: @escaping FlutterResult) {
    stateLock.lock()
    let active = isDirectRecording
    isDirectRecording = false
    let writer = directWriter
    let vIn = directVideoInput
    let aIn = directAudioInput
    let url = directURL
    directWriter = nil
    directVideoInput = nil
    directAdaptor = nil
    directAudioInput = nil
    directStartResult = nil
    stateLock.unlock()

    stopAudioCapture()

    guard active, let writer = writer, writer.status == .writing, let url = url else {
      result(FlutterError(code: "not_recording", message: "No recorded frames.", details: nil))
      return
    }

    vIn?.markAsFinished()
    aIn?.markAsFinished()
    writer.finishWriting {
      DispatchQueue.main.async {
        if writer.status == .completed {
          result(url.path)
        } else {
          result(FlutterError(
            code: "write_failed",
            message: writer.error?.localizedDescription ?? "Direct LUT recording failed.",
            details: nil
          ))
        }
      }
    }
  }

  private func startAudioCapture() {
    guard directAudioSession == nil,
          let audioDevice = AVCaptureDevice.default(for: .audio),
          let input = try? AVCaptureDeviceInput(device: audioDevice) else { return }
    let session = AVCaptureSession()
    let output = AVCaptureAudioDataOutput()
    if session.canAddInput(input), session.canAddOutput(output) {
      session.addInput(input)
      session.addOutput(output)
      output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "cinelens.direct.audio"))
      directAudioSession = session
      DispatchQueue.global(qos: .userInitiated).async {
        session.startRunning()
      }
    }
  }

  private func stopAudioCapture() {
    if let s = directAudioSession {
      DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() }
      directAudioSession = nil
    }
  }

  // MARK: AVCapture SampleBufferDelegate
  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    if output is AVCaptureVideoDataOutput {
      originalDelegate?.captureOutput?(output, didOutput: sampleBuffer, from: connection)
      processVideoFrame(sampleBuffer)
    } else {
      processAudioFrame(sampleBuffer)
    }
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didDrop sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    originalDelegate?.captureOutput?(output, didDrop: sampleBuffer, from: connection)
  }

  private func processAudioFrame(_ sampleBuffer: CMSampleBuffer) {
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
    stateLock.lock()
    defer { stateLock.unlock() }
    guard isDirectRecording,
          let writer = directWriter,
          writer.status == .writing,
          let aIn = directAudioInput,
          let start = directStartPTS else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    if CMTimeCompare(pts, start) < 0 { return }
    if aIn.isReadyForMoreMediaData {
      aIn.append(sampleBuffer)
    }
  }

  private func processVideoFrame(_ sampleBuffer: CMSampleBuffer) {
    guard CMSampleBufferDataIsReady(sampleBuffer),
          let srcBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    stateLock.lock()
    let look = activeLook
    let matrix = activeMatrix
    let isLog = appleLogInput
    let peaking = focusPeaking
    let zebra = zebraStripes
    let fColor = falseColor
    let wantScope = liveScopeEnabled
    let recording = isDirectRecording
    if !recording && isRenderingFrame {
      // Never queue multiple 12MP/48MP ISP buffers — return immediately so 2x/5x
      // sensor-crop zoom transitions never starve AVFoundation's buffer pool!
      stateLock.unlock()
      return
    }
    if !recording {
      isRenderingFrame = true
    }
    frameCounter &+= 1
    let fIdx = frameCounter
    stateLock.unlock()

    let rawCI = CIImage(cvPixelBuffer: srcBuffer)
    let rawExtent = rawCI.extent
    guard rawExtent.width > 1, rawExtent.height > 1 else {
      stateLock.lock()
      isRenderingFrame = false
      stateLock.unlock()
      return
    }

    // If recording Direct-to-Disk 4K HEVC, grade & write full-res synchronously on writer pool.
    if recording {
      var fullCI = rawCI
      if fullCI.extent.origin != .zero {
        fullCI = fullCI.transformed(
          by: CGAffineTransform(translationX: -fullCI.extent.origin.x, y: -fullCI.extent.origin.y)
        )
      }
      if isLog { fullCI = FilmEngine.applyAppleLogIDT(to: fullCI) }
      let fullGraded = Self.gradeLiveImage(fullCI, look: look, matrix: matrix)
      let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      appendDirectFrame(fullGraded, pts: pts)

      stateLock.lock()
      if isRenderingFrame {
        stateLock.unlock()
        return
      }
      isRenderingFrame = true
      stateLock.unlock()
    }

    // Offload viewfinder GPU render to dedicated queue at <=1280px so live zoom
    // (1x -> 2x -> 8x) stays butter-smooth 60fps with zero black-screen stalls.
    renderQueue.async { [weak self] in
      guard let self = self else { return }
      defer {
        self.stateLock.lock()
        self.isRenderingFrame = false
        self.stateLock.unlock()
      }

      var ci = rawCI
      if ci.extent.origin != .zero {
        ci = ci.transformed(
          by: CGAffineTransform(translationX: -ci.extent.origin.x, y: -ci.extent.origin.y)
        )
      }
      let maxSide = max(ci.extent.width, ci.extent.height)
      if maxSide > 1280.0 {
        let factor = 1280.0 / maxSide
        ci = ci.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
      }
      let w = max(2, Int(floor(ci.extent.width / 2.0) * 2.0))
      let h = max(2, Int(floor(ci.extent.height / 2.0) * 2.0))
      let extent = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
      ci = ci.cropped(to: extent)

      if isLog {
        ci = FilmEngine.applyAppleLogIDT(to: ci)
      }

      let graded = Self.gradeLiveImage(ci, look: look, matrix: matrix)
      var displayImage = graded

      if fColor, let fcCube = LiveMetalViewfinderPipeline.falseColorCube() {
        if let filter = CIFilter(name: "CIColorCubeWithColorSpace"),
           let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
          filter.setValue(displayImage, forKey: kCIInputImageKey)
          filter.setValue(33, forKey: "inputCubeDimension")
          filter.setValue(fcCube, forKey: "inputCubeData")
          filter.setValue(srgb, forKey: "inputColorSpace")
          displayImage = filter.outputImage?.cropped(to: extent) ?? displayImage
        }
      }
      if zebra {
        let hotMask = graded.applyingFilter(
          "CIColorMatrix",
          parameters: [
            "inputRVector": CIVector(x: 4.5, y: 15.0, z: 1.5, w: 0),
            "inputGVector": CIVector(x: 3.3, y: 11.0, z: 1.1, w: 0),
            "inputBVector": CIVector(x: 0.9, y: 3.0, z: 0.3, w: 0),
            "inputBiasVector": CIVector(x: -19.7, y: -14.5, z: -4.0, w: 0)
          ]
        ).applyingFilter(
          "CIColorClamp",
          parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 0.9, y: 0.66, z: 0.22, w: 1)
          ]
        )
        displayImage = hotMask.applyingFilter(
          "CIScreenBlendMode",
          parameters: [kCIInputBackgroundImageKey: displayImage]
        ).cropped(to: extent)
      }
      if peaking {
        let edges = graded.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 3.5])
          .applyingFilter(
            "CIColorMatrix",
            parameters: [
              "inputRVector": CIVector(x: 0.95, y: 0, z: 0, w: 0),
              "inputGVector": CIVector(x: 0, y: 0.68, z: 0, w: 0),
              "inputBVector": CIVector(x: 0, y: 0, z: 0.20, w: 0)
            ]
          )
        displayImage = edges.applyingFilter(
          "CIAdditionCompositing",
          parameters: [kCIInputBackgroundImageKey: displayImage]
        ).cropped(to: extent)
      }

      guard let outBuf = self.nextPixelBuffer(width: w, height: h) else { return }
      let srgb = CGColorSpace(name: CGColorSpace.sRGB)
      AppDelegate.gradingContext.render(
        displayImage,
        to: outBuf,
        bounds: extent,
        colorSpace: srgb
      )

      self.stateLock.lock()
      self.latestPixelBuffer = outBuf
      let tid = self.textureId
      self.stateLock.unlock()

      if tid >= 0 {
        DispatchQueue.main.async { [weak self] in
          self?.registry?.textureFrameAvailable(tid)
        }
      }

      if wantScope && (fIdx % 6 == 0) {
        let scopes = PhotoEditor.computeScopes(for: graded)
        if !scopes.isEmpty {
          DispatchQueue.main.async { [weak self] in
            self?.channel?.invokeMethod("liveCameraScope", arguments: scopes)
          }
        }
      }
    }
  }

  private static func gradeLiveImage(
    _ ci: CIImage,
    look: FilmLook?,
    matrix: [Double]
  ) -> CIImage {
    let extent = ci.extent
    var graded: CIImage
    if let look = look {
      if look.usesCube,
         let cube = CIFilter(name: "CIColorCubeWithColorSpace"),
         let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
        cube.setValue(ci, forKey: kCIInputImageKey)
        cube.setValue(look.cubeSize, forKey: "inputCubeDimension")
        cube.setValue(look.cubeData, forKey: "inputCubeData")
        cube.setValue(srgb, forKey: "inputColorSpace")
        graded = cube.outputImage?.cropped(to: extent) ?? ci
      } else {
        graded = ci
      }
      if look.shadowDepth > 0.005 {
        graded = FilmEngine.applyShadowDepth(to: graded, strength: look.shadowDepth)
          .cropped(to: extent)
      }
      if look.filmicRollOff > 0.005 {
        graded = FilmEngine.applyFilmicRollOff(to: graded, strength: look.filmicRollOff)
          .cropped(to: extent)
      }
    } else {
      graded = AppDelegate.colorMatrixImage(matrix, to: ci)
    }
    return graded
  }

  private func appendDirectFrame(_ graded: CIImage, pts: CMTime) {
    let ext = graded.extent
    let w = max(2, Int(floor(ext.width / 2.0) * 2.0))
    let h = max(2, Int(floor(ext.height / 2.0) * 2.0))

    stateLock.lock()
    if directWriter == nil, let url = directURL {
      do {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoSettings: [String: Any] = [
          AVVideoCodecKey: AVVideoCodecType.hevc.rawValue,
          AVVideoWidthKey: w,
          AVVideoHeightKey: h,
          AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: directBitrate,
            AVVideoExpectedSourceFrameRateKey: directFps
          ]
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vIn.expectsMediaDataInRealTime = true
        if writer.canAdd(vIn) { writer.add(vIn) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
          assetWriterInput: vIn,
          sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
          ]
        )
        let audioSettings: [String: Any] = [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVNumberOfChannelsKey: 1,
          AVSampleRateKey: 44100,
          AVEncoderBitRateKey: 192000
        ]
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        aIn.expectsMediaDataInRealTime = true
        if writer.canAdd(aIn) {
          writer.add(aIn)
          directAudioInput = aIn
        }
        if writer.startWriting() {
          writer.startSession(atSourceTime: pts)
          directWriter = writer
          directVideoInput = vIn
          directAdaptor = adaptor
          directStartPTS = pts
          directSize = (w, h)
          directDidStart = true
          let cb = directStartResult
          directStartResult = nil
          DispatchQueue.main.async { cb?(true) }
        }
      } catch {
        isDirectRecording = false
        let cb = directStartResult
        directStartResult = nil
        DispatchQueue.main.async {
          cb?(FlutterError(code: "writer_failed", message: error.localizedDescription, details: nil))
        }
      }
    }

    guard let writer = directWriter,
          writer.status == .writing,
          let vIn = directVideoInput,
          vIn.isReadyForMoreMediaData,
          let adaptor = directAdaptor,
          let pool = adaptor.pixelBufferPool,
          directSize.0 == w, directSize.1 == h else {
      stateLock.unlock()
      return
    }
    stateLock.unlock()

    var dst: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst) == kCVReturnSuccess,
          let pixelBuf = dst else { return }
    AppDelegate.gradingContext.render(graded, to: pixelBuf)
    stateLock.lock()
    if isDirectRecording, directWriter?.status == .writing, directVideoInput?.isReadyForMoreMediaData == true {
      directAdaptor?.append(pixelBuf, withPresentationTime: pts)
    }
    stateLock.unlock()
  }

  private func nextPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    stateLock.lock()
    if pool == nil || poolSize.0 != width || poolSize.1 != height {
      var newPool: CVPixelBufferPool?
      let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        kCVPixelBufferMetalCompatibilityKey as String: true
      ]
      CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &newPool)
      pool = newPool
      poolSize = (width, height)
    }
    let currentPool = pool
    stateLock.unlock()

    guard let p = currentPool else { return nil }
    var buf: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, p, &buf) == kCVReturnSuccess else { return nil }
    return buf
  }

  /// Broadcast cinema False Color IRE 33³ LUT:
  /// Purple (<5 IRE crushed), Blue (5-15 shadows), Grey (mid), Green (38-45 mid-grey),
  /// Pink (55-68 skin tone), Yellow (80-92 hot), Red (>94 clipped).
  private static func falseColorCube() -> Data? {
    if let cached = falseColorCubeCache { return cached }
    let n = 33
    let last = Double(n - 1)
    var vals = [Float]()
    vals.reserveCapacity(n * n * n * 4)
    for bi in 0..<n {
      for gi in 0..<n {
        for ri in 0..<n {
          let y = 0.2126 * Double(ri) / last
            + 0.7152 * Double(gi) / last
            + 0.0722 * Double(bi) / last
          let rgb: (Float, Float, Float)
          if y < 0.05 { rgb = (0.45, 0.05, 0.75) }         // Purple: crushed
          else if y < 0.15 { rgb = (0.10, 0.35, 0.90) }    // Blue: deep shadow
          else if y >= 0.38 && y <= 0.45 { rgb = (0.15, 0.80, 0.25) } // Green: 18% grey
          else if y >= 0.55 && y <= 0.68 { rgb = (0.95, 0.52, 0.68) } // Pink: skin tone
          else if y >= 0.82 && y < 0.94 { rgb = (0.95, 0.85, 0.15) }  // Yellow: bright
          else if y >= 0.94 { rgb = (0.98, 0.12, 0.12) }              // Red: clipped
          else {
            let g = Float(y)
            rgb = (g, g, g)
          }
          vals.append(rgb.0); vals.append(rgb.1); vals.append(rgb.2); vals.append(1.0)
        }
      }
    }
    let data = vals.withUnsafeBufferPointer { Data(buffer: $0) }
    falseColorCubeCache = data
    return data
  }
}
