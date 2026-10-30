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
