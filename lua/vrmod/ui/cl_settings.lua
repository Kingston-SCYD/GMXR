if SERVER then return end
local convars = vrmod.GetConvars()
local frame = nil
local darkHelpApplied = false

-- ══════════════════════════════════════════════════════════════════
-- Convar lists for presets and export
-- ══════════════════════════════════════════════════════════════════
local CLIENT_CVARS = {
	-- General
	"vrmod_laserpointer", "vrmod_useworldmodels", "vrmod_heightmenu", "vrmod_seated",
	"vrmod_autostart", "vrmod_climbing", "vrmod_doors", "vrmod_flashlight_attachment",
	"vrmod_flashlight_shadows", "vrmod_flashlight_depth",
	"vrmod_menu_float", "vrmod_menu_scale", "vrmod_quickmenu_float",
	-- Controls
	"vrmod_smoothturn", "vrmod_smoothturnrate", "vrmod_snapturnangle", "vrmod_althead", "vrmod_althead_auto",
	"vrmod_controlleroffset_x", "vrmod_controlleroffset_y", "vrmod_controlleroffset_z",
	"vrmod_controlleroffset_pitch", "vrmod_controlleroffset_yaw", "vrmod_controlleroffset_roll",
	-- Rendering
	"vrmod_desktopview", "vrmod_postprocess", "vrmod_skybox", "vrmod_znear", "vrmod_eyescale",
	"vrmod_perfoverrides",
	"vrmod_perf_threaded_bones", "vrmod_perf_mcore", "vrmod_perf_mat_queue",
	"vrmod_perf_no_bloom", "vrmod_perf_no_fancyblend", "vrmod_perf_no_lightwarp",
	"vrmod_perf_no_pspatch", "vrmod_perf_no_motionblur", "vrmod_perf_reduce_particles",
	"vrmod_perf_no_rtt_shadows", "vrmod_perf_threaded_particles", "vrmod_perf_queued_ropes",
	-- Character
	"vrmod_floatinghands", "vrmod_characterik", "vrmod_armstretcher", "vrmod_characteryawblend",
	"vrmod_fbt_leginfluence", "vrmod_fbt_animshoulders",
	"vrmod_sitheight", "vrmod_sitheadtohmddist", "vrmod_proneheight", "vrmod_proneheadtohmddist",
	"vrmod_charactereyeheight", "vrmod_characterheadtohmddist", "vrmod_smallhull", "vrmod_hullscale", "vrmod_anticlip", "vrmod_scale",
	-- HUD
	"vrmod_hud", "vrmod_hudmode", "vrmod_hudcurve", "vrmod_huddistance", "vrmod_hudscale",
	"vrmod_hudtestalpha", "vrmod_hudblacklist", "vrmod_hud_visible_quickmenukey",
	"vrmod_beam_color", "vrmod_laser_color", "vrmod_hud_color", "vrmod_hud_font",
	"vrmod_hudattach", "vrmod_hudarmscale",
	"vrmod_hudcrt", "vrmod_hudarm_x", "vrmod_hudarm_y", "vrmod_hudarm_z",
	"vrmod_hudarm_p", "vrmod_hudarm_yaw", "vrmod_hudarm_r", "vrmod_hudinteract",
	"vrmod_ui_outline", "vrmod_pointer_hand",
	-- Gameplay (client)
	"vr_pickup_disable_client", "vrmod_collisions", "vrmod_weapondrop_enable", "vrmod_weapondrop_release",
	"vrmod_manualpickups", "vrmod_interactive_buttons", "vrmod_weapon_swap",
	"vrmod_pickup_halos", "vrmod_nocrouchjump", "vrmod_allow_teleport_client",
	"vrmod_teleport_use_left", "vrmod_weaponmenu_style", "vrmod_menu_hand",
	"vrmod_deathcam_ragdoll", "vrmod_deathcam_ragdoll_view",
	-- Melee (client)
	"cl_vrmod_melee", "cl_vrmod_kick", "cl_vrmod_headbutt",
	-- Vehicles
	"vrmod_sens_pitch", "vrmod_sens_pitch_smooth", "vrmod_sens_yaw", "vrmod_sens_yaw_smooth",
	"vrmod_sens_roll", "vrmod_sens_roll_smooth",
	"vrmod_sens_steer_car", "vrmod_sens_steer_car_smooth", "vrmod_rot_range_car",
	"vrmod_sens_steer_motorcycle", "vrmod_sens_steer_motorcycle_smooth", "vrmod_rot_range_motorcycle",
	"vrmod_vehicle_gripenter", "vrmod_vehicle_gripamount", "vrmod_vehicle_gripdist",
	"vrmod_vehicle_sitenter", "vrmod_vehicle_sitexit",
	-- Climbing
	"vrmod_brushclimb", "vrmod_brushclimb_requireboth", "vrmod_brushclimb_nofloor",
	"vrmod_brushclimb_magnet", "vrmod_brushclimb_magnet_offset", "vrmod_brushclimb_ledgeonly",
	"vrmod_brushclimb_ladderonly", "vrmod_brushclimb_ledgereach", "vrmod_brushclimb_ledge", "vrmod_brushclimb_marker",
	"vrmod_brushclimb_vaultreach", "vrmod_brushclimb_vaultmin",
	"vrmod_brushclimb_reach", "vrmod_brushclimb_smooth", "vrmod_brushclimb_ladderreach",
	-- Holster
	"vrmod_pouch_enabled", "vrmod_pouch_visiblename", "vrmod_pouch_visiblename_hud",
	"vrmod_pouch_lefthandwep_enable", "vrmod_holster_showmodels", "vrmod_pouch_chest_z",
	"vrmod_holster_prop_maxvolume", "vrmod_holster_ragdolls", "vrmod_holster_ragdoll_models",
	"vrmod_holster_persist",
	"vrmod_holster_model_enabled", "vrmod_holster_model",
	"vrmod_holster_model_x", "vrmod_holster_model_y", "vrmod_holster_model_z",
	"vrmod_holster_model_p", "vrmod_holster_model_yaw", "vrmod_holster_model_r",
	"vrmod_holster_model_slot1", "vrmod_holster_model_slot2", "vrmod_holster_model_slot3", "vrmod_holster_model_slot4",
	-- Face Tracking
	"ft_enabled", "ft_port", "ft_rate", "ft_smooth", "ft_multiplier",
}

local SERVER_CVARS = {
	"vrmod_allow_teleport", "vrmod_teleport_maxdist",
	"vrmod_pickup_limit", "vrmod_pickup_npcs", "vrmod_pickup_no_phys",
	"vrmod_pickup_weight", "vrmod_pickup_range", "vrmod_hand_physics",
	"vrmod_pickup_players", "vrmod_pickup_players_adminprotect",
	"vrmod_selfdamage",
	"sv_vrmod_melee", "vrmod_melee_damage", "vrmod_melee_velthreshold",
	"vrmod_melee_delay", "vrmod_melee_speedscale", "vrmod_melee_fist_collisionmodel",
	"sv_vrmod_kick", "vrmod_kick_damage", "vrmod_kick_velthreshold",
	"sv_vrmod_headbutt", "vrmod_headbutt_damage", "vrmod_headbutt_velthreshold",
	"vrmod_sv_climbing", "vrmod_sv_climbing_ledgeonly", "vrmod_sv_climbing_ladderonly",
	"vrmod_sv_climbing_throw", "vrmod_sv_climbing_throwmin", "vrmod_sv_climbing_throwmax",
	-- Hull
	"vrmod_smallhull_all",
	-- Networking
	"vrmod_net_tickrate", "vrmod_net_minsend",
}

-- ══════════════════════════════════════════════════════════════════
-- ULX RCON forwarding for server-side settings
-- Server convars are FCVAR_REPLICATED / pure-server, so a client console
-- can't write them. With this toggle on, any change to a SERVER_CVARS
-- control (and the reset button) is mirrored through `ulx rcon`, letting a
-- superadmin flip server settings from inside VR without opening console.
-- ══════════════════════════════════════════════════════════════════
local cv_rcon = CreateClientConVar("vrmod_settings_rcon", "0", true, false)

local SERVER_CVAR_SET = {}
for i = 1, #SERVER_CVARS do SERVER_CVAR_SET[SERVER_CVARS[i]] = true end

local function RconCvar(name, value)
	if not cv_rcon:GetBool() then return end
	-- Debounce: collapse slider drags / rapid edits into a single rcon call.
	timer.Create("vrmod_rcon_" .. name, 0.3, 1, function()
		RunConsoleCommand("ulx", "rcon", name .. " " .. value)
	end)
end

-- One pass over the built frame: re-route every control bound to a server
-- convar so its commit event also fires rcon. Runs once on menu open.
local function WireServerRcon(panel)
	for _, child in ipairs(panel:GetChildren()) do
		local name = child.GetConVar and child:GetConVar() or child.m_strConVar
		if name and name ~= "" and SERVER_CVAR_SET[name] then
			if child.OnValueChanged then            -- DNumSlider
				local old = child.OnValueChanged
				child.OnValueChanged = function(s, v) old(s, v) RconCvar(name, tostring(v)) end
			elseif child.OnSelect then              -- DComboBox
				local old = child.OnSelect
				child.OnSelect = function(s, i, t, d) old(s, i, t, d) RconCvar(name, tostring(d == nil and t or d)) end
			elseif child.OnValueChange then         -- DTextEntry (commit, not per-keystroke)
				local old = child.OnValueChange
				child.OnValueChange = function(s, v) old(s, v) RconCvar(name, tostring(v)) end
			elseif child.OnChange then              -- DCheckBox
				local old = child.OnChange
				child.OnChange = function(s, v) old(s, v) RconCvar(name, v and "1" or "0") end
			end
		end
		WireServerRcon(child)
	end
end

-- ══════════════════════════════════════════════════════════════════
-- Preset helpers
-- ══════════════════════════════════════════════════════════════════
local PRESET_DIR_CLIENT = "vrmod/presets_client"
local PRESET_DIR_SERVER = "vrmod/presets_server"

local function EnsureDir(path)
	if not file.IsDir(path, "DATA") then file.CreateDir(path) end
end

local function SavePreset(dir, name, cvarList)
	EnsureDir("vrmod")
	EnsureDir(dir)
	local data = {}
	for _, cvar in ipairs(cvarList) do
		local cv = GetConVar(cvar)
		if cv then data[cvar] = cv:GetString() end
	end
	file.Write(dir .. "/" .. name .. ".json", util.TableToJSON(data, true))
end

local function LoadPreset(dir, name)
	local raw = file.Read(dir .. "/" .. name .. ".json", "DATA")
	if not raw then return false end
	local data = util.JSONToTable(raw)
	if not data then return false end
	for cvar, val in pairs(data) do
		RunConsoleCommand(cvar, val)
	end
	return true
end

local function GetPresetNames(dir)
	EnsureDir("vrmod")
	EnsureDir(dir)
	local files = file.Find(dir .. "/*.json", "DATA")
	local names = {}
	for _, f in ipairs(files) do
		names[#names + 1] = f:sub(1, -6)
	end
	table.sort(names)
	return names
end

local function DeletePreset(dir, name)
	file.Delete(dir .. "/" .. name .. ".json")
end

local function ImportPresetFromText(dir, name, text)
	EnsureDir("vrmod")
	EnsureDir(dir)
	local data = {}
	for line in text:gmatch("[^\r\n]+") do
		local k, v = line:match("^(%S+)%s+(.+)$")
		if k and v then data[k] = v end
	end
	if table.Count(data) == 0 then return false end
	file.Write(dir .. "/" .. name .. ".json", util.TableToJSON(data, true))
	return true, table.Count(data)
end

-- Write built-in default presets to disk on first run
do
	EnsureDir("vrmod")
	local defaultClient = {
		vrmod_laserpointer = "0", vrmod_useworldmodels = "0", vrmod_heightmenu = "0",
		vrmod_seated = "0", vrmod_autostart = "0", vrmod_doors = "1",
		vrmod_flashlight_attachment = "1", vrmod_flashlight_shadows = "0", vrmod_flashlight_depth = "0",
		vrmod_menu_float = "1", vrmod_menu_scale = "1.0", vrmod_quickmenu_float = "0",
		vrmod_smoothturn = "1", vrmod_smoothturnrate = "180", vrmod_snapturnangle = "45", vrmod_althead = "0", vrmod_althead_auto = "1",
		vrmod_controlleroffset_x = "-15", vrmod_controlleroffset_y = "-1",
		vrmod_controlleroffset_z = "5", vrmod_controlleroffset_pitch = "50",
		vrmod_controlleroffset_yaw = "0", vrmod_controlleroffset_roll = "0",
		vrmod_desktopview = "3", vrmod_postprocess = "0", vrmod_skybox = "1",
		vrmod_znear = "1", vrmod_eyescale = "0.5", vrmod_perfoverrides = "1",
		vrmod_perf_threaded_bones = "1", vrmod_perf_mcore = "1", vrmod_perf_mat_queue = "1",
		vrmod_perf_no_bloom = "1", vrmod_perf_no_fancyblend = "1", vrmod_perf_no_lightwarp = "1",
		vrmod_perf_no_pspatch = "1", vrmod_perf_no_motionblur = "1", vrmod_perf_reduce_particles = "1",
		vrmod_perf_no_rtt_shadows = "1", vrmod_perf_threaded_particles = "1", vrmod_perf_queued_ropes = "1",
		vrmod_floatinghands = "0", vrmod_characterik = "1", vrmod_armstretcher = "1",
		vrmod_characteryawblend = "1.5", vrmod_fbt_leginfluence = "0.33",
		vrmod_fbt_animshoulders = "1", vrmod_charactereyeheight = "55.6",
		vrmod_characterheadtohmddist = "7.7", vrmod_smallhull = "1", vrmod_hullscale = "0.625", vrmod_anticlip = "1", vrmod_scale = "41.669140",
		vrmod_hud = "1", vrmod_hudmode = "0", vrmod_hudcurve = "4", vrmod_huddistance = "59",
		vrmod_hudscale = "0.04", vrmod_hudtestalpha = "0", vrmod_hudblacklist = "",
		vrmod_beam_color = "203,109,109,255", vrmod_laser_color = "255,0,0,255",
		vrmod_hud_color = "255,250,0,255", vrmod_hud_font = "Trebuchet MS",
		vrmod_hudattach = "1", vrmod_hudarmscale = "0.0418", vrmod_hudcrt = "0",
		vrmod_hudarm_x = "5", vrmod_hudarm_y = "-3", vrmod_hudarm_z = "1",
		vrmod_hudarm_p = "0", vrmod_hudarm_yaw = "180", vrmod_hudarm_r = "90",
		vrmod_hudinteract = "2", vrmod_ui_outline = "0", vrmod_pointer_hand = "0",
		vrmod_collisions = "1", vrmod_weapondrop_enable = "0", vrmod_manualpickups = "0",
		vrmod_interactive_buttons = "1", vrmod_weapon_swap = "1", vrmod_pickup_halos = "1",
		vrmod_nocrouchjump = "1", vrmod_allow_teleport_client = "0",
		vrmod_teleport_use_left = "0", vrmod_weaponmenu_style = "0", vrmod_menu_hand = "1",
		vrmod_deathcam_ragdoll = "1", vrmod_deathcam_ragdoll_view = "1",
		cl_vrmod_melee = "1", cl_vrmod_kick = "1", cl_vrmod_headbutt = "1",
		vrmod_brushclimb = "1", vrmod_brushclimb_requireboth = "1",
		vrmod_brushclimb_nofloor = "1", vrmod_brushclimb_magnet = "0",
		vrmod_brushclimb_magnet_offset = "2.0", vrmod_brushclimb_ledgeonly = "0",
		vrmod_brushclimb_ladderonly = "0", vrmod_brushclimb_ledgereach = "24", vrmod_brushclimb_ledge = "1",
		vrmod_brushclimb_marker = "1", vrmod_brushclimb_vaultreach = "31",
		vrmod_brushclimb_vaultmin = "8",
		vrmod_brushclimb_reach = "2", vrmod_brushclimb_smooth = "0", vrmod_brushclimb_ladderreach = "24",
		vrmod_pouch_enabled = "0", vrmod_pouch_visiblename = "0",
		vrmod_pouch_visiblename_hud = "0", vrmod_pouch_lefthandwep_enable = "1",
		vrmod_holster_showmodels = "1", vrmod_pouch_chest_z = "-3.4",
		vrmod_holster_prop_maxvolume = "5750", vrmod_holster_ragdolls = "0",
		vrmod_holster_ragdoll_models = "0", vrmod_holster_persist = "1",
		vrmod_holster_model_enabled = "1", vrmod_holster_model = "models/weapons/w_eq_eholster.mdl",
		vrmod_holster_model_x = "0", vrmod_holster_model_y = "0", vrmod_holster_model_z = "0",
		vrmod_holster_model_p = "0", vrmod_holster_model_yaw = "0", vrmod_holster_model_r = "0",
		vrmod_holster_model_slot1 = "1", vrmod_holster_model_slot2 = "1", vrmod_holster_model_slot3 = "1", vrmod_holster_model_slot4 = "1",
	}
	local defaultServer = {
		vrmod_allow_teleport = "1", vrmod_teleport_maxdist = "0",
		vrmod_pickup_limit = "1", vrmod_pickup_npcs = "1", vrmod_pickup_no_phys = "0",
		vrmod_pickup_weight = "35", vrmod_pickup_range = "0.7", vrmod_selfdamage = "1",
		vrmod_pickup_players = "0", vrmod_pickup_players_adminprotect = "1",
		vrmod_hand_physics = "1",
		sv_vrmod_melee = "1", vrmod_melee_damage = "2", vrmod_melee_velthreshold = "2.5",
		vrmod_melee_delay = "0.03", vrmod_melee_speedscale = "0.001",
		vrmod_melee_fist_collisionmodel = "models/props_junk/PopCan01a.mdl",
		sv_vrmod_kick = "1", vrmod_kick_damage = "25", vrmod_kick_velthreshold = "1.6",
		sv_vrmod_headbutt = "1", vrmod_headbutt_damage = "5", vrmod_headbutt_velthreshold = "2.5",
	}
	EnsureDir(PRESET_DIR_CLIENT)
	EnsureDir(PRESET_DIR_SERVER)
	if not file.Exists(PRESET_DIR_CLIENT .. "/Default.json", "DATA") then
		file.Write(PRESET_DIR_CLIENT .. "/Default.json", util.TableToJSON(defaultClient, true))
	end
	if not file.Exists(PRESET_DIR_SERVER .. "/Default.json", "DATA") then
		file.Write(PRESET_DIR_SERVER .. "/Default.json", util.TableToJSON(defaultServer, true))
	end
end

-- VR-safe dialog helpers (render as children of parent frame, not as popups)
local function VRStringRequest(parent, title, prompt, default, onConfirm)
	local overlay = vgui.Create("DPanel", parent)
	overlay:SetSize(parent:GetWide(), parent:GetTall())
	overlay:SetPos(0, 0)
	overlay:MoveToFront()
	overlay:SetMouseInputEnabled(true)
	overlay.Paint = function(_, w, h)
		surface.SetDrawColor(0, 0, 0, 180)
		surface.DrawRect(0, 0, w, h)
	end
	local dlg = vgui.Create("DPanel", overlay)
	dlg:SetSize(300, 140)
	dlg:Center()
	dlg.Paint = function(_, w, h)
		draw.RoundedBox(6, 0, 0, w, h, Color(50, 50, 50))
		draw.RoundedBox(6, 0, 0, w, 26, Color(70, 70, 70))
	end
	local lbl = vgui.Create("DLabel", dlg)
	lbl:SetPos(10, 4)
	lbl:SetText(title)
	lbl:SetFont("DermaDefaultBold")
	lbl:SizeToContents()
	local lbl2 = vgui.Create("DLabel", dlg)
	lbl2:SetPos(10, 34)
	lbl2:SetText(prompt)
	lbl2:SizeToContents()
	local entry = vgui.Create("DTextEntry", dlg)
	entry:SetPos(10, 56)
	entry:SetSize(280, 25)
	entry:SetText(default or "")
	entry:RequestFocus()
	local ok = vgui.Create("DButton", dlg)
	ok:SetPos(10, 92)
	ok:SetSize(135, 30)
	ok:SetText("OK")
	function ok:DoClick()
		local val = entry:GetValue()
		overlay:Remove()
		if onConfirm and val ~= "" then onConfirm(val) end
	end
	function entry:OnEnter() ok:DoClick() end
	local cancel = vgui.Create("DButton", dlg)
	cancel:SetPos(155, 92)
	cancel:SetSize(135, 30)
	cancel:SetText("Cancel")
	function cancel:DoClick() overlay:Remove() end
end

local function VRConfirm(parent, prompt, title, onYes)
	local overlay = vgui.Create("DPanel", parent)
	overlay:SetSize(parent:GetWide(), parent:GetTall())
	overlay:SetPos(0, 0)
	overlay:MoveToFront()
	overlay:SetMouseInputEnabled(true)
	overlay.Paint = function(_, w, h)
		surface.SetDrawColor(0, 0, 0, 180)
		surface.DrawRect(0, 0, w, h)
	end
	local dlg = vgui.Create("DPanel", overlay)
	dlg:SetSize(320, 120)
	dlg:Center()
	dlg.Paint = function(_, w, h)
		draw.RoundedBox(6, 0, 0, w, h, Color(50, 50, 50))
		draw.RoundedBox(6, 0, 0, w, 26, Color(70, 70, 70))
	end
	local lbl = vgui.Create("DLabel", dlg)
	lbl:SetPos(10, 4)
	lbl:SetText(title)
	lbl:SetFont("DermaDefaultBold")
	lbl:SizeToContents()
	local lbl2 = vgui.Create("DLabel", dlg)
	lbl2:SetPos(10, 34)
	lbl2:SetSize(300, 40)
	lbl2:SetText(prompt)
	lbl2:SetWrap(true)
	lbl2:SetAutoStretchVertical(true)
	local yes = vgui.Create("DButton", dlg)
	yes:SetPos(10, 80)
	yes:SetSize(145, 30)
	yes:SetText("Yes")
	function yes:DoClick()
		overlay:Remove()
		if onYes then onYes() end
	end
	local no = vgui.Create("DButton", dlg)
	no:SetPos(165, 80)
	no:SetSize(145, 30)
	no:SetText("Cancel")
	function no:DoClick() overlay:Remove() end
end

-- Reusable preset UI builder (returns refresh function for external use)
local function BuildPresetPanel(parent, dir, cvarList)
	local form = vgui.Create("DForm", parent)
	form:SetName("Presets")
	form:Dock(TOP)
	form:DockMargin(5, 0, 5, 5)
	form:SetExpanded(true)

	local combo = vgui.Create("DComboBox")
	form:AddItem(combo)
	combo:SetValue("Select preset...")

	local function Refresh()
		if not IsValid(combo) then return end
		combo:Clear()
		combo:SetValue("Select preset...")
		for _, name in ipairs(GetPresetNames(dir)) do combo:AddChoice(name) end
	end
	Refresh()

	local loadBtn = form:Button("Load")
	function loadBtn:DoClick()
		local _, name = combo:GetSelected()
		if not name then return end
		if LoadPreset(dir, name) then
			chat.AddText(Color(100, 255, 100), "[VRMod] ", Color(255, 255, 255), "Loaded preset: " .. name)
		end
	end

	-- Inline save: text entry + button on same row
	local saveEntry = vgui.Create("DTextEntry")
	form:AddItem(saveEntry)
	saveEntry:SetPlaceholderText("Preset name...")
	local saveBtn = form:Button("Save Current Settings")
	function saveBtn:DoClick()
		local name = saveEntry:GetValue()
		if not name or name == "" then
			chat.AddText(Color(255, 100, 100), "[VRMod] ", Color(255, 255, 255), "Enter a preset name first.")
			return
		end
		name = name:gsub("[^%w_%-]", "_")
		SavePreset(dir, name, cvarList)
		Refresh()
		if IsValid(saveEntry) then saveEntry:SetValue("") end
		chat.AddText(Color(100, 255, 100), "[VRMod] ", Color(255, 255, 255), "Saved preset: " .. name)
	end

	local deleteBtn = form:Button("Delete")
	function deleteBtn:DoClick()
		local _, name = combo:GetSelected()
		if not name then return end
		DeletePreset(dir, name)
		Refresh()
		chat.AddText(Color(100, 255, 100), "[VRMod] ", Color(255, 255, 255), "Deleted preset: " .. name)
	end

	local exportBtn = form:Button("Export to Console")
	function exportBtn:DoClick()
		local lines = {}
		for _, cvar in ipairs(cvarList) do
			local cv = GetConVar(cvar)
			if cv then lines[#lines + 1] = cvar .. " " .. cv:GetString() end
		end
		local out = table.concat(lines, "\n")
		local label = dir == PRESET_DIR_SERVER and "server" or "client"
		file.Write("vrmod_export_" .. label .. ".txt", out)
		print(out)
		print("\n-- Exported " .. #lines .. " " .. label .. " convars to data/vrmod_export_" .. label .. ".txt")
		chat.AddText(Color(100, 255, 100), "[VRMod] ", Color(255, 255, 255), "Exported " .. #lines .. " " .. label .. " settings to console + data/vrmod_export_" .. label .. ".txt")
	end

	return form, Refresh
end

function VRUtilOpenMenu()
	if IsValid(frame) then return frame end
	-- Darken ControlHelp labels once (deferred until VGUI is ready)
	if not darkHelpApplied then
		local dt = vgui.GetControlTable("DForm")
		if dt and dt.ControlHelp then
			local _orig = dt.ControlHelp
			local darkColor = Color(50, 50, 50)
			dt.ControlHelp = function(self, ...)
				local lbl = _orig(self, ...)
				if IsValid(lbl) then lbl:SetColor(darkColor) end
				return lbl
			end
		end
		darkHelpApplied = true
	end

	frame = vgui.Create("DFrame")
	frame:SetSize(460, 560)
	local startupErr, errCode = vrmod.GetStartupError and vrmod.GetStartupError()
	frame:SetTitle(startupErr and ("VRMod Menu (" .. startupErr:match("^[^\n.]+") .. ")") or "VRMod Menu")
	frame:MakePopup()
	frame:Center()

	-- ── Bottom bar (version + start/exit) ──
	local bottomPanel = vgui.Create("DPanel", frame)
	bottomPanel:Dock(BOTTOM)
	bottomPanel:SetTall(35)
	bottomPanel.Paint = nil
	local versionLabel = vgui.Create("DLabel", bottomPanel)
	versionLabel:SetText("Addon version: " .. vrmod.GetVersion() .. "\nModule version: " .. vrmod.GetModuleVersion())
	versionLabel:SizeToContents()
	versionLabel:SetPos(5, 5)
	local exitBtn = vgui.Create("DButton", bottomPanel)
	exitBtn:SetText("Exit")
	exitBtn:Dock(RIGHT)
	exitBtn:DockMargin(0, 5, 0, 0)
	exitBtn:SetWide(96)
	exitBtn:SetEnabled(g_VR.active)
	function exitBtn:DoClick() frame:Remove() RunConsoleCommand("vrmod_exit") end
	local startBtn = vgui.Create("DButton", bottomPanel)
	startBtn:SetText(g_VR.active and "Restart" or "Start")
	startBtn:Dock(RIGHT)
	startBtn:DockMargin(0, 5, 5, 0)
	startBtn:SetWide(96)
	startBtn:SetEnabled(not errCode)
	-- Cold start goes through vrmod_start, which waits for the cursor to go away
	-- before anything touches render targets. Starting with this popup still up
	-- lets the module's one-shot D3D9 CreateTexture hook latch onto a VGUI
	-- texture instead of the VR RT -- and leaves the vtable patched if the start
	-- then aborts. Restart keeps the direct call: VR menus can hold the cursor
	-- visible, which would stall the concommand's poll forever.
	function startBtn:DoClick()
		frame:Remove()
		if g_VR.active then
			VRUtilClientExit()
			timer.Simple(1, VRUtilClientStart)
		else
			RunConsoleCommand("vrmod_start")
		end
	end

	surface.CreateFont("BoldSliderFont", { font = "Tahoma", size = 13, weight = 1000 })

	-- ══════════════════════════════════════════════════════════════════
	-- TOP-LEVEL TABS
	-- ══════════════════════════════════════════════════════════════════
	local topSheet = vgui.Create("DPropertySheet", frame)
	topSheet:SetPadding(1)
	topSheet:Dock(FILL)
	frame.DPropertySheet = topSheet

	-- ══════════════════════════════════════════════════════════════════
	-- CLIENT TAB (nested subtabs)
	-- ══════════════════════════════════════════════════════════════════
	local clientPanel = vgui.Create("DPanel", topSheet)
	clientPanel:Dock(FILL)
	clientPanel.Paint = nil
	local clientSheet = vgui.Create("DPropertySheet", clientPanel)
	clientSheet:SetPadding(1)
	clientSheet:Dock(FILL)
	topSheet:AddSheet("Client", clientPanel, "icon16/user.png")

	-- ─────────────── Client > General ───────────────
	do
		local t = vgui.Create("DScrollPanel", clientSheet)
		clientSheet:AddSheet("General", t, "icon16/cog.png")

		local lf = vgui.Create("DForm", t)
		lf:Dock(TOP)
		lf.Header:SetVisible(false)
		lf.Paint = nil
		lf:CheckBox("Linux mode", "vrmod_linux")
		lf:ControlHelp("Uses alternative module loading for Linux. Don't toggle this if you are on Windows. Requires VR restart.")

		-- Client presets
		BuildPresetPanel(t, PRESET_DIR_CLIENT, CLIENT_CVARS)

		local form = vgui.Create("DForm", t)
		form:SetName("General")
		form:Dock(TOP)
		form.Header:SetVisible(false)
		form.Paint = nil
		frame.SettingsForm = form

		local laser_pointer = form:CheckBox("Add laser pointer to tools/weapons")
		laser_pointer:SetChecked(GetConVar("vrmod_laserpointer"):GetBool())
		function laser_pointer:OnChange(val) RunConsoleCommand("vrmod_togglelaserpointer") end

		form:CheckBox("Use weapon world models", "vrmod_useworldmodels")
		form:ControlHelp("Requires VR restart")

		local heightCheckbox = form:CheckBox("Show height adjustment menu", "vrmod_heightmenu")
		local checkTime = 0
		function heightCheckbox:OnChange(checked)
			if checked and SysTime() - checkTime < 0.1 then VRUtilOpenHeightMenu() end
			checkTime = SysTime()
		end

		form:CheckBox("Enable seated offset", "vrmod_seated")
		form:ControlHelp("Adjust from height adjustment menu")
		form:CheckBox("Automatically start VR after map loads", "vrmod_autostart")
		form:CheckBox("Replace door use mechanics (when available)", "vrmod_doors")
		form:CheckBox("Apply server settings via ULX RCON", "vrmod_settings_rcon")
		form:ControlHelp("Sends changes to server-side settings (Server tab: teleport, pickup, melee, climbing) through 'ulx rcon' so you don't need console in VR. Requires ULX superadmin.")

		-- Menus
		local menuForm = vgui.Create("DForm", form)
		menuForm:SetName("Menus")
		menuForm:Dock(TOP)
		menuForm:DockMargin(10, 10, 10, 0)
		menuForm:SetExpanded(true)
		menuForm:CheckBox("Floating menus (stay in world)", "vrmod_menu_float")
		menuForm:ControlHelp("Menus stay where opened instead of following your hand")
		menuForm:CheckBox("Floating quick menu", "vrmod_quickmenu_float")
		menuForm:ControlHelp("Quick menu stays where opened instead of following your hand")
		local scaleRow = vgui.Create("DPanel", menuForm)
		menuForm:AddItem(scaleRow)
		scaleRow:SetTall(24)
		scaleRow.Paint = nil
		local scaleLabel = vgui.Create("DLabel", scaleRow)
		scaleLabel:SetDark(true)
		scaleLabel:Dock(FILL)
		local scaleCV = GetConVar("vrmod_menu_scale")
		local function UpdateScaleLabel() scaleLabel:SetText("Menu scale: " .. string.format("%.1f", scaleCV:GetFloat())) end
		UpdateScaleLabel()
		local scaleUp = vgui.Create("DButton", scaleRow)
		scaleUp:SetText("+")
		scaleUp:SetWide(32)
		scaleUp:Dock(RIGHT)
		function scaleUp:DoClick()
			local v = math.min(scaleCV:GetFloat() + 0.1, 2)
			RunConsoleCommand("vrmod_menu_scale", string.format("%.1f", v))
			timer.Simple(0, UpdateScaleLabel)
		end
		local scaleDown = vgui.Create("DButton", scaleRow)
		scaleDown:SetText("-")
		scaleDown:SetWide(32)
		scaleDown:Dock(RIGHT)
		scaleDown:DockMargin(0, 0, 2, 0)
		function scaleDown:DoClick()
			local v = math.max(scaleCV:GetFloat() - 0.1, 0.1)
			RunConsoleCommand("vrmod_menu_scale", string.format("%.1f", v))
			timer.Simple(0, UpdateScaleLabel)
		end
		menuForm:ControlHelp("Size of spawn/context menus (1 = default)")

		form:Button("Reset settings to default", "vrmod_reset")
	end

	-- ─────────────── Client > Controls ───────────────
	do
		local t = vgui.Create("DScrollPanel", clientSheet)
		clientSheet:AddSheet("Controls", t, "icon16/controller.png")
		local controlsPanel = vgui.Create("DForm", t)
		controlsPanel:SetName("Turning & Movement")
		controlsPanel:Dock(TOP)
		controlsPanel:DockMargin(5, 5, 5, 0)
		controlsPanel:SetExpanded(true)

		local turnRateSlider, snapAngleCombo
		local isSmooth = convars.vrmod_smoothturn:GetBool()

		local turnModeCombo = vgui.Create("DComboBox", controlsPanel)
		controlsPanel:AddItem(turnModeCombo)
		turnModeCombo:SetDark(true)
		turnModeCombo:AddChoice("Smooth Turn", true)
		turnModeCombo:AddChoice("Snap Turn", false)
		turnModeCombo:ChooseOptionID(isSmooth and 1 or 2)
		function turnModeCombo:OnSelect(_, _, val)
			convars.vrmod_smoothturn:SetBool(val)
			turnRateSlider:SetVisible(val)
			snapAngleCombo:SetVisible(not val)
		end

		turnRateSlider = vgui.Create("DNumSlider", controlsPanel)
		controlsPanel:AddItem(turnRateSlider)
		turnRateSlider:SetMin(1)
		turnRateSlider:SetMax(1000)
		turnRateSlider:SetDecimals(0)
		turnRateSlider:SetValue(convars.vrmod_smoothturnrate:GetInt())
		turnRateSlider:SetDark(true)
		turnRateSlider:SetText("Smooth turn rate")
		turnRateSlider:SetVisible(isSmooth)
		function turnRateSlider:OnValueChanged(val) convars.vrmod_smoothturnrate:SetInt(val) end

		snapAngleCombo = vgui.Create("DComboBox", controlsPanel)
		controlsPanel:AddItem(snapAngleCombo)
		snapAngleCombo:SetDark(true)
		snapAngleCombo:AddChoice("30°", 30)
		snapAngleCombo:AddChoice("45°", 45)
		snapAngleCombo:AddChoice("90°", 90)
		snapAngleCombo:ChooseOptionID(({[30]=1,[45]=2,[90]=3})[convars.vrmod_snapturnangle:GetInt()] or 2)
		snapAngleCombo:SetVisible(not isSmooth)
		function snapAngleCombo:OnSelect(_, _, val) RunConsoleCommand("vrmod_snapturnangle", val) end

		controlsPanel:NumSlider("Crouch threshold", "vrmod_crouchthreshold", 10, 60, 0)
		controlsPanel:ControlHelp("HMD height below which roomscale crouch activates (default 40)")

		local actionBtn = vgui.Create("DButton", controlsPanel)
		controlsPanel:AddItem(actionBtn)
		actionBtn:SetText("Edit custom controller input actions")
		function actionBtn:DoClick() RunConsoleCommand("vrmod_actioneditor") end

		-- Controller offsets
		local offsetForm = vgui.Create("DForm", t)
		offsetForm:SetName("Controller offsets")
		offsetForm:Dock(TOP)
		offsetForm:DockMargin(5, 5, 5, 0)
		offsetForm:SetExpanded(false)
		local function AddOffsetSlider(name, convar, mn, mx)
			local s = offsetForm:NumSlider(name, convar, mn, mx, 0)
			function s:PerformLayout() self.TextArea:SetWide(30) self.Label:SetWide(30) end
		end
		AddOffsetSlider("X", "vrmod_controlleroffset_x", -30, 30)
		AddOffsetSlider("Y", "vrmod_controlleroffset_y", -30, 30)
		AddOffsetSlider("Z", "vrmod_controlleroffset_z", -30, 30)
		AddOffsetSlider("Pitch", "vrmod_controlleroffset_pitch", -180, 180)
		AddOffsetSlider("Yaw", "vrmod_controlleroffset_yaw", -180, 180)
		AddOffsetSlider("Roll", "vrmod_controlleroffset_roll", -180, 180)
		local applyBtn = offsetForm:Button("Apply offsets", nil)
		function applyBtn:OnReleased()
			local x = convars.vrmod_controlleroffset_x:GetFloat()
			local y = convars.vrmod_controlleroffset_y:GetFloat()
			local z = convars.vrmod_controlleroffset_z:GetFloat()
			local p = convars.vrmod_controlleroffset_pitch:GetFloat()
			local yw = convars.vrmod_controlleroffset_yaw:GetFloat()
			local r = convars.vrmod_controlleroffset_roll:GetFloat()
			if g_VR then
				g_VR.rightControllerOffsetPos = Vector(x, y, z)
				g_VR.leftControllerOffsetPos = Vector(x, -y, z)
				g_VR.rightControllerOffsetAng = Angle(p, yw, r)
				g_VR.leftControllerOffsetAng = g_VR.rightControllerOffsetAng
			end
		end
		local resetBtn = offsetForm:Button("Reset offsets", "")
		function resetBtn:OnReleased()
			RunConsoleCommand("vrmod_controlleroffset_x", "-15")
			RunConsoleCommand("vrmod_controlleroffset_y", "-1")
			RunConsoleCommand("vrmod_controlleroffset_z", "5")
			RunConsoleCommand("vrmod_controlleroffset_pitch", "50")
			RunConsoleCommand("vrmod_controlleroffset_yaw", "0")
			RunConsoleCommand("vrmod_controlleroffset_roll", "0")
			if g_VR then
				g_VR.rightControllerOffsetPos = Vector(-15, -1, 5)
				g_VR.leftControllerOffsetPos = Vector(-15, 1, 5)
				g_VR.rightControllerOffsetAng = Angle(50, 0, 0)
				g_VR.leftControllerOffsetAng = Angle(50, 0, 0)
			end
		end
	end

	-- ─────────────── Client > Rendering ───────────────
	-- Dead OpenVR convars removed: renderoffset, viewscale, fovscale_x/y, scalefactor, verticaloffset, horizontaloffset
	do
		local t = vgui.Create("DScrollPanel", clientSheet)
		clientSheet:AddSheet("Rendering", t, "icon16/monitor.png")
		local form = vgui.Create("DForm", t)
		form:SetName("Rendering")
		form:Dock(TOP)
		form:DockMargin(5, 5, 5, 0)
		form:SetExpanded(true)
		form.Header:SetVisible(false)
		form.Paint = nil

		form:CheckBox("Performance convar overrides (master)", "vrmod_perfoverrides")
		form:ControlHelp("Master switch for the FPS-friendly engine overrides below. These apply the moment you tick them, on desktop as well as in VR, and stay applied after you exit. Unticking one returns that convar to its engine default rather than a value you set yourself.")
		for _, o in ipairs(vrmod.PerfOverrides or {}) do
			form:CheckBox(o.label, o.toggle)
		end

		-- Desktop view combo
		local dvCombo = form:ComboBox("Desktop view", "vrmod_desktopview")
		dvCombo:AddChoice("none", "1")
		dvCombo:AddChoice("left eye", "2")
		dvCombo:AddChoice("right eye", "3")
		local dvVal = convars.vrmod_desktopview:GetInt()
		dvCombo:ChooseOptionID(dvVal > 0 and dvVal or 1)

		form:CheckBox("Enable engine postprocessing", "vrmod_postprocess")
		form:CheckBox("3D Skybox (disable for more FPS)", "vrmod_skybox")
		form:CheckBox("Flashlight shadows", "vrmod_flashlight_shadows")
		form:ControlHelp("Lets the VR flashlight cast shadows. Free to flip, but nothing changes unless the depth texture below is on too. Takes effect on your next flashlight toggle.")
		form:CheckBox("Flashlight shadow depth texture", "vrmod_flashlight_depth")
		form:ControlHelp("Off by default: the depth pass re-renders whenever your hands or a nearby prop sit in the beam, which stutters under the threaded material queue. Changing this reallocates the depth texture and WILL freeze the game for about a second. Applies outside VR -- toggling in-headset takes effect on exit.")

		form:NumSlider("ZNear", "vrmod_znear", -3.0, 3.0, 2)
		form:ControlHelp("How close objects can be before clipping. Lower values let you see closer objects.")

		form:NumSlider("Eye distance offset", "vrmod_eyescale", 0.0, 1.0, 2)
		form:ControlHelp("Adjusts stereo eye separation. Changing this will visually affect your POV.")

		local resetBtn = form:Button("Reset Rendering Defaults")
		function resetBtn:DoClick()
			RunConsoleCommand("vrmod_postprocess", "0")
			RunConsoleCommand("vrmod_skybox", "1")
			RunConsoleCommand("vrmod_flashlight_shadows", "0")
			RunConsoleCommand("vrmod_flashlight_depth", "0")
			RunConsoleCommand("vrmod_znear", "1.0")
			RunConsoleCommand("vrmod_eyescale", "0.5")
			RunConsoleCommand("vrmod_perfoverrides", "1")
			for _, o in ipairs(vrmod.PerfOverrides or {}) do RunConsoleCommand(o.toggle, "1") end
		end

		local compat = vgui.Create("DForm", t)
		compat:SetName("Compatibility")
		compat:Dock(TOP)
		compat:DockMargin(5, 5, 5, 0)
		compat:SetExpanded(true)
		compat:CheckBox("Warn about addons that break VR", "vrmod_compat_warn")
		compat:ControlHelp("Reports render replacers such as gShader on VR start.")
		compat:CheckBox("Suppress other ShouldDrawLocalPlayer hooks", "vrmod_compat_killhooks")
		compat:ControlHelp("Thirdperson and camera addons hook ShouldDrawLocalPlayer with no priority system and silently win over VRMod, killing the body and hands. Restored on VR exit.")
		compat:CheckBox("Warn on screen when VR rendering stalls", "vrmod_compat_stallwarn")
		compat:ControlHelp("Draws a banner over the console or menu naming whatever stopped the headset updating.")
		compat:CheckBox("Show reason card in headset", "vrmod_pausecard")
		compat:ControlHelp("Paints the reason into both eyes instead of leaving the last frame frozen.")
		local compatBtn = compat:Button("Run compatibility check now")
		function compatBtn:DoClick() RunConsoleCommand("vrmod_compat") end
	end

	-- ─────────────── Client > Character ───────────────
	do
		local t = vgui.Create("DScrollPanel", clientSheet)
		clientSheet:AddSheet("Character", t, "icon16/user_edit.png")

		local charForm = vgui.Create("DForm", t)
		charForm:SetName("Appearance")
		charForm:Dock(TOP)
		charForm:DockMargin(5, 5, 5, 0)
		charForm:SetExpanded(true)
		charForm.Header:SetVisible(false)
		charForm.Paint = nil
		charForm:CheckBox("Use floating hands", "vrmod_floatinghands")
		charForm:ControlHelp("Use floating hand models instead of the full player body.")

		local animSection = vgui.Create("DForm", t)
		animSection:SetName("Animations")
		animSection:Dock(TOP)
		animSection:DockMargin(5, 5, 5, 0)
		animSection:SetExpanded(true)
		local animCheckbox = animSection:CheckBox("Disable Animations")
		animCheckbox:SetChecked(not GetConVar("vrmod_characterik"):GetBool())
		function animCheckbox:OnChange(val) RunConsoleCommand("vrmod_characterik", val and "0" or "1") end
		animSection:ControlHelp("When checked, the player model stays in place without animations.")
		animSection:CheckBox("Enable Arm Stretcher", "vrmod_armstretcher")
		animSection:ControlHelp("Stretches arm bones to reach targets beyond the model's natural arm length.")
		animSection:NumSlider("Body Yaw Source", "vrmod_characteryawblend", 1, 2, 1)
		animSection:ControlHelp("1 = head direction only, 2 = arm direction only. Blend in between.")
		local headAngleBox = vgui.Create("DCheckBoxLabel", animSection)
		animSection:AddItem(headAngleBox)
		headAngleBox:SetDark(true)
		headAngleBox:SetText("Alternative head angles (jigglebone compat)")
		headAngleBox:SetChecked(convars.vrmod_althead:GetBool())
		function headAngleBox:OnChange(val) convars.vrmod_althead:SetBool(val) end
		animSection:ControlHelp("Less precise head tracking, fixes jigglebones on some models.")
		animSection:CheckBox("Auto-detect jigglebone models", "vrmod_althead_auto")
		animSection:ControlHelp("Turns the above on by itself for any playermodel with more than one bone parented to the head (hair, ears, hats).")
		animSection:NumSlider("FBT Leg Influence", "vrmod_fbt_leginfluence", 0, 1, 2)
		animSection:ControlHelp("How much the foot trackers rotate the legs while walking. 0 = animation only, 1 = full FBT.")
		animSection:CheckBox("FBT: Animate Shoulders", "vrmod_fbt_animshoulders")
		animSection:ControlHelp("When checked, the walk animation also swings the shoulders during FBT.")
		animSection:NumSlider("Sit Height", "vrmod_sitheight", 0, 60, 0)
		animSection:ControlHelp("Head height above feet at/below which the sit animation plays. 0 disables. Default 40.")
		animSection:NumSlider("Sit: HMD to Body Distance", "vrmod_sitheadtohmddist", 0, 20, 1)
		animSection:ControlHelp("How far behind the HMD the body sits while sitting. Default 0.")
		animSection:NumSlider("Prone Height", "vrmod_proneheight", 0, 60, 0)
		animSection:ControlHelp("Head height above feet at/below which the prone animation plays. 0 disables. Default 15. Requires the [wOS] Animation Extension - Prone Mod addon; without it, sitting is used instead.")
		animSection:NumSlider("Prone: HMD to Body Distance", "vrmod_proneheadtohmddist", 0, 40, 1)
		animSection:ControlHelp("How far behind the HMD the body lies while prone. Default 26. Requires the [wOS] Animation Extension - Prone Mod addon.")

		local calibSection = vgui.Create("DForm", t)
		calibSection:SetName("Model Calibration")
		calibSection:Dock(TOP)
		calibSection:DockMargin(5, 5, 5, 0)
		calibSection:SetExpanded(true)
		calibSection:NumSlider("Eye Height", "vrmod_charactereyeheight", 30, 100, 1)
		calibSection:ControlHelp("Character eye height in source units. Default 66.8.")
		calibSection:NumSlider("Head to HMD Distance", "vrmod_characterheadtohmddist", 0, 20, 1)
		calibSection:ControlHelp("Distance from HMD to head bone. Default 6.3.")
		local charRestoreBtn = calibSection:Button("Restore Character Defaults")
		function charRestoreBtn:DoClick()
			RunConsoleCommand("vrmod_characterik", "1")
			RunConsoleCommand("vrmod_armstretcher", "0")
			RunConsoleCommand("vrmod_charactereyeheight", "66.8")
			RunConsoleCommand("vrmod_characterheadtohmddist", "6.3")
			RunConsoleCommand("vrmod_characteryawblend", "1.5")
			RunConsoleCommand("vrmod_fbt_leginfluence", "1")
			RunConsoleCommand("vrmod_fbt_animshoulders", "1")
			RunConsoleCommand("vrmod_sitheight", "40")
			RunConsoleCommand("vrmod_sitheadtohmddist", "0")
			RunConsoleCommand("vrmod_proneheight", "15")
			RunConsoleCommand("vrmod_proneheadtohmddist", "26")
			chat.AddText(Color(100, 255, 100), "[VR Character] ", Color(255, 255, 255), "Settings reset to defaults!")
		end

		-- Per-playermodel Presets
		local presetForm = vgui.Create("DForm", t)
		presetForm:SetName("Per-Model Presets")
		presetForm:Dock(TOP)
		presetForm:DockMargin(5, 5, 5, 0)
		presetForm:SetExpanded(true)
		local presets = vrmod.characterPresets
		local statusLabel = vgui.Create("DLabel", presetForm)
		statusLabel:SetDark(true)
		statusLabel:SetWrap(true)
		statusLabel:SetAutoStretchVertical(true)
		presetForm:AddItem(statusLabel)
		local function RefreshStatus()
			if not IsValid(statusLabel) or not presets then return end
			local model = presets.GetCurrentModel and presets.GetCurrentModel()
			local total = presets.Count and presets.Count() or 0
			local lines = {}
			if model then
				lines[#lines + 1] = "Current model: " .. model
				lines[#lines + 1] = presets.Has(model) and "Saved preset: YES (auto-loads on model change)" or "Saved preset: no (will save on first change)"
			else
				lines[#lines + 1] = "Current model: (unknown — start VR to detect)"
			end
			lines[#lines + 1] = "Total saved presets: " .. total
			statusLabel:SetText(table.concat(lines, "\n"))
		end
		RefreshStatus()
		local lastRefresh = 0
		function presetForm:Think()
			if CurTime() - lastRefresh < 0.5 then return end
			lastRefresh = CurTime()
			RefreshStatus()
		end
		local clearBtn = presetForm:Button("Clear preset for current model")
		function clearBtn:DoClick()
			if not presets or not presets.GetCurrentModel then return end
			local model = presets.GetCurrentModel()
			if not model then chat.AddText(Color(255, 100, 100), "[VR Character] ", Color(255, 255, 255), "No active model detected.") return end
			VRConfirm(frame, "Clear calibration for " .. model .. " and reset to defaults?", "Clear Preset", function()
				presets.ClearCurrent(model)
				chat.AddText(Color(100, 255, 100), "[VR Character] ", Color(255, 255, 255), "Cleared preset for " .. model)
				RefreshStatus()
			end)
		end
		local clearAllBtn = presetForm:Button("Clear ALL saved presets")
		function clearAllBtn:DoClick()
			if not presets then return end
			VRConfirm(frame, "Delete every saved per-model preset? This cannot be undone.", "Clear All Presets", function()
				presets.ClearAll()
				chat.AddText(Color(100, 255, 100), "[VR Character] ", Color(255, 255, 255), "All presets cleared.")
				RefreshStatus()
			end)
		end
		presetForm:ControlHelp("Calibration is saved per playermodel. Changing models auto-loads the matching preset.")

		-- Bone Hider
		local boneSection = vgui.Create("DForm", t)
		boneSection:SetName("Bone Hider")
		boneSection:Dock(TOP)
		boneSection:DockMargin(5, 5, 5, 0)
		boneSection:SetExpanded(true)
		boneSection:ControlHelp("Hide individual bones on your playermodel. Saved per model.")
		boneSection:CheckBox("Also hide bones parented under hidden bones", "vrmod_bonehider_children")
		local boneBtn = boneSection:Button("Open Bone Hider")
		function boneBtn:DoClick()
			if vrmod.boneHider then vrmod.boneHider.OpenPanel() end
		end

		-- Bone Scaler
		local scaleSection = vgui.Create("DForm", t)
		scaleSection:SetName("Bone Scaler")
		scaleSection:Dock(TOP)
		scaleSection:DockMargin(5, 5, 5, 0)
		scaleSection:SetExpanded(true)
		scaleSection:ControlHelp("Scale individual bones on your playermodel. Saved per model.")
		scaleSection:CheckBox("Also scale bones parented under scaled bones", "vrmod_bonescaler_children")
		local scaleBtn = scaleSection:Button("Open Bone Scaler")
		function scaleBtn:DoClick()
			if vrmod.boneScaler then vrmod.boneScaler.OpenPanel() end
		end
	end

	-- ─────────────── Client > Holster ───────────────
	do
		local POUCH_SLOTS = 4
		local holsterPositions = {
			{ part = "Head",  side = "Right"  },
			{ part = "Head",  side = "Left"   },
			{ part = "Chest", side = "Right"  },
			{ part = "Chest", side = "Left"   },
		}
		local t = vgui.Create("DScrollPanel", clientSheet)
		clientSheet:AddSheet("Holster", t, "icon16/briefcase.png")

		local settingsForm = vgui.Create("DForm", t)
		settingsForm:SetName("Holster Settings")
		settingsForm:Dock(TOP)
		settingsForm:DockMargin(5, 5, 5, 0)
		settingsForm:SetExpanded(true)
		settingsForm:CheckBox("Enable Holster System", "vrmod_pouch_enabled")
		settingsForm:CheckBox("Show Entity Names (world)", "vrmod_pouch_visiblename")
		settingsForm:CheckBox("Show Entity Names (hud)", "vrmod_pouch_visiblename_hud")
		settingsForm:CheckBox("Enable Left Hand Weapon Holster", "vrmod_pouch_lefthandwep_enable")
		settingsForm:CheckBox("Show Holstered Weapon Models", "vrmod_holster_showmodels")
		settingsForm:NumSlider("Chest Holster Height Offset", "vrmod_pouch_chest_z", -30, 30, 1)
		settingsForm:NumSlider("Prop Max Volume (0=no limit)", "vrmod_holster_prop_maxvolume", 0, 50000, 0)
		settingsForm:ControlHelp("Props with OBB volume above this are rejected. Ragdolls bypass this limit.")
		settingsForm:CheckBox("Allow Holstering Ragdolls", "vrmod_holster_ragdolls")
		settingsForm:CheckBox("Show Ragdoll Models on Holster", "vrmod_holster_ragdoll_models")
		settingsForm:CheckBox("Persist Holster Across Map Changes", "vrmod_holster_persist")

		local modelForm = vgui.Create("DForm", t)
		modelForm:SetName("Holster Model")
		modelForm:Dock(TOP)
		modelForm:DockMargin(5, 5, 5, 0)
		modelForm:SetExpanded(true)
		modelForm:CheckBox("Show Holster Model", "vrmod_holster_model_enabled")
		modelForm:ControlHelp("Draws a model at the centre of every grip point. Off frees the model but keeps the path below.")
		modelForm:TextEntry("Model", "vrmod_holster_model")
		modelForm:ControlHelp("Defaults to the CS:S holster, which GMod mounts by default.")
		for s = 1, POUCH_SLOTS do
			modelForm:CheckBox("Draw on " .. holsterPositions[s].part .. " (" .. holsterPositions[s].side .. ")", "vrmod_holster_model_slot" .. s)
		end
		modelForm:NumSlider("Forward offset", "vrmod_holster_model_x", -32, 32, 1)
		modelForm:NumSlider("Sideways offset", "vrmod_holster_model_y", -32, 32, 1)
		modelForm:NumSlider("Vertical offset", "vrmod_holster_model_z", -32, 32, 1)
		modelForm:NumSlider("Pitch", "vrmod_holster_model_p", -180, 180, 0)
		modelForm:NumSlider("Yaw", "vrmod_holster_model_yaw", -180, 180, 0)
		modelForm:ControlHelp("Rotation is applied on top of your body yaw, so the holster turns with you.")
		modelForm:NumSlider("Roll", "vrmod_holster_model_r", -180, 180, 0)
		local hmReset = modelForm:Button("Reset Holster Model")
		function hmReset:DoClick()
			RunConsoleCommand("vrmod_holster_model_enabled", "1")
			RunConsoleCommand("vrmod_holster_model", "models/weapons/w_eq_eholster.mdl")
			for s = 1, POUCH_SLOTS do RunConsoleCommand("vrmod_holster_model_slot" .. s, "1") end
			for _, s in ipairs({"x", "y", "z", "p", "yaw", "r"}) do RunConsoleCommand("vrmod_holster_model_" .. s, "0") end
		end

		local sizeForm = vgui.Create("DForm", t)
		sizeForm:SetName("Holster Sizes")
		sizeForm:Dock(TOP)
		sizeForm:DockMargin(5, 5, 5, 0)
		sizeForm:SetExpanded(true)
		for i = 1, POUCH_SLOTS do
			sizeForm:NumSlider(holsterPositions[i].part .. " (" .. holsterPositions[i].side .. ")", "vrmod_pouch_size_" .. i, 1, 100, 0)
		end

		local slotForm = vgui.Create("DForm", t)
		slotForm:SetName("Weapon Slots")
		slotForm:Dock(TOP)
		slotForm:DockMargin(5, 5, 5, 0)
		slotForm:SetExpanded(true)
		for i = 1, POUCH_SLOTS do
			slotForm:TextEntry(holsterPositions[i].part .. " (" .. holsterPositions[i].side .. ")", "vrmod_pouch_weapon_" .. i)
		end
	end

	-- ─────────────── Client > HUD/UI ───────────────
	do
		local t = vgui.Create("DScrollPanel", clientSheet)
		clientSheet:AddSheet("HUD/UI", t, "icon16/layers.png")

		local function AddSl(lbl, cv, mn, mx, dec, py)
			local s = vgui.Create("DNumSlider", t)
			s:SetPos(20, py)
			s:SetSize(370, 25)
			s:SetDark(true)
			s:SetText(lbl)
			s:SetMin(mn)
			s:SetMax(mx)
			s:SetDecimals(dec)
			s:SetConVar(cv)
		end

		local cY = 10
		local cb = t:Add("DCheckBoxLabel")
		cb:SetPos(20, cY)
		cb:SetDark(true)
		cb:SetText("Enable HUD")
		cb:SetConVar("vrmod_hud")
		cb:SizeToContents()
		AddSl("HUD Curve", "vrmod_hudcurve", -100, 100, 0, 30)
		AddSl("HUD Distance", "vrmod_huddistance", 1, 100, 0, 55)
		AddSl("HUD Scale", "vrmod_hudscale", 0.01, 0.1, 2, 80)
		AddSl("HUD Transparency", "vrmod_hudtestalpha", 0, 255, 0, 105)
		cY = 135
		local cb2 = t:Add("DCheckBoxLabel")
		cb2:SetPos(20, cY)
		cb2:SetDark(true)
		cb2:SetText("HUD only while pressing menu key")
		cb2:SetConVar("vrmod_hud_visible_quickmenukey")
		cb2:SizeToContents()
		cY = 165
		local cb3 = t:Add("DCheckBoxLabel")
		cb3:SetPos(20, cY)
		cb3:SetDark(true)
		cb3:SetText("[Menu & UI Red Outline]")
		cb3:SetConVar("vrmod_ui_outline")
		cb3:SizeToContents()

		-- Font selector
		local fontLabel = t:Add("DLabel")
		fontLabel:SetPos(20, 185)
		fontLabel:SetDark(true)
		fontLabel:SetText("Weapon Menu Font")
		fontLabel:SizeToContents()
		local fontDropdown = vgui.Create("DComboBox", t)
		fontDropdown:SetPos(160, 185)
		fontDropdown:SetSize(200, 20)
		local hudFonts = {"Trebuchet MS", "Arial", "Verdana", "Tahoma", "Roboto", "Courier New", "Impact"}
		for _, f in ipairs(hudFonts) do fontDropdown:AddChoice(f) end
		fontDropdown:SetValue(GetConVar("vrmod_hud_font") and GetConVar("vrmod_hud_font"):GetString() or "Trebuchet MS")
		fontDropdown.OnSelect = function(_, _, val) RunConsoleCommand("vrmod_hud_font", val) end

		-- Color selector
		local modeDropdown = vgui.Create("DComboBox", t)
		modeDropdown:SetPos(20, 210)
		modeDropdown:SetSize(200, 30)
		modeDropdown:SetValue("Beam Color")
		modeDropdown:AddChoice("Beam Color")
		modeDropdown:AddChoice("Laser Color")
		modeDropdown:AddChoice("HUD Color")
		local mixer = vgui.Create("DColorMixer", t)
		mixer:SetPos(20, 245)
		mixer:SetSize(360, 200)
		mixer:SetPalette(true)
		mixer:SetAlphaBar(true)
		mixer:SetWangs(true)
		local function updateMixerColor()
			local selection = modeDropdown:GetValue()
			local convar
			if selection == "HUD Color" then convar = GetConVar("vrmod_hud_color")
			elseif selection == "Laser Color" then convar = convars.vrmod_laser_color
			else convar = convars.vrmod_beam_color end
			if not convar then return end
			local str = convar:GetString()
			local r, g, b, a = string.match(str, "(%d+),(%d+),(%d+),(%d+)")
			if r and g and b and a then mixer:SetColor(Color(tonumber(r), tonumber(g), tonumber(b), tonumber(a))) end
		end
		updateMixerColor()
		modeDropdown.OnSelect = function(_, _, value) updateMixerColor() end
		mixer.ValueChanged = function(_, col)
			local selection = modeDropdown:GetValue()
			local cvarName = selection == "HUD Color" and "vrmod_hud_color"
				or selection == "Laser Color" and "vrmod_laser_color"
				or "vrmod_beam_color"
			RunConsoleCommand(cvarName, string.format("%d,%d,%d,%d", col.r, col.g, col.b, col.a))
		end

		local btn2 = vgui.Create("DButton", t)
		btn2:SetText("Set Defaults")
		btn2:SetPos(190, 475)
		btn2:SetSize(160, 30)
		btn2.DoClick = function()
			RunConsoleCommand("vrmod_hud", "1")
			RunConsoleCommand("vrmod_hudmode", "0")
			RunConsoleCommand("vrmod_hudcurve", "60")
			RunConsoleCommand("vrmod_huddistance", "60")
			RunConsoleCommand("vrmod_hudscale", "0.05")
			RunConsoleCommand("vrmod_hudtestalpha", "0")
			RunConsoleCommand("vrmod_hudblacklist", "")
			RunConsoleCommand("vrmod_hud_visible_quickmenukey", "0")
			RunConsoleCommand("vrmod_beam_color", "203,109,109,255")
			RunConsoleCommand("vrmod_laser_color", "255,0,0,255")
			RunConsoleCommand("vrmod_hud_color", "255,250,0,255")
			RunConsoleCommand("vrmod_hud_font", "Trebuchet MS")
			RunConsoleCommand("vrmod_hudattach", "0")
			RunConsoleCommand("vrmod_hudarmscale", "0.05")
			RunConsoleCommand("vrmod_hudcrt", "0.15")
			RunConsoleCommand("vrmod_hudarm_x", "5")
			RunConsoleCommand("vrmod_hudarm_y", "-3")
			RunConsoleCommand("vrmod_hudarm_z", "1")
			RunConsoleCommand("vrmod_hudarm_p", "0")
			RunConsoleCommand("vrmod_hudarm_yaw", "180")
			RunConsoleCommand("vrmod_hudarm_r", "90")
		end

		-- Arm HUD Section
		local armSpacer = vgui.Create("DPanel", t)
		armSpacer:Dock(TOP)
		armSpacer:SetTall(525)
		armSpacer.Paint = nil
		armSpacer:SetMouseInputEnabled(false)

		local armSection = vgui.Create("DForm", t)
		armSection:SetName("Arm HUD")
		armSection:Dock(TOP)
		armSection:DockMargin(5, 5, 5, 5)
		armSection:SetExpanded(true)

		local hudModeCombo = armSection:ComboBox("HUD Placement", "vrmod_hudmode")
		hudModeCombo:AddChoice("Front (default)", "0")
		hudModeCombo:AddChoice("Left Arm", "1")
		hudModeCombo:AddChoice("Right Arm", "2")
		local curMode = GetConVar("vrmod_hudmode")
		local curModeVal = curMode and curMode:GetString() or "0"
		if curModeVal == "1" then hudModeCombo:ChooseOptionID(2)
		elseif curModeVal == "2" then hudModeCombo:ChooseOptionID(3)
		else hudModeCombo:ChooseOptionID(1) end

		local hudAttachCombo = armSection:ComboBox("Attach To", "vrmod_hudattach")
		hudAttachCombo:AddChoice("Forearm (bone)", "0")
		hudAttachCombo:AddChoice("Hand (controller)", "1")
		local curAttach = GetConVar("vrmod_hudattach")
		local curAttachVal = curAttach and curAttach:GetString() or "0"
		if curAttachVal == "1" then hudAttachCombo:ChooseOptionID(2)
		else hudAttachCombo:ChooseOptionID(1) end
		armSection:ControlHelp("Forearm tracks the player model's arm bone. Hand tracks the VR controller directly.")
		armSection:NumSlider("Arm HUD Scale", "vrmod_hudarmscale", 0.01, 0.15, 4)
		armSection:NumSlider("CRT Distortion", "vrmod_hudcrt", 0, 0.5, 2)
		armSection:ControlHelp("Barrel distortion for arm HUD. 0 = flat.")
		armSection:NumSlider("Offset X (along arm)", "vrmod_hudarm_x", -20, 20, 2)
		armSection:NumSlider("Offset Y (left/right)", "vrmod_hudarm_y", -20, 20, 2)
		armSection:NumSlider("Offset Z (up/down)", "vrmod_hudarm_z", -20, 20, 2)
		armSection:NumSlider("Pitch", "vrmod_hudarm_p", -180, 180, 1)
		armSection:NumSlider("Yaw", "vrmod_hudarm_yaw", -180, 180, 1)
		armSection:NumSlider("Roll", "vrmod_hudarm_r", -180, 180, 1)
		local interactCombo = armSection:ComboBox("Interactive Button", "vrmod_hudinteract")
		interactCombo:AddChoice("Reload", "0")
		interactCombo:AddChoice("Quick Menu", "1")
		interactCombo:AddChoice("Disabled", "2")
		local curInteract = GetConVar("vrmod_hudinteract")
		local curInteractVal = curInteract and curInteract:GetString() or "0"
		if curInteractVal == "1" then interactCombo:ChooseOptionID(2)
		elseif curInteractVal == "2" then interactCombo:ChooseOptionID(3)
		else interactCombo:ChooseOptionID(1) end
		armSection:ControlHelp("Hold this button to activate the HUD pointer. Set to Disabled to turn off.")
		local armRestoreBtn = armSection:Button("Restore Arm HUD Defaults")
		function armRestoreBtn:DoClick()
			RunConsoleCommand("vrmod_hudmode", "0")
			RunConsoleCommand("vrmod_hudattach", "0")
			RunConsoleCommand("vrmod_hudarmscale", "0.05")
			RunConsoleCommand("vrmod_hudcrt", "0.15")
			RunConsoleCommand("vrmod_hudarm_x", "5")
			RunConsoleCommand("vrmod_hudarm_y", "-3")
			RunConsoleCommand("vrmod_hudarm_z", "1")
			RunConsoleCommand("vrmod_hudarm_p", "0")
			RunConsoleCommand("vrmod_hudarm_yaw", "180")
			RunConsoleCommand("vrmod_hudarm_r", "90")
			RunConsoleCommand("vrmod_hudinteract", "0")
		end

		-- Show/hide arm-specific controls based on mode
		local armSpecificItems = {}
		local function GatherArmItems()
			table.Empty(armSpecificItems)
			local children = armSection:GetChildren()
			local editableItems = {}
			for _, child in ipairs(children) do
				if child:GetClassName() == "EditablePanel" or child:GetClassName() == "DPanel" then
					editableItems[#editableItems + 1] = child
				end
			end
			local hideEnd = #editableItems - 3
			for i = 2, hideEnd do
				if editableItems[i] then armSpecificItems[#armSpecificItems + 1] = editableItems[i] end
			end
		end
		local function UpdateArmControlsVisibility()
			if #armSpecificItems == 0 then GatherArmItems() end
			local modeCV = GetConVar("vrmod_hudmode")
			local m = modeCV and modeCV:GetInt() or 0
			local isArm = (m == 1 or m == 2)
			for _, item in ipairs(armSpecificItems) do item:SetVisible(isArm) end
			armSection:InvalidateLayout(true)
			t:InvalidateLayout(true)
		end
		hudModeCombo.OnSelect = function(self, idx, val, data)
			RunConsoleCommand("vrmod_hudmode", data)
			timer.Simple(0.05, UpdateArmControlsVisibility)
		end
		timer.Simple(0.1, UpdateArmControlsVisibility)
	end

	-- ─────────────── Client > Gameplay ───────────────
	do
		local t = vgui.Create("DScrollPanel", clientSheet)
		clientSheet:AddSheet("Gameplay", t, "icon16/joystick.png")
		local form = vgui.Create("DForm", t)
		form:SetName("Client Gameplay")
		form:Dock(TOP)
		form:DockMargin(5, 5, 5, 0)
		form:SetExpanded(true)
		form.Header:SetVisible(false)
		form.Paint = nil

		form:CheckBox("Disable Pickup", "vr_pickup_disable_client")
		form:CheckBox("Enable wall collisions", "vrmod_collisions")
		form:CheckBox("Drop weapon on grip release", "vrmod_weapondrop_enable")
		form:NumSlider("Grip release threshold %", "vrmod_weapondrop_release", 5, 90, 0)
		form:ControlHelp("Weapon drops when grip squeeze falls below this percent. Lower = must let go more fully before it drops")
		form:CheckBox("Manual item pickup", "vrmod_manualpickups")
		form:CheckBox("Interactive buttons", "vrmod_interactive_buttons")
		form:CheckBox("Replace weapons with ArcVR on pickup", "vrmod_weapon_swap")
		form:CheckBox("Show Pickup halos", "vrmod_pickup_halos")
		form:CheckBox("Disable forced crouch jump", "vrmod_nocrouchjump")
		form:CheckBox("Ragdoll death", "vrmod_deathcam_ragdoll")
		form:CheckBox("Ragdoll death follows rotation of head", "vrmod_deathcam_ragdoll_view")
		form:CheckBox("Teleportation", "vrmod_allow_teleport_client")
		form:CheckBox("Use Left hand for Teleportation", "vrmod_teleport_use_left")

		-- Weapon menu style
		local wmCombo = form:ComboBox("Weapon menu style", "vrmod_weaponmenu_style")
		wmCombo:AddChoice("Radial Wheel", "0")
		wmCombo:AddChoice("Legacy HL2 Grid", "1")
		local wmVal = GetConVar("vrmod_weaponmenu_style")
		wmCombo:ChooseOptionID((wmVal and wmVal:GetInt() or 0) + 1)

		-- Menu hand
		if not ConVarExists("vrmod_menu_hand") then CreateClientConVar("vrmod_menu_hand", "0", true, false, "Which hand menus spawn on", 0, 1) end
		local mhCombo = form:ComboBox("Menu hand", "vrmod_menu_hand")
		mhCombo:AddChoice("Right Hand", "0")
		mhCombo:AddChoice("Left Hand", "1")
		mhCombo:ChooseOptionID((GetConVar("vrmod_menu_hand"):GetInt() or 0) + 1)

		-- Pointer hand
		local phCombo = form:ComboBox("Pointer hand", "vrmod_pointer_hand")
		phCombo:AddChoice("Right Hand", "0")
		phCombo:AddChoice("Left Hand", "1")
		phCombo:ChooseOptionID((GetConVar("vrmod_pointer_hand"):GetInt() or 0) + 1)

		-- Flashlight
		if not ConVarExists("vrmod_flashlight_attachment") then CreateClientConVar("vrmod_flashlight_attachment", "0", true, false, "Flashlight source: 0=Right Hand, 1=Left Hand, 2=Head") end
		local flCombo = form:ComboBox("Flashlight attachment", "vrmod_flashlight_attachment")
		flCombo:SetSortItems(false)
		flCombo:AddChoice("Right Hand", "0")
		flCombo:AddChoice("Left Hand", "1")
		flCombo:AddChoice("Head", "2")
		local flCV = GetConVar("vrmod_flashlight_attachment")
		flCombo:ChooseOptionID((flCV and flCV:GetInt() or 0) + 1)

		-- Two-handed grip aim (foregrip.lua)
		form:NumSlider("Foregrip aim smoothing", "vrmod_foregrip_smooth", 0, 30, 0)
		form:ControlHelp("Filters two-handed aim jitter. Higher = snappier, 0 = off (raw)")
		form:NumSlider("Virtual stock blend", "vrmod_foregrip_stock", 0, 1, 2)
		form:ControlHelp("Blends aim toward a shoulder pivot while the gun hand is shouldered. 0 = off")
		form:NumSlider("Stock engage distance", "vrmod_foregrip_stock_dist", 4, 20, 0)
		form:ControlHelp("How close the gun hand must be to the shoulder to engage the stock")

		local adjustBtn = form:Button("Weapon Fixer")
		function adjustBtn:DoClick() frame:Close() RunConsoleCommand("vrmod_weaponfix_menu") end

		local resetBtn = form:Button("Reset Client Gameplay Defaults")
		function resetBtn:DoClick()
			RunConsoleCommand("vrmod_allow_teleport_client", "0")
			RunConsoleCommand("vr_pickup_disable_client", "0")
			RunConsoleCommand("vrmod_weapondrop_enable", "1")
			RunConsoleCommand("vrmod_weapondrop_release", "40")
			RunConsoleCommand("vrmod_manualpickups", "1")
			RunConsoleCommand("vrmod_interactive_buttons", "1")
			RunConsoleCommand("vrmod_weapon_swap", "1")
			RunConsoleCommand("vrmod_pickup_halos", "1")
			RunConsoleCommand("vrmod_collisions", "1")
			RunConsoleCommand("vrmod_weaponmenu_style", "0")
			RunConsoleCommand("vrmod_foregrip_smooth", "0")
			RunConsoleCommand("vrmod_foregrip_stock", "0")
			RunConsoleCommand("vrmod_foregrip_stock_dist", "10")
			RunConsoleCommand("vrmod_menu_hand", "0")
			RunConsoleCommand("vrmod_pointer_hand", "0")
		end
	end

	-- ─────────────── Client > Melee ───────────────
	do
		local t = vgui.Create("DScrollPanel", clientSheet)
		clientSheet:AddSheet("Melee", t, "icon16/asterisk_orange.png")
		local form = vgui.Create("DForm", t)
		form:SetName("Melee (Client)")
		form:Dock(TOP)
		form:DockMargin(5, 5, 5, 0)
		form:SetExpanded(true)
		form:CheckBox("Enable melee", "cl_vrmod_melee")
		form:CheckBox("Enable kicking", "cl_vrmod_kick")
		form:CheckBox("Enable headbutting", "cl_vrmod_headbutt")
	end

	-- ─────────────── Client > Vehicles ───────────────
	do
		local t = vgui.Create("DScrollPanel", clientSheet)
		clientSheet:AddSheet("Vehicles", t, "icon16/car.png")
		local form = vgui.Create("DForm", t)
		form:SetName("Motion Driving")
		form:Dock(TOP)
		form:DockMargin(5, 5, 5, 0)
		form:SetExpanded(true)
		form:NumSlider("Pitch Sensitivity", "vrmod_sens_pitch", 0, 5, 2)
		form:NumSlider("Pitch Smooth", "vrmod_sens_pitch_smooth", 0, 1, 2)
		form:NumSlider("Yaw Sensitivity", "vrmod_sens_yaw", 0, 5, 2)
		form:NumSlider("Yaw Smooth", "vrmod_sens_yaw_smooth", 0, 1, 2)
		form:NumSlider("Roll Sensitivity", "vrmod_sens_roll", 0, 5, 2)
		form:NumSlider("Roll Smooth", "vrmod_sens_roll_smooth", 0, 1, 2)
		form:NumSlider("Car Steering Sensitivity", "vrmod_sens_steer_car", 0, 5, 2)
		form:NumSlider("Car Steering Smooth", "vrmod_sens_steer_car_smooth", 0, 1, 2)
		form:NumSlider("Car Rotation Range", "vrmod_rot_range_car", 0, 1080, 0)
		form:NumSlider("Motorcycle Steering Sensitivity", "vrmod_sens_steer_motorcycle", 0, 5, 2)
		form:NumSlider("Motorcycle Steering Smooth", "vrmod_sens_steer_motorcycle_smooth", 0, 1, 2)
		form:NumSlider("Motorcycle Rotation Range", "vrmod_rot_range_motorcycle", 0, 1080, 0)
		local resetBtn = form:Button("Reset Defaults")
		function resetBtn:DoClick()
			RunConsoleCommand("vrmod_sens_pitch", "1.5")
			RunConsoleCommand("vrmod_sens_pitch_smooth", "0.1")
			RunConsoleCommand("vrmod_sens_yaw", "1.25")
			RunConsoleCommand("vrmod_sens_yaw_smooth", "0.1")
			RunConsoleCommand("vrmod_sens_roll", "0.15")
			RunConsoleCommand("vrmod_sens_roll_smooth", "0.1")
			RunConsoleCommand("vrmod_sens_steer_car", "0.75")
			RunConsoleCommand("vrmod_sens_steer_car_smooth", "0.154")
			RunConsoleCommand("vrmod_rot_range_car", "900")
			RunConsoleCommand("vrmod_sens_steer_motorcycle", "0.30")
			RunConsoleCommand("vrmod_sens_steer_motorcycle_smooth", "0.15")
			RunConsoleCommand("vrmod_rot_range_motorcycle", "360")
		end

		local entry = vgui.Create("DForm", t)
		entry:SetName("Getting In and Out")
		entry:Dock(TOP)
		entry:DockMargin(5, 5, 5, 0)
		entry:SetExpanded(true)
		entry:CheckBox("Grip a seat to get in", "vrmod_vehicle_gripenter")
		entry:ControlHelp("Replaces aiming at a vehicle and pressing use. While this is on, a hand within reach of a seat can't physics-grab it.")
		entry:NumSlider("Grip Amount", "vrmod_vehicle_gripamount", 5, 100, 0)
		entry:ControlHelp("How far the grip has to close, in percent, before it seats you. Needs a controller that reports analog grip.")
		entry:NumSlider("Grip Reach", "vrmod_vehicle_gripdist", 2, 60, 0)
		entry:ControlHelp("How close the hand must be to the seat's surface, in units.")
		entry:CheckBox("Sit down to get in", "vrmod_vehicle_sitenter")
		entry:ControlHelp("Physically sitting while stood on top of a seat puts you in it. Uses the Sit Height set under Character, and is skipped entirely while seated offset is on.")
		entry:CheckBox("Stand up to get out", "vrmod_vehicle_sitexit")
		local entryReset = entry:Button("Reset Defaults")
		function entryReset:DoClick()
			RunConsoleCommand("vrmod_vehicle_gripenter", "1")
			RunConsoleCommand("vrmod_vehicle_gripamount", "75")
			RunConsoleCommand("vrmod_vehicle_gripdist", "20")
			RunConsoleCommand("vrmod_vehicle_sitenter", "1")
			RunConsoleCommand("vrmod_vehicle_sitexit", "1")
		end
	end

	-- ─────────────── Client > Climbing ───────────────
	do
		local t = vgui.Create("DScrollPanel", clientSheet)
		clientSheet:AddSheet("Climbing", t, "icon16/arrow_up.png")
		local f = vgui.Create("DForm", t)
		f:SetName("Brush Climbing")
		f:Dock(TOP)
		f:DockMargin(5, 5, 5, 0)
		f:CheckBox("Enable climbing", "vrmod_brushclimb")
		f:CheckBox("Require grip + trigger", "vrmod_brushclimb_requireboth")
		f:ControlHelp("Both grip and trigger must be held on a hand to grab walls")
		f:CheckBox("Block floor grabs", "vrmod_brushclimb_nofloor")
		f:ControlHelp("Prevent grabbing walkable surfaces (floors, ramps)")
		f:CheckBox("Grab magnet", "vrmod_brushclimb_magnet")
		f:ControlHelp("Snap hand to wall surface when grabbing")
		f:NumSlider("Magnet offset", "vrmod_brushclimb_magnet_offset", 0, 8, 1)
		f:ControlHelp("Palm distance from wall for magnet grab")
		f:CheckBox("Whitelist ladders", "vrmod_brushclimb_ladderonly")
		f:ControlHelp("Only grab ladder surfaces (texture or entity)")
		f:CheckBox("Whitelist ledges", "vrmod_brushclimb_ledgeonly")
		f:ControlHelp("Only grab near the top edges of surfaces")
		f:NumSlider("Ledge reach", "vrmod_brushclimb_ledgereach", 8, 96, 0)
		f:ControlHelp("Max height above hand to detect ledge (lower = stricter)")
		f:CheckBox("Enable ledge vaulting", "vrmod_brushclimb_ledge")
		f:CheckBox("Show landing marker", "vrmod_brushclimb_marker")
		f:NumSlider("Vault scan range", "vrmod_brushclimb_vaultreach", 16, 128, 0)
		f:ControlHelp("How far ahead to search for vault targets")
		f:NumSlider("Vault min distance", "vrmod_brushclimb_vaultmin", 8, 64, 0)
		f:ControlHelp("Minimum distance from head to place vault target")
		f:NumSlider("Grab reach", "vrmod_brushclimb_reach", 0, 32, 0)
		f:ControlHelp("How far from the hand a wall can be grabbed (lower = must nearly touch)")
		f:NumSlider("Ladder grab reach", "vrmod_brushclimb_ladderreach", 0, 64, 0)
		f:ControlHelp("Grab reach inside ladder zones, where removed clip brushes sit deeper")
		f:NumSlider("Climb smoothing", "vrmod_brushclimb_smooth", 0, 0.9, 2)
		f:ControlHelp("0 = exact 1:1 motion; higher softens hand motion but adds lag")
		f:Button("Reset climbing settings", "vrmod_brushclimb_reset")
	end

	-- ─────────────── Client > Face Tracking ───────────────
	if ConVarExists("ft_enabled") then
		local t = vgui.Create("DScrollPanel", clientSheet)
		clientSheet:AddSheet("Face Track", t, "icon16/eye.png")
		local form = vgui.Create("DForm", t)
		form:SetName("Face Tracking")
		form:Dock(TOP)
		form:DockMargin(5, 5, 5, 0)
		form:SetExpanded(true)
		form:CheckBox("Enable Face Tracking", "ft_enabled")
		form:NumSlider("OSC Port", "ft_port", 1024, 65535, 0)
		form:NumSlider("Smoothing", "ft_smooth", 0, 0.95, 2)
		form:NumSlider("Net Update Rate (Hz)", "ft_rate", 5, 60, 0)
		form:NumSlider("Global Multiplier", "ft_multiplier", 0, 5, 2)
		form:CheckBox("Show Debug HUD", "ft_debug")
		local btn = form:Button("Open Full Face Tracking Panel")
		btn.DoClick = function() RunConsoleCommand("ft_menu") end
		form:ControlHelp("Mapping overrides are saved per playermodel in data/facetracking/.")
	end

	-- ══════════════════════════════════════════════════════════════════
	-- SERVER TAB
	-- ══════════════════════════════════════════════════════════════════
	do
		local t = vgui.Create("DScrollPanel", topSheet)
		topSheet:AddSheet("Server", t, "icon16/server.png")

		-- Server presets
		BuildPresetPanel(t, PRESET_DIR_SERVER, SERVER_CVARS)

		local netForm = vgui.Create("DForm", t)
		netForm:SetName("Networking")
		netForm:Dock(TOP)
		netForm:DockMargin(5, 5, 5, 0)
		netForm:SetExpanded(true)
		netForm:NumSlider("Tracking rate (Hz)", "vrmod_net_tickrate", 10, 100, 0)
		netForm:ControlHelp("How many times per second tracking is sent/received. Higher = smoother, more bandwidth. Capped at 100.")
		netForm:NumSlider("Min send movement", "vrmod_net_minsend", 0, 0.1, 3)
		netForm:ControlHelp("Per-tick movement a hand/part must exceed before an update is sent. 0 = always send (fixes slow parts freezing); higher saves bandwidth by skipping tiny moves.")

		local tpForm = vgui.Create("DForm", t)
		tpForm:SetName("Teleportation")
		tpForm:Dock(TOP)
		tpForm:DockMargin(5, 5, 5, 0)
		tpForm:SetExpanded(true)
		tpForm:CheckBox("Allow Teleportation", "vrmod_allow_teleport")
		tpForm:NumSlider("Max distance", "vrmod_teleport_maxdist", 0, 1000, 0)

		local pickupForm = vgui.Create("DForm", t)
		pickupForm:SetName("Pickup & Physics")
		pickupForm:Dock(TOP)
		pickupForm:DockMargin(5, 5, 5, 0)
		pickupForm:SetExpanded(true)
		pickupForm:CheckBox("Weight limit", "vrmod_pickup_limit")
		pickupForm:CheckBox("Pickup NPCs", "vrmod_pickup_npcs")
		pickupForm:CheckBox("Disable prop physics", "vrmod_pickup_no_phys")
		pickupForm:NumSlider("Pickup weight", "vrmod_pickup_weight", 1, 10000, 0)
		pickupForm:NumSlider("Pickup range", "vrmod_pickup_range", 0.0, 10.0, 1)
		pickupForm:CheckBox("Hand physics props", "vrmod_hand_physics")
		pickupForm:ControlHelp("Spawns solid physics props on VR players' hands so they can shove objects around. Off despawns them, which also stops hands blocking bullets and movement. Applies live, no rejoin needed.")
		pickupForm:CheckBox("Allow grabbing players", "vrmod_pickup_players")
		pickupForm:ControlHelp("VR players can pick up other players. The target is swapped for a ragdoll and dragged along by it, the same way NPCs are. Hard landings deal fall damage.")
		pickupForm:CheckBox("Protect higher ranks", "vrmod_pickup_players_adminprotect")
		pickupForm:ControlHelp("Refuses grabs where the target's usergroup outranks the grabber's. Uses CAMI inheritance when an admin mod provides it, otherwise superadmin > admin > user.")

		local combatForm = vgui.Create("DForm", t)
		combatForm:SetName("Combat")
		combatForm:Dock(TOP)
		combatForm:DockMargin(5, 5, 5, 0)
		combatForm:SetExpanded(true)
		combatForm:CheckBox("Self damage", "vrmod_selfdamage")
		combatForm:CheckBox("Enable melee", "sv_vrmod_melee")
		combatForm:NumSlider("Melee Damage", "vrmod_melee_damage", 0, 10, 0)
		combatForm:NumSlider("Melee Velocity Threshold", "vrmod_melee_velthreshold", 0.1, 10, 1)
		combatForm:NumSlider("Melee Delay", "vrmod_melee_delay", 0.01, 1, 2)
		combatForm:NumSlider("Relative speed multiplier", "vrmod_melee_speedscale", 0.001, 0.05, 3)
		local defaultModel = "models/props_junk/PopCan01a.mdl"
		local te = combatForm:TextEntry("Collision Model", "vrmod_melee_fist_collisionmodel")
		combatForm:CheckBox("Enable kicking", "sv_vrmod_kick")
		combatForm:NumSlider("Kick Damage", "vrmod_kick_damage", 0, 25, 0)
		combatForm:NumSlider("Kick Velocity Threshold", "vrmod_kick_velthreshold", 0.5, 10, 1)
		combatForm:CheckBox("Enable headbutting", "sv_vrmod_headbutt")
		combatForm:NumSlider("Headbutt Damage", "vrmod_headbutt_damage", 0, 15, 0)
		combatForm:NumSlider("Headbutt Velocity Threshold", "vrmod_headbutt_velthreshold", 0.5, 10, 1)

		local resetBtn = combatForm:Button("Reset Server Defaults")
		function resetBtn:DoClick()
			local defs = {
				vrmod_allow_teleport = "1", vrmod_teleport_maxdist = "500",
				vrmod_pickup_limit = "1", vrmod_pickup_npcs = "1", vrmod_pickup_no_phys = "0",
				vrmod_pickup_weight = "150", vrmod_pickup_range = "3.5", vrmod_selfdamage = "1",
				vrmod_pickup_players = "0", vrmod_pickup_players_adminprotect = "1",
				vrmod_hand_physics = "1",
				sv_vrmod_melee = "1", vrmod_melee_damage = "3", vrmod_melee_velthreshold = "1.5",
				vrmod_melee_delay = "0.45", vrmod_melee_speedscale = "0.030",
				vrmod_melee_fist_collisionmodel = defaultModel,
				sv_vrmod_kick = "1", vrmod_kick_damage = "8", vrmod_kick_velthreshold = "2.0",
				sv_vrmod_headbutt = "1", vrmod_headbutt_damage = "5", vrmod_headbutt_velthreshold = "2.5",
			}
			for name, value in pairs(defs) do
				RunConsoleCommand(name, value)
				RconCvar(name, value)
			end
		end

		local climbForm = vgui.Create("DForm", t)
		climbForm:SetName("Climbing")
		climbForm:Dock(TOP)
		climbForm:DockMargin(5, 5, 5, 0)
		climbForm:SetExpanded(true)
		climbForm:CheckBox("Allow climbing", "vrmod_sv_climbing")
		climbForm:CheckBox("Force whitelist ledges", "vrmod_sv_climbing_ledgeonly")
		climbForm:CheckBox("Force whitelist ladders", "vrmod_sv_climbing_ladderonly")
		climbForm:NumSlider("Throw force", "vrmod_sv_climbing_throw", 0, 10, 1)
		climbForm:ControlHelp("Momentum multiplier when a player launches off a wall.")
		climbForm:NumSlider("Throw threshold", "vrmod_sv_climbing_throwmin", 0, 400, 0)
		climbForm:ControlHelp("Release speed below which letting go is just a drop, with no launch.")
		climbForm:NumSlider("Throw speed cap", "vrmod_sv_climbing_throwmax", 0, 2000, 0)
		climbForm:ControlHelp("Hard ceiling on launch speed, applied after the multiplier.")
	end

	-- ══════════════════════════════════════════════════════════════════
	-- HULL TAB
	-- ══════════════════════════════════════════════════════════════════
	do
		local t = vgui.Create("DScrollPanel", topSheet)
		topSheet:AddSheet("Hull", t, "icon16/shape_square.png")

		local hullForm = vgui.Create("DForm", t)
		hullForm:SetName("Collision Hull")
		hullForm:Dock(TOP)
		hullForm:DockMargin(5, 5, 5, 0)
		hullForm:SetExpanded(true)
		hullForm:CheckBox("Use reduced collision hull", "vrmod_smallhull")
		hullForm:ControlHelp("Shrinks the player collision box so you fit through tighter gaps and can stand closer to walls. Height is unchanged.")
		hullForm:NumSlider("Hull width scale", "vrmod_hullscale", 0.1, 1, 3)
		hullForm:ControlHelp("1 = GMod default (16u wide). 0.625 = the classic VR hull (10u). 0.1 = smallest (1.6u). Only applies while the reduced hull is enabled.")
		hullForm:CheckBox("Affects all non-VR players", "vrmod_smallhull_all")
		hullForm:ControlHelp("Gives every player the reduced hull, not just VR players, so mixed lobbies fit through the same gaps. Server setting: needs host or the RCON toggle. Non-VR players may reach spots the map assumes are sealed.")
		hullForm:CheckBox("Head anti-clip", "vrmod_anticlip")
		hullForm:ControlHelp("Pushes your view out of walls when leaning through them in roomscale. Disable if an addon's collision fights it (addons can also override via the VRMod_AllowHeadAntiClip hook).")

		local resetBtn = hullForm:Button("Reset Hull Defaults")
		function resetBtn:DoClick()
			RunConsoleCommand("vrmod_smallhull", "1")
			RunConsoleCommand("vrmod_hullscale", "0.625")
			RunConsoleCommand("vrmod_smallhull_all", "0")
			RconCvar("vrmod_smallhull_all", "0")
			RunConsoleCommand("vrmod_anticlip", "1")
		end
	end


	-- ══════════════════════════════════════════════════════════════════
	-- DEBUG TAB
	-- ══════════════════════════════════════════════════════════════════
	do
		local t = vgui.Create("DPanel", topSheet)
		topSheet:AddSheet("Debug", t, "icon16/bug.png")
		local y = 10
		local function AddCB(lbl, cv)
			local cb = t:Add("DCheckBoxLabel")
			cb:SetDark(true)
			cb:SetText(lbl)
			cb:SetConVar(cv)
			cb:SetPos(20, y)
			cb:SizeToContents()
			y = y + 20
		end
		local function AddLogLevelCB(lbl, cv)
			local label = vgui.Create("DLabel", t)
			label:SetPos(20, y)
			label:SetText(lbl)
			label:SetDark(true)
			label:SizeToContents()
			y = y + 20
			local combo = vgui.Create("DComboBox", t)
			combo:SetPos(20, y)
			combo:SetSize(150, 20)
			local levelMap = { OFF = 0, ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4 }
			for name, val in pairs(levelMap) do
				combo:AddChoice(name, val, val == cv:GetInt())
			end
			combo.OnSelect = function(self, index, value, data) RunConsoleCommand(cv:GetName(), data) end
			y = y + 30
		end
		local function ProperSubName(s)
			if s == "api" then return "API" end
			if s == "ui" then return "UI" end
			return s:sub(1, 1):upper() .. s:sub(2)
		end
		local function PopulateDebugSettings()
			local order = vrmod.subsystemOrder or {"api", "utils", "core", "network", "input", "player", "physics", "pickup", "combat", "ui"}
			for _, subsystem in ipairs(order) do
				local cvarName = "vrmod_debug_" .. subsystem
				local cv = GetConVar(cvarName) or vrmod.debug_cvars and vrmod.debug_cvars[subsystem]
				if cv then AddCB("Debug " .. ProperSubName(subsystem), cvarName) end
			end
			if vrmod.debug_cvars then
				for subsystem, _ in pairs(vrmod.debug_cvars) do
					if not table.HasValue(order, subsystem) then
						local cvarName = "vrmod_debug_" .. subsystem
						local cv = GetConVar(cvarName)
						if cv then AddCB("Debug " .. ProperSubName(subsystem), cvarName) end
					end
				end
			end
		end
		AddLogLevelCB("Console log level", GetConVar("vrmod_log_console"))
		AddLogLevelCB("File log level", GetConVar("vrmod_log_file"))
		PopulateDebugSettings()
		AddCB("Visible wall collision", "vrmod_debug_collisions")
		AddCB("Redirect server prints to VR console (can cause lags)", "vrmod_console_redirect")
	end

	-- ══════════════════════════════════════════════════════════════════
	-- ArcVR TAB (conditional)
	-- ══════════════════════════════════════════════════════════════════
	local maxChecks = 3
	local checks = 0
	timer.Create("VRMod_CheckArcVR", 1, 0, function()
		if ConVarExists("arcticvr_virtualstock") then
			timer.Remove("VRMod_CheckArcVR")
			if not IsValid(topSheet) then return end
			local t = vgui.Create("DScrollPanel", topSheet)
			topSheet:AddSheet("ArcVR", t, "icon16/gun.png")
			local function AddSection(parentList, title, builder)
				local cat = vgui.Create("DCollapsibleCategory", parentList)
				cat:SetLabel(title)
				cat:Dock(TOP)
				cat:DockMargin(0, 0, 0, 5)
				cat:SetExpanded(false)
				local form = vgui.Create("DForm", cat)
				form:Dock(FILL)
				form.Header:SetVisible(false)
				form:InvalidateLayout(true)
				builder(form)
				cat:SetContents(form)
				return cat
			end
			AddSection(t, "Controls", function(f)
				f:CheckBox("Grip with reload key", "arcticvr_grip_withreloadkey")
				f:CheckBox("Magazine bump preload", "arcticvr_mag_bumpreload")
				f:CheckBox("Alternative frontgrip mode", "arcticvr_grip_alternative_mode")
				f:NumSlider("Slide magnification", "arcticvr_slide_magnification", 1, 10, 2)
				f:NumSlider("Grip magnification", "arcticvr_grip_magnification", 1, 10, 2)
				f:CheckBox("Disable reload with key", "arcticvr_disable_reloadkey")
				f:CheckBox("Disable grab reload", "arcticvr_disable_grabreload")
			end)
			AddSection(t, "Virtual Stock & Fixes", function(f)
				f:CheckBox("Enable virtual stock", "arcticvr_virtualstock")
				f:NumSlider("Frontgrip power", "arcticvr_2h_sens", 0, 2, 2)
				f:CheckBox("Grenade pin enable", "arcticvr_grenade_pin_enable")
				f:CheckBox("Shoot system fix", "arcticvr_shootsys")
				f:CheckBox("Misc client fix", "arcticvr_test_cl_misc_fix")
			end)
			AddSection(t, "Physical Gunstock", function(f)
				f:CheckBox("Enable physical gunstock", "arcticvr_physstock_enable")
				f:ControlHelp("Offset applied in gun-local space when foregripping a two-handed non-pistol weapon")
				f:NumSlider("Pos X (forward)", "arcticvr_physstock_pos_x", -20, 20, 2)
				f:NumSlider("Pos Y (right)", "arcticvr_physstock_pos_y", -20, 20, 2)
				f:NumSlider("Pos Z (up)", "arcticvr_physstock_pos_z", -20, 20, 2)
				f:NumSlider("Ang pitch", "arcticvr_physstock_ang_p", -45, 45, 2)
				f:NumSlider("Ang yaw", "arcticvr_physstock_ang_y", -45, 45, 2)
				f:NumSlider("Ang roll", "arcticvr_physstock_ang_r", -45, 45, 2)
			end)
			AddSection(t, "Mag Pouches", function(f)
				f:NumSlider("Default pouch distance", "arcticvr_defpouchdist", 0, 200, 2)
				f:CheckBox("Hybrid pouch", "arcticvr_hybridpouch")
				f:NumSlider("Hybrid pouch distance", "arcticvr_hybridpouchdist", 0, 200, 1)
				f:CheckBox("Head pouch", "arcticvr_headpouch")
				f:NumSlider("Head pouch distance", "arcticvr_headpouchdist", 0, 200, 1)
				f:CheckBox("Infinite pouch range", "arcticvr_infpouch")
			end)
			AddSection(t, "Server Settings", function(f)
				f:CheckBox("Allow reload key (all guns)", "arcticvr_allgun_allow_reloadkey")
				f:CheckBox("Allow reload key (client)", "arcticvr_allgun_allow_reloadkey_client")
				f:CheckBox("Bump reload (all guns)", "arcticvr_bumpreload_allgun")
				f:CheckBox("Bump reload (client)", "arcticvr_bumpreload_allgun_client")
				f:CheckBox("Normalize default ammo", "arcticvr_defaultammo_normalize")
				f:CheckBox("Alternate physics bullets", "arcticvr_physical_bullets")
				f:NumSlider("Mag pickup delay", "arcticvr_net_magtimertime", 0, 1, 2)
				f:CheckBox("Flick reload", "arcticvr_flickreload")
				f:CheckBox("Flick reload (dual wield)", "arcticvr_flickreload_dw")
			end)
		else
			checks = checks + 1
			if checks >= maxChecks then
				timer.Remove("VRMod_CheckArcVR")
				vrmod.logger.Warn("Timed out waiting for ArcVR convars.")
			end
		end
	end)

	-- ══════════════════════════════════════════════════════════════════
	-- PRESET IMPORTS TAB
	-- ══════════════════════════════════════════════════════════════════
	do
		local t = vgui.Create("DScrollPanel", topSheet)
		topSheet:AddSheet("Import", t, "icon16/disk.png")

		local importForm = vgui.Create("DForm", t)
		importForm:SetName("Import Preset from Text")
		importForm:Dock(TOP)
		importForm:DockMargin(5, 5, 5, 0)
		importForm:SetExpanded(true)

		importForm:ControlHelp("Paste the output of vrmod_export_client or vrmod_export_server, give it a name, and import.")

		local nameEntry = vgui.Create("DTextEntry")
		importForm:AddItem(nameEntry)
		nameEntry:SetPlaceholderText("Preset name...")

		local typeCombo = vgui.Create("DComboBox")
		importForm:AddItem(typeCombo)
		typeCombo:AddChoice("Client Preset", PRESET_DIR_CLIENT, true)
		typeCombo:AddChoice("Server Preset", PRESET_DIR_SERVER)

		local pasteEntry = vgui.Create("DTextEntry")
		importForm:AddItem(pasteEntry)
		pasteEntry:SetMultiline(true)
		pasteEntry:SetTall(200)
		pasteEntry:SetPlaceholderText("Paste exported settings here...\n\nFormat: one 'convar_name value' per line")

		local importBtn = importForm:Button("Import")
		function importBtn:DoClick()
			local name = nameEntry:GetValue()
			if not name or name == "" then
				chat.AddText(Color(255, 100, 100), "[VRMod] ", Color(255, 255, 255), "Enter a preset name first.")
				return
			end
			name = name:gsub("[^%w_%-]", "_")
			local text = pasteEntry:GetValue()
			if not text or text == "" then
				chat.AddText(Color(255, 100, 100), "[VRMod] ", Color(255, 255, 255), "Paste settings text first.")
				return
			end
			local _, dir = typeCombo:GetSelected()
			local ok, count = ImportPresetFromText(dir, name, text)
			if ok then
				chat.AddText(Color(100, 255, 100), "[VRMod] ", Color(255, 255, 255), "Imported '" .. name .. "' (" .. count .. " convars). Load it from the preset dropdown.")
				pasteEntry:SetValue("")
				nameEntry:SetValue("")
			else
				chat.AddText(Color(255, 100, 100), "[VRMod] ", Color(255, 255, 255), "No valid settings found in pasted text.")
			end
		end
	end

	-- ── VRMod_Menu hook ──
	local hooks = hook.GetTable().VRMod_Menu or {}
	local names = {}
	for _, v in ipairs(names) do
		local func = hooks[v]
		if isfunction(func) then pcall(func, frame) end
	end
	table.sort(names)
	for _, v in ipairs(names) do hooks[v](frame) end
	WireServerRcon(frame)
	return frame
end

-- ══════════════════════════════════════════════════════════════════
-- Export commands (split client / server)
-- ══════════════════════════════════════════════════════════════════
local function ExportCvars(cvarList, filename, label)
	local lines = {}
	for _, name in ipairs(cvarList) do
		local cv = GetConVar(name)
		if cv then lines[#lines + 1] = name .. " " .. cv:GetString() end
	end
	local out = table.concat(lines, "\n")
	file.Write(filename, out)
	print(out)
	print("\n-- Exported " .. #lines .. " " .. label .. " convars to data/" .. filename)
end

concommand.Add("vrmod_export_client", function()
	ExportCvars(CLIENT_CVARS, "vrmod_export_client.txt", "client")
end)

concommand.Add("vrmod_export_server", function()
	ExportCvars(SERVER_CVARS, "vrmod_export_server.txt", "server")
end)