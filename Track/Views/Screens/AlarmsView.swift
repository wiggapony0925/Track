import SwiftUI

struct AlarmsView: View {
    var body: some View {
        NavigationStack {
            VStack {
                Image(systemName: "alarm.fill")
                    .font(.system(size: 60))
                    .foregroundColor(AppTheme.Colors.accent)
                    .padding()
                
                Text("Alarms & Widgets")
                    .font(.title2.bold())
                
                Text("Coming soon...")
                    .foregroundColor(.secondary)
            }
            .navigationTitle("Alarms")
        }
    }
}

#Preview {
    AlarmsView()
}
