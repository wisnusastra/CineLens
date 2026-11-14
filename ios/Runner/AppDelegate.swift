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
      guard call.method == "applyCinemaMatrixToVideo",
            let args = call.arguments as? [String: Any],
            let inputPath = args["inputPath"] as? String,
            let matrix = args["matrix"] as? [Double] else {
        result(FlutterMethodNotImplemented)
        return
      }

      let anamorphic = (args["anamorphic"] as? Bool) ?? false
      self?.exportGradedVideo(
        inputPath: inputPath,
        matrix: matrix,
        anamorphic: anamorphic,
        result: result
      )
    }
  }

  private func exportGradedVideo(
    inputPath: String,
    matrix: [Double],
    anamorphic: Bool,
    result: @escaping FlutterResult
  ) {
    guard matrix.count == 20 else {
      result(inputPath)
      return
    }

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

        if !preferredTransform.isIdentity {
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
      composition.frameDuration = CMTime(value: 1, timescale: 24)

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
