// Combined folder/rendering model compatibility, appended to Models.swift on the smoke runner.
let libraryJSON = #"{"id":"combined","title":"Kept notes","pages":[],"createdAt":"2026-10-24T00:00:00Z","updatedAt":"2026-10-24T00:00:00Z","folderId":"chemistry","scratch":true,"expiresAt":"2026-10-31T00:00:00Z","deleteRequestedAt":"2026-10-24T01:00:00Z"}"#
let libraryNotebook = try JSONDecoder().decode(Notebook.self, from: Data(libraryJSON.utf8))
assert(libraryNotebook.folderId == "chemistry" && libraryNotebook.isScratch && libraryNotebook.expiryDate != nil)
assert(libraryNotebook.deleteRequestedAt == "2026-10-24T01:00:00Z")
let libraryRoundTrip = try JSONDecoder().decode(Notebook.self, from: JSONEncoder().encode(libraryNotebook))
assert(libraryRoundTrip == libraryNotebook)
print("Combined folders, scratch expiry and pending deletion notebook model passed")

// Older snapshots have neither field; synthesized Codable must keep accepting them.
let oldTextBoxJSON = #"{"text":"21rh+ 4T42","x":100,"y":200,"w":300,"h":50}"#
let oldTextBox = try JSONDecoder().decode(TextBox.self, from: Data(oldTextBoxJSON.utf8))
assert(oldTextBox.alts == nil && oldTextBox.confidence == nil)
let newTextBoxJSON = #"{"text":"21rh+ 4T42","x":100,"y":200,"w":300,"h":50,"alts":["21rh+ 4T42","2πrh + 4πr²","2πrh"],"confidence":0.42}"#
let newTextBox = try JSONDecoder().decode(TextBox.self, from: Data(newTextBoxJSON.utf8))
assert(newTextBox.alts?.count == 3 && newTextBox.confidence == 0.42)
let textBoxRoundTrip = try JSONDecoder().decode(TextBox.self, from: JSONEncoder().encode(newTextBox))
assert(textBoxRoundTrip == newTextBox)
let constructedTextBox = TextBox(text: "x", x: 0, y: 0, w: 10, h: 10)
assert(constructedTextBox.alts == nil && constructedTextBox.confidence == nil)
print("Vision TextBox old/new snapshot decoding and round trip passed")
