import AmyrlinCore
import SwiftUI

/// The middle column with nothing open: the projects on every machine, recent ones first, with what the task list
/// doesn't show: each checkout's state, since uncommitted files stay behind when a sandbox starts and a checkout
/// behind its upstream needs a pull. A click narrows the list to the project; New task starts one in it.
struct ProjectsHome: View {
	let model: AppModel

	private var connected: [AppModel.Machine] { model.machines.filter { $0.store.info != nil } }

	var body: some View {
		let table = ProjectTable.rows(
			connected.map { ProjectSpotlight.Source(machine: $0.id, projects: $0.store.projects, sessions: Array($0.store.state.conversations.values)) },
			ships: { machine, id in model.machine(machine)?.store.state.ship(id) },
			all: model.showAllProjects
		)
		ScrollView {
			VStack(alignment: .leading, spacing: 0) {
				HStack(alignment: .firstTextBaseline, spacing: 10) {
					Text("Projects").font(Typography.uiSansStrong).foregroundStyle(Palette.ink)
					Text(model.showAllProjects ? "all" : "active in the last \(ProjectTable.recentDays) days")
						.font(Typography.uiSmall).foregroundStyle(Palette.ink3)
					Spacer()
					if let maker = connected.first(where: { $0.store.newProjects != nil }) {
						BracketButton("+ new project", color: Palette.ink2) { model.creatingProject = .create(machine: maker.id) }
							.help("Make a project on \(model.name(of: maker)), with a private GitHub repository")
					}
					if table.hidden > 0 || model.showAllProjects {
						BracketButton(model.showAllProjects ? "recent only" : "show all \(table.rows.count + table.hidden)") {
							model.showAllProjects.toggle()
						}
					}
				}
				.padding(.bottom, 12)
				header
				ForEach(table.rows) { row in
					ProjectTableRow(model: model, row: row)
				}
				if table.rows.isEmpty {
					Text(connected.isEmpty ? "No machine is connected" : "Nothing active lately. Show all to see every project.")
						.font(Typography.ui).foregroundStyle(Palette.ink3).padding(.vertical, 12)
				}
			}
			.padding(.horizontal, 28)
			.padding(.vertical, 22)
			.frame(maxWidth: 1100, alignment: .leading)
		}
	}

	private var header: some View {
		HStack(spacing: 0) {
			Text("project").frame(width: Columns.project, alignment: .leading)
			Text("tasks").frame(width: Columns.tasks, alignment: .leading)
			Text("checkout").frame(maxWidth: .infinity, alignment: .leading)
			Text("last").frame(width: Columns.last, alignment: .leading)
			Color.clear.frame(width: Columns.action)
		}
		.font(Typography.label)
		.textCase(.uppercase)
		.foregroundStyle(Palette.ink3)
		.padding(.horizontal, 8)
		.padding(.bottom, 6)
		.overlay(alignment: .bottom) { Rectangle().fill(Palette.rule).frame(height: 1) }
	}

	@MainActor enum Columns {
		static var project: CGFloat { 200 * Typography.scale }
		static var tasks: CGFloat { 150 * Typography.scale }
		static var last: CGFloat { 250 * Typography.scale }
		static var action: CGFloat { 90 * Typography.scale }
	}
}

private struct ProjectTableRow: View {
	let model: AppModel
	let row: ProjectTable.Row<UUID>
	@State private var hovering = false

	private var colors: [String: Int] { model.machine(row.machine)?.store.state.projectColors ?? [:] }

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 0) {
			VStack(alignment: .leading, spacing: 1) {
				HStack(spacing: 6) {
					Text(row.project.name).foregroundStyle(Palette.project(row.project.name, in: colors))
					if let tag = model.machineTag(row.machine) { Text(tag).foregroundStyle(Palette.ink3) }
				}
				Text(row.project.path).font(Typography.uiSmall).foregroundStyle(Palette.ink3).truncationMode(.head)
			}
			.frame(width: ProjectsHome.Columns.project, alignment: .leading)
			tasks.frame(width: ProjectsHome.Columns.tasks, alignment: .leading)
			checkout.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 12)
			VStack(alignment: .leading, spacing: 1) {
				if let title = row.lastTitle, let at = row.lastActive {
					Text(title).foregroundStyle(Palette.ink2).truncationMode(.tail)
					Text(Date(timeIntervalSince1970: TimeInterval(at) / 1000).shortAge).font(Typography.uiSmall).foregroundStyle(Palette.ink3)
				} else {
					Text("·").foregroundStyle(Palette.ink3)
				}
			}
			.frame(width: ProjectsHome.Columns.last, alignment: .leading)
			BracketButton("new task") { model.newTask(in: row.project, on: row.machine) }
				.opacity(hovering ? 1 : 0)
				.frame(width: ProjectsHome.Columns.action, alignment: .trailing)
		}
		.font(Typography.ui)
		.lineLimit(1)
		.padding(.horizontal, 8)
		.padding(.vertical, 7)
		.background(hovering ? Palette.paper2 : .clear)
		.overlay(alignment: .bottom) { Rectangle().fill(Palette.rule).frame(height: 1).opacity(0.6) }
		.contentShape(Rectangle())
		.onHover { hovering = $0 }
		.onTapGesture { model.scope = .project(machine: row.machine, name: row.project.name) }
		.help("Show \(row.project.name)'s tasks in the list")
	}

	@ViewBuilder private var tasks: some View {
		let parts: [(String, Color)] = TaskGroups.Group.allCases.compactMap { group in
			guard let count = row.counts[group], count > 0, group != .done else { return nil }
			let color: Color = switch group {
			case .needsYou: Palette.wait
			case .running: Palette.accent
			case .ready: Palette.add
			case .done: Palette.ink3
			}
			return ("\(count) \(group.title)", color)
		}
		if parts.isEmpty {
			Text("·").foregroundStyle(Palette.ink3)
		} else {
			HStack(spacing: 0) {
				ForEach(parts.indices, id: \.self) { index in
					if index > 0 { Text(" · ").foregroundStyle(Palette.ink3) }
					Text(parts[index].0).foregroundStyle(parts[index].1)
				}
			}
		}
	}

	@ViewBuilder private var checkout: some View {
		if let checkout = row.project.checkout {
			let base = checkout.branch ?? (checkout.sandboxRefusal == "it isn't in git" ? "no git" : "detached")
			let notes: [(String, Bool)] = [
				checkout.dirty > 0 ? ("\(checkout.dirty) uncommitted", true) : nil,
				checkout.ahead > 0 ? ("\(checkout.ahead) ahead", false) : nil,
				checkout.behind > 0 ? ("\(checkout.behind) behind", true) : nil,
			].compactMap(\.self)
			HStack(spacing: 0) {
				Text(base).foregroundStyle(Palette.ink2).truncationMode(.middle)
				if notes.isEmpty, checkout.branch != nil {
					Text(" · clean").foregroundStyle(Palette.ink3)
				}
				ForEach(notes.indices, id: \.self) { index in
					Text(" · ").foregroundStyle(Palette.ink3)
					Text(notes[index].0).foregroundStyle(notes[index].1 ? Palette.wait : Palette.ink3)
				}
				// Only where its machine has sandboxes: on one without, every project is here only.
				if let refusal = checkout.sandboxRefusal, checkout.branch != nil, model.machine(row.machine)?.store.sandboxes != nil {
					Text(" · here only").foregroundStyle(Palette.ink3).help(refusal)
				}
			}
			.help([checkout.upstream.map { "against \($0) as last fetched" }, checkout.sandboxRefusal.map { "No sandbox: \($0)" }].compactMap(\.self).joined(separator: "\n"))
		} else {
			Text("·").foregroundStyle(Palette.ink3)
		}
	}
}
