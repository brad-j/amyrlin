import AmyrlinCore
import SwiftUI

/// Identifiable wrapper so a machine can drive `.sheet(item:)`.
struct MachineRef: Identifiable {
	let machine: AppModel.Machine
	var id: UUID { machine.id }
}

/// The new-task box: one big box for the ask, and under it the project, where it runs and how it lands. Sandbox is
/// the default where the project can take one; "here" works in the project's checkout on its machine. Sending the
/// first message creates the task and shows it where the box was.
struct NewTaskView: View {
	let model: AppModel
	/// The message being written, kept while other tasks are shown.
	@Bindable var composition: Composition
	@State private var sending = false
	@FocusState private var focused: Bool

	private var task: NewTask { model.newTask }
	private var machine: AppModel.Machine? { task.machine.flatMap(model.machine) }
	private var attachments: Attachments { composition.attachments }
	private var pasted: PastedText { composition.pasted }
	/// The chosen project as the host last read it, with its checkout now.
	private var project: ProjectInfo? {
		guard let chosen = task.project, let machine else { return nil }
		return machine.store.projects.first { $0.dir == chosen.dir } ?? chosen
	}
	private var refusal: String? { task.machine.flatMap { model.sandboxRefusal(for: task.project, on: $0) } }
	private var inSandbox: Bool { task.sandbox && refusal == nil }

	private var canSend: Bool {
		(!composition.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
			&& !attachments.isPreparing && !sending && machine?.store.isConnected == true
	}

	var body: some View {
		VStack(spacing: 0) {
			HeaderBar {
				Text("New task").foregroundStyle(Palette.ink2)
				if let machine {
					Text(" in ").foregroundStyle(Palette.ink3)
					ProjectName(name: project?.name, colors: machine.store.state.projectColors)
					if let tag = model.machineTag(machine.id) { Text(" · \(tag)").foregroundStyle(Palette.ink3) }
				}
				Spacer(minLength: 8)
				PaneCloseButton()
			}
			ScrollView {
				VStack(alignment: .leading, spacing: 14) {
					box
					options
				}
				.frame(maxWidth: Metrics.measure + 48)
				.padding(.horizontal, 40)
				.padding(.top, 28)
				.frame(maxWidth: .infinity)
			}
		}
		.background(Palette.paper)
		.overlay(alignment: .bottomLeading) { SidebarToggle().padding(10) }
		.followsPaneFocus($focused)
		// Opened before the machines listed their projects: pick the default once they have.
		.onChange(of: model.machines.map(\.store.projects.count), initial: true) { _, _ in
			if !task.settled { model.chooseDefaultProject() }
		}
		.sheet(isPresented: Binding(get: { model.pickingProject }, set: { model.pickingProject = $0 })) {
			ProjectPicker(model: model)
		}
	}

	private var box: some View {
		VStack(alignment: .leading, spacing: 10) {
			AttachmentStrip(attachments: attachments)
			TextField("", text: $composition.text, prompt: Text("What should it do?").foregroundStyle(Palette.ink3), axis: .vertical)
				.textFieldStyle(.plain)
				.font(Typography.reading)
				.foregroundStyle(Palette.ink)
				.lineLimit(6...20)
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
			HStack(spacing: 10) {
				IconButton(machine?.store.info?.files == nil ? "photo.badge.plus" : "paperclip", color: attachments.isFull ? Palette.ink3 : Palette.ink2) { attachments.pick() }
					.disabled(attachments.isFull || sending)
					.help("Attach images, videos or files; you can also drop them here or paste them (⌘V)")
				Spacer()
				Text(sending ? "starting…" : "↵ start · ⇧↵ new line")
					.font(Typography.uiSmall)
					.foregroundStyle(Palette.ink3)
				Button(sending ? "starting…" : "Start ↵", action: send)
					.buttonStyle(QuietButton(fill: canSend ? Palette.accent : nil, ink: canSend ? Palette.accentInk : Palette.ink3))
					.disabled(!canSend)
			}
		}
		.padding(14)
		.background(Palette.paper2)
		.overlay(Rectangle().stroke(focused ? Palette.rule2 : Palette.rule))
		.acceptsPastes(attachments, text: pasted, focused: focused)
	}

	/// The project, where it runs and how it lands, each a line: a label, its control, and a plain sentence.
	private var options: some View {
		VStack(alignment: .leading, spacing: 10) {
			option("project") {
				Button { model.pickingProject = true } label: {
					HStack(spacing: 6) {
						ProjectName(name: project?.name, colors: machine?.store.state.projectColors ?? [:])
						if let machine { Text(model.machineTag(machine.id) ?? model.name(of: machine)).foregroundStyle(Palette.ink3) }
						Text("▾").foregroundStyle(Palette.ink3)
					}
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.help("Pick the project (⌘/ also finds one)")
			} note: {
				checkoutNote
			}
			option("runs") {
				Segmented(choices: ["here", "sandbox"], selected: inSandbox ? 1 : 0, disabled: refusal == nil ? [] : [1]) { index in
					task.sandbox = index == 1
				}
			} note: {
				Text(runsNote).foregroundStyle(refusal != nil && task.sandbox ? Palette.wait : Palette.ink3)
			}
			if inSandbox {
				option("size") {
					Segmented(choices: ["auto", "small", "medium", "large"], selected: task.size.flatMap { SandboxSize.known.firstIndex(of: $0).map { $0 + 1 } } ?? 0) { index in
						task.size = index == 0 ? nil : SandboxSize.known[index - 1]
					}
				} note: {
					Text(task.size?.resources ?? "the project's size, else 2 CPUs · 4 GB").foregroundStyle(Palette.ink3)
				}
			}
			if inSandbox, project == nil {
				option("lands") {
					Text("nowhere yet").foregroundStyle(Palette.ink2)
				} note: {
					Text("scratch can't ship; make it a project from its result").foregroundStyle(Palette.ink3)
				}
			} else if inSandbox, let defaults = machine?.store.sandboxes {
				option("lands") {
					Text(defaults.shipTo == .branch ? "as a PR" : "on \(project?.checkout?.upstream?.replacingOccurrences(of: "origin/", with: "") ?? "main")")
						.foregroundStyle(Palette.ink2)
				} note: {
					Text("only when you press Ship · approvals \(defaults.approvals == .off ? "off: it holds no keys" : "on")")
						.foregroundStyle(Palette.ink3)
				}
			}
		}
		.font(Typography.ui)
	}

	private func option<Control: View, Note: View>(_ label: String, @ViewBuilder control: () -> Control, @ViewBuilder note: () -> Note) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 12) {
			Text(label)
				.font(Typography.label)
				.textCase(.uppercase)
				.foregroundStyle(Palette.ink3)
				.frame(width: 64 * Typography.scale, alignment: .leading)
			control()
			note().font(Typography.uiSansSmall).lineLimit(2)
			Spacer(minLength: 0)
		}
	}

	/// The checkout's state where it bears on the task: what stays behind, and whether it's behind its upstream.
	@ViewBuilder private var checkoutNote: some View {
		if let checkout = project?.checkout {
			let parts = [
				checkout.branch.map { "on \($0)" },
				checkout.dirty > 0 && inSandbox ? "\(checkout.dirty) uncommitted \(checkout.dirty == 1 ? "change" : "changes") here won't be in it" : checkout.dirty > 0 ? "\(checkout.dirty) uncommitted" : nil,
				checkout.behind > 0 ? "\(checkout.behind) behind \(checkout.upstream ?? "upstream") as last fetched" : nil,
			].compactMap(\.self)
			Text(parts.joined(separator: " · ")).foregroundStyle(checkout.dirty > 0 && inSandbox || checkout.behind > 0 ? Palette.wait : Palette.ink3)
		} else if project == nil {
			Text(inSandbox ? "an empty repository of its own" : "a directory of its own on \(machine.map(model.name(of:)) ?? "the machine")").foregroundStyle(Palette.ink3)
		}
	}

	private var runsNote: String {
		if let refusal { return "here only: \(refusal)" }
		if inSandbox, project == nil {
			return "its own machine, with an empty repository it can commit to"
		}
		if inSandbox {
			return "its own machine from the last commit\(project?.checkout?.branch.map { " on \($0)" } ?? ""); nothing here is touched"
		}
		return "in \(project.map { ConversationView.shortPath($0.dir) } ?? "a scratch directory") on \(machine.map(model.name(of:)) ?? "the machine"), with approvals"
	}

	private func send() {
		let message = pasted.expand(composition.text).trimmingCharacters(in: .whitespacesAndNewlines)
		guard canSend, !attachments.refused(by: machine?.store.info) else { return }
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

	private var connected: [AppModel.Machine] { model.machines.filter { $0.store.isConnected } }

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
				Text(refusal == nil ? "sandbox" : "here only").foregroundStyle(refusal == nil ? Palette.ink3 : Palette.rule2)
			}
			.font(Typography.label)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(selected ? (project.map { Palette.projectWash($0.name, in: colors) } ?? Palette.paper3) : .clear)
		.contentShape(Rectangle())
		.help(refusal.map { "Here only: \($0)" } ?? "Can run in a sandbox")
	}
}
