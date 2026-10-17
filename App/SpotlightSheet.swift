import AmyrlinCore
import SwiftUI

/// Finds a project on any connected machine (⌘/): typing narrows the list by fuzzy match (ProjectSpotlight), with the
/// matched characters lit, and ↩ or a double-click opens an empty session in it, as the picker does.
struct SpotlightSheet: View {
	let model: AppModel
	@Environment(\.dismiss) private var dismiss
	@State private var query = ""
	@State private var selected: String?
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
					.onSubmit { open(results.first { $0.id == selected } ?? results.first) }
					.onKeyPress(.downArrow) { move(1, in: results) }
					.onKeyPress(.upArrow) { move(-1, in: results) }
					.onChange(of: query) { _, _ in selected = self.results.first?.id }
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
					}
					.padding(8)
				}
				.onChange(of: selected) { _, id in
					if let id { proxy.scrollTo(id) }
				}
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
		guard !results.isEmpty else { return .ignored }
		let index = selected.flatMap { id in results.firstIndex { $0.id == id } } ?? (step > 0 ? -1 : results.count)
		selected = results[min(max(index + step, 0), results.count - 1)].id
		return .handled
	}

	private func open(_ result: ProjectSpotlight.Result<UUID>?) {
		guard let result else { return }
		model.openDraft(on: result.machine, project: result.project)
		dismiss()
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
