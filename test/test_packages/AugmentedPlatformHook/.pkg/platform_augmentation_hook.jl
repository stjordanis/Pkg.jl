using Base.BinaryPlatforms

function augment_platform!(p::Platform)
    # This hook will simply check an environment variable
    flooblecrank_status = get(ENV, "FLOOBLECRANK", "disengaged")
    if flooblecrank_status == "engaged"
        p["flooblecrank"] = "engaged"
    else
        p["flooblecrank"] = "disengaged"
    end
    return p
end