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
					showInspector: $model.showInspector
				)
				.id(model.selection)
			} else if let draft = model.draft, let machine = model.machine(draft.machine) {
				DraftView(model: model, machine: machine, project: draft.project)
					.id(draft.project?.dir ?? "no project")
			} else if model.machines.isEmpty {
				VStack(spacing: 10) {
					Text("No machines yet")
						.font(Typography.ui)
						.foregroundStyle(Palette.secondaryText)
					Button("Add Machine…") { model.isAddingMachine = true }
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.background(Palette.background)
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

struct AddMachineSheet: View {
	let model: AppModel
	@Environment(\.dismiss) private var dismiss
	@State private var address = "wss://"

	private var url: URL? {
		guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)),
			let scheme = url.scheme, ["ws", "wss"].contains(scheme), url.host() != nil
		else { return nil }
		return url.path().isEmpty || url.path() == "/" ? url.appending(path: "amyrlin") : url
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Add Machine").font(.headline)
			TextField("wss://machine.tailnet.ts.net/amyrlin", text: $address)
				.textFieldStyle(.roundedBorder)
				.font(Typography.code)
				.frame(width: 380)
				.onSubmit(add)
			Text("The host's tailscale serve address, for example wss://aludra.example.ts.net/amyrlin.")
				.font(Typography.ui)
				.foregroundStyle(Palette.secondaryText)
			HStack {
				Spacer()
				Button("Cancel", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Button("Add", action: add)
					.keyboardShortcut(.defaultAction)
					.disabled(url == nil)
			}
		}
		.padding(20)
	}

	private func add() {
		guard let url else { return }
		model.addMachine(url)
		dismiss()
	}
}
