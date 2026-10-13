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
			CommandGroup(after: .newItem) {
				Button("Add Machine…") { model.isAddingMachine = true }
					.keyboardShortcut("n", modifiers: [.command, .shift])
			}
			CommandGroup(after: .sidebar) {
				Button(model.showInspector ? "Hide Inspector" : "Show Inspector") { model.showInspector.toggle() }
					.keyboardShortcut("i", modifiers: [.command, .option])
			}
		}
	}
}

struct MainView: View {
	@Bindable var model: AppModel

	var body: some View {
		NavigationSplitView {
			SidebarView(model: model)
				.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
		} detail: {
			if let selected = model.selected {
				ConversationView(
					store: selected.conversation,
					host: selected.machine.store,
					showInspector: $model.showInspector
				)
				.id(model.selection)
			} else if let draft = model.draft, let machine = model.machine(draft.machine) {
				DraftView(model: model, machine: machine, project: draft.project)
					.id(draft.project.dir)
			} else if model.machines.isEmpty {
				VStack(spacing: 10) {
					Text("No machines yet")
						.font(Typography.reading)
						.foregroundStyle(Palette.secondaryText)
					Button("Add Machine…") { model.isAddingMachine = true }
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.background(Palette.background)
			} else {
				Text("Select a conversation")
					.font(Typography.reading)
					.foregroundStyle(Palette.tertiaryText)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.background(Palette.background)
			}
		}
		// On the split view, not the detail: the detail is rebuilt per selection, which dropped the inspector.
		.inspector(isPresented: $model.showInspector) {
			Group {
				if let selected = model.selected {
					InspectorView(store: selected.conversation, host: selected.machine.store)
						.id(model.selection)
				} else {
					Text("No conversation selected")
						.font(Typography.readingSmall)
						.foregroundStyle(Palette.tertiaryText)
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
				.font(Typography.readingSmall)
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
