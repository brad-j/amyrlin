import AmyrlinCore
import SwiftUI

/// New project (protocol section 10 item 20): a name checked as it's typed, an optional description, and where it
/// goes, `<root>/<name>`, private on `<owner>`. The host makes the folder, a first commit and the GitHub repository.
/// The same sheet makes a scratch sandbox's work a project (`sandbox.promote`). On success the new-task box opens on
/// the project, set to sandbox; a scratch task's page then has Ship.
struct ProjectSheet: View {
	enum Purpose: Identifiable, Hashable {
		/// A new, empty project on this machine.
		case create(machine: UUID)
		/// A scratch sandbox's work, as a project.
		case promote(ConversationKey, title: String)

		var id: String {
			switch self {
			case .create(let machine): "create-\(machine)"
			case .promote(let key, _): "promote-\(key.machine)-\(key.conversation)"
			}
		}

		var machine: UUID {
			switch self {
			case .create(let machine): machine
			case .promote(let key, _): key.machine
			}
		}
	}

	let model: AppModel
	let purpose: Purpose
	@Environment(\.dismiss) private var dismiss
	@State private var name = ""
	@State private var description = ""
	@State private var working = false
	@State private var failure: String?
	@FocusState private var nameFocused: Bool

	private var machine: AppModel.Machine? { model.machine(purpose.machine) }
	private var newProjects: NewProjects? { machine?.store.newProjects }
	private var problem: String? { ProjectNames.problem(name) ?? taken }
	/// A project of that name already listed on the machine; the host checks GitHub too.
	private var taken: String? {
		guard !name.isEmpty, machine?.store.projects.contains(where: { $0.name == name }) == true else { return nil }
		return "there's already a project called \(name)"
	}
	private var canCreate: Bool { !name.isEmpty && problem == nil && !working && newProjects != nil && machine?.store.isConnected == true }
	private var promoting: Bool { if case .promote = purpose { true } else { false } }

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack(spacing: 10) {
				Text("+").font(Typography.uiStrong).foregroundStyle(Palette.accent)
				TextField("", text: $name, prompt: Text("project-name").foregroundStyle(Palette.ink3))
					.textFieldStyle(.plain)
					.font(Typography.ui)
					.foregroundStyle(Palette.ink)
					.focused($nameFocused)
					.onSubmit(create)
					.disabled(working)
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 13)
			Rectangle().fill(Palette.rule).frame(height: 1)
			VStack(alignment: .leading, spacing: 10) {
				HStack(spacing: 8) {
					if let problem {
						Text("!").foregroundStyle(Palette.bad)
						Text(problem).foregroundStyle(Palette.bad)
					} else if let newProjects {
						Text("→").foregroundStyle(Palette.accent)
						Text("\(ConversationView.shortPath(newProjects.root))/\(name.isEmpty ? "name" : name)").foregroundStyle(name.isEmpty ? Palette.ink3 : Palette.ink)
						Text("· private on github.com/\(newProjects.owner)").foregroundStyle(Palette.ink3)
					} else {
						Text("!").foregroundStyle(Palette.wait)
						Text("\(machine.map(model.name(of:)) ?? "This machine") can't make projects now: its aludra needs newProjects set and gh signed in").foregroundStyle(Palette.wait)
					}
				}
				.lineLimit(2)
				TextField("", text: $description, prompt: Text("what it is (optional, goes in the README)").foregroundStyle(Palette.ink3), axis: .vertical)
					.textFieldStyle(.plain)
					.font(Typography.ui)
					.lineLimit(1...3)
					.padding(8)
					.background(Palette.paper)
					.overlay(Rectangle().stroke(Palette.rule))
					.disabled(working)
				Text(promoting
					? "The scratch task's commits become main, pushed to the new repository. The task then belongs to the project, and Ship lands its next work there."
					: "A folder with a README and a first commit, and a private GitHub repository it's pushed to. Every task after this can run in a sandbox.")
					.foregroundStyle(Palette.ink3)
					.fixedSize(horizontal: false, vertical: true)
				if let failure {
					Text(failure).foregroundStyle(Palette.bad).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
				}
			}
			.font(Typography.uiSmall)
			.padding(16)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(Palette.panel)
			Rectangle().fill(Palette.rule).frame(height: 1)
			HStack(spacing: 8) {
				Text(promoting ? "make it a project" : "new project").font(Typography.label).foregroundStyle(Palette.ink3).textCase(.uppercase)
				Spacer()
				Button("esc cancel") { dismiss() }
					.buttonStyle(QuietButton())
					.keyboardShortcut(.cancelAction)
					.disabled(working)
				Button(working ? "making it…" : "↵ create", action: create)
					.buttonStyle(QuietButton(fill: canCreate ? Palette.accent : nil, ink: canCreate ? Palette.accentInk : Palette.ink3))
					.keyboardShortcut(.defaultAction)
					.disabled(!canCreate)
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 10)
		}
		.frame(width: 580 * Typography.scale)
		.background(Palette.paper)
		.interactiveDismissDisabled(working)
		.onAppear {
			if case .promote(_, let title) = purpose { name = ProjectNames.suggest(title) }
			nameFocused = true
			#if DEBUG
			// `--args -openNewProject -createProjectNamed x` fills the name and presses create, to check the whole path
			// against a host from a script. It really makes the project and its GitHub repository.
			let arguments = ProcessInfo.processInfo.arguments
			if let flag = arguments.firstIndex(of: "-createProjectNamed"), flag + 1 < arguments.count {
				name = arguments[flag + 1]
				description = "A throwaway project made by amyrlin's New project check; delete it."
				Task {
					try? await Task.sleep(for: .seconds(1))
					create()
				}
			}
			#endif
		}
		.onChange(of: name) { _, _ in failure = nil }
	}

	private func create() {
		guard canCreate, let machine else { return }
		working = true
		failure = nil
		let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
		Task {
			do {
				switch purpose {
				case .create:
					let project = try await machine.store.createProject(name: name, description: description.isEmpty ? nil : description)
					dismiss()
					model.newTask(in: project, on: machine.id)
				case .promote(let key, _):
					_ = try await machine.store.promote(key.conversation, name: name, description: description.isEmpty ? nil : description)
					dismiss()
					model.note("\(name) is a project now; Ship lands this task's work there")
				}
			} catch let error as ProtocolError {
				failure = error.message
			} catch {
				failure = String(describing: error)
			}
			working = false
		}
	}
}
