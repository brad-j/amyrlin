import AmyrlinCore
import SwiftUI

/// Finds a project on any connected machine (⌘/): typing narrows the list by fuzzy match (ProjectSpotlight), with the
/// matched characters lit, and ↩ or a double-click opens an empty session in it, as the picker does. Under the projects,
/// messages holding the words on any machine (messages.search), which open their session at the message.
struct SpotlightSheet: View {
	let model: AppModel
	@Environment(\.dismiss) private var dismiss
	@State private var query = ""
	@State private var selected: String?
	@State private var messages = MessageResults()
	@FocusState private var searchFocused: Bool

	private var connected: [AppModel.Machine] { model.machines.filter { $0.store.isConnected } }

	private var results: [ProjectSpotlight.Result<UUID>] {
		ProjectSpotlight.search(query, in: connected.map { machine in
			ProjectSpotlight.Source(
				machine: machine.id,
				projects: machine.store.info?.projects ?? [],
				sessions: Array(machine.store.state.conversations.values)
			)
		})
	}

	var body: some View {
		let results = results
		VStack(spacing: 0) {
			HStack(spacing: 10) {
				Text("/").font(Typography.uiStrong).foregroundStyle(Palette.accent)
				TextField("Open a project", text: $query)
					.textFieldStyle(.plain)
					.font(Typography.ui)
					.focused($searchFocused)
					.onSubmit { submit(results) }
					.onKeyPress(.downArrow) { move(1, in: results) }
					.onKeyPress(.upArrow) { move(-1, in: results) }
					.onChange(of: query) { _, _ in selected = self.results.first?.id ?? messages.hits.first?.id }
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 13)
			Rectangle().fill(Palette.rule).frame(height: 1)
			ScrollViewReader { proxy in
				ScrollView {
					LazyVStack(alignment: .leading, spacing: 0) {
						if results.isEmpty {
							Text(emptyText)
								.font(Typography.ui)
								.foregroundStyle(Palette.ink3)
								.padding(16)
						}
						ForEach(results) { result in
							SpotlightRow(result: result, machine: machineName(result.machine), selected: selected == result.id, colors: colors(result.machine))
								.id(result.id)
								.onTapGesture(count: 2) { open(result) }
								.onTapGesture { selected = result.id }
						}
						if query.trimmingCharacters(in: .whitespaces).count >= 2 {
							HStack {
								Text("messages").font(Typography.label).foregroundStyle(Palette.ink3).textCase(.uppercase)
								Spacer()
								if messages.searching { Text("searching…").font(Typography.label).foregroundStyle(Palette.ink3) }
							}
							.padding(.horizontal, 12)
							.padding(.top, 12)
							.padding(.bottom, 4)
							if !messages.searching, messages.hits.isEmpty {
								Text("No messages match").font(Typography.uiSmall).foregroundStyle(Palette.ink3).padding(.horizontal, 12)
							}
							ForEach(messages.hits) { hit in
								SpotlightMessageRow(hit: hit, machine: machineName(hit.machine), selected: selected == hit.id)
									.id(hit.id)
									.onTapGesture(count: 2) { open(hit) }
									.onTapGesture { selected = hit.id }
							}
						}
					}
					.padding(8)
				}
				.onChange(of: selected) { _, id in
					if let id { proxy.scrollTo(id) }
				}
			}
			Rectangle().fill(Palette.rule).frame(height: 1)
			HStack(spacing: 8) {
				Text("↑↓ move · ↵ open · a project's session starts when you send")
					.font(Typography.label)
					.foregroundStyle(Palette.ink3)
				Spacer()
				Button("esc cancel") { dismiss() }
					.buttonStyle(QuietButton())
					.keyboardShortcut(.cancelAction)
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 10)
		}
		.frame(width: 620 * Typography.scale, height: 420 * Typography.scale)
		.background(Palette.paper)
		.onAppear {
			searchFocused = true
			selected = results.first?.id
		}
		.task(id: query) {
			let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
			guard words.count >= 2 else {
				messages = MessageResults()
				return
			}
			messages.searching = true
			try? await Task.sleep(for: .milliseconds(250))
			guard !Task.isCancelled else { return }
			let found = await MessageResults.search(words, on: connected)
			guard !Task.isCancelled else { return }
			messages = found
			if selected == nil { selected = results.first?.id ?? found.hits.first?.id }
		}
	}

	/// Every row's ID in order, projects then messages, for ↑↓.
	private func order(_ results: [ProjectSpotlight.Result<UUID>]) -> [String] {
		results.map(\.id) + messages.hits.map(\.id)
	}

	private func submit(_ results: [ProjectSpotlight.Result<UUID>]) {
		if let hit = messages.hits.first(where: { $0.id == selected }) { return open(hit) }
		open(results.first { $0.id == selected } ?? results.first)
	}

	private func open(_ hit: MessageResults.Hit) {
		model.openSearchResult(hit.result, on: hit.machine)
		dismiss()
	}

	private var emptyText: String {
		if connected.isEmpty { return "No machine is connected" }
		return query.trimmingCharacters(in: .whitespaces).isEmpty ? "No projects" : "No project matches \u{201C}\(query)\u{201D}"
	}

	/// The machine's name, shown only when there's more than one to tell apart.
	private func machineName(_ id: UUID) -> String? {
		guard connected.count > 1, let machine = model.machine(id) else { return nil }
		return model.name(of: machine)
	}

	private func colors(_ id: UUID) -> [String: Int] {
		model.machine(id)?.store.state.projectColors ?? [:]
	}

	private func move(_ step: Int, in results: [ProjectSpotlight.Result<UUID>]) -> KeyPress.Result {
		let ids = order(results)
		guard !ids.isEmpty else { return .ignored }
		let index = selected.flatMap { ids.firstIndex(of: $0) } ?? (step > 0 ? -1 : ids.count)
		selected = ids[min(max(index + step, 0), ids.count - 1)]
		return .handled
	}

	private func open(_ result: ProjectSpotlight.Result<UUID>?) {
		guard let result else { return }
		model.openDraft(on: result.machine, project: result.project)
		dismiss()
	}
}

/// A message search's hit: who wrote it, its session's title, the snippet with the matched words lit, and its project,
/// machine and whether it's archived.
private struct SpotlightMessageRow: View {
	let hit: MessageResults.Hit
	let machine: String?
	let selected: Bool

	var body: some View {
		let result = hit.result
		VStack(alignment: .leading, spacing: 3) {
			HStack(spacing: 8) {
				Text(result.from == .user ? "❯" : "●").foregroundStyle(result.from == .user ? Palette.accent : Palette.ink3)
				Text(result.title.isEmpty ? "Untitled" : result.title).foregroundStyle(Palette.ink).lineLimit(1)
				Spacer(minLength: 8)
				Group {
					Text(result.project.isEmpty ? "scratch" : result.project)
					if result.archived { Text("archived") }
					if let machine { Text(machine).foregroundStyle(Palette.ink2) }
					Text(Date(timeIntervalSince1970: TimeInterval(result.at) / 1000).shortAge).monospacedDigit()
				}
				.font(Typography.label)
				.foregroundStyle(Palette.ink3)
			}
			.font(Typography.ui)
			Text(MessageResults.snippet(result.snippet))
				.font(Typography.uiSansSmall)
				.lineLimit(2)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 7)
		.background(selected ? Palette.selection : .clear)
		.contentShape(Rectangle())
	}
}

/// A project: its colour, its name and path with the query's characters lit, its machine when there are several, and
/// its sessions.
private struct SpotlightRow: View {
	let result: ProjectSpotlight.Result<UUID>
	let machine: String?
	let selected: Bool
	let colors: [String: Int]

	private var project: ProjectInfo { result.project }

	var body: some View {
		HStack(spacing: 10) {
			Circle().fill(Palette.project(project.name, in: colors)).frame(width: 8, height: 8)
			Text(Self.lit(project.name, result.nameMatches, ink: Palette.ink))
				.font(Typography.ui)
				.lineLimit(1)
			Text(Self.lit(project.path, result.pathMatches, ink: Palette.ink3))
				.font(Typography.uiSmall)
				.lineLimit(1)
				.truncationMode(.head)
			Spacer(minLength: 8)
			Group {
				if let sessions = sessionsText { Text(sessions) }
				if let machine { Text(machine).foregroundStyle(Palette.ink2) }
			}
			.font(Typography.label)
			.foregroundStyle(Palette.ink3)
			.monospacedDigit()
			.lineLimit(1)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(selected ? Palette.projectWash(project.name, in: colors) : .clear, in: RoundedRectangle(cornerRadius: Metrics.radiusRow))
		.contentShape(Rectangle())
	}

	private var sessionsText: String? {
		let entry = result.entry
		guard entry.sessions > 0 else { return nil }
		let count = entry.sessions == 1 ? "1 session" : "\(entry.sessions) sessions"
		guard let last = entry.lastActive else { return count }
		return "\(count) · \(Date(timeIntervalSince1970: TimeInterval(last) / 1000).shortAge)"
	}

	/// `text` in `ink`, with the characters at `positions` in the accent.
	static func lit(_ text: String, _ positions: [Int], ink: Color) -> AttributedString {
		let hits = Set(positions)
		var out = AttributedString()
		for (offset, character) in text.enumerated() {
			var piece = AttributedString(String(character))
			piece.foregroundColor = hits.contains(offset) ? Palette.accent : ink
			out += piece
		}
		return out
	}
}
