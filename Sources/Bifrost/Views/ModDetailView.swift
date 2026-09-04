import SwiftUI

/// Full detail view for a single Thunderstore package: description,
/// version/dependency info, a link out to the Thunderstore page, and an
/// Install button placeholder (wired up in a later phase).
struct ModDetailView: View {
    let package: ThunderstorePackage
    let iconURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let version = package.latestVersion {
                    GroupBox("Version") {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("Latest", value: version.versionNumber)
                            LabeledContent("Downloads", value: version.downloads.formatted())
                            LabeledContent("Size", value: byteFormatter.string(fromByteCount: Int64(version.fileSize)))

                            if !version.dependencies.isEmpty {
                                Divider()
                                Text("Dependencies")
                                    .font(.subheadline.weight(.semibold))
                                ForEach(version.dependencies, id: \.self) { dependency in
                                    Text(dependency)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let description = package.latestVersion?.description, !description.isEmpty {
                    GroupBox("Description") {
                        Text(description)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                }

                HStack(spacing: 12) {
                    Link(destination: package.packageURL) {
                        Label("Open on Thunderstore", systemImage: "arrow.up.right.square")
                    }

                    Spacer()

                    Button {
                        // Install flow wired up in a later phase.
                    } label: {
                        Label("Install", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                    .help("Coming in a later phase")
                }
            }
            .padding(24)
        }
        .navigationTitle(package.name)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ModIconView(url: iconURL, size: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(package.name)
                    .font(.title2.bold())
                Text("by \(package.owner)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Label("\(package.totalDownloads.formatted())", systemImage: "arrow.down.circle")
                    Label("\(package.ratingScore.formatted())", systemImage: "star.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var byteFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }
}

/// Shared icon view used by both the browse list rows and the detail
/// header.
struct ModIconView: View {
    let url: URL?
    var size: CGFloat = 44

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            default:
                RoundedRectangle(cornerRadius: size * 0.2)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "shippingbox")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
    }
}
