--[[
    VRMod Weapon Fix
    Tab 1 – Muzzle Angles  : per-weapon P/Y/R correction + laser
    Tab 2 – Grip Position  : physical freeze-and-reposition grip offset
    Tab 3 – Animations     : per-weapon animation disabler
    Tab 4 – World Models   : force world model rendering per weapon
    Tab 5 – Attack Block   : disable IN_ATTACK for motion-controlled melees

    Place in: garrysmod/lua/autorun/client/
    One file, no dependencies.
]]

-- Discard slot for multi-return calls; without it `_, setPRow = AxisRow(...)`
-- below writes the global _ and breaks addons that expect it to stay nil.
local _

if SERVER then return end

-- ============================================================================
-- Cached natives
-- ============================================================================

local LocalPlayer = LocalPlayer
local IsValid = IsValid
local WorldToLocal = WorldToLocal
local LocalToWorld = LocalToWorld
local string_find = string.find
local string_format = string.format
local math_Clamp = math.Clamp
local math_Round = math.Round
local bit_band  = bit.band
local bit_bnot  = bit.bnot

-- ============================================================================
-- Shared palette
-- ============================================================================

local COL_BG         = Color(30,  30,  30,  245)
local COL_PANEL      = Color(38,  38,  42,  245)
local COL_ROW        = Color(48,  48,  54,  230)
local COL_HEADER     = Color(22,  22,  26,  255)
local COL_ACCENT     = Color(80,  160, 220, 255)
local COL_BTN        = Color(58,  58,  65,  255)
local COL_BTN_HOV    = Color(82,  134, 194, 255)
local COL_SAVE       = Color(50,  160, 80,  255)
local COL_SAVE_HOV   = Color(72,  204, 104, 255)
local COL_RESET      = Color(180, 60,  60,  255)
local COL_RESET_HOV  = Color(220, 82,  82,  255)
local COL_START      = Color(60,  130, 200, 255)
local COL_START_HOV  = Color(80,  170, 240, 255)
local COL_CANCEL     = Color(140, 90,  40,  255)
local COL_CANCEL_HOV = Color(190, 120, 50,  255)
local COL_LASER_ON   = Color(50,  200, 90,  255)
local COL_LASER_HOV  = Color(70,  240, 110, 255)
local COL_LASER_OFF  = Color(58,  58,  65,  255)
local COL_TEXT       = Color(222, 222, 222, 255)
local COL_DIM        = Color(140, 140, 148, 255)
local COL_WARN       = Color(230, 180, 50,  255)
local COL_ACTIVE     = Color(50,  210, 100, 255)
local COL_MARKER_BG  = Color(34,  90,  34,  210)

-- ============================================================================
-- Shared UI helpers
-- ============================================================================

local function StyledButton(parent, label, col, hoverCol, onClick)
    local btn = vgui.Create("DButton", parent)
    btn:SetText(label) btn:SetFont("DermaDefaultBold") btn:SetTextColor(COL_TEXT)
    local hov = false
    btn.Paint = function(_, w, h) draw.RoundedBox(5, 0, 0, w, h, hov and hoverCol or col) end
    btn.OnCursorEntered = function() hov = true  end
    btn.OnCursorExited  = function() hov = false end
    btn.DoClick = onClick
    return btn
end

local function Separator(parent)
    local s = vgui.Create("DPanel", parent)
    s:Dock(TOP) s:SetTall(1) s:DockMargin(4, 4, 4, 4)
    s.Paint = function(_, w, h) draw.RoundedBox(0, 0, 0, w, h, COL_ACCENT) end
end

local function SectionLabel(parent, text)
    local l = vgui.Create("DLabel", parent)
    l:Dock(TOP) l:SetTall(16) l:DockMargin(8, 2, 8, 0)
    l:SetFont("DermaDefault") l:SetTextColor(COL_DIM) l:SetText(text)
end

local function WeaponBanner(parent)
    local wp = vgui.Create("DPanel", parent)
    wp:Dock(TOP) wp:SetTall(46) wp:DockMargin(4, 4, 4, 2)
    wp.Paint = function(_, w, h)
        draw.RoundedBox(6, 0, 0, w, h, COL_HEADER)
        draw.SimpleText("Active Weapon", "DermaDefaultBold", 8, 5, COL_DIM)
    end
    local lbl = vgui.Create("DLabel", wp)
    lbl:Dock(FILL) lbl:DockMargin(8, 18, 8, 4)
    lbl:SetFont("DermaDefaultBold") lbl:SetTextColor(COL_TEXT)
    return lbl
end

local function WeaponList(parent, savedTable, onRowClick, formatRight)
    local scroll = vgui.Create("DScrollPanel", parent)
    scroll:Dock(TOP) scroll:SetTall(120) scroll:DockMargin(4, 2, 4, 4)
    local function Rebuild()
        scroll:Clear()
        local any = false
        for class, entry in SortedPairs(savedTable) do
            any = true
            local btn = vgui.Create("DButton", scroll)
            btn:SetText("") btn:Dock(TOP) btn:DockMargin(0,0,0,2) btn:SetTall(24)
            local hov = false
            btn.Paint = function(_, w, h)
                draw.RoundedBox(4, 0, 0, w, h, hov and COL_BTN_HOV or COL_ROW)
                draw.SimpleText(class,              "DermaDefault", 8,   h*0.5, COL_TEXT, TEXT_ALIGN_LEFT,  TEXT_ALIGN_CENTER)
                draw.SimpleText(formatRight(entry), "DermaDefault", w-8, h*0.5, COL_DIM,  TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
            end
            btn.OnCursorEntered = function() hov = true  end
            btn.OnCursorExited  = function() hov = false end
            btn.DoClick = function() onRowClick(class, entry) end
        end
        if not any then
            local e = vgui.Create("DLabel", scroll)
            e:Dock(TOP) e:SetTall(24) e:SetTextColor(COL_DIM) e:SetText("  No saved offsets yet.")
        end
    end
    Rebuild()
    return scroll, Rebuild
end

-- ============================================================================
-- TAB 1 – MUZZLE ANGLES
-- ============================================================================

local MUZZLE_FILE      = "vrmod_muzzle_offsets.json"
local WM_MUZZLE_FILE   = "vrmod_muzzle_offsets_wm.json"
local LASER_FILE       = "vrmod_muzzle_lasers.json"

local builtinDefaults = {
    ["weapon_hl1_glock"] = { p = 5, y = -2.5, r = 0 },
}

local muzzleSaved     = {}
local muzzlePreview   = nil
local wmMuzzleSaved   = {}
local wmMuzzlePreview = nil
local laserEnabled    = {}
local laserColors     = {}
local laserMaterials  = {}

local DEFAULT_LASER = { r = 0, g = 220, b = 255 }

local function GetLaserColor(class)
    local c = laserColors[class]
    if c then return Color(c.r, c.g, c.b, 200) end
    return Color(DEFAULT_LASER.r, DEFAULT_LASER.g, DEFAULT_LASER.b, 200)
end

local function MuzzleLoad()
    local raw = file.Read(MUZZLE_FILE, "DATA")
    if raw then muzzleSaved = util.JSONToTable(raw) or {} end
    local migrated = false
    for class, off in pairs(muzzleSaved) do
        if off.auto then muzzleSaved[class] = nil; migrated = true end
    end
    for class, def in pairs(builtinDefaults) do
        if not muzzleSaved[class] then
            muzzleSaved[class] = { p = def.p, y = def.y, r = def.r }
        end
    end
    if migrated then file.Write(MUZZLE_FILE, util.TableToJSON(muzzleSaved, true)) end
    local wmraw = file.Read(WM_MUZZLE_FILE, "DATA")
    if wmraw then wmMuzzleSaved = util.JSONToTable(wmraw) or {} end
    local lraw = file.Read(LASER_FILE, "DATA")
    if lraw then
        local t = util.JSONToTable(lraw) or {}
        laserEnabled   = t.enabled   or {}
        laserColors    = t.colors    or {}
        laserMaterials = t.materials or {}
    end
end
local function MuzzleSave()
    file.Write(MUZZLE_FILE, util.TableToJSON(muzzleSaved, true))
    file.Write(WM_MUZZLE_FILE, util.TableToJSON(wmMuzzleSaved, true))
    file.Write(LASER_FILE,  util.TableToJSON({
        enabled   = laserEnabled,
        colors    = laserColors,
        materials = laserMaterials,
    }, true))
end
MuzzleLoad()

-- ============================================================================
-- Weapon class checks
-- ============================================================================

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
    if IsArcVRWeapon(wep) then return false end
    return true
end

-- ============================================================================
-- Muzzle offset application
-- ============================================================================

local function ApplyMuzzleOffset(ang, p, y, r)
    ang:RotateAroundAxis(ang:Right(), p)
    ang:RotateAroundAxis(ang:Up(), y)
    ang:RotateAroundAxis(ang:Forward(), r)
end

do
    local origUpdateViewModel = vrmod.utils.UpdateViewModel

    vrmod.utils.UpdateViewModel = function(...)
        origUpdateViewModel(...)

        local muz = g_VR.viewModelMuzzle
        if not muz then return end
        local wep = LocalPlayer():GetActiveWeapon()
        if not ShouldProcess(wep) then return end

        local class = wep:GetClass()
        local off
        if g_VR.wmActive then
            off = wmMuzzlePreview or wmMuzzleSaved[class]
        else
            off = muzzlePreview or muzzleSaved[class]
        end
        if not off then return end
        local p, y, r = off.p or 0, off.y or 0, off.r or 0
        if p == 0 and y == 0 and r == 0 then return end
        ApplyMuzzleOffset(muz.Ang, p, y, r)
    end
end

-- ============================================================================
-- Per-weapon laser
-- ============================================================================

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
for _, path in ipairs(LASER_MATERIALS) do
    laserMatCache[path] = Material(path)
end

local function GetLaserMat(class)
    local path = laserMaterials[class] or DEFAULT_LASER_MAT
    return laserMatCache[path] or laserMatCache[DEFAULT_LASER_MAT]
end

hook.Add("PostDrawTranslucentRenderables", "vrmod_muzzlefix_laser", function(depth, sky)
    if depth or sky then return end
    local ply = LocalPlayer()
    local wep = ply:GetActiveWeapon()
    if not IsValid(wep) then return end
    local class = wep:GetClass()
    if not laserEnabled[class] then return end

    -- wm_base draws from its own worldmodel muzzle (the viewmodel one is the
    -- suppressed dumbass), traced to the hit point. Uses the same per-class enable
    -- / material / colour config as every other weapon, so the existing menu
    -- configures it.
    if wep.IsWMBase and wep.WMGetMuzzleWorld then
        local mp, dir = wep:WMGetMuzzleWorld(ply)
        if not mp then return end
        local tr = util.TraceLine({ start = mp, endpos = mp + dir * 10000, filter = ply })
        render.SetMaterial(GetLaserMat(class))
        render.DrawBeam(mp, tr.HitPos, 3, 0, 1, GetLaserColor(class))
        return
    end

    -- Default: viewmodel muzzle (unchanged).
    local muz = g_VR.viewModelMuzzle
    if not muz then return end
    local fwd = muz.Ang:Forward()
    render.SetMaterial(GetLaserMat(class))
    render.DrawBeam(muz.Pos, muz.Pos + fwd * 1000, 3, 0, 1, GetLaserColor(class))
end)

-- ============================================================================
-- Muzzle panel UI
-- ============================================================================

-- Axis row with ±0.1, ±1, ±5 nudge buttons + slider + value label
local function AxisRow(parent, axisLabel, getter, setter)
    local row = vgui.Create("DPanel", parent)
    row:Dock(TOP) row:DockMargin(4,2,4,2) row:SetTall(28)
    row.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, COL_ROW) end

    local api = {}

    local lbl = vgui.Create("DLabel", row)
    lbl:SetText(axisLabel) lbl:SetFont("DermaDefaultBold") lbl:SetTextColor(COL_ACCENT)
    lbl:Dock(LEFT) lbl:DockMargin(6,0,2,0) lbl:SetWide(34) lbl:SetContentAlignment(4)

    -- Minus buttons: -5 -1 -0.1
    for _, step in ipairs({-5, -1, -0.1}) do
        local txt = step == -0.1 and "-.1" or tostring(step)
        local b = StyledButton(row, txt, COL_BTN, COL_BTN_HOV, function()
            api.set(math_Round(math_Clamp(getter() + step, -180, 180), 1))
        end)
        b:Dock(LEFT) b:DockMargin(1,3,1,3) b:SetWide(step == -0.1 and 28 or 26)
    end

    -- Plus buttons on the right: +5 +1 +0.1 (docked RIGHT so order is reversed)
    local valLbl = vgui.Create("DLabel", row)
    valLbl:SetFont("DermaDefault") valLbl:SetTextColor(COL_TEXT)
    valLbl:Dock(RIGHT) valLbl:DockMargin(0,0,4,0) valLbl:SetWide(50) valLbl:SetContentAlignment(6)

    for _, step in ipairs({5, 1, 0.1}) do
        local txt = step == 0.1 and "+.1" or "+"..tostring(step)
        local b = StyledButton(row, txt, COL_BTN, COL_BTN_HOV, function()
            api.set(math_Round(math_Clamp(getter() + step, -180, 180), 1))
        end)
        b:Dock(RIGHT) b:DockMargin(1,3,1,3) b:SetWide(step == 0.1 and 28 or 26)
    end

    local slider = vgui.Create("DNumSlider", row)
    slider:Dock(FILL) slider:DockMargin(2,2,2,2)
    slider:SetMin(-180) slider:SetMax(180) slider:SetDecimals(1) slider:SetValue(getter())
    if IsValid(slider.Label)    then slider.Label:SetWide(0)    end
    if IsValid(slider.TextArea) then slider.TextArea:SetWide(0) end

    slider.OnValueChanged = function(_, val)
        setter(math_Round(val, 1))
        valLbl:SetText(string_format("%.1f°", val))
    end

    local publicSet = function(val)
        setter(val)
        slider:SetValue(val)
        valLbl:SetText(string_format("%.1f°", val))
    end
    api.set = publicSet
    valLbl:SetText(string_format("%.1f°", getter()))
    return row, publicSet
end

local function BuildMuzzlePanel(parent)
    -- Wrap everything in a scroll panel so all content is reachable
    local scroll = vgui.Create("DScrollPanel", parent)
    scroll:Dock(FILL) scroll:DockMargin(0,0,0,0)

    local inner = scroll  -- all children dock into scroll

    local wepLbl = WeaponBanner(inner)

    -- ── Mode indicator ────────────────────────────────────────────────────
    local modeLbl = vgui.Create("DLabel", inner)
    modeLbl:Dock(TOP) modeLbl:SetTall(18) modeLbl:DockMargin(8,0,8,0)
    modeLbl:SetFont("DermaDefaultBold") modeLbl:SetContentAlignment(4)

    -- Track which mode sliders/buttons target
    local isWM = false

    -- ── Laser controls ────────────────────────────────────────────────────
    Separator(inner)

    local laserRow = vgui.Create("DPanel", inner)
    laserRow:Dock(TOP) laserRow:SetTall(30) laserRow:DockMargin(4,0,4,2) laserRow.Paint = function() end

    local laserBtn, colorSwatch, matCombo

    local function UpdateLaserUI(class)
        if not IsValid(laserBtn) then return end
        local on = laserEnabled[class]
        laserBtn:SetText(on and "  Laser: ON" or "  Laser: OFF")
        local col    = on and COL_LASER_ON  or COL_LASER_OFF
        local colHov = on and COL_LASER_HOV or COL_BTN_HOV
        local hov = false
        laserBtn.Paint           = function(_, w, h) draw.RoundedBox(5, 0, 0, w, h, hov and colHov or col) end
        laserBtn.OnCursorEntered = function() hov = true  end
        laserBtn.OnCursorExited  = function() hov = false end
        if IsValid(colorSwatch) then colorSwatch.currentColor = GetLaserColor(class) end
        if IsValid(matCombo) then matCombo:SetValue(laserMaterials[class] or DEFAULT_LASER_MAT) end
    end

    laserBtn = vgui.Create("DButton", laserRow)
    laserBtn:SetText("  Laser: OFF")
    laserBtn:SetFont("DermaDefaultBold") laserBtn:SetTextColor(COL_TEXT)
    laserBtn:Dock(LEFT) laserBtn:SetWide(148) laserBtn:DockMargin(0,3,6,3)
    laserBtn.DoClick = function()
        local wep = LocalPlayer():GetActiveWeapon()
        if not IsValid(wep) then return end
        local class = wep:GetClass()
        laserEnabled[class] = not laserEnabled[class] or nil
        MuzzleSave()
        UpdateLaserUI(class)
    end

    colorSwatch = vgui.Create("DButton", laserRow)
    colorSwatch:SetText("")
    colorSwatch:Dock(LEFT) colorSwatch:SetWide(26) colorSwatch:DockMargin(0,4,4,4)
    colorSwatch.currentColor = GetLaserColor("")
    colorSwatch.Paint = function(self, w, h)
        draw.RoundedBox(4, 1, 1, w-2, h-2, Color(20,20,20,200))
        draw.RoundedBox(3, 2, 2, w-4, h-4, self.currentColor)
    end
    colorSwatch.DoClick = function()
        local wep = LocalPlayer():GetActiveWeapon()
        if not IsValid(wep) then
            notification.AddLegacy("[MuzzleFix] Equip a weapon first", NOTIFY_ERROR, 3)
            return
        end
        local class = wep:GetClass()
        local existing = laserColors[class] or DEFAULT_LASER

        local pf = vgui.Create("DFrame")
        pf:SetSize(250, 280)
        pf:SetTitle("Laser Colour – "..class)
        pf:MakePopup() pf:Center()
        pf.Paint = function(_, w, h)
            draw.RoundedBox(6, 0, 0, w, h, COL_BG)
            draw.RoundedBox(6, 0, 0, w, 24, COL_HEADER)
        end

        local mixer = vgui.Create("DColorMixer", pf)
        mixer:SetPos(8, 30) mixer:SetSize(234, 190)
        mixer:SetPalette(false) mixer:SetAlphaBar(false)
        mixer:SetColor(Color(existing.r, existing.g, existing.b, 255))

        local presets = {
            {"Red",Color(255,50,50)}, {"Green",Color(50,255,80)}, {"Blue",Color(50,150,255)},
            {"Cyan",Color(0,220,255)}, {"Yellow",Color(255,230,30)}, {"White",Color(255,255,255)},
        }
        local presRow = vgui.Create("DPanel", pf)
        presRow:SetPos(8, 226) presRow:SetSize(234, 22) presRow.Paint = function() end
        for _, pre in ipairs(presets) do
            local sw = vgui.Create("DButton", presRow)
            sw:SetText("") sw:Dock(LEFT) sw:SetWide(34) sw:DockMargin(0,0,3,0)
            local hov = false
            sw.Paint = function(_, w, h)
                local c = pre[2]
                draw.RoundedBox(3, 0, 0, w, h, Color(c.r, c.g, c.b, hov and 255 or 180))
            end
            sw.OnCursorEntered = function() hov = true  end
            sw.OnCursorExited  = function() hov = false end
            sw.DoClick = function() mixer:SetColor(pre[2]) end
        end

        local applyBtn = StyledButton(pf, "Apply", COL_SAVE, COL_SAVE_HOV, function()
            local chosen = mixer:GetColor()
            laserColors[class] = { r = chosen.r, g = chosen.g, b = chosen.b }
            MuzzleSave()
            colorSwatch.currentColor = GetLaserColor(class)
            pf:Close()
        end)
        applyBtn:SetPos(8, 252) applyBtn:SetSize(114, 22)

        local cancelBtn = StyledButton(pf, "Cancel", COL_RESET, COL_RESET_HOV, function() pf:Close() end)
        cancelBtn:SetPos(128, 252) cancelBtn:SetSize(114, 22)
    end

    local laserHint = vgui.Create("DLabel", laserRow)
    laserHint:Dock(FILL) laserHint:DockMargin(2,0,0,0)
    laserHint:SetFont("DermaDefault") laserHint:SetTextColor(COL_DIM)
    laserHint:SetText("Shows muzzle direction in-world")
    laserHint:SetContentAlignment(4)

    -- Material dropdown
    local matRow = vgui.Create("DPanel", inner)
    matRow:Dock(TOP) matRow:SetTall(24) matRow:DockMargin(4,0,4,4) matRow.Paint = function() end

    local matLbl = vgui.Create("DLabel", matRow)
    matLbl:Dock(LEFT) matLbl:SetWide(68) matLbl:DockMargin(4,0,4,0)
    matLbl:SetFont("DermaDefault") matLbl:SetTextColor(COL_DIM)
    matLbl:SetText("Material:") matLbl:SetContentAlignment(4)

    matCombo = vgui.Create("DComboBox", matRow)
    matCombo:Dock(FILL) matCombo:DockMargin(0,2,4,2)
    matCombo:SetFont("DermaDefault") matCombo:SetValue(DEFAULT_LASER_MAT)
    for _, path in ipairs(LASER_MATERIALS) do matCombo:AddChoice(path, path) end
    matCombo.OnSelect = function(_, _, _, data)
        local wep = LocalPlayer():GetActiveWeapon()
        if not IsValid(wep) then return end
        laserMaterials[wep:GetClass()] = data
        MuzzleSave()
    end

    -- ── Angle adjustment ──────────────────────────────────────────────────
    Separator(inner)
    SectionLabel(inner, "  Adjust muzzle angles (applied in real-time):")
    SectionLabel(inner, "  Enable laser to see changes live.")

    local liveP, liveY, liveR = 0, 0, 0
    local setPRow, setYRow, setRRow

    local function syncPreview()
        local off = { p = liveP, y = liveY, r = liveR }
        if isWM then
            wmMuzzlePreview = off; muzzlePreview = nil
        else
            muzzlePreview = off; wmMuzzlePreview = nil
        end
    end

    _, setPRow = AxisRow(inner, "Pitch", function() return liveP end, function(v) liveP = v syncPreview() end)
    _, setYRow = AxisRow(inner, "Yaw",   function() return liveY end, function(v) liveY = v syncPreview() end)
    _, setRRow = AxisRow(inner, "Roll",  function() return liveR end, function(v) liveR = v syncPreview() end)

    Separator(inner)

    local actionRow = vgui.Create("DPanel", inner)
    actionRow:Dock(TOP) actionRow:SetTall(32) actionRow:DockMargin(4,0,4,4) actionRow.Paint = function() end

    local saveBtn = StyledButton(actionRow, "Save", COL_SAVE, COL_SAVE_HOV, function()
        local wep = LocalPlayer():GetActiveWeapon()
        if not IsValid(wep) then notification.AddLegacy("[MuzzleFix] No weapon!", NOTIFY_ERROR, 3) return end
        local class = wep:GetClass()
        local tbl = isWM and wmMuzzleSaved or muzzleSaved
        tbl[class] = { p = liveP, y = liveY, r = liveR }
        MuzzleSave(); muzzlePreview = nil; wmMuzzlePreview = nil
        local tag = isWM and "WM" or "VM"
        notification.AddLegacy("[MuzzleFix] Saved "..tag.." for "..class, NOTIFY_GENERIC, 3)
    end)
    saveBtn:Dock(LEFT) saveBtn:SetWide(80) saveBtn:DockMargin(0,2,4,2)

    local resetBtn = StyledButton(actionRow, "Reset weapon", COL_RESET, COL_RESET_HOV, function()
        local wep = LocalPlayer():GetActiveWeapon()
        if not IsValid(wep) then return end
        local class = wep:GetClass()
        local tbl = isWM and wmMuzzleSaved or muzzleSaved
        tbl[class] = nil; MuzzleSave()
        liveP, liveY, liveR = 0, 0, 0; syncPreview()
        setPRow(0); setYRow(0); setRRow(0)
        notification.AddLegacy("[MuzzleFix] Reset "..class, NOTIFY_GENERIC, 3)
    end)
    resetBtn:Dock(LEFT) resetBtn:SetWide(120) resetBtn:DockMargin(0,2,4,2)

    local zeroBtn = StyledButton(actionRow, "Zero all", COL_BTN, COL_BTN_HOV, function()
        liveP, liveY, liveR = 0, 0, 0; syncPreview()
        setPRow(0); setYRow(0); setRRow(0)
    end)
    zeroBtn:Dock(LEFT) zeroBtn:SetWide(80) zeroBtn:DockMargin(0,2,0,2)

    Separator(inner)
    SectionLabel(inner, "  Saved viewmodel offsets (click to load):")

    local _, rebuildList = WeaponList(inner, muzzleSaved,
        function(_, off)
            liveP, liveY, liveR = off.p or 0, off.y or 0, off.r or 0
            syncPreview(); setPRow(liveP); setYRow(liveY); setRRow(liveR)
        end,
        function(off) return string_format("P:%.1f  Y:%.1f  R:%.1f", off.p or 0, off.y or 0, off.r or 0) end
    )

    Separator(inner)
    SectionLabel(inner, "  Saved world model offsets (click to load):")

    local _, rebuildWMList = WeaponList(inner, wmMuzzleSaved,
        function(_, off)
            liveP, liveY, liveR = off.p or 0, off.y or 0, off.r or 0
            syncPreview(); setPRow(liveP); setYRow(liveY); setRRow(liveR)
        end,
        function(off) return string_format("P:%.1f  Y:%.1f  R:%.1f", off.p or 0, off.y or 0, off.r or 0) end
    )

    local os_, or_ = saveBtn.DoClick, resetBtn.DoClick
    saveBtn.DoClick  = function(s) os_(s); rebuildList(); rebuildWMList() end
    resetBtn.DoClick = function(s) or_(s); rebuildList(); rebuildWMList() end

    local lastClass = ""
    local lastWM = false
    parent.Think = function()
        local wep = LocalPlayer():GetActiveWeapon()
        local class = IsValid(wep) and wep:GetClass() or "None"
        local wm = g_VR.wmActive or false
        if class == lastClass and wm == lastWM then return end
        lastClass = class
        lastWM = wm
        isWM = wm
        wepLbl:SetText(class)
        UpdateLaserUI(class)
        if wm then
            modeLbl:SetText("World Model offsets")
            modeLbl:SetTextColor(COL_WARN)
        else
            modeLbl:SetText("Viewmodel offsets")
            modeLbl:SetTextColor(COL_DIM)
        end
        local tbl = wm and wmMuzzleSaved or muzzleSaved
        local off = tbl[class] or { p=0, y=0, r=0 }
        liveP, liveY, liveR = off.p or 0, off.y or 0, off.r or 0
        syncPreview(); setPRow(liveP); setYRow(liveY); setRRow(liveR)
    end

    parent.OnRemove = function() muzzlePreview = nil; wmMuzzlePreview = nil end
end

-- ============================================================================
-- TAB 2 – GRIP POSITION
-- ============================================================================

local GRIP_FILE     = "vrmod_grip_offsets.json"
local GRIP_LH_FILE  = "vrmod_grip_offsets_lefthand.json"
local gripSaved     = {}
local gripSavedLH   = {}
local gripCurrent   = { pos = Vector(), ang = Angle() }
local gripRepos     = false
local gripFrozenPos, gripFrozenAng = nil, nil
local gripUnsaved   = false
local gripListeners = {}
local gripIsLH      = false

vrmod_gripfix = vrmod_gripfix or {}
vrmod_gripfix.lhOffsets = gripSavedLH
vrmod_gripfix.lhLive    = nil

local function GripStatus(msg)
    for _, fn in ipairs(gripListeners) do pcall(fn, msg) end
end

local function GripLoad()
    local raw = file.Read(GRIP_FILE, "DATA")
    if raw then
        for class, e in pairs(util.JSONToTable(raw) or {}) do
            gripSaved[class] = {
                pos = Vector(e.px or 0, e.py or 0, e.pz or 0),
                ang = Angle (e.ap or 0, e.ay or 0, e.ar or 0),
            }
        end
    end
    local rawLH = file.Read(GRIP_LH_FILE, "DATA")
    if rawLH then
        for class, e in pairs(util.JSONToTable(rawLH) or {}) do
            gripSavedLH[class] = {
                pos = Vector(e.px or 0, e.py or 0, e.pz or 0),
                ang = Angle (e.ap or 0, e.ay or 0, e.ar or 0),
            }
        end
    end
end
local function GripSaveFile()
    local out = {}
    for class, e in pairs(gripSaved) do
        out[class] = { px=e.pos.x, py=e.pos.y, pz=e.pos.z, ap=e.ang.p, ay=e.ang.y, ar=e.ang.r }
    end
    file.Write(GRIP_FILE, util.TableToJSON(out, true))
    local outLH = {}
    for class, e in pairs(gripSavedLH) do
        outLH[class] = { px=e.pos.x, py=e.pos.y, pz=e.pos.z, ap=e.ang.p, ay=e.ang.y, ar=e.ang.r }
    end
    file.Write(GRIP_LH_FILE, util.TableToJSON(outLH, true))
end
GripLoad()

local function GetHandPose(forceLeft)
    if not g_VR or not g_VR.tracking then return nil, nil end
    local p = (forceLeft or gripIsLH) and g_VR.tracking.pose_lefthand or g_VR.tracking.pose_righthand
    return p and p.pos, p and p.ang
end
local function GetVMI() return g_VR and g_VR.currentvmi end

hook.Add("Think", "vrmod_gripoffset_apply", function()
    if not g_VR or not g_VR.active then return end
    if gripIsLH then
        if gripRepos and gripFrozenPos then
            local hp, ha = GetHandPose(); if not hp then return end
            local op, oa = WorldToLocal(gripFrozenPos, gripFrozenAng, hp, ha)
            vrmod_gripfix.lhLive = { pos = op, ang = oa }
        end
        return
    end
    local vmi = GetVMI(); if not vmi then return end
    local hp, ha = GetHandPose(); if not hp then return end
    if gripRepos and gripFrozenPos then
        local op, oa = WorldToLocal(gripFrozenPos, gripFrozenAng, hp, ha)
        vmi.offsetPos = op; vmi.offsetAng = oa
        return
    end
    local c = gripCurrent
    if c.pos:LengthSqr() == 0 and c.ang.p == 0 and c.ang.y == 0 and c.ang.r == 0 then return end
    vmi.offsetPos = c.pos; vmi.offsetAng = c.ang
end)

hook.Add("VRMod_Input", "vrmod_gripoffset_grab", function(action, pressed)
    if not gripRepos then return end
    if action ~= (gripIsLH and "boolean_left_pickup" or "boolean_right_pickup") then return end
    if not pressed then return true end
    local hp, ha = GetHandPose(); if not hp then return end
    local np, na = WorldToLocal(gripFrozenPos, gripFrozenAng, hp, ha)
    gripCurrent.pos = np; gripCurrent.ang = na
    if gripIsLH then
        vrmod_gripfix.lhLive = { pos = np, ang = na }
    else
        local vmi = GetVMI()
        if vmi then vmi.offsetPos = np; vmi.offsetAng = na end
    end
    gripRepos = false; gripFrozenPos = nil; gripFrozenAng = nil
    vrmod_gripfix.repos = nil; vrmod_gripfix.suppressDrop = true; timer.Simple(0.5, function() vrmod_gripfix.suppressDrop = false end)
    gripUnsaved = true
    GripStatus("Grip set! Press Save to keep it.")
    notification.AddLegacy("[GripOffset] Grip repositioned — press Save.", NOTIFY_GENERIC, 4)
    return true
end)

hook.Add("VRMod_AllowDefaultAction", "vrmod_gripoffset_blockdefault", function(action)
    if (gripRepos or vrmod_gripfix.suppressDrop) and (action == "boolean_left_pickup" or action == "boolean_right_pickup") then return false end
end)

local lastGripClass = ""
hook.Add("Think", "vrmod_gripoffset_wepchange", function()
    local wep = LocalPlayer():GetActiveWeapon()
    local class = IsValid(wep) and wep:GetClass() or ""
    if class == lastGripClass then return end
    lastGripClass = class
    if gripRepos then
        gripRepos = false; gripFrozenPos = nil; gripFrozenAng = nil; vrmod_gripfix.repos = nil
        gripIsLH = false; vrmod_gripfix.lhLive = nil
        GripStatus("Cancelled (weapon changed).")
    end
    gripUnsaved = false
    local saved = gripSaved[class]
    if saved then gripCurrent.pos = saved.pos; gripCurrent.ang = saved.ang
    else gripCurrent.pos = Vector(); gripCurrent.ang = Angle() end
end)

hook.Add("VRMod_Exit", "vrmod_gripoffset_exit", function(ply)
    if ply ~= LocalPlayer() then return end
    gripRepos = false; gripFrozenPos = nil; gripFrozenAng = nil; vrmod_gripfix.repos = nil
    gripIsLH = false; vrmod_gripfix.lhLive = nil
end)

local function GripStart()
    if not g_VR or not g_VR.active then GripStatus("VR not active.") return end
    local vmi = GetVMI(); if not vmi then GripStatus("No weapon VMI.") return end
    gripIsLH = false or false
    local hp, ha = GetHandPose(); if not hp then GripStatus("No hand tracking.") return end

    if gripIsLH then
        local wep = LocalPlayer():GetActiveWeapon()
        local class = IsValid(wep) and wep:GetClass() or ""
        local lhGrip = gripSavedLH[class]
        if lhGrip then
            gripFrozenPos, gripFrozenAng = LocalToWorld(lhGrip.pos, lhGrip.ang, hp, ha)
        else
            local gp, ga = LocalToWorld(vmi.offsetPos, vmi.offsetAng, hp, ha)
            gripFrozenPos, gripFrozenAng = LocalToWorld(Vector(0, -2.5, 0), Angle(0, 0, -5), gp, ga)
        end
    else
        gripFrozenPos, gripFrozenAng = LocalToWorld(vmi.offsetPos, vmi.offsetAng, hp, ha)
    end

    gripRepos = true; vrmod_gripfix.repos = true
    local hand = gripIsLH and "left" or "right"
    GripStatus("Gun frozen. Move "..hand.." hand to it, then grab.")
    notification.AddLegacy("[GripOffset] Gun frozen — move "..hand.." hand and grab.", NOTIFY_GENERIC, 5)
end

local function GripCancel()
    gripRepos = false; gripFrozenPos = nil; gripFrozenAng = nil; vrmod_gripfix.repos = nil
    if gripIsLH then
        vrmod_gripfix.lhLive = nil
    else
        local vmi = GetVMI()
        if vmi then vmi.offsetPos = gripCurrent.pos; vmi.offsetAng = gripCurrent.ang end
    end
    gripIsLH = false
    GripStatus("Cancelled.")
end

local function GripSaveCurrent()
    local wep = LocalPlayer():GetActiveWeapon()
    if not IsValid(wep) then GripStatus("No weapon equipped.") return false end
    local class = wep:GetClass()
    if gripIsLH or false then
        gripSavedLH[class] = { pos = Vector(gripCurrent.pos), ang = Angle(gripCurrent.ang) }
        vrmod_gripfix.lhLive = nil
        gripIsLH = false
    else
        gripSaved[class] = { pos = Vector(gripCurrent.pos), ang = Angle(gripCurrent.ang) }
    end
    GripSaveFile(); gripUnsaved = false
    GripStatus("Saved for "..class)
    return true
end

local function GripReset()
    local wep = LocalPlayer():GetActiveWeapon(); if not IsValid(wep) then return end
    local class = wep:GetClass()
    if false then
        gripSavedLH[class] = nil; vrmod_gripfix.lhLive = nil
    else
        gripSaved[class] = nil
    end
    GripSaveFile()
    gripCurrent.pos = Vector(); gripCurrent.ang = Angle()
    if not false then
        local vmi = GetVMI()
        if vmi then vmi.offsetPos = Vector(); vmi.offsetAng = Angle() end
    end
    gripUnsaved = false; GripStatus("Reset for "..class)
end

local function BuildGripPanel(parent)
    local statusLbl
    local idx = #gripListeners + 1
    gripListeners[idx] = function(msg) if IsValid(statusLbl) then statusLbl:SetText(msg) end end
    parent.OnRemove = function()
        gripListeners[idx] = nil
        if gripRepos then GripCancel() end
    end

    local wepLbl = WeaponBanner(parent)

    local statPanel = vgui.Create("DPanel", parent)
    statPanel:Dock(TOP) statPanel:SetTall(26) statPanel:DockMargin(4,0,4,4)
    statPanel.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, Color(35,35,42,220)) end
    statusLbl = vgui.Create("DLabel", statPanel)
    statusLbl:Dock(FILL) statusLbl:DockMargin(8,0,8,0)
    statusLbl:SetFont("DermaDefault") statusLbl:SetTextColor(COL_DIM)
    statusLbl:SetText("Ready.") statusLbl:SetContentAlignment(4)

    -- Visual foregrip only toggle (requires foregrip addon)
    local fgBtn, lastFGClass, UpdateFGBtn
    if vrmod_foregrip and vrmod_foregrip.SetVisualOnly then
        local fgRow = vgui.Create("DPanel", parent)
        fgRow:Dock(TOP) fgRow:SetTall(32) fgRow:DockMargin(4,2,4,0) fgRow.Paint = function() end

        UpdateFGBtn = function(class)
            if not IsValid(fgBtn) then return end
            local vo = vrmod_foregrip.visualOnly
            local on = vo and vo[class]
            fgBtn:SetText(on and "  Foregrip: Visual Only" or "  Foregrip: Two-Hand Aim")
            local col    = on and COL_LASER_ON  or COL_LASER_OFF
            local colHov = on and COL_LASER_HOV or COL_BTN_HOV
            local hov = false
            fgBtn.Paint           = function(_, w, h) draw.RoundedBox(5, 0, 0, w, h, hov and colHov or col) end
            fgBtn.OnCursorEntered = function() hov = true  end
            fgBtn.OnCursorExited  = function() hov = false end
        end

        fgBtn = vgui.Create("DButton", fgRow)
        fgBtn:SetFont("DermaDefaultBold") fgBtn:SetTextColor(COL_TEXT)
        fgBtn:Dock(LEFT) fgBtn:SetWide(210) fgBtn:DockMargin(0,3,6,3)
        fgBtn.DoClick = function()
            local wep = LocalPlayer():GetActiveWeapon()
            if not IsValid(wep) then return end
            local c = wep:GetClass()
            local vo = vrmod_foregrip.visualOnly
            vrmod_foregrip.SetVisualOnly(c, not vo[c])
            UpdateFGBtn(c)
        end

        local fgLbl = vgui.Create("DLabel", fgRow)
        fgLbl:Dock(FILL) fgLbl:DockMargin(0,0,0,0)
        fgLbl:SetFont("DermaDefault") fgLbl:SetTextColor(COL_DIM)
        fgLbl:SetText("Pin hand without rotating weapon")

        lastFGClass = ""
        local wep = LocalPlayer():GetActiveWeapon()
        UpdateFGBtn(IsValid(wep) and wep:GetClass() or "")
    end

    -- Foregrip grab-zone shape + scale (requires foregrip addon)
    if vrmod_foregrip then
        local zoneRow = vgui.Create("DPanel", parent)
        zoneRow:Dock(TOP) zoneRow:SetTall(32) zoneRow:DockMargin(4,2,4,0) zoneRow.Paint = function() end

        local zoneBtn
        local function UpdateZoneBtn()
            if not IsValid(zoneBtn) then return end
            local on = GetConVar("vrmod_foregrip_sphere"):GetBool()
            zoneBtn:SetText(on and "  Grab Zone: Sphere" or "  Grab Zone: Box")
            local col    = on and COL_LASER_ON  or COL_LASER_OFF
            local colHov = on and COL_LASER_HOV or COL_BTN_HOV
            local hov = false
            zoneBtn.Paint           = function(_, w, h) draw.RoundedBox(5, 0, 0, w, h, hov and colHov or col) end
            zoneBtn.OnCursorEntered = function() hov = true  end
            zoneBtn.OnCursorExited  = function() hov = false end
        end
        zoneBtn = vgui.Create("DButton", zoneRow)
        zoneBtn:SetFont("DermaDefaultBold") zoneBtn:SetTextColor(COL_TEXT)
        zoneBtn:Dock(LEFT) zoneBtn:SetWide(210) zoneBtn:DockMargin(0,3,6,3)
        zoneBtn.DoClick = function()
            RunConsoleCommand("vrmod_foregrip_sphere", GetConVar("vrmod_foregrip_sphere"):GetBool() and "0" or "1")
            timer.Simple(0, UpdateZoneBtn)
        end
        UpdateZoneBtn()

        local zoneLbl = vgui.Create("DLabel", zoneRow)
        zoneLbl:Dock(FILL)
        zoneLbl:SetFont("DermaDefault") zoneLbl:SetTextColor(COL_DIM)
        zoneLbl:SetText("Box = directional, Sphere = radial")

        local scaleSlider = vgui.Create("DNumSlider", parent)
        scaleSlider:Dock(TOP) scaleSlider:DockMargin(8,2,8,0) scaleSlider:SetTall(28)
        scaleSlider:SetText("Sphere Scale")
        scaleSlider:SetMin(0.25) scaleSlider:SetMax(4) scaleSlider:SetDecimals(2)
        scaleSlider:SetConVar("vrmod_foregrip_scale")
        if IsValid(scaleSlider.Label) then scaleSlider.Label:SetTextColor(COL_DIM) end
    end

    Separator(parent)

    local handModeLbl = vgui.Create("DLabel", parent)
    handModeLbl:Dock(TOP) handModeLbl:SetTall(18) handModeLbl:DockMargin(8,2,8,0)
    handModeLbl:SetFont("DermaDefaultBold") handModeLbl:SetContentAlignment(4)

    local instrPanel = vgui.Create("DPanel", parent)
    instrPanel:Dock(TOP) instrPanel:SetTall(72) instrPanel:DockMargin(4,2,4,4)
    instrPanel.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, COL_ROW) end
    for i, line in ipairs({
        "1.  Press  Start Reposition",
        "2.  Gun freezes in world space",
        "3.  Move your weapon hand to where the gun is",
        "4.  Grab  (weapon hand grip)",
        "5.  Gun snaps to your new grip point",
    }) do
        local l = vgui.Create("DLabel", instrPanel)
        l:SetPos(10,(i-1)*13+3) l:SetSize(420,14)
        l:SetFont("DermaDefault") l:SetText(line)
        l:SetTextColor(i == 1 and COL_ACCENT or COL_DIM)
    end

    Separator(parent)

    local ctrlRow = vgui.Create("DPanel", parent)
    ctrlRow:Dock(TOP) ctrlRow:SetTall(38) ctrlRow:DockMargin(4,4,4,0) ctrlRow.Paint = function() end
    local startBtn  = StyledButton(ctrlRow, "Start Reposition", COL_START,  COL_START_HOV,  GripStart)
    local cancelBtn = StyledButton(ctrlRow, "Cancel",           COL_CANCEL, COL_CANCEL_HOV, GripCancel)
    startBtn:Dock(LEFT)  startBtn:SetWide(180)  startBtn:DockMargin(0,3,6,3)
    cancelBtn:Dock(LEFT) cancelBtn:SetWide(100) cancelBtn:DockMargin(0,3,0,3)

    local activePanel = vgui.Create("DPanel", parent)
    activePanel:Dock(TOP) activePanel:SetTall(26) activePanel:DockMargin(4,2,4,2)
    activePanel.Paint = function(_, w, h)
        if not gripRepos then return end
        draw.RoundedBox(5, 0, 0, w, h, COL_MARKER_BG)
        draw.SimpleText("REPOSITIONING — move hand to gun, then grab",
            "DermaDefaultBold", w*0.5, h*0.5, COL_ACTIVE, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    Separator(parent)

    local saveRow = vgui.Create("DPanel", parent)
    saveRow:Dock(TOP) saveRow:SetTall(38) saveRow:DockMargin(4,4,4,0) saveRow.Paint = function() end

    local saveBtn = StyledButton(saveRow, "Save for this weapon", COL_SAVE, COL_SAVE_HOV, function()
        if GripSaveCurrent() then
            notification.AddLegacy("[GripOffset] Saved!", NOTIFY_GENERIC, 3)
        end
    end)
    saveBtn:Dock(LEFT) saveBtn:SetWide(190) saveBtn:DockMargin(0,3,6,3)

    local resetBtn = StyledButton(saveRow, "Reset weapon", COL_RESET, COL_RESET_HOV, function()
        GripReset()
        notification.AddLegacy("[GripOffset] Reset.", NOTIFY_GENERIC, 3)
    end)
    resetBtn:Dock(LEFT) resetBtn:SetWide(130) resetBtn:DockMargin(0,3,0,3)

    local unsavedLbl = vgui.Create("DLabel", parent)
    unsavedLbl:Dock(TOP) unsavedLbl:SetTall(16) unsavedLbl:DockMargin(8,0,8,2)
    unsavedLbl:SetFont("DermaDefault") unsavedLbl:SetTextColor(COL_WARN) unsavedLbl:SetText("")

    Separator(parent)
    SectionLabel(parent, "  Saved weapons — Right Hand (click to load):")

    local _, rebuildFn = WeaponList(parent, gripSaved,
        function(_, entry)
            gripCurrent.pos = entry.pos; gripCurrent.ang = entry.ang
            local vmi = GetVMI()
            if vmi then vmi.offsetPos = entry.pos; vmi.offsetAng = entry.ang end
            GripStatus("Loaded.")
        end,
        function(entry) return string_format("X:%.1f Y:%.1f Z:%.1f", entry.pos.x, entry.pos.y, entry.pos.z) end
    )

    Separator(parent)
    SectionLabel(parent, "  Saved weapons — Left Hand (click to load):")

    local _, rebuildLHFn = WeaponList(parent, gripSavedLH,
        function(_, entry)
            gripCurrent.pos = entry.pos; gripCurrent.ang = entry.ang
            vrmod_gripfix.lhLive = { pos = entry.pos, ang = entry.ang }
            GripStatus("Loaded (left hand).")
        end,
        function(entry) return string_format("X:%.1f Y:%.1f Z:%.1f", entry.pos.x, entry.pos.y, entry.pos.z) end
    )

    local os_, or_ = saveBtn.DoClick, resetBtn.DoClick
    saveBtn.DoClick  = function(s) os_(s); rebuildFn(); rebuildLHFn() end
    resetBtn.DoClick = function(s) or_(s); rebuildFn(); rebuildLHFn() end

    local lastClass = ""
    parent.Think = function()
        local wep = LocalPlayer():GetActiveWeapon()
        local class = IsValid(wep) and wep:GetClass() or "None"
        if class ~= lastClass then
            lastClass = class; wepLbl:SetText(class)
            if fgBtn and class ~= lastFGClass then lastFGClass = class; UpdateFGBtn(class) end
        end
        unsavedLbl:SetText(gripUnsaved and "● Unsaved changes" or "")
        local isLH = false or false
        local hasLH = gripSavedLH[lastClass] ~= nil
        if isLH then
            handModeLbl:SetText(hasLH and "Left-Hand Mode (saved offset exists)" or "Left-Hand Mode (no offset — will use default)")
            handModeLbl:SetTextColor(hasLH and COL_ACTIVE or COL_WARN)
        else
            handModeLbl:SetText("Right-Hand Mode")
            handModeLbl:SetTextColor(COL_DIM)
        end
    end
end

-- ============================================================================
-- TAB 3 – ANIMATION DISABLER
-- ============================================================================

local ANIM_FILE    = "weapon_anim_disabled.txt"
local animDisabled = {}

local function AnimLoad()
    local raw = file.Read(ANIM_FILE, "DATA")
    if raw then animDisabled = util.JSONToTable(raw) or {} end
end
local function AnimSave()
    file.Write(ANIM_FILE, util.TableToJSON(animDisabled))
end
AnimLoad()

hook.Add("PreDrawViewModel", "vrmod_weaponfix_animdisable", function(vm, _, wep)
    if not IsValid(vm) or not IsValid(wep) then return end
    if animDisabled[wep:GetClass()] then
        vm:SetCycle(0)
        vm:SetPlaybackRate(0)
    end
end)

local function BuildAnimPanel(parent)
    local wepLbl = WeaponBanner(parent)

    local btnRow = vgui.Create("DPanel", parent)
    btnRow:Dock(TOP) btnRow:SetTall(34) btnRow:DockMargin(4,4,4,4) btnRow.Paint = function() end

    local toggleBtn, listScroll
    local function UpdateToggleBtn(class)
        if not IsValid(toggleBtn) then return end
        local off = animDisabled[class]
        toggleBtn:SetText(off and "Animations: DISABLED" or "Animations: Enabled")
        local col    = off and COL_LASER_ON  or Color(40,80,40,220)
        local colHov = off and COL_LASER_HOV or Color(50,110,50,220)
        local hov = false
        toggleBtn.Paint           = function(_, w, h) draw.RoundedBox(5, 0, 0, w, h, hov and colHov or col) end
        toggleBtn.OnCursorEntered = function() hov = true  end
        toggleBtn.OnCursorExited  = function() hov = false end
    end

    toggleBtn = vgui.Create("DButton", btnRow)
    toggleBtn:SetFont("DermaDefaultBold") toggleBtn:SetTextColor(COL_TEXT)
    toggleBtn:Dock(LEFT) toggleBtn:SetWide(220) toggleBtn:DockMargin(0,2,6,2)
    toggleBtn.DoClick = function()
        local wep = LocalPlayer():GetActiveWeapon()
        if not IsValid(wep) then
            notification.AddLegacy("[AnimFix] No weapon equipped!", NOTIFY_ERROR, 3) return
        end
        local class = wep:GetClass()
        animDisabled[class] = not animDisabled[class] or nil
        AnimSave()
        UpdateToggleBtn(class)
        RebuildAnimList(listScroll)
    end

    local clearBtn = StyledButton(btnRow, "Enable All", COL_RESET, COL_RESET_HOV, function()
        animDisabled = {}; AnimSave()
        local wep = LocalPlayer():GetActiveWeapon()
        UpdateToggleBtn(IsValid(wep) and wep:GetClass() or "")
        RebuildAnimList(listScroll)
        notification.AddLegacy("[AnimFix] All animations re-enabled", NOTIFY_GENERIC, 3)
    end)
    clearBtn:Dock(LEFT) clearBtn:SetWide(110) clearBtn:DockMargin(0,2,0,2)

    Separator(parent)
    SectionLabel(parent, "  Weapons with animations disabled:")

    listScroll = vgui.Create("DScrollPanel", parent)
    listScroll:Dock(FILL) listScroll:DockMargin(4,2,4,4)
    listScroll.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, Color(18,18,18,180)) end

    function RebuildAnimList(scroll)
        scroll:Clear()
        local sorted = {}
        for class in SortedPairs(animDisabled) do
            if animDisabled[class] then sorted[#sorted+1] = class end
        end
        if #sorted == 0 then
            local lbl = vgui.Create("DLabel", scroll)
            lbl:Dock(TOP) lbl:SetTall(28) lbl:DockMargin(0,6,0,0)
            lbl:SetFont("DermaDefault") lbl:SetTextColor(COL_DIM)
            lbl:SetText("  No weapons have animations disabled")
            lbl:SetContentAlignment(4)
            return
        end
        for _, class in ipairs(sorted) do
            local row = vgui.Create("DPanel", scroll)
            row:Dock(TOP) row:SetTall(26) row:DockMargin(2,2,2,0)
            row.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, COL_ROW) end

            local lbl = vgui.Create("DLabel", row)
            lbl:Dock(FILL) lbl:DockMargin(8,0,0,0)
            lbl:SetFont("DermaDefault") lbl:SetTextColor(COL_TEXT)
            lbl:SetText(class) lbl:SetContentAlignment(4)

            local re = StyledButton(row, "Re-enable", Color(50,80,50,220), Color(60,110,60,220), function()
                animDisabled[class] = nil; AnimSave()
                local wep = LocalPlayer():GetActiveWeapon()
                UpdateToggleBtn(IsValid(wep) and wep:GetClass() or "")
                RebuildAnimList(scroll)
            end)
            re:Dock(RIGHT) re:SetWide(80) re:DockMargin(0,3,4,3)
        end
    end

    RebuildAnimList(listScroll)

    local lastClass = ""
    parent.Think = function()
        local wep = LocalPlayer():GetActiveWeapon()
        local class = IsValid(wep) and wep:GetClass() or "None"
        if class == lastClass then return end
        lastClass = class
        wepLbl:SetText(class)
        UpdateToggleBtn(class)
    end
end

-- ============================================================================
-- TAB 4 – PER-WEAPON WORLD MODELS
-- ============================================================================

local WM_FILE = "vrmod_worldmodel_weapons.json"
g_VR = g_VR or {}
g_VR.wmWeapons = g_VR.wmWeapons or {}
g_VR.wmForced  = g_VR.wmForced or {}   -- class -> true: always worldmodel, set by code (e.g. wm_base), not user-toggleable
g_VR.wmActive = g_VR.wmActive or false

local function WMLoad()
    local raw = file.Read(WM_FILE, "DATA")
    if raw then
        for class, v in pairs(util.JSONToTable(raw) or {}) do
            if v then g_VR.wmWeapons[class] = true end
        end
    end
end
local function WMSave() file.Write(WM_FILE, util.TableToJSON(g_VR.wmWeapons, true)) end
WMLoad()

-- Immediately apply WM/VM switch for the current weapon without waiting
-- for a weapon-switch net message.  Switching TO viewmodel mode may leave
-- finger angles zeroed until the next full weapon swap.
local function WMApplyNow()
    if not g_VR or not g_VR.active then return end
    local ply = LocalPlayer()
    local wep = ply:GetActiveWeapon()
    if not IsValid(wep) then return end
    local class = wep:GetClass()
    if g_VR.wmWeapons[class] or g_VR.wmForced[class] or wep.IsWMBase then
        g_VR.wmActive = true
        g_VR.viewModel = wep
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
    local ply = LocalPlayer()
    local wep = IsValid(ply) and ply:GetActiveWeapon()
    if IsValid(wep) and wep:GetClass() == class then WMApplyNow() end
end

hook.Add("VRMod_Exit", "vrmod_wm_exit", function(ply)
    if ply ~= LocalPlayer() then return end
    g_VR.wmActive = false
end)

local function BuildWorldModelPanel(parent)
    local wepLbl = WeaponBanner(parent)

    SectionLabel(parent, "  Force world model rendering per weapon (no VR restart needed)")

    local btnRow = vgui.Create("DPanel", parent)
    btnRow:Dock(TOP) btnRow:SetTall(34) btnRow:DockMargin(4,4,4,4) btnRow.Paint = function() end

    local toggleBtn, listScroll

    local function UpdateToggleBtn(class)
        if not IsValid(toggleBtn) then return end
        local on = g_VR.wmWeapons[class]
        toggleBtn:SetText(on and "  World Model: ON" or "  World Model: OFF")
        local col    = on and COL_LASER_ON  or COL_LASER_OFF
        local colHov = on and COL_LASER_HOV or COL_BTN_HOV
        local hov = false
        toggleBtn.Paint           = function(_, w, h) draw.RoundedBox(5, 0, 0, w, h, hov and colHov or col) end
        toggleBtn.OnCursorEntered = function() hov = true  end
        toggleBtn.OnCursorExited  = function() hov = false end
    end

    local function RebuildWMList(scroll)
        scroll:Clear()
        local sorted = {}
        for class in SortedPairs(g_VR.wmWeapons) do
            if g_VR.wmWeapons[class] then sorted[#sorted+1] = class end
        end
        if #sorted == 0 then
            local lbl = vgui.Create("DLabel", scroll)
            lbl:Dock(TOP) lbl:SetTall(28) lbl:DockMargin(0,6,0,0)
            lbl:SetFont("DermaDefault") lbl:SetTextColor(COL_DIM)
            lbl:SetText("  No per-weapon world model overrides") lbl:SetContentAlignment(4)
            return
        end
        for _, class in ipairs(sorted) do
            local row = vgui.Create("DPanel", scroll)
            row:Dock(TOP) row:SetTall(26) row:DockMargin(2,2,2,0)
            row.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, COL_ROW) end
            local lbl = vgui.Create("DLabel", row)
            lbl:Dock(FILL) lbl:DockMargin(8,0,0,0)
            lbl:SetFont("DermaDefault") lbl:SetTextColor(COL_TEXT)
            lbl:SetText(class) lbl:SetContentAlignment(4)
            local re = StyledButton(row, "Use Viewmodel", Color(50,80,50,220), Color(60,110,60,220), function()
                g_VR.wmWeapons[class] = nil; WMSave(); WMApplyNow()
                UpdateToggleBtn(IsValid(LocalPlayer():GetActiveWeapon()) and LocalPlayer():GetActiveWeapon():GetClass() or "")
                RebuildWMList(scroll)
            end)
            re:Dock(RIGHT) re:SetWide(110) re:DockMargin(0,3,4,3)
        end
    end

    toggleBtn = vgui.Create("DButton", btnRow)
    toggleBtn:SetFont("DermaDefaultBold") toggleBtn:SetTextColor(COL_TEXT)
    toggleBtn:Dock(LEFT) toggleBtn:SetWide(220) toggleBtn:DockMargin(0,2,6,2)
    toggleBtn.DoClick = function()
        local wep = LocalPlayer():GetActiveWeapon()
        if not IsValid(wep) then
            notification.AddLegacy("[WorldModel] No weapon equipped!", NOTIFY_ERROR, 3) return
        end
        local class = wep:GetClass()
        g_VR.wmWeapons[class] = not g_VR.wmWeapons[class] or nil
        WMSave(); WMApplyNow()
        UpdateToggleBtn(class)
        RebuildWMList(listScroll)
        notification.AddLegacy("[WorldModel] "..class..": "..(g_VR.wmWeapons[class] and "WORLD MODEL" or "viewmodel"), NOTIFY_GENERIC, 3)
    end

    local clearBtn = StyledButton(btnRow, "Clear All", COL_RESET, COL_RESET_HOV, function()
        table.Empty(g_VR.wmWeapons); WMSave(); WMApplyNow()
        UpdateToggleBtn(IsValid(LocalPlayer():GetActiveWeapon()) and LocalPlayer():GetActiveWeapon():GetClass() or "")
        RebuildWMList(listScroll)
        notification.AddLegacy("[WorldModel] All overrides cleared", NOTIFY_GENERIC, 3)
    end)
    clearBtn:Dock(LEFT) clearBtn:SetWide(110) clearBtn:DockMargin(0,2,0,2)

    Separator(parent)
    SectionLabel(parent, "  Weapons using world model:")

    listScroll = vgui.Create("DScrollPanel", parent)
    listScroll:Dock(FILL) listScroll:DockMargin(4,2,4,4)
    listScroll.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, Color(18,18,18,180)) end
    RebuildWMList(listScroll)

    local lastClass = ""
    parent.Think = function()
        local wep = LocalPlayer():GetActiveWeapon()
        local class = IsValid(wep) and wep:GetClass() or "None"
        if class == lastClass then return end
        lastClass = class
        wepLbl:SetText(class)
        UpdateToggleBtn(class)
    end
end

-- ============================================================================
-- TAB 5 – ATTACK DISABLER
-- ============================================================================

local ATKBLOCK_FILE = "vrmod_attack_disabled.json"
local atkDisabled   = {}

local function AtkLoad()
    local raw = file.Read(ATKBLOCK_FILE, "DATA")
    if raw then atkDisabled = util.JSONToTable(raw) or {} end
end
local function AtkSave() file.Write(ATKBLOCK_FILE, util.TableToJSON(atkDisabled)) end
AtkLoad()

-- Strip IN_ATTACK + IN_ATTACK2 for blocked weapons
hook.Add("CreateMove", "vrmod_weaponfix_atkblock", function(cmd)
    if not g_VR or not g_VR.active then return end
    local wep = LocalPlayer():GetActiveWeapon()
    if not IsValid(wep) or not atkDisabled[wep:GetClass()] then return end
    cmd:SetButtons(bit_band(cmd:GetButtons(), bit_bnot(IN_ATTACK + IN_ATTACK2)))
end)

local function BuildAtkBlockPanel(parent)
    local wepLbl = WeaponBanner(parent)
    SectionLabel(parent, "  Block built-in attack for melee weapons (VR motion melee still works)")

    local btnRow = vgui.Create("DPanel", parent)
    btnRow:Dock(TOP) btnRow:SetTall(34) btnRow:DockMargin(4,4,4,4) btnRow.Paint = function() end

    local toggleBtn, listScroll

    local function UpdateToggleBtn(class)
        if not IsValid(toggleBtn) then return end
        local off = atkDisabled[class]
        toggleBtn:SetText(off and "  Attack: BLOCKED" or "  Attack: Enabled")
        local col    = off and COL_RESET     or Color(40,80,40,220)
        local colHov = off and COL_RESET_HOV or Color(50,110,50,220)
        local hov = false
        toggleBtn.Paint           = function(_, w, h) draw.RoundedBox(5, 0, 0, w, h, hov and colHov or col) end
        toggleBtn.OnCursorEntered = function() hov = true  end
        toggleBtn.OnCursorExited  = function() hov = false end
    end

    local function RebuildAtkList(scroll)
        scroll:Clear()
        local sorted = {}
        for class in SortedPairs(atkDisabled) do
            if atkDisabled[class] then sorted[#sorted+1] = class end
        end
        if #sorted == 0 then
            local lbl = vgui.Create("DLabel", scroll)
            lbl:Dock(TOP) lbl:SetTall(28) lbl:DockMargin(0,6,0,0)
            lbl:SetFont("DermaDefault") lbl:SetTextColor(COL_DIM)
            lbl:SetText("  No weapons have attacks blocked") lbl:SetContentAlignment(4)
            return
        end
        for _, class in ipairs(sorted) do
            local row = vgui.Create("DPanel", scroll)
            row:Dock(TOP) row:SetTall(26) row:DockMargin(2,2,2,0)
            row.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, COL_ROW) end
            local lbl = vgui.Create("DLabel", row)
            lbl:Dock(FILL) lbl:DockMargin(8,0,0,0)
            lbl:SetFont("DermaDefault") lbl:SetTextColor(COL_TEXT)
            lbl:SetText(class) lbl:SetContentAlignment(4)
            local re = StyledButton(row, "Unblock", Color(50,80,50,220), Color(60,110,60,220), function()
                atkDisabled[class] = nil; AtkSave()
                local wep = LocalPlayer():GetActiveWeapon()
                UpdateToggleBtn(IsValid(wep) and wep:GetClass() or "")
                RebuildAtkList(scroll)
            end)
            re:Dock(RIGHT) re:SetWide(80) re:DockMargin(0,3,4,3)
        end
    end

    toggleBtn = vgui.Create("DButton", btnRow)
    toggleBtn:SetFont("DermaDefaultBold") toggleBtn:SetTextColor(COL_TEXT)
    toggleBtn:Dock(LEFT) toggleBtn:SetWide(220) toggleBtn:DockMargin(0,2,6,2)
    toggleBtn.DoClick = function()
        local wep = LocalPlayer():GetActiveWeapon()
        if not IsValid(wep) then notification.AddLegacy("[AtkBlock] No weapon equipped!", NOTIFY_ERROR, 3) return end
        local class = wep:GetClass()
        atkDisabled[class] = not atkDisabled[class] or nil
        AtkSave(); UpdateToggleBtn(class); RebuildAtkList(listScroll)
    end

    local clearBtn = StyledButton(btnRow, "Unblock All", COL_RESET, COL_RESET_HOV, function()
        atkDisabled = {}; AtkSave()
        local wep = LocalPlayer():GetActiveWeapon()
        UpdateToggleBtn(IsValid(wep) and wep:GetClass() or "")
        RebuildAtkList(listScroll)
        notification.AddLegacy("[AtkBlock] All attacks unblocked", NOTIFY_GENERIC, 3)
    end)
    clearBtn:Dock(LEFT) clearBtn:SetWide(110) clearBtn:DockMargin(0,2,0,2)

    Separator(parent)
    SectionLabel(parent, "  Weapons with attacks blocked:")

    listScroll = vgui.Create("DScrollPanel", parent)
    listScroll:Dock(FILL) listScroll:DockMargin(4,2,4,4)
    listScroll.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, Color(18,18,18,180)) end
    RebuildAtkList(listScroll)

    local lastClass = ""
    parent.Think = function()
        local wep = LocalPlayer():GetActiveWeapon()
        local class = IsValid(wep) and wep:GetClass() or "None"
        if class == lastClass then return end
        lastClass = class
        wepLbl:SetText(class)
        UpdateToggleBtn(class)
    end
end

-- ============================================================================
-- Tabbed popup
-- ============================================================================

local mainFrame = nil

local function OpenWeaponFixMenu()
    if IsValid(mainFrame) then mainFrame:MakePopup() mainFrame:Center() return end

    local frame = vgui.Create("DFrame")
    frame:SetSize(500, 580)
    frame:SetTitle("VRMod – Weapon Fix")
    frame:MakePopup() frame:Center()
    frame.Paint = function(_, w, h)
        draw.RoundedBox(6, 0, 0, w, h, COL_BG)
        draw.RoundedBox(6, 0, 0, w, 24, COL_HEADER)
    end
    mainFrame = frame
    frame.OnRemove = function()
        mainFrame = nil
        muzzlePreview = nil
        if gripRepos then GripCancel() end
    end

    local sheet = vgui.Create("DPropertySheet", frame)
    sheet:Dock(FILL) sheet:DockMargin(4, 26, 4, 4)
    sheet.Paint = function() end

    for _, info in ipairs({
        {"Muzzle Angles", BuildMuzzlePanel},
        {"Grip Position", BuildGripPanel},
        {"Animations",    BuildAnimPanel},
        {"World Models",  BuildWorldModelPanel},
        {"Attack Block",  BuildAtkBlockPanel},
    }) do
        local p = vgui.Create("DPanel", sheet)
        p:Dock(FILL)
        p.Paint = function(_, w, h) draw.RoundedBox(0, 0, 0, w, h, COL_PANEL) end
        info[2](p)
        sheet:AddSheet(info[1], p)
    end
end

concommand.Add("vrmod_weaponfix_menu", OpenWeaponFixMenu, nil, "Open VRMod Weapon Fix menu")
concommand.Add("vrmod_muzzlefix_menu", OpenWeaponFixMenu, nil, "Alias")

-- ============================================================================
-- VRMod Menu tab integration
-- ============================================================================

hook.Add("VRMod_Menu", "vrmod_weaponfix_hook", function(frame)
    if IsValid(frame.DPropertySheet) then
        for _, info in ipairs({
            {"Muzzle Fix",    BuildMuzzlePanel},
            {"Grip Offset",   BuildGripPanel},
            {"Animations",    BuildAnimPanel},
            {"World Models",  BuildWorldModelPanel},
            {"Attack Block",  BuildAtkBlockPanel},
        }) do
            local p = vgui.Create("DPanel", frame.DPropertySheet)
            p:Dock(FILL)
            p.Paint = function(_, w, h) draw.RoundedBox(0, 0, 0, w, h, COL_PANEL) end
            info[2](p)
            frame.DPropertySheet:AddSheet(info[1], p)
        end
        return
    end
    local form = frame.SettingsForm
    if not IsValid(form) then return end
    form:ControlHelp("=== Weapon Fix ===")
    local btn = form:Button("Open Weapon Fix Menu")
    btn.DoClick = function() RunConsoleCommand("vrmod_weaponfix_menu") end
end)

-- ============================================================================
-- VRMod quick-menu button
-- ============================================================================

local menuItemRegistered = false

local function TryRegisterMenuItem()
    if menuItemRegistered then return true end
    if not vrmod or not vrmod.AddInGameMenuItem then return false end
    if not g_VR or not g_VR.active then return false end
    vrmod.AddInGameMenuItem("Weapon Fix", 5, 4, function()
        RunConsoleCommand("vrmod_weaponfix_menu")
    end)
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

-- ============================================================================
-- Spawn menu fallback
-- ============================================================================

hook.Add("PopulateToolMenu", "vrmod_weaponfix_spawnmenu", function()
    spawnmenu.AddToolCategory("Utilities", "VRMod", "VRMod")
    spawnmenu.AddToolMenuOption("Utilities", "VRMod", "VRMod_WeaponFix", "Weapon Fix", "", "", function(panel)
        panel:ClearControls()
        panel:Help("VRMod Weapon Fix – muzzle angle correction and grip position offset.")
        panel:Help(" ")
        local btn = panel:Button("Open Weapon Fix Menu")
        btn.DoClick = function() RunConsoleCommand("vrmod_weaponfix_menu") end
        panel:Help(" ")
        panel:Help("Current weapon laser:")
        local laserToggle = panel:Button("Toggle Laser for Current Weapon")
        laserToggle.DoClick = function()
            local wep = LocalPlayer():GetActiveWeapon()
            if not IsValid(wep) then notification.AddLegacy("No weapon equipped!", NOTIFY_ERROR, 3) return end
            local class = wep:GetClass()
            laserEnabled[class] = not laserEnabled[class] or nil
            MuzzleSave()
            notification.AddLegacy("Laser "..(laserEnabled[class] and "ON" or "OFF").." for "..class, NOTIFY_GENERIC, 3)
        end
        panel:Help(" ")
        panel:Help("Console: vrmod_weaponfix_menu, vrmod_muzzle_list, vrmod_grip_list")
    end)
end)

-- ============================================================================
-- Console helpers
-- ============================================================================

concommand.Add("vrmod_muzzle_list", function()
    print("[WeaponFix] Muzzle offsets (viewmodel):")
    for c, off in pairs(muzzleSaved) do
        print(string_format("  %-40s  P:%-6.1f Y:%-6.1f R:%-6.1f", c, off.p or 0, off.y or 0, off.r or 0))
    end
    print("[WeaponFix] Muzzle offsets (world model):")
    local any = false
    for c, off in pairs(wmMuzzleSaved) do
        print(string_format("  %-40s  P:%-6.1f Y:%-6.1f R:%-6.1f", c, off.p or 0, off.y or 0, off.r or 0))
        any = true
    end
    if not any then print("  (none)") end
end)
concommand.Add("vrmod_grip_list", function()
    print("[WeaponFix] Grip offsets:")
    for c, e in pairs(gripSaved) do
        print(string_format("  %-40s  pos:%s  ang:%s", c, tostring(e.pos), tostring(e.ang)))
    end
end)
concommand.Add("vrmod_grip_reposition_start",  GripStart)
concommand.Add("vrmod_grip_reposition_cancel", GripCancel)
concommand.Add("vrmod_grip_save",              GripSaveCurrent)
concommand.Add("vrmod_grip_reset",             GripReset)
concommand.Add("vrmod_muzzle_reset_current", function()
    local wep = LocalPlayer():GetActiveWeapon()
    if not IsValid(wep) then print("[WeaponFix] No weapon") return end
    local class = wep:GetClass()
    muzzleSaved[class] = nil; wmMuzzleSaved[class] = nil; MuzzleSave()
    print("[WeaponFix] Muzzle reset (VM+WM) for "..class)
end)
concommand.Add("vrmod_wm_list", function()
    print("[WeaponFix] World model weapons:")
    local any = false
    for c in SortedPairs(g_VR.wmWeapons) do
        if g_VR.wmWeapons[c] then print("  "..c) any = true end
    end
    if not any then print("  (none)") end
end)
concommand.Add("vrmod_atkblock_list", function()
    print("[WeaponFix] Attack-blocked weapons:")
    local any = false
    for c in SortedPairs(atkDisabled) do
        if atkDisabled[c] then print("  "..c) any = true end
    end
    if not any then print("  (none)") end
end)

-- ============================================================================
print("[VRMod WeaponFix] Loaded.")