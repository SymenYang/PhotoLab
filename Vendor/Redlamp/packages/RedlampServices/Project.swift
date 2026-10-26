import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: Module.services.name,
    settings: .redlampProject,
    targets: [
        .frameworkTarget(module: .services, extraDependencies: libRawDependencies, resources: ["Resources/**"]),
        .frameworkTestTarget(module: .services),
    ],
)
