import AVFoundation
import Flutter
import Photos
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var capture: CaptureChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    application.isIdleTimerDisabled = true
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CaptureChannel") {
      capture = CaptureChannel(messenger: registrar.messenger())
    }
  }
}

/// Saves photos and videos to the photo library for the Dart side.
final class CaptureChannel {
  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "car_cam.capture")
  private var recorder: Mp4Recorder?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "car_cam/capture", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "savePhoto":
      guard let data = call.arguments as? FlutterStandardTypedData else {
        result(FlutterError(code: "bad_args", message: "Missing photo", details: nil))
        return
      }
      savePhoto(data.data, result)
    case "startRecording":
      // Ask now, so a refusal doesn't lose a finished video.
      withPhotoAccess(result) {
        self.queue.async {
          guard self.recorder == nil else {
            self.finish(result, FlutterError(code: "already_recording", message: nil, details: nil))
            return
          }
          self.recorder = Mp4Recorder()
          self.finish(result, nil)
        }
      }
    case "frame":
      if let args = call.arguments as? [String: Any],
        let jpeg = args["jpeg"] as? FlutterStandardTypedData,
        let pts = args["ptsMs"] as? NSNumber
      {
        queue.async { self.recorder?.addFrame(jpeg.data, ptsMs: pts.int64Value) }
      }
      result(nil)
    case "stopRecording":
      queue.async { self.stopRecording(result) }
    case "openWifiSettings", "openAppSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func finish(_ result: @escaping FlutterResult, _ value: Any?) {
    DispatchQueue.main.async { result(value) }
  }

  private func stopRecording(_ result: @escaping FlutterResult) {
    guard let active = recorder else {
      finish(result, FlutterError(code: "not_recording", message: nil, details: nil))
      return
    }
    recorder = nil
    active.finish { url, frames in
      guard let url = url else {
        self.finish(
          result, FlutterError(code: "save_failed", message: "No video was recorded", details: nil))
        return
      }
      self.withPhotoAccess(result) {
        PHPhotoLibrary.shared().performChanges({
          let request = PHAssetCreationRequest.forAsset()
          request.addResource(with: .video, fileURL: url, options: nil)
        }) { ok, error in
          try? FileManager.default.removeItem(at: url)
          self.finish(
            result,
            ok
              ? ["frames": frames]
              : FlutterError(
                code: "save_failed", message: error?.localizedDescription, details: nil))
        }
      }
    }
  }

  private func savePhoto(_ jpeg: Data, _ result: @escaping FlutterResult) {
    withPhotoAccess(result) {
      PHPhotoLibrary.shared().performChanges({
        PHAssetCreationRequest.forAsset().addResource(with: .photo, data: jpeg, options: nil)
      }) { ok, error in
        self.finish(
          result,
          ok
            ? nil
            : FlutterError(code: "save_failed", message: error?.localizedDescription, details: nil))
      }
    }
  }

  private func withPhotoAccess(_ result: @escaping FlutterResult, _ action: @escaping () -> Void) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      if status == .authorized || status == .limited {
        action()
      } else {
        self.finish(
          result, FlutterError(code: "permission_denied", message: "Photos access denied", details: nil))
      }
    }
  }
}

/// Encodes JPEG frames to an H.264 MP4. Call from one serial queue.
final class Mp4Recorder {
  private let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("CarCam_\(UUID().uuidString).mp4")
  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var width = 0
  private var height = 0
  private var lastPts: Int64 = -1
  private var frames = 0

  func addFrame(_ jpeg: Data, ptsMs: Int64) {
    guard let image = UIImage(data: jpeg)?.cgImage else { return }
    if writer == nil && !start(image: image, ptsMs: ptsMs) { return }
    guard let input = input, let adaptor = adaptor, input.isReadyForMoreMediaData,
      ptsMs > lastPts, let pool = adaptor.pixelBufferPool
    else { return }

    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
      let pixels = buffer
    else { return }
    CVPixelBufferLockBaseAddress(pixels, [])
    let context = CGContext(
      data: CVPixelBufferGetBaseAddress(pixels),
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue)
    context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    CVPixelBufferUnlockBaseAddress(pixels, [])

    if adaptor.append(pixels, withPresentationTime: CMTime(value: ptsMs, timescale: 1000)) {
      lastPts = ptsMs
      frames += 1
    }
  }

  func finish(_ done: @escaping (URL?, Int) -> Void) {
    guard let writer = writer, let input = input, frames > 0 else {
      writer?.cancelWriting()
      done(nil, 0)
      return
    }
    input.markAsFinished()
    let count = frames
    let output = url
    writer.finishWriting {
      done(writer.status == .completed ? output : nil, count)
    }
  }

  private func start(image: CGImage, ptsMs: Int64) -> Bool {
    width = image.width & ~1
    height = image.height & ~1
    guard let newWriter = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: max(1_500_000, width * height * 16)
      ],
    ]
    let newInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    newInput.expectsMediaDataInRealTime = true
    let newAdaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: newInput,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
      ])
    guard newWriter.canAdd(newInput) else { return false }
    newWriter.add(newInput)
    guard newWriter.startWriting() else { return false }
    newWriter.startSession(atSourceTime: CMTime(value: ptsMs, timescale: 1000))
    writer = newWriter
    input = newInput
    adaptor = newAdaptor
    return true
  }
}
