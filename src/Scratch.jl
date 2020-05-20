module Scratch
import ...Pkg
import Base: UUID
using ...Pkg.TOML, Dates

export with_scratch_directory, scratch_dir, get_scratch!, delete_scratch!, clear_scratchspaces!, @get_scratch!

const scratch_dir_OVERRIDE = Ref{Union{String,Nothing}}(nothing)
"""
    with_scratch_directory(f::Function, scratch_dir::String)

Helper function to allow temporarily changing the scratch space directory.  When this is
set, no other directory will be searched for spaces, and new spaces will be created
within this directory.  Similarly, removing a scratch space will only effect the given
scratch directory.
"""
function with_scratch_directory(f::Function, scratch_dir::String)
    try
        scratch_dir_OVERRIDE[] = scratch_dir
        f()
    finally
        scratch_dir_OVERRIDE[] = nothing
    end
end

"""
    scratch_dir(args...)

Returns a path within the current depot's `scratchspaces` directory.  This location can
be overridden via `with_scratch_directory()`.
"""
function scratch_dir(args...)
    if scratch_dir_OVERRIDE[] === nothing
        return abspath(Pkg.depots1(), "scratchspaces", args...)
    else
        # If we've been given an override, use _only_ that directory.
        return abspath(scratch_dir_OVERRIDE[], args...)
    end
end

"""
    scratch_path(key, pkg_uuid)

Common utility function to return the path of a scratch space, keyed by the given
parameters.  Users should use `get_scratch!()` for most user-facing usage.
"""
function scratch_path(key::AbstractString, pkg_uuid::Union{UUID,Nothing} = nothing)
    # If we were not given a UUID, we use the "global space" UUID:
    if pkg_uuid === nothing
        pkg_uuid = UUID(UInt128(0))
    end

    return scratch_dir(string(pkg_uuid), key)
end

# Session-based space access time tracker
scratch_access_timers = Dict{String,Float64}()
"""
    track_scratch_access(pkg_uuid, scratch_path)

We need to keep track of who is using which spaces, so we know when it is advisable to
remove them during a GC.  We do this by attributing accesses of spaces to `Manifest.toml`
files in much the same way that package versions themselves are logged upon install, only
instead of having the manifest information implicitly available, we must rescue it out
from the currently-active Pkg Env.  If we cannot do that, it is because someone is doing
something weird like opening a space for a Pkg UUID that is not loadable, which we will
simply not track; that space will be reaped after the appropriate time in an orphanage.

If `pkg_uuid` is explicitly set to `nothing`, this space is treated as belonging to the
default global manifest next to the global project at `Base.load_path_expand("@v#.#")`.

While package and artifact access tracking can be done at `add()`/`instantiate()` time,
we must do it at access time for spaces, as we have no declarative list of spaces that
a package may or may not access throughout its lifetime.  To avoid building up a
ludicrously large number of accesses through programs that e.g. call `get_scratch!()` in a
loop, we only write out usage information for each space once per day at most.
"""
function track_scratch_access(pkg_uuid::Union{UUID,Nothing}, scratch_path::AbstractString)
    # Don't write this out more than once per day within the same Julia session.
    curr_time = time()
    if get(scratch_access_timers, scratch_path, 0.0) >= curr_time - 60*60*24
        return
    end

    function find_project_file(pkg_uuid)
        # The simplest case (`pkg_uuid` == `nothing`) simply attributes the space to
        # the global depot environment, which will never cause the space to be GC'ed
        # because it has been removed, as long as the depot itself is intact.
        if pkg_uuid === nothing
            return Base.load_path_expand("@v#.#")
        end

        # The slightly more complicated case inspects the currently-loaded Pkg env
        # to find the project file that we should tie our lifetime to.  If we can't
        # find it, we'll return `nothing` and skip tracking access.
        ctx = Pkg.Types.Context()

        # Check to see if the UUID is the overall project itself:
        if ctx.env.pkg !== nothing && ctx.env.pkg.uuid == pkg_uuid
            return ctx.env.project_file
        end

        # Finally, check to see if the package is loadable from the current environment
        if haskey(ctx.env.manifest, pkg_uuid)
            pkg_entry = ctx.env.manifest[pkg_uuid]
            pkg_path = Pkg.Operations.source_path(
                ctx,
                Pkg.Types.PackageSpec(
                    name=pkg_entry.name,
                    uuid=pkg_uuid,
                    tree_hash=pkg_entry.tree_hash,
                    path=pkg_entry.path,
                )
            )
            project_path = joinpath(pkg_path, "Project.toml")
            if isfile(project_path)
                return project_path
            end
        end

        # If we couldn't find anything to attribute the space to, return `nothing`.
        return nothing
    end

    # We must decide which manifest to attribute this space to.
    project_file = abspath(find_project_file(pkg_uuid))

    # If we couldn't find one, skip out.
    if project_file === nothing
        return
    end

    entry = Dict(
        "time" => now(),
        "parent_projects" => [project_file],
    )
    Pkg.Types.write_env_usage(abspath(scratch_path), "scratch_usage.toml", entry)

    # Record that we did, in fact, write out the space access time
    scratch_access_timers[scratch_path] = curr_time
end


const VersionConstraint = Union{VersionNumber,AbstractString,Nothing}

"""
    get_scratch!(key::AbstractString, parent_pkg = nothing)

Returns the path to (or creates) a space.

If `parent_pkg` is given (either as a `UUID` or as a `Module`), the scratch space is
namespaced with that package's UUID, so that it will not conflict with any other space
with the same name but a different parent package UUID.  The space's lifecycle is tied
to that parent package, allowing the space to be garbage collected if all versions of the
package that used it have been removed.

If `parent_pkg` is not defined, or is a `Module` without a root UUID (e.g. `Main`,
`Base`, an anonymous module, etc...) a global scratch space that does not have any
explicit parent will be created.

In the current implementation, scratch spaces (both parented and global) are removed if
they have not been accessed for a predetermined amount of time.  Parented scratch spaces
can be removed sooner if their parent package has been garbage collected.  See `Pkg.gc()`
and `track_scratch_access()` for more details.

!!! note
    Scratch spaces should never be treated as persistent storage; all content within them
    must be nonessential or easily recreatable.  All lifecycle guarantees set a maximum
    lifetime for the space, never a minimum.
"""
function get_scratch!(key::AbstractString, parent_pkg::Union{UUID,Nothing} = nothing)
    # Calculate the path and create the containing folder
    path = scratch_path(key, parent_pkg)
    mkpath(path)

    # We need to keep track of who is using which spaces, so we track usage in a log
    track_scratch_access(parent_pkg, path)
    return path
end
function get_scratch!(key::AbstractString, parent_pkg::Module)
    return get_scratch!(key, Base.PkgId(parent_pkg).uuid)
end

"""
    delete_scratch!(key, parent_pkg)

Explicitly deletes a scratch space created through `get_scratch!()`.
"""
function delete_scratch!(key::AbstractString, parent_pkg::Union{UUID,Nothing} = nothing)
    path = scratch_path(key, parent_pkg)
    rm(path; force=true, recursive=true)
    delete!(scratch_access_timers, path)
    return nothing
end
function delete_scratch!(key::AbstractString, parent_pkg::Module)
    return delete_scratch!(key, Base.PkgId(parent_pkg).uuid)
end

"""
    clear_scratchspaces!()

Delete all scratch spaces in the current depot.
"""
function clear_scratchspaces!()
    rm(scratch_dir(); force=true, recursive=true)
    empty!(scratch_access_timers)
    return nothing
end

"""
    @get_scratch!(key)

Convenience macro that gets/creates a scratch space with the given key and parented to
the package the calling module belongs to.  If the calling module does not belong to a
package, (e.g. it is `Main`, `Base`, an anonymous module, etc...) the UUID will be taken
to be `nothing`, creating a global scratchspace.
"""
macro get_scratch!(key)
    # Note that if someone uses this in the REPL, it will return `nothing`, and thereby
    # create a global scratch space.
    uuid = Base.PkgId(__module__).uuid
    return quote
        get_scratch!($(esc(key)), $(esc(uuid)))
    end
end

end # module Scratch