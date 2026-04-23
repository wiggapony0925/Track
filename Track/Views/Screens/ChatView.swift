import SwiftUI

struct ChatView: View {
    var body: some View {
        NavigationStack {
            VStack {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 60))
                    .foregroundColor(AppTheme.Colors.accent)
                    .padding()
                
                Text("AI Transit Assistant")
                    .font(.title2.bold())
                
                Text("Coming soon...")
                    .foregroundColor(.secondary)
            }
            .navigationTitle("Chat")
        }
    }
}

#Preview {
    ChatView()
}
