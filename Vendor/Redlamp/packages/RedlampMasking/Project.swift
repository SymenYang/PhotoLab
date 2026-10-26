import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: Module.masking.name,
    settings: .redlampProject,
    targets: [
        .frameworkTarget(module: .masking, resources: ["Resources/**"]),
        .frameworkTestTarget(module: .masking),
    ],
)
