import SwiftUI

struct AppLockView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var failedOnce = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "faceid")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("SecureChat is locked")
                .font(.title2.bold())
            if failedOnce {
                Text("Authentication failed. Try again.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Button("Unlock") {
                Task {
                    let success = await container.appLockService.unlock()
                    failedOnce = !success
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .task {
            _ = await container.appLockService.unlock()
        }
    }
}
