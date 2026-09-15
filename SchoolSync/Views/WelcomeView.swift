import SwiftUI

/// The one question a fresh install has to ask: is this the phone that runs the
/// schedule, or a phone that follows one?
///
/// Shown only when there's genuinely nothing to go on — no kids, no backend, no
/// viewer token. An install that's already been used answers the question by
/// existing, and gets straight to Morning Mode as it always has.
struct WelcomeView: View {
    @AppStorage(ViewerSettings.hasChosenRoleKey) private var hasChosenRole = false
    @State private var isJoining = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 10) {
                    Image(systemName: "sun.horizon")
                        .font(.system(size: 52))
                        .foregroundStyle(.orange)
                    Text("SchoolSync")
                        .font(.largeTitle.weight(.semibold))
                    Text("What each kid needs today, before you're out the door.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Spacer()

                VStack(spacing: 14) {
                    Button {
                        hasChosenRole = true
                    } label: {
                        VStack(spacing: 3) {
                            Text("Set this up").font(.headline)
                            Text("Add your kids and their schools")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)

                    NavigationLink {
                        JoinHouseholdView()
                    } label: {
                        VStack(spacing: 3) {
                            Text("Join with a code").font(.headline)
                            Text("Someone shared their family's schedule with you")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 24)

                // Neither choice is a trap. Setting up is just the normal app,
                // and joining can be undone from Settings — so nobody has to
                // work out which they are before they've seen either.
                Text("You can change this later.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 24)
            }
        }
    }
}

#Preview {
    WelcomeView()
}
