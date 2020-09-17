module AugmentedPlatformHook
using Artifacts
export get_artifact_dir

include("../.pkg/platform_augmentation_hook.jl")

function get_artifact_dir(name)
    return @artifact_str(name, augment_platform!(HostPlatform()))
end
end # module AugmentedPlatformHook
