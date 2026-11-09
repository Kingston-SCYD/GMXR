-- Death cam (cl_vrmod, every frame): VRMod_ViewOverride, else the ragdoll's
-- head while dead. Convars cached; the head bone/physbone resolved, and the
-- head hidden, once per ragdoll.
local cv_rag = CreateClientConVar("vrmod_deathcam_ragdoll", "0", true, false, "Follow ragdoll head on death (may cause motion sickness)")
local cv_view = CreateClientConVar("vrmod_deathcam_ragdoll_view", "0", true, false, "Lock VR view to ragdoll head direction (requires vrmod_deathcam_ragdoll)")
local ragOn, ragView = cv_rag:GetBool(), cv_view:GetBool()
cvars.AddChangeCallback("vrmod_deathcam_ragdoll", function() ragOn = cv_rag:GetBool() end, "vr_rdc")
cvars.AddChangeCallback("vrmod_deathcam_ragdoll_view", function() ragView = cv_view:GetBool() end, "vr_rdv")
local rawequal, IsValid, LocalPlayer = rawequal, IsValid, LocalPlayer
local dcRag, dcBone, dcPhys -- last ragdoll seen, its head bone (false: none), its physbone

-- Returns ragdoll head pos + angles, or nil.
-- Reads physics bone directly (ticked by engine, not render pipeline).
function vrmod.utils.GetDeathCamView()
    -- Generic addon hook: return pos, ang to override VR view
    local hPos, hAng = hook.Call("VRMod_ViewOverride", nil)
    if hPos then return hPos, hAng end
    -- Death cam
    if not ragOn then g_VR._ragViewAng = nil return end
    local ply = LocalPlayer()
    if ply:Alive() then g_VR._ragViewAng = nil return end
    local rag = ply:GetRagdollEntity()
    if not IsValid(rag) then return end
    if not rawequal(rag, dcRag) then
        dcRag = rag
        dcBone = rag:LookupBone("ValveBiped.Bip01_Head1") or false
        if dcBone then
            dcPhys = rag:TranslateBoneToPhysBone(dcBone)
            -- Hide head so we don't see inside our own skull
            rag:ManipulateBoneScale(dcBone, vector_origin)
        end
    end
    if not dcBone or dcPhys < 0 then return end
    local phys = rag:GetPhysicsObjectNum(dcPhys)
    if not IsValid(phys) then return end
    local ragPos, ragAng = phys:GetPos(), phys:GetAngles()
    -- Ragdoll view: lock both position and view angles to ragdoll head.
    -- Angles stored on g_VR because the XR path in PerformRenderViews
    -- overwrites g_VR.view.angles with the eye pose after we return.
    if ragView then
        g_VR._ragViewAng = ragAng
        return ragPos, ragAng
    end
    g_VR._ragViewAng = nil
    -- Base: position at ragdoll head, keep current HMD view angles
    return ragPos, g_VR.view.angles
end