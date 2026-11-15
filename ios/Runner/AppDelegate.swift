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
      self?.enableStabilization(on: session)
      self?.captureActiveDevice(from: session)
    }

    center.addObserver(
      forName: AVCaptureSession.didStopRunningNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.reportStabilization(active: false, mode: 0)
    }
  }

  private func enableStabilization(on session: AVCaptureSession) {
    let stabilizable = session.connections.filter { $0.isVideoStabilizationSupported }
    guard let connection = stabilizable.first else {
      reportStabilization(active: false, mode: 0)
      return
    }

    for candidate in stabilizable where candidate.preferredVideoStabilizationMode == .off {
      candidate.preferredVideoStabilizationMode = .auto
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
