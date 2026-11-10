import SwiftUI

struct InfoTip: View {
    let text: String
    @State private var isPresented = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("说明")
        .popover(isPresented: $isPresented) {
            Text(text).font(.callout).padding(16).frame(width: 300)
        }
    }
}
