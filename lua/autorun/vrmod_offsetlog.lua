--[[
    vrmod_offsetlog.lua
    Per-hand weapon grip offset logger.

    Grab a weapon and this records where the gun actually sits relative to the
    hand holding it, tagged by hand. Do a pass right-handed, do the same pass
    left-handed, then `vrmod_offsetlog_diff` reports the per-weapon delta and
    the average across everything recorded -- which is the universal left-hand
    correction you're looking for.

    Measurements are stored in the Weapon Fixer's flat px/py/pz/ap/ay/ar grip
    format, so `vrmod_offsetlog_preset` can emit a file that drops straight into
    lua/vrmod_weaponfix_presets/ with its grip and gripleft tables filled in.

    Place in: garrysmod/lua/autorun/client/
]]

if SERVER then return end

local IsValid, LocalPlayer = IsValid, LocalPlayer
local WorldToLocal = WorldToLocal
local FrameNumber = FrameNumber
local string_format = string.format
local AngleDifference = math.AngleDifference
local SortedPairs, pairs, ipairs = SortedPairs, pairs, ipairs

local LOG_FILE = "vrmod_offsetlog.json"
local PRESET_DIR = "vrmod_weaponfix_presets"

-- The gun is only where it looks once the render pass has repositioned it, and
-- a fresh grab takes a few frames to settle. Ten is comfortably past both.
local SETTLE_FRAMES = 10

-- log[hand][class] = { px, py, pz, ap, ay, ar, vpx, vpy, vpz, vap, vay, var }
-- The first six are measured from the live weapon pose; the last six are the
-- configured viewmodel offset, kept as a control value. In worldmodel mode
-- there is no vmi, so those stay nil.
local log = { right = {}, left = {} }
local handOverride = nil

local function Save()
    file.Write(LOG_FILE, util.TableToJSON(log, true))
end

do
    local raw = file.Read(LOG_FILE, "DATA")
    if raw then
        local t = util.JSONToTable(raw)
        if istable(t) then
            log.right = istable(t.right) and t.right or {}
            log.left = istable(t.left) and t.left or {}
        end
    end
end

local function Count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Which hand is actually holding the gun. Both left-hand flags are checked
-- because the ArcVR path and the VRMod path set different ones.
local function WeaponHand()
    if handOverride then return handOverride end
    if g_VR.gunInLeftHand then return "left" end
    if ArcticVR and ArcticVR.GunInLeftHand then return "left" end
    return "right"
end

local function Fmt(e)
    return string_format("pos %6.2f %6.2f %6.2f   ang %6.1f %6.1f %6.1f", e[1], e[2], e[3], e[4], e[5], e[6])
end

--- Measure the held weapon against the holding hand.
-- @return class, hand, entry  (nil plus a reason string on failure)
local function Measure()
    if not g_VR.active then return nil, "VR is not active" end

    local wep = LocalPlayer():GetActiveWeapon()
    if not IsValid(wep) then return nil, "no weapon equipped" end

    local wPos, wAng = g_VR.viewModelPos, g_VR.viewModelAng
    if not wPos or not wAng then return nil, "no weapon pose this frame" end

    local hand = WeaponHand()
    local t = g_VR.tracking
    local pose = t and t[hand == "left" and "pose_lefthand" or "pose_righthand"]
    if not pose or not pose.pos then return nil, "no hand tracking" end

    -- Same math the Weapon Fixer's reposition uses, so the numbers land in the
    -- same frame its saved grip offsets already live in.
    local p, a = WorldToLocal(wPos, wAng, pose.pos, pose.ang)
    local e = { p.x, p.y, p.z, a.p, a.y, a.r }

    local vmi = g_VR.currentvmi
    if vmi and vmi.offsetPos and vmi.offsetAng then
        local vp, va = vmi.offsetPos, vmi.offsetAng
        e[7], e[8], e[9] = vp.x, vp.y, vp.z
        e[10], e[11], e[12] = va.p, va.y, va.r
    end

    return wep:GetClass(), hand, e
end

local function Record(verbose)
    local class, hand, e = Measure()
    if not class then
        if verbose then print("[OffsetLog] " .. hand) end
        return false
    end

    log[hand][class] = e
    Save()

    print(string_format("[OffsetLog] %s  %-28s %s%s",
        hand == "left" and "L" or "R", class, Fmt(e),
        e[7] and string_format("   vmi %6.2f %6.2f %6.2f", e[7], e[8], e[9]) or "   (worldmodel)"))
    return true
end

-- ── Auto-capture on weapon change ───────────────────────────────────────────
-- One identity compare per frame on the steady path; the measurement only runs
-- on the settle frame after a change.

local lastClass, settleAt = "", 0

hook.Add("VRMod_Tracking", "vrmod_offsetlog", function()
    local wep = LocalPlayer():GetActiveWeapon()
    local class = IsValid(wep) and wep:GetClass() or ""

    if class ~= lastClass then
        lastClass = class
        settleAt = class ~= "" and FrameNumber() + SETTLE_FRAMES or 0
        return
    end

    if settleAt == 0 or FrameNumber() < settleAt then return end
    settleAt = 0
    Record(false)
end)

-- ── Commands ────────────────────────────────────────────────────────────────

concommand.Add("vrmod_offsetlog_hand", function(_, _, args)
    local v = string.lower(args[1] or "")
    if v == "auto" or v == "" then
        handOverride = nil
        print("[OffsetLog] Hand tag: auto")
    elseif v == "left" or v == "right" then
        handOverride = v
        print("[OffsetLog] Hand tag forced to " .. v)
    else
        print("[OffsetLog] usage: vrmod_offsetlog_hand <auto|left|right>")
    end
end, nil, "Force which hand recordings are tagged as, instead of auto-detecting")

concommand.Add("vrmod_offsetlog_mark", function()
    Record(true)
end, nil, "Record the held weapon's offset right now")

concommand.Add("vrmod_offsetlog_list", function()
    for _, hand in ipairs({ "right", "left" }) do
        print(string_format("[OffsetLog] --- %s (%d) ---", hand, Count(log[hand])))
        for class, e in SortedPairs(log[hand]) do
            print(string_format("  %-28s %s", class, Fmt(e)))
        end
    end
end, nil, "Print every recorded offset")

concommand.Add("vrmod_offsetlog_diff", function()
    local n = 0
    local sx, sy, sz, sp, sy2, sr = 0, 0, 0, 0, 0, 0
    local mins, maxs = {}, {}

    print("[OffsetLog] --- left minus right, per weapon ---")
    for class, l in SortedPairs(log.left) do
        local r = log.right[class]
        if r then
            -- AngleDifference on every rotational component: a pair straddling
            -- 180 differences to a few degrees, not to ~360.
            local d = {
                l[1] - r[1], l[2] - r[2], l[3] - r[3],
                AngleDifference(l[4], r[4]), AngleDifference(l[5], r[5]), AngleDifference(l[6], r[6]),
            }
            n = n + 1
            sx, sy, sz = sx + d[1], sy + d[2], sz + d[3]
            sp, sy2, sr = sp + d[4], sy2 + d[5], sr + d[6]
            for i = 1, 6 do
                if not mins[i] or d[i] < mins[i] then mins[i] = d[i] end
                if not maxs[i] or d[i] > maxs[i] then maxs[i] = d[i] end
            end
            print(string_format("  %-28s %s", class, Fmt(d)))
        end
    end

    if n == 0 then
        print("[OffsetLog] No weapon recorded in both hands yet.")
        return
    end

    print(string_format("[OffsetLog] mean over %d weapons: %s", n,
        Fmt({ sx / n, sy / n, sz / n, sp / n, sy2 / n, sr / n })))
    print(string_format("[OffsetLog] spread min:  %s", Fmt(mins)))
    print(string_format("[OffsetLog] spread max:  %s", Fmt(maxs)))
    print("[OffsetLog] A tight spread means one universal correction will do. A wide one means it is per-weapon.")
end, nil, "Report left-vs-right offset deltas and their average")

concommand.Add("vrmod_offsetlog_preset", function(_, _, args)
    local name = string.lower(string.gsub(args[1] or "", "[^%w_%-]", "_"))
    if name == "" then name = "offsetlog" end

    local function Pack(src)
        local out = {}
        for class, e in pairs(src) do
            out[class] = { px = e[1], py = e[2], pz = e[3], ap = e[4], ay = e[5], ar = e[6] }
        end
        return out
    end

    file.CreateDir(PRESET_DIR)
    local json = util.TableToJSON({
        name = name,
        author = LocalPlayer():Nick(),
        grip = Pack(log.right),
        gripleft = Pack(log.left),
    }, true)

    -- file.Write refuses a .lua extension, so the shareable copy lands as
    -- .lua.txt and you drop the ".txt" -- same convention the Weapon Fixer uses.
    file.Write(PRESET_DIR .. "/" .. name .. ".json", json)
    file.Write(PRESET_DIR .. "/" .. name .. ".lua.txt",
        "return util.JSONToTable([==[\n" .. json .. "\n]==])\n")

    print(string_format("[OffsetLog] Wrote %s.json and %s.lua.txt to data/%s/ (%d right, %d left)",
        name, name, PRESET_DIR, Count(log.right), Count(log.left)))
end, nil, "Export the log as a Weapon Fixer preset")

concommand.Add("vrmod_offsetlog_clear", function(_, _, args)
    local v = string.lower(args[1] or "")
    if v == "left" or v == "right" then
        log[v] = {}
    else
        log.right, log.left = {}, {}
    end
    Save()
    print("[OffsetLog] Cleared " .. (v ~= "" and v or "everything"))
end, nil, "Clear recorded offsets, optionally just one hand")
