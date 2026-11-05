import AmyrlinCore
import SwiftUI

/// The top of a sandbox task's result page, for landing it (protocol section 10 item 19): the ship confirmation in
/// plain words while open, then how the ship went. Sending `sandbox.ship` is the approval of the push; the ship runs
/// as a turn, so its plan shows below like any run's, and `sandbox.shipped` ends it.
struct ShipPanel: View {
	let summary: ConversationSummary
	let host: HostStore
	let task: TaskStore
	@Binding var confirming: Bool
	/// Sends a reply in the conversation, for a stopped ship's free-text answer.
	let reply: (String) -> Void
	@Environment(AppModel.self) private var model: AppModel?
	@State private var to: ShipTo = .main
	@State private var note = ""
	@State private var sending = false
	@State private var failure: String?

	private var outcome: ShipOutcome? { host.state.ship(summary.id) }
	private var project: ProjectInfo? { host.projects.first { $0.dir == summary.source } ?? host.projects.first { $0.name == summary.project } }
	private var upstream: String { project?.checkout?.upstream?.replacingOccurrences(of: "origin/", with: "") ?? "main" }

	var body: some View {
		Group {
			if confirming {
				confirmation
			} else if case .shipped(let to, let pushed, let head, let commits, let pr) = outcome, summary.status != .busy {
				landed(to: to, pushed: pushed, head: head, commits: commits, pr: pr)
			} else if case .stopped(let kind, let reason) = outcome, summary.status != .busy {
				stopped(kind: kind, reason: reason)
			}
		}
		.frame(maxWidth: Metrics.measure + 48, alignment: .leading)
		.padding(.horizontal, 40)
		.padding(.top, 18)
		.frame(maxWidth: .infinity)
		.onAppear { to = host.sandboxes?.shipTo ?? .main }
	}

	private var confirmation: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("ship \(summary.title.lowercased())").font(Typography.label).textCase(.uppercase).foregroundStyle(Palette.ink3)
			Text(to == .main ? "This goes live on \(upstream)." : "This goes to a branch of its own with a pull request, for review before it lands.")
				.font(Typography.readingStrong).foregroundStyle(Palette.ink)
			Text(sentence)
				.font(Typography.reading).foregroundStyle(Palette.ink2)
				.fixedSize(horizontal: false, vertical: true)
			TextField("", text: $note, prompt: Text("anything the agent should know first (optional)").foregroundStyle(Palette.ink3), axis: .vertical)
				.textFieldStyle(.plain)
				.font(Typography.ui)
				.lineLimit(1...4)
				.padding(8)
				.background(Palette.paper)
				.overlay(Rectangle().stroke(Palette.rule))
			HStack(spacing: 10) {
				Segmented(choices: ["on \(upstream)", "as a PR"], selected: to == .branch ? 1 : 0) { to = $0 == 1 ? .branch : .main }
				Spacer()
				if let failure { Text(failure).font(Typography.uiSmall).foregroundStyle(Palette.bad).lineLimit(2) }
				Button("Cancel") { withAnimation(.row) { confirming = false } }
					.buttonStyle(QuietButton())
					.keyboardShortcut(.cancelAction)
				Button(sending ? "starting…" : to == .main ? "Ship to \(upstream)" : "Open a PR") { ship() }
					.buttonStyle(QuietButton(fill: Palette.accent, ink: Palette.accentInk))
					.disabled(sending)
			}
		}
		.padding(14)
		.background(Palette.paper2)
		.overlay(Rectangle().stroke(Palette.accent.opacity(0.7)))
	}

	/// What the ship will do, and what happens if it can't.
	private var sentence: String {
		let behind = project?.checkout?.behind ?? 0
		let moved = task.result?.headsUp.contains { $0.kind == "upstream" } == true || behind > 0
		let first = moved
			? "\(upstream.capitalized) has moved since this started. The agent brings in the latest \(upstream), adapts the work to it, runs the checks again, and only then pushes."
			: "The agent brings in the latest \(upstream), runs the checks again, and only then pushes."
		return first + " If anything fails, nothing is pushed and it asks you."
	}

	private func ship() {
		sending = true
		failure = nil
		let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
		Task {
			do {
				try await host.ship(summary.id, to: to, note: note.isEmpty ? nil : note)
				withAnimation(.row) { confirming = false }
				self.note = ""
			} catch let error as ProtocolError {
				failure = error.code == "busy" ? "It's running; ship once it's done" : error.message
			} catch {
				failure = String(describing: error)
			}
			sending = false
		}
	}

	private func landed(to: ShipTo, pushed: String, head: String, commits: Int, pr: String?) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 12) {
			Text("✓").foregroundStyle(Palette.add)
			VStack(alignment: .leading, spacing: 4) {
				Text(commits == 0 ? "Nothing to ship: it's all on \(pushed.replacingOccurrences(of: "origin/", with: "")) already." : pr != nil ? "The pull request is open." : to == .main ? "It's live on \(pushed.replacingOccurrences(of: "origin/", with: ""))." : "It's on \(pushed).")
					.font(Typography.readingStrong).foregroundStyle(Palette.ink)
				Text(commits == 0 ? "nothing pushed · \(head.prefix(7))" : "\(commits == 1 ? "1 commit" : "\(commits) commits") · \(head.prefix(7))")
					.font(Typography.uiSmall).foregroundStyle(Palette.ink3).textSelection(.enabled)
			}
			Spacer()
			if let pr, let url = URL(string: pr) {
				Link("Open the PR", destination: url).buttonStyle(QuietButton())
			}
			if let model {
				Button("Archive") { model.setArchived(ConversationKey(machine: machineID ?? UUID(), conversation: summary.id), true) }
					.buttonStyle(QuietButton())
					.disabled(machineID == nil)
					.help("Archiving removes its sandbox; the work is upstream")
			}
		}
		.padding(14)
		.background(Palette.add.opacity(0.05))
		.overlay(Rectangle().stroke(Palette.add.opacity(0.6)))
	}

	private func stopped(kind: ShipOutcome.FailureKind, reason: String) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("ship stopped · nothing was pushed").font(Typography.label).textCase(.uppercase).foregroundStyle(Palette.bad)
			Text(Self.words(kind)).font(Typography.readingStrong).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
			if !reason.isEmpty {
				Text(reason).font(Typography.reading).foregroundStyle(Palette.ink2).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
			}
			HStack(spacing: 10) {
				Spacer()
				// A blocked ship's question, when it has options, is in the result below; otherwise the box answers it.
				if kind == .blocked {
					Text(task.result?.question == nil ? "Answer in the box below, then ship again." : "Answer below, then ship again.")
						.font(Typography.uiSmall).foregroundStyle(Palette.ink3)
				}
				Button("Ship again") { withAnimation(.row) { confirming = true } }
					.buttonStyle(QuietButton(fill: kind == .upstreamMoved ? Palette.accent : nil, ink: kind == .upstreamMoved ? Palette.accentInk : Palette.ink))
			}
		}
		.padding(14)
		.background(Palette.bad.opacity(0.05))
		.overlay(Rectangle().stroke(Palette.bad.opacity(0.6)))
	}

	static func words(_ kind: ShipOutcome.FailureKind) -> String {
		switch kind {
		case .blocked: "The agent stopped before it was ready to push."
		case .upstreamMoved: "The upstream moved while it shipped, so the push was refused. Shipping again brings in the new commits."
		case .pushFailed: "git couldn't push to the upstream."
		case .checkFailed: "The final check before pushing failed."
		case .unknown(let raw): "It stopped (\(raw))."
		}
	}

	private var machineID: UUID? {
		model?.machines.first { $0.store === host }?.id
	}
}

/// A sandbox task's ··· menu: bring its commits home now, fast-forward the checkout to them, or drop the branch.
struct SandboxMenu: View {
	let model: AppModel
	let host: HostStore
	let summary: ConversationSummary
	@State private var confirmDiscard = false

	private var key: ConversationKey? {
		model.machines.first { $0.store === host }.map { ConversationKey(machine: $0.id, conversation: summary.id) }
	}

	var body: some View {
		let ready = summary.sandbox.map { $0.state == .ready || $0.state == .paused } ?? false
		let idle = summary.status != .busy && host.isConnected
		Button("Fetch Its Commits Now") { sync(merge: false) }.disabled(!ready || !idle)
		// A scratch sandbox has no checkout to merge into until it's a project.
		if summary.project != nil {
			Button("Merge into the Checkout Here") { sync(merge: true) }
				.disabled(!ready || !idle)
				.help("Fast-forward the checked-out branch on \(host.state.host?.name ?? "the machine") to this work, when that's safe")
		}
		Divider()
		Button("Discard \(summary.sandbox?.branch ?? "the Branch")…", role: .destructive) { discard() }
			.disabled(!idle)
		Divider()
		// Archiving removes the sandbox once its commits are home; for a task you won't ship.
		if let key {
			if summary.archived {
				Button("Bring Back from the Archive") { model.setArchived(key, false) }.disabled(!host.isConnected)
			} else {
				Button("Archive") { model.setArchived(key, true) }.disabled(!host.isConnected)
			}
		}
	}

	private func sync(merge: Bool) {
		Task {
			do {
				let result = try await host.syncSandbox(summary.id, merge: merge)
				let brought = result.commits == 0 ? "No new commits" : "\(result.commits == 1 ? "1 commit" : "\(result.commits) commits") on \(result.branch)"
				let left = result.uncommitted > 0 ? " · \(result.uncommitted) uncommitted in the sandbox" : ""
				if merge {
					model.note(result.merged ? "Merged into the checkout: \(brought)\(left)" : "Not merged: \(result.mergeRefusal ?? "the host said no")")
				} else {
					model.note("\(brought)\(left)")
				}
			} catch {
				model.note("Couldn't sync: \((error as? ProtocolError)?.message ?? String(describing: error))")
			}
		}
	}

	/// Deletes the local branch after asking; the sandbox stays until the task is archived.
	private func discard() {
		let alert = NSAlert()
		alert.messageText = "Discard \(summary.sandbox?.branch ?? "the branch")?"
		alert.informativeText = "Its commits are deleted from the checkout on \(host.state.host?.name ?? "the machine"), merged or not. The sandbox stays until you archive the task, and fetching brings the branch back."
		alert.addButton(withTitle: "Discard")
		alert.addButton(withTitle: "Cancel")
		alert.buttons.first?.hasDestructiveAction = true
		guard alert.runModal() == .alertFirstButtonReturn else { return }
		Task {
			do {
				let result = try await host.discardSandbox(summary.id)
				model.note(result.deleted ? "Discarded \(result.branch)" : "Already discarded")
			} catch {
				model.note("Couldn't discard: \((error as? ProtocolError)?.message ?? String(describing: error))")
			}
		}
	}
}
