import Foundation

/// Saved swarm templates + launching them into a grid. A "swarm" is just a set
/// of role-tagged panes opened side by side (parallel panes you orchestrate —
/// no agent-to-agent mailbox). Mirrors BookmarksManager.
@MainActor
final class SwarmManager: ObservableObject {
    @Published private(set) var templates: [SwarmTemplate] = []
    private let cache: SessionCache?

    init(cache: SessionCache?) {
        self.cache = cache
        templates = cache?.loadSwarmTemplates() ?? []
    }

    func create(_ template: SwarmTemplate) {
        templates.insert(template, at: 0)
        cache?.saveSwarmTemplate(template)
    }

    func delete(_ id: UUID) {
        templates.removeAll { $0.id == id }
        cache?.deleteSwarmTemplate(id: id)
    }

    /// A built-in starter so the feature is usable before anyone builds a custom
    /// template: three role-tagged shells in a grid.
    static func starter() -> SwarmTemplate {
        let layout = GridLayout.fit(3)
        let roles: [PaneRole] = [.builder, .reviewer, .scout]
        let specs = roles.enumerated().map { i, role in
            SwarmRoleSpec(role: role, agent: .shell, gridPosition: layout.position(for: i))
        }
        return SwarmTemplate(name: "Builder · Reviewer · Scout", layout: layout, specs: specs)
    }

    /// Open every spec as a role-tagged pane in the active grid. Spec panes are
    /// shells (a fresh agent self-identifies via the live-session linker once
    /// launched); an optional initialPrompt is injected after a short delay so
    /// the shell is ready to receive it.
    func launch(_ template: SwarmTemplate, into spawner: PaneSpawning, baseCWD: URL?) {
        let fallback = baseCWD ?? URL(fileURLWithPath: NSHomeDirectory())
        for spec in template.specs {
            let cwd = spec.cwd.map { URL(fileURLWithPath: $0) } ?? fallback
            let paneID = spawner.spawnPane(
                Conversation.shellConversation(cwd: cwd), role: spec.role, at: spec.gridPosition)
            if let prompt = spec.initialPrompt, !prompt.isEmpty {
                let text = prompt.hasSuffix("\n") ? prompt : prompt + "\n"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    spawner.sendText(text, toPaneID: paneID)
                }
            }
        }
    }
}
