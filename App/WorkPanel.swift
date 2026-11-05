import AmyrlinCore
import SwiftUI

/// A sandbox task's right column (option B, 2026-11-04): what it's doing and how far along, without the transcript.
/// The plan with its current step; the files it changed (the branch's diff once its commits are home, with each
/// file's patch on a click, or the files its calls edited while it runs); its checks; a short timeline of the latest
/// turn's calls; then the sandbox and the agent in a quiet footer. A local session keeps the old inspector.
struct WorkPanel: View {
	let store: ConversationStore
	let host: HostStore
	let task: TaskStore

	private var summary: ConversationSummary? { host.state.conversations[store.id] }

	var body: some View {
		VStack(spacing: 0) {
			HeaderBar {
				Text("this task").font(Typography.label).foregroundStyle(Palette.ink3).textCase(.uppercase)
				Spacer()
				if let summary {
					Text(Date(timeIntervalSince1970: TimeInterval(summary.createdAt) / 1000).shortAge)
						.font(Typography.uiSmall).foregroundStyle(Palette.ink3)
				}
			}
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					plan
					files
					checks
					timeline
					footer
				}
				.padding(.horizontal, 16)
				.padding(.bottom, 12)
			}
		}
		.background(Palette.panel)
		.task(id: task.result?.at) {
			// The branch's diff, once per answer; while it runs, the edits below stand in for it.
			if task.result?.isRunning == false, (task.result?.code.files ?? 0) > 0 { await task.loadCode() }
		}
	}

	// MARK: Plan

	@ViewBuilder private var plan: some View {
		if let steps = task.result?.plan, !steps.isEmpty {
			let current = steps.firstIndex { !$0.done }
			PanelSection("plan", trailing: "\(steps.filter(\.done).count) of \(steps.count)") {
				VStack(alignment: .leading, spacing: 4) {
					ForEach(steps.indices, id: \.self) { index in
						let step = steps[index]
						HStack(alignment: .firstTextBaseline, spacing: 8) {
							Group {
								if step.done { Text("✓").foregroundStyle(Palette.add) }
								else if index == current, summary?.status == .busy { Text("›").foregroundStyle(Palette.accent) }
								else { Text("·").foregroundStyle(Palette.ink3) }
							}
							.frame(width: 10, alignment: .leading)
							Text(step.text)
								.foregroundStyle(step.done ? Palette.ink2 : index == current ? Palette.ink : Palette.ink3)
								.fixedSize(horizontal: false, vertical: true)
						}
						.font(Typography.uiSansSmall)
					}
				}
			}
		}
	}

	// MARK: Files

	@ViewBuilder private var files: some View {
		let running = summary?.status == .busy
		if !running, case .success(let changes)? = task.code, case .available(_, let add, let del, let list) = changes, !list.isEmpty {
			PanelSection("files", trailing: "\(list.count) · +\(add) −\(del)") {
				ChangesView(changes: changes, diff: task.diff)
			}
		} else {
			let edited = editedFiles
			if !edited.isEmpty {
				PanelSection(running ? "files so far" : "files edited", trailing: "\(edited.count)") {
					VStack(alignment: .leading, spacing: 3) {
						ForEach(edited, id: \.path) { file in
							HStack(spacing: 8) {
								Text(file.new ? "A" : "M").foregroundStyle(file.new ? Palette.add : Palette.ink3).frame(width: 10)
								Text(file.path).foregroundStyle(Palette.ink2).lineLimit(1).truncationMode(.head)
								Spacer(minLength: 4)
								if file.editing { Spinner(color: Palette.accent).frame(width: 8, height: 8) }
							}
							.font(Typography.uiSmall)
						}
						if running {
							Text("line counts once its commits come home").font(Typography.uiSmall).foregroundStyle(Palette.ink3).padding(.top, 2)
						}
					}
				}
			}
		}
	}

	/// The files the latest turn's calls wrote or edited, by path relative to the project, in the order first touched.
	private var editedFiles: [(path: String, new: Bool, editing: Bool)] {
		let dir = summary?.dir ?? ""
		var seen: [String: (new: Bool, editing: Bool)] = [:]
		var order: [String] = []
		for call in WorkTimeline.calls(rows) where call.name == "edit" || call.name == "write" {
			guard var path = call.args["path"]?.stringValue ?? call.args["file_path"]?.stringValue else { continue }
			if !dir.isEmpty, path.hasPrefix(dir + "/") { path = String(path.dropFirst(dir.count + 1)) }
			let editing = if case .running = call.status { true } else { false }
			if seen[path] == nil { order.append(path) }
			seen[path] = (new: (seen[path]?.new ?? false) || call.name == "write", editing: editing)
		}
		return order.map { (path: $0, new: seen[$0]!.new, editing: seen[$0]!.editing) }
	}

	private var rows: [TranscriptRow] {
		TranscriptLayout.rows(state: store.state)
	}

	// MARK: Checks

	@ViewBuilder private var checks: some View {
		let line = summary?.line ?? ""
		if let checks = task.result?.checks, !checks.isEmpty {
			PanelSection("checks", trailing: line.hasSuffix("· running checks") ? "running" : nil) {
				VStack(alignment: .leading, spacing: 3) {
					ForEach(checks, id: \.name) { check in
						HStack(spacing: 8) {
							Text(check.ok ? "✓" : "✗").foregroundStyle(check.ok ? Palette.add : Palette.wait).frame(width: 10)
							Text(check.name).foregroundStyle(Palette.ink2).lineLimit(1).truncationMode(.tail)
						}
						.font(Typography.uiSmall)
						.help(check.detail ?? (check.ok ? "Passed" : "Failed"))
					}
				}
			}
		} else if line.hasSuffix("· running checks") {
			PanelSection("checks") {
				HStack(spacing: 8) { Spinner(color: Palette.accent).frame(width: 8, height: 8); Text("running the project's checks") }
					.font(Typography.uiSmall).foregroundStyle(Palette.ink3)
			}
		}
	}

	// MARK: Timeline

	@ViewBuilder private var timeline: some View {
		let steps = WorkTimeline.steps(WorkTimeline.calls(rows))
		if !steps.isEmpty {
			PanelSection("what it did", trailing: "latest turn") {
				VStack(alignment: .leading, spacing: 3) {
					ForEach(steps.indices, id: \.self) { index in
						let step = steps[index]
						HStack(alignment: .firstTextBaseline, spacing: 8) {
							Circle()
								.fill(step.running ? Palette.accent : step.failed ? Palette.wait : Palette.rule2)
								.frame(width: 5, height: 5)
								.frame(width: 10)
							Text(step.text)
								.foregroundStyle(step.running ? Palette.ink : step.failed ? Palette.wait : Palette.ink2)
								.lineLimit(2)
								.fixedSize(horizontal: false, vertical: true)
						}
						.font(Typography.uiSansSmall)
					}
				}
			}
		}
	}

	// MARK: Footer

	private var footer: some View {
		let settings = store.settings
		let model = ComposerView.modelName(store: store, host: host)
		let thinking = settings?.stored.thinkingLevel ?? settings?.effective.thinkingLevel
		return PanelSection("sandbox") {
			VStack(alignment: .leading, spacing: 4) {
				if let sandbox = summary?.sandbox {
					footerRow(sandbox.branch, [sandbox.size?.rawValue, sandbox.state == .paused ? "paused" : sandbox.state.rawValue].compactMap(\.self).joined(separator: " · "))
					if let base = sandbox.base { footerRow("from", String(base.prefix(7))) }
				}
				HStack(spacing: 0) {
					Text("agent").foregroundStyle(Palette.ink3)
					Spacer()
					Menu { ModelChoices(store: store, host: host) } label: {
						Text(model ?? "—").foregroundStyle(Palette.ink2)
					}
					.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
					.disabled(host.info?.models.isEmpty ?? true)
					if let thinking {
						Text(" · ").foregroundStyle(Palette.ink3)
						Menu { ThinkingChoices(store: store, host: host) } label: {
							Text(thinking.rawValue).foregroundStyle(Palette.ink2)
						}
						.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
					}
				}
				if let context = ComposerView.contextLine(store: store, host: host) {
					footerRow("context", context)
				}
			}
			.font(Typography.uiSmall)
		}
	}

	private func footerRow(_ label: String, _ value: String) -> some View {
		HStack {
			Text(label).foregroundStyle(Palette.ink3)
			Spacer()
			Text(value).foregroundStyle(Palette.ink2).monospacedDigit().lineLimit(1)
		}
	}
}
