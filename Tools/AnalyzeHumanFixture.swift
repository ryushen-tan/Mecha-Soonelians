import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
enum AnalyzeHumanFixture {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fatalError("Usage: analyze-human input.png output-directory")
        }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            fatalError("Cannot load input image")
        }
        let humans = try HumanAnalyzer.analyze(image)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for human in humans {
            for (name, image) in [("cutout", human.cutout), ("mask", human.mask)] {
                let url = output.appendingPathComponent("human-\(human.id)-\(name).png")
                guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    fatalError("Cannot create PNG")
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { fatalError("Cannot save PNG") }
            }
            print("Person \(human.id): \(human.joints.count) joints; bounds \(human.bounds)")
        }
        let metadata = humans.map { HumanSampleMetadata(id: $0.id, bounds: $0.bounds, joints: $0.joints) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: output.appendingPathComponent("human-analysis.json"))
        guard !humans.isEmpty else { fatalError("No humans detected in fixture") }
    }
}
