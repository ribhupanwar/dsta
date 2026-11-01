import SwiftUI

private struct LocalCommunityTeam: Identifiable {
    let name: String
    let focus: String
    var id: String { focus + "|" + name }
}

/// Local-first Community UI. Teams are saved on this device only until a backend exists.
struct WoopCommunityScreen: View {
    @AppStorage("pulseforge.community.localTeams") private var storedTeams = ""
    @State private var selectedSection = "MY TEAMS"
    @State private var showingCreateTeam = false
    @State private var teamName = ""
    @State private var teamFocus = "Running"

    private var teams: [LocalCommunityTeam] {
        storedTeams.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return LocalCommunityTeam(name: parts[1], focus: parts[0])
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                header
                sectionPicker
                if selectedSection == "MY TEAMS" {
                    myTeams
                } else {
                    discover
                }
                privacyNote
                Color.clear.frame(height: 112)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
        }
        .background(WoopReplicaPalette.canvas.ignoresSafeArea())
        .sheet(isPresented: $showingCreateTeam) { createTeamSheet }
        .animation(.easeInOut(duration: 0.2), value: selectedSection)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("COMMUNITY")
                    .font(WoopTypography.label(10)).tracking(1.8)
                    .foregroundStyle(WoopReplicaPalette.secondary)
                Spacer()
                Image(systemName: "person.2.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(WoopReplicaPalette.sleep)
                    .frame(width: 40, height: 40)
                    .background(WoopReplicaPalette.surfaceRaised, in: Circle())
            }
            Text("Find your people")
                .font(WoopTypography.emphasis(27))
                .foregroundStyle(WoopReplicaPalette.primary)
            Text("Train together. Share progress. Stay accountable.")
                .font(WoopTypography.body(12))
                .foregroundStyle(WoopReplicaPalette.secondary)
        }
    }

    private var sectionPicker: some View {
        HStack(spacing: 3) {
            pickerButton("MY TEAMS")
            pickerButton("DISCOVER")
        }
        .padding(4)
        .background(WoopReplicaPalette.surfaceInset, in: Capsule())
    }

    private func pickerButton(_ title: String) -> some View {
        Button { selectedSection = title } label: {
            Text(title)
                .font(WoopTypography.label(9)).tracking(0.8)
                .foregroundStyle(selectedSection == title ? WoopReplicaPalette.primary : WoopReplicaPalette.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background {
                    if selectedSection == title {
                        Capsule().fill(WoopReplicaPalette.surfaceRaised)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private var myTeams: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionTitle("YOUR TEAMS")
                Spacer()
                Text("\(teams.count) CREATED")
                    .font(WoopTypography.label(8)).tracking(0.7)
                    .foregroundStyle(WoopReplicaPalette.muted)
            }

            if teams.isEmpty {
                emptyState(
                    icon: "person.3.sequence.fill",
                    title: "Your team starts here",
                    message: "Create a training group and keep its details on this device. Shared membership and live team feeds need a Community service."
                )
            } else {
                ForEach(teams) { team in
                    HStack(spacing: 12) {
                        Image(systemName: "figure.run")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(WoopReplicaPalette.sleep)
                            .frame(width: 43, height: 43)
                            .background(WoopReplicaPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 13))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(team)
                                .font(WoopTypography.emphasis(14))
                                .foregroundStyle(WoopReplicaPalette.primary)
                            Text("LOCAL TEAM · \(team.focus.uppercased())")
                                .font(WoopTypography.label(8)).tracking(0.7)
                                .foregroundStyle(WoopReplicaPalette.secondary)
                        }
                        Spacer()
                        Image(systemName: "iphone")
                            .font(.system(size: 12))
                            .foregroundStyle(WoopReplicaPalette.muted)
                    }
                    .padding(13)
                    .background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(WoopReplicaPalette.hairline, lineWidth: 1))
                }
            }

            Button { showingCreateTeam = true } label: {
                Label("CREATE A TEAM", systemImage: "plus")
                    .font(WoopTypography.label(10)).tracking(0.8)
                    .foregroundStyle(WoopReplicaPalette.canvas)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(WoopReplicaPalette.recoveryHigh, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(WoopReplicaPalette.hairline, lineWidth: 1))
    }

    private var discover: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("DISCOVER")
            emptyState(
                icon: "globe",
                title: "Community service not connected",
                message: "Discovering public teams, joining groups, leaderboards and shared activity requires a secure backend. PulseForge will not display invented members or activity."
            )
            HStack(spacing: 10) {
                featurePill("RUN CLUBS", icon: "figure.run")
                featurePill("CHALLENGES", icon: "trophy")
                featurePill("LEADERBOARDS", icon: "chart.bar")
            }
        }
        .padding(16)
        .background(WoopReplicaPalette.surface, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(WoopReplicaPalette.hairline, lineWidth: 1))
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(WoopReplicaPalette.sleep)
                .frame(width: 64, height: 64)
                .background(WoopReplicaPalette.surfaceInset, in: Circle())
            Text(title)
                .font(WoopTypography.emphasis(17))
                .foregroundStyle(WoopReplicaPalette.primary)
            Text(message)
                .font(WoopTypography.body(11))
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .foregroundStyle(WoopReplicaPalette.secondary)
                .frame(maxWidth: 285)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 12)
        .background(WoopReplicaPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 16))
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(WoopReplicaPalette.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("YOUR SCORES, YOUR CHOICE")
                    .font(WoopTypography.label(9)).tracking(0.8)
                    .foregroundStyle(WoopReplicaPalette.primary)
                Text("No health or workout data is published from this screen. Local teams stay on this device.")
                    .font(WoopTypography.body(10))
                    .lineSpacing(3)
                    .foregroundStyle(WoopReplicaPalette.secondary)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WoopReplicaPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 15))
    }

    private var createTeamSheet: some View {
        NavigationStack {
            Form {
                Section("TEAM DETAILS") {
                    TextField("Team name", text: $teamName)
                        .textInputAutocapitalization(.words)
                    Picker("Focus", selection: $teamFocus) {
                        Text("Running").tag("Running")
                        Text("Strength").tag("Strength")
                        Text("General fitness").tag("General fitness")
                    }
                }
                Section {
                    Text("This creates a private local team entry on this iPhone. Invites, member lists and shared feeds are not active until a Community backend is connected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(WoopReplicaPalette.canvas)
            .navigationTitle("Create a team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingCreateTeam = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let cleaned = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cleaned.isEmpty else { return }
                        let safeName = cleaned.replacingOccurrences(of: "|", with: "-").replacingOccurrences(of: "\n", with: " ")
                        storedTeams = (teams.map { "\($0.focus)|\($0.name)" } + ["\(teamFocus)|\(safeName)"]).joined(separator: "\n")
                        teamName = ""
                        showingCreateTeam = false
                        selectedSection = "MY TEAMS"
                    }
                    .disabled(teamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .preferredColorScheme(.dark)
        }
        .presentationDetents([.medium, .large])
    }

    private func featurePill(_ title: String, icon: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 14))
            Text(title).font(WoopTypography.label(7)).tracking(0.3)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(WoopReplicaPalette.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(WoopReplicaPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(WoopTypography.label(9)).tracking(1.1)
            .foregroundStyle(WoopReplicaPalette.secondary)
    }
}
