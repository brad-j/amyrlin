import Foundation
import Testing
@testable import AmyrlinCore

/// A `settings.get` result as aludra 861c0f3 answers it, cut to one setting of each kind, plus one of a kind this app
/// doesn't know.
let settingsJSON = #"""
{"file":"/home/brad/.config/aludra/config.json","settings":[
{"key":"workspaces","label":"Workspaces","help":"Where projects are.","kind":"workspaces","value":[{"name":"code","roots":["~/code/*"]}],"set":true,"editable":true,"live":true},
{"key":"model.id","label":"Default model","help":"The model new sessions start on.","kind":"model","value":"claude-bridge/claude-opus-5-5","default":"claude-bridge/claude-opus-5-5","set":false,"editable":true,"live":true},
{"key":"model.thinking","label":"Default thinking","help":"","kind":"choice","value":"high","default":"high","set":false,"options":["off","minimal","low","medium","high","xhigh"],"editable":true,"live":true},
{"key":"model.choices","label":"Pinned models","help":"","kind":"models","value":["claude-bridge/claude-opus-5-5"],"default":["claude-bridge/claude-opus-5-5"],"set":false,"editable":true,"live":true},
{"key":"approvals.hosts","label":"Approval hosts","help":"","kind":"list","value":["build-box"],"default":[],"set":true,"editable":true,"live":true},
{"key":"approvals.waitHours","label":"Approval wait (hours)","help":"","kind":"number","value":1.5,"default":24,"set":true,"editable":true,"live":true},
{"key":"backup.keep","label":"Backups kept","help":"","kind":"integer","value":7,"default":7,"set":false,"editable":true,"live":true},
{"key":"backup.dir","label":"Backup folder","help":"","kind":"path","value":"/data/backups","default":"/data/backups","set":false,"editable":true,"live":false},
{"key":"api.port","label":"Port","help":"","kind":"integer","value":8724,"default":8724,"set":false,"editable":false,"live":false},
{"key":"api.users","label":"Logins","help":"","kind":"list","value":[],"default":[],"set":false,"editable":false,"live":false},
{"key":"theme.dark","label":"Dark","help":"","kind":"toggle","value":true,"set":false,"editable":true,"live":true}
],"restart":["backup.dir"],"errors":["config.json: api.port should be a number"]}
"""#

func decodeSettings(_ json: String = settingsJSON) throws -> HostSettings {
	try JSONDecoder().decode(HostSettings.self, from: Data(json.utf8))
}

@Suite struct SettingsFormTests {
	private func setting(_ settings: HostSettings, _ key: String) throws -> HostSetting {
		try #require(settings.settings.first { $0.key == key })
	}

	@Test func settingsDecodeInTheShapeOfTheirKind() throws {
		let settings = try decodeSettings()
		#expect(settings.file == "/home/brad/.config/aludra/config.json")
		#expect(settings.restart == ["backup.dir"])
		#expect(settings.errors == ["config.json: api.port should be a number"])
		let workspaces = try setting(settings, "workspaces")
		#expect(workspaces.kind == .workspaces)
		#expect(workspaces.value == .workspaces([Workspace(name: "code", roots: ["~/code/*"])]))
		#expect(workspaces.default == nil)
		#expect(try setting(settings, "model.thinking").options.contains("xhigh"))
		#expect(try setting(settings, "approvals.waitHours").value == .number(1.5))
		#expect(try setting(settings, "api.users").value == .list([]))
		#expect(try setting(settings, "api.port").editable == false)
		let unknown = try setting(settings, "theme.dark")
		#expect(unknown.kind == .unknown("toggle"))
		#expect(unknown.value == .other(.bool(true)))
		#expect(!SettingsForm.isEditable(unknown), "a kind without a control here isn't edited here")
	}

	@Test func noWorkspacesIsAnEmptyListOfWorkspaces() throws {
		let settings = try decodeSettings(#"{"file":null,"settings":[{"key":"workspaces","label":"Workspaces","help":"","kind":"workspaces","value":[],"set":false,"editable":true,"live":true}]}"#)
		#expect(settings.file == nil)
		#expect(settings.settings[0].value == .workspaces([]))
		#expect(settings.restart.isEmpty && settings.errors.isEmpty)
		#expect(SettingsForm(settings).changes.isEmpty)
	}

	@Test func anUntouchedFormChangesNothing() throws {
		let form = SettingsForm(try decodeSettings())
		#expect(form.changes.isEmpty)
		#expect(!form.isDirty)
		#expect(form.draft("approvals.waitHours") == .text("1.5"))
		#expect(form.draft("backup.keep") == .text("7"), "a whole number shows without a fraction")
		#expect(form.draft("approvals.hosts") == .text("build-box"))
	}

	@Test func onlyChangedSettingsAreSent() throws {
		var form = SettingsForm(try decodeSettings())
		form.edit("approvals.hosts", .text("build-box\n  egwene  \n\n"))
		form.edit("backup.keep", .text(" 10 "))
		form.edit("model.thinking", .text("high"))
		form.edit("api.port", .text("9000"))
		#expect(form.changes == [
			"approvals.hosts": .value(.list(["build-box", "egwene"])),
			"backup.keep": .value(.number(10)),
		])
	}

	@Test func aNumberThatIsntOneGoesAsTypedForTheHostToRefuse() throws {
		var form = SettingsForm(try decodeSettings())
		form.edit("backup.keep", .text("lots"))
		#expect(form.changes == ["backup.keep": .value(.text("lots"))])
	}

	@Test func workspacesAreEditedAsNamesAndLinesOfRoots() throws {
		let settings = try decodeSettings()
		var form = SettingsForm(settings)
		guard case .workspaces(var drafts) = form.draft("workspaces") else {
			Issue.record("workspaces should draft as workspaces")
			return
		}
		#expect(drafts.map(\.roots) == ["~/code/*"])
		drafts.append(SettingsForm.WorkspaceDraft(name: " notes ", roots: "~/notes/*\n~/wiki"))
		form.edit("workspaces", .workspaces(drafts))
		#expect(form.changes == ["workspaces": .value(.workspaces([
			Workspace(name: "code", roots: ["~/code/*"]),
			Workspace(name: "notes", roots: ["~/notes/*", "~/wiki"]),
		]))])
	}

	@Test func useDefaultSendsNullWhileTheFieldHoldsTheDefault() throws {
		let settings = try decodeSettings()
		let hosts = try setting(settings, "approvals.hosts")
		var form = SettingsForm(settings)
		#expect(!form.isAtDefault(hosts))
		#expect(form.isAtDefault(try setting(settings, "backup.keep")))
		#expect(!form.isAtDefault(try setting(settings, "workspaces")), "no default, so never at it")
		form.useDefault(hosts)
		#expect(form.draft("approvals.hosts") == .text(""))
		#expect(form.isAtDefault(hosts))
		#expect(form.changes == ["approvals.hosts": .toDefault])
		form.edit("approvals.hosts", .text("egwene"))
		#expect(form.changes == ["approvals.hosts": .value(.list(["egwene"]))], "edited after, it's a value again")
	}

	@Test func changesEncodeAsTheHostTakesThem() throws {
		let command = Commands.SetSettings(changes: ["approvals.hosts": .toDefault, "backup.keep": .value(.number(10)), "approvals.waitHours": .value(.number(1.5))])
		let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(command.params))
		#expect(json == .object(["changes": .object(["approvals.hosts": .null, "backup.keep": .number(10), "approvals.waitHours": .number(1.5)])]))
		let text = String(decoding: try JSONEncoder().encode(command.params), as: UTF8.self)
		#expect(text.contains(#""backup.keep":10"#), "an integer setting refuses 10.0")
	}

	@Test func valuesShowInALine() {
		#expect(SettingsForm.shown(.list([])) == "none")
		#expect(SettingsForm.shown(.list(["a", "b"])) == "a, b")
		#expect(SettingsForm.shown(.number(8724)) == "8724")
		#expect(SettingsForm.shown(.workspaces([Workspace(name: "code", roots: ["~/code/*", "~/x"])])) == "code: ~/code/*, ~/x")
	}

	@Test func aRefusedChangeGivesEveryReason() throws {
		let frame = try JSONDecoder().decode(
			ResponseFrame<Commands.SetSettings.Result>.self,
			from: Data(#"{"type":"response","id":"1","error":{"code":"invalid_settings","message":"backup.keep should be a number\napprovals.waitHours should be a number","retryable":false,"data":{"errors":["backup.keep should be a number","approvals.waitHours should be a number"]}}}"#.utf8)
		)
		let error = try #require(frame.error)
		#expect(error.code == "invalid_settings")
		#expect(error.reasons == ["backup.keep should be a number", "approvals.waitHours should be a number"])
		#expect(ProtocolError(code: "unavailable", message: "The host is restarting").reasons == ["The host is restarting"])
	}
}
