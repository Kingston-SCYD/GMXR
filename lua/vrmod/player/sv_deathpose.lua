-- sv_deathpose.lua
-- Stamps the last VR tracking frame onto the death ragdoll's physics bones
-- so it collapses from the player's actual VR pose, not the default animation.
if not SERVER then return end

g_VR = g_VR or {}

local LocalToWorld = LocalToWorld
local IsValid = IsValid
local ZERO_ANG = Angle()

-- VR frame field prefix → Valve biped bone name.
-- First 3 always present; last 3 only with FBT (waist/feet nil-guarded).
local BONE_MAP = {
    {"hmd",       "ValveBiped.Bip01_Head1"},
    {"lefthand",  "ValveBiped.Bip01_L_Hand"},
    {"righthand", "ValveBiped.Bip01_R_Hand"},
    {"waist",     "ValveBiped.Bip01_Pelvis"},
    {"leftfoot",  "ValveBiped.Bip01_L_Foot"},
    {"rightfoot", "ValveBiped.Bip01_R_Foot"},
}

hook.Add("CreateEntityRagdoll", "VRMod_DeathPose", function(ent, ragdoll)
    if not ent:IsPlayer() or not IsValid(ragdoll) then return end
    local vrData = g_VR[ent:SteamID()]
    if not vrData or not vrData.latestFrame then return end

    local frame = vrData.latestFrame
    local plyPos = ent:GetPos()
    -- Frame was encoded relative to player pos + zero angle (or vehicle angle)
    local plyAng = ZERO_ANG
    if ent:InVehicle() then
        local veh = ent:GetVehicle()
        if IsValid(veh) then plyAng = veh:GetAngles() end
    end

    for i = 1, #BONE_MAP do
        local prefix, boneName = BONE_MAP[i][1], BONE_MAP[i][2]
        local relPos = frame[prefix .. "Pos"]
        if not relPos then continue end -- FBT fields nil when 3-point
        local relAng = frame[prefix .. "Ang"]

        local boneIdx = ragdoll:LookupBone(boneName)
        if not boneIdx or boneIdx < 0 then continue end
        local physIdx = ragdoll:TranslateBoneToPhysBone(boneIdx)
        if physIdx < 0 then continue end
        local phys = ragdoll:GetPhysicsObjectNum(physIdx)
        if not IsValid(phys) then continue end

        local wPos, wAng = LocalToWorld(relPos, relAng, plyPos, plyAng)
        phys:EnableMotion(false)
        phys:SetPos(wPos)
        phys:SetAngles(wAng)
        phys:EnableMotion(true)
        phys:Wake()
    end
end)
