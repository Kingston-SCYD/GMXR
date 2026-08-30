--[[
    VRMod Weapon Fixer

    Muzzle Angles  : per-weapon P/Y/R muzzle correction + laser
    Grip Position  : freeze-and-regrab grip offset
    Animations     : per-weapon viewmodel animation disabler
    World Models   : force world model rendering per weapon
    Attack Block   : strip IN_ATTACK for motion-controlled melees
    Presets        : import/export the whole config, shareable via Workshop

    Place in: garrysmod/lua/autorun/client/
    One file, no dependencies. Stock Derma throughout.
]]

if SERVER then return end

-- ============================================================================
-- Cached natives
-- ============================================================================

local LocalPlayer, IsValid       = LocalPlayer, IsValid
local WorldToLocal, LocalToWorld = WorldToLocal, LocalToWorld
local Vector, Angle, Color       = Vector, Angle, Color
local SortedPairs, pairs, ipairs = SortedPairs, pairs, ipairs
local next, istable              = next, istable
local string_find                = string.find
local string_format              = string.format
local math_Round                 = math.Round
local table_Count                = table.Count
local bit_band                   = bit.band
local vgui_Create                = vgui.Create

local ATK_MASK = bit.bnot(IN_ATTACK + IN_ATTACK2)
local EMPTY    = {}

local function Msg(txt, isError)
    notification.AddLegacy(txt, isError and NOTIFY_ERROR or NOTIFY_GENERIC, 3)
end

local function ActiveClass()
    local wep = LocalPlayer():GetActiveWeapon()
    if IsValid(wep) then return wep:GetClass() end
end

-- ============================================================================
-- Shared active-weapon watcher
-- One GetActiveWeapon per frame for every open panel instead of one each, and
-- no hook at all while the menu is closed.
-- ============================================================================

local watchers, watchN     = {}, 0
local watchClass, watchWM  = nil, nil

local function WatchTick()
    local class = ActiveClass() or "None"
    local wm    = g_VR.wmActive or false
    if class == watchClass and wm == watchWM then return end
    watchClass, watchWM = class, wm
    for _, fn in pairs(watchers) do fn(class, wm) end
end

-- fn(class, isWorldModel) fires on registration and on every change.
local function Watch(panel, fn, onRemove)
    watchers[panel] = fn
    watchN = watchN + 1
    if watchN == 1 then hook.Add("Think", "vrmod_weaponfix_watch", WatchTick) end
    panel.OnRemove = function()
        if not watchers[panel] then return end
        watchers[panel] = nil
        watchN = watchN - 1
        if watchN == 0 then hook.Remove("Think", "vrmod_weaponfix_watch") end
        if onRemove then onRemove() end
    end
    fn(ActiveClass() or "None", g_VR.wmActive or false)
end

-- ============================================================================
-- Derma helpers
-- ============================================================================

local function MakeForm(parent, name)
    local form = vgui_Create("DForm", parent)
    form:SetName(name)
    form:Dock(TOP)
    form:DockMargin(5, 5, 5, 0)
    form:SetExpanded(true)
    return form
end

local function MakeList(form, tall, ...)
    local lv = vgui_Create("DListView", form)
    lv:SetTall(tall)
    lv:SetMultiSelect(false)
    for _, name in ipairs({...}) do lv:AddColumn(name) end
    form:AddItem(lv)
    return lv
end

-- Bound checkbox that never re-enters its own OnChange when refreshed.
local function MakeCheck(form, label, onChange)
    local chk, lock = form:CheckBox(label), false
    chk.OnChange = function(_, v) if not lock then onChange(v) end end
    chk.SetQuiet = function(_, v) lock = true chk:SetValue(v or false) lock = false end
    return chk
end

-- ============================================================================
-- MUZZLE ANGLES
-- ============================================================================

local MUZZLE_FILE    = "vrmod_muzzle_offsets.json"
local WM_MUZZLE_FILE = "vrmod_muzzle_offsets_wm.json"
local LASER_FILE     = "vrmod_muzzle_lasers.json"

local builtinDefaults = {
    ["weapon_hl1_glock"] = { p = 5, y = -2.5, r = 0 },
}

local muzzleSaved, muzzlePreview     = {}, nil
local wmMuzzleSaved, wmMuzzlePreview = {}, nil
local laserEnabled, laserColors, laserMaterials = {}, {}, {}

local DEFAULT_LASER     = { r = 0, g = 220, b = 255 }
local DEFAULT_LASER_MAT = "trails/laser"

local LASER_MATERIALS = {
    "trails/laser", "trails/smoke", "trails/electric", "trails/star",
    "trails/beam", "trails/lol", "trails/plasma", "trails/tube",
    "trails/scanline", "trails/heart", "trails/floater", "trails/zig",
    "trails/bluelaser",
    "cable/rope", "cable/xbeam", "cable/cable2", "cable/physbeam",
    "cable/hydra", "cable/redlaser",
}

local laserMatCache = {}
for _, path in ipairs(LASER_MATERIALS) do laserMatCache[path] = Material(path) end

local function GetLaserMat(class)
    return laserMatCache[laserMaterials[class] or DEFAULT_LASER_MAT] or laserMatCache[DEFAULT_LASER_MAT]
end

local function GetLaserColor(class)
    local c = laserColors[class] or DEFAULT_LASER
    return Color(c.r, c.g, c.b, 200)
end

local function MuzzleLoad()
    local raw = file.Read(MUZZLE_FILE, "DATA")
    if raw then muzzleSaved = util.JSONToTable(raw) or {} end

    local migrated = false
    for class, off in pairs(muzzleSaved) do
        if off.auto then muzzleSaved[class] = nil migrated = true end
    end
    for class, def in pairs(builtinDefaults) do
        if not muzzleSaved[class] then muzzleSaved[class] = { p = def.p, y = def.y, r = def.r } end
    end
    if migrated then file.Write(MUZZLE_FILE, util.TableToJSON(muzzleSaved, true)) end

    raw = file.Read(WM_MUZZLE_FILE, "DATA")
    if raw then wmMuzzleSaved = util.JSONToTable(raw) or {} end

    raw = file.Read(LASER_FILE, "DATA")
    if raw then
        local t = util.JSONToTable(raw) or EMPTY
        laserEnabled   = t.enabled   or {}
        laserColors    = t.colors    or {}
        laserMaterials = t.materials or {}
    end
end

local function MuzzleSave()
    file.Write(MUZZLE_FILE, util.TableToJSON(muzzleSaved, true))
    file.Write(WM_MUZZLE_FILE, util.TableToJSON(wmMuzzleSaved, true))
    file.Write(LASER_FILE, util.TableToJSON({
        enabled = laserEnabled, colors = laserColors, materials = laserMaterials,
    }, true))
end
MuzzleLoad()

-- ---------------------------------------------------------------------------
-- Weapon class checks
-- ---------------------------------------------------------------------------

local SKIP_CLASSES = { weapon_vrmod_empty = true, weapon_fists = true }

local function IsArcVRWeapon(wep)
    if wep.ArcticVR then return true end
    local class = wep:GetClass()
    return string_find(class, "arcticvr_", 1, true)
        or string_find(class, "catse_vr_gun", 1, true)
        or string_find(class, "cvrg_", 1, true)
end

local function ShouldProcess(wep)
    if not IsValid(wep) then return false end
    if SKIP_CLASSES[wep:GetClass()] then return false end
    return not IsArcVRWeapon(wep)
end

-- ---------------------------------------------------------------------------
-- Offset application
-- ---------------------------------------------------------------------------

do
    local origUpdateViewModel = vrmod.utils.UpdateViewModel

    vrmod.utils.UpdateViewModel = function(...)
        origUpdateViewModel(...)

        local muz = g_VR.viewModelMuzzle
        if not muz then return end

        local wm  = g_VR.wmActive
        local off = wm and wmMuzzlePreview or not wm and muzzlePreview
        if not off then
            local wep = LocalPlayer():GetActiveWeapon()
            if not ShouldProcess(wep) then return end
            off = (wm and wmMuzzleSaved or muzzleSaved)[wep:GetClass()]
            if not off then return end
        end

        local p, y, r = off.p or 0, off.y or 0, off.r or 0
        if p == 0 and y == 0 and r == 0 then return end

        local ang = muz.Ang
        ang:RotateAroundAxis(ang:Right(), p)
        ang:RotateAroundAxis(ang:Up(), y)
        ang:RotateAroundAxis(ang:Forward(), r)
    end
end

hook.Add("PostDrawTranslucentRenderables", "vrmod_muzzlefix_laser", function(depth, sky)
    if depth or sky or not next(laserEnabled) then return end

    local ply = LocalPlayer()
    local wep = ply:GetActiveWeapon()
    if not IsValid(wep) then return end

    local class = wep:GetClass()
    if not laserEnabled[class] then return end

    -- wm_base draws from its own worldmodel muzzle (the viewmodel one is
    -- suppressed), traced to the hit point. Same per-class config as everything
    -- else, so this menu configures it too.
    if wep.IsWMBase and wep.WMGetMuzzleWorld then
        local mp, dir = wep:WMGetMuzzleWorld(ply)
        if not mp then return end
        local tr = util.TraceLine({ start = mp, endpos = mp + dir * 10000, filter = ply })
        render.SetMaterial(GetLaserMat(class))
        render.DrawBeam(mp, tr.HitPos, 3, 0, 1, GetLaserColor(class))
        return
    end

    local muz = g_VR.viewModelMuzzle
    if not muz then return end
    render.SetMaterial(GetLaserMat(class))
    render.DrawBeam(muz.Pos, muz.Pos + muz.Ang:Forward() * 1000, 3, 0, 1, GetLaserColor(class))
end)

-- ============================================================================
-- GRIP POSITION
-- ============================================================================

local GRIP_FILE    = "vrmod_grip_offsets.json"
local GRIP_LH_FILE = "vrmod_grip_offsets_lefthand.json"

local gripSaved, gripSavedLH = {}, {}
local gripCurrent = { pos = Vector(), ang = Angle() }
local gripRepos, gripUnsaved = false, false
local gripFrozenPos, gripFrozenAng = nil, nil
local gripListeners = {}

vrmod_gripfix = vrmod_gripfix or {}
vrmod_gripfix.lhOffsets = gripSavedLH
vrmod_gripfix.lhLive    = nil

local function GripStatus(msg)
    for _, fn in pairs(gripListeners) do fn(msg) end
end

-- Flat px/py/pz/ap/ay/ar is both the on-disk and the preset format, so the
-- same two functions serve saving, loading, exporting and importing.
local function GripPack(src)
    local out = {}
    for class, e in pairs(src) do
        out[class] = { px = e.pos.x, py = e.pos.y, pz = e.pos.z, ap = e.ang.p, ay = e.ang.y, ar = e.ang.r }
    end
    return out
end

local function GripUnpack(src, dst, overwrite)
    local n = 0
    for class, e in pairs(src or EMPTY) do
        if overwrite or not dst[class] then
            dst[class] = {
                pos = Vector(e.px or 0, e.py or 0, e.pz or 0),
                ang = Angle(e.ap or 0, e.ay or 0, e.ar or 0),
            }
            n = n + 1
        end
    end
    return n
end

local function GripLoad()
    local raw = file.Read(GRIP_FILE, "DATA")
    if raw then GripUnpack(util.JSONToTable(raw), gripSaved, true) end
    raw = file.Read(GRIP_LH_FILE, "DATA")
    if raw then GripUnpack(util.JSONToTable(raw), gripSavedLH, true) end
end

local function GripSaveFile()
    file.Write(GRIP_FILE, util.TableToJSON(GripPack(gripSaved), true))
    file.Write(GRIP_LH_FILE, util.TableToJSON(GripPack(gripSavedLH), true))
end
GripLoad()

-- Which hand is holding the gun. VRMod's own flag first, ArcVR's as fallback:
-- reading only ArcticVR.GunInLeftHand reports right-handed whenever ArcVR
-- isn't installed, since sh_lefthand's bridge onto it is guarded by
-- `if ArcticVR then`.
local function WepLeft()
    return g_VR.gunInLeftHand or (ArcticVR and ArcticVR.GunInLeftHand) or false
end

local function GetHandPose()
    local t = g_VR and g_VR.tracking
    local p = t and (WepLeft() and t.pose_lefthand or t.pose_righthand)
    if p then return p.pos, p.ang end
end

local function GetVMI() return g_VR and g_VR.currentvmi end

hook.Add("Think", "vrmod_gripoffset_apply", function()
    if not g_VR or not g_VR.active then return end
    local vmi = GetVMI() if not vmi then return end

    if gripRepos and gripFrozenPos then
        local hp, ha = GetHandPose() if not hp then return end
        vmi.offsetPos, vmi.offsetAng = WorldToLocal(gripFrozenPos, gripFrozenAng, hp, ha)
        return
    end

    local c = gripCurrent
    if c.pos:LengthSqr() == 0 and c.ang.p == 0 and c.ang.y == 0 and c.ang.r == 0 then return end
    vmi.offsetPos = Vector(c.pos)
    vmi.offsetAng = Angle(c.ang)
end)

hook.Add("VRMod_Input", "vrmod_gripoffset_grab", function(action, pressed)
    if not gripRepos or action ~= (WepLeft() and "boolean_left_pickup" or "boolean_right_pickup") then return end
    if not pressed then return true end

    local hp, ha = GetHandPose() if not hp then return end
    local np, na = WorldToLocal(gripFrozenPos, gripFrozenAng, hp, ha)

    -- Copy rather than share: gripCurrent, g_VR.currentvmi and gripSaved all end
    -- up holding these, and anything editing a Vector/Angle in place would
    -- otherwise silently rewrite the others (and the saved JSON).
    gripCurrent.pos, gripCurrent.ang = Vector(np), Angle(na)

    local vmi = GetVMI()
    if vmi then vmi.offsetPos, vmi.offsetAng = Vector(np), Angle(na) end

    gripRepos, gripFrozenPos, gripFrozenAng = false, nil, nil
    vrmod_gripfix.repos = nil
    vrmod_gripfix.suppressDrop = true
    timer.Simple(0.5, function() vrmod_gripfix.suppressDrop = false end)

    gripUnsaved = true
    GripStatus("Grip set - press Save to keep it.")
    Msg("[GripOffset] Grip repositioned - press Save.")
    return true
end)

hook.Add("VRMod_AllowDefaultAction", "vrmod_gripoffset_blockdefault", function(action)
    if not gripRepos and not vrmod_gripfix.suppressDrop then return end
    if action == "boolean_left_pickup" or action == "boolean_right_pickup" then return false end
end)

local lastGripClass = ""

hook.Add("Think", "vrmod_gripoffset_wepchange", function()
    local class = ActiveClass() or ""
    if class == lastGripClass then return end
    lastGripClass = class

    if gripRepos then
        gripRepos, gripFrozenPos, gripFrozenAng = false, nil, nil
        vrmod_gripfix.repos = nil
    end
    gripUnsaved = false

    local saved = gripSaved[class]
    if saved then
        gripCurrent.pos, gripCurrent.ang = Vector(saved.pos), Angle(saved.ang)
    else
        gripCurrent.pos, gripCurrent.ang = Vector(), Angle()
    end
    GripStatus("Ready.")
end)

hook.Add("VRMod_Exit", "vrmod_gripoffset_exit", function(ply)
    if ply ~= LocalPlayer() then return end
    gripRepos, gripFrozenPos, gripFrozenAng = false, nil, nil
    vrmod_gripfix.repos = nil
    vrmod_gripfix.lhLive = nil
end)

local function GripStart()
    if not g_VR or not g_VR.active then GripStatus("VR is not active.") return end
    local vmi = GetVMI() if not vmi then GripStatus("No weapon view model info.") return end
    local hp, ha = GetHandPose() if not hp then GripStatus("No hand tracking.") return end

    gripFrozenPos, gripFrozenAng = LocalToWorld(vmi.offsetPos, vmi.offsetAng, hp, ha)
    gripRepos = true
    vrmod_gripfix.repos = true
    GripStatus("Gun frozen - move your weapon hand to it, then grab.")
    Msg("[GripOffset] Gun frozen - move your hand to it and grab.")
end

local function GripCancel()
    gripRepos, gripFrozenPos, gripFrozenAng = false, nil, nil
    vrmod_gripfix.repos = nil
    local vmi = GetVMI()
    if vmi then vmi.offsetPos, vmi.offsetAng = Vector(gripCurrent.pos), Angle(gripCurrent.ang) end
    GripStatus("Cancelled.")
end

local function GripSaveCurrent()
    local class = ActiveClass()
    if not class then GripStatus("No weapon equipped.") return false end
    gripSaved[class] = { pos = Vector(gripCurrent.pos), ang = Angle(gripCurrent.ang) }
    GripSaveFile()
    gripUnsaved = false
    GripStatus("Saved for " .. class)
    return true
end

local function GripReset()
    local class = ActiveClass() if not class then return end
    gripSaved[class] = nil
    GripSaveFile()
    gripCurrent.pos, gripCurrent.ang = Vector(), Angle()
    local vmi = GetVMI()
    if vmi then vmi.offsetPos, vmi.offsetAng = Vector(), Angle() end
    gripUnsaved = false
    GripStatus("Reset for " .. class)
end

-- ============================================================================
-- ANIMATION DISABLER
-- ============================================================================

local ANIM_FILE    = "weapon_anim_disabled.txt"
local animDisabled = {}

local function AnimLoad()
    local raw = file.Read(ANIM_FILE, "DATA")
    if raw then animDisabled = util.JSONToTable(raw) or {} end
end
local function AnimSave() file.Write(ANIM_FILE, util.TableToJSON(animDisabled)) end
AnimLoad()

hook.Add("PreDrawViewModel", "vrmod_weaponfix_animdisable", function(vm, _, wep)
    if not next(animDisabled) then return end
    if not IsValid(vm) or not IsValid(wep) then return end
    if not animDisabled[wep:GetClass()] then return end
    vm:SetCycle(0)
    vm:SetPlaybackRate(0)
end)

-- ============================================================================
-- PER-WEAPON WORLD MODELS
-- ============================================================================

local WM_FILE = "vrmod_worldmodel_weapons.json"

g_VR = g_VR or {}
g_VR.wmWeapons = g_VR.wmWeapons or {}
g_VR.wmForced  = g_VR.wmForced or {}  -- class -> true: always worldmodel, set by code (e.g. wm_base), not user-toggleable
g_VR.wmActive  = g_VR.wmActive or false

local function WMLoad()
    local raw = file.Read(WM_FILE, "DATA")
    if not raw then return end
    for class, v in pairs(util.JSONToTable(raw) or EMPTY) do
        if v then g_VR.wmWeapons[class] = true end
    end
end
local function WMSave() file.Write(WM_FILE, util.TableToJSON(g_VR.wmWeapons, true)) end
WMLoad()

-- Apply the WM/VM switch for the current weapon immediately instead of waiting
-- for a weapon-switch net message. Switching TO viewmodel mode may leave finger
-- angles zeroed until the next full weapon swap.
local function WMApplyNow()
    if not g_VR.active then return end
    local ply = LocalPlayer()
    local wep = ply:GetActiveWeapon()
    if not IsValid(wep) then return end

    if g_VR.wmWeapons[wep:GetClass()] or g_VR.wmForced[wep:GetClass()] or wep.IsWMBase then
        g_VR.wmActive = true
        wep:SetNoDraw(false) -- see sh_network: nothing else un-hides it
        g_VR.viewModel  = wep
        g_VR.currentvmi = nil
        if g_VR.zeroHandAngles then
            vrmod.SetRightHandOpenFingerAngles(g_VR.zeroHandAngles)
            vrmod.SetRightHandClosedFingerAngles(g_VR.zeroHandAngles)
        end
    else
        g_VR.wmActive = false
        local viewModel = ply:GetViewModel()
        if IsValid(viewModel) then g_VR.viewModel = viewModel end
    end
end

-- Force a weapon CLASS to always render as a worldmodel (never a viewmodel),
-- ignoring the global vrmod_useworldmodels convar and the per-weapon menu
-- toggle. Intended to be called from weapon code (wm_base calls this for every
-- child in Initialize). Pass force=false to lift the override. Re-applies live
-- if that class is the active weapon.
function g_VR.ForceWorldModel(class, force)
    if not class then return end
    g_VR.wmForced[class] = (force ~= false) or nil
    if ActiveClass() == class then WMApplyNow() end
end

hook.Add("VRMod_Exit", "vrmod_wm_exit", function(ply)
    if ply == LocalPlayer() then g_VR.wmActive = false end
end)

-- Re-resolve the worldmodel weapon whenever g_VR.viewModel has gone stale.
-- A drop followed by an instant regrab Remove()s the world entity and hands back
-- a fresh weapon without the server ever emitting a switchweapon -- from its
-- point of view the active class never changed -- so g_VR.viewModel is left
-- pointing at a dead entity and nothing draws or muzzles. One native per frame
-- on the steady path, and the identity compare exits before any table lookup.
hook.Add("VRMod_Tracking", "vrmod_wm_revalidate", function()
    if not g_VR.wmActive then return end
    local wep = LocalPlayer():GetActiveWeapon()
    if g_VR.viewModel == wep or not IsValid(wep) then return end
    if g_VR.wmWeapons[wep:GetClass()] or g_VR.wmForced[wep:GetClass()] or wep.IsWMBase then
        wep:SetNoDraw(false)
        g_VR.viewModel = wep
    end
end)

-- ============================================================================
-- ATTACK DISABLER
-- ============================================================================

local ATKBLOCK_FILE = "vrmod_attack_disabled.json"
local atkDisabled   = {}

local function AtkLoad()
    local raw = file.Read(ATKBLOCK_FILE, "DATA")
    if raw then atkDisabled = util.JSONToTable(raw) or {} end
end
local function AtkSave() file.Write(ATKBLOCK_FILE, util.TableToJSON(atkDisabled)) end
AtkLoad()

hook.Add("CreateMove", "vrmod_weaponfix_atkblock", function(cmd)
    if not next(atkDisabled) or not g_VR.active then return end
    local wep = LocalPlayer():GetActiveWeapon()
    if not IsValid(wep) or not atkDisabled[wep:GetClass()] then return end
    cmd:SetButtons(bit_band(cmd:GetButtons(), ATK_MASK))
end)

-- ============================================================================
-- PRESETS
--
-- A preset is one table holding every per-weapon fix. Exporting writes two
-- copies into data/vrmod_weaponfix_presets/:
--   <name>.json      re-importable locally
--   <name>.lua.txt   drop the ".txt" and put it in your addon's
--                    lua/vrmod_weaponfix_presets/ folder to publish it
-- Importing scans the LUA search path, so every subscribed Workshop addon that
-- ships a preset shows up in the list with no extra wiring.
-- ============================================================================

local PRESET_DIR = "vrmod_weaponfix_presets"

local function KeyList(t)
    local out, n = {}, 0
    for k, v in SortedPairs(t) do
        if v then n = n + 1 out[n] = k end
    end
    return out
end

local function PresetCollect(name)
    return {
        name     = name,
        author   = LocalPlayer():Nick(),
        muzzle   = muzzleSaved,
        muzzlewm = wmMuzzleSaved,
        grip     = GripPack(gripSaved),
        gripleft = GripPack(gripSavedLH),
        anim     = KeyList(animDisabled),
        wm       = KeyList(g_VR.wmWeapons),
        atk      = KeyList(atkDisabled),
    }
end

local function PresetCount(p)
    return table_Count(p.muzzle or EMPTY) + table_Count(p.muzzlewm or EMPTY)
         + table_Count(p.grip or EMPTY)   + table_Count(p.gripleft or EMPTY)
         + #(p.anim or EMPTY) + #(p.wm or EMPTY) + #(p.atk or EMPTY)
end

local function PresetApply(p, overwrite)
    if not istable(p) then return 0 end
    local n = 0

    for _, pair in ipairs({ { p.muzzle, muzzleSaved }, { p.muzzlewm, wmMuzzleSaved } }) do
        local dst = pair[2]
        for class, off in pairs(pair[1] or EMPTY) do
            if overwrite or not dst[class] then
                dst[class] = { p = off.p or 0, y = off.y or 0, r = off.r or 0 }
                n = n + 1
            end
        end
    end

    n = n + GripUnpack(p.grip, gripSaved, overwrite)
          + GripUnpack(p.gripleft, gripSavedLH, overwrite)

    for _, pair in ipairs({ { p.anim, animDisabled }, { p.wm, g_VR.wmWeapons }, { p.atk, atkDisabled } }) do
        local dst = pair[2]
        for _, class in ipairs(pair[1] or EMPTY) do
            if not dst[class] then dst[class] = true n = n + 1 end
        end
    end

    MuzzleSave() GripSaveFile() AnimSave() WMSave() AtkSave()
    WMApplyNow()
    lastGripClass = "" -- forces the held weapon's grip offset to re-apply

    return n
end

local function PresetList()
    local out, n = {}, 0

    for _, f in ipairs(file.Find(PRESET_DIR .. "/*.lua", "LUA")) do
        local ok, t = pcall(include, PRESET_DIR .. "/" .. f)
        if ok and istable(t) then
            n = n + 1
            out[n] = { file = f, source = "Addon", data = t }
        end
    end

    for _, f in ipairs(file.Find(PRESET_DIR .. "/*.json", "DATA")) do
        local t = util.JSONToTable(file.Read(PRESET_DIR .. "/" .. f, "DATA") or "")
        if istable(t) then
            n = n + 1
            out[n] = { file = f, source = "Local", data = t }
        end
    end

    return out
end

local function PresetExport(name)
    name = string.lower(string.gsub(name or "", "[^%w_%-]", "_"))
    if name == "" then name = "preset" end

    file.CreateDir(PRESET_DIR)
    local json = util.TableToJSON(PresetCollect(name), true)

    -- file.Write refuses a .lua extension, so the shareable copy lands as
    -- .lua.txt and the user drops the ".txt".
    file.Write(PRESET_DIR .. "/" .. name .. ".json", json)
    file.Write(PRESET_DIR .. "/" .. name .. ".lua.txt", "return util.JSONToTable([==[\n" .. json .. "\n]==])\n")

    return name
end

-- ============================================================================
-- PANEL: MUZZLE ANGLES
-- ============================================================================

local function BuildMuzzlePanel(root)
    local form = MakeForm(root, "Muzzle Angles")

    local wepLbl  = form:Help("Weapon: none")
    local modeLbl = form:Help("Editing: viewmodel offsets")

    local isWM = false
    local liveP, liveY, liveR = 0, 0, 0

    local function SyncPreview()
        local off = { p = liveP, y = liveY, r = liveR }
        if isWM then wmMuzzlePreview, muzzlePreview = off, nil
        else muzzlePreview, wmMuzzlePreview = off, nil end
    end

    -- Laser --------------------------------------------------------------
    local laserChk = MakeCheck(form, "Show muzzle laser", function(v)
        local class = ActiveClass()
        if not class then Msg("[MuzzleFix] No weapon equipped.", true) return end
        laserEnabled[class] = v or nil
        MuzzleSave()
    end)
    form:ControlHelp("Draws a beam down the muzzle so you can see the correction live.")

    local matBox = form:ComboBox("Laser material")
    for _, path in ipairs(LASER_MATERIALS) do matBox:AddChoice(path, path) end
    matBox.OnSelect = function(_, _, _, data)
        local class = ActiveClass() if not class then return end
        laserMaterials[class] = data
        MuzzleSave()
    end

    local colBtn = form:Button("Laser Colour...")
    colBtn.DoClick = function()
        local class = ActiveClass()
        if not class then Msg("[MuzzleFix] Equip a weapon first.", true) return end

        local existing = laserColors[class] or DEFAULT_LASER
        local pf = vgui_Create("DFrame")
        pf:SetSize(260, 260)
        pf:SetTitle("Laser Colour - " .. class)
        pf:Center()
        pf:MakePopup()

        local mixer = vgui_Create("DColorMixer", pf)
        mixer:Dock(FILL)
        mixer:DockMargin(6, 6, 6, 6)
        mixer:SetAlphaBar(false)
        mixer:SetColor(Color(existing.r, existing.g, existing.b))

        local apply = vgui_Create("DButton", pf)
        apply:SetText("Apply")
        apply:Dock(BOTTOM)
        apply:DockMargin(6, 0, 6, 6)
        apply.DoClick = function()
            local c = mixer:GetColor()
            laserColors[class] = { r = c.r, g = c.g, b = c.b }
            MuzzleSave()
            pf:Close()
        end
    end

    -- Angles -------------------------------------------------------------
    local pitch = form:NumSlider("Pitch", nil, -180, 180, 1)
    local yaw   = form:NumSlider("Yaw", nil, -180, 180, 1)
    local roll  = form:NumSlider("Roll", nil, -180, 180, 1)
    form:ControlHelp("Drag, or type an exact value. Applied live - press Save to keep it.")

    pitch.OnValueChanged = function(_, v) liveP = math_Round(v, 1) SyncPreview() end
    yaw.OnValueChanged   = function(_, v) liveY = math_Round(v, 1) SyncPreview() end
    roll.OnValueChanged  = function(_, v) liveR = math_Round(v, 1) SyncPreview() end

    local list
    local function LoadInto(p, y, r)
        pitch:SetValue(p) yaw:SetValue(y) roll:SetValue(r)
    end

    local function Rebuild()
        list:Clear()
        for _, set in ipairs({ { muzzleSaved, "Viewmodel" }, { wmMuzzleSaved, "World model" } }) do
            for class, off in SortedPairs(set[1]) do
                local ln = list:AddLine(class, set[2],
                    string_format("%.1f / %.1f / %.1f", off.p or 0, off.y or 0, off.r or 0))
                ln.class, ln.tbl = class, set[1]
            end
        end
    end

    local saveBtn = form:Button("Save For This Weapon")
    saveBtn.DoClick = function()
        local class = ActiveClass()
        if not class then Msg("[MuzzleFix] No weapon equipped.", true) return end
        local tbl = isWM and wmMuzzleSaved or muzzleSaved
        tbl[class] = { p = liveP, y = liveY, r = liveR }
        MuzzleSave()
        muzzlePreview, wmMuzzlePreview = nil, nil
        Rebuild()
        Msg("[MuzzleFix] Saved " .. (isWM and "world model" or "viewmodel") .. " offset for " .. class)
    end

    local resetBtn = form:Button("Reset This Weapon")
    resetBtn.DoClick = function()
        local class = ActiveClass() if not class then return end
        local tbl = isWM and wmMuzzleSaved or muzzleSaved
        tbl[class] = nil
        MuzzleSave()
        LoadInto(0, 0, 0)
        Rebuild()
        Msg("[MuzzleFix] Reset " .. class)
    end

    local zeroBtn = form:Button("Zero Sliders")
    zeroBtn.DoClick = function() LoadInto(0, 0, 0) end

    -- Saved list ---------------------------------------------------------
    local listForm = MakeForm(root, "Saved Muzzle Offsets")
    list = MakeList(listForm, 150, "Weapon", "Mode", "Pitch / Yaw / Roll")
    list.OnRowSelected = function(_, _, ln)
        local off = ln.tbl[ln.class] or EMPTY
        LoadInto(off.p or 0, off.y or 0, off.r or 0)
    end

    local delBtn = listForm:Button("Delete Selected")
    delBtn.DoClick = function()
        local _, ln = list:GetSelectedLine() if not ln then return end
        ln.tbl[ln.class] = nil
        MuzzleSave()
        Rebuild()
    end
    Rebuild()

    Watch(root, function(class, wm)
        isWM = wm
        wepLbl:SetText("Weapon: " .. class)
        modeLbl:SetText(wm and "Editing: world model offsets" or "Editing: viewmodel offsets")
        laserChk:SetQuiet(laserEnabled[class])
        matBox:SetValue(laserMaterials[class] or DEFAULT_LASER_MAT)
        local off = (wm and wmMuzzleSaved or muzzleSaved)[class] or EMPTY
        LoadInto(off.p or 0, off.y or 0, off.r or 0)
    end, function()
        muzzlePreview, wmMuzzlePreview = nil, nil
    end)
end

-- ============================================================================
-- PANEL: GRIP POSITION
-- ============================================================================

local function BuildGripPanel(root)
    local form = MakeForm(root, "Grip Position")

    local wepLbl    = form:Help("Weapon: none")
    local statusLbl = form:Help("Ready.")

    gripListeners[root] = function(msg)
        if not IsValid(statusLbl) then return end
        statusLbl:SetText(gripUnsaved and (msg .. "  (unsaved)") or msg)
    end

    form:Help("1. Press Start Reposition\n2. The gun freezes in world space\n" ..
              "3. Move your weapon hand to where the gun is\n4. Grab with the weapon-hand grip\n" ..
              "5. The gun snaps to your new grip point")

    local startBtn = form:Button("Start Reposition")
    startBtn.DoClick = GripStart

    local cancelBtn = form:Button("Cancel Reposition")
    cancelBtn.DoClick = GripCancel

    local saveBtn = form:Button("Save For This Weapon")
    local resetBtn = form:Button("Reset This Weapon")

    -- Foregrip addon options ---------------------------------------------
    local fgChk
    if vrmod_foregrip then
        local fgForm = MakeForm(root, "Foregrip")

        if vrmod_foregrip.SetVisualOnly then
            fgChk = MakeCheck(fgForm, "Visual only (pin hand without rotating weapon)", function(v)
                local class = ActiveClass() if not class then return end
                vrmod_foregrip.SetVisualOnly(class, v)
            end)
        end

        fgForm:CheckBox("Spherical grab zone", "vrmod_foregrip_sphere")
        fgForm:ControlHelp("Off = directional box, on = radial sphere.")
        fgForm:NumSlider("Grab zone scale", "vrmod_foregrip_scale", 0.25, 4, 2)
        fgForm:CheckBox("Show grab zone", "vrmod_foregrip_debug")
        fgForm:ControlHelp("Draws the live zone: green = a grab would latch, blue = gripping, grey = out of reach. The orange cube marks the hand foregrip thinks holds the gun.")
    end

    -- Saved lists ---------------------------------------------------------
    local listForm = MakeForm(root, "Saved Grip Offsets")
    local list = MakeList(listForm, 150, "Weapon", "Hand", "X / Y / Z")

    local function Rebuild()
        list:Clear()
        for _, set in ipairs({ { gripSaved, "Right" }, { gripSavedLH, "Left" } }) do
            for class, e in SortedPairs(set[1]) do
                local ln = list:AddLine(class, set[2],
                    string_format("%.1f / %.1f / %.1f", e.pos.x, e.pos.y, e.pos.z))
                ln.class, ln.tbl, ln.left = class, set[1], set[1] == gripSavedLH
            end
        end
    end

    list.OnRowSelected = function(_, _, ln)
        local e = ln.tbl[ln.class] if not e then return end
        if ln.left then
            vrmod_gripfix.lhLive = { pos = Vector(e.pos), ang = Angle(e.ang) }
            GripStatus("Loaded left-hand offset for " .. ln.class)
            return
        end
        gripCurrent.pos, gripCurrent.ang = Vector(e.pos), Angle(e.ang)
        local vmi = GetVMI()
        if vmi then vmi.offsetPos, vmi.offsetAng = Vector(e.pos), Angle(e.ang) end
        GripStatus("Loaded " .. ln.class)
    end

    local delBtn = listForm:Button("Delete Selected")
    delBtn.DoClick = function()
        local _, ln = list:GetSelectedLine() if not ln then return end
        ln.tbl[ln.class] = nil
        GripSaveFile()
        Rebuild()
    end
    Rebuild()

    saveBtn.DoClick  = function() if GripSaveCurrent() then Rebuild() Msg("[GripOffset] Saved.") end end
    resetBtn.DoClick = function() GripReset() Rebuild() Msg("[GripOffset] Reset.") end

    Watch(root, function(class)
        wepLbl:SetText("Weapon: " .. class)
        if fgChk then
            local vo = vrmod_foregrip.visualOnly
            fgChk:SetQuiet(vo and vo[class])
        end
    end, function()
        gripListeners[root] = nil
        if gripRepos then GripCancel() end
    end)
end

-- ============================================================================
-- PANELS: simple per-class toggle lists (animations / world models / attacks)
-- ============================================================================

-- One builder covers three tabs that only differ in wording and storage.
local function BuildTogglePanel(root, cfg)
    local form = MakeForm(root, cfg.title)
    local wepLbl = form:Help("Weapon: none")
    form:ControlHelp(cfg.help)

    local list
    local function Rebuild()
        list:Clear()
        for class in SortedPairs(cfg.tbl) do
            if cfg.tbl[class] then list:AddLine(class) end
        end
    end

    local chk = MakeCheck(form, cfg.label, function(v)
        local class = ActiveClass()
        if not class then Msg("[WeaponFix] No weapon equipped.", true) return end
        cfg.tbl[class] = v or nil
        cfg.save()
        if cfg.onChange then cfg.onChange() end
        Rebuild()
    end)

    local clearBtn = form:Button(cfg.clear)
    clearBtn.DoClick = function()
        table.Empty(cfg.tbl)
        cfg.save()
        if cfg.onChange then cfg.onChange() end
        chk:SetQuiet(false)
        Rebuild()
        Msg("[WeaponFix] " .. cfg.clear .. " done.")
    end

    local listForm = MakeForm(root, cfg.listTitle)
    list = MakeList(listForm, 170, "Weapon")

    local delBtn = listForm:Button("Remove Selected")
    delBtn.DoClick = function()
        local _, ln = list:GetSelectedLine() if not ln then return end
        cfg.tbl[ln:GetColumnText(1)] = nil
        cfg.save()
        if cfg.onChange then cfg.onChange() end
        chk:SetQuiet(cfg.tbl[ActiveClass() or ""])
        Rebuild()
    end
    Rebuild()

    Watch(root, function(class)
        wepLbl:SetText("Weapon: " .. class)
        chk:SetQuiet(cfg.tbl[class])
    end)
end

local function BuildAnimPanel(root)
    BuildTogglePanel(root, {
        title     = "Animations",
        help      = "Freezes the viewmodel animation for weapons whose anims fight the VR pose.",
        label     = "Disable animations for this weapon",
        clear     = "Re-enable All",
        listTitle = "Animations Disabled",
        tbl       = animDisabled,
        save      = AnimSave,
    })
end

local function BuildWorldModelPanel(root)
    BuildTogglePanel(root, {
        title     = "World Models",
        help      = "Renders the weapon's world model instead of its viewmodel. Applies instantly, no VR restart.",
        label     = "Force world model for this weapon",
        clear     = "Clear All Overrides",
        listTitle = "Using World Model",
        tbl       = g_VR.wmWeapons,
        save      = WMSave,
        onChange  = WMApplyNow,
    })
end

local function BuildAtkBlockPanel(root)
    BuildTogglePanel(root, {
        title     = "Attack Block",
        help      = "Strips IN_ATTACK and IN_ATTACK2 so motion melee is the only way to swing.",
        label     = "Block built-in attack for this weapon",
        clear     = "Unblock All",
        listTitle = "Attacks Blocked",
        tbl       = atkDisabled,
        save      = AtkSave,
    })
end

-- ============================================================================
-- PANEL: PRESETS
-- ============================================================================

local function BuildPresetPanel(root)
    local inForm = MakeForm(root, "Import")
    inForm:ControlHelp("Presets found in your data folder and in any subscribed addon that ships one.")

    local list = MakeList(inForm, 150, "Preset", "Author", "Source", "Weapons")
    local found = {}

    local function Refresh()
        list:Clear()
        found = PresetList()
        for i, p in ipairs(found) do
            list:AddLine(p.data.name or p.file, p.data.author or "?", p.source, tostring(PresetCount(p.data))).idx = i
        end
    end

    local overwrite = false
    local owChk = inForm:CheckBox("Overwrite my existing entries")
    owChk.OnChange = function(_, v) overwrite = v end
    inForm:ControlHelp("Off: the preset only fills in weapons you have not configured yourself.")

    local applyBtn = inForm:Button("Apply Selected Preset")
    applyBtn.DoClick = function()
        local _, ln = list:GetSelectedLine()
        if not ln then Msg("[WeaponFix] Select a preset first.", true) return end
        local n = PresetApply(found[ln.idx].data, overwrite)
        Msg("[WeaponFix] Applied " .. n .. " weapon fixes.")
    end

    local refreshBtn = inForm:Button("Rescan For Presets")
    refreshBtn.DoClick = Refresh

    local delBtn = inForm:Button("Delete Selected (local only)")
    delBtn.DoClick = function()
        local _, ln = list:GetSelectedLine() if not ln then return end
        local p = found[ln.idx]
        if p.source ~= "Local" then Msg("[WeaponFix] Addon presets must be unsubscribed, not deleted.", true) return end
        file.Delete(PRESET_DIR .. "/" .. p.file)
        Refresh()
    end
    Refresh()

    local outForm = MakeForm(root, "Export")
    outForm:ControlHelp("Writes every muzzle, grip, animation, world model and attack-block fix you have set.")

    local nameEntry = outForm:TextEntry("Preset name")
    nameEntry:SetValue("my_fixes")

    local expBtn = outForm:Button("Export Preset")
    local expHelp = outForm:Help(" ")
    expBtn.DoClick = function()
        local name = PresetExport(nameEntry:GetValue())
        Refresh()
        expHelp:SetText(string_format(
            "Written to garrysmod/data/%s/\n\n" ..
            "To share on the Workshop:\n" ..
            "1. Rename %s.lua.txt to %s.lua\n" ..
            "2. Put it in <youraddon>/lua/%s/\n" ..
            "3. Publish the addon as normal\n\n" ..
            "Anyone subscribed sees it in this list automatically.",
            PRESET_DIR, name, name, PRESET_DIR))
        Msg("[WeaponFix] Exported preset '" .. name .. "'.")
    end
end

-- ============================================================================
-- Frame
-- ============================================================================

local TABS = {
    { "Muzzle Angles", BuildMuzzlePanel,     "icon16/bullet_go.png" },
    { "Grip Position", BuildGripPanel,       "icon16/wrench.png" },
    { "Animations",    BuildAnimPanel,       "icon16/film.png" },
    { "World Models",  BuildWorldModelPanel, "icon16/box.png" },
    { "Attack Block",  BuildAtkBlockPanel,   "icon16/cancel.png" },
    { "Presets",       BuildPresetPanel,     "icon16/package.png" },
}

local mainFrame

local function OpenWeaponFixMenu()
    if IsValid(mainFrame) then mainFrame:Center() mainFrame:MakePopup() return end

    local frame = vgui_Create("DFrame")
    frame:SetSize(540, 620)
    frame:SetTitle("VRMod - Weapon Fixer")
    frame:SetSizable(true)
    frame:SetMinimumSize(460, 400)
    frame:SetDeleteOnClose(true)
    frame:Center()
    frame:MakePopup()
    mainFrame = frame

    local sheet = vgui_Create("DPropertySheet", frame)
    sheet:Dock(FILL)

    for _, tab in ipairs(TABS) do
        local scroll = vgui_Create("DScrollPanel", sheet)
        tab[2](scroll)
        sheet:AddSheet(tab[1], scroll, tab[3])
    end
end

concommand.Add("vrmod_weaponfix_menu", OpenWeaponFixMenu, nil, "Open the VRMod Weapon Fixer")
concommand.Add("vrmod_muzzlefix_menu", OpenWeaponFixMenu, nil, "Alias for vrmod_weaponfix_menu")

-- ============================================================================
-- Menu integration
-- ============================================================================

hook.Add("VRMod_Menu", "vrmod_weaponfix_hook", function(frame)
    local sheet = frame.DPropertySheet
    if IsValid(sheet) then
        local panel = vgui_Create("DPanel", sheet)
        local btn = vgui_Create("DButton", panel)
        btn:SetText("Open Weapon Fixer")
        btn:Dock(TOP)
        btn:DockMargin(8, 8, 8, 0)
        btn:SetTall(32)
        btn.DoClick = OpenWeaponFixMenu
        sheet:AddSheet("Weapon Fixer", panel, "icon16/wrench.png")
        return
    end

    local form = frame.SettingsForm
    if not IsValid(form) then return end
    form:ControlHelp("=== Weapon Fixer ===")
    form:Button("Open Weapon Fixer").DoClick = OpenWeaponFixMenu
end)

local menuItemRegistered = false

local function TryRegisterMenuItem()
    if menuItemRegistered then return true end
    if not vrmod or not vrmod.AddInGameMenuItem then return false end
    if not g_VR.active then return false end
    vrmod.AddInGameMenuItem("Weapon Fix", 5, 4, OpenWeaponFixMenu)
    menuItemRegistered = true
    return true
end

hook.Add("VRMod_Start", "vrmod_weaponfix_menuitem", function(ply)
    if ply ~= LocalPlayer() then return end
    menuItemRegistered = false
    TryRegisterMenuItem()
end)

timer.Create("vrmod_weaponfix_menuitem_poll", 0.5, 0, function()
    if TryRegisterMenuItem() then timer.Remove("vrmod_weaponfix_menuitem_poll") end
end)

hook.Add("PopulateToolMenu", "vrmod_weaponfix_spawnmenu", function()
    spawnmenu.AddToolCategory("Utilities", "VRMod", "VRMod")
    spawnmenu.AddToolMenuOption("Utilities", "VRMod", "VRMod_WeaponFix", "Weapon Fix", "", "", function(panel)
        panel:ClearControls()
        panel:Help("VRMod Weapon Fixer - muzzle angles, grip offsets, animations, world models and attack blocking.")
        panel:Button("Open Weapon Fixer").DoClick = OpenWeaponFixMenu
        panel:Help("Console: vrmod_weaponfix_menu, vrmod_weaponfix_export, vrmod_weaponfix_presets")
    end)
end)

-- ============================================================================
-- Console helpers
-- ============================================================================

concommand.Add("vrmod_muzzle_list", function()
    for _, set in ipairs({ { muzzleSaved, "viewmodel" }, { wmMuzzleSaved, "world model" } }) do
        print("[WeaponFix] Muzzle offsets (" .. set[2] .. "):")
        local any = false
        for c, off in SortedPairs(set[1]) do
            print(string_format("  %-40s  P:%-6.1f Y:%-6.1f R:%-6.1f", c, off.p or 0, off.y or 0, off.r or 0))
            any = true
        end
        if not any then print("  (none)") end
    end
end)

concommand.Add("vrmod_grip_list", function()
    for _, set in ipairs({ { gripSaved, "right hand" }, { gripSavedLH, "left hand" } }) do
        print("[WeaponFix] Grip offsets (" .. set[2] .. "):")
        local any = false
        for c, e in SortedPairs(set[1]) do
            print(string_format("  %-40s  pos:%s  ang:%s", c, tostring(e.pos), tostring(e.ang)))
            any = true
        end
        if not any then print("  (none)") end
    end
end)

local function PrintSet(label, tbl)
    print("[WeaponFix] " .. label .. ":")
    local any = false
    for c in SortedPairs(tbl) do
        if tbl[c] then print("  " .. c) any = true end
    end
    if not any then print("  (none)") end
end

concommand.Add("vrmod_wm_list", function() PrintSet("World model weapons", g_VR.wmWeapons) end)
concommand.Add("vrmod_atkblock_list", function() PrintSet("Attack-blocked weapons", atkDisabled) end)
concommand.Add("vrmod_anim_list", function() PrintSet("Animation-disabled weapons", animDisabled) end)

concommand.Add("vrmod_grip_reposition_start", GripStart)
concommand.Add("vrmod_grip_reposition_cancel", GripCancel)
concommand.Add("vrmod_grip_save", GripSaveCurrent)
concommand.Add("vrmod_grip_reset", GripReset)

concommand.Add("vrmod_muzzle_reset_current", function()
    local class = ActiveClass()
    if not class then print("[WeaponFix] No weapon") return end
    muzzleSaved[class], wmMuzzleSaved[class] = nil, nil
    MuzzleSave()
    print("[WeaponFix] Muzzle reset (VM+WM) for " .. class)
end)

concommand.Add("vrmod_weaponfix_export", function(_, _, args)
    local name = PresetExport(args[1])
    print("[WeaponFix] Exported to data/" .. PRESET_DIR .. "/" .. name .. ".json")
    print("[WeaponFix] Rename " .. name .. ".lua.txt to " .. name .. ".lua and place it in")
    print("[WeaponFix]   <youraddon>/lua/" .. PRESET_DIR .. "/  to publish it on the Workshop.")
end, nil, "Export every weapon fix as a shareable preset")

concommand.Add("vrmod_weaponfix_presets", function()
    local presets = PresetList()
    if #presets == 0 then print("[WeaponFix] No presets found.") return end
    for _, p in ipairs(presets) do
        print(string_format("  %-30s %-8s %-20s %d weapons",
            p.file, p.source, p.data.author or "?", PresetCount(p.data)))
    end
end, nil, "List every preset found locally and in subscribed addons")

concommand.Add("vrmod_weaponfix_apply", function(_, _, args)
    local target = args[1]
    if not target then print("[WeaponFix] Usage: vrmod_weaponfix_apply <file> [1 to overwrite]") return end
    for _, p in ipairs(PresetList()) do
        if p.file == target or p.data.name == target then
            print("[WeaponFix] Applied " .. PresetApply(p.data, args[2] == "1") .. " weapon fixes.")
            return
        end
    end
    print("[WeaponFix] No preset named '" .. target .. "'.")
end, nil, "Apply a preset by file or name")

print("[VRMod WeaponFix] Loaded.")