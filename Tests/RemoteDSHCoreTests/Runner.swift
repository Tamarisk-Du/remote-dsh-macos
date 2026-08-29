import Testing

@main
struct Runner {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}
