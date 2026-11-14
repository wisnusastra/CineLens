import AVFoundation
import CoreImage
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private static let videoChannelName = "com.cinelens.ios/video_grader"

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

      default:
        result(FlutterMethodNotImplemented)
      }
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

    let context = CIContext(options: [.useSoftwareRenderer: false])
    let clampedQuality = min(max(quality, 0.5), 1.0)

    guard let jpeg = context.jpegRepresentation(
      of: output,
      colorSpace: colorSpace,
      options: [.lossyCompressionQuality: clampedQuality]
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

    result(FlutterStandardTypedData(bytes: jpeg))
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

        request.finish(with: output, context: nil)
      }

      if renderSize.width > 0, renderSize.height > 0 {
        composition.renderSize = renderSize
      }
      composition.frameDuration = CMTime(value: 1, timescale: frameRate)

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
