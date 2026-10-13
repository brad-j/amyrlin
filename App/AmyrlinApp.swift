import AmyrlinCore
import SwiftUI

@main
struct AmyrlinApp: App {
	@State private var model = AppModel()

	var body: some Scene {
		WindowGroup("Amyrlin") {
			MainView(model: model)
				.preferredColorScheme(.dark)
				.frame(minWidth: 900, minHeight: 560)
		}
		.windowToolbarStyle(.unifiedCompact)
		.commands {
			// One window: ⌘N starts a session instead of opening another window.
			CommandGroup(replacing: .newItem) {
				Button("New Session…") { model.newSession() }
					.keyboardShortcut("n", modifiers: .command)
				Button("Add Machine…") { model.isAddingMachine = true }
					.keyboardShortcut("n", modifiers: [.command, .shift])
			}
			CommandGroup(after: .sidebar) {
				Button(model.showSidebar ? "Hide Sidebar" : "Show Sidebar") { model.showSidebar.toggle() }
					.keyboardShortcut("s", modifiers: [.command, .control])
				Button(model.showInspector ? "Hide Inspector" : "Show Inspector") { model.showInspector.toggle() }
					.keyboardShortcut("i", modifiers: [.command, .option])
			}
		}
	}
}

struct MainView: View {
	@Bindable var model: AppModel

	var body: some View {
		// A plain row instead of NavigationSplitView, whose sidebar floats as a separate panel on macOS 26. This one
		// is flush, like the inspector, runs under the title bar, and resizes from its edge.
		HStack(spacing: 0) {
			if model.showSidebar {
				SidebarView(model: model)
					.frame(width: model.sidebarWidth)
					.overlay(alignment: .trailing) { SidebarEdge(width: $model.sidebarWidth) }
					.ignoresSafeArea(.container, edges: .top)
					.transition(.move(edge: .leading))
			}
			detail
				.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.background(Palette.paper)
		.toolbar(removing: .title)
		.toolbar {
			ToolbarItem(placement: .navigation) {
				Button {
					withAnimation(.easeInOut(duration: 0.2)) { model.showSidebar.toggle() }
				} label: {
					Label("Sidebar", systemImage: "sidebar.left")
				}
				.help("Show or hide the sidebar (⌃⌘S)")
			}
		}
		// On the row, not the detail: the detail is rebuilt per selection, which dropped the inspector.
		.inspector(isPresented: $model.showInspector) {
			Group {
				if let selected = model.selected {
					InspectorView(store: selected.conversation, host: selected.machine.store) { model.showInspector = false }
						.id(model.selection)
				} else {
					Text("No conversation selected")
						.font(Typography.ui)
						.foregroundStyle(Palette.tertiaryText)
						.frame(maxWidth: .infinity, maxHeight: .infinity)
						.background(Palette.panel)
				}
			}
			.inspectorColumnWidth(min: 240, ideal: 280, max: 380)
		}
		.sheet(isPresented: $model.isAddingMachine) {
			AddMachineSheet(model: model)
		}
		.sheet(item: Binding(get: { model.renaming.map(RenameRef.init) }, set: { model.renaming = $0?.conversation })) { ref in
			RenameSheet(model: model, target: ref.conversation)
		}
		.sheet(item: Binding(get: { model.newConversationMachine.flatMap(model.machine) .map(MachineRef.init) }, set: { model.newConversationMachine = $0?.id })) { ref in
			NewConversationSheet(model: model, machine: ref.machine)
		}
		.alert("Something went wrong", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
			Button("OK") { model.error = nil }
		} message: {
			Text(model.error ?? "")
		}
	}

	@ViewBuilder private var detail: some View {
			if let selected = model.selected {
				ConversationView(
					store: selected.conversation,
					host: selected.machine.store,
					showInspector: $model.showInspector,
					rename: { model.renaming = model.selection }
				)
				.id(model.selection)
			} else if let draft = model.draft, let machine = model.machine(draft.machine) {
				DraftView(model: model, machine: machine, project: draft.project)
					.id(draft.project?.dir ?? "no project")
			} else if model.machines.isEmpty {
				SetupGuide { model.isAddingMachine = true }
			} else {
				Text("Select a conversation")
					.font(Typography.ui)
					.foregroundStyle(Palette.tertiaryText)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.background(Palette.background)
			}
	}
}

/// The sidebar's right edge: a hairline that resizes the sidebar when dragged.
private struct SidebarEdge: View {
	@Binding var width: CGFloat
	@State private var start: CGFloat?
	@State private var hovering = false

	var body: some View {
		Rectangle()
			.fill(hovering || start != nil ? Palette.rule2 : Palette.rule)
			.frame(width: 1)
			.frame(maxHeight: .infinity)
			.overlay {
				Color.clear
					.frame(width: 8)
					.contentShape(Rectangle())
					.onHover { inside in
						hovering = inside
						if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
					}
					.gesture(
						DragGesture(minimumDistance: 1, coordinateSpace: .global)
							.onChanged { value in
								let origin = start ?? width
								start = origin
								width = min(max(origin + value.translation.width, 220), 420)
							}
							.onEnded { _ in start = nil }
					)
			}
	}
}

/// The window with no machines: what a machine needs, the commands that set one up, and the way to add it.
struct SetupGuide: View {
	let add: () -> Void

	private static let commands = [
		"git clone git@github.com:brad-j/aludra.git && cd aludra",
		"sh scripts/install.sh",
		"aludra init",
		"aludra service install",
		"tailscale serve --bg 8724",
	]

	var body: some View {
		VStack(alignment: .leading, spacing: 18) {
			Text("connect a machine").font(Typography.label).foregroundStyle(Palette.ink3).textCase(.uppercase)
			Text("Amyrlin runs your sessions on your own machines. Each machine whose projects you want runs aludra, with Claude Code and Tailscale, and Amyrlin connects to it over your tailnet.")
				.font(Typography.reading)
				.foregroundStyle(Palette.ink2)
				.fixedSize(horizontal: false, vertical: true)
			VStack(alignment: .leading, spacing: 6) {
				Text("on the machine").font(Typography.label).foregroundStyle(Palette.ink3).textCase(.uppercase)
				VStack(alignment: .leading, spacing: 4) {
					ForEach(Self.commands, id: \.self) { command in
						HStack(alignment: .firstTextBaseline, spacing: 8) {
							Text("$").foregroundStyle(Palette.accent)
							Text(command).foregroundStyle(Palette.ink)
						}
					}
				}
				.font(Typography.code)
				.textSelection(.enabled)
				.padding(14)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(Palette.panel)
				.overlay(Rectangle().stroke(Palette.rule, lineWidth: 1))
			}
			Text("It needs Node 22.18 or later, pnpm, Claude Code logged in (claude auth login) and Tailscale. aludra doctor checks all of it and prints the address to add here.")
				.font(Typography.uiSmall)
				.foregroundStyle(Palette.ink3)
				.fixedSize(horizontal: false, vertical: true)
			Button("↵ add machine", action: add)
				.buttonStyle(QuietButton(fill: Palette.accent, ink: Palette.accentInk))
				.keyboardShortcut(.defaultAction)
		}
		.frame(maxWidth: 600 * Typography.scale, alignment: .leading)
		.padding(40)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Palette.background)
	}
}

struct RenameRef: Identifiable {
	let conversation: ConversationKey
	var id: ConversationKey { conversation }
}

/// A conversation's new title, saved on its host; the phone app shows it too.
struct RenameSheet: View {
	let model: AppModel
	let target: ConversationKey
	@Environment(\.dismiss) private var dismiss
	@State private var title = ""
	@FocusState private var focused: Bool

	private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack(spacing: 10) {
				Text("❯").font(Typography.uiStrong).foregroundStyle(Palette.accent)
				TextField("", text: $title, prompt: Text("title").foregroundStyle(Palette.ink3))
					.textFieldStyle(.plain)
					.font(Typography.ui)
					.foregroundStyle(Palette.ink)
					.focused($focused)
					.onSubmit(save)
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 13)
			Rectangle().fill(Palette.rule).frame(height: 1)
			HStack(spacing: 8) {
				Text("rename").font(Typography.label).foregroundStyle(Palette.ink3).textCase(.uppercase)
				Spacer()
				Button("esc cancel") { dismiss() }
					.buttonStyle(QuietButton())
					.keyboardShortcut(.cancelAction)
				Button("↵ rename", action: save)
					.buttonStyle(QuietButton(fill: trimmed.isEmpty ? nil : Palette.accent, ink: trimmed.isEmpty ? Palette.ink3 : Palette.accentInk))
					.keyboardShortcut(.defaultAction)
					.disabled(trimmed.isEmpty)
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 10)
		}
		.frame(width: 560 * Typography.scale)
		.background(Palette.paper)
		.onAppear {
			title = model.machine(target.machine)?.store.state.conversations[target.conversation]?.title ?? ""
			focused = true
		}
	}

	private func save() {
		guard !trimmed.isEmpty else { return }
		model.rename(target, to: trimmed)
		dismiss()
	}
}

/// Adds a host by its tailscale serve address. Type a full URL, or just the host (`aludra`, or its full tailnet name):
/// the line under the field shows the exact address it will connect to, or why it can't.
struct AddMachineSheet: View {
	let model: AppModel
	@Environment(\.dismiss) private var dismiss
	@State private var address = ""
	@FocusState private var focused: Bool

	/// The address to connect to, or why there isn't one.
	private var parsed: Result<URL, AddressProblem> {
		let text = address.trimmingCharacters(in: .whitespaces)
		guard !text.isEmpty else { return .failure(.empty) }
		let full = text.contains("://") ? text : "wss://\(text)"
		guard let url = URL(string: full), let scheme = url.scheme, url.host() != nil else { return .failure(.unreadable) }
		guard ["ws", "wss"].contains(scheme) else { return .failure(.scheme(scheme)) }
		let withPath = url.path().isEmpty || url.path() == "/" ? url.appending(path: "amyrlin") : url
		if model.machines.contains(where: { $0.url == withPath }) { return .failure(.duplicate) }
		return .success(withPath)
	}

	private enum AddressProblem: Error {
		case empty, unreadable, scheme(String), duplicate

		var isEmpty: Bool {
			if case .empty = self { true } else { false }
		}

		var text: String {
			switch self {
			case .empty: "the host's tailscale serve name, or a full ws:// or wss:// address"
			case .unreadable: "that isn't an address"
			case .scheme(let scheme): "\(scheme):// isn't a WebSocket address; use wss://"
			case .duplicate: "that machine is already in the sidebar"
			}
		}
	}

	private var url: URL? { try? parsed.get() }

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack(spacing: 10) {
				Text("+").font(Typography.uiStrong).foregroundStyle(Palette.accent)
				TextField("", text: $address, prompt: Text("machine.tailnet.ts.net").foregroundStyle(Palette.ink3))
					.textFieldStyle(.plain)
					.font(Typography.ui)
					.foregroundStyle(Palette.ink)
					.focused($focused)
					.onSubmit(add)
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 13)
			Rectangle().fill(Palette.rule).frame(height: 1)
			VStack(alignment: .leading, spacing: 8) {
				switch parsed {
				case .success(let url):
					HStack(spacing: 8) {
						Text("→").foregroundStyle(Palette.accent)
						Text(url.absoluteString).foregroundStyle(Palette.ink).textSelection(.enabled)
					}
				case .failure(let problem):
					HStack(spacing: 8) {
						Text(problem.isEmpty ? "·" : "!").foregroundStyle(problem.isEmpty ? Palette.ink3 : Palette.bad)
						Text(problem.text).foregroundStyle(problem.isEmpty ? Palette.ink3 : Palette.bad)
					}
				}
				Text("On the machine, aludra doctor prints this address. wss:// and the /amyrlin path are filled in when you leave them out. Tailscale says who you are, so there's nothing to sign in to.")
					.foregroundStyle(Palette.ink3)
					.fixedSize(horizontal: false, vertical: true)
			}
			.font(Typography.uiSmall)
			.padding(16)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(Palette.panel)
			Rectangle().fill(Palette.rule).frame(height: 1)
			HStack(spacing: 8) {
				Text("add machine").font(Typography.label).foregroundStyle(Palette.ink3).textCase(.uppercase)
				Spacer()
				Button("esc cancel") { dismiss() }
					.buttonStyle(QuietButton())
					.keyboardShortcut(.cancelAction)
				Button("↵ add", action: add)
					.buttonStyle(QuietButton(fill: url == nil ? nil : Palette.accent, ink: url == nil ? Palette.ink3 : Palette.accentInk))
					.keyboardShortcut(.defaultAction)
					.disabled(url == nil)
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 10)
		}
		.frame(width: 560 * Typography.scale)
		.background(Palette.paper)
		.onAppear { focused = true }
	}

	private func add() {
		guard let url else { return }
		model.addMachine(url)
		dismiss()
	}
}
