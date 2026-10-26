import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: Module.color.name,
    settings: .redlampProject,
    targets: [
        .frameworkTarget(module: .color),
        .frameworkTestTarget(module: .color),
    ],
)
