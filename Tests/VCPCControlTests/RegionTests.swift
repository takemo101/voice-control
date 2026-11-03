import Foundation
import Testing
@testable import VCPCControl

@Suite struct RegionTests {
    private let window = Rect(x: 100, y: 100, width: 300, height: 600)

    private func element(x: Double, y: Double, w: Double = 20, h: Double = 20) -> UIElement {
        UIElement(ref: "@s:e1", role: "button", name: "B", actions: ["Click"], bounds: Rect(x: x, y: y, width: w, height: h))
    }

    @Test func mapsTheCenterToANineCellGridInsideTheWindow() {
        #expect(element(x: 110, y: 110).region(in: window) == "左上")
        #expect(element(x: 240, y: 110).region(in: window) == "上")
        #expect(element(x: 370, y: 110).region(in: window) == "右上")
        #expect(element(x: 240, y: 390).region(in: window) == "中央")
        #expect(element(x: 110, y: 670).region(in: window) == "左下")
        #expect(element(x: 370, y: 670).region(in: window) == "右下")
    }

    @Test func hasNoRegionWithoutBounds() {
        let e = UIElement(ref: "@s:e1", role: "button", name: "B", actions: ["Click"])
        #expect(e.region(in: window) == nil)
        #expect(element(x: 0, y: 0).region(in: nil) == nil)
    }

    @Test func parserReadsBoundsAndDropsZeroSizedElements() throws {
        let json = #"""
        {"ok":true,"data":{"app":"A","tree":{"role":"window","bounds":{"x":0,"y":0,"width":300,"height":600},"children":[
          {"role":"button","name":"A","ref_id":"@s:e1","available_actions":["Click"],"bounds":{"x":10,"y":10,"width":40,"height":20}},
          {"role":"button","name":"Hidden","ref_id":"@s:e2","available_actions":["Click"],"bounds":{"x":10,"y":10,"width":0,"height":0}}]}}}
        """#
        let snapshot = try SnapshotParser.parse(Data(json.utf8))
        #expect(snapshot.window == Rect(x: 0, y: 0, width: 300, height: 600))
        #expect(snapshot.elements.map(\.name) == ["A"])
        #expect(snapshot.elements.first?.bounds == Rect(x: 10, y: 10, width: 40, height: 20))
    }
}
