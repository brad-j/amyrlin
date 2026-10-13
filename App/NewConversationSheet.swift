import AmyrlinCore
import SwiftUI

/// Identifiable wrapper so a machine can drive `.sheet(item:)`.
struct MachineRef: Identifiable {
	let machine: AppModel.Machine
	var id: UUID { machine.id }
}

/// Picks a project. Return or a double-click opens an empty conversation for it in the main pane.
struct NewConversationSheet: View {
	let model: AppModel
	let machine: AppModel.Machine
	@Environment(\.dismiss) private var dismiss
	@State private var query = ""
	@State private var selected: String?
	@FocusState private var searchFocused: Bool

	private var projects: [ProjectInfo] { machine.store.info?.projects ?? [] }

	private var filtered: [ProjectInfo] {
		let words = query.lowercased().split(separator: " ")
		guard !words.isEmpty else { return projects }
		return projects.filter { project in
			let haystack = "\(project.path) \(project.workspace)".lowercased()
			return words.allSatisfy { haystack.contains($0) }
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("New conversation on \(machine.store.state.host?.name ?? machine.url.host() ?? "this machine")")
				.font(.headline)
			TextField("Find a project", text: $query)
				.textFieldStyle(.roundedBorder)
				.focused($searchFocused)
				.onSubmit { open(selected ?? filtered.first?.dir) }
				.onChange(of: query) { _, _ in selected = filtered.first?.dir }
				.onKeyPress(.downArrow) { move(1) }
				.onKeyPress(.upArrow) { move(-1) }
			List(filtered, selection: $selected) { item in
				HStack {
					Circle().fill(Palette.project(item.name)).frame(width: 7, height: 7)
					Text(item.name).font(Typography.reading)
					Spacer()
					Text(item.path).font(Typography.label).foregroundStyle(Palette.tertiaryText)
				}
				.tag(item.dir)
				.contentShape(Rectangle())
				.simultaneousGesture(TapGesture(count: 2).onEnded { open(item.dir) })
			}
			.frame(height: 320)
			HStack {
				Text("Return opens it · the conversation starts when you send")
					.font(Typography.label)
					.foregroundStyle(Palette.tertiaryText)
				Spacer()
				Button("Cancel", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Button("Open") { open(selected) }
					.keyboardShortcut(.defaultAction)
					.disabled(selected == nil)
			}
		}
		.padding(20)
		.frame(width: 560)
		.onAppear {
			searchFocused = true
			selected = filtered.first?.dir
		}
	}

	private func move(_ step: Int) -> KeyPress.Result {
		let dirs = filtered.map(\.dir)
		guard !dirs.isEmpty else { return .ignored }
		let index = selected.flatMap { dirs.firstIndex(of: $0) } ?? (step > 0 ? -1 : dirs.count)
		selected = dirs[min(max(index + step, 0), dirs.count - 1)]
		return .handled
	}

	private func open(_ dir: String?) {
		guard let dir, let project = projects.first(where: { $0.dir == dir }) else { return }
		model.openDraft(on: machine.id, project: project)
		dismiss()
	}
}

/// An empty conversation for a project. Sending the first message creates it on the host and switches to it.
struct DraftView: View {
	let model: AppModel
	let machine: AppModel.Machine
	let project: ProjectInfo
	@State private var text = ""
	@State private var sending = false
	@FocusState private var focused: Bool

	var body: some View {
		VStack(spacing: 0) {
			VStack(spacing: 6) {
				Text(project.name)
					.font(Typography.reading.weight(.semibold))
					.foregroundStyle(Palette.project(project.name))
				Text(project.dir)
					.font(Typography.code)
					.foregroundStyle(Palette.tertiaryText)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			VStack(alignment: .leading, spacing: 4) {
				TextField("Message", text: $text, axis: .vertical)
					.textFieldStyle(.plain)
					.font(Typography.reading)
					.lineLimit(1...10)
					.focused($focused)
					.disabled(sending)
					.onKeyPress(.return, phases: .down) { press in
						if press.modifiers.contains(.option) || press.modifiers.contains(.shift) { return .ignored }
						send()
						return .handled
					}
					.padding(10)
					.background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
					.overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? Palette.accent.opacity(0.5) : Palette.hairline))
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
		.navigationTitle("New conversation")
		.navigationSubtitle(project.path)
		.onAppear { focused = true }
	}

	private func send() {
		let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !message.isEmpty, !sending else { return }
		sending = true
		Task {
			if !(await model.startConversation(on: machine, project: project.dir, text: message)) { sending = false }
		}
	}
}
