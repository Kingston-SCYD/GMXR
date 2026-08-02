-- lua/vrmod/core/cl_compat.lua
-- Addon-conflict detection, hook suppression and stall reporting.
--
-- Three jobs:
--   1. Warn about addons known to break VR rendering (gShader and friends).
--   2. Detect and optionally suppress foreign ShouldDrawLocalPlayer hooks,
--      which silently win over VRMod's and kill the body/hands.
--   3. Tell the user WHY the headset went blank instead of leaving them to
--      guess -- the console, the game menu and focus loss all stall the VR
--      render loop, and from inside the HMD they look identical to a crash.
if SERVER then return end

vrmod = vrmod or {}
vrmod.compat = vrmod.compat or {}

local C = vrmod.compat
local PREFIX = "[VRMod] "
local COL_WARN, COL_TEXT, COL_OK = Color(255, 190, 60), Color(255, 255, 255), Color(120, 255, 120)

local cv_warn = CreateClientConVar("vrmod_compat_warn", "1", true, false, "Warn about installed addons known to break VR", 0, 1)
local cv_killsdlp = CreateClientConVar("vrmod_compat_killhooks", "1", true, false, "Suppress other addons' ShouldDrawLocalPlayer hooks while VR is active", 0, 1)
local cv_stallwarn = CreateClientConVar("vrmod_compat_stallwarn", "1", true, false, "Draw an on-screen banner when the console/menu/focus loss stalls VR rendering", 0, 1)

------------------------------------------------------------------------
-- 1. Known-incompatible addons
--
-- Matched on workshop/legacy addon title, global table or convar -- whichever
-- the addon happens to expose. Any single hit counts.
------------------------------------------------------------------------
local INCOMPATIBLE = {
	{
		label = "gShader",
		why = "replaces the scene render pipeline; VR eyes render black, single-eye or heavily ghosted.",
		titles = { "gshader" },
		globals = { "gShader", "GShader", "gshader", "gShaderMod" },
		convars = { "gshader_enabled", "gshader_toggle", "gshader_quality", "mat_gshader" },
	},
}

local function AddonTitles()
	local out, add = {}, nil
	if engine and engine.GetAddons then
		for _, a in ipairs(engine.GetAddons()) do
			if a.title and (a.mounted == nil or a.mounted) then out[#out + 1] = a.title:lower() end
		end
	end
	add = file.Find("addons/*", "GAME")
	if add then
		for i = 1, #add do out[#out + 1] = add[i]:lower() end
	end
	return out
end

-- Returns an array of { label, why } for everything detected.
function C.ScanAddons()
	local hits, titles = nil, nil
	for i = 1, #INCOMPATIBLE do
		local e = INCOMPATIBLE[i]
		local found = false
		for j = 1, #e.globals do
			if _G[e.globals[j]] ~= nil then found = true break end
		end
		if not found then
			for j = 1, #e.convars do
				if GetConVar(e.convars[j]) then found = true break end
			end
		end
		if not found and #e.titles > 0 then
			titles = titles or AddonTitles()
			for j = 1, #e.titles do
				local pat = e.titles[j]
				for k = 1, #titles do
					if titles[k]:find(pat, 1, true) then found = true break end
				end
				if found then break end
			end
		end
		if found then
			hits = hits or {}
			hits[#hits + 1] = e
		end
	end
	return hits
end

------------------------------------------------------------------------
-- 2. Foreign hooks
--
-- ShouldDrawLocalPlayer has no priority system: whichever hook GMod happens to
-- reach first and returns non-nil wins, so a single thirdperson/camera addon
-- can permanently hide (or force-show) the VR body with no error anywhere.
------------------------------------------------------------------------
local OURS = {
	ShouldDrawLocalPlayer = { vrutil_hook_shoulddrawlocalplayer = true, vrmod_debugvr = true },
	RenderScene = { vrutil_hook_renderscene = true },
	CalcView = { vrutil_hook_calcview = true },
}

-- Foreign hook names on `event`, or nil. Second return is the count.
function C.ForeignHooks(event)
	local t = hook.GetTable()[event]
	if not t then return nil, 0 end
	local ours = OURS[event]
	local out, n = nil, 0
	for name in pairs(t) do
		if not (ours and ours[name]) and isstring(name) then
			out = out or {}
			n = n + 1
			out[n] = name
		end
	end
	return out, n
end

local started -- VR session live (g_VR.active goes false while paused)
local stash -- [name] = fn, removed while VR is active

function C.SuppressSDLP()
	if not cv_killsdlp:GetBool() then return 0 end
	local t = hook.GetTable().ShouldDrawLocalPlayer
	if not t then return 0 end
	local ours, pull, n = OURS.ShouldDrawLocalPlayer, nil, 0
	-- Collect before removing: hook.Remove mutates the table we are walking.
	for name, fn in pairs(t) do
		if not ours[name] and isstring(name) then
			pull = pull or {}
			n = n + 1
			pull[n] = name
			stash = stash or {}
			stash[name] = fn
		end
	end
	for i = 1, n do
		hook.Remove("ShouldDrawLocalPlayer", pull[i])
	end
	return n
end

function C.RestoreSDLP()
	if not stash then return end
	for name, fn in pairs(stash) do
		hook.Add("ShouldDrawLocalPlayer", name, fn)
	end
	stash = nil
end

------------------------------------------------------------------------
-- 3. Why the headset is blank
------------------------------------------------------------------------
-- Focus-class stalls only. The console and the escape menu stall VR too, but
-- they are already on screen announcing themselves -- a banner over them is
-- noise. Those cases are handled by the in-headset card instead, which is the
-- one place the user genuinely cannot see what happened.
function C.GetStallReason()
	if not system.HasFocus() then return "The game window is not focused" end
	if g_VR.errorText and #g_VR.errorText > 0 then return g_VR.errorText end
end

local stallStart
hook.Add("PostRenderVGUI", "vrmod_compat_stallbanner", function()
	if not cv_stallwarn:GetBool() or not started then
		stallStart = nil
		return
	end
	local reason = C.GetStallReason()
	if not reason then
		if stallStart then
			vrmod.logger.Info("VR render stalled for %.1fs", RealTime() - stallStart)
			stallStart = nil
		end
		return
	end
	stallStart = stallStart or RealTime()

	local w = math.min(ScrW() - 40, 720)
	local x, y = (ScrW() - w) * 0.5, 24
	draw.RoundedBox(6, x, y, w, 64, Color(20, 20, 20, 230))
	draw.RoundedBox(6, x, y, 5, 64, COL_WARN)
	draw.SimpleText("VR rendering is stalled - the headset is not updating", "DermaLarge", x + 18, y + 10, COL_WARN)
	draw.SimpleText(reason .. ". Close it and refocus the game to resume.", "DermaDefaultBold", x + 18, y + 42, COL_TEXT)
end)

------------------------------------------------------------------------
-- Reporting
------------------------------------------------------------------------
local function Say(col, msg) chat.AddText(COL_WARN, PREFIX, col, msg) end

function C.Report(verbose)
	if not cv_warn:GetBool() and not verbose then return end
	local hits = C.ScanAddons()
	if hits then
		for i = 1, #hits do
			Say(COL_TEXT, hits[i].label .. " detected - " .. hits[i].why)
		end
		Say(COL_TEXT, "Disable it if the headset image looks wrong. Silence this with vrmod_compat_warn 0.")
	elseif verbose then
		Say(COL_OK, "No known-incompatible render addons detected.")
	end

	local sdlp, n = C.ForeignHooks("ShouldDrawLocalPlayer")
	if n > 0 then
		local killed = cv_killsdlp:GetBool()
		Say(COL_TEXT, n .. " other addon(s) hook ShouldDrawLocalPlayer (" .. table.concat(sdlp, ", ") .. ") - this breaks the VR body/hands.")
		Say(killed and COL_OK or COL_TEXT, killed and "They are suppressed while VR is active (vrmod_compat_killhooks 1)." or "Set vrmod_compat_killhooks 1 to suppress them while VR is active.")
	elseif verbose then
		Say(COL_OK, "No foreign ShouldDrawLocalPlayer hooks.")
	end

	if verbose then
		local rs, rn = C.ForeignHooks("RenderScene")
		local cv, cn = C.ForeignHooks("CalcView")
		if rn > 0 then Say(COL_TEXT, "Foreign RenderScene hooks: " .. table.concat(rs, ", ")) end
		if cn > 0 then Say(COL_TEXT, "Foreign CalcView hooks: " .. table.concat(cv, ", ")) end
	end
end

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------
hook.Add("VRMod_Start", "vrmod_compat", function(ply)
	if ply ~= LocalPlayer() then return end
	started = true
	-- Deferred: addons that add their hooks on spawn/deploy are not in the
	-- table yet at VRMod_Start.
	timer.Simple(1, function()
		C.SuppressSDLP()
		C.Report(false)
	end)
	-- Re-sweep: thirdperson and camera addons re-add on weapon switch.
	timer.Create("vrmod_compat_sweep", 5, 0, function()
		if C.SuppressSDLP() > 0 then vrmod.logger.Info("Suppressed a re-added ShouldDrawLocalPlayer hook") end
	end)
end)

hook.Add("VRMod_Exit", "vrmod_compat", function(ply)
	if ply ~= LocalPlayer() then return end
	started = false
	timer.Remove("vrmod_compat_sweep")
	C.RestoreSDLP()
end)

cvars.AddChangeCallback("vrmod_compat_killhooks", function(_, _, new)
	if tobool(new) then
		if started then C.SuppressSDLP() end
	else
		C.RestoreSDLP()
	end
end, "vrmod_compat")

concommand.Add("vrmod_compat", function() C.Report(true) end, nil, "Report addons and hooks known to conflict with VRMod")