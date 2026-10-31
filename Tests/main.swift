import Foundation
import CoreGraphics

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { print("FAIL: \(message)"); exit(1) }
}
func near(_ a: Double, _ b: Double) -> Bool { abs(a-b) < 0.000001 }
let screen = CGRect(x: -100, y: 100, width: 100, height: 100)
check(StatusJSON.data(["screens":[["mediaTime":Double.nan]]]) == nil, "undefined media timestamp must never reach Foundation JSON writer")
check(StatusJSON.data(["screens":[["mediaTime":Double.infinity]]]) == nil, "infinite media timestamp must never reach Foundation JSON writer")
check(StatusJSON.data(["screens":[["mediaTime":0.0]]]) != nil, "status writer still works after invalid timestamps")
check(near(Visibility.coveredFraction(of: screen, by: []), 0), "empty desktop")
check(near(Visibility.coveredFraction(of: screen, by: [screen]), 1), "fully covered")
check(near(Visibility.coveredFraction(of: screen, by: [screen,screen]), 1), "overlaps count once")
check(near(Visibility.coveredFraction(of: screen, by: [CGRect(x:-150,y:50,width:100,height:100)]), 0.25), "clip against offset monitor")
check(near(Visibility.coveredFraction(of: screen, by: [CGRect(x:0,y:0,width:500,height:500)]), 0), "neighboring display does not cover this one")
check(near(Visibility.coveredFraction(of: screen, by: [CGRect(x:-100,y:100,width:60,height:100),CGRect(x:-60,y:100,width:60,height:100)]), 1), "overlapping windows jointly cover")
check(near(Visibility.coveredFraction(of: screen, by: [CGRect(x:-100,y:100,width:20,height:100),CGRect(x:-20,y:100,width:20,height:100)]), 0.4), "gap remains visible")
check(!Visibility.shouldPlay(mode:.visible,suspended:false,coverage:0.96,wasPlaying:true), "pause at 95 percent coverage")
check(Visibility.shouldPlay(mode:.visible,suspended:false,coverage:0.92,wasPlaying:true), "hysteresis while playing")
check(!Visibility.shouldPlay(mode:.visible,suspended:false,coverage:0.92,wasPlaying:false), "hysteresis while paused")
check(Visibility.shouldPlay(mode:.visible,suspended:false,coverage:0.89,wasPlaying:false), "resume with desktop visible")
for m in PlaybackMode.allCases { check(!Visibility.shouldPlay(mode:m,suspended:true,coverage:0,wasPlaying:true), "suspend overrides \(m)") }
check(Visibility.shouldPlay(mode:.always,suspended:false,coverage:1,wasPlaying:false), "always plays when covered")
check(!Visibility.shouldPlay(mode:.paused,suspended:false,coverage:0,wasPlaying:true), "manual pause wins")

let a = "840FE8E4-D952-4680-B1A7-AC5BACA2C1F8", b = "94383DC9-59D3-43EC-9E8E-A783DA633E06"
func section(_ id: String?, linked: Bool = true, idleOnly: Bool = false) -> [String: Any] {
    let config = try! PropertyListSerialization.data(fromPropertyList: ["assetID":id ?? a], format:.binary,options:0)
    let choice: [String:Any] = ["Provider":id == nil ? "com.apple.wallpaper.choice.image" : "com.apple.wallpaper.choice.aerials", "Configuration":config]
    return ["Type":idleOnly ? "idle" : linked ? "linked" : "individual", idleOnly ? "Idle" : linked ? "Linked" : "Desktop":["Content":["Choices":[choice]]]]
}
var store: [String: Any] = ["AllSpacesAndDisplays":section(a)]
check(WallpaperStore.selection(in:store,display:"D",space:nil) == .aerial(a), "global linked aerial")
store["Displays"] = ["D":section(b,linked:false)]
check(WallpaperStore.selection(in:store,display:"D",space:nil) == .aerial(b), "display override")
store["Spaces"] = ["S":["Default":section(a),"Displays":["D":section(nil)]]]
check(WallpaperStore.selection(in:store,display:"D",space:"S") == .other, "per-space still supersedes global aerial")
check(WallpaperStore.selection(in:store,display:"Other",space:"S") == .aerial(a), "space default")
store["Displays"] = ["D":section(b,idleOnly:true)]
check(WallpaperStore.selection(in:store,display:"D",space:nil) == .aerial(a), "screen saver-only slot never becomes desktop")
check(WallpaperStore.selection(in:["AllSpacesAndDisplays":section("../../bad")],display:"D",space:nil) == .unavailable, "reject unsafe or unsupported asset IDs")
check(WallpaperStore.selection(in:[:],display:"D",space:nil) == .unavailable, "malformed store")
let defaultSection: [String: Any] = ["Type":"linked", "Linked":["Content":["Choices":[["Provider":"default", "Files":[], "Configuration":Data()]]]]]
check(WallpaperStore.selection(in:["AllSpacesAndDisplays":defaultSection],display:"D",space:nil) == .systemDefault, "Golden Gate Sunset empty default-provider configuration")
check(WallpaperStore.selection(in:["Displays":["D":defaultSection],"AllSpacesAndDisplays":section(a)],display:"D",space:nil) == .systemDefault, "per-display system default supersedes global aerial")
check(WallpaperStore.selection(in:["Displays":["D":section(nil)],"AllSpacesAndDisplays":defaultSection],display:"D",space:nil) == .other, "still-image override supersedes system default")
let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
try! FileManager.default.createDirectory(at:fixture,withIntermediateDirectories:true)
check(BundledDefault.video(in:fixture) == nil, "image-only default has no movie")
try! Data().write(to:fixture.appendingPathComponent("DefaultAerial.heic"))
try! Data().write(to:fixture.appendingPathComponent("Future Default.mov"))
check(BundledDefault.video(in:fixture)?.lastPathComponent == "Future Default.mov", "resolve bundled movie without hardcoded OS name or asset ID")
try! Data().write(to:fixture.appendingPathComponent("Ambiguous.mov"))
check(BundledDefault.video(in:fixture) == nil, "ambiguous default movies fall back safely")
try! FileManager.default.removeItem(at:fixture)

let underwater = "8BE8B524-6EAE-43F5-A3E8-01DCFA1BCD4B"
let land = "A33A55D9-EDEA-4596-A850-6C10B54FBBB5"
func shuffleSection(_ collection: String, _ cadence: String) -> [String:Any] {
    var value = section(collection)
    var slot = value["Linked"] as! [String:Any]
    var content = slot["Content"] as! [String:Any]
    content["EncodedOptionValues"] = try! PropertyListSerialization.data(fromPropertyList:["values":["aerialShuffleFrequency":["picker":["_0":["id":cadence]]]]],format:.binary,options:0)
    slot["Content"] = content; value["Linked"] = slot
    return value
}
let all = ShuffleChoice(collectionID:"shuffle-all-aerials",cadence:.continuously)
let water = ShuffleChoice(collectionID:underwater,cadence:.continuously)
check(WallpaperStore.selection(in:["AllSpacesAndDisplays":shuffleSection(underwater,"shuffle_continuously")],display:"D",space:nil,categoryIDs:[underwater]) == .shuffle(water), "category UUID denotes shuffle rather than a missing movie")
check(WallpaperStore.selection(in:["AllSpacesAndDisplays":shuffleSection("shuffle-all-aerials","shuffle_continuously")],display:"D",space:nil) == .shuffle(all), "Shuffle All has a non-UUID selection ID")
check(WallpaperStore.selection(in:["AllSpacesAndDisplays":shuffleSection(underwater,"future-unknown-cadence")],display:"D",space:nil,categoryIDs:[underwater]) == .unavailable, "unknown cadence never silently becomes continuous")
let now = Date()
for cadence in [ShuffleCadence.twelveHours,.day,.twoDays,.week,.month] {
    let choice = ShuffleChoice(collectionID:underwater,cadence:cadence)
    check(WallpaperStore.selection(in:["AllSpacesAndDisplays":shuffleSection(underwater,cadence.rawValue)],display:"D",space:nil,categoryIDs:[underwater]) == .shuffle(choice), "decode \(cadence.rawValue) from Settings")
    check(cadence.deadline(after:now)! > now, "scheduled deadline advances into future")
}
check(ShuffleCadence.continuously.deadline(after:now) == nil, "continuous shuffle needs no wall-clock timer")
check(near(ShuffleCadence.twelveHours.deadline(after:now)!.timeIntervalSince(now),43200), "12-hour cadence")
let catalog = AerialCatalog(["categories":[["id":underwater],["id":land]],"assets":[
    ["id":a,"categories":[underwater],"includeInShuffle":true],
    ["id":b,"categories":[land],"includeInShuffle":true],
    ["id":"4DFE24ED-71CC-42D4-9FE8-3B8959B6CC19","categories":[underwater],"includeInShuffle":false],
    ["id":"../../invalid","categories":[underwater],"includeInShuffle":true]]])
check(catalog.candidates(for:water,available:{_ in true}) == [a], "shuffle stays in selected category and honors exclusions")
check(Set(catalog.candidates(for:all,available:{_ in true})) == Set([a,b]), "all collections include eligible videos")
check(catalog.candidates(for:water,available:{_ in false}).isEmpty, "missing downloads are never picked")
var bag = ShuffleBag()
let candidates = [a,b,underwater] // valid IDs suffice for bag tests; no filesystem access.
var cycle: [String] = []
for _ in 0..<3 { cycle.append(bag.select(from:candidates,advance:true)!) }
check(Set(cycle).count == 3, "visit every candidate once before refilling bag")
var last = bag.current
for _ in 0..<30 {
    let next = bag.select(from:candidates,advance:true)
    check(next != last, "avoid immediate repeats, including bag boundaries")
    check(bag.select(from:candidates) == next, "file notifications preserve current shuffle video")
    last = next
}
check(bag.select(from:[]) == nil, "empty collection clears previous video")
check(bag.select(from:[a]) == a && bag.select(from:[a],advance:true) == a, "one available video keeps looping")
check(bag.select(from:[b]) == b, "removed current video is replaced immediately")
var downloadBag = ShuffleBag()
_ = downloadBag.select(from:[a])
check(downloadBag.select(from:[a,b],advance:true) == b, "newly downloaded candidate enters rotation")

// Compare the exact sweep against a brute-force oracle over integer cells.
var seed: UInt64 = 17
func rand(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % UInt64(n)) }
for _ in 0..<200 {
    let s = CGRect(x:0,y:0,width:20,height:20)
    let rects = (0..<8).map { _ in CGRect(x:rand(30)-5,y:rand(30)-5,width:rand(15),height:rand(15)) }
    var occupied = 0
    for y in 0..<20 { for x in 0..<20 {
        if rects.contains(where: { $0.contains(CGPoint(x:Double(x)+0.5,y:Double(y)+0.5)) }) { occupied += 1 }
    } }
    check(near(Visibility.coveredFraction(of:s,by:rects),Double(occupied)/400), "union coverage vs independent oracle")
}
let start = ProcessInfo.processInfo.systemUptime
for _ in 0..<10000 {
    _ = Visibility.coveredFraction(of:screen,by:[screen,CGRect(x:-80,y:80,width:80,height:100)])
}
print("PASS: \(checks) checks; 10,000 coverage computations in \(String(format:"%.1f",(ProcessInfo.processInfo.systemUptime-start)*1000)) ms")
