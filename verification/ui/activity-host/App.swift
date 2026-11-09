import ActivityKit
import SwiftUI

// Offline owner of the production widget, independent of account restoration.
// The extension, models, assets and fixture states are the production sources.
@main
struct ActivityVerifyApp: App {
  @State private var selection = "single"
  @State private var result = "Ready"

  var body: some Scene {
    WindowGroup {
      List {
        Text("Live Activity verification").font(.headline)
        Text(result).accessibilityIdentifier("activity-result")
        ForEach(["single", "running", "permission", "question", "done", "failed", "doneMany", "stale", "end"], id: \.self) { name in
          Button(name) { select(name) }.accessibilityIdentifier("activity-\(name)")
        }
      }
      .onOpenURL { url in select(url.lastPathComponent) }
      .task {
        if ProcessInfo.processInfo.arguments.contains("-render-watch") { renderWatch() }
        LodyLiveActivityActions.respond = { session, request, option in
          result = "Answered \(session)/\(request)/\(option)"
          for activity in Activity<LodyActivityAttributes>.activities {
            await activity.update(ActivityContent(state: LiveActivityFixtures.single, staleDate: .now.addingTimeInterval(1800)))
          }
        }
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-fixture"), arguments.indices.contains(index + 1) {
          select(arguments[index + 1])
        }
      }
    }
  }

  private func select(_ name: String) {
    selection = name
    Task { @MainActor in
      let activities = Activity<LodyActivityAttributes>.activities
      if name == "end" {
        for activity in activities { await activity.end(nil, dismissalPolicy: .immediate) }
        result = "Ended"
        return
      }
      let states: [String: LodyState] = [
        "single": LiveActivityFixtures.single,
        "running": LiveActivityFixtures.running,
        "permission": LiveActivityFixtures.permission,
        "question": LiveActivityFixtures.question,
        "done": LiveActivityFixtures.done,
        "failed": LiveActivityFixtures.failed,
        "doneMany": LiveActivityFixtures.doneMany,
        "stale": LiveActivityFixtures.single,
      ]
      guard let state = states[name] else { return }
      let content = ActivityContent(state: state, staleDate: name == "stale" ? .now.addingTimeInterval(-1) : .now.addingTimeInterval(1800))
      do {
        if let activity = activities.first {
          await activity.update(content)
        } else {
          _ = try Activity.request(attributes: LiveActivityFixtures.attributes, content: content)
        }
        result = "Showing \(name)"
      } catch {
        result = "Error: \(error.localizedDescription)"
      }
    }
  }
  @MainActor
  private func renderWatch() {
    let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let sizes: [(String, CGFloat, CGFloat)] = [("40mm", 152, 69.5), ("45mm", 184, 80.5)]
    let states = [("permission", LiveActivityFixtures.permission), ("running", LiveActivityFixtures.single)]
    for (size, width, height) in sizes {
      for (name, state) in states {
        let view = LodySupplementalActivityView(userId: "local:fixture", state: state, isStale: false)
          .padding(4).frame(width: width, height: height).background(.black)
          .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        try! renderer.uiImage!.pngData()!.write(to: directory.appendingPathComponent("watch-\(size)-\(name).png"))
      }
    }
    result = "Rendered Watch fixtures"
  }

}
