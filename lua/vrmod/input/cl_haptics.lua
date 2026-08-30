--[[
    cl_haptics.lua
    Controller haptic feedback.

    One entry point, one preset table, one polling hook. Everything reads cached
    convar values rather than calling GetConVar per pulse, and every event source
    is edge-detected off state the addon already maintains -- no new hooks are
    invented and nothing here runs a trace, an allocation or a string concat in
    the per-frame path.
]]

if SERVER then return end

vrmod = vrmod or {}

local IsValid, RealTime, LocalPlayer = IsValid, RealTime, LocalPlayer

-- Resolved lazily: the module global only exists once require("vrmod") has run,
-- which may be after this file loads.
local TriggerHaptic

local LEFT, RIGHT = "vibration_left", "vibration_right"

-- Every hand spelling the codebase uses, resolved in one lookup. Booleans are
-- the bLeftHand convention from the pickup system; the numbers are gravgloves'
-- hand indices (1 = right, 2 = left).
local ACTIONS = {
    left  = LEFT,  right = RIGHT,
    [true] = LEFT, [false] = RIGHT,
    [2] = LEFT,    [1] = RIGHT,
}

-- { durationMs, frequencyHz, amplitude, cooldownSeconds }
-- Frequency 0 = XR_FREQUENCY_UNSPECIFIED; Quest ignores it either way, Index
-- uses it. Cooldowns keep a full-auto weapon or a physics rattle from queueing
-- a pulse every frame -- the runtime interrupts the previous one each time, so
-- uncapped spam produces a weaker buzz, not a stronger one.
local PRESETS = {
    tick   = {  8,  0, 0.35, 0.02 },  -- menu detent, hover
    click  = { 18,  0, 0.60, 0.05 },  -- discrete confirm
    pickup = { 45, 70, 0.55, 0.08 },
    drop   = { 25, 50, 0.35, 0.08 },
    shot   = { 60,  0, 0.90, 0.03 },
    impact = { 90, 60, 0.85, 0.10 },  -- melee connect
    grab   = { 70, 55, 0.70, 0.10 },  -- climbing grip caught a surface
    catch  = {120, 80, 0.90, 0.10 },
}

local enabled, scale, offhand = true, 1, 1
local nextTime = {}

CreateClientConVar("vrmod_haptics", "1", true, false, "Controller haptic feedback", 0, 1)
CreateClientConVar("vrmod_haptics_scale", "1", true, false, "Haptic strength multiplier", 0, 2)
CreateClientConVar("vrmod_haptics_offhand", "1", true, false, "Support-hand strength while two-handing, relative to the weapon hand", 0, 1)

cvars.AddChangeCallback("vrmod_haptics", function(_, _, v) enabled = tobool(v) end, "vrmod_haptics")
cvars.AddChangeCallback("vrmod_haptics_scale", function(_, _, v) scale = tonumber(v) or 1 end, "vrmod_haptics")
cvars.AddChangeCallback("vrmod_haptics_offhand", function(_, _, v) offhand = tonumber(v) or 1 end, "vrmod_haptics")

enabled = GetConVar("vrmod_haptics"):GetBool()
scale = GetConVar("vrmod_haptics_scale"):GetFloat()
offhand = GetConVar("vrmod_haptics_offhand"):GetFloat()

local function Pulse(action, p, amp, now)
    if (nextTime[action] or 0) > now then return false end
    nextTime[action] = now + p[4]
    TriggerHaptic(action, 0, p[1], p[2], amp)
    return true
end

--- Fire a haptic pulse.
-- @param hand    "left"/"right"/"both", bLeftHand boolean, or gravgloves index
-- @param preset  key into PRESETS
-- @param mul     optional per-call amplitude multiplier
-- @return true if at least one pulse was sent
function vrmod.Haptic(hand, preset, mul)
    if not enabled or not g_VR.active then return false end

    local p = PRESETS[preset]
    if not p then return false end

    TriggerHaptic = TriggerHaptic or VRMOD_TriggerHaptic
    if not TriggerHaptic then return false end

    local amp = p[3] * scale
    if mul then amp = amp * mul end
    if amp <= 0 then return false end
    if amp > 1 then amp = 1 end

    local now = RealTime()
    if hand ~= "both" then
        local action = ACTIONS[hand]
        return action ~= nil and Pulse(action, p, amp, now)
    end

    local l = Pulse(LEFT, p, amp, now)
    local r = Pulse(RIGHT, p, amp, now)
    return l or r
end

-- ── Hand resolution ─────────────────────────────────────────────────────────

-- Two hands on the gun. foregrip publishes this through the recoil addon (it
-- halves recoil while gripping); vrmod_foregrip.gripping is checked too so the
-- signal survives if foregrip ever publishes it directly.
local function TwoHanded()
    local r = vrmod_wmrecoil
    if r and r.gripping then return true end
    local f = vrmod_foregrip
    return f ~= nil and f.gripping == true
end

-- Both left-hand flags, since the ArcVR path and the VRMod path set different
-- ones and either can be the live signal depending on the loaded weapon base.
local function WeaponHand()
    if g_VR.gunInLeftHand then return "left" end
    if ArcticVR and ArcticVR.GunInLeftHand then return "left" end
    return "right"
end

-- ── Event sources ───────────────────────────────────────────────────────────
-- All edge detection lives in one VRMod_Tracking pass. Held entities, clip
-- count and climbing grips are all state the addon already keeps current, so
-- this reads them rather than hooking anything that might not fire clientside.

local heldL, heldR = false, false
local climbL, climbR = false, false
local lastWep, lastClip = NULL, 0

hook.Add("VRMod_Tracking", "vrmod_haptics", function()
    if not enabled then return end

    local hl = IsValid(g_VR.heldEntityLeft)
    if hl ~= heldL then
        heldL = hl
        vrmod.Haptic("left", hl and "pickup" or "drop")
    end

    local hr = IsValid(g_VR.heldEntityRight)
    if hr ~= heldR then
        heldR = hr
        vrmod.Haptic("right", hr and "pickup" or "drop")
    end

    local c = vrmod.climbing
    if c then
        local gl = c.gripLeft == true
        if gl ~= climbL then
            climbL = gl
            if gl then vrmod.Haptic("left", "grab") end
        end
        local gr = c.gripRight == true
        if gr ~= climbR then
            climbR = gr
            if gr then vrmod.Haptic("right", "grab") end
        end
    end

    -- Shot detection by clip decrease, the same trick vrmod_wm_recoil uses:
    -- it needs no weapon-base integration and works for anything that consumes
    -- ammo. Weapons with no clip sit at -1 and never trip it.
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    local wep = ply:GetActiveWeapon()
    if not IsValid(wep) then
        lastWep = NULL
        return
    end

    local clip = wep:Clip1()
    if wep ~= lastWep then
        lastWep = wep
    elseif clip < lastClip then
        local hand = WeaponHand()
        vrmod.Haptic(hand, "shot")
        -- Recoil travels up both arms when the gun is shouldered, so the
        -- support hand gets its own pulse at the offhand multiplier.
        if offhand > 0 and TwoHanded() then
            vrmod.Haptic(hand == "left" and "right" or "left", "shot", offhand)
        end
    end
    lastClip = clip
end)

-- Melee connect. Fired by sh_combat with { Player, Weapon, Hand, Position }.
-- Returns nothing: a non-nil return would short-circuit the hook and eat the
-- swing sound override the other listeners provide.
hook.Add("VRMod_MeleeSwing", "vrmod_haptics", function(info)
    if info then vrmod.Haptic(info.Hand, "impact") end
end)

hook.Add("VRMod_Exit", "vrmod_haptics", function(ply)
    if ply ~= LocalPlayer() then return end
    heldL, heldR, climbL, climbR = false, false, false, false
    lastWep, lastClip = NULL, 0
    for k in pairs(nextTime) do nextTime[k] = nil end
end)

-- ── Diagnostic ──────────────────────────────────────────────────────────────

concommand.Add("vrmod_haptic_test", function(_, _, args)
    local hand = string.lower(args[1] or "right")
    local action = hand == "both" and "both" or ACTIONS[hand]
    if not action then
        print("[HAP] usage: vrmod_haptic_test <right|left|both> [preset]")
        return
    end

    print("[HAP] module: " .. tostring(g_VR.moduleVersion) .. "  VR active: " .. tostring(g_VR.active == true) .. "  enabled: " .. tostring(enabled) .. "  scale: " .. tostring(scale))
    print("[HAP] weapon hand: " .. WeaponHand() .. "  two-handed: " .. tostring(TwoHanded()))

    if not VRMOD_TriggerHaptic then
        print("[HAP] VRMOD_TriggerHaptic is nil -- the loaded module does not export it")
        return
    end

    local preset = args[2]
    if preset then
        if not PRESETS[preset] then
            print("[HAP] no such preset: " .. preset)
            return
        end
        print("[HAP] " .. preset .. " -> " .. tostring(vrmod.Haptic(hand, preset)))
        return
    end

    if hand == "both" then
        print("[HAP] " .. LEFT .. " -> " .. tostring(VRMOD_TriggerHaptic(LEFT, 0, 150, 0, 1)))
        print("[HAP] " .. RIGHT .. " -> " .. tostring(VRMOD_TriggerHaptic(RIGHT, 0, 150, 0, 1)))
        return
    end

    -- No preset named: bypass the layer and report the module's raw answer.
    print("[HAP] " .. action .. " -> " .. tostring(VRMOD_TriggerHaptic(action, 0, 150, 0, 1)))
end, nil, "Fire a test haptic pulse. Optional preset name runs it through vrmod.Haptic instead")