import AmyrlinCore
import AppKit
import SwiftUI

/// A sandbox task's result page, for judging it without reading the code (protocol section 10 item 19). While it
/// works: the agent's plan as a checklist, the current step marked. Once it answers: a question with its choices as
/// buttons, what it did in a sentence, checks, what changed for someone using the project, before and after
/// screenshots, heads-ups in plain words, and the code folded into one line at the bottom.
struct ResultView: View {
	let task: TaskStore
	let summary: ConversationSummary?
	/// Sends a reply, as the composer would: a question's option.
	let reply: (String) -> Void

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 0) {
				content
			}
			.frame(maxWidth: Metrics.measure + 48, alignment: .leading)
			.padding(.horizontal, 40)
			.padding(.vertical, 22)
			.frame(maxWidth: .infinity)
		}
	}

	@ViewBuilder private var content: some View {
		if let sandbox = summary?.sandbox, sandbox.state == .preparing {
			Preparing(step: sandbox.step)
		} else if let sandbox = summary?.sandbox, sandbox.state == .failed {
			Said(text: "The sandbox couldn't be made, so nothing ran. Start a new task to try again.", color: Palette.bad)
			Detail(text: sandbox.reason ?? summary?.stuck?.detail ?? "No reason given.")
		} else if let result = task.result, result.isRunning || summary?.status == .busy {
			Running(plan: result.plan ?? [], line: summary?.line)
		} else if let result = task.result {
			Finished(task: task, result: result, summary: summary, reply: reply)
		} else if summary?.status == .busy {
			Running(plan: [], line: summary?.line)
		} else if task.hasRead {
			Text(task.problem ?? "No result yet. It shows here once the agent answers.")
				.font(Typography.reading)
				.foregroundStyle(task.problem == nil ? Palette.ink3 : Palette.bad)
		}
	}
}

/// A section's small-caps label, with an optional quiet action at its right.
private struct SectionLabel: View {
	let title: String
	var trailing: AnyView?

	var body: some View {
		HStack(spacing: 10) {
			Text(title).font(Typography.label).textCase(.uppercase).foregroundStyle(Palette.ink3)
			Spacer()
			trailing
		}
		.padding(.top, 22)
		.padding(.bottom, 8)
	}
}

/// The page's lead sentence.
private struct Said: View {
	let text: String
	var color: Color = Palette.ink

	var body: some View {
		Text(text)
			.font(.custom("IBM Plex Sans", size: 17 * Typography.textScale).weight(.light))
			.lineSpacing(5)
			.foregroundStyle(color)
			.textSelection(.enabled)
			.fixedSize(horizontal: false, vertical: true)
	}
}

private struct Detail: View {
	let text: String

	var body: some View {
		Text(text)
			.font(Typography.codeSmall)
			.foregroundStyle(Palette.ink2)
			.textSelection(.enabled)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(10)
			.background(Palette.panel)
			.overlay(Rectangle().stroke(Palette.rule))
			.padding(.top, 12)
	}
}

/// The sandbox being made, its step in words.
private struct Preparing: View {
	let step: String?

	var body: some View {
		HStack(spacing: 10) {
			StateMark(.running, size: 12)
			Said(text: "Making its sandbox: \(Self.words(step)). Your message waits and goes in once it's ready.", color: Palette.ink2)
		}
	}

	static func words(_ step: String?) -> String {
		switch step {
		case "waiting": "waiting for the project's template, which another task is making"
		case "cloning": "copying the project's last commit"
		case "installing": "installing its dependencies"
		case "saving": "saving the template for the next task"
		case "starting": "starting its machine"
		default: "getting ready"
		}
	}
}

/// The plan while it works: done steps checked, the first open one current, the rest waiting.
private struct Running: View {
	let plan: [TaskResult.Step]
	let line: String?

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Said(text: plan.isEmpty ? "Working on it." : "Working on it. Here's the plan:", color: Palette.ink2)
			if plan.isEmpty, let line, line != "Working" {
				HStack(spacing: 10) {
					StateMark(.running, size: 10)
					Text(line).font(Typography.reading).foregroundStyle(Palette.ink)
				}
				.padding(.top, 14)
			}
			let current = plan.firstIndex { !$0.done }
			VStack(alignment: .leading, spacing: 8) {
				ForEach(plan.indices, id: \.self) { index in
					let step = plan[index]
					HStack(alignment: .firstTextBaseline, spacing: 10) {
						Group {
							if step.done {
								Text("✓").foregroundStyle(Palette.add)
							} else if index == current {
								Text("›").foregroundStyle(Palette.accent)
							} else {
								Text("·").foregroundStyle(Palette.ink3)
							}
						}
						.font(Typography.uiStrong)
						.frame(width: 14, alignment: .leading)
						Text(step.text)
							.font(Typography.reading)
							.foregroundStyle(step.done || index == current ? Palette.ink : Palette.ink3)
						if index == current {
							Spinner(color: Palette.accent).frame(width: 9, height: 9)
						}
					}
				}
			}
			.padding(.top, 14)
		}
	}
}

/// An answered turn's result.
private struct Finished: View {
	let task: TaskStore
	let result: TaskResult
	let summary: ConversationSummary?
	let reply: (String) -> Void
	@State private var codeOpen = false

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			if let question = result.question {
				QuestionBox(question: question, reply: reply, disabled: summary?.status == .busy)
					.padding(.bottom, 18)
			}
			Said(text: result.summary ?? "")
			if !result.checks.isEmpty {
				SectionLabel(title: "checks")
				ChecksRow(checks: result.checks, running: summary?.line?.hasSuffix("· running checks") == true)
			} else if summary?.line?.hasSuffix("· running checks") == true {
				SectionLabel(title: "checks")
				HStack(spacing: 8) { StateMark(.running, size: 10); Text("running the project's checks") }
					.font(Typography.ui).foregroundStyle(Palette.ink3)
			}
			if !result.changes.isEmpty {
				SectionLabel(title: "what changed for someone using it")
				VStack(alignment: .leading, spacing: 6) {
					ForEach(result.changes, id: \.self) { change in
						HStack(alignment: .firstTextBaseline, spacing: 10) {
							Text("•").foregroundStyle(Palette.ink3)
							Text(change).foregroundStyle(Palette.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
						}
						.font(Typography.reading)
					}
				}
			}
			if !result.shots.isEmpty {
				SectionLabel(title: "before and after")
				ShotPairs(task: task, shots: result.shots, base: summary?.sandbox?.base)
			} else if summary?.line?.hasSuffix("· taking screenshots") == true {
				SectionLabel(title: "before and after")
				HStack(spacing: 8) { StateMark(.running, size: 10); Text("taking screenshots") }
					.font(Typography.ui).foregroundStyle(Palette.ink3)
			}
			if !result.headsUp.isEmpty {
				SectionLabel(title: "heads up")
				VStack(alignment: .leading, spacing: 6) {
					ForEach(result.headsUp, id: \.self) { item in
						HStack(alignment: .firstTextBaseline, spacing: 8) {
							Text(Self.kind(item.kind)).font(Typography.uiSmall).foregroundStyle(Palette.wait)
							Text(item.text).font(Typography.reading).foregroundStyle(Palette.ink).textSelection(.enabled)
								.fixedSize(horizontal: false, vertical: true)
						}
					}
				}
				.padding(.leading, 12)
				.overlay(alignment: .leading) { Rectangle().fill(Palette.wait).frame(width: 2) }
			}
			if summary?.sandbox != nil {
				CodeLine(task: task, code: result.code, open: $codeOpen)
			}
		}
	}

	static func kind(_ kind: String) -> String {
		switch kind {
		case "upstream": "upstream"
		case "dependency": "dependency"
		case "left": "left behind"
		default: "note"
		}
	}
}

/// The question an answer ended on, with its options as buttons that send the option's text; the composer takes any
/// other answer.
private struct QuestionBox: View {
	let question: TaskResult.Question
	let reply: (String) -> Void
	let disabled: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("needs your call").font(Typography.label).textCase(.uppercase).foregroundStyle(Palette.wait)
			Text(question.text).font(Typography.readingStrong).foregroundStyle(Palette.ink).textSelection(.enabled)
				.fixedSize(horizontal: false, vertical: true)
			if let why = question.why {
				Text(why).font(Typography.readingSmall).foregroundStyle(Palette.ink2).textSelection(.enabled)
					.fixedSize(horizontal: false, vertical: true)
			}
			if !question.options.isEmpty {
				FlowButtons(options: question.options, disabled: disabled, pick: reply)
			}
			Text("Or answer in the box below.").font(Typography.uiSmall).foregroundStyle(Palette.ink3)
		}
		.padding(14)
		.background(Palette.wait.opacity(0.05))
		.overlay(Rectangle().stroke(Palette.wait.opacity(0.8)))
	}
}

/// A question's options, wrapping onto more lines when they don't fit on one.
private struct FlowButtons: View {
	let options: [String]
	let disabled: Bool
	let pick: (String) -> Void

	var body: some View {
		FlowLayout(spacing: 8) {
			ForEach(options.indices, id: \.self) { index in
				Button(options[index]) { pick(options[index]) }
					.buttonStyle(QuietButton(fill: index == 0 ? Palette.wait : nil, ink: index == 0 ? Palette.waitInk : Palette.ink))
					.disabled(disabled)
			}
		}
	}
}

/// Lays its children out in rows, left to right, wrapping at the width offered.
struct FlowLayout: Layout {
	var spacing: CGFloat = 8

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
		let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
		return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		var y = bounds.minY
		for row in rows(width: bounds.width, subviews: subviews) {
			var x = bounds.minX
			for index in row.indices {
				let size = subviews[index].sizeThatFits(.unspecified)
				subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
				x += size.width + spacing
			}
			y += row.height + spacing
		}
	}

	private func rows(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
		var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
		var current: [Int] = []
		var x: CGFloat = 0
		var height: CGFloat = 0
		for index in subviews.indices {
			let size = subviews[index].sizeThatFits(.unspecified)
			if !current.isEmpty, x + spacing + size.width > width {
				rows.append((current, x, height))
				current = []
				x = 0
				height = 0
			}
			x += (current.isEmpty ? 0 : spacing) + size.width
			height = max(height, size.height)
			current.append(index)
		}
		if !current.isEmpty { rows.append((current, x, height)) }
		return rows
	}
}

/// `✓ pnpm test  ✗ types`, a failing one's detail under the row on a click.
private struct ChecksRow: View {
	let checks: [TaskResult.Check]
	let running: Bool
	@State private var open: String?

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			FlowLayout(spacing: 18) {
				ForEach(checks, id: \.name) { check in
					Button {
						withAnimation(.row) { open = open == check.name ? nil : check.name }
					} label: {
						HStack(spacing: 6) {
							Text(check.ok ? "✓" : "✗").foregroundStyle(check.ok ? Palette.add : Palette.bad)
							Text(check.name).foregroundStyle(Palette.ink2)
						}
						.font(Typography.ui)
						.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
					.disabled(check.detail == nil)
					.help(check.detail == nil ? (check.ok ? "Passed" : "Failed") : "Show its output")
				}
				if running {
					HStack(spacing: 6) { StateMark(.running, size: 9); Text("running again").foregroundStyle(Palette.ink3) }.font(Typography.ui)
				}
			}
			if let open, let detail = checks.first(where: { $0.name == open })?.detail {
				Detail(text: detail)
			}
		}
	}
}

/// Screenshots paired by page: before at the sandbox's starting commit, after at its head. A page that's new has only
/// an after, and a removed one only a before.
private struct ShotPairs: View {
	let task: TaskStore
	let shots: [TaskResult.Shot]
	let base: String?

	private var pages: [(key: String, label: String, before: TaskResult.Shot?, after: TaskResult.Shot?)] {
		var order: [String] = []
		var byPage: [String: (label: String, before: TaskResult.Shot?, after: TaskResult.Shot?)] = [:]
		for shot in shots {
			let key = shot.path ?? shot.label
			if byPage[key] == nil {
				order.append(key)
				byPage[key] = (shot.label, nil, nil)
			}
			switch shot.side {
			case .before: byPage[key]?.before = shot
			default: byPage[key]?.after = shot
			}
		}
		return order.compactMap { key in byPage[key].map { (key, $0.label, $0.before, $0.after) } }
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			ForEach(pages, id: \.key) { page in
				HStack(alignment: .top, spacing: 14) {
					ShotFrame(task: task, shot: page.before, caption: "before · \(page.label)", side: base.map { "at \($0.prefix(7))" } ?? "at the start", missing: "new page")
					ShotFrame(task: task, shot: page.after, caption: "after · \(page.label)", side: "now", missing: "page removed")
				}
			}
		}
	}
}

private struct ShotFrame: View {
	let task: TaskStore
	let shot: TaskResult.Shot?
	let caption: String
	let side: String
	let missing: String
	@State private var image: NSImage?
	@State private var gone = false

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				Text(caption).lineLimit(1).truncationMode(.middle)
				Spacer(minLength: 6)
				Text(side)
			}
			.font(Typography.uiSmall)
			.foregroundStyle(Palette.ink3)
			.padding(.horizontal, 8)
			.padding(.vertical, 4)
			.background(Palette.paper2)
			.overlay(alignment: .bottom) { Rectangle().fill(Palette.rule).frame(height: 1) }
			Group {
				if shot == nil {
					placeholder(missing)
				} else if let image {
					Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
						.onTapGesture(count: 2) { open(image) }
						.help("Double-click to open it in Preview")
				} else if gone {
					placeholder("no longer kept")
				} else {
					placeholder("loading…")
				}
			}
		}
		.overlay(Rectangle().stroke(Palette.rule2))
		.frame(maxWidth: .infinity)
		.task(id: shot?.id) {
			guard let shot else { return }
			if let data = await task.shot(shot.id), let loaded = NSImage(data: data) { image = loaded } else { gone = true }
		}
	}

	private func placeholder(_ text: String) -> some View {
		Palette.panel
			.aspectRatio(1280 / 800, contentMode: .fit)
			.overlay { Text(text).font(Typography.uiSmall).foregroundStyle(Palette.ink3) }
	}

	/// Saves the shot to the temporary directory and opens it in the default viewer, full size.
	private func open(_ image: NSImage) {
		guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
		let url = FileManager.default.temporaryDirectory.appending(path: "\(caption.replacingOccurrences(of: "/", with: "-")).png")
		try? png.write(to: url)
		NSWorkspace.shared.open(url)
	}
}

/// `4 files, +98 −4 · show the code`: the branch's changes against its base, folded until asked for.
private struct CodeLine: View {
	let task: TaskStore
	let code: TaskResult.Code
	@Binding var open: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 8) {
				if code.files == 0 && code.commits == 0 {
					Text("no commits home yet").foregroundStyle(Palette.ink3)
				} else {
					Text("\(code.files == 1 ? "1 file" : "\(code.files) files"), \(code.commits == 1 ? "1 commit" : "\(code.commits) commits")").foregroundStyle(Palette.ink3)
					LineCounts(add: code.add, del: code.del)
					Text("·").foregroundStyle(Palette.ink3)
					BracketButton(open ? "hide the code" : "show the code", color: Palette.ink2) {
						withAnimation(.row) { open.toggle() }
					}
				}
			}
			.font(Typography.uiSmall)
			if open {
				Group {
					switch task.code {
					case .success(let changes): ChangesView(changes: changes, diff: task.diff)
					case .failure(let error): Text(error.message).font(Typography.uiSmall).foregroundStyle(Palette.bad)
					case nil: Text("reading…").font(Typography.uiSmall).foregroundStyle(Palette.ink3)
					}
				}
				.task { await task.loadCode() }
			}
		}
		.padding(.top, 12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.overlay(alignment: .top) { Rectangle().fill(Palette.rule).frame(height: 1) }
		.padding(.top, 24)
	}
}
