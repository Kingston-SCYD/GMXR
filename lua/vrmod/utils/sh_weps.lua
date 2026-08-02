g_VR = g_VR or {}
vrmod = vrmod or {}
vrmod.utils = vrmod.utils or {}
vrmod.suppressViewModelUpdates = false
-- WEP UTILS
function vrmod.utils.IsValidWep(wep, get)
    if not IsValid(wep) then return false end
    local class = wep:GetClass()
    local vm
    vm = wep:GetWeaponViewModel()
    if class == "weapon_vrmod_empty" or vm == "" or vm == "models/weapons/c_arms.mdl" then return false end
    if get then
        return class, vm
    else
        return true
    end
end

function vrmod.utils.IsWeaponEntity(ent)
    if not IsValid(ent) then return false end
    local c = ent:GetClass()
    return ent:IsWeapon() or c:find("weapon_") or c == "prop_physics" and ent:GetModel():find("w_")
end

function vrmod.utils.WepInfo(wep)
    local class, vm = vrmod.utils.IsValidWep(wep, true)
    if class and vm then return class, vm end
end

function vrmod.utils.UpdateViewModelPos(pos, ang, override)
    local ply = LocalPlayer()
    if vrmod.suppressViewModelUpdates and not override then
        vrmod.utils.UpdateViewModel()
        return
    end

    pos, ang = vrmod.utils.CheckWeaponPushout(pos, ang)
    if not IsValid(ply) or not g_VR.active then return end
    if not ply:Alive() then return end
    local currentvmi = g_VR.currentvmi
    local modelPos = pos
    if currentvmi then
        local collisionShape = vrmod._collisionShapeByHand and vrmod._collisionShapeByHand.right
        if collisionShape and collisionShape.isClipped and collisionShape.pushOutPos then
            modelPos = collisionShape.pushOutPos
            vrmod.logger.Debug("[VRMod] Applying collision-corrected pos for viewmodel:", modelPos)
        end

        local offsetPos, offsetAng = LocalToWorld(currentvmi.offsetPos, currentvmi.offsetAng, modelPos, ang)
        g_VR.viewModelPos = offsetPos
        g_VR.viewModelAng = offsetAng
    else
        g_VR.viewModelPos = pos
        g_VR.viewModelAng = ang
    end

    vrmod.utils.UpdateViewModel()
end

-- Muzzle attachment index, resolved by name and cached per model. Index 1 is
-- the muzzle on purpose-built VR weapons, but on HL2 viewmodels it is often the
-- shell-eject/casing attachment.
local muzModel, muzIdx = nil, 1
local function MuzzleIndex(ent)
    local mdl = ent:GetModel()
    if mdl ~= muzModel then
        muzModel = mdl
        local i = ent:LookupAttachment("muzzle")
        if not i or i <= 0 then i = ent:LookupAttachment("muzzle_flash") end
        muzIdx = (i and i > 0) and i or 1
    end
    return muzIdx
end

-- Rigid muzzle: the attachment transform captured once per model from a neutral
-- clientside copy, then carried on the weapon pose.
--
-- Reading the live attachment every frame makes the muzzle inherit whatever the
-- viewmodel animation is doing. HL2 deploy and idle anims swing it around; the
-- physgun's prongs move it while it is holding something, which shakes the held
-- prop because the server drives it off this angle. In VR the gun is rigid in
-- your hand and recoil is already applied to the hand pose, so a fixed offset
-- is both more correct and much cheaper -- no per-frame bone rebuild at all.
local cv_rigid = CreateClientConVar("vrmod_muzzle_rigid", "1", true, false, "Carry the muzzle rigidly on the weapon instead of following viewmodel animation", 0, 1)
local muzLocal = {} -- [model] = {Pos, Ang} in model space, or false if none

local function MuzzleLocal(mdl)
    local c = muzLocal[mdl]
    if c ~= nil then return c end
    c = false
    local cm = ClientsideModel(mdl)
    if IsValid(cm) then
        cm:SetNoDraw(true)
        cm:SetPos(vector_origin)
        cm:SetAngles(angle_zero)
        cm:SetupBones()
        -- At the world origin with zero angles, world space IS model space.
        local att = cm:GetAttachment(MuzzleIndex(cm))
        if att then c = {Pos = att.Pos, Ang = att.Ang} end
        cm:Remove()
    end
    muzLocal[mdl] = c
    return c
end

-- Reposition the viewmodel and re-read its muzzle from g_VR.viewModelPos/Ang.
-- Shared by the early tracking pass, the left-hand path and the per-eye
-- refresh, so all three agree.
function vrmod.utils.RefreshViewModelMuzzle(vm)
    vm = vm or g_VR.viewModel
    if not IsValid(vm) then return end
    local pos, ang = g_VR.viewModelPos, g_VR.viewModelAng
    vm:SetPos(pos)
    vm:SetAngles(ang)
    -- Source keys its bone cache on TIME, not on position, so moving the entity
    -- does NOT dirty it. Anything that already built this viewmodel's bones
    -- earlier in the frame leaves DrawModel rendering the previous pose, and the
    -- animation pass on an animated viewmodel does exactly that -- which is why
    -- the HL2 weapons trailed the hand while the static physgun and camera were
    -- fine. Must stay outside the rigid branch: the rigid muzzle no longer needs
    -- bones, but the RENDER still does.
    vm:InvalidateBoneCache()
    if cv_rigid:GetBool() then
        local m = MuzzleLocal(vm:GetModel())
        if m then
            local wp, wa = LocalToWorld(m.Pos, m.Ang, pos, ang)
            g_VR.viewModelMuzzle = {Pos = wp, Ang = wa}
            return
        end
    end
    -- Live path: build now so GetAttachment reflects the pose we just set
    -- rather than whatever it was cached at.
    vm:SetupBones()
    g_VR.viewModelMuzzle = vm:GetAttachment(MuzzleIndex(vm))
end

function vrmod.utils.UpdateViewModel()
    vrmod.utils.RefreshViewModelMuzzle(g_VR.viewModel)
end