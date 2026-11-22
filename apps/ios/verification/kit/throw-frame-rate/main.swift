import UIKit

let track = ChatThrowCurve.positionTrack(from: .zero, to: CGPoint(x: 200, y: -400))
let animations: [(String, CAAnimation)] = [
  ("position", ChatThrowCurve.positionAnimation(track)),
  ("scale", ChatThrowCurve.scaleAnimation()),
]
for (name, animation) in animations {
  let range = animation.preferredFrameRateRange
  precondition(range.preferred == 120 && range.maximum == 120 && range.minimum >= 80,
    "The \(name) throw must ask for ProMotion rates, got \(range)")
}
print("Send throw: position and scale request 80–120 Hz")
