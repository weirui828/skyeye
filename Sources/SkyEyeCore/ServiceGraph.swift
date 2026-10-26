import Foundation

/// Edges point from a prerequisite to the services that require it.
public enum ServiceGraph {
    public static func order(_ services: [ServiceConfig], roots: [String]? = nil) throws -> [String] {
        var byName: [String: ServiceConfig] = [:]
        for service in services {
            guard byName[service.name] == nil else { throw SkyEyeError("Duplicate service '\(service.name)'.") }
            byName[service.name] = service
        }
        var visiting = Set<String>()
        var visited = Set<String>()
        var result: [String] = []
        func visit(_ name: String, path: [String]) throws {
            guard !visiting.contains(name) else {
                throw SkyEyeError("Circular dependency: " + (path + [name]).joined(separator: " → "))
            }
            guard !visited.contains(name) else { return }
            guard let service = byName[name] else { throw SkyEyeError("Unknown dependency '\(name)'.") }
            visiting.insert(name)
            for dependency in service.dependencies { try visit(dependency, path: path + [name]) }
            visiting.remove(name)
            visited.insert(name)
            result.append(name)
        }
        for name in roots ?? services.map(\.name) { try visit(name, path: []) }
        return result
    }

    public static func levels(_ services: [ServiceConfig]) throws -> [String: Int] {
        let order = try order(services)
        let byName = Dictionary(uniqueKeysWithValues: services.map { ($0.name, $0) })
        var levels: [String: Int] = [:]
        for name in order {
            levels[name] = byName[name]!.dependencies.map { (levels[$0] ?? 0) + 1 }.max() ?? 0
        }
        return levels
    }
}
