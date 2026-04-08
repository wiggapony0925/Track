import SwiftUI

/// Context about the user's current trip, used to pre-fill lost item details.
struct TripContext {
    let routeName: String        // e.g. "Bx10", "7"
    let mode: String             // "bus", "subway", etc.
    let direction: String?       // e.g. "Westchester Sq via..."
    let vehicleId: String?       // e.g. "MTA NYCT_7560" (bus only)
    let nearestStop: String?     // e.g. "Hunts Point Av"

    /// Clean fleet number stripped of MTA prefixes.
    var fleetNumber: String? {
        guard let vid = vehicleId, !vid.isEmpty else { return nil }
        return vid
            .replacingOccurrences(of: "MTA NYCT_", with: "")
            .replacingOccurrences(of: "MTABC_", with: "")
            .replacingOccurrences(of: "MTA_", with: "")
    }

    /// Human-readable summary for clipboard.
    var summary: String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short

        var lines: [String] = []
        lines.append("MTA Lost Item — Trip Details")
        lines.append("Route: \(routeName) (\(mode.capitalized))")
        if let dir = direction { lines.append("Direction: \(dir)") }
        if let stop = nearestStop { lines.append("Near Stop: \(stop)") }
        if let fleet = fleetNumber { lines.append("Vehicle #: \(fleet)") }
        lines.append("Date/Time: \(df.string(from: Date()))")
        return lines.joined(separator: "\n")
    }
}

/// Comprehensive MTA Lost & Found guide — actionable steps,
/// service-specific contacts, and timeline expectations.
struct LostAndFoundSheet: View {

    let tripContext: TripContext?

    private static let primaryClaimURL = URL(string: "https://new.mta.info/lost-and-found")!
    private static let fallbackClaimURL = URL(string: "https://new.mta.info")!

    @State private var resolvedClaimURL: URL = LostAndFoundSheet.primaryClaimURL
    @State private var showSafari = false
    @State private var copied = false

    init(tripContext: TripContext? = nil) {
        self.tripContext = tripContext
    }

    // MARK: - Body

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                // ── Drag indicator ──
                Capsule()
                    .fill(AppTheme.Colors.textTertiary.opacity(0.35))
                    .frame(width: 36, height: 5)
                    .padding(.top, 10)
                    .padding(.bottom, 20)

                headerSection
                    .padding(.bottom, 24)

                // ── Trip details card ──
                if let ctx = tripContext {
                    tripCard(ctx)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                }

                // ── CTA Buttons (up top so users find them immediately) ──
                ctaButtons
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                // ── Immediate actions ──
                immediateActionsSection
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)

                // ── What you'll need ──
                whatYouNeedSection
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)

                // ── Step-by-step claim process ──
                claimProcessSection
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)

                // ── Where to pick up ──
                pickupLocationsSection
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)

                // ── What to expect ──
                timelineSection
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)

                // ── Found someone else's item? ──
                foundItemSection
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
            }
        }
        .background(AppTheme.Colors.cardBackground)
        .task { await resolveClaimURL() }
        .sheet(isPresented: $showSafari) {
            SafariView(url: resolvedClaimURL)
                .ignoresSafeArea()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.orange.opacity(0.15),
                                Color.yellow.opacity(0.08),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 72, height: 72)
                Image(systemName: "bag.fill.badge.questionmark")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.orange, .red.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            Text("Lost & Found Guide")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textPrimary)

            Text("Everything you need to recover\na lost item on the MTA")
                .font(.system(size: 15))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Immediate Actions

    private var immediateActionsSection: some View {
        sectionCard(
            icon: "bolt.fill",
            iconColor: .orange,
            title: "Do this right now"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                actionRow(
                    icon: "eye.fill",
                    text: "Check around your seat immediately — look under seats, between cushions, and on overhead racks."
                )
                actionRow(
                    icon: "person.fill.questionmark",
                    text: "Tell the bus operator or ask a station agent before you leave. They can radio ahead if the vehicle is still in service."
                )
                actionRow(
                    icon: "note.text",
                    text: "Write down the vehicle or train number, the route, your stop, and the time — you'll need these for your claim."
                )
                actionRow(
                    icon: "clock.arrow.circlepath",
                    text: "File your claim as soon as possible. The sooner you report it, the better your chances."
                )
            }
        }
    }

    // MARK: - What You'll Need

    private var whatYouNeedSection: some View {
        sectionCard(
            icon: "checklist",
            iconColor: AppTheme.Colors.mtaBlue,
            title: "Info you'll need for your claim"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                checkItem("Detailed item description (color, brand, size, distinguishing marks)")
                checkItem("Date and approximate time you lost the item")
                checkItem("Route name or line (e.g. \(tripContext?.routeName ?? "7 train"), \(tripContext?.routeName ?? "Bx10"))")
                checkItem("Direction of travel or last stop you remember")
                if tripContext?.fleetNumber != nil {
                    checkItem("Vehicle/fleet number (we already saved this for you)")
                }
                checkItem("Where on the vehicle you were (front, back, which car)")
                checkItem("Your contact info (email and phone)")
            }
        }
    }

    // MARK: - Claim Process

    private var claimProcessSection: some View {
        sectionCard(
            icon: "list.number",
            iconColor: .purple,
            title: "How to file a claim"
        ) {
            VStack(spacing: 0) {
                step(
                    number: "1",
                    color: .blue,
                    title: "File online or call 511",
                    detail: "Go to mta.info/lost-and-found and fill out the form. You can also call 511 and say \"Lost and Found\" to file by phone. Online is fastest.",
                    isLast: false
                )
                step(
                    number: "2",
                    color: .indigo,
                    title: "Get your claim number",
                    detail: "You'll receive a confirmation email with a claim number. Save this — it's how you'll track your item.",
                    isLast: false
                )
                step(
                    number: "3",
                    color: .purple,
                    title: "MTA searches for your item",
                    detail: "Staff check vehicles and depots. You'll get email updates as they look. This can take several days — items need to be collected and transported.",
                    isLast: false
                )
                step(
                    number: "4",
                    color: .green,
                    title: "Pick up or request shipping",
                    detail: "Once found, you can pick up in person (bring photo ID) or pay to have it shipped. You'll need your claim number.",
                    isLast: true
                )
            }
        }
    }

    // MARK: - Pickup Locations

    private var pickupLocationsSection: some View {
        sectionCard(
            icon: "map.fill",
            iconColor: .teal,
            title: "Lost & Found offices"
        ) {
            VStack(spacing: 12) {
                officeRow(
                    service: "NYC Transit",
                    coverage: "Subway, Local Bus, SIR",
                    location: "34th St–Penn Station",
                    detail: "Lower level, near the A/C/E platforms",
                    hours: "Mon–Fri, 8 AM – 4 PM",
                    phone: "(212) 712-4500"
                )

                thinDivider

                officeRow(
                    service: "Metro-North",
                    coverage: "Commuter Rail",
                    location: "Grand Central Terminal",
                    detail: "Lower level, Window 23",
                    hours: "Mon–Fri, 7 AM – 5 PM",
                    phone: "(212) 340-2555"
                )

                thinDivider

                officeRow(
                    service: "LIRR",
                    coverage: "Long Island Rail Road",
                    location: "Penn Station",
                    detail: "Main concourse level",
                    hours: "Mon–Fri, 7:20 AM – 3:20 PM",
                    phone: "(511 → option 3)"
                )
            }
        }
    }

    // MARK: - Timeline & Retention

    private var timelineSection: some View {
        sectionCard(
            icon: "calendar.badge.clock",
            iconColor: .indigo,
            title: "What to expect"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                expectationRow(
                    icon: "hourglass",
                    title: "3–5 business days",
                    detail: "It typically takes this long for items to be collected from vehicles and delivered to a Lost & Found office."
                )
                expectationRow(
                    icon: "archivebox",
                    title: "Held for 90+ days",
                    detail: "The MTA keeps items for at least 3 months. After that, unclaimed items are auctioned per New York State law."
                )
                expectationRow(
                    icon: "bell.badge",
                    title: "You'll be notified",
                    detail: "If your item is found, you'll get an email with instructions to pick it up or arrange shipping."
                )
                expectationRow(
                    icon: "arrow.clockwise",
                    title: "Check back if not found",
                    detail: "Items sometimes take longer to surface. You can update your claim or file a new one if more time has passed."
                )
            }
        }
    }

    // MARK: - Found Someone Else's Item

    private var foundItemSection: some View {
        sectionCard(
            icon: "hand.raised.fill",
            iconColor: .green,
            title: "Found someone else's item?"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                actionRow(
                    icon: "tram.fill",
                    text: "On the subway?  Hand it to a station booth agent or MTA employee."
                )
                actionRow(
                    icon: "bus.fill",
                    text: "On a bus?  Give it directly to the bus operator."
                )
                actionRow(
                    icon: "phone.fill",
                    text: "Larger or valuable items?  Call 511 and let them know where you found it."
                )
                actionRow(
                    icon: "exclamationmark.triangle.fill",
                    text: "Never open suspicious bags — alert an MTA employee or call 911."
                )
            }
        }
    }

    // MARK: - CTA Buttons

    private var ctaButtons: some View {
        VStack(spacing: 12) {
            Button {
                if let ctx = tripContext {
                    UIPasteboard.general.string = ctx.summary
                }
                showSafari = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 15, weight: .semibold))
                    Text("File a Claim on mta.info")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .foregroundColor(.white)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(
                            LinearGradient(
                                colors: [AppTheme.Colors.mtaBlue, AppTheme.Colors.mtaBlue.opacity(0.85)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .shadow(color: AppTheme.Colors.mtaBlue.opacity(0.25), radius: 8, y: 4)
                )
            }

            if tripContext != nil {
                Text("Trip details auto-copied to your clipboard")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textTertiary)
            }

            // Call 511 row
            Button {
                if let url = URL(string: "tel:511") {
                    UIApplication.shared.open(url)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Call 511")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .foregroundColor(AppTheme.Colors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(AppTheme.Colors.cardFloating)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(AppTheme.Colors.borderSubtle, lineWidth: 0.5)
                        )
                )
            }
        }
    }

    // MARK: - Trip Card

    private func tripCard(_ ctx: TripContext) -> some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: ctx.mode == "bus" ? "bus.fill" : "tram.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(AppTheme.Colors.mtaBlue)
                    Text("Your Trip")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                }
                Spacer()
                copyButton(ctx)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().padding(.horizontal, 14)

            VStack(spacing: 6) {
                infoRow(icon: "arrow.triangle.branch", label: ctx.routeName, accent: true)
                if let dir = ctx.direction {
                    infoRow(icon: "arrow.right", label: dir)
                }
                if let stop = ctx.nearestStop {
                    infoRow(icon: "mappin", label: "Near \(stop)")
                }
                if let fleet = ctx.fleetNumber {
                    infoRow(icon: "number", label: "Vehicle \(fleet)")
                }
                infoRow(icon: "clock", label: {
                    let df = DateFormatter()
                    df.dateStyle = .medium
                    df.timeStyle = .short
                    return df.string(from: Date())
                }())
            }
            .padding(14)
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppTheme.Colors.mtaBlue.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(AppTheme.Colors.mtaBlue.opacity(0.12), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Reusable Components

    /// Card wrapper used for every section.
    private func sectionCard<Content: View>(
        icon: String,
        iconColor: Color,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(iconColor)
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
            }

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppTheme.Colors.cardFloating)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(AppTheme.Colors.borderSubtle, lineWidth: 0.5)
                )
        )
    }

    private func actionRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.Colors.textTertiary)
                .frame(width: 16, alignment: .center)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func checkItem(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppTheme.Colors.mtaBlue.opacity(0.6))
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func expectationRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.indigo.opacity(0.7))
                .frame(width: 16, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func officeRow(
        service: String,
        coverage: String,
        location: String,
        detail: String,
        hours: String,
        phone: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(service)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Text("·")
                    .foregroundColor(AppTheme.Colors.textTertiary)
                Text(coverage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textTertiary)
            }
            HStack(spacing: 4) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(AppTheme.Colors.textTertiary)
                Text("\(location) — \(detail)")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                    Text(hours)
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                }
                HStack(spacing: 4) {
                    Image(systemName: "phone")
                        .font(.system(size: 9))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                    Text(phone)
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.Colors.textTertiary)
                }
            }
        }
    }

    private var thinDivider: some View {
        Rectangle()
            .fill(AppTheme.Colors.borderSubtle)
            .frame(height: 0.5)
    }

    private func step(
        number: String,
        color: Color,
        title: String,
        detail: String,
        isLast: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.12))
                        .frame(width: 26, height: 26)
                    Text(number)
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundColor(color)
                }

                if !isLast {
                    Rectangle()
                        .fill(color.opacity(0.12))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, isLast ? 0 : 16)
        }
    }

    private func copyButton(_ ctx: TripContext) -> some View {
        Button {
            UIPasteboard.general.string = ctx.summary
            withAnimation(.spring(response: 0.3)) { copied = true }
            HapticManager.notification(.success)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { copied = false }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .bold))
                Text(copied ? "Copied!" : "Copy")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
            }
            .foregroundColor(copied ? AppTheme.Colors.successGreen : AppTheme.Colors.mtaBlue)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(
                        copied
                            ? AppTheme.Colors.successGreen.opacity(0.10)
                            : AppTheme.Colors.mtaBlue.opacity(0.08)
                    )
            )
        }
    }

    private func infoRow(icon: String, label: String, accent: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(accent ? AppTheme.Colors.mtaBlue : AppTheme.Colors.textTertiary)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 13, weight: accent ? .bold : .semibold, design: .rounded))
                .foregroundColor(accent ? AppTheme.Colors.textPrimary : AppTheme.Colors.textSecondary)
                .lineLimit(1)
            Spacer()
        }
    }

    // MARK: - URL Resolution

    /// Verify the primary Lost & Found URL is reachable; fall back to mta.info if not.
    private func resolveClaimURL() async {
        var request = URLRequest(url: Self.primaryClaimURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse,
               (200..<400).contains(http.statusCode) {
                return // primary URL is fine
            }
            resolvedClaimURL = Self.fallbackClaimURL
        } catch {
            resolvedClaimURL = Self.fallbackClaimURL
        }
    }
}
