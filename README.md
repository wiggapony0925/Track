# Track - NYC Transit AI

Track is an intelligent transit companion for iOS that learns your commute habits and predicts *real* arrival times using local historical data, rather than just relying on the official schedule.

## 🏗 Architecture
The app follows a strict **MVVM** pattern with a **Repository** layer for data access.
- **SwiftData:** Used for persisting user habits (`CommutePattern`) and trip logs (`TripLog`).
- **SwiftProtobuf:** (Planned) Will decode high-frequency binary data from the MTA API.
- **CoreML:** (Planned) Will use `TripLog` data to train a regression model for delay prediction.

## 🚀 Setup
1. **Clone the repo.**
2. **Add API Key:** Create `Secrets.xcconfig` and add `MTA_API_KEY = "your_key"`.
3. **Dependencies:** Swift Package Manager will auto-install `SwiftProtobuf` when integrated.
4. **Build:** Run on iPhone 15 Pro Simulator or later (iOS 18+).

## 📂 Key Files
- `TransitRepository.swift`: Handles real-time transit data fetching (stub, ready for GTFS-RT Protobuf integration).
- `DelayCalculator.swift`: The heuristic engine that adjusts ETA based on weather and history.
- `SmartSuggester.swift`: The logic that powers the "Magic Card" on the home screen.
- `ContentView.swift`: Root view with tab-based navigation (Home dashboard + Trip History).
- `HomeView.swift`: Map-based dashboard with sliding bottom sheet and smart suggestions.
- `AppTheme.swift`: Centralized design system (colors, typography, layout constants).

## 🤖 AI Features
- **Smart Commute:** Passive logging of user trips allows the app to predict destination upon launch.
- **Reality Check:** Compares `MTA_Predicted` vs `Actual_Arrival` to generate a delay index for each line.
- **Delay Predictor:** Adjusts arrival estimates based on rush hour, weather conditions, and historical delay data.

## ♿ Accessibility
All UI components include accessibility labels and hints for VoiceOver support.

## 🔒 Privacy
- Location data is used only to find nearby stations and predict commute patterns.
- All user data is stored locally on-device via SwiftData.
- No data is transmitted to third-party services.
