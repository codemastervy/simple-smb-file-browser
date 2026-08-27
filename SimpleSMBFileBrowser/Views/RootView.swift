import SwiftUI

/// Temporary shell. Replaced by the NavigationSplitView browser in a later
/// commit; exists now so the project has a buildable entry point while the
/// AMSMB2 integration is verified.
struct RootView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Simple SMB")
                .font(.title2.weight(.semibold))
            Text(SMBClientEnvironment.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

#Preview {
    RootView()
}
