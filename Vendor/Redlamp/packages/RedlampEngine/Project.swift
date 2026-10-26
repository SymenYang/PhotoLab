import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: Module.engine.name,
    settings: .redlampProject,
    targets: [
        .frameworkTarget(module: .engine),
        .frameworkTestTarget(module: .engine),
    ],
)
