import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: Module.engineAPI.name,
    settings: .redlampProject,
    targets: [
        .frameworkTarget(module: .engineAPI, resources: ["Resources/**"]),
        .frameworkTestTarget(module: .engineAPI),
    ],
)
