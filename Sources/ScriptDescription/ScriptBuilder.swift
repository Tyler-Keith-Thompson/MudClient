@resultBuilder
public struct ScriptBuilder {
    public static func buildBlock<each S: ScriptDescription>(_ content: repeat each S) -> [any ScriptDescription] {
        var scripts: [any ScriptDescription] = []
        (repeat scripts.append(each content))
        return scripts
    }
}
