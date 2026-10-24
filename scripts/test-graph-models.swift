// Appended to Models.swift and run with `swift` on the macOS smoke runner.
let graphJSON = #"{"id":"parametric","type":"plot","x":"cos(t)","y":"sin(t)","from":0,"to":6.28,"parts":[{"d":"M10,10L20,20","stroke":"black","clip":"M0,0h100v100h-100Z"}],"graph":{"origin":[300,700],"unit":[60,60],"xrange":[-2,5],"yrange":[-1,4]}}"#
let graphItem = try JSONDecoder().decode(ClaudeItem.self, from: Data(graphJSON.utf8))
assert(graphItem.parts?.count == 1 && graphItem.graph?.origin == [300, 700])
assert(graphItem.x == nil && graphItem.from == nil)
let legacyJSON = #"{"id":"legacy","type":"line","from":[1,2],"to":[3,4]}"#
let legacyItem = try JSONDecoder().decode(ClaudeItem.self, from: Data(legacyJSON.utf8))
assert(legacyItem.from == [1, 2] && legacyItem.to == [3, 4])
print("Graph and legacy drawing model decoding passed")

let shadeJSON = #"{"id":"shade","type":"shade","from":-2,"to":2,"parts":[{"d":"M0 0L10 0L10 10Z","fill":"blue","opacity":0.25,"clip":"M0 0H10V10H0Z"}]}"#
let shadeItem = try JSONDecoder().decode(ClaudeItem.self, from: Data(shadeJSON.utf8))
assert(shadeItem.from == nil && shadeItem.to == nil && shadeItem.parts?.first?.opacity == 0.25)
let headsJSON = #"{"id":"heads","type":"arrow","from":[1,2],"to":[3,4],"head":"both","head_filled":true,"head_d":"M1 2L3 4"}"#
let headsItem = try JSONDecoder().decode(ClaudeItem.self, from: Data(headsJSON.utf8))
assert(headsItem.head == "both" && headsItem.headFilled == true && headsItem.headD != nil)
let encodedHeads = try JSONDecoder().decode(ClaudeItem.self, from: JSONEncoder().encode(headsItem))
assert(encodedHeads == headsItem)
print("Shade scalars, prepared styles and rendering arrowheads decoding passed")
