import AmyrlinCore
import SwiftUI

/// A machine's aludra settings. Every field is drawn from the host's description of the setting (`HostSetting`), so a
/// setting added on the host shows here without a change. Only what changed is sent; a refused save lists every reason,
/// and a saved one says what waits for a restart. The machine's menu offers it only on hosts that answer `settings.get`.
struct HostSettingsSheet: View {
	let model: AppModel
	let machine: AppModel.Machine
	@Environment(\.dismiss) private var dismiss
	@State private var form: SettingsForm?
	@State private var saving = false
	@State private var note: Note?
	/// Set once the host has been asked, so "reading" can give way to why there's nothing.
	@State private var asked = false

	private enum Note {
		case saved(String)
		case refused([String])
	}

	private var store: HostStore { machine.store }
	private var dirty: Bool { form?.isDirty ?? false }

	/// The form, with any edit clearing what the last save said.
	private var editing: Binding<SettingsForm>? {
		guard let form else { return nil }
		return Binding(get: { self.form ?? form }, set: { self.form = $0; note = nil })
	}

	var body: some View {
		VStack(spacing: 0) {
			ScrollView {
				if let editing {
					fields(editing)
				} else {
					Text(asked ? "\(model.name(of: machine)) has no settings to show" : "reading settings…")
						.font(Typography.ui)
						.foregroundStyle(Palette.ink3)
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(16)
				}
			}
			Rectangle().fill(Palette.rule).frame(height: 1)
			if let note { noteView(note) }
			HStack(spacing: 8) {
				Text("\(model.name(of: machine)) settings").font(Typography.label).foregroundStyle(Palette.ink3).textCase(.uppercase)
				Spacer()
				Button(dirty ? "esc cancel" : "esc close") { dismiss() }
					.buttonStyle(QuietButton())
					.keyboardShortcut(.cancelAction)
				Button(saving ? "saving…" : "⌘↵ save", action: save)
					.buttonStyle(QuietButton(fill: dirty ? Palette.accent : nil, ink: dirty ? Palette.accentInk : Palette.ink3))
					.keyboardShortcut(.return, modifiers: .command)
					.disabled(!dirty || saving)
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 10)
		}
		.frame(width: 660 * Typography.scale, height: 600 * Typography.scale)
		.background(Palette.paper)
		.task {
			if let settings = store.settings { form = SettingsForm(settings) }
			// The last read may be old: another app can have changed them, or the file by hand.
			await store.refreshSettings()
			asked = true
			if !dirty { form = store.settings.map(SettingsForm.init) }
		}
	}

	private func fields(_ form: Binding<SettingsForm>) -> some View {
		let settings = form.wrappedValue.settings
		return VStack(alignment: .leading, spacing: 22) {
			ForEach(settings.settings) { setting in
				SettingField(setting: setting, form: form, pending: settings.restart.contains(setting.key), models: store.info?.models ?? [])
			}
			VStack(alignment: .leading, spacing: 6) {
				HStack(alignment: .firstTextBaseline, spacing: 8) {
					Text("file").foregroundStyle(Palette.ink3)
					Text(settings.file ?? "none: the host started without a settings file, so nothing can be saved")
						.foregroundStyle(settings.file == nil ? Palette.wait : Palette.ink2)
						.textSelection(.enabled)
				}
				ForEach(settings.errors, id: \.self) { error in
					reason(error)
				}
			}
			.font(Typography.uiSmall)
		}
		.padding(16)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private func noteView(_ note: Note) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			switch note {
			case .saved(let text):
				Text(text).foregroundStyle(Palette.ink2)
			case .refused(let reasons):
				ForEach(reasons, id: \.self) { reason($0) }
			}
		}
		.font(Typography.uiSmall)
		.padding(.horizontal, 16)
		.padding(.vertical, 10)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Palette.panel)
		.overlay(alignment: .bottom) { Rectangle().fill(Palette.rule).frame(height: 1) }
	}

	private func reason(_ text: String) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Text("!")
			Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
		}
		.foregroundStyle(Palette.bad)
	}

	private func save() {
		guard let changes = form?.changes, !changes.isEmpty, !saving else { return }
		saving = true
		note = nil
		Task {
			do {
				let saved = try await store.saveSettings(changes)
				form = SettingsForm(saved)
				let waiting = saved.settings.filter { saved.restart.contains($0.key) }.map(\.label)
				note = .saved(waiting.isEmpty ? "saved" : "saved · \(waiting.joined(separator: ", ")) after a restart")
			} catch let error as ProtocolError {
				note = .refused(error.reasons)
			} catch {
				note = .refused([String(describing: error)])
			}
			saving = false
		}
	}
}

/// One setting: its label and marks (waiting for a restart, file-only, at its default or a way back to it), its control
/// or, when it isn't edited here, its value, and its help.
private struct SettingField: View {
	let setting: HostSetting
	@Binding var form: SettingsForm
	/// Saved, and waiting for the host to restart.
	let pending: Bool
	/// The host's models, for `model` and `models` settings.
	let models: [ModelInfo]

	private var key: String { setting.key }

	var body: some View {
		VStack(alignment: .leading, spacing: 7) {
			HStack(alignment: .firstTextBaseline, spacing: 10) {
				Text(setting.label).font(Typography.uiStrong).foregroundStyle(Palette.ink)
				if pending { tag("after a restart", Palette.wait) }
				if !setting.editable {
					tag("settings file only")
				} else if !SettingsForm.isEditable(setting) {
					tag("not editable here")
				} else if setting.default != nil {
					if form.isAtDefault(setting) {
						tag("default")
					} else {
						BracketButton("use default") { form.useDefault(setting) }
							.help("Put back the host's default, \(SettingsForm.shown(setting.default!))")
					}
				}
				Spacer(minLength: 0)
			}
			if SettingsForm.isEditable(setting) {
				control
			} else {
				Text(SettingsForm.shown(setting.value))
					.font(Typography.ui)
					.foregroundStyle(Palette.ink2)
					.textSelection(.enabled)
			}
			if !help.isEmpty {
				Text(help)
					.font(Typography.uiSmall)
					.foregroundStyle(Palette.ink3)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
	}

	private var help: String {
		guard setting.editable, !setting.live else { return setting.help }
		return [setting.help, "A change takes effect when the host restarts."].filter { !$0.isEmpty }.joined(separator: " ")
	}

	private func tag(_ text: String, _ color: Color = Palette.ink3) -> some View {
		Text(text).font(Typography.uiSmall).foregroundStyle(color)
	}

	@ViewBuilder private var control: some View {
		switch setting.kind {
		case .choice:
			HStack(spacing: 6) {
				ForEach(setting.options, id: \.self) { option in
					let picked = form.draft(key) == .text(option)
					Button(option) { form.edit(key, .text(option)) }
						.buttonStyle(QuietButton(fill: picked ? Palette.accent : nil, ink: picked ? Palette.accentInk : Palette.ink2))
				}
			}
		case .workspaces:
			WorkspacesField(workspaces: workspaces)
		case .list, .models:
			HStack(alignment: .top, spacing: 8) {
				LinesField(text: text, placeholder: setting.kind == .models ? "provider/model, one per line" : "one per line")
				if setting.kind == .models, !models.isEmpty {
					modelMenu("add") { picked in
						let lines = text.wrappedValue.split(whereSeparator: \.isNewline).map(String.init) + [picked]
						text.wrappedValue = lines.joined(separator: "\n")
					}
				}
			}
		case .model:
			HStack(spacing: 8) {
				LineField(text: text, placeholder: "provider/model")
				if !models.isEmpty { modelMenu("pick") { text.wrappedValue = $0 } }
			}
		default:
			LineField(text: text, placeholder: setting.kind == .path ? "path" : "")
		}
	}

	/// The host's models by provider, each as `provider/id`.
	private func modelMenu(_ title: String, pick: @escaping (String) -> Void) -> some View {
		Menu {
			let groups = ModelNaming.byProvider(models)
			ForEach(groups, id: \.provider) { group in
				Section(ModelNaming.providerHeading(group.provider)) {
					ForEach(group.models) { model in
						Button(model.name ?? model.modelId) { pick("\(model.provider)/\(model.modelId)") }
					}
				}
			}
		} label: {
			Text("[\(title)]").font(Typography.uiSmall).foregroundStyle(Palette.ink3)
		}
		.menuStyle(.button)
		.buttonStyle(.plain)
		.menuIndicator(.hidden)
		.fixedSize()
		.help("The models this host has")
	}

	private var text: Binding<String> {
		Binding(
			get: { if case .text(let text) = form.draft(key) { text } else { "" } },
			set: { form.edit(key, .text($0)) }
		)
	}

	private var workspaces: Binding<[SettingsForm.WorkspaceDraft]> {
		Binding(
			get: { if case .workspaces(let drafts) = form.draft(key) { drafts } else { [] } },
			set: { form.edit(key, .workspaces($0)) }
		)
	}
}

/// Each workspace as its name and its roots, one per line, with ways to add and remove them.
private struct WorkspacesField: View {
	@Binding var workspaces: [SettingsForm.WorkspaceDraft]

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			ForEach($workspaces) { $workspace in
				VStack(alignment: .leading, spacing: 6) {
					HStack(spacing: 8) {
						LineField(text: $workspace.name, placeholder: "name")
						if workspaces.count > 1 {
							BracketButton("remove") { workspaces.removeAll { $0.id == workspace.id } }
								.help("Remove \(workspace.name.isEmpty ? "this workspace" : workspace.name)")
						}
					}
					LinesField(text: $workspace.roots, placeholder: "~/code/*, one per line")
				}
				.padding(.leading, 10)
				.overlay(alignment: .leading) { Rectangle().fill(Palette.rule2).frame(width: 1) }
			}
			BracketButton("add a workspace") { workspaces.append(SettingsForm.WorkspaceDraft()) }
		}
	}
}

/// A one-line field in the sidebar search's box.
private struct LineField: View {
	@Binding var text: String
	let placeholder: String
	@FocusState private var focused: Bool

	var body: some View {
		TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Palette.ink3))
			.textFieldStyle(.plain)
			.font(Typography.ui)
			.foregroundStyle(Palette.ink)
			.focused($focused)
			.padding(.horizontal, 10)
			.frame(minHeight: 28 * Typography.scale)
			.background(Palette.paper2)
			.overlay(Rectangle().stroke(focused ? Palette.rule2 : Palette.rule))
	}
}

/// A field of one entry per line, as tall as its lines and one more, up to eight.
private struct LinesField: View {
	@Binding var text: String
	let placeholder: String
	@FocusState private var focused: Bool

	private var lines: Int { text.split(separator: "\n", omittingEmptySubsequences: false).count }

	var body: some View {
		TextEditor(text: $text)
			.font(Typography.ui)
			.foregroundStyle(Palette.ink)
			.scrollContentBackground(.hidden)
			.focused($focused)
			.frame(height: CGFloat(min(max(lines + 1, 2), 8)) * 17 * Typography.scale)
			.padding(.horizontal, 6)
			.padding(.vertical, 5)
			.background(Palette.paper2)
			.overlay(alignment: .topLeading) {
				if text.isEmpty {
					Text(placeholder).font(Typography.ui).foregroundStyle(Palette.ink3).padding(.horizontal, 11).padding(.vertical, 5).allowsHitTesting(false)
				}
			}
			.overlay(Rectangle().stroke(focused ? Palette.rule2 : Palette.rule))
	}
}
