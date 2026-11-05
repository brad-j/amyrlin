import AmyrlinCore
import SwiftUI

/// The middle column with nothing open: the home (every project) or a project's page, by the rail's choice.
struct HomeOrProject: View {
	let model: AppModel

	var body: some View {
		if let scoped = model.scopedProject {
			ProjectPage(model: model, machine: scoped.machine, project: scoped.project, name: scoped.name)
				.id("\(scoped.machine.id)/\(scoped.name)")
		} else {
			FocusHome(model: model)
		}
	}
}

/// The home (option 2, "Focus"): a queue to empty. The ask box, then what needs you, each with its decision inline
/// (a question's options as buttons, Open otherwise), then what's ready, with Look and Ship. Work in progress and today's
/// ships sit in a slim column at the right. Opening a task is for digging in.
struct FocusHome: View {
	let model: AppModel

	var body: some View {
		let all = model.allTasks()
		let groups = Dictionary(grouping: all) { TaskGroups.group($0.summary, ship: $0.ship) }
		let needs = (groups[.needsYou] ?? []).sorted { $0.summary.updatedAt > $1.summary.updatedAt }
		let ready = (groups[.ready] ?? []).sorted { $0.summary.updatedAt > $1.summary.updatedAt }
		let running = (groups[.running] ?? []).sorted { $0.summary.createdAt > $1.summary.createdAt }
		let today = Calendar.current.startOfDay(for: .now).timeIntervalSince1970 * 1000
		let shipped = (model.allTasks() + model.archivedTasks()).filter { item in
			if case .shipped = item.ship { return Double(item.summary.updatedAt) >= today }
			return false
		}
		VStack(spacing: 0) {
			HeaderBar {
				Text("Home").foregroundStyle(Palette.ink2)
				Spacer(minLength: 8)
				BracketButton("all projects") { model.showingProjectTable = true }
					.help("Every project with its checkout")
				PaneCloseButton()
			}
			HStack(spacing: 0) {
				ScrollView {
					VStack(alignment: .leading, spacing: 0) {
						AskBox(model: model, composition: model.composition(for: .empty))
						Section(title: "needs you", count: needs.count, color: Palette.wait) {
							ForEach(needs) { item in QueueItem(model: model, item: item) }
						}
						Section(title: "ready to ship", count: ready.count, color: Palette.add) {
							ForEach(ready) { item in QueueItem(model: model, item: item) }
						}
						if needs.isEmpty, ready.isEmpty, model.sandboxMachines.contains(where: { $0.store.state.hasSnapshot }) {
							Text(running.isEmpty ? "Nothing needs you. Ask a sandbox for something above." : "Nothing needs you. \(running.count == 1 ? "One task is" : "\(running.count) tasks are") working.")
								.font(Typography.reading)
								.foregroundStyle(Palette.ink3)
								.padding(.top, 28)
						}
						if model.sandboxMachines.isEmpty, !model.machines.isEmpty {
							Text("No machine here has a sandbox host. This app runs work in sandboxes; add a machine whose aludra has one.")
								.font(Typography.reading)
								.foregroundStyle(Palette.wait)
								.padding(.top, 28)
						}
					}
					.frame(maxWidth: Metrics.measure + 48, alignment: .leading)
					.padding(.horizontal, 36)
					.padding(.vertical, 24)
					.frame(maxWidth: .infinity)
				}
				SideColumn(model: model, running: running, shipped: shipped)
			}
		}
		.background(Palette.paper)
		.overlay(alignment: .bottomLeading) { SidebarToggle().padding(10) }
		.sheet(isPresented: Binding(get: { model.showingProjectTable }, set: { model.showingProjectTable = $0 })) {
			ProjectsHome(model: model).frame(width: 980, height: 620)
		}
	}
}

/// A labeled part of the queue; left out while empty.
private struct Section<Content: View>: View {
	let title: String
	let count: Int
	let color: Color
	@ViewBuilder let content: Content

	var body: some View {
		if count > 0 {
			VStack(alignment: .leading, spacing: 0) {
				HStack(spacing: 6) {
					Text(title).foregroundStyle(color)
					Text("\(count)").foregroundStyle(Palette.ink3)
				}
				.font(Typography.label)
				.textCase(.uppercase)
				.padding(.top, 26)
				.padding(.bottom, 4)
				content
			}
		}
	}
}

/// One item in the queue: its mark, title and project, its line, and the obvious next step as buttons. A question's
/// options answer it in place; Ship opens the task with the confirmation up.
private struct QueueItem: View {
	let model: AppModel
	let item: TaskEntry

	private var host: HostStore? { model.machine(item.id.machine)?.store }

	var body: some View {
		let summary = item.summary
		let group = TaskGroups.group(summary, ship: item.ship)
		let colors = host?.state.projectColors ?? [:]
		let result = host.map { $0.task(item.id.conversation) }
		VStack(alignment: .leading, spacing: 4) {
			HStack(alignment: .firstTextBaseline, spacing: 10) {
				TaskMark(summary: summary, ship: item.ship, unread: model.isUnread(item.id))
				Text(summary.title.isEmpty ? "New task" : summary.title)
					.font(Typography.readingStrong)
					.foregroundStyle(Palette.ink)
					.lineLimit(1)
				Text(summary.project ?? "scratch")
					.font(Typography.uiSmall)
					.foregroundStyle(summary.project.map { Palette.project($0, in: colors) } ?? Palette.ink3)
				Spacer(minLength: 8)
				Text(Date(timeIntervalSince1970: TimeInterval(summary.updatedAt) / 1000).shortAge)
					.font(Typography.uiSmall).foregroundStyle(Palette.ink3)
			}
			Text(result?.result?.question?.text ?? TaskLine.line(summary, ship: item.ship) ?? "")
				.font(Typography.reading)
				.foregroundStyle(Palette.ink2)
				.lineLimit(2)
				.fixedSize(horizontal: false, vertical: true)
				.padding(.leading, 20)
			FlowLayout(spacing: 8) {
				if group == .needsYou, let options = result?.result?.question?.options, !options.isEmpty {
					ForEach(options.indices, id: \.self) { index in
						Button(options[index]) { answer(options[index]) }
							.buttonStyle(QuietButton(fill: index == 0 ? Palette.wait : nil, ink: index == 0 ? Palette.waitInk : Palette.ink))
							.disabled(summary.status == .busy)
					}
					Button("Open") { model.selection = item.id }.buttonStyle(QuietButton(fill: .clear))
				} else if group == .ready {
					Button("Look") { model.selection = item.id }.buttonStyle(QuietButton(fill: .clear))
					if summary.project != nil {
						Button("Ship") { model.openToShip(item.id) }
							.buttonStyle(QuietButton(fill: Palette.accent, ink: Palette.accentInk))
					} else {
						Button("Make it a project") { model.creatingProject = .promote(item.id, title: summary.title) }
							.buttonStyle(QuietButton())
							.disabled(host?.newProjects == nil)
					}
				} else {
					Button("Open") { model.selection = item.id }.buttonStyle(QuietButton())
				}
			}
			.padding(.leading, 20)
			.padding(.top, 4)
		}
		.padding(.vertical, 12)
		.overlay(alignment: .top) { Rectangle().fill(Palette.rule).frame(height: 1) }
		.contextMenu { TaskMenu(model: model, entry: item) }
		.task(id: TaskStore.key(summary)) { result?.refresh(summary) }
	}

	/// Sends the option as the reply, as the result page's buttons do.
	private func answer(_ text: String) {
		host?.conversation(item.id.conversation).send(text)
	}
}

/// The slim right column of the home: what's working, what shipped today, and the machine.
private struct SideColumn: View {
	let model: AppModel
	let running: [TaskEntry]
	let shipped: [TaskEntry]

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 0) {
				label("working", running.count)
				if running.isEmpty { quiet("nothing running") }
				ForEach(running) { item in TaskLine(model: model, item: item, compact: true) }
				label("shipped today", shipped.count).padding(.top, 14)
				if shipped.isEmpty { quiet("nothing yet") }
				ForEach(shipped) { item in TaskLine(model: model, item: item, compact: true) }
				ForEach(model.sandboxMachines) { machine in
					label(model.name(of: machine), nil).padding(.top, 14)
					HStack(spacing: 6) {
						StatusDot(color: Palette.color(for: machine.store.status))
						Text("\(MachinesMenu.status(machine.store.status)) · \(sandboxes(machine)) in sandboxes")
					}
					.font(Typography.uiSmall)
					.foregroundStyle(Palette.ink3)
					.padding(.horizontal, 12)
				}
			}
			.padding(.vertical, 18)
		}
		.frame(width: 250 * Typography.scale)
		.background(Palette.panel)
		.overlay(alignment: .leading) { Rectangle().fill(Palette.rule).frame(width: 1) }
	}

	private func sandboxes(_ machine: AppModel.Machine) -> String {
		let count = machine.store.state.active.filter { $0.sandbox.map { $0.state != .removed } ?? false }.count
		return count == 1 ? "1 task" : "\(count) tasks"
	}

	private func label(_ title: String, _ count: Int?) -> some View {
		HStack(spacing: 6) {
			Text(title)
			if let count { Text("\(count)") }
		}
		.font(Typography.label)
		.textCase(.uppercase)
		.foregroundStyle(Palette.ink3)
		.padding(.horizontal, 12)
		.padding(.bottom, 4)
	}

	private func quiet(_ text: String) -> some View {
		Text(text).font(Typography.uiSmall).foregroundStyle(Palette.ink3).padding(.horizontal, 12).padding(.vertical, 3)
	}
}

/// A project's page (option 3): its name and folder, its checkout (branch, uncommitted, ahead and behind, the last
/// ship), the ask box pinned to it, then its tasks by group, with done folded under a line.
struct ProjectPage: View {
	let model: AppModel
	let machine: AppModel.Machine
	let project: ProjectInfo?
	let name: String
	@State private var doneOpen = false

	var body: some View {
		let colors = machine.store.state.projectColors
		let tasks = model.allTasks().filter { $0.id.machine == machine.id && ($0.summary.project ?? "") == name }
		let groups = TaskGroups.grouped(tasks, summary: \.summary, ship: \.ship)
		let open = groups.filter { $0.group != .done }
		let done = (groups.first { $0.group == .done }?.items ?? []) + model.archivedTasks(in: (machine.id, name))
		VStack(spacing: 0) {
			HeaderBar {
				Text(name.isEmpty ? "scratch" : name).foregroundStyle(name.isEmpty ? Palette.ink2 : Palette.project(name, in: colors))
				if let project { Text("  \(ConversationView.shortPath(project.dir))").foregroundStyle(Palette.ink3).truncationMode(.head) }
				Spacer(minLength: 8)
				PaneCloseButton()
			}
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					CheckoutStrip(model: model, machine: machine, project: project, tasks: tasks + done)
						.padding(.bottom, 14)
					if let project, project.checkout?.takesSandboxes ?? true {
						AskBox(model: model, composition: model.composition(for: .empty), fixedProject: (machine.id, project))
					} else if name.isEmpty {
						AskBox(model: model, composition: model.composition(for: .empty))
					} else if let refusal = project?.checkout?.sandboxRefusal {
						Text("This project can't take a sandbox: \(refusal).").font(Typography.reading).foregroundStyle(Palette.wait)
					}
					ForEach(open, id: \.group) { group in
						HStack(spacing: 6) {
							Text(group.group.title).foregroundStyle(group.group == .needsYou ? Palette.wait : Palette.ink3)
							Text("\(group.items.count)").foregroundStyle(Palette.ink3)
						}
						.font(Typography.label).textCase(.uppercase)
						.padding(.top, 22).padding(.bottom, 4)
						ForEach(group.items) { item in
							TaskLine(model: model, item: item)
								.overlay(alignment: .top) { Rectangle().fill(Palette.rule).frame(height: 1) }
						}
					}
					if open.isEmpty {
						Text(done.isEmpty ? "No tasks yet. Ask above." : "Nothing open.")
							.font(Typography.reading).foregroundStyle(Palette.ink3).padding(.top, 22)
					}
					if !done.isEmpty {
						Button { withAnimation(.easeInOut(duration: 0.15)) { doneOpen.toggle() } } label: {
							HStack(spacing: 6) {
								Text(doneOpen ? "▾" : "▸")
								Text("shipped and done")
								Text("\(done.count)")
								Spacer()
							}
							.font(Typography.label).textCase(.uppercase).foregroundStyle(Palette.ink3)
							.padding(.top, 22).padding(.bottom, 4)
							.contentShape(Rectangle())
						}
						.buttonStyle(.plain)
						if doneOpen {
							ForEach(done) { item in TaskLine(model: model, item: item, compact: true) }
						}
					}
				}
				.frame(maxWidth: Metrics.measure + 48, alignment: .leading)
				.padding(.horizontal, 36)
				.padding(.vertical, 22)
				.frame(maxWidth: .infinity)
			}
		}
		.background(Palette.paper)
		.overlay(alignment: .bottomLeading) { SidebarToggle().padding(10) }
	}
}

/// `main · 2 uncommitted · 1 ahead · last shipped 2h ago`, under a project's name.
private struct CheckoutStrip: View {
	let model: AppModel
	let machine: AppModel.Machine
	let project: ProjectInfo?
	let tasks: [TaskEntry]

	var body: some View {
		let lastShip = tasks.compactMap { item -> Int64? in
			if case .shipped = item.ship { return item.summary.updatedAt } else { return nil }
		}.max()
		HStack(spacing: 14) {
			if let checkout = project?.checkout {
				HStack(spacing: 0) {
					Text(checkout.branch ?? "detached").foregroundStyle(Palette.ink2)
					if checkout.dirty > 0 { Text(" · \(checkout.dirty) uncommitted").foregroundStyle(Palette.wait) }
					if checkout.ahead > 0 { Text(" · \(checkout.ahead) ahead").foregroundStyle(Palette.ink3) }
					if checkout.behind > 0 { Text(" · \(checkout.behind) behind").foregroundStyle(Palette.wait) }
				}
				.help(checkout.dirty > 0 ? "Uncommitted changes on \(model.name(of: machine)) stay behind when a sandbox starts" : "The checkout on \(model.name(of: machine))")
			} else if project == nil {
				Text("scratch: sandboxes with an empty repository of their own").foregroundStyle(Palette.ink3)
			}
			if let lastShip {
				Text("last shipped \(Date(timeIntervalSince1970: TimeInterval(lastShip) / 1000).shortAge) ago").foregroundStyle(Palette.ink3)
			}
			if model.sandboxMachines.count > 1 { Text(model.name(of: machine)).foregroundStyle(Palette.ink3) }
			Spacer()
		}
		.font(Typography.uiSmall)
	}
}
