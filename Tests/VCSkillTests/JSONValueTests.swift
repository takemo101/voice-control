import Foundation
import Testing
@testable import VCSkill

@Suite struct JSONValueTests {
    @Test func jsonValuesRoundTripAndKeepBooleansDistinctFromNumbers() {
        let value = JSONValue(any: ["a": 1, "b": true, "c": [1.5, "x"], "d": NSNull()] as [String: Any])
        #expect(value["b"]?.bool == true && value["a"]?.int == 1 && value["a"]?.bool == nil)
        #expect(JSONValue.parse(value.serialized()!) == value)
    }
}
