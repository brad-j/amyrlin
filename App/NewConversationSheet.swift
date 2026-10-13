import AmyrlinCore
import SwiftUI

/// Identifiable wrapper so a machine can drive `.sheet(item:)`.
struct MachineRef: Identifiable {
	let machine: AppModel.Machine
	var id: UUID { machine.id }
}

/// Picks a project: a rail of groups (Recent, then each folder) and the group's projects; typing searches them all.
/// ↑↓ move, Return or a double-click opens an empty conversation for the project in the main pane.
struct NewConversationSheet: View {
	let model: AppModel
	let machine: AppModel.Machine
	@Environment(\.dismiss) private var dismiss
	@State private var query = ""
	@State private var group: String?
	@State private var selected: String?
	@FocusState private var searchFocused: Bool

	private var projects: [ProjectInfo] { machine.store.info?.projects ?? [] }
	private var sessions: [ConversationSummary] { Array(machine.store.state.conversations.values) }
	private var groups: [ProjectCatalog.Group] { ProjectCatalog.groups(projects: projects, sessions: sessions) }
	private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

	/// What the list shows: the search's groups, or the picked group.
	private var shown: [ProjectCatalog.Group] {
		if searching { return ProjectCatalog.search(query, projects: projects, sessions: sessions) }
		let id = group ?? groups.first?.id
		return groups.filter { $0.id == id }
	}

	private var flat: [ProjectCatalog.Entry] { shown.flatMap(\.entries) }

	/// The "no project" row's selection ID: project rows use their directory, never empty.
	private static let noProjectID = ""
	/// "No project" heads the list, unless a search clearly means something else.
	private var showNoProject: Bool { !searching || "no project".contains(query.trimmingCharacters(in: .whitespaces).lowercased()) }
	/// Every row's ID in order, for the arrow keys.
	private var rowIDs: [String] { (showNoProject ? [Self.noProjectID] : []) + flat.map(\.id) }

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 10) {
				Text("/").font(Typography.uiStrong).foregroundStyle(Palette.accent)
				TextField("Find a project on \(machine.store.state.host?.name ?? "this machine")", text: $query)
					.textFieldStyle(.plain)
					.font(Typography.ui)
					.focused($searchFocused)
					.onSubmit { openRow(selected ?? rowIDs.first) }
					.onKeyPress(.downArrow) { move(1) }
					.onKeyPress(.upArrow) { move(-1) }
					.onChange(of: query) { _, _ in selected = rowIDs.first }
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 13)
			Rectangle().fill(Palette.rule).frame(height: 1)
			HStack(spacing: 0) {
				rail
				Rectangle().fill(Palette.rule).frame(width: 1)
				list
			}
			Rectangle().fill(Palette.rule).frame(height: 1)
			HStack(spacing: 8) {
				Text("↑↓ move · ↵ open · the session starts when you send")
					.font(Typography.label)
					.foregroundStyle(Palette.ink3)
				Spacer()
				Button("esc cancel") { dismiss() }
					.buttonStyle(QuietButton())
					.keyboardShortcut(.cancelAction)
				Button("↵ open") { openRow(selected) }
					.buttonStyle(QuietButton(fill: Palette.accent, ink: Palette.accentInk))
					.keyboardShortcut(.defaultAction)
					.disabled(selected == nil)
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 10)
		}
		.frame(width: 700 * Typography.scale, height: 460 * Typography.scale)
		.background(Palette.paper)
		.onAppear {
			searchFocused = true
			selected = rowIDs.first
		}
	}

	private var rail: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 2) {
				ForEach(groups) { item in
					let current = !searching && (group ?? groups.first?.id) == item.id
					Button {
						group = item.id
						query = ""
						selected = item.entries.first?.id
					} label: {
						HStack {
							Text(item.title)
								.font(Typography.ui)
								.foregroundStyle(current ? Palette.ink : Palette.ink2)
							Spacer()
							Text("\(item.entries.count)")
								.font(Typography.label)
								.foregroundStyle(Palette.ink3)
								.monospacedDigit()
						}
						.padding(.horizontal, 10)
						.padding(.vertical, 7)
						.background(current ? Palette.paper3 : .clear, in: RoundedRectangle(cornerRadius: Metrics.radiusRow))
						.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
				}
			}
			.padding(8)
		}
		.frame(width: 190 * Typography.scale)
		.background(Palette.panel)
	}

	private var list: some View {
		ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 0) {
					if showNoProject {
						NoProjectRow(selected: selected == Self.noProjectID)
							.id(Self.noProjectID)
							.onTapGesture(count: 2) { openRow(Self.noProjectID) }
							.onTapGesture { selected = Self.noProjectID }
					}
					if flat.isEmpty && !showNoProject {
						Text(searching ? "No project matches \u{201C}\(query)\u{201D}" : "No projects")
							.font(Typography.ui)
							.foregroundStyle(Palette.ink3)
							.padding(16)
					}
					ForEach(shown) { section in
						if searching || shown.count > 1 {
							Text(section.title)
								.font(Typography.label)
								.foregroundStyle(Palette.ink3)
								.textCase(.uppercase)
								.padding(.horizontal, 12)
								.padding(.top, 12)
								.padding(.bottom, 4)
						}
						ForEach(section.entries) { entry in
							ProjectRow(entry: entry, selected: selected == entry.id)
								.id(entry.id)
								.onTapGesture(count: 2) { open(entry.project) }
								.onTapGesture { selected = entry.id }
						}
					}
				}
				.padding(8)
			}
			.onChange(of: selected) { _, id in
				if let id { proxy.scrollTo(id) }
			}
		}
	}

	private func move(_ step: Int) -> KeyPress.Result {
		let ids = rowIDs
		guard !ids.isEmpty else { return .ignored }
		let index = selected.flatMap { ids.firstIndex(of: $0) } ?? (step > 0 ? -1 : ids.count)
		selected = ids[min(max(index + step, 0), ids.count - 1)]
		return .handled
	}

	private func open(_ project: ProjectInfo?) {
		guard let project else { return }
		model.openDraft(on: machine.id, project: project)
		dismiss()
	}

	/// Opens the row `id` names: "no project", or a project by its directory.
	private func openRow(_ id: String?) {
		guard let id else { return }
		if id == Self.noProjectID {
			model.openDraft(on: machine.id, project: nil)
			dismiss()
		} else {
			open(flat.first { $0.id == id }?.project)
		}
	}
}

/// The picker's first row: a session in no project, in a scratch directory of its own on the host.
private struct NoProjectRow: View {
	let selected: Bool

	var body: some View {
		HStack(spacing: 10) {
			Circle().strokeBorder(Palette.ink3, lineWidth: 1.5).frame(width: 8, height: 8)
			Text("no project").font(Typography.ui).foregroundStyle(Palette.ink)
			Text("a scratch directory of its own").font(Typography.uiSmall).foregroundStyle(Palette.ink3)
			Spacer(minLength: 8)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(selected ? Palette.paper3 : .clear)
		.contentShape(Rectangle())
	}
}

private struct ProjectRow: View {
	let entry: ProjectCatalog.Entry
	let selected: Bool

	var body: some View {
		HStack(spacing: 10) {
			Circle().fill(Palette.project(entry.project.name)).frame(width: 8, height: 8)
			Text(entry.project.name)
				.font(Typography.ui)
				.foregroundStyle(Palette.ink)
				.lineLimit(1)
			Text(entry.project.path)
				.font(Typography.codeSmall)
				.foregroundStyle(Palette.ink3)
				.lineLimit(1)
				.truncationMode(.head)
			Spacer(minLength: 8)
			if entry.sessions > 0 {
				Text(sessionsText)
					.font(Typography.label)
					.foregroundStyle(Palette.ink3)
					.monospacedDigit()
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(selected ? Palette.projectWash(entry.project.name) : .clear, in: RoundedRectangle(cornerRadius: Metrics.radiusRow))
		.contentShape(Rectangle())
	}

	private var sessionsText: String {
		let count = entry.sessions == 1 ? "1 session" : "\(entry.sessions) sessions"
		guard let last = entry.lastActive else { return count }
		return "\(count) · \(Date(timeIntervalSince1970: TimeInterval(last) / 1000).shortAge)"
	}
}

/// An empty conversation for a project. Sending the first message creates it on the host and switches to it.
struct DraftView: View {
	let model: AppModel
	let machine: AppModel.Machine
	/// Nil for a no-project session.
	let project: ProjectInfo?
	@State private var text = ""
	@State private var sending = false
	@FocusState private var focused: Bool

	var body: some View {
		VStack(spacing: 0) {
			VStack(spacing: 6) {
				Text(project?.name ?? "no project")
					.font(Typography.uiStrong)
					.foregroundStyle(project.map { Palette.project($0.name) } ?? Palette.ink2)
				Text(project.map { ConversationView.shortPath($0.dir) } ?? "a scratch directory of its own, on \(machine.store.state.host?.name ?? "the host")")
					.font(Typography.code)
					.foregroundStyle(Palette.tertiaryText)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			VStack(alignment: .leading, spacing: 4) {
				TextField("Message", text: $text, axis: .vertical)
					.textFieldStyle(.plain)
					.font(Typography.ui)
					.lineLimit(1...10)
					.focused($focused)
					.disabled(sending)
					.onKeyPress(.return, phases: .down) { press in
						if press.modifiers.contains(.option) || press.modifiers.contains(.shift) { return .ignored }
						send()
						return .handled
					}
					.padding(10)
					.background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radius))
					.overlay(RoundedRectangle(cornerRadius: Metrics.radius).stroke(focused ? Palette.accent.opacity(0.5) : Palette.hairline))
				Text(sending ? "Starting…" : "Return starts the conversation · ⌥Return new line")
					.font(Typography.label)
					.foregroundStyle(Palette.tertiaryText)
					.padding(.horizontal, 2)
			}
			.padding(.horizontal, 16)
			.padding(.top, 8)
			.padding(.bottom, 10)
		}
		.background(Palette.background)
		.onAppear { focused = true }
	}

	private func send() {
		let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !message.isEmpty, !sending else { return }
		sending = true
		Task {
			if !(await model.startConversation(on: machine, project: project?.dir, text: message)) { sending = false }
		}
	}
}
