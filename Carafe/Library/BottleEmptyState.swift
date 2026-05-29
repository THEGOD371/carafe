import SwiftUI

struct BottleEmptyState: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "cellularbars")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .foregroundStyle(.tertiary)
                .overlay {
                    Image(systemName: "wineglass")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                        .foregroundStyle(.tint)
                }
            Text("No bottles yet")
                .font(.title2.weight(.semibold))
            VStack(spacing: 4) {
                Text("A bottle is an isolated Wine prefix — think of it as a sandboxed Windows install for one game or app.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
                Text("Each bottle keeps its own Windows version, DLL overrides, and environment.")
                    .multilineTextAlignment(.center)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: 460)
            }

            Button(action: onCreate) {
                Label("Create your first bottle", systemImage: "plus")
                    .frame(minWidth: 220)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.top, 12)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
