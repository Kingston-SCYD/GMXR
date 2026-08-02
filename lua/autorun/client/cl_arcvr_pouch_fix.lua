-- cl_arcvr_pouch_fix.lua
-- Client-side: ammo pouch sphere, X button mag eject, flick reload signal
-- Works with STOCK ArcVR - does not modify ArcVR's pickup/positioning system

if SERVER then return end

local POUCH_DROP = 14
local POUCH_RADIUS = 14

CreateClientConVar("vrmod_pouch_fix_drop", tostring(POUCH_DROP), true, FCVAR_ARCHIVE, "Units below HMD for ammo pouch", 5, 80)
CreateClientConVar("vrmod_pouch_fix_radius", tostring(POUCH_RADIUS), true, FCVAR_ARCHIVE, "Radius of ammo pouch sphere", 8, 24)
CreateClientConVar("vrmod_pouch_fix_lookdown", "55", true, FCVAR_ARCHIVE, "Degrees looking down to disable pouch", 20, 80)

local function GetPouchPos()
    if not g_VR or not g_VR.active or not g_VR.tracking or not g_VR.tracking.hmd then return nil end
    local hmd = g_VR.tracking.hmd.pos
    if not hmd then return nil end
    local ply = LocalPlayer()
    local drop = GetConVar("vrmod_pouch_fix_drop"):GetFloat()
    if IsValid(ply) and ply:Crouching() then drop = drop * 0.5 end
    local back = Angle(0, g_VR.tracking.hmd.ang.yaw, 0):Forward() * -3
    return Vector(hmd.x + back.x, hmd.y + back.y, hmd.z - drop)
end

local function HandInPouch(leftHand)
    local pouch = GetPouchPos()
    if not pouch then return false end
    local hand = leftHand and g_VR.tracking.pose_lefthand.pos or g_VR.tracking.pose_righthand.pos
    local r = GetConVar("vrmod_pouch_fix_radius"):GetFloat()
    return hand:DistToSqr(pouch) < (r * r)
end

local _nextSpawn = 0
local function TrySpawnMag(leftHand)
    if CurTime() < _nextSpawn then return end
    local wpn = LocalPlayer():GetActiveWeapon()
    if not IsValid(wpn) or not wpn.ArcticVR then return end
    if wpn.NotAGun then return end
    if LocalPlayer():GetAmmoCount(wpn.Primary.Ammo) <= 0 then
        surface.PlaySound("items/medshotno1.wav")
        _nextSpawn = CurTime() + 0.3
        return
    end
    local hand = leftHand and g_VR.tracking.pose_lefthand or g_VR.tracking.pose_righthand
    net.Start("vrmod_pouch_spawnmag")
    net.WriteVector(hand.pos)
    net.WriteAngle(hand.ang)
    net.WriteBool(leftHand)
    net.SendToServer()
    surface.PlaySound(wpn.SpawnMagSound or "arcticvr/mag_spawn.wav")
    _nextSpawn = CurTime() + 0.5
end

hook.Add("VRMod_Input", "arcvr_pouch_fix", function(action, pressed)
    if not g_VR or not g_VR.active then return end

    -- X button: eject mag + signal flick reload held
    if action == "boolean_use" then
        local wpn = LocalPlayer():GetActiveWeapon()
        if IsValid(wpn) and wpn.ArcticVR then
            if pressed and wpn.EjectMagazine then wpn:EjectMagazine(false) end
            hook.Call("VRMod_Input", nil, "boolean_reload", pressed)
        end
        return
    end

    -- Pouch: off-hand grip spawns mag (disabled when looking down)
    local lookdownAngle = GetConVar("vrmod_pouch_fix_lookdown"):GetFloat()
    local lookingDown = g_VR.tracking.hmd and g_VR.tracking.hmd.ang.p > lookdownAngle
    if not lookingDown then
        if action == "boolean_left_pickup" and pressed and HandInPouch(true) then
            TrySpawnMag(true)
        end
    end
end)

-- Block default pickup when hand is in pouch (unless looking down)
hook.Add("VRMod_AllowDefaultAction", "arcvr_pouch_block_pickup", function(action)
    if action ~= "boolean_left_pickup" then return end
    if not g_VR or not g_VR.active then return end
    -- Only block if player has an ArcVR weapon (pouch is relevant)
    local wep = LocalPlayer():GetActiveWeapon()
    if not IsValid(wep) or not wep.ArcticVR then return end
    local lookdownAngle = GetConVar("vrmod_pouch_fix_lookdown"):GetFloat()
    local lookingDown = g_VR.tracking.hmd and g_VR.tracking.hmd.ang.p > lookdownAngle
    if lookingDown then return end
    if HandInPouch(true) then return false end
end)

-- Debug wireframe sphere
local _pouchGripped = false
hook.Add("VRMod_Input", "arcvr_pouch_fix_grip_state", function(action, pressed)
    if action == "boolean_left_pickup" or action == "boolean_right_pickup" then
        _pouchGripped = pressed
    end
end)

hook.Add("PostDrawTranslucentRenderables", "arcvr_pouch_fix_debug", function(depth, sky)
    if depth or sky then return end
    if not g_VR or not g_VR.active then return end
    if not vrmod.DebugVisible() then return end
    local pos = GetPouchPos()
    if not pos then return end
    local r = GetConVar("vrmod_pouch_fix_radius"):GetFloat()
    local handIn = HandInPouch(true) or HandInPouch(false)
    local lookdownAngle = GetConVar("vrmod_pouch_fix_lookdown"):GetFloat()
    local lookingDown = g_VR.tracking.hmd and g_VR.tracking.hmd.ang.p > lookdownAngle
    local col
    if lookingDown then
        col = Color(128, 128, 128, 100)
    elseif handIn and _pouchGripped then
        col = Color(255, 50, 50, 220)
    elseif handIn then
        col = Color(255, 220, 0, 200)
    else
        col = Color(0, 255, 128, 120)
    end
    render.SetColorMaterial()
    render.DrawWireframeSphere(pos, r, 12, 12, col, true)
end)

-- Force viewmodel finger bones to closed grip for melee weapons
hook.Add("VRMod_Tracking", "zz_melee_fingers_close", function()
    if not g_VR or not g_VR.active then return end
    local wep = LocalPlayer():GetActiveWeapon()
    if not IsValid(wep) then return end
    if not wep.NotAGun and not (weapons.GetStored(wep:GetClass()) or {}).NotAGun then return end
    -- Force ArcVR's finger interpolation to fully closed by overriding the input
    if wep.FingerAngles and g_VR.input then
        g_VR.input.vector1_primaryfire = 1
    end
end)

-- Fix: restore hand angles that get zeroed by finger tracking validation
hook.Add("VRMod_Start", "fix_hand_angles", function()
    timer.Simple(2, function()
        if g_VR and g_VR.defaultClosedHandAngles then
            g_VR.closedHandAngles = g_VR.defaultClosedHandAngles
            g_VR.openHandAngles = g_VR.defaultOpenHandAngles
        end
    end)
end)

local _lastWepClass = ""
hook.Add("Think", "fix_hand_angles_melee", function()
    if not g_VR or not g_VR.active then return end
    local wep = LocalPlayer():GetActiveWeapon()
    if not IsValid(wep) then return end
    local class = wep:GetClass()
    if class ~= _lastWepClass then
        _lastWepClass = class
        if wep.NotAGun or (weapons.GetStored(class) or {}).NotAGun then
            g_VR.closedHandAngles = g_VR.defaultClosedHandAngles
            g_VR.openHandAngles = g_VR.defaultOpenHandAngles
        end
    end
end)
