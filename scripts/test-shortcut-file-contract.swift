import Foundation
import CoreFoundation

// Inspect the shipped plist with Apple's property-list parser. This does not
// execute Shortcuts or emulate a File Provider.
let bytes = try Data(contentsOf: URL(fileURLWithPath: "Resources/SSClip-Send.unsigned.shortcut"))
let root = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as! [String: Any]
let actions = root["WFWorkflowActions"] as! [[String: Any]]
func parameters(_ id: String) -> [[String: Any]] {
    actions.filter { $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions." + id }
        .map { $0["WFWorkflowActionParameters"] as! [String: Any] }
}
let names = parameters("setitemname")
precondition(names.count == 1)
let name = names[0]
precondition(name["WFName"] as? String == "connection-state.txt")
let extensionFlag = name["WFDontIncludeFileExtension"] as! NSNumber
precondition(CFGetTypeID(extensionFlag) == CFBooleanGetTypeID() && !extensionFlag.boolValue)
let writes = parameters("documentpicker.save")
precondition(writes.count == 1)
precondition(writes[0]["WFFileDestinationPath"] as? String == "SSClip/connection-state.txt")
let input = writes[0]["WFInput"] as! [String: Any]
let inputValue = input["Value"] as! [String: Any]
precondition(inputValue["VariableName"] as? String == "namedStateFile")
let reads = parameters("documentpicker.open")
let paths = Set(reads.map { $0["WFGetFilePath"] as! String })
precondition(paths == Set(["/SSClip/connection-state.txt", "/SSClip/connection-state.json.txt", "/SSClip/connection-state.json"]))
precondition(reads.filter { $0["WFGetFilePath"] as? String == "/SSClip/connection-state.txt" }.count == 2)
print("PASS: native plist metadata: explicit .txt name, Boolean extension flag, named save input, and exact canonical/legacy read paths")
