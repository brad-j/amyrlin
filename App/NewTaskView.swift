import AmyrlinCore
import SwiftUI

/// Identifiable wrapper so a machine can drive `.sheet(item:)`.
struct MachineRef: Identifiable {
	let machine: AppModel.Machine
	var id: UUID { machine.id }
}

/// The ⌘N pane: the ask box on its own, with room to write.
struct NewTaskView: View {
	let model: AppModel
	@Bindable var composition: Composition

	var body: some View {
		VStack(spacing: 0) {
			HeaderBar {
				Text("New task").foregroundStyle(Palette.ink2)
				Spacer(minLength: 8)
				PaneCloseButton()
			}
			ScrollView {
				AskBox(model: model, composition: composition, lines: 6...20, takesFocus: true)
					.frame(maxWidth: Metrics.measure + 48)
					.padding(.horizontal, 40)
					.padding(.top, 28)
					.frame(maxWidth: .infinity)
			}
		}
		.background(Palette.paper)
		.overlay(alignment: .bottomLeading) { SidebarToggle().padding(10) }
	}
}

/// Asks a sandbox for something: the box, then under it the project (with what its checkout leaves behind), the
/// sandbox's size, and where the work lands. Every task runs in a sandbox. Starting it opens the task where the box was.
/// `fixedProject` pins the box to one project (a project's page), hiding the project choice.
struct AskBox: View {
	let model: AppModel
	@Bindable var composition: Composition
	var fixedProject: (machine: UUID, project: ProjectInfo)? = nil
	var lines: ClosedRange<Int> = 2...12
	var takesFocus = false
	@State private var sending = false
	@FocusState private var focused: Bool

	private var task: NewTask { model.newTask }
	private var machineID: UUID? { fixedProject?.machine ?? task.machine }
	private var machine: AppModel.Machine? { machineID.flatMap(model.machine) }
	private var attachments: Attachments { composition.attachments }
	private var pasted: PastedText { composition.pasted }
	/// The chosen project as the host last read it, with its checkout now.
	private var project: ProjectInfo? {
		guard let chosen = fixedProject?.project ?? task.project, let machine else { return nil }
		return machine.store.projects.first { $0.dir == chosen.dir } ?? chosen
	}
	private var refusal: String? { machineID.flatMap { model.sandboxRefusal(for: project, on: $0) } }

	private var canSend: Bool {
		(!composition.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
			&& !attachments.isPreparing && !sending && machine?.store.isConnected == true && refusal == nil
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			box
			options
		}
		.followsPaneFocus($focused)
		.onAppear { if takesFocus { focused = true } }
		// Opened before the machines listed their projects: pick the default once they have.
		.onChange(of: model.machines.map(\.store.projects.count), initial: true) { _, _ in
			if fixedProject == nil, !task.settled { model.chooseDefaultProject() }
		}
		.sheet(isPresented: Binding(get: { model.pickingProject }, set: { model.pickingProject = $0 })) {
			ProjectPicker(model: model)
		}
	}

	private var box: some View {
		VStack(alignment: .leading, spacing: 8) {
			AttachmentStrip(attachments: attachments)
			HStack(alignment: .firstTextBaseline, spacing: 10) {
				TextField("", text: $composition.text, prompt: Text(prompt).foregroundStyle(Palette.ink3), axis: .vertical)
					.textFieldStyle(.plain)
					.font(Typography.reading)
					.foregroundStyle(Palette.ink)
					.lineLimit(lines)
					.focused($focused)
					.wrapsAtItsWidth(focused: focused)
					.disabled(sending)
					.onKeyPress(.return, phases: .down) { press in
						if press.modifiers.contains(.option) || press.modifiers.contains(.shift) {
							insertLineBreak()
							return .handled
						}
						send()
						return .handled
					}
				IconButton(machine?.store.info?.files == nil ? "photo.badge.plus" : "paperclip", color: attachments.isFull ? Palette.ink3 : Palette.ink2) { attachments.pick() }
					.disabled(attachments.isFull || sending)
					.help("Attach images, videos or files; you can also drop them here or paste them (⌘V)")
				Button(sending ? "starting…" : "Start ↵", action: send)
					.buttonStyle(QuietButton(fill: canSend ? Palette.accent : nil, ink: canSend ? Palette.accentInk : Palette.ink3))
					.disabled(!canSend)
			}
		}
		.padding(12)
		.background(Palette.paper2)
		.overlay(Rectangle().stroke(focused ? Palette.rule2 : Palette.rule))
		.acceptsPastes(attachments, text: pasted, focused: focused)
	}

	private var prompt: String {
		if let name = fixedProject?.project.name { return "What should a sandbox do in \(name)?" }
		return "What should a sandbox do?"
	}

	/// One quiet line under the box: the project (a menu, unless the box is a project's), the size, where it lands,
	/// and what the checkout leaves behind or why it can't take a sandbox.
	private var options: some View {
		HStack(spacing: 14) {
			if fixedProject == nil {
				Button { model.pickingProject = true } label: {
					HStack(spacing: 5) {
						ProjectName(name: project?.name, colors: machine?.store.state.projectColors ?? [:])
						if let machine, let tag = model.machineTag(machine.id) { Text(tag).foregroundStyle(Palette.ink3) }
						Text("▾").foregroundStyle(Palette.ink3)
					}
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.help("Pick the project (⌘/ also finds one)")
			}
			Menu {
				Button(task.size == nil ? "✓ Auto" : "Auto") { task.size = nil }
				ForEach(SandboxSize.known, id: \.self) { size in
					Button("\(task.size == size ? "✓ " : "")\(size.rawValue.capitalized) · \(size.resources ?? "")") { task.size = size }
				}
			} label: {
				Text("size \(task.size?.rawValue ?? "auto") ▾").foregroundStyle(Palette.ink3)
			}
			.menuStyle(.button)
			.buttonStyle(.plain)
			.menuIndicator(.hidden)
			.fixedSize()
			.help(task.size?.resources ?? "The project's size from .agents/project.json, else small (2 CPUs · 4 GB)")
			Text(lands).foregroundStyle(Palette.ink3)
			note
			Spacer(minLength: 0)
		}
		.font(Typography.uiSmall)
		.lineLimit(1)
	}

	private var lands: String {
		guard project != nil else { return "scratch: lands nowhere until it's a project" }
		let upstream = project?.checkout?.upstream?.replacingOccurrences(of: "origin/", with: "") ?? "main"
		return machine?.store.sandboxes?.shipTo == .branch ? "lands as a PR on Ship" : "lands on \(upstream) on Ship"
	}

	/// What the checkout leaves behind, or why the project can't take a sandbox.
	@ViewBuilder private var note: some View {
		if let refusal {
			Text("no sandbox: \(refusal)").foregroundStyle(Palette.wait)
		} else if let checkout = project?.checkout, checkout.dirty > 0 || checkout.behind > 0 {
			Text([
				checkout.dirty > 0 ? "\(checkout.dirty) uncommitted here won't be in it" : nil,
				checkout.behind > 0 ? "\(checkout.behind) behind \(checkout.upstream ?? "upstream")" : nil,
			].compactMap(\.self).joined(separator: " · "))
			.foregroundStyle(Palette.wait)
		}
	}

	private func send() {
		let message = pasted.expand(composition.text).trimmingCharacters(in: .whitespacesAndNewlines)
		guard canSend, !attachments.refused(by: machine?.store.info) else { return }
		if let fixedProject { model.choose(fixedProject.project, on: fixedProject.machine) }
		sending = true
		let images = attachments.items.map(\.upload)
		let videos = attachments.videos.map(\.upload)
		let files = attachments.files.map(\.upload)
		Task {
			if await model.startTask(text: message, images: images, videos: videos, files: files) {
				composition.clear()
			}
			sending = false
		}
	}
}

/// A project's name in its colour, or "scratch".
struct ProjectName: View {
	let name: String?
	let colors: [String: Int]

	var body: some View {
		Text(name ?? "scratch").foregroundStyle(name.map { Palette.project($0, in: colors) } ?? Palette.ink2)
	}
}

/// A row of choices in one box, one lit; a disabled choice is dim and can't be picked.
struct Segmented: View {
	let choices: [String]
	let selected: Int
	var disabled: Set<Int> = []
	let pick: (Int) -> Void

	var body: some View {
		HStack(spacing: 0) {
			ForEach(choices.indices, id: \.self) { index in
				if index > 0 { Rectangle().fill(Palette.rule2).frame(width: 1) }
				Button { pick(index) } label: {
					Text(choices[index])
						.foregroundStyle(disabled.contains(index) ? Palette.rule2 : index == selected ? Palette.ink : Palette.ink3)
						.padding(.horizontal, 9)
						.padding(.vertical, 1)
						.background(index == selected ? Palette.paper3 : .clear)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.disabled(disabled.contains(index))
			}
		}
		.font(Typography.ui)
		.overlay(Rectangle().stroke(Palette.rule2))
		.fixedSize()
	}
}

/// Picks the new task's project from every connected machine: typing narrows by fuzzy match (ProjectSpotlight), most
/// recently used first without a query. Each row says whether it can take a sandbox, and scratch heads the list.
struct ProjectPicker: View {
	let model: AppModel
	@Environment(\.dismiss) private var dismiss
	@State private var query = ""
	@State private var selected: String?
	@FocusState private var searchFocused: Bool

	/// Machines with sandboxes, connected: the only ones a task can go to.
	private var connected: [AppModel.Machine] { model.sandboxMachines.filter { $0.store.isConnected } }

	private var results: [ProjectSpotlight.Result<UUID>] {
		ProjectSpotlight.search(query, in: connected.map { machine in
			ProjectSpotlight.Source(machine: machine.id, projects: machine.store.projects, sessions: Array(machine.store.state.conversations.values))
		})
	}

	/// Scratch on each machine, while the query could mean it.
	private var scratch: [AppModel.Machine] {
		let q = query.trimmingCharacters(in: .whitespaces).lowercased()
		return q.isEmpty || "scratch".contains(q) || "no project".contains(q) ? connected : []
	}

	private func scratchID(_ machine: AppModel.Machine) -> String { "scratch\n\(machine.id)" }

	private var ids: [String] { scratch.map(scratchID) + results.map(\.id) }

	var body: some View {
		let results = results
		VStack(spacing: 0) {
			HStack(spacing: 10) {
				Text("/").font(Typography.uiStrong).foregroundStyle(Palette.accent)
				TextField("Find a project", text: $query)
					.textFieldStyle(.plain)
					.font(Typography.ui)
					.focused($searchFocused)
					.onSubmit { pick(selected ?? ids.first) }
					.onKeyPress(.downArrow) { move(1) }
					.onKeyPress(.upArrow) { move(-1) }
					.onChange(of: query) { _, _ in selected = ids.first }
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 13)
			Rectangle().fill(Palette.rule).frame(height: 1)
			ScrollViewReader { proxy in
				ScrollView {
					LazyVStack(alignment: .leading, spacing: 0) {
						ForEach(results) { result in
							PickerRow(model: model, project: result.project, machine: result.machine, selected: selected == result.id)
								.id(result.id)
								.onTapGesture(count: 2) { pick(result.id) }
								.onTapGesture { selected = result.id }
						}
						ForEach(scratch) { machine in
							PickerRow(model: model, project: nil, machine: machine.id, selected: selected == scratchID(machine))
								.id(scratchID(machine))
								.onTapGesture(count: 2) { pick(scratchID(machine)) }
								.onTapGesture { selected = scratchID(machine) }
						}
						if results.isEmpty, scratch.isEmpty {
							Text(connected.isEmpty ? "No machine is connected" : "No project matches \u{201C}\(query)\u{201D}")
								.font(Typography.ui).foregroundStyle(Palette.ink3).padding(16)
						}
					}
					.padding(8)
				}
				.onChange(of: selected) { _, id in if let id { proxy.scrollTo(id) } }
			}
			Rectangle().fill(Palette.rule).frame(height: 1)
			HStack(spacing: 8) {
				Text("↑↓ move · ↵ pick").font(Typography.label).foregroundStyle(Palette.ink3)
				Spacer()
				// The first machine that can make projects; usually egwene.
				if let maker = connected.first(where: { $0.store.newProjects != nil }) {
					Button("+ New project") {
						dismiss()
						model.creatingProject = .create(machine: maker.id)
					}
					.buttonStyle(QuietButton())
					.help("Make a project on \(model.name(of: maker)), with a private GitHub repository")
				}
				Button("esc cancel") { dismiss() }
					.buttonStyle(QuietButton())
					.keyboardShortcut(.cancelAction)
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 10)
		}
		.frame(width: 640 * Typography.scale, height: 440 * Typography.scale)
		.background(Palette.paper)
		.onAppear {
			searchFocused = true
			selected = ids.first
		}
	}

	private func move(_ step: Int) -> KeyPress.Result {
		let ids = ids
		guard !ids.isEmpty else { return .ignored }
		let index = selected.flatMap { ids.firstIndex(of: $0) } ?? (step > 0 ? -1 : ids.count)
		selected = ids[min(max(index + step, 0), ids.count - 1)]
		return .handled
	}

	private func pick(_ id: String?) {
		guard let id else { return }
		if let machine = scratch.first(where: { scratchID($0) == id }) {
			model.choose(nil, on: machine.id)
		} else if let result = results.first(where: { $0.id == id }) {
			model.choose(result.project, on: result.machine)
		} else {
			return
		}
		dismiss()
	}
}

/// A project to pick: its colour and name, its path, its machine when it isn't the home one, and whether a sandbox
/// can start from it.
private struct PickerRow: View {
	let model: AppModel
	let project: ProjectInfo?
	let machine: UUID
	let selected: Bool

	var body: some View {
		let colors = model.machine(machine)?.store.state.projectColors ?? [:]
		let refusal = model.sandboxRefusal(for: project, on: machine)
		HStack(spacing: 10) {
			Circle().fill(project.map { Palette.project($0.name, in: colors) } ?? Palette.ink3).frame(width: 8, height: 8)
			Text(project?.name ?? "scratch").font(Typography.ui).foregroundStyle(Palette.ink).lineLimit(1)
			Text(project?.path ?? "no project, a directory of its own")
				.font(Typography.uiSmall).foregroundStyle(Palette.ink3).lineLimit(1).truncationMode(.head)
			Spacer(minLength: 8)
			Group {
				if let tag = model.machineTag(machine) { Text(tag).foregroundStyle(Palette.ink2) }
				if refusal != nil { Text("no sandbox").foregroundStyle(Palette.rule2) }
			}
			.font(Typography.label)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(selected ? (project.map { Palette.projectWash($0.name, in: colors) } ?? Palette.paper3) : .clear)
		.contentShape(Rectangle())
		.help(refusal.map { "Can't take a sandbox: \($0)" } ?? "Runs in a sandbox")
	}
}
