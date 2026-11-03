import Foundation
import Testing
@testable import VCPCControl

@Suite struct ElementVerbTests {
    @Test func verbsAreOfferedOnlyWhereTheElementAdvertisesTheAction() {
        let checkbox = UIElement(ref: "@s:e1", role: "checkbox", name: "Dark", actions: ["Click", "Toggle", "SetFocus"])
        let disclosure = UIElement(ref: "@s:e2", role: "disclosure", name: "Details", actions: ["Click", "Expand", "Collapse"])
        let button = UIElement(ref: "@s:e3", role: "button", name: "Save", actions: ["Click"])
        let field = UIElement(ref: "@s:e4", role: "textfield", name: "Search", actions: ["Click", "SetValue", "SetFocus", "TypeText"])
        let sw = UIElement(ref: "@s:e5", role: "switch", name: "Sound", actions: ["Click", "Toggle"])
        func verbs(_ e: UIElement) -> Set<ElementVerb> { Set(ElementVerb.allCases.filter { $0.applies(to: e) }) }
        #expect(verbs(checkbox) == [.check, .uncheck, .toggle])
        #expect(verbs(disclosure) == [.expand, .collapse])
        #expect(verbs(button).isEmpty)
        #expect(verbs(field) == [.clear, .focus])
        #expect(verbs(sw).isEmpty)
    }

    @Test func destructiveVerbsAlwaysAskAndInversesPairUp() {
        let e = UIElement(ref: "@s:e1", role: "checkbox", name: "Dark", actions: ["Toggle"])
        #expect(ElementVerb.clear.needsConfirmation)
        #expect(!ElementVerb.check.needsConfirmation)
        #expect(Step.element(.check, e).inverse == .element(.uncheck, e))
        #expect(Planner.needsConfirmation(.closeApp("A")))
    }
}
