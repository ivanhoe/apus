import SwiftUI
#if DEBUG
import Apus
#endif

struct HotReloadShowcaseCard: View {
    @State private var taps = 0
    @State private var tint: Color = .mint
    #if DEBUG
    @ObserveInjection var forceReload
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Text("Hot Reload Zone")
            //     .font(.headline.weight(.semibold))

            // Text("Edita HotReloadShowcaseCard.swift y guarda: este bloque debe cambiar al instante.")
            //     .font(.caption)
            //     .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                // Button {
                //     taps += 1
                // } label: {
                //     Label("Tap count: \(taps)", systemImage: "bolt.fill")
                //         .font(.caption.weight(.medium))
                // }
                // .buttonStyle(.borderedProminent)
                // .tint(tint)

                // Button("Toggle tint") {
                //     tint = tint == .mint ? .orange : .mint
                // }
                // .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        #if DEBUG
        .enableInjection()
        #endif
    }
}
