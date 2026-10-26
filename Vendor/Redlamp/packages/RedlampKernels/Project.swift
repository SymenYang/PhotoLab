import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: Module.kernels.name,
    settings: .redlampProject,
    targets: [
        .frameworkTarget(module: .kernels),
    ],
)
