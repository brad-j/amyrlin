import AmyrlinCore
import SwiftUI

/// What changed over a span, in the inspector's quiet style: the totals, then each file with its status, path and
/// `+add −del`, biggest first. A click on a file opens its patch under it, read from the host once. `diff` fetches a
/// file's patch; nil shows the list alone.
struct ChangesView: View {
	let changes: Changes
	var diff: ((String) async throws -> String)?
	@State private var open: String?

	var body: some View {
		switch changes {
		case .unavailable(let reason):
			Text(reason).font(Typography.uiSmall).foregroundStyle(Palette.ink3)
		case .available(_, let add, let del, let files):
			VStack(alignment: .leading, spacing: 0) {
				if files.isEmpty {
					Text("No files changed").font(Typography.uiSmall).foregroundStyle(Palette.ink3)
				} else {
					HStack(spacing: 8) {
						Text(files.count == 1 ? "1 file" : "\(files.count) files").foregroundStyle(Palette.ink2)
						LineCounts(add: add, del: del)
					}
					.font(Typography.uiSmall)
					.padding(.bottom, 6)
					ForEach(files) { file in
						ChangedFileRow(file: file, open: open == file.path, diff: diff) {
							withAnimation(.row) { open = open == file.path ? nil : file.path }
						}
					}
				}
			}
		}
	}
}

/// `+12 −3`, in green and red, leaving out a side that's zero.
struct LineCounts: View {
	let add: Int
	let del: Int

	var body: some View {
		HStack(spacing: 6) {
			if add > 0 { Text("+\(add)").foregroundStyle(Palette.add) }
			if del > 0 { Text("−\(del)").foregroundStyle(Palette.bad) }
		}
		.monospacedDigit()
	}
}

private struct ChangedFileRow: View {
	let file: ChangedFile
	let open: Bool
	let diff: ((String) async throws -> String)?
	let toggle: () -> Void
	@State private var patch: Result<String, Error>?
	@State private var hovering = false

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Button(action: toggle) {
				HStack(spacing: 8) {
					Text(mark).foregroundStyle(markColor).frame(width: 10)
					Text(file.old.map { "\($0) → \(file.path)" } ?? file.path)
						.foregroundStyle(Palette.ink2)
						.lineLimit(1)
						.truncationMode(.head)
					Spacer(minLength: 6)
					if file.binary {
						Text("binary").foregroundStyle(Palette.ink3)
					} else {
						LineCounts(add: file.add, del: file.del)
					}
				}
				.font(Typography.uiSmall)
				.padding(.vertical, 3)
				.padding(.horizontal, 4)
				.background(hovering || open ? Palette.paper2 : .clear)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.disabled(diff == nil || file.binary)
			.onHover { hovering = $0 }
			.help(file.binary ? "A binary file has no patch" : open ? "Hide the patch" : "Show the patch")
			Disclosure(open: open) {
				PatchView(patch: patch)
					.padding(.vertical, 4)
					.task {
						guard patch == nil, let diff else { return }
						do { patch = .success(try await diff(file.path)) } catch { patch = .failure(error) }
					}
			}
		}
	}

	private var mark: String {
		switch file.status {
		case .added: "A"
		case .deleted: "D"
		case .renamed: "R"
		default: "M"
		}
	}

	private var markColor: Color {
		switch file.status {
		case .added: Palette.add
		case .deleted: Palette.bad
		default: Palette.ink3
		}
	}
}

/// A unified diff, line by line: additions green, removals red, hunk headers dim.
private struct PatchView: View {
	let patch: Result<String, Error>?

	var body: some View {
		switch patch {
		case nil:
			Text("reading…").font(Typography.uiSmall).foregroundStyle(Palette.ink3)
		case .failure(let error):
			Text((error as? ProtocolError)?.message ?? String(describing: error)).font(Typography.uiSmall).foregroundStyle(Palette.bad)
		case .success(let text):
			ScrollView(.horizontal) {
				VStack(alignment: .leading, spacing: 0) {
					ForEach(Array(lines(text).enumerated()), id: \.offset) { _, line in
						Text(line.isEmpty ? " " : line)
							.foregroundStyle(color(line))
							.frame(maxWidth: .infinity, alignment: .leading)
							.background(wash(line))
					}
				}
				.font(Typography.codeSmall)
				.textSelection(.enabled)
				.padding(8)
			}
			.background(Palette.paper2)
			.overlay(Rectangle().stroke(Palette.rule))
		}
	}

	/// The patch from its first hunk; the `diff --git` and `index` lines say nothing the row doesn't.
	private func lines(_ text: String) -> [String] {
		let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
		let start = all.firstIndex { $0.hasPrefix("@@") } ?? 0
		return Array(all[start...].prefix(2000))
	}

	private func color(_ line: String) -> Color {
		if line.hasPrefix("@@") { return Palette.ink3 }
		if line.hasPrefix("+") { return Palette.add }
		if line.hasPrefix("-") { return Palette.bad }
		return Palette.ink2
	}

	private func wash(_ line: String) -> Color {
		if line.hasPrefix("+"), !line.hasPrefix("+++") { return Palette.add.opacity(0.07) }
		if line.hasPrefix("-"), !line.hasPrefix("---") { return Palette.bad.opacity(0.07) }
		return .clear
	}
}

/// One turn's changes and the way back: what the turn changed, then Restore, which confirms first since it rewrites the
/// project's files, and after it what changed with Undo. Restore is off while the session runs or waits.
struct CheckpointSheet: View {
	let store: ConversationStore
	let checkpoint: Checkpoint
	/// The first words of the message whose turn this is, to say which turn.
	let message: String
	let busy: Bool
	@Environment(\.dismiss) private var dismiss
	@State private var changes: Result<Changes, Error>?
	@State private var confirming = false
	@State private var working = false
	@State private var restored: RestoreResult?
	@State private var undone = false
	@State private var failure: String?

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			ScrollView {
				VStack(alignment: .leading, spacing: 14) {
					VStack(alignment: .leading, spacing: 4) {
						Text("checkpoint \(checkpoint.id) · \(Date(timeIntervalSince1970: TimeInterval(checkpoint.at) / 1000).formatted(date: .abbreviated, time: .shortened))")
							.font(Typography.uiSmall).foregroundStyle(Palette.ink3)
						Text(message).font(Typography.uiSans).foregroundStyle(Palette.ink).lineLimit(2)
					}
					if let restored {
						restoredView(restored)
					} else {
						Text("What this turn changed").font(Typography.label).foregroundStyle(Palette.ink3).textCase(.uppercase)
						switch changes {
						case nil: Text("reading…").font(Typography.uiSmall).foregroundStyle(Palette.ink3)
						case .failure(let error): Text(Self.describe(error)).font(Typography.uiSmall).foregroundStyle(Palette.bad)
						case .success(let changes): ChangesView(changes: changes) { try await store.diff(at: checkpoint.id, path: $0) }
						}
					}
					if let failure {
						Text(failure).font(Typography.uiSmall).foregroundStyle(Palette.bad).fixedSize(horizontal: false, vertical: true)
					}
				}
				.padding(16)
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			Rectangle().fill(Palette.rule).frame(height: 1)
			footer
		}
		.frame(width: 620 * Typography.scale, height: 520 * Typography.scale)
		.background(Palette.paper)
		.task {
			do { changes = .success(try await store.changes(at: checkpoint.id)) } catch { changes = .failure(error) }
		}
	}

	private var footer: some View {
		HStack(spacing: 8) {
			if confirming {
				Text("Put the project's files back to before this turn?")
					.font(Typography.uiSmall).foregroundStyle(Palette.wait)
			} else if busy, restored == nil {
				Text("Stop the session or answer it before restoring")
					.font(Typography.uiSmall).foregroundStyle(Palette.ink3)
			}
			Spacer()
			Button(restored == nil && !confirming ? "esc close" : confirming ? "esc cancel" : "esc done") {
				if confirming { confirming = false } else { dismiss() }
			}
			.buttonStyle(QuietButton())
			.keyboardShortcut(.cancelAction)
			if restored == nil {
				Button(working ? "restoring…" : confirming ? "↵ restore files" : "restore…") {
					if confirming { restore() } else { confirming = true }
				}
				.buttonStyle(QuietButton(fill: confirming ? Palette.wait : nil, ink: confirming ? Palette.waitInk : busy ? Palette.ink3 : Palette.ink))
				.keyboardShortcut(confirming ? .defaultAction : nil)
				.disabled(busy || working)
				.help(busy ? "The session is running or waiting; the host won't restore until it's idle" : "Put the project's files back to how they were before this turn. It can be undone.")
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 10)
	}

	private func restoredView(_ result: RestoreResult) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(undone ? "Restore undone" : "Files restored to checkpoint \(checkpoint.id)")
				.font(Typography.uiStrong).foregroundStyle(undone ? Palette.ink2 : Palette.add)
			Text("\(result.written) written, \(result.deleted) deleted. The session's next message tells the agent.")
				.font(Typography.uiSmall).foregroundStyle(Palette.ink3)
			VStack(alignment: .leading, spacing: 2) {
				ForEach(result.files.prefix(40), id: \.self) { path in
					Text(path).font(Typography.uiSmall).foregroundStyle(Palette.ink2).lineLimit(1).truncationMode(.head)
				}
				if result.files.count > 40 {
					Text("and \(result.files.count - 40) more").font(Typography.uiSmall).foregroundStyle(Palette.ink3)
				}
			}
			if !undone {
				BracketButton(working ? "undoing…" : "undo restore", color: Palette.accent) { undo(result) }
					.disabled(working)
					.help("Put the files back as they were just before the restore (checkpoint \(result.undo))")
			}
		}
	}

	private func restore() {
		confirming = false
		working = true
		failure = nil
		Task {
			defer { working = false }
			do {
				restored = try await store.restore(checkpoint.id)
			} catch {
				failure = Self.describe(error)
			}
		}
	}

	private func undo(_ result: RestoreResult) {
		working = true
		failure = nil
		Task {
			defer { working = false }
			do {
				_ = try await store.restore(result.undo)
				undone = true
			} catch {
				failure = Self.describe(error)
			}
		}
	}

	static func describe(_ error: Error) -> String {
		guard let error = error as? ProtocolError else { return String(describing: error) }
		switch error.code {
		case "busy": return "The session is running or waiting, so the host won't restore now: \(error.message)"
		case "unknown_method": return "This machine's aludra has no checkpoints"
		default: return error.message
		}
	}
}
