import AVFoundation
import UIKit

/// Camera rotation tracking shared by the attachment cameras. iOS 17 uses
/// `AVCaptureDevice.RotationCoordinator`; earlier systems derive the angle
/// from `UIDevice.orientation` and drive `videoOrientation` instead.
final class LodyCameraRotation: @unchecked Sendable {
  private var coordinator: AnyObject?
  private var observation: NSKeyValueObservation?
  private var orientationObserver: NSObjectProtocol?
  private weak var previewLayer: AVCaptureVideoPreviewLayer?

  /// Rotation angle in degrees for the captured still; follows the preview.
  var captureAngle: CGFloat {
    if #available(iOS 17.0, *),
       let coordinator = coordinator as? AVCaptureDevice.RotationCoordinator {
      return coordinator.videoRotationAngleForHorizonLevelCapture
    }
    return Self.angle(UIDevice.current.orientation)
  }

  @MainActor
  init(device: AVCaptureDevice, previewLayer: AVCaptureVideoPreviewLayer) {
    self.previewLayer = previewLayer
    if #available(iOS 17.0, *) {
      let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
      self.coordinator = coordinator
      observation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] _, change in
        // RotationCoordinator delivers preview-angle observations on the main queue.
        let angle = change.newValue
        MainActor.assumeIsolated {
          if let angle { self?.apply(angle) }
        }
      }
    } else {
      UIDevice.current.beginGeneratingDeviceOrientationNotifications()
      apply(Self.angle(UIDevice.current.orientation))
      orientationObserver = NotificationCenter.default.addObserver(
        forName: UIDevice.orientationDidChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.apply(Self.angle(UIDevice.current.orientation))
        }
      }
    }
  }

  private func apply(_ angle: CGFloat) {
    guard let connection = previewLayer?.connection else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if #available(iOS 17.0, *) {
      if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
    } else if connection.isVideoOrientationSupported {
      connection.videoOrientation = Self.videoOrientation(for: angle)
    }
    CATransaction.commit()
  }

  /// Horizon-level rotation angle for a device orientation, matching the
  /// `RotationCoordinator` convention: portrait is 90°.
  private static func angle(_ orientation: UIDeviceOrientation) -> CGFloat {
    switch orientation {
    case .portraitUpsideDown: return 270
    case .landscapeLeft: return 0
    case .landscapeRight: return 180
    default: return 90
    }
  }

  /// The pre-iOS 17 `videoOrientation` matching a horizon-level angle.
  static func videoOrientation(for angle: CGFloat) -> AVCaptureVideoOrientation {
    switch angle {
    case 0: return .landscapeRight
    case 180: return .landscapeLeft
    case 270: return .portraitUpsideDown
    default: return .portrait
    }
  }

  deinit {
    observation?.invalidate()
    if let orientationObserver {
      NotificationCenter.default.removeObserver(orientationObserver)
      Task { @MainActor in
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
      }
    }
  }
}
