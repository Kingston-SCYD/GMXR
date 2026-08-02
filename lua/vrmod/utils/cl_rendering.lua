g_VR = g_VR or {}
vrmod = vrmod or {}
vrmod.utils = vrmod.utils or {}

function vrmod.utils.CalculateProjectionParams(projMatrix, worldScale)
    local xscale = projMatrix[1][1]
    local xoffset = projMatrix[1][3]
    local yscale = projMatrix[2][2]
    local yoffset = projMatrix[2][3]
    -- ** Normalize vertical sign: **
    if not system.IsWindows() then
        -- On Linux/OpenGL: invert the sign so + means “down” just like on Windows
        yoffset = -yoffset
    end

    -- now the rest is identical on both platforms:
    local tan_px = math.abs((1 - xoffset) / xscale)
    local tan_nx = math.abs((-1 - xoffset) / xscale)
    local tan_py = math.abs((1 - yoffset) / yscale)
    local tan_ny = math.abs((-1 - yoffset) / yscale)
    local w = (tan_px + tan_nx) / worldScale
    local h = (tan_py + tan_ny) / worldScale
    return {
        HorizontalFOV = math.deg(2 * math.atan(w / 2)),
        AspectRatio = w / h,
        HorizontalOffset = xoffset,
        VerticalOffset = yoffset,
        Width = w,
        Height = h,
    }
end

function vrmod.utils.ComputeSubmitBounds(leftCalc, rightCalc, hOffset, vOffset, scaleFactor, renderOffset)
    local isWindows = system.IsWindows()
    local hFactor, vFactor = 0, 0
    -- average half‐eye extents in tangent space
    if renderOffse then
        local wAvg = (leftCalc.Width + rightCalc.Width) * 0.5
        local hAvg = (leftCalc.Height + rightCalc.Height) * 0.5
        hFactor = 0.5 / wAvg
        vFactor = 1.0 / hAvg
    else
        --original calues
        hFactor = 0.25
        vFactor = 0.5
    end

    hFactor = hFactor * scaleFactor
    vFactor = vFactor * scaleFactor
    -- UV origin flip only affects V‐range endpoints, not the offset sign:
    local vMin, vMax = isWindows and 0 or 1, isWindows and 1 or 0
    local function calcVMinMax(offset)
        local adj = offset * vFactor
        return vMin - adj, vMax - adj
    end

    -- U bounds
    local uMinLeft = 0.0 + (leftCalc.HorizontalOffset + hOffset) * hFactor
    local uMaxLeft = 0.5 + (leftCalc.HorizontalOffset + hOffset) * hFactor
    local uMinRight = 0.5 + (rightCalc.HorizontalOffset + hOffset) * hFactor
    local uMaxRight = 1.0 + (rightCalc.HorizontalOffset + hOffset) * hFactor
    -- V bounds
    local vMinLeft, vMaxLeft = calcVMinMax(leftCalc.VerticalOffset + vOffset)
    local vMinRight, vMaxRight = calcVMinMax(rightCalc.VerticalOffset + vOffset)
    return uMinLeft, vMinLeft, uMaxLeft, vMaxLeft, uMinRight, vMinRight, uMaxRight, vMaxRight
end

function vrmod.utils.ComputeDesktopCrop(desktopView, w, h)
    local vmargin = (1 - ScrH() / ScrW() * w / 2 / h) / 2
    local hoffset = desktopView == 3 and 0.5 or 0
    return vmargin, hoffset
end

function vrmod.utils.AdjustFOV(proj, fovScaleX, fovScaleY)
    local clone = {}
    for i = 1, 4 do
        clone[i] = {proj[i][1], proj[i][2], proj[i][3], proj[i][4]}
    end

    -- scale the FOV (diagonal terms)
    clone[1][1] = clone[1][1] * fovScaleX
    clone[2][2] = clone[2][2] * fovScaleY
    -- scale the center offset (asymmetry) terms
    clone[1][3] = clone[1][3] * fovScaleX
    clone[2][3] = clone[2][3] * fovScaleY
    return clone
end

function vrmod.utils.DrawDeathAnimation(rtWidth, rtHeight)
    if not g_VR.deathTime then g_VR.deathTime = CurTime() end
    local progress = math.min((CurTime() - g_VR.deathTime) / 3.5, 1)
    cam.Start2D()
    surface.SetDrawColor(120, 0, 0, math.min(progress * 200, 200))
    surface.DrawRect(0, 0, rtWidth, rtHeight)
    cam.End2D()
end

local cv_deathcam_ragdoll = CreateClientConVar("vrmod_deathcam_ragdoll", "0", true, false, "Follow ragdoll head on death (may cause motion sickness)")
local cv_deathcam_ragdoll_view = CreateClientConVar("vrmod_deathcam_ragdoll_view", "0", true, false, "Lock VR view to ragdoll head direction (requires vrmod_deathcam_ragdoll)")
local ragviewEnabled = cv_deathcam_ragdoll_view:GetBool()
cvars.AddChangeCallback("vrmod_deathcam_ragdoll_view", function(_, _, val) ragviewEnabled = val ~= "0" end, "vr_rdv")

-- Returns ragdoll head pos + angles, or nil.
-- Reads physics bone directly (ticked by engine, not render pipeline).
function vrmod.utils.GetDeathCamView()
    -- Generic addon hook: return pos, ang to override VR view
    local hPos, hAng = hook.Run("VRMod_ViewOverride")
    if hPos then return hPos, hAng end
    -- Death cam
    if not cv_deathcam_ragdoll:GetBool() then g_VR._ragViewAng = nil return end
    local ply = LocalPlayer()
    if ply:Alive() then g_VR._ragViewAng = nil return end
    local rag = ply:GetRagdollEntity()
    if not IsValid(rag) then return end
    -- Cache bone indices on entity (one lookup per ragdoll lifetime)
    local bi = rag._vrDCBone
    if bi == nil then
        bi = rag:LookupBone("ValveBiped.Bip01_Head1") or false
        rag._vrDCBone = bi
        if bi then rag._vrDCPhys = rag:TranslateBoneToPhysBone(bi) end
    end
    if not bi then return end
    -- Hide head so we don't see inside our own skull
    if not rag._vrDeathCamHidden then
        rag:ManipulateBoneScale(bi, vector_origin)
        rag._vrDeathCamHidden = true
    end
    local pbi = rag._vrDCPhys
    if pbi < 0 then return end
    local phys = rag:GetPhysicsObjectNum(pbi)
    if not IsValid(phys) then return end
    local ragPos, ragAng = phys:GetPos(), phys:GetAngles()
    -- Ragdoll view: lock both position and view angles to ragdoll head.
    -- Angles stored on g_VR because the XR path in PerformRenderViews
    -- overwrites g_VR.view.angles with the eye pose after we return.
    if ragviewEnabled then
        g_VR._ragViewAng = ragAng
        return ragPos, ragAng
    end
    g_VR._ragViewAng = nil
    -- Base: position at ragdoll head, keep current HMD view angles
    return ragPos, g_VR.view.angles
end