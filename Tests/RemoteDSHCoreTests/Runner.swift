import Testing

@main
struct Runner {
    static func main() async {
        var arguments = Testing.__CommandLineArguments_v0()
        let filters = CommandLine.arguments.dropFirst()
        if filters.isEmpty == false {
            arguments.filter = Array(filters)
        }
        await Testing.__swiftPMEntryPoint(passing: arguments) as Never
    }
}
