// Appended to Models.swift on the macOS smoke runner.
let physicsJSON = #"{"id":"rotated-field","type":"svg","d":"M100,100h100v60h-100Z","rotation":30,"rotation_center":[150,130],"fill_pattern":"cross","pattern_spacing":20,"pattern_angle":45,"head":"both","head_filled":true,"head_d":"M100,100L110,90L110,110Z","parts":[{"d":"M120,120L125,125","stroke":"black","clip":"M100,100h100v60h-100Z"}]}"#
let physicsItem = try JSONDecoder().decode(ClaudeItem.self, from: Data(physicsJSON.utf8))
assert(physicsItem.rotation == 30 && physicsItem.rotationCenter == [150, 130])
assert(physicsItem.fillPattern == "cross" && physicsItem.patternSpacing == 20 && physicsItem.patternAngle == 45)
assert(physicsItem.head == "both" && physicsItem.headFilled == true && physicsItem.headD != nil)
assert(physicsItem.parts?.first?.clip != nil)
let physicsRoundTrip = try JSONDecoder().decode(ClaudeItem.self, from: JSONEncoder().encode(physicsItem))
assert(physicsRoundTrip == physicsItem)
let groundJSON = #"{"id":"incline","type":"ground","from":[90,690],"to":[850,251],"side":"below","hatch_length":14,"spacing":12}"#
let groundItem = try JSONDecoder().decode(ClaudeItem.self, from: Data(groundJSON.utf8))
assert(groundItem.from == [90, 690] && groundItem.side == "below" && groundItem.hatchLength == 14 && groundItem.spacing == 12)
print("Physics rotation, pattern, ground and rendering model fields round-trip passed")
