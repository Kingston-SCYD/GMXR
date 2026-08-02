-- lua/vrmod/player/cl_character_presets.lua
-- Per-playermodel calibration presets. Auto-saves convar changes while in VR,
-- auto-loads when the active playermodel changes or when VR starts.
if SERVER then return end

vrmod = vrmod or {}
vrmod.characterPresets = vrmod.characterPresets or {}

local PRESETS = vrmod.characterPresets
local FILE_PATH = "vrmod/character_presets.json"
local DIR_PATH = "vrmod"

-- Convars that differ per playermodel. Keep this list tight; global settings
-- (controller offsets, laser, etc.) must NOT be here.
local TRACKED = {
	"vrmod_charactereyeheight",
	"vrmod_characterheadtohmddist",
	"vrmod_armstretcher",
	"vrmod_characteryawblend",
	"vrmod_characterik",
	"vrmod_scale",
	"vrmod_smallhull",
}

-- Default values, used when clearing a preset.
local DEFAULTS = {
	vrmod_charactereyeheight = "66.8",
	vrmod_characterheadtohmddist = "6.3",
	vrmod_armstretcher = "0",
	vrmod_characteryawblend = "1.5",
	vrmod_characterik = "1",
	vrmod_scale = "32.7",
	vrmod_smallhull = "1",
}

local data = {} -- [modelPath] = { cvarName = stringValue, ... }
local currentModel = nil -- last model we applied a preset for
local loading = false -- suppress save during load
local saveTimerName = "vrmod_char_presets_save"

------------------------------------------------------------------------
-- Disk I/O
------------------------------------------------------------------------
local function LoadFile()
	if not file.Exists(FILE_PATH, "DATA") then return end
	local raw = file.Read(FILE_PATH, "DATA")
	if not raw or raw == "" then return end
	local tbl = util.JSONToTable(raw)
	if type(tbl) ~= "table" then
		vrmod.logger.Warn("character_presets.json unreadable, ignoring")
		return
	end
	data = tbl
	vrmod.logger.Info("Loaded %d character preset(s)", table.Count(data))
end

local function WriteFile()
	if not file.IsDir(DIR_PATH, "DATA") then file.CreateDir(DIR_PATH) end
	file.Write(FILE_PATH, util.TableToJSON(data, true))
end

-- Debounce disk writes to 1Hz so slider drags don't hammer the disk.
local function QueueSave()
	timer.Create(saveTimerName, 1, 1, WriteFile)
end

------------------------------------------------------------------------
-- Apply / Capture
------------------------------------------------------------------------
-- Holds `loading` true for a short window so both synchronous (SetString)
-- and asynchronous (RunConsoleCommand -> server -> replicate back) convar
-- change callbacks can fire without triggering a save loop.
local loadingHoldUntil = 0
local function BeginLoading()
	loading = true
	loadingHoldUntil = CurTime() + 0.25
end

hook.Add("Think", "vrmod_char_presets_loadguard", function()
	if loading and CurTime() >= loadingHoldUntil then loading = false end
end)

-- Safely set a convar value, handling replicated convars (which can't be
-- SetString'd from the client) by falling back to RunConsoleCommand.
local function SetConVarValue(cv, name, value)
	if not cv then return end
	-- FCVAR_REPLICATED convars live on the server; SetString errors.
	-- RunConsoleCommand for these: the client sends the command to the
	-- server, which applies it and replicates the new value back.
	if cv:IsFlagSet(FCVAR_REPLICATED) then
		RunConsoleCommand(name, tostring(value))
	else
		cv:SetString(tostring(value))
	end
end

-- Push a preset's values into the live convars. See BeginLoading above for
-- why we extend the guard window instead of releasing synchronously.
local function ApplyPreset(preset)
	BeginLoading()
	for _, name in ipairs(TRACKED) do
		local v = preset[name]
		if v ~= nil then SetConVarValue(GetConVar(name), name, v) end
	end
	-- Keep g_VR.scale in sync with vrmod_scale (heightadjust writes both).
	if preset.vrmod_scale and g_VR then g_VR.scale = tonumber(preset.vrmod_scale) or g_VR.scale end
end

-- Snapshot current convar values into data[model].
local function CaptureCurrent(model)
	if not model or model == "" then return end
	local t = data[model] or {}
	for _, name in ipairs(TRACKED) do
		local cv = GetConVar(name)
		if cv then t[name] = cv:GetString() end
	end
	data[model] = t
end

------------------------------------------------------------------------
-- Model tracking
------------------------------------------------------------------------
-- Prefer ply.vrmod_pm (broadcast by sh_pmchange.lua when any addon calls
-- Entity:SetModel server-side) but fall back to ply:GetModel(). Both are
-- needed: vrmod_pm catches cases where GetModel goes stale after PAC3 or
-- similar addons; GetModel catches cases where the sh_pmchange broadcast
-- hasn't fired yet (e.g. initial spawn).
local function GetLocalModel()
	local lp = LocalPlayer()
	if not IsValid(lp) then return nil end
	local m = lp.vrmod_pm or lp:GetModel()
	if not m or m == "" or m == "models/player.mdl" then return nil end
	return m
end

local function OnModelChanged(newModel)
	if currentModel and not loading then
		-- Before switching, save the outgoing model's values.
		CaptureCurrent(currentModel)
		QueueSave()
	end
	currentModel = newModel
	local preset = data[newModel]
	if preset then
		ApplyPreset(preset)
		vrmod.logger.Info("Applied preset for %s", newModel)
	else
		-- No preset yet; current convar values become the seed once the user edits something.
		vrmod.logger.Info("No preset for %s (will create on first change)", newModel)
	end
end

-- Detect model changes every frame via Think. The check is two table lookups
-- and one string compare — truly free. Previously this ran on a 1-second
-- timer which meant the UI status label could show the wrong model for up
-- to a second after switching, and the preset swap was similarly delayed.
hook.Add("Think", "vrmod_char_presets_watch", function()
	local m = GetLocalModel()
	if m and m ~= currentModel then OnModelChanged(m) end
end)

------------------------------------------------------------------------
-- Convar change hooks: auto-save on edit
------------------------------------------------------------------------
local function OnTrackedChanged()
	if loading then return end
	if not currentModel then
		local m = GetLocalModel()
		if not m then return end
		currentModel = m
	end
	CaptureCurrent(currentModel)
	QueueSave()
end

for _, name in ipairs(TRACKED) do
	cvars.AddChangeCallback(name, function() OnTrackedChanged() end, "vrmod_char_presets")
end

-- Mirror vrmod_scale into g_VR.scale on every change. The engine's tracking
-- loop (UpdateTracking in cl_vrmod.lua) reads g_VR.scale directly each frame
-- -- it does NOT re-read the convar. The height-menu +/- buttons happen to
-- write both the convar and g_VR.scale, which hid this design gap; every
-- other path (presets, console `vrmod_scale X`, UI sliders) only wrote the
-- convar, so world scale would only update on the next VR restart. This
-- callback runs regardless of the `loading` guard because it's read-only
-- w.r.t. convars (can't trigger a save loop).
cvars.AddChangeCallback("vrmod_scale", function(_, _, new)
	if g_VR then
		local v = tonumber(new)
		if v then g_VR.scale = v end
	end
end, "vrmod_char_presets_scale_mirror")

------------------------------------------------------------------------
-- VR lifecycle
------------------------------------------------------------------------
hook.Add("VRMod_Start", "vrmod_char_presets_start", function()
	local m = GetLocalModel()
	if not m then return end
	currentModel = m
	local preset = data[m]
	if preset then ApplyPreset(preset) end
end)

hook.Add("VRMod_Exit", "vrmod_char_presets_exit", function(ply)
	if ply ~= LocalPlayer() then return end
	if currentModel then CaptureCurrent(currentModel) end
	if timer.Exists(saveTimerName) then timer.Remove(saveTimerName) end
	WriteFile()
end)

hook.Add("ShutDown", "vrmod_char_presets_shutdown", function()
	if currentModel then CaptureCurrent(currentModel) end
	if timer.Exists(saveTimerName) then timer.Remove(saveTimerName) end
	WriteFile()
end)

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------
-- Returns the model path currently worn by the local player, or nil if
-- unknown. Always reads live (not cached) so the UI reflects reality.
function PRESETS.GetCurrentModel()
	return GetLocalModel()
end

-- Returns the number of saved presets.
function PRESETS.Count()
	return table.Count(data)
end

-- Returns true if a preset exists for the given model (or current if nil).
function PRESETS.Has(model)
	model = model or PRESETS.GetCurrentModel()
	return model ~= nil and data[model] ~= nil
end

-- Reset convars to defaults (does not touch stored data).
local function ResetConvarsToDefaults()
	BeginLoading()
	for name, val in pairs(DEFAULTS) do
		SetConVarValue(GetConVar(name), name, val)
	end
	if g_VR then g_VR.scale = tonumber(DEFAULTS.vrmod_scale) end
end

-- Clear the preset for the given model (or current). Resets live convars.
function PRESETS.ClearCurrent(model)
	model = model or PRESETS.GetCurrentModel()
	if not model then return false end
	data[model] = nil
	ResetConvarsToDefaults()
	WriteFile()
	vrmod.logger.Info("Cleared preset for %s", model)
	return true
end

-- Wipe every preset. Resets live convars.
function PRESETS.ClearAll()
	data = {}
	ResetConvarsToDefaults()
	WriteFile()
	vrmod.logger.Info("Cleared all character presets")
end

-- For the UI: expose read-only access to the data table.
function PRESETS.GetAllModels()
	local r = {}
	for m in pairs(data) do r[#r + 1] = m end
	table.sort(r)
	return r
end

------------------------------------------------------------------------
LoadFile()

-- Diagnostic: console command to inspect what we think the current model is
-- and what's stored. Useful when troubleshooting stale playermodel issues.
concommand.Add("vrmod_char_presets_debug", function()
	local lp = LocalPlayer()
	local getModel = IsValid(lp) and lp:GetModel() or "(no player)"
	local vrmodPm = IsValid(lp) and lp.vrmod_pm or "(nil)"
	local resolved = GetLocalModel() or "(nil)"
	print("== VRMod Character Presets ==")
	print("  ply:GetModel()    : " .. tostring(getModel))
	print("  ply.vrmod_pm      : " .. tostring(vrmodPm))
	print("  resolved          : " .. tostring(resolved))
	print("  tracked currentModel: " .. tostring(currentModel))
	print("  presets stored    : " .. table.Count(data))
	for m in pairs(data) do print("    * " .. m) end
end)