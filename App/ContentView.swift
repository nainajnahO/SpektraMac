import SpektraEngine
import SwiftUI

/// Placeholder until the Scanjet-style shell lands (PLAN.md, Day 5).
struct ContentView: View {
    var body: some View {
        ContentUnavailableView(
            "SpektraMac",
            systemImage: "film",
            description: Text("Engine port of Spektrafilm \(SpektraEngine.referenceVersion) in progress.")
        )
    }
}
