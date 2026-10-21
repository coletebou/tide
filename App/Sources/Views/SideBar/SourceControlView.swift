import SwiftUI
import TideCore
import TideSSH

/// The Source Control view: branch, staged and unstaged changes, read from
/// the workspace's `.git` folder. Tapping a change opens its diff.
struct SourceControlView: View {
    @Bindable var workbench: Workbench
    @Bindable var scm: SourceControlModel
    @Environment(\.theme) private var theme
    @State private var stagedExpanded = true
    @State private var changesExpanded = true

    var body: some View {
        Group {
            if !scm.isRepository {
                VStack(alignment: .leading, spacing: 12) {
                    Text("The folder currently open doesn't have a git repository.")
                    Text("Tide reads git repositories directly from the .git folder. Clone a repository on your Mac or with Working Copy, then open its folder here.")
                        .foregroundStyle(theme.color("descriptionForeground"))
                }
                .font(.system(size: 13))
                .padding(16)
                Spacer()
            } else {
                VStack(spacing: 0) {
                    if let branch = scm.branch {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.branch")
                            Text(branch).font(.system(size: 13, weight: .semibold))
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                    }
                    ScrollView {
                        VStack(spacing: 0) {
                            if !scm.stagedChanges.isEmpty {
                                PaneHeader(title: "Staged Changes", isExpanded: $stagedExpanded)
                                if stagedExpanded { ForEach(scm.stagedChanges) { change in row(change) } }
                            }
                            PaneHeader(title: "Changes", isExpanded: $changesExpanded)
                            if changesExpanded {
                                if scm.unstagedChanges.isEmpty {
                                    Text("No changes").font(.system(size: 12)).foregroundStyle(theme.color("descriptionForeground")).padding(12)
                                }
                                ForEach(scm.unstagedChanges) { change in row(change) }
                            }
                        }
                    }
                }
            }
        }
        .task(id: workbench.workspace.name) { await scm.refresh() }
    }

    private func row(_ change: SourceControlModel.Change) -> some View {
        Button {
            // Untracked and intent-to-add files have nothing to compare with yet.
            if change.kind == .untracked || (change.kind == .added && !change.staged) {
                Task { await workbench.open(change.path, preview: true) }
            } else {
                workbench.open(.diff(change.path, staged: change.staged))
            }
        } label: {
            HStack(spacing: 6) {
                FileIcon(name: WorkspacePath.name(of: change.path), size: 13)
                Text(WorkspacePath.name(of: change.path)).font(.system(size: 13)).lineLimit(1)
                    .strikethrough(change.kind == .deleted)
                Text(WorkspacePath.parent(of: change.path)).font(.system(size: 11)).foregroundStyle(theme.color("descriptionForeground")).lineLimit(1)
                Spacer()
                Text(change.kind.rawValue).font(.system(size: 12, weight: .semibold)).foregroundStyle(color(change.kind))
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("scm-change-\(change.id)")
    }

    private func color(_ kind: SourceControlModel.ChangeKind) -> Color {
        switch kind {
        case .modified, .renamed: theme.color("gitDecoration.modifiedResourceForeground")
        case .added: theme.color("gitDecoration.addedResourceForeground")
        case .untracked: theme.color("gitDecoration.untrackedResourceForeground")
        case .deleted: theme.color("gitDecoration.deletedResourceForeground")
        case .conflicted: theme.color("gitDecoration.conflictingResourceForeground")
        }
    }
}

/// The Remote Explorer: SSH hosts, like Termius's host list, and the key
/// Tide logs in with.
struct RemoteExplorerView: View {
    @Bindable var workbench: Workbench
    @Environment(\.theme) private var theme
    private let ssh = RemoteSSH.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SSH hosts").font(.system(size: 13, weight: .semibold))
            Text("Connect to a host to open its shell in the terminal panel.")
                .font(.system(size: 12))
                .foregroundStyle(theme.color("descriptionForeground"))
            actionButton("Connect to Host...", symbol: "plus", id: "remote-connect") { workbench.run("remote-ssh.connectToHost") }
            if !ssh.recentHosts.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(ssh.recentHosts, id: \.self) { target in
                        Button {
                            workbench.connect(to: target)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "server.rack").font(.system(size: 11))
                                Text(target.description).font(.system(size: 12)).lineLimit(1)
                                Spacer()
                            }
                            .frame(height: 22)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("remote-host-\(target)")
                    }
                }
            }
            Rectangle().fill(theme.color("sideBarSectionHeader.border")).frame(height: 1)
            Text("SSH key").font(.system(size: 13, weight: .semibold))
            if let key = ssh.key {
                Text("\(key.typeName) key in the Keychain. Add its public key to ~/.ssh/authorized_keys on each host.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.color("descriptionForeground"))
                actionButton("Copy Public Key", symbol: "doc.on.doc", id: "remote-copy-key") { workbench.run("remote-ssh.copyPublicKey") }
            } else {
                Text("Tide has no key yet. Create one, or import an Ed25519 or ECDSA key from the clipboard. Without a key Tide asks for passwords.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.color("descriptionForeground"))
                actionButton("Create SSH Key", symbol: "key", id: "remote-create-key") { workbench.run("remote-ssh.createKey") }
                actionButton("Import from Clipboard", symbol: "doc.on.clipboard", id: "remote-import-key") { workbench.run("remote-ssh.importKey") }
            }
            Spacer()
        }
        .padding(16)
    }

    private func actionButton(_ title: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 3).fill(theme.color("button.background")))
                .foregroundStyle(theme.color("button.foreground"))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// The secondary side bar, where the chat assistant lives (as in VS Code).
struct SecondarySideBar: View {
    @Bindable var workbench: Workbench
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CHAT").font(.system(size: 11)).foregroundStyle(theme.color("sideBarTitle.foreground"))
            Text("Ask about your workspace, edit files and run commands with an AI assistant.")
                .font(.system(size: 12))
                .foregroundStyle(theme.color("descriptionForeground"))
            Spacer()
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.color("sideBar.background"))
    }
}
