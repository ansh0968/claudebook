// Combined folder/rendering model compatibility, appended to Models.swift on the smoke runner.
let libraryJSON = #"{"id":"combined","title":"Kept notes","pages":[],"createdAt":"2026-10-24T00:00:00Z","updatedAt":"2026-10-24T00:00:00Z","folderId":"chemistry","scratch":true,"expiresAt":"2026-10-31T00:00:00Z","deleteRequestedAt":"2026-10-24T01:00:00Z"}"#
let libraryNotebook = try JSONDecoder().decode(Notebook.self, from: Data(libraryJSON.utf8))
assert(libraryNotebook.folderId == "chemistry" && libraryNotebook.isScratch && libraryNotebook.expiryDate != nil)
assert(libraryNotebook.deleteRequestedAt == "2026-10-24T01:00:00Z")
assert(try JSONDecoder().decode(Notebook.self, from: JSONEncoder().encode(libraryNotebook)) == libraryNotebook)
print("Combined folders, scratch expiry and pending deletion notebook model passed")
