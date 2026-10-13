import AmyrlinCore
import SwiftUI

/// Identifiable wrapper so a machine can drive `.sheet(item:)`.
struct MachineRef: Identifiable {
	let machine: AppModel.Machine
	var id: UUID { machine.id }
}

/// Pick a project, write the first message, send: the conversation starts with it.
struct NewConversationSheet: View {
	let model: AppModel
	let machine: AppModel.Machine
	@Environment(\.dismiss) private var dismiss
	@State private var query = ""
	@State private var project: String?
	@State private var text = ""
	@State private var sending = false
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
			if !projects.isEmpty {
				TextField("Find a project", text: $query)
					.textFieldStyle(.roundedBorder)
					.focused($searchFocused)
				List(filtered, selection: $project) { item in
					HStack {
						Text(item.name).font(Typography.reading)
						Spacer()
						Text(item.path).font(Typography.label).foregroundStyle(Palette.tertiaryText)
					}
					.tag(item.dir)
				}
				.frame(height: 220)
			}
			TextField("First message", text: $text, axis: .vertical)
				.textFieldStyle(.plain)
				.font(Typography.reading)
				.lineLimit(3...10)
				.padding(10)
				.background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
				.onKeyPress(.return, phases: .down) { press in
					if press.modifiers.contains(.option) || press.modifiers.contains(.shift) { return .ignored }
					send()
					return .handled
				}
			HStack {
				if let dir = project { Text(dir).font(Typography.code).foregroundStyle(Palette.tertiaryText).lineLimit(1).truncationMode(.head) }
				Spacer()
				Button("Cancel", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Button("Start", action: send)
					.keyboardShortcut(.defaultAction)
					.disabled(!canSend)
			}
		}
		.padding(20)
		.frame(width: 560)
		.onAppear { searchFocused = true }
	}

	private var canSend: Bool {
		!sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (projects.isEmpty || project != nil)
	}

	private func send() {
		guard canSend else { return }
		sending = true
		Task {
			if await model.startConversation(on: machine, project: project, text: text) { dismiss() }
			sending = false
		}
	}
}
