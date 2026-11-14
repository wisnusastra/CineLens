import Flutter
import UIKit
import AVFoundation
import CoreImage

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "com.cinelens.ios/video_grader",
        binaryMessenger: controller.binaryMessenger
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

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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

    let composition = AVMutableVideoComposition(asset: asset) { request in
      let extent = request.sourceImage.extent
      let source = request.sourceImage.clampedToExtent()

      guard let colorFilter = CIFilter(name: "CIColorMatrix") else {
        request.finish(with: request.sourceImage, context: nil)
        return
      }

      colorFilter.setValue(source, forKey: kCIInputImageKey)
      colorFilter.setValue(CIVector(x: matrix[0], y: matrix[1], z: matrix[2], w: matrix[3]), forKey: "inputRVector")
      colorFilter.setValue(CIVector(x: matrix[5], y: matrix[6], z: matrix[7], w: matrix[8]), forKey: "inputGVector")
      colorFilter.setValue(CIVector(x: matrix[10], y: matrix[11], z: matrix[12], w: matrix[13]), forKey: "inputBVector")
      colorFilter.setValue(CIVector(x: matrix[15], y: matrix[16], z: matrix[17], w: matrix[18]), forKey: "inputAVector")
      colorFilter.setValue(
        CIVector(x: matrix[4] / 255.0, y: matrix[9] / 255.0, z: matrix[14] / 255.0, w: matrix[19] / 255.0),
        forKey: "inputBiasVector"
      )

      var output = colorFilter.outputImage?.cropped(to: extent) ?? request.sourceImage

      if anamorphic {
        let targetHeight = extent.width / 2.39
        if extent.height > targetHeight {
          let barHeight = (extent.height - targetHeight) / 2.0
          let activeRect = CGRect(
            x: extent.origin.x,
            y: extent.origin.y + barHeight,
            width: extent.width,
            height: targetHeight
          )
          let blackBackground = CIImage(color: .black).cropped(to: extent)
          output = output.cropped(to: activeRect).composited(over: blackBackground)
        }
      }

      request.finish(with: output, context: nil)
    }

    composition.frameDuration = CMTime(value: 1, timescale: 24)

    guard let exportSession = AVAssetExportSession(
      asset: asset,
      presetName: AVAssetExportPresetHighestQuality
    ) else {
      result(inputPath)
      return
    }

    exportSession.outputURL = outputURL
    exportSession.outputFileType = .mov
    exportSession.videoComposition = composition
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
