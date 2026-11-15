#!/usr/bin/env python3
"""Test-only native input, inserted identically into baseline and candidate.

Only the disposable farm snapshots are instrumented. Posting through NSApp
exercises event monitors and AppKit routing without outside input grants.
"""
from pathlib import Path
import sys

path = Path(sys.argv[1]) / 'Sources/Fast/Bench.swift'
source = path.read_text()
marker = '        case "grab":'
assert source.count(marker) == 1
command = r'''
        case "capture-swipe":
            guard Store.testing, let window = Links.window, let content = window.contentView else {
                answer(["error": "isolated test window required"]); return
            }
            let x = request["x"] as? Double ?? 0, y = request["y"] as? Double ?? 0
            let dx = request["dx"] as? Double ?? 0, dy = request["dy"] as? Double ?? 0
            let end = Int64(request["end"] as? Int ?? 4)
            let start = DispatchTime.now().uptimeNanoseconds
            func post(_ phase: Int64, _ dx: Int32, _ dy: Int32, _ step: Int, momentum: Int64 = 0) {
                guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                          wheel1: dy, wheel2: dx, wheel3: 0) else { return }
                let screen = window.convertPoint(toScreen: CGPoint(x: x, y: y))
                event.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
                event.flags = []
                event.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(window.windowNumber))
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
                event.timestamp = CGEventTimestamp(start + UInt64(step) * 1_000_000_000 / 60)
                typealias Place = @convention(c) (CGEvent, CGPoint) -> Void
                guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return }
                unsafeBitCast(symbol, to: Place.self)(event, CGPoint(x: x, y: content.bounds.height - y))
                guard let wheel = NSEvent(cgEvent: event) else { return }
                NSApp.postEvent(wheel, atStart: false)
            }
            post(1, 0, 0, 0)
            for step in 1...24 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) / 60) {
                    let mx = Int32((dx * Double(step) / 24).rounded() - (dx * Double(step - 1) / 24).rounded())
                    let my = Int32((dy * Double(step) / 24).rounded() - (dy * Double(step - 1) / 24).rounded())
                    post(2, mx, my, step)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 25.0 / 60) { post(end, 0, 0, 25) }
            if end == 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 26.0 / 60) { post(0, 24, 0, 26, momentum: 1) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 27.0 / 60) { post(0, 0, 0, 27, momentum: 4) }
            }
            answer(["posted": true])

'''
path.write_text(source.replace(marker, command + marker))
