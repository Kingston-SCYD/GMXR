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
	"vrmod_menu_float", "vrmod_menu_smooth", "vrmod_menu_scale", "vrmod_quickmenu_float",
	-- Controls
	"vrmod_smoothturn", "vrmod_smoothturnrate", "vrmod_snapturnangle", "vrmod_althead", "vrmod_althead_auto",
	"vrmod_controlleroffset_x", "vrmod_controlleroffset_y", "vrmod_controlleroffset_z",
	"vrmod_controlleroffset_pitch", "vrmod_controlleroffset_yaw", "vrmod_controlleroffset_roll",
	"vrmod_stick_deadzone_left", "vrmod_stick_deadzone_right",
	-- Rendering
	"vrmod_desktopview", "vrmod_postprocess", "vrmod_skybox", "vrmod_znear", "vrmod_eyescale",
	"vrmod_perfoverrides",
	"vrmod_perf_threaded_bones", "vrmod_perf_mcore", "vrmod_perf_mat_queue",
	"vrmod_perf_no_bloom", "vrmod_perf_no_fancyblend", "vrmod_perf_no_lightwarp",
	"vrmod_perf_no_pspatch", "vrmod_perf_no_motionblur", "vrmod_perf_reduce_particles",
	"vrmod_perf_no_rtt_shadows", "vrmod_perf_threaded_particles", "vrmod_perf_queued_ropes",
	-- Desktop Rendering
	"vrmod_cheaprender", "vrmod_specfov", "vrmod_specfov_mode", "vrmod_specfov_smooth_ang",
	"vrmod_specfov_hidehead", "vrmod_specfov_showhud", "vrmod_specfov_shaders", "vrmod_specfov_showsprite",
	"vrmod_specfov_eyepos", "vrmod_speccam_blend", "vrmod_specfov_rate", "vrmod_specfov_scale",
	"vrmod_specfov_tp_x", "vrmod_specfov_tp_y", "vrmod_specfov_tp_z",
	"vrmod_specfov_tp_ang_p", "vrmod_specfov_tp_ang_y", "vrmod_specfov_tp_ang_r",
	"vrmod_specfov_tp_faceply", "vrmod_specfov_tp_usepitch", "vrmod_specfov_tp_useyaw", "vrmod_specfov_tp_useroll",
	"vrmod_specfov_bodycam_x", "vrmod_specfov_bodycam_y", "vrmod_specfov_bodycam_z",
	"vrmod_specfov_bone_name", "vrmod_specfov_bone_rotmode", "vrmod_specfov_bone_flip",
	"vrmod_specfov_bone_x", "vrmod_specfov_bone_y", "vrmod_specfov_bone_z",
	"vrmod_specfov_bone_ang_p", "vrmod_specfov_bone_ang_y", "vrmod_specfov_bone_ang_r",
	"vrmod_specfov_vehmode", "vrmod_specfov_chase_dist", "vrmod_specfov_chase_z",
	"vrmod_specfov_awesome", "vrmod_specfov_awesome_fov", "vrmod_specfov_awesome_sway",
	"vrmod_specfov_awesome_shake", "vrmod_specfov_awesome_speed", "vrmod_specfov_awesome_speed_foot",
	"vrmod_specfov_shot_min", "vrmod_specfov_shot_max", "vrmod_specfov_rotate", "vrmod_specfov_rotate_time",
	"vrmod_specfov_rotate_checklist", "vrmod_specfov_rotate_pool",
	-- Character
	"vrmod_floatinghands", "vrmod_floatinghands_chands", "vrmod_floatinghands_stub",
	"vrmod_characterik", "vrmod_armstretcher", "vrmod_characterik_solver", "vrmod_hik_animblend", "vrmod_hik_handblend", "vrmod_yaw_hip_head", "vrmod_yaw_hip_arms", "vrmod_yaw_torso_head", "vrmod_yaw_torso_arms", "vrmod_lean_sens", "vrmod_lean_sens_fwd",
	"vrmod_fbt_leginfluence", "vrmod_fbt_animshoulders",
	"vrmod_sitheight", "vrmod_sitheadtohmddist", "vrmod_lieheight",
	"vrmod_charactereyeheight", "vrmod_characterheadtohmddist", "vrmod_smallhull", "vrmod_hullscale", "vrmod_anticlip", "vrmod_scale",
	-- HUD
	"vrmod_hud", "vrmod_hudmode", "vrmod_hudcurve", "vrmod_huddistance", "vrmod_hudscale",
	"vrmod_hudtestalpha", "vrmod_hudblacklist", "vrmod_hud_visible_quickmenukey",
	"vrmod_beam_color", "vrmod_laser_color", "vrmod_hud_color", "vrmod_hud_font",
	"vrmod_hudattach", "vrmod_hudarmscale",
	"vrmod_hudcrt", "vrmod_hudarm_x", "vrmod_hudarm_y", "vrmod_hudarm_z",
	"vrmod_hudarm_p", "vrmod_hudarm_yaw", "vrmod_hudarm_r", "vrmod_hudinteract",
	"vrmod_ui_outline", "vrmod_pointer_hand", "vrmod_pointer_use",
	-- Gameplay (client)
	"vr_pickup_disable_client", "vrmod_weapondrop_enable", "vrmod_weapondrop_release",
	"vrmod_manualpickups", "vrmod_interactive_buttons", "vrmod_weapon_swap",
	"vrmod_pickup_halos", "vrmod_nocrouchjump", "vrmod_allow_teleport_client",
	"vrmod_teleport_use_left", "vrmod_weaponmenu_style", "vrmod_menu_hand",
	"vrmod_deathcam_ragdoll", "vrmod_deathcam_ragdoll_view",
	-- Collisions
	"vrmod_collisions", "vrmod_collision_round", "vrmod_gunwall_clearance", "vrmod_hull_predict",
	-- Melee (client)
	"cl_vrmod_melee", "cl_vrmod_kick", "cl_vrmod_headbutt",
	-- Vehicles
	"vrmod_wheel", "vrmod_wheel_virtual", "vrmod_wheel_show", "vrmod_wheel_radius", "vrmod_wheel_lock",
	"vrmod_wheel_bar_radius", "vrmod_wheel_bar_lock", "vrmod_wheel_autohands", "vrmod_wheel_animhands",
	"vrmod_seat_x", "vrmod_seat_y", "vrmod_seat_z",
	"vrmod_vehicle_gripenter", "vrmod_vehicle_gripamount", "vrmod_vehicle_gripdist",
	"vrmod_vehicle_sitenter", "vrmod_vehicle_sitexit",
	"vrmod_vehicle_aimsteer", "vrmod_vehicle_aimsteer_range", "vrmod_vehicle_aimsteer_deadzone",
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
	"vrmod_holster_persist", "vrmod_holster_follow_body",
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
	"vrmod_pickup_weight", "vrmod_pickup_range", "vrmod_hand_physics", "vrmod_hand_interp", "vrmod_foot_physics", "vrmod_foot_force",
	"vrmod_pickup_players", "vrmod_pickup_players_adminprotect",
	"vrmod_weight", "vrmod_weight_lag", "vrmod_weight_ramp",
	"vrmod_selfdamage",
	"sv_vrmod_melee", "vrmod_melee_damage", "vrmod_melee_velthreshold",
	"vrmod_melee_delay", "vrmod_melee_speedscale", "vrmod_melee_fist_collisionmodel",
	"sv_vrmod_kick", "vrmod_kick_damage", "vrmod_kick_velthreshold",
	"sv_vrmod_headbutt", "vrmod_headbutt_damage", "vrmod_headbutt_velthreshold",
	"vrmod_physmelee_force", "vrmod_physmelee_damage", "vrmod_physmelee_speed",
	"vrmod_sv_climbing", "vrmod_sv_climbing_ledgeonly", "vrmod_sv_climbing_ladderonly",
	"vrmod_sv_climbing_throw", "vrmod_sv_climbing_throwmin", "vrmod_sv_climbing_throwmax",
	-- Hull
	"vrmod_smallhull_all",
	-- Networking
	"vrmod_net_tickrate", "vrmod_net_minsend",
	-- Poses
	"vrmod_sv_poses",
}

-- ══════════════════════════════════════════════════════════════════
-- ULX RCON forwarding for server-side settings
-- Server convars are FCVAR_REPLICATED / pure-server, so a client console
-- can't write them. With this toggle on, any change to a SERVER_CVARS
-- control (and the reset button) is mirrored through `ulx rcon`, letting a
-- superadmin flip server settings from inside VR without opening console.
-- ══════════════════════════════════════════════════════════════════
local cv_rcon = CreateClientConVar("vrmod_settings_rcon", "0", true, false)

-- ══════════════════════════════════════════════════════════════════
-- Setting descriptions (the DForm:ControlHelp line under each control),
-- shown or hidden from the bottom of the menu. The ControlHelp override in
-- VRUtilOpenMenu registers each one this menu builds -- tabs built later
-- (ArcVR, VRMod_Menu hooks) included -- and hides it if they're off. A row
-- some other logic hides (vrHidden: Arm HUD in Front mode) stays hidden.
-- ══════════════════════════════════════════════════════════════════
local cv_help = CreateClientConVar("vrmod_settings_help", "1", true, false, "Show the short description under each setting in the VRMod menu", 0, 1)
local helpRows = setmetatable({}, {__mode = "k"})
local function ShowHelp(show)
	local forms = {}
	for row in pairs(helpRows) do
		if IsValid(row) then
			row:SetVisible(show and not row.vrHidden)
			forms[row:GetParent()] = true
		else
			helpRows[row] = nil
		end
	end
	-- Re-lay each form, then up through its scroll panel to the frame
	for p in pairs(forms) do
		while IsValid(p) and p ~= frame do
			p:InvalidateLayout(true)
			p = p:GetParent()
		end
	end
end
cvars.AddChangeCallback("vrmod_settings_help", function(_, _, v) ShowHelp(v ~= "0") end, "vrmod_settings_help")

local SERVER_CVAR_SET = {}
for i = 1, #SERVER_CVARS do SERVER_CVAR_SET[SERVER_CVARS[i]] = true end

local function RconCvar(name, value)
	if not cv_rcon:GetBool() then return end
	-- Debounce: collapse slider drags / rapid edits into a single rcon call.
	timer.Create("vrmod_rcon_" .. name, 0.3, 1, function()
		RunConsoleCommand("ulx", "rcon", name .. " " .. value)
	end)
end

-- Resets convars to their code defaults (the Create*ConVar calls are the single
-- source of truth). rcon mirrors each reset to the server for SERVER_CVARS.
local function ResetCvars(list, rcon)
	for i = 1, #list do
		local n = list[i]
		local cv = GetConVar(n)
		if cv then
			local d = cv:GetDefault()
			RunConsoleCommand(n, d)
			if rcon then RconCvar(n, d) end
		end
	end
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

local function LoadPreset(dir, name, cvarList)
	if name == "Default" then ResetCvars(cvarList) return true end
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
		f = f:sub(1, -6)
		if f ~= "Default" then names[#names + 1] = f end
	end
	table.sort(names)
	table.insert(names, 1, "Default")
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
	form:ControlHelp("Saved snapshots of these settings. Default puts every one of them back to its default.")

	local function Refresh()
		if not IsValid(combo) then return end
		combo:Clear()
		combo:SetValue("Select preset...")
		for _, name in ipairs(GetPresetNames(dir)) do combo:AddChoice(name) end
	end
	Refresh()

	local loadBtn = form:Button("Load")
	form:ControlHelp("Applies the selected preset.")
	function loadBtn:DoClick()
		local _, name = combo:GetSelected()
		if not name then return end
		if LoadPreset(dir, name, cvarList) then
			chat.AddText(Color(100, 255, 100), "[VRMod] ", Color(255, 255, 255), "Loaded preset: " .. name)
		end
	end

	-- Inline save: text entry + button on same row
	local saveEntry = vgui.Create("DTextEntry")
	form:AddItem(saveEntry)
	saveEntry:SetPlaceholderText("Preset name...")
	local saveBtn = form:Button("Save Current Settings")
	form:ControlHelp("Saves your current settings under the name typed above.")
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
	form:ControlHelp("Deletes the selected preset.")
	function deleteBtn:DoClick()
		local _, name = combo:GetSelected()
		if not name or name == "Default" then return end
		DeletePreset(dir, name)
		Refresh()
		chat.AddText(Color(100, 255, 100), "[VRMod] ", Color(255, 255, 255), "Deleted preset: " .. name)
	end

	local exportBtn = form:Button("Export to Console")
	form:ControlHelp("Prints these settings to the console and to a file in data/, to share or paste into Import.")
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
	-- Darken ControlHelp labels once (deferred until VGUI is ready), and
	-- register this menu's description rows (see ShowHelp)
	if not darkHelpApplied then
		local dt = vgui.GetControlTable("DForm")
		if dt and dt.ControlHelp then
			local _orig = dt.ControlHelp
			local darkColor = Color(50, 50, 50)
			dt.ControlHelp = function(self, ...)
				local lbl = _orig(self, ...)
				if IsValid(lbl) then
					lbl:SetColor(darkColor)
					local row = lbl:GetParent()
					if IsValid(frame) and IsValid(row) and self:HasParent(frame) then
						row.vrHelp, helpRows[row] = true, true
						if not cv_help:GetBool() then row:SetVisible(false) end
					end
				end
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

	-- ── Description toggle (docked after the bar: sits just above it) ──
	local helpRow = vgui.Create("DPanel", frame)
	helpRow:Dock(BOTTOM)
	helpRow:SetTall(20)
	helpRow.Paint = nil
	local helpBox = vgui.Create("DCheckBoxLabel", helpRow)
	helpBox:Dock(LEFT)
	helpBox:DockMargin(5, 2, 0, 0)
	helpBox:SetText("Show setting descriptions")
	helpBox:SetConVar("vrmod_settings_help")
	helpBox:SizeToContents()

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
		form:ControlHelp("Draws a laser from the muzzle of whatever you hold, showing where it points.")

		form:CheckBox("Use weapon world models", "vrmod_useworldmodels")
		form:ControlHelp("Draws every weapon's third-person world model in your hand instead of its viewmodel. Requires VR restart.")

		local heightCheckbox = form:CheckBox("Show height adjustment menu", "vrmod_heightmenu")
		form:ControlHelp("Opens the height adjustment menu each time VR starts, to set your eye height and seated offset.")
		local checkTime = 0
		function heightCheckbox:OnChange(checked)
			if checked and SysTime() - checkTime < 0.1 then VRUtilOpenHeightMenu() end
			checkTime = SysTime()
		end

		form:CheckBox("Enable seated offset", "vrmod_seated")
		form:ControlHelp("Raises your view by a fixed amount so you can play sitting down. Set the amount in the height adjustment menu.")
		form:CheckBox("Automatically start VR after map loads", "vrmod_autostart")
		form:ControlHelp("Starts VR by itself once a map has finished loading.")
		form:CheckBox("Replace door use mechanics (when available)", "vrmod_doors")
		form:ControlHelp("On maps with grab points set up, doors and lockers open by grabbing and pulling their handle instead of pressing use.")
		form:CheckBox("Apply server settings via ULX RCON", "vrmod_settings_rcon")
		form:ControlHelp("Sends changes to server-side settings (Server tab: teleport, pickup, melee, climbing) through 'ulx rcon' so you don't need console in VR. Requires ULX superadmin.")

		-- Quick menu (spawn/context menu placement: its own tab)
		local menuForm = vgui.Create("DForm", form)
		menuForm:SetName("Quick Menu")
		menuForm:Dock(TOP)
		menuForm:DockMargin(10, 10, 10, 0)
		menuForm:SetExpanded(true)
		menuForm:CheckBox("Floating quick menu", "vrmod_quickmenu_float")
		menuForm:ControlHelp("Quick menu stays where opened instead of following your hand")

		form:Button("Reset settings to default", "vrmod_reset")
		form:ControlHelp("Resets every VRMod client setting to its default value.")
	end

	-- ─────────────── Client > Spawn Menu ───────────────
	do
		local t = vgui.Create("DScrollPanel", clientSheet)
		clientSheet:AddSheet("Spawn Menu", t, "icon16/application_view_tile.png")

		local menuForm = vgui.Create("DForm", t)
		menuForm:SetName("Spawn & Context Menus")
		menuForm:Dock(TOP)
		menuForm:DockMargin(5, 5, 5, 0)
		menuForm:SetExpanded(true)

		local posCombo = menuForm:ComboBox("Menu position", "vrmod_menu_float")
		posCombo:AddChoice("Follow hand", "0")
		posCombo:AddChoice("Stay where opened", "1")
		posCombo:AddChoice("In front of you", "2")
		posCombo:AddChoice("Follow where you look", "3")
		posCombo:ChooseOptionID(math.Clamp(GetConVar("vrmod_menu_float"):GetInt(), 0, 3) + 1)
		menuForm:ControlHelp("Follow hand: rides on your off hand. Stay where opened: left floating at your hand. In front of you: opens centred ahead of you and stays there. Follow where you look: stays ahead of you as you turn. Also applies to other popup windows, chat, keyboard and numpad.")
		menuForm:NumSlider("Menu smoothing", "vrmod_menu_smooth", 0, 1, 2)
		menuForm:ControlHelp("Smooths a menu that follows your hand or view, so tremor and small head movements don't shake it. 0 = rigid; higher trails further behind.")

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
		menuForm:ControlHelp("Size of spawn/context menus (1.3 = default)")

		local resetBtn = menuForm:Button("Reset Menu Defaults")
		menuForm:ControlHelp("Puts every Spawn & Context Menu setting back to its default.")
		function resetBtn:DoClick()
			ResetCvars({"vrmod_menu_float", "vrmod_menu_smooth", "vrmod_menu_scale"})
			posCombo:ChooseOptionID(tonumber(GetConVar("vrmod_menu_float"):GetDefault()) + 1)
			timer.Simple(0, UpdateScaleLabel)
		end
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
		controlsPanel:ControlHelp("Smooth Turn rotates you continuously while the stick is held, at the rate set (degrees per second). Snap Turn rotates in fixed steps, one per flick.")

		controlsPanel:NumSlider("Crouch threshold", "vrmod_crouchthreshold", 10, 60, 0)
		controlsPanel:ControlHelp("HMD height below which roomscale crouch activates (default 40)")

		controlsPanel:NumSlider("Left stick deadzone", "vrmod_stick_deadzone_left", 0, 0.9, 2)
		controlsPanel:NumSlider("Right stick deadzone", "vrmod_stick_deadzone_right", 0, 0.9, 2)
		controlsPanel:ControlHelp("Stick travel ignored before input registers; the rest is rescaled to full range. Raise to stop drift (default 0.10).")

		local actionBtn = vgui.Create("DButton", controlsPanel)
		controlsPanel:AddItem(actionBtn)
		actionBtn:SetText("Edit custom controller input actions")
		function actionBtn:DoClick() RunConsoleCommand("vrmod_actioneditor") end
		controlsPanel:ControlHelp("Opens the action editor, to change which controller buttons trigger which VRMod actions.")

		-- Pointer. Convar-bound combos sync their shown choice in Think
		-- (DComboBox:CheckConVarChanges), so no ChooseOptionID here.
		local ptrForm = vgui.Create("DForm", t)
		ptrForm:SetName("Pointer")
		ptrForm:Dock(TOP)
		ptrForm:DockMargin(5, 5, 5, 0)
		ptrForm:SetExpanded(true)
		local ph = ptrForm:ComboBox("Pointer hand", "vrmod_pointer_hand")
		ph:AddChoice("Right Hand", "0")
		ph:AddChoice("Left Hand", "1")
		ptrForm:ControlHelp("Which hand points at and clicks menus.")
		ptrForm:CheckBox("Pointer uses map objects", "vrmod_pointer_use")
		ptrForm:ControlHelp("Point that hand at a button, door, keypad, charger, ammo crate or vehicle within reach: the pointer beam lands on it, and Use uses exactly that instead of whatever you're facing. Anything else, or nothing, and Use works as before. Not while that hand holds a weapon.")
		local hi = ptrForm:ComboBox("HUD pointer button", "vrmod_hudinteract")
		hi:AddChoice("Reload", "0")
		hi:AddChoice("Quick Menu", "1")
		hi:AddChoice("Disabled", "2")
		ptrForm:ControlHelp("Hold this button to point at and click the HUD with your right hand. Disabled turns the HUD pointer off.")
		local ptrReset = ptrForm:Button("Reset Pointer Defaults")
		ptrForm:ControlHelp("Puts every Pointer setting back to its default.")
		function ptrReset:DoClick() ResetCvars({"vrmod_pointer_hand", "vrmod_pointer_use", "vrmod_hudinteract"}) end

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
		offsetForm:ControlHelp("Where the hand sits relative to the tracked controller: X forward, Y sideways, Z up, then its rotation. Press Apply offsets to use them.")
		local applyBtn = offsetForm:Button("Apply offsets", nil)
		offsetForm:ControlHelp("Uses the offsets above right away.")
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
		offsetForm:ControlHelp("Puts the controller offsets back to their defaults and applies them.")
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
			if o.desc then form:ControlHelp(o.desc) end
		end

		form:CheckBox("Enable engine postprocessing", "vrmod_postprocess")
		form:ControlHelp("Runs the engine's screen effects (colour correction, bloom and the like) in VR, at a cost in frame time." .. (shaderlib and " Also enables GShader in VR. Its effects are computed at your game resolution, so they look softer than the scene; it also runs twice a frame (details in chat when you turn it on)." or ""))
		form:CheckBox("3D Skybox (disable for more FPS)", "vrmod_skybox")
		form:ControlHelp("Draws the map's 3D skybox. Off saves frame time on maps with a detailed one.")

		form:NumSlider("ZNear", "vrmod_znear", -3.0, 3.0, 2)
		form:ControlHelp("How close objects can be before clipping. Lower values let you see closer objects.")

		form:NumSlider("Eye distance offset", "vrmod_eyescale", 0.0, 1.0, 2)
		form:ControlHelp("Adjusts stereo eye separation. Changing this will visually affect your POV.")

		local resetBtn = form:Button("Reset Rendering Defaults")
		form:ControlHelp("Puts every Rendering setting back to its default.")
		function resetBtn:DoClick()
			ResetCvars({"vrmod_postprocess", "vrmod_skybox", "vrmod_znear", "vrmod_eyescale", "vrmod_perfoverrides"})
			for _, o in ipairs(vrmod.PerfOverrides or {}) do RunConsoleCommand(o.toggle, o.def or "1") end
		end

		local compat = vgui.Create("DForm", t)
		compat:SetName("Compatibility")
		compat:Dock(TOP)
		compat:DockMargin(5, 5, 5, 0)
		compat:SetExpanded(true)
		compat:CheckBox("Warn about addons that break VR", "vrmod_compat_warn")
		compat:ControlHelp("Reports addons known to break the VR render on VR start.")
		compat:CheckBox("Suppress other ShouldDrawLocalPlayer hooks", "vrmod_compat_killhooks")
		compat:ControlHelp("Thirdperson and camera addons hook ShouldDrawLocalPlayer with no priority system and silently win over VRMod, killing the body and hands. Restored on VR exit.")
		compat:CheckBox("Warn on screen when VR rendering stalls", "vrmod_compat_stallwarn")
		compat:ControlHelp("Draws a banner over the console or menu naming whatever stopped the headset updating.")
		compat:CheckBox("Show reason card in headset", "vrmod_pausecard")
		compat:ControlHelp("Paints the reason into both eyes instead of leaving the last frame frozen.")
		local compatBtn = compat:Button("Run compatibility check now")
		function compatBtn:DoClick() RunConsoleCommand("vrmod_compat") end
		compat:ControlHelp("Checks your installed addons against the known-incompatible list and reports what it finds.")
	end

	-- ─────────────── Client > Desktop Rendering ───────────────
	-- What the monitor shows while you're in VR. The spectator camera lives in
	-- utils/sh_speccam; every control here is a convar it reads live.
	do
		local t = vgui.Create("DScrollPanel", clientSheet)
		clientSheet:AddSheet("Desktop Rendering", t, "icon16/television.png")
		local function Section(name, open)
			local f = vgui.Create("DForm", t)
			f:SetName(name)
			f:Dock(TOP)
			f:DockMargin(5, 5, 5, 0)
			f:SetExpanded(open)
			return f
		end
		local function UseMode(f, mode)
			f:Button("Use This Mode").DoClick = function() RunConsoleCommand("vrmod_specfov_mode", mode) end
			f:ControlHelp("Switches the spectator camera to this mode.")
		end

		local form = Section("Desktop View", true)
		form:CheckBox("Cheap Rendering", "vrmod_cheaprender")
		form:ControlHelp("Mirrors one headset eye to the desktop. Costs nothing extra. Untick to use the spectator camera below instead, which renders a whole extra view of the scene every frame.")
		local dvCombo = form:ComboBox("Mirrored eye", "vrmod_desktopview")
		dvCombo:AddChoice("none", "1")
		dvCombo:AddChoice("left eye", "2")
		dvCombo:AddChoice("right eye", "3")
		local dvVal = convars.vrmod_desktopview:GetInt()
		dvCombo:ChooseOptionID(dvVal > 0 and dvVal or 1)
		form:ControlHelp("Used while Cheap Rendering is on. Applies on VR start.")

		local spec = Section("Spectator Camera", true)
		spec:ControlHelp("Used while Cheap Rendering is off. Independent of the headset view.")
		spec:NumSlider("Field of view", "vrmod_specfov", 10, 150, 0)
		spec:ControlHelp("Field of view of the spectator camera, in degrees.")
		spec:NumSlider("Render every Nth frame", "vrmod_specfov_rate", 1, 4, 0)
		spec:ControlHelp("1 renders it every frame. 2 halves its GPU cost and the desktop shows each spectator frame twice. Raise it if the headset judders while the spectator camera is on.")
		spec:NumSlider("Resolution scale", "vrmod_specfov_scale", 0.25, 1, 2)
		spec:ControlHelp("Renders the spectator view smaller and stretches it to the desktop. Applies on VR start.")
		spec:NumSlider("Rotation smoothing", "vrmod_specfov_smooth_ang", 0, 1, 2)
		spec:ControlHelp("Smooths the spectator camera's turning so head movement doesn't shake the desktop view. 0 = rigid.")
		local MODES = {"Eye (headset viewpoint)", "Static / Attached", "Third-Person", "Body Camera (Chest)", "Attach To Bone", "Chase (vehicles only)", "Random Shots"}
		local modeCombo = spec:ComboBox("Camera mode", "vrmod_specfov_mode")
		modeCombo:SetSortItems(false)
		for i = 1, 7 do if i ~= 6 then modeCombo:AddChoice(MODES[i], i - 1) end end
		spec:ControlHelp("Each mode has its own section below. Camera Rotation, while on, picks the mode for you. A VR Camera you are looking through overrides all of them.")
		spec:CheckBox("Hide player head", "vrmod_specfov_hidehead")
		spec:ControlHelp("Hides your playermodel's head from the spectator view in Eye (first-person) mode, so it doesn't block the camera. Other modes always show it.")
		spec:CheckBox("Show HUD on desktop view", "vrmod_specfov_showhud")
		spec:ControlHelp("Draws the HUD on the desktop spectator view.")
		spec:CheckBox("Apply post-process shaders", "vrmod_specfov_shaders")
		spec:ControlHelp("Runs RenderScreenspaceEffects on the spectator view, so shader addons apply to it.")
		spec:CheckBox("Show camera sprite in VR", "vrmod_specfov_showsprite")
		spec:ControlHelp("Marks where the spectator camera is in VR, so you can see what it's filming.")

		local fx = Section("Awesome Camera & Vehicles", false)
		fx:ControlHelp("Driving-game effects on the spectator view: speed widens the FOV, turns bank the camera and swing it into the corner, braking dips it, top speed shakes it, crashes slam it.")
		local fxCombo = fx:ComboBox("Awesome camera", "vrmod_specfov_awesome")
		fxCombo:SetSortItems(false)
		fxCombo:AddChoice("Off", 0)
		fxCombo:AddChoice("Always", 1)
		fxCombo:AddChoice("Only in vehicles", 2)
		fx:ControlHelp("Always also runs on foot, where walking speed barely moves it. Placed VR Cameras are never affected.")
		fx:NumSlider("Speed FOV boost", "vrmod_specfov_awesome_fov", 0, 60, 0)
		fx:ControlHelp("Degrees added to the field of view at full speed. Throttle punches it wider, braking pulls it in.")
		fx:NumSlider("Sway strength", "vrmod_specfov_awesome_sway", 0, 3, 2)
		fx:ControlHelp("How hard the camera banks and looks into turns, and dips under braking. 0 = off.")
		fx:NumSlider("Shake strength", "vrmod_specfov_awesome_shake", 0, 3, 2)
		fx:ControlHelp("High-speed rumble, and the jolt from crashes and hard landings. 0 = off.")
		fx:NumSlider("Full-effect speed: vehicle", "vrmod_specfov_awesome_speed", 100, 5000, 0)
		fx:NumSlider("Full-effect speed: on foot", "vrmod_specfov_awesome_speed_foot", 50, 2000, 0)
		fx:ControlHelp("Speed where the effects peak, in units per second. About 1500 suits cars (raise it for planes), about 400 a sprint.")
		local vehCombo = fx:ComboBox("Vehicle camera", "vrmod_specfov_vehmode")
		vehCombo:SetSortItems(false)
		vehCombo:AddChoice("Same as on foot", -1)
		for i = 1, 7 do vehCombo:AddChoice(MODES[i], i - 1) end
		fx:ControlHelp("Camera mode used while you're in a vehicle, with or without the awesome camera. Modes keep their own settings below.")
		fx:NumSlider("Chase distance", "vrmod_specfov_chase_dist", 1, 6, 2)
		fx:NumSlider("Chase height", "vrmod_specfov_chase_z", 0, 2, 2)
		fx:ControlHelp("In vehicle sizes, so one setting frames a bike and a bus. The chase cam trails the vehicle's turns and pulls in off walls.")

		local rot = Section("Camera Rotation", false)
		rot:CheckBox("Camera rotation", "vrmod_specfov_rotate")
		rot:ControlHelp("Switches to a random camera mode on a timer. Overrides Camera mode and Vehicle camera while on.")
		rot:NumSlider("Seconds per camera", "vrmod_specfov_rotate_time", 5, 300, 0)
		rot:ControlHelp("How long each camera stays up before the next.")
		rot:CheckBox("Checklist selection", "vrmod_specfov_rotate_checklist")
		rot:ControlHelp("No camera comes up twice until every camera in the list has had its turn.")
		-- One bitmask convar; picking an entry flips its bit (bit n = mode n)
		local cv_pool = GetConVar("vrmod_specfov_rotate_pool")
		local poolCombo = rot:ComboBox("Cameras")
		poolCombo:SetSortItems(false)
		local function FillPool(mask)
			poolCombo:Clear()
			local n = 0
			for i = 1, 7 do
				local on = bit.band(mask, bit.lshift(1, i - 1)) ~= 0
				if on then n = n + 1 end
				poolCombo:AddChoice((on and "[X]  " or "[   ]  ") .. MODES[i], i - 1)
			end
			poolCombo:SetValue(n .. " of 7 in rotation")
		end
		FillPool(cv_pool:GetInt())
		function poolCombo:OnSelect(_, _, bitIdx)
			local mask = bit.bxor(cv_pool:GetInt(), bit.lshift(1, bitIdx))
			RunConsoleCommand("vrmod_specfov_rotate_pool", tostring(mask))
			FillPool(mask)
		end
		rot:ControlHelp("Pick a camera to tick or untick it. Chase only joins in while you're in a vehicle. Static sits wherever you last placed it.")

		local eye = Section("Mode: Eye", false)
		eye:ControlHelp("Renders from the headset itself: what you see, at the desktop's shape.")
		local eyeCombo = eye:ComboBox("Eye position", "vrmod_specfov_eyepos")
		eyeCombo:AddChoice("Center between eyes", 0)
		eyeCombo:AddChoice("Left eye", 1)
		eyeCombo:AddChoice("Right eye", 2)
		eye:ControlHelp("Which eye position the view is taken from.")
		UseMode(eye, "0")

		local st = Section("Mode: Static / Attached", false)
		st:ControlHelp("A fixed point in the world, or a camera bolted to a prop. The VR Spec Cam Placer tool places it on a surface or attaches it to a prop.")
		UseMode(st, "1")
		st:Button("Place at eye position now").DoClick = function() RunConsoleCommand("vrmod_specfov_place_static") end
		st:Button("Detach from entity").DoClick = function() RunConsoleCommand("vrmod_specfov_detach") end
		st:ControlHelp("Place moves the static camera to your eyes. Detach unbolts it from a prop, leaving it where it is.")
		st:ControlHelp("Rotation: absolute in the world; added on top of the prop's angle when attached.")
		st:NumSlider("Pitch", "vrmod_specfov_static_p", -89, 89, 1)
		st:NumSlider("Yaw", "vrmod_specfov_static_y", -180, 180, 1)
		st:NumSlider("Roll", "vrmod_specfov_static_r", -180, 180, 1)
		st:ControlHelp("Offset from an attached prop, along its own axes:")
		st:NumSlider("Forward", "vrmod_specfov_att_x", -100, 100, 1)
		st:NumSlider("Right", "vrmod_specfov_att_y", -100, 100, 1)
		st:NumSlider("Up", "vrmod_specfov_att_z", -100, 100, 1)

		local tp = Section("Mode: Third-Person", false)
		tp:ControlHelp("Follows you from the headset. Pulls in when it would go through a wall.")
		UseMode(tp, "2")
		tp:NumSlider("Right offset", "vrmod_specfov_tp_x", -100, 100, 1)
		tp:NumSlider("Back offset", "vrmod_specfov_tp_y", -300, 0, 1)
		tp:NumSlider("Up offset", "vrmod_specfov_tp_z", -100, 100, 1)
		tp:ControlHelp("Where the camera sits relative to your head, in units.")
		tp:CheckBox("Always face player", "vrmod_specfov_tp_faceply")
		tp:ControlHelp("Keeps the camera pointed at you instead of looking where you look.")
		tp:ControlHelp("Follow these headset rotation axes:")
		tp:CheckBox("Pitch (tilt)", "vrmod_specfov_tp_usepitch")
		tp:CheckBox("Yaw (turn)", "vrmod_specfov_tp_useyaw")
		tp:CheckBox("Roll (lean)", "vrmod_specfov_tp_useroll")
		tp:NumSlider("Pitch offset", "vrmod_specfov_tp_ang_p", -89, 89, 1)
		tp:NumSlider("Yaw offset", "vrmod_specfov_tp_ang_y", -180, 180, 1)
		tp:NumSlider("Roll offset", "vrmod_specfov_tp_ang_r", -180, 180, 1)
		tp:ControlHelp("Extra rotation added to the camera's direction, in degrees.")

		local body = Section("Mode: Body Camera", false)
		body:ControlHelp("Anchored to the chest, looking where the headset looks. A helmet-cam feel.")
		UseMode(body, "3")
		body:NumSlider("Right / Left", "vrmod_specfov_bodycam_x", -30, 30, 1)
		body:NumSlider("Up / Down", "vrmod_specfov_bodycam_y", -30, 30, 1)
		body:NumSlider("Forward / Back", "vrmod_specfov_bodycam_z", -30, 30, 1)
		body:ControlHelp("Where the camera sits relative to your chest, in units.")

		local bone = Section("Mode: Bone", false)
		bone:ControlHelp("Follows any bone on your playermodel.")
		UseMode(bone, "4")
		local boneCombo = bone:ComboBox("Bone", "vrmod_specfov_bone_name")
		boneCombo:SetSortItems(false)
		local function FillBones()
			boneCombo:Clear()
			local ply = LocalPlayer()
			if not IsValid(ply) then return end
			for i = 0, ply:GetBoneCount() - 1 do
				local n = ply:GetBoneName(i)
				if n and n ~= "__INVALIDBONE__" then boneCombo:AddChoice(n, n) end
			end
		end
		FillBones()
		bone:ControlHelp("Bone to follow, from your current playermodel.")
		bone:TextEntry("Bone name", "vrmod_specfov_bone_name")
		bone:ControlHelp("Or type a bone name in directly (ValveBiped.Bip01_Head1, for example).")
		bone:Button("Refresh bone list").DoClick = FillBones
		bone:ControlHelp("Re-reads the bone list after a playermodel change.")
		local rotCombo = bone:ComboBox("Rotation", "vrmod_specfov_bone_rotmode")
		rotCombo:AddChoice("Follow bone", 0)
		rotCombo:AddChoice("Follow headset", 1)
		bone:ControlHelp("Follow bone turns with the bone. Follow headset sits on the bone but looks where you look.")
		bone:CheckBox("Flip camera (selfie)", "vrmod_specfov_bone_flip")
		bone:ControlHelp("Turns the camera around to look back the other way, selfie-style.")
		bone:NumSlider("Right / Left", "vrmod_specfov_bone_x", -100, 100, 1)
		bone:NumSlider("Up / Down", "vrmod_specfov_bone_y", -100, 100, 1)
		bone:NumSlider("Forward / Back", "vrmod_specfov_bone_z", -100, 100, 1)
		bone:ControlHelp("Where the camera sits relative to the bone, in units.")
		bone:NumSlider("Pitch offset", "vrmod_specfov_bone_ang_p", -89, 89, 1)
		bone:NumSlider("Yaw offset", "vrmod_specfov_bone_ang_y", -180, 180, 1)
		bone:NumSlider("Roll offset", "vrmod_specfov_bone_ang_r", -180, 180, 1)
		bone:ControlHelp("Extra rotation added to the camera's direction, in degrees.")

		local shots = Section("Mode: Random Shots", false)
		shots:ControlHelp("A film crew: cuts between orbits, low hero angles, dutch tilts, cranes, telephoto, dolly zooms, close-ups and roadside tripods. In a vehicle a shot frames you, the vehicle, or both. Each shot sets its own FOV to keep its subject in frame.")
		UseMode(shots, "6")
		shots:NumSlider("Shortest shot", "vrmod_specfov_shot_min", 3, 60, 0)
		shots:NumSlider("Longest shot", "vrmod_specfov_shot_max", 3, 60, 0)
		shots:ControlHelp("Each shot runs a random time between these, in seconds. A tripod shot cuts early once you're out of its sight or range.")

		local cams = Section("VR Cameras", false)
		cams:ControlHelp("Key-bound cameras placed with the VR Camera tool (Render tab), or the stock Camera tool, which is converted. Press a camera's key to look through it. Needs Cheap Rendering off while you're in VR.")
		cams:Button("Next camera").DoClick = function() RunConsoleCommand("vrmod_speccam_next") end
		cams:Button("Previous camera").DoClick = function() RunConsoleCommand("vrmod_speccam_prev") end
		cams:Button("Use camera I'm aiming at").DoClick = function() RunConsoleCommand("vrmod_speccam_pick") end
		cams:Button("Stop viewing").DoClick = function() RunConsoleCommand("vrmod_speccam_off") end
		cams:ControlHelp("Step through the cameras, look through the one you're aiming at, or go back to the normal desktop view.")
		cams:NumSlider("Switch blend (seconds)", "vrmod_speccam_blend", 0, 3, 2)
		cams:ControlHelp("0 cuts between cameras; higher flies the view across. Also used on every camera mode change, rotation and Random Shots cut. Per-camera FOV and number: context menu, right-click a camera, Edit Properties. Binds: vrmod_speccam_place / _next / _prev / _toggle / _off, vrmod_speccam_select <number>.")

		local resetBtn = form:Button("Reset Desktop Rendering Defaults")
		form:ControlHelp("Puts every Desktop Rendering setting back to its default.")
		function resetBtn:DoClick()
			ResetCvars({"vrmod_cheaprender", "vrmod_desktopview", "vrmod_specfov", "vrmod_specfov_mode",
				"vrmod_specfov_smooth_ang", "vrmod_specfov_hidehead", "vrmod_specfov_showhud", "vrmod_specfov_shaders",
				"vrmod_specfov_showsprite", "vrmod_speccam_blend", "vrmod_specfov_rate", "vrmod_specfov_scale",
				"vrmod_specfov_vehmode", "vrmod_specfov_chase_dist", "vrmod_specfov_chase_z",
				"vrmod_specfov_awesome", "vrmod_specfov_awesome_fov", "vrmod_specfov_awesome_sway",
				"vrmod_specfov_awesome_shake", "vrmod_specfov_awesome_speed", "vrmod_specfov_awesome_speed_foot",
				"vrmod_specfov_shot_min", "vrmod_specfov_shot_max", "vrmod_specfov_rotate", "vrmod_specfov_rotate_time",
				"vrmod_specfov_rotate_checklist", "vrmod_specfov_rotate_pool"})
			dvCombo:ChooseOptionID(tonumber(convars.vrmod_desktopview:GetDefault()))
		end
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
		charForm:CheckBox("Floating hands: use playermodel c_hands", "vrmod_floatinghands_chands")
		charForm:ControlHelp("Draws your playermodel's registered viewmodel hands instead of the generic hand model, and follows playermodel changes. Rigs without ValveBiped hand bones fall back to the generic model.")
		charForm:CheckBox("Floating hands: forearm stub", "vrmod_floatinghands_stub")
		charForm:ControlHelp("Keeps the forearm as a rigid stub ending at the elbow. Off collapses everything above the wrist.")
		charForm:NumSlider("Open-hand finger extend", "vrmod_finger_openextend", 0, 1, 2)
		charForm:ControlHelp("How far the fingers straighten past the model's rest pose when open, as a fraction of the fist curl. Saved per floating-hands model, so set it once for each and it comes back with that model.")

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
		-- Hai IK (the default solver), the body yaw / lean tuning and the
		-- sit / lie heights live out of the way.
		local advSection = vgui.Create("DForm", animSection)
		advSection:SetName("Advanced")
		advSection:SetExpanded(false)
		animSection:AddItem(advSection)
		advSection:CheckBox("Use Hai IK (full body)", "vrmod_characterik_solver")
		advSection:ControlHelp("On by default. Haï~'s solver: spine, head and legs follow your head, knees bend when you crouch, learned elbow placement. Applies to every VR player you see. Off = the classic solver. Falls back to classic on models without a full ValveBiped spine.")
		advSection:NumSlider("Hai IK: Animation Blend", "vrmod_hik_animblend", 0, 1, 2)
		advSection:ControlHelp("Lets the walk/idle animation move the head, and the shoulders and elbows a little. Calibrate Eye Height first: Hai IK stands the model at its own eye height when you stand at yours. Default 0.33.")
		advSection:NumSlider("Hai IK: Hand Swing", "vrmod_hik_handblend", 0, 1, 2)
		advSection:ControlHelp("How much the animation swings the hands. Only other players and your spectator view see it; in your headset the hands stay on the controllers. Default 0.1.")
		-- Tuning sliders for the split body yaw (to be hard coded later).
		advSection:ControlHelp("Body yaw is split: hips (legs, feet) and torso (chest, shoulders, arms). Each follows a mix of where your head and your arms point. Both 0 = that part only turns while you walk. Things that need one body yaw (holsters etc.) use the average.")
		advSection:NumSlider("Hip Yaw: Head", "vrmod_yaw_hip_head", 0, 1, 2)
		advSection:NumSlider("Hip Yaw: Arms", "vrmod_yaw_hip_arms", 0, 1, 2)
		advSection:ControlHelp("Hips turn only once you're 30 degrees past them, and feet step to follow. Defaults 1 / 0.7.")
		advSection:NumSlider("Torso Yaw: Head", "vrmod_yaw_torso_head", 0, 1, 2)
		advSection:NumSlider("Torso Yaw: Arms", "vrmod_yaw_torso_arms", 0, 1, 2)
		advSection:ControlHelp("The torso twists up to 60 degrees off the hips. Defaults 0.25 / 1. While walking with the stick both follow the head.")
		advSection:NumSlider("Lean Sensitivity: Side", "vrmod_lean_sens", 0, 4, 2)
		advSection:NumSlider("Lean Sensitivity: Forward/Back", "vrmod_lean_sens_fwd", 0, 4, 2)
		advSection:ControlHelp("The body leans when you go down with your head tilted (side) or nodded (forward/back); the hips move the other way. Higher kicks in with less head angle. 0 turns that lean off. Defaults 3.13 / 1.28.")
		-- A height of 0 is each pose's off switch; the box just makes it
		-- findable. Off parks the height in a cookie, on brings it back (else the
		-- default). The slider tracks the convar itself and drives the box, so
		-- reset, presets and typing 0 all agree.
		local function HeightToggle(form, label, help, name, slider, max, sliderHelp)
			local cv = convars[name]
			local box = form:CheckBox(label)
			form:ControlHelp(help)
			local sl = form:NumSlider(slider, name, 0, max, 0)
			form:ControlHelp(sliderHelp)
			box:SetChecked(cv:GetFloat() > 0)
			function box:OnChange(on)
				local v = cv:GetFloat()
				if on then
					if v <= 0 then cv:SetFloat(cookie.GetNumber(name, tonumber(cv:GetDefault()))) end
				elseif v > 0 then
					cookie.Set(name, v)
					cv:SetFloat(0)
				end
			end
			function sl:OnValueChanged(v) box:SetChecked(v > 0) end
		end
		HeightToggle(advSection, "Sit animation", "Plays a sit pose when you physically sit down. Off also stops sit-to-enter for vehicles.",
			"vrmod_sitheight", "Sit Height", 60, "Head height above feet at/below which the sit animation plays. Default 31.")
		advSection:NumSlider("Sit: HMD to Body Distance", "vrmod_sitheadtohmddist", 0, 20, 1)
		advSection:ControlHelp("How far behind the HMD the body sits while sitting. Default 13.1.")
		HeightToggle(advSection, "Lie down (prone / supine)", "Lying on the floor tips the whole body over, face down or face up from how your head is turned. Done by the IK, so arms and head keep tracking. No addon needed.",
			"vrmod_lieheight", "Lie Down Height", 40, "Headset height above the floor where you are fully lying. The body starts tipping over from the bottom of your squat and follows your head down to here. Default 20.")

		local calibSection = vgui.Create("DForm", t)
		calibSection:SetName("Model Calibration")
		calibSection:Dock(TOP)
		calibSection:DockMargin(5, 5, 5, 0)
		calibSection:SetExpanded(true)
		calibSection:NumSlider("Eye Height", "vrmod_charactereyeheight", 30, 100, 1)
		calibSection:ControlHelp("Character eye height in source units. Default 67.8.")
		calibSection:NumSlider("Head to HMD Distance", "vrmod_characterheadtohmddist", 0, 20, 1)
		calibSection:ControlHelp("Distance from HMD to head bone. Default 6.3.")
		local charRestoreBtn = calibSection:Button("Restore Character Defaults")
		calibSection:ControlHelp("Puts the animation and calibration settings back to their defaults.")
		function charRestoreBtn:DoClick()
			ResetCvars({"vrmod_characterik", "vrmod_armstretcher", "vrmod_characterik_solver", "vrmod_hik_animblend", "vrmod_hik_handblend", "vrmod_charactereyeheight", "vrmod_characterheadtohmddist",
				"vrmod_yaw_hip_head", "vrmod_yaw_hip_arms", "vrmod_yaw_torso_head", "vrmod_yaw_torso_arms", "vrmod_lean_sens", "vrmod_lean_sens_fwd", "vrmod_fbt_leginfluence", "vrmod_fbt_animshoulders", "vrmod_sitheight",
				"vrmod_sitheadtohmddist", "vrmod_lieheight"})
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
		presetForm:ControlHelp("Deletes the saved calibration for the model you're wearing and resets it.")
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
		presetForm:ControlHelp("Deletes every saved per-model calibration.")
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
		boneSection:ControlHelp("Hiding a bone also hides everything attached below it.")
		local boneBtn = boneSection:Button("Open Bone Hider")
		boneSection:ControlHelp("Opens the bone list for your current playermodel.")
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
		scaleSection:ControlHelp("Scaling a bone also scales everything attached below it.")
		local scaleBtn = scaleSection:Button("Open Bone Scaler")
		scaleSection:ControlHelp("Opens the bone list for your current playermodel.")
		function scaleBtn:DoClick()
			if vrmod.boneScaler then vrmod.boneScaler.OpenPanel() end
		end
	end

	-- ─────────────── Client > Trackers ───────────────
	if vrmod.BuildTrackerPanel then
		local t = vgui.Create("DScrollPanel", clientSheet)
		clientSheet:AddSheet("Trackers", t, "icon16/transmit.png")
		vrmod.BuildTrackerPanel(t)
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
		settingsForm:ControlHelp("Store weapons and props in body slots by letting go of them there; grab a slot to take them back out.")
		settingsForm:CheckBox("Show Entity Names (world)", "vrmod_pouch_visiblename")
		settingsForm:ControlHelp("Shows what each slot holds as floating text at the slot.")
		settingsForm:CheckBox("Show Entity Names (hud)", "vrmod_pouch_visiblename_hud")
		settingsForm:ControlHelp("Shows what each slot holds on your HUD.")
		settingsForm:CheckBox("Enable Left Hand Weapon Holster", "vrmod_pouch_lefthandwep_enable")
		settingsForm:ControlHelp("Lets the left hand store and draw weapons too, not just the right.")
		settingsForm:CheckBox("Holsters Follow Body", "vrmod_holster_follow_body")
		settingsForm:ControlHelp("Slots turn with your body instead of your head, so looking around doesn't swing them. Uses head direction with floating hands.")
		settingsForm:CheckBox("Show Holstered Weapon Models", "vrmod_holster_showmodels")
		settingsForm:ControlHelp("Draws stored weapons at their slots.")
		settingsForm:NumSlider("Chest Holster Height Offset", "vrmod_pouch_chest_z", -30, 30, 1)
		settingsForm:ControlHelp("Moves the chest slots up or down, in units.")
		settingsForm:NumSlider("Prop Max Volume (0=no limit)", "vrmod_holster_prop_maxvolume", 0, 50000, 0)
		settingsForm:ControlHelp("Props with OBB volume above this are rejected. Ragdolls bypass this limit.")
		settingsForm:CheckBox("Allow Holstering Ragdolls", "vrmod_holster_ragdolls")
		settingsForm:ControlHelp("Lets ragdolls be stored in a slot.")
		settingsForm:CheckBox("Show Ragdoll Models on Holster", "vrmod_holster_ragdoll_models")
		settingsForm:ControlHelp("Draws a stored ragdoll at its slot.")
		settingsForm:CheckBox("Persist Holster Across Map Changes", "vrmod_holster_persist")
		settingsForm:ControlHelp("Keeps what's in your slots when the map changes.")

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
		modelForm:ControlHelp("Which slots get the model.")
		modelForm:NumSlider("Forward offset", "vrmod_holster_model_x", -32, 32, 1)
		modelForm:NumSlider("Sideways offset", "vrmod_holster_model_y", -32, 32, 1)
		modelForm:NumSlider("Vertical offset", "vrmod_holster_model_z", -32, 32, 1)
		modelForm:ControlHelp("Where the model sits relative to each slot's grip point, in units.")
		modelForm:NumSlider("Pitch", "vrmod_holster_model_p", -180, 180, 0)
		modelForm:NumSlider("Yaw", "vrmod_holster_model_yaw", -180, 180, 0)
		modelForm:NumSlider("Roll", "vrmod_holster_model_r", -180, 180, 0)
		modelForm:ControlHelp("Rotation is applied on top of your body yaw, so the holster turns with you.")
		local hmReset = modelForm:Button("Reset Holster Model")
		modelForm:ControlHelp("Puts every Holster Model setting back to its default.")
		function hmReset:DoClick()
			local l = {"vrmod_holster_model_enabled", "vrmod_holster_model", "vrmod_holster_model_x", "vrmod_holster_model_y",
				"vrmod_holster_model_z", "vrmod_holster_model_p", "vrmod_holster_model_yaw", "vrmod_holster_model_r"}
			for s = 1, POUCH_SLOTS do l[#l + 1] = "vrmod_holster_model_slot" .. s end
			ResetCvars(l)
		end

		local sizeForm = vgui.Create("DForm", t)
		sizeForm:SetName("Holster Sizes")
		sizeForm:Dock(TOP)
		sizeForm:DockMargin(5, 5, 5, 0)
		sizeForm:SetExpanded(true)
		for i = 1, POUCH_SLOTS do
			sizeForm:NumSlider(holsterPositions[i].part .. " (" .. holsterPositions[i].side .. ")", "vrmod_pouch_size_" .. i, 1, 100, 0)
		end
		sizeForm:ControlHelp("How close a hand has to be to each slot to use it, in units (default 9 head, 6 chest).")

		local slotForm = vgui.Create("DForm", t)
		slotForm:SetName("Weapon Slots")
		slotForm:Dock(TOP)
		slotForm:DockMargin(5, 5, 5, 0)
		slotForm:SetExpanded(true)
		for i = 1, POUCH_SLOTS do
			slotForm:TextEntry(holsterPositions[i].part .. " (" .. holsterPositions[i].side .. ")", "vrmod_pouch_weapon_" .. i)
		end
		slotForm:ControlHelp("Weapon class held in each slot. Filled in when you holster a weapon; clear one to empty the slot.")
	end

	-- ─────────────── Client > HUD/UI ───────────────
	do
		local t = vgui.Create("DScrollPanel", clientSheet)
		clientSheet:AddSheet("HUD/UI", t, "icon16/layers.png")

		-- A DForm like every other tab (was hand-placed at fixed pixel
		-- positions, with a 525px spacer holding the Arm HUD section below)
		local PLACE_CVARS = {"vrmod_hudmode", "vrmod_hudattach", "vrmod_hudarmscale", "vrmod_hudcrt", "vrmod_hudarm_x",
			"vrmod_hudarm_y", "vrmod_hudarm_z", "vrmod_hudarm_p", "vrmod_hudarm_yaw", "vrmod_hudarm_r"}
		local hud = vgui.Create("DForm", t)
		hud:SetName("HUD")
		hud:Dock(TOP)
		hud:DockMargin(5, 5, 5, 0)
		hud:SetExpanded(true)
		hud:CheckBox("Enable HUD", "vrmod_hud")
		hud:ControlHelp("Shows the game's HUD (health, ammo and so on) on a panel in VR.")
		hud:NumSlider("HUD Curve", "vrmod_hudcurve", -100, 100, 0)
		hud:ControlHelp("How far the front HUD panel wraps around you. 0 = flat.")
		hud:NumSlider("HUD Distance", "vrmod_huddistance", 1, 100, 0)
		hud:ControlHelp("How far in front of you the front HUD floats.")
		hud:NumSlider("HUD Scale", "vrmod_hudscale", 0.01, 0.1, 2)
		hud:ControlHelp("Size of the front HUD panel.")
		hud:NumSlider("HUD Transparency", "vrmod_hudtestalpha", 0, 255, 0)
		hud:ControlHelp("Darkness of the backing behind the HUD. 0 = no backing.")
		hud:CheckBox("HUD only while pressing menu key", "vrmod_hud_visible_quickmenukey")
		hud:ControlHelp("Keeps the HUD hidden until you hold the quick menu button.")
		hud:CheckBox("[Menu & UI Red Outline]", "vrmod_ui_outline")
		hud:ControlHelp("Outlines every VR menu and UI panel in red, to see where their edges are.")

		local fontDropdown = hud:ComboBox("Weapon Menu Font")
		local hudFonts = {"Trebuchet MS", "Arial", "Verdana", "Tahoma", "Roboto", "Courier New", "Impact"}
		for _, fnt in ipairs(hudFonts) do fontDropdown:AddChoice(fnt) end
		fontDropdown:SetValue(GetConVar("vrmod_hud_font") and GetConVar("vrmod_hud_font"):GetString() or "Trebuchet MS")
		fontDropdown.OnSelect = function(_, _, val) RunConsoleCommand("vrmod_hud_font", val) end
		hud:ControlHelp("Font used by the weapon selection menu.")

		-- Color selector
		local modeDropdown = hud:ComboBox("Color")
		modeDropdown:SetValue("Beam Color")
		modeDropdown:AddChoice("Beam Color")
		modeDropdown:AddChoice("Laser Color")
		modeDropdown:AddChoice("HUD Color")
		hud:ControlHelp("Which colour the picker edits. Beam: the menu pointer beam. Laser: the weapon laser pointer. HUD: the weapon menu.")
		local mixer = vgui.Create("DColorMixer")
		hud:AddItem(mixer)
		mixer:SetTall(200)
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

		local btn2 = hud:Button("Set Defaults")
		hud:ControlHelp("Puts every HUD and HUD Placement setting, and the three colours, back to default.")
		btn2.DoClick = function()
			RunConsoleCommand("vrmod_hud", "1")
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
			ResetCvars(PLACE_CVARS)
		end


		local armSection = vgui.Create("DForm", t)
		armSection:SetName("HUD Placement")
		armSection:Dock(TOP)
		armSection:DockMargin(5, 5, 5, 5)
		armSection:SetExpanded(true)

		-- Rows only Arm modes use, hidden in Front mode (UpdateArmControlsVisibility)
		local armRows = {}
		local function Arm(p) armRows[#armRows + 1] = p:GetParent() end
		local hudModeCombo = armSection:ComboBox("HUD Placement", "vrmod_hudmode")
		hudModeCombo:AddChoice("Front", "0")
		hudModeCombo:AddChoice("Left Arm", "1")
		hudModeCombo:AddChoice("Right Arm (default)", "2")
		armSection:ControlHelp("Front floats the HUD ahead of you. Left or Right Arm puts it on that forearm, like a watch.")

		local hudAttachCombo = armSection:ComboBox("Attach To", "vrmod_hudattach")
		Arm(hudAttachCombo)
		hudAttachCombo:AddChoice("Forearm (bone)", "0")
		hudAttachCombo:AddChoice("Hand (controller)", "1")
		Arm(armSection:ControlHelp("Forearm tracks the player model's arm bone. Hand tracks the VR controller directly."))
		Arm(armSection:NumSlider("Arm HUD Scale", "vrmod_hudarmscale", 0.01, 0.15, 4))
		Arm(armSection:ControlHelp("Size of the arm HUD."))
		Arm(armSection:NumSlider("CRT Distortion", "vrmod_hudcrt", 0, 0.5, 2))
		Arm(armSection:ControlHelp("Barrel distortion for arm HUD. 0 = flat."))
		Arm(armSection:NumSlider("Offset X (along arm)", "vrmod_hudarm_x", -20, 20, 2))
		Arm(armSection:NumSlider("Offset Y (left/right)", "vrmod_hudarm_y", -20, 20, 2))
		Arm(armSection:NumSlider("Offset Z (up/down)", "vrmod_hudarm_z", -20, 20, 2))
		Arm(armSection:ControlHelp("Where the arm HUD sits on the arm, in units."))
		Arm(armSection:NumSlider("Pitch", "vrmod_hudarm_p", -180, 180, 1))
		Arm(armSection:NumSlider("Yaw", "vrmod_hudarm_yaw", -180, 180, 1))
		Arm(armSection:NumSlider("Roll", "vrmod_hudarm_r", -180, 180, 1))
		Arm(armSection:ControlHelp("Rotation of the arm HUD, in degrees."))
		local armRestoreBtn = armSection:Button("Restore HUD Placement Defaults")
		armSection:ControlHelp("Puts every HUD Placement setting back to its default.")

		-- Show/hide arm-specific rows based on mode. A description row also
		-- needs descriptions on; vrHidden keeps ShowHelp from re-showing it.
		local function UpdateArmControlsVisibility()
			local modeCV = GetConVar("vrmod_hudmode")
			local m = modeCV and modeCV:GetInt() or 0
			local isArm = (m == 1 or m == 2)
			local help = cv_help:GetBool()
			for _, row in ipairs(armRows) do
				if IsValid(row) then
					row.vrHidden = not isArm
					row:SetVisible(isArm and (help or not row.vrHelp))
				end
			end
			armSection:InvalidateLayout(true)
			t:InvalidateLayout(true)
		end
		hudModeCombo.OnSelect = function(self, idx, val, data)
			RunConsoleCommand("vrmod_hudmode", data)
			timer.Simple(0.05, UpdateArmControlsVisibility)
		end
		function armRestoreBtn:DoClick()
			ResetCvars(PLACE_CVARS)
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

		form:CheckBox("Weapon menu equips to left hand", "vrmod_weaponmenu_lefthand")
		form:ControlHelp("Off = right hand (default). A grip press after the menu closes still picks the hand.")
		form:CheckBox("Disable Pickup", "vr_pickup_disable_client")
		form:ControlHelp("Turns off grabbing things with your hands.")
		form:CheckBox("Drop weapon on grip release", "vrmod_weapondrop_enable")
		form:ControlHelp("Letting go of the grip drops the weapon you're holding.")
		form:NumSlider("Grip release threshold %", "vrmod_weapondrop_release", 5, 90, 0)
		form:ControlHelp("Weapon drops when grip squeeze falls below this percent. Lower = must let go more fully before it drops")
		form:CheckBox("Manual item pickup", "vrmod_manualpickups")
		form:ControlHelp("Weapons and items on the floor aren't collected by walking over them; pick them up with your hands.")
		form:CheckBox("Interactive buttons", "vrmod_interactive_buttons")
		form:ControlHelp("Map buttons, chargers and ammo crates are pressed by grabbing them.")
		form:CheckBox("Replace weapons with ArcVR on pickup", "vrmod_weapon_swap")
		form:ControlHelp("Weapons you pick up are swapped for their ArcVR versions, where one exists.")
		form:CheckBox("Show Pickup halos", "vrmod_pickup_halos")
		form:ControlHelp("Outlines what each hand would grab: orange for the left, cyan for the right.")
		form:CheckBox("Disable forced crouch jump", "vrmod_nocrouchjump")
		form:ControlHelp("The jump button only jumps. Off, it also crouches mid-air, which clears higher ledges.")
		form:CheckBox("Ragdoll death", "vrmod_deathcam_ragdoll")
		form:ControlHelp("When you die, your view rides your ragdoll's head. Can cause motion sickness.")
		form:CheckBox("Ragdoll death follows rotation of head", "vrmod_deathcam_ragdoll_view")
		form:ControlHelp("Also turns your view with the ragdoll's head. Needs Ragdoll death.")
		form:CheckBox("Teleportation", "vrmod_allow_teleport_client")
		form:ControlHelp("Use the teleport button to teleport, where the server allows it.")
		form:CheckBox("Use Left hand for Teleportation", "vrmod_teleport_use_left")
		form:ControlHelp("Aim teleports with the left hand instead of the right.")

		-- Weapon menu style
		local wmCombo = form:ComboBox("Weapon menu style", "vrmod_weaponmenu_style")
		wmCombo:AddChoice("Radial Wheel", "0")
		wmCombo:AddChoice("Legacy HL2 Grid", "1")
		local wmVal = GetConVar("vrmod_weaponmenu_style")
		wmCombo:ChooseOptionID((wmVal and wmVal:GetInt() or 0) + 1)
		form:ControlHelp("Radial Wheel picks a weapon by pointing at it. Legacy HL2 Grid uses HL2's slot layout.")

		-- Menu hand
		if not ConVarExists("vrmod_menu_hand") then CreateClientConVar("vrmod_menu_hand", "0", true, false, "Which hand menus spawn on", 0, 1) end
		local mhCombo = form:ComboBox("Menu hand", "vrmod_menu_hand")
		mhCombo:AddChoice("Right Hand", "0")
		mhCombo:AddChoice("Left Hand", "1")
		mhCombo:ChooseOptionID((GetConVar("vrmod_menu_hand"):GetInt() or 0) + 1)
		form:ControlHelp("Which hand the quick menu and weapon menu open on.")

		-- Flashlight
		if not ConVarExists("vrmod_flashlight_attachment") then CreateClientConVar("vrmod_flashlight_attachment", "0", true, false, "Flashlight source: 0=Right Hand, 1=Left Hand, 2=Head") end
		local flCombo = form:ComboBox("Flashlight attachment", "vrmod_flashlight_attachment")
		flCombo:SetSortItems(false)
		flCombo:AddChoice("Right Hand", "0")
		flCombo:AddChoice("Left Hand", "1")
		flCombo:AddChoice("Head", "2")
		local flCV = GetConVar("vrmod_flashlight_attachment")
		flCombo:ChooseOptionID((flCV and flCV:GetInt() or 0) + 1)
		form:ControlHelp("Where the flashlight shines from.")

		-- Two-handed grip aim (foregrip.lua)
		form:NumSlider("Foregrip aim smoothing", "vrmod_foregrip_smooth", 0, 30, 0)
		form:ControlHelp("Filters two-handed aim jitter. Higher = snappier, 0 = off (raw)")
		form:NumSlider("Virtual stock blend", "vrmod_foregrip_stock", 0, 1, 2)
		form:ControlHelp("Blends aim toward a shoulder pivot while the gun hand is shouldered. 0 = off")
		form:NumSlider("Stock engage distance", "vrmod_foregrip_stock_dist", 4, 20, 0)
		form:ControlHelp("How close the gun hand must be to the shoulder to engage the stock")

		-- The fixer adds its own top-level tab (VRMod_Menu); jump to it. The
		-- standalone window is the fallback if that tab never got built.
		local adjustBtn = form:Button("Weapon Fixer")
		function adjustBtn:DoClick()
			local tab = frame.WeaponFixTab
			if IsValid(tab) then topSheet:SetActiveTab(tab) return end
			frame:Close()
			RunConsoleCommand("vrmod_weaponfix_menu")
		end
		form:ControlHelp("Goes to the Weapon Fixer tab: per-weapon grip offsets, hand pose, animations, worldmodel mode and manual reload setup.")

		local resetBtn = form:Button("Reset Client Gameplay Defaults")
		form:ControlHelp("Puts every Client Gameplay setting back to its default.")
		function resetBtn:DoClick()
			ResetCvars({"vrmod_allow_teleport_client", "vr_pickup_disable_client", "vrmod_weapondrop_enable",
				"vrmod_weapondrop_release", "vrmod_manualpickups", "vrmod_interactive_buttons", "vrmod_weapon_swap",
				"vrmod_pickup_halos", "vrmod_weaponmenu_style", "vrmod_foregrip_smooth",
				"vrmod_foregrip_stock", "vrmod_foregrip_stock_dist", "vrmod_menu_hand"})
		end
	end

	-- ─────────────── Client > Collisions ───────────────
	do
		local t = vgui.Create("DScrollPanel", clientSheet)
		clientSheet:AddSheet("Collisions", t, "icon16/brick.png")
		local form = vgui.Create("DForm", t)
		form:SetName("Hand & Weapon Collisions")
		form:Dock(TOP)
		form:DockMargin(5, 5, 5, 0)
		form:SetExpanded(true)
		form:CheckBox("Enable wall collisions", "vrmod_collisions")
		form:ControlHelp("Hands and weapons stop at walls, floors and bodies instead of passing through. A gun pressed into a wall bends its barrel off it.")
		form:NumSlider("Rounded edges", "vrmod_collision_round", 0, 8, 1)
		form:ControlHelp("Rounds map brush edges for hands and barrels, so they slide and turn smoothly over a corner instead of snapping face to face. Radius in units; 0 = sharp edges.")
		form:NumSlider("Muzzle wall clearance", "vrmod_gunwall_clearance", 0, 8, 1)
		form:ControlHelp("Gap kept between the muzzle and a wall when the barrel bends off it, in units.")
		form:CheckBox("Predict stops on heavy props", "vrmod_hull_predict")
		form:ControlHelp("A hand or weapon stops on a prop too heavy to push the moment it touches it, instead of a network round trip later. Needs hand physics on the server.")
		local resetBtn = form:Button("Reset Collision Defaults")
		form:ControlHelp("Puts every setting in this section back to its default.")
		function resetBtn:DoClick() ResetCvars({"vrmod_collisions", "vrmod_collision_round", "vrmod_gunwall_clearance", "vrmod_hull_predict"}) end
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
		form:ControlHelp("Punches and hand swings deal damage. The server has to allow melee too.")
		form:CheckBox("Enable kicking", "cl_vrmod_kick")
		form:ControlHelp("Kicks with full-body foot trackers deal damage. The server has to allow kicking too.")
		form:CheckBox("Enable headbutting", "cl_vrmod_headbutt")
		form:ControlHelp("Headbutts deal damage. The server has to allow headbutting too.")
	end

	-- ─────────────── Client > Vehicles ───────────────
	do
		local t = vgui.Create("DScrollPanel", clientSheet)
		clientSheet:AddSheet("Vehicles", t, "icon16/car.png")
		local form = vgui.Create("DForm", t)
		form:SetName("Steering Wheel")
		form:Dock(TOP)
		form:DockMargin(5, 5, 5, 0)
		form:SetExpanded(true)
		form:CheckBox("Enable steering wheel", "vrmod_wheel")
		form:ControlHelp("Squeeze a grip on the rim to take hold, then turn it to steer. Uses the vehicle's own steering wheel or handlebars when its model has one. Pushing the steer stick takes over once you let go.")
		form:CheckBox("Virtual wheel when there is none", "vrmod_wheel_virtual")
		form:ControlHelp("Vehicles without a steering wheel get one drawn in front of you. Plain seats never do.")
		form:CheckBox("Hands rest on the wheel", "vrmod_wheel_autohands")
		form:ControlHelp("For driving with the stick or a physical (force feedback) wheel: a hand touching the rim, or behind the wheel, grips it and turns with it. The hands never steer.")
		form:CheckBox("Driving animation hands", "vrmod_wheel_animhands")
		form:ControlHelp("A hand at the wheel (touching the rim, or behind and below it, as above) goes where your playermodel's driving animation puts it, as in normal GMod. Move it away and it's yours again. The hands never steer. Overrides the option above.")
		form:CheckBox("Always show the wheel ring", "vrmod_wheel_show")
		form:ControlHelp("Draws the grab ring on real wheels too, to check it lines up.")
		form:NumSlider("Wheel Radius", "vrmod_wheel_radius", 3, 20, 1)
		form:NumSlider("Wheel Lock", "vrmod_wheel_lock", 30, 450, 0)
		form:ControlHelp("Rim radius in units, and how far the wheel turns from centre to full lock, in degrees.")
		form:NumSlider("Handlebar Radius", "vrmod_wheel_bar_radius", 4, 24, 1)
		form:NumSlider("Handlebar Lock", "vrmod_wheel_bar_lock", 10, 90, 0)
		form:ControlHelp("The same for motorcycle handlebars: half their width, and their turn to full lock.")
		local calBtn = form:Button("Calibrate This Vehicle")
		form:ControlHelp("Seated as the driver: hold the rim at 9 and 3 o'clock and squeeze both grips for a second. Saved per vehicle model, and used over its own wheel or the virtual one. Press again to cancel.")
		function calBtn:DoClick() RunConsoleCommand("vrmod_wheel_calibrate") end
		local forgetBtn = form:Button("Forget This Vehicle's Calibration")
		function forgetBtn:DoClick() RunConsoleCommand("vrmod_wheel_calibrate", "reset") end
		local resetBtn = form:Button("Reset Defaults")
		form:ControlHelp("Puts every steering wheel setting back to its default.")
		function resetBtn:DoClick() ResetCvars({"vrmod_wheel", "vrmod_wheel_virtual", "vrmod_wheel_show", "vrmod_wheel_radius", "vrmod_wheel_lock", "vrmod_wheel_bar_radius", "vrmod_wheel_bar_lock", "vrmod_wheel_autohands", "vrmod_wheel_animhands"}) end

		local seat = vgui.Create("DForm", t)
		seat:SetName("Seat")
		seat:Dock(TOP)
		seat:DockMargin(5, 5, 5, 0)
		seat:SetExpanded(true)
		seat:NumSlider("Forward", "vrmod_seat_x", -40, 40, 1)
		seat:NumSlider("Left", "vrmod_seat_y", -40, 40, 1)
		seat:NumSlider("Up", "vrmod_seat_z", -40, 40, 1)
		seat:ControlHelp("Where your head sits in every vehicle, in units from the seat's eye position.")
		local adjBtn = seat:Button("Adjust Seat In Headset")
		seat:ControlHelp("While seated: left stick moves you forward, back and sideways, right stick up and down. Press again (or get out) to save. Also in the quick menu.")
		function adjBtn:DoClick() RunConsoleCommand("vrmod_seat_adjust") end
		local fwdBtn = seat:Button("Reset Forward")
		seat:ControlHelp("Puts your head back at the seat, facing forward. Bindable as vrmod_reset_forward; addons can call vrmod.ResetForward() or hook.Run(\"VRMod_ResetForward\").")
		function fwdBtn:DoClick() RunConsoleCommand("vrmod_reset_forward") end
		local seatReset = seat:Button("Reset Defaults")
		function seatReset:DoClick() ResetCvars({"vrmod_seat_x", "vrmod_seat_y", "vrmod_seat_z"}) end

		local aim = vgui.Create("DForm", t)
		aim:SetName("Aim Steering")
		aim:Dock(TOP)
		aim:DockMargin(5, 5, 5, 0)
		aim:SetExpanded(true)
		aim:CheckBox("Steer by aiming your right hand", "vrmod_vehicle_aimsteer")
		aim:ControlHelp("Halo-style: point where you want to go and the vehicle turns its nose toward it, flipping automatically while reversing. Pushing the steer stick takes over. Ground vehicles only; off while gripping a wheel or pointing at a menu.")
		aim:NumSlider("Full Lock Angle", "vrmod_vehicle_aimsteer_range", 5, 90, 0)
		aim:ControlHelp("How far off the nose you aim before steering hits full lock. Lower = twitchier.")
		aim:NumSlider("Deadzone", "vrmod_vehicle_aimsteer_deadzone", 0, 20, 0)
		aim:ControlHelp("Aim angle around the nose that drives straight.")

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
		entry:ControlHelp("Physically standing up gets you out of a seat.")
		local entryReset = entry:Button("Reset Defaults")
		entry:ControlHelp("Puts every Getting In and Out setting back to its default.")
		function entryReset:DoClick()
			ResetCvars({"vrmod_vehicle_gripenter", "vrmod_vehicle_gripamount", "vrmod_vehicle_gripdist", "vrmod_vehicle_sitenter", "vrmod_vehicle_sitexit"})
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
		f:ControlHelp("Grab walls and other map surfaces to climb them. The server has to allow climbing.")
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
		f:ControlHelp("Pulling yourself up past a ledge vaults you on top of it.")
		f:CheckBox("Show landing marker", "vrmod_brushclimb_marker")
		f:ControlHelp("Shows where a vault would put you.")
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
		f:ControlHelp("Puts every climbing setting back to its default.")
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
		form:ControlHelp("Drives your playermodel's face from a face tracker, through VRCFaceTracking over OSC.")
		form:CheckBox("Eye Gaze (headset eye tracking)", "ft_gaze")
		form:ControlHelp("Moves your playermodel's eyes from headset eye tracking (OpenXR, else OSC).")
		form:CheckBox("Eyes Only (gaze, leave other flexes alone)", "ft_eyesonly")
		form:ControlHelp("Uses tracking for eye gaze only and leaves every other face flex alone.")
		form:NumSlider("OSC Port", "ft_port", 1024, 65535, 0)
		form:ControlHelp("Port VRCFaceTracking sends its OSC data to.")
		form:NumSlider("Smoothing", "ft_smooth", 0, 0.95, 2)
		form:ControlHelp("Smooths the face so tracker noise doesn't twitch it. 0 = raw.")
		form:NumSlider("Net Update Rate (Hz)", "ft_rate", 5, 60, 0)
		form:ControlHelp("How many times a second your face is sent to other players.")
		form:NumSlider("Global Multiplier", "ft_multiplier", 0, 5, 2)
		form:ControlHelp("Scales every face flex. Above 1 exaggerates expressions.")
		form:CheckBox("Show Debug HUD", "ft_debug")
		form:ControlHelp("Shows the incoming tracking values on screen.")
		local btn = form:Button("Open Full Face Tracking Panel")
		btn.DoClick = function() RunConsoleCommand("ft_menu") end
		form:ControlHelp("Mapping overrides are saved per playermodel in data/facetracking/.")
	end

	-- ══════════════════════════════════════════════════════════════════
	-- SERVER TAB (nested subtabs, as Client). Server convars: changes need
	-- the host, or the RCON toggle (Client > General).
	-- ══════════════════════════════════════════════════════════════════
	local serverPanel = vgui.Create("DPanel", topSheet)
	serverPanel:Dock(FILL)
	serverPanel.Paint = nil
	local serverSheet = vgui.Create("DPropertySheet", serverPanel)
	serverSheet:SetPadding(1)
	serverSheet:Dock(FILL)
	topSheet:AddSheet("Server", serverPanel, "icon16/server.png")

	local function ServerForm(t, name)
		local f = vgui.Create("DForm", t)
		f:SetName(name)
		f:Dock(TOP)
		f:DockMargin(5, 5, 5, 0)
		f:SetExpanded(true)
		return f
	end

	-- ─────────────── Server > General ───────────────
	do
		local t = vgui.Create("DScrollPanel", serverSheet)
		serverSheet:AddSheet("General", t, "icon16/cog.png")

		-- Server presets
		BuildPresetPanel(t, PRESET_DIR_SERVER, SERVER_CVARS)

		local netForm = ServerForm(t, "Networking")
		netForm:NumSlider("Tracking rate (Hz)", "vrmod_net_tickrate", 10, 100, 0)
		netForm:ControlHelp("How many times per second tracking is sent/received. Higher = smoother, more bandwidth. Capped at 100.")
		netForm:NumSlider("Min send movement", "vrmod_net_minsend", 0, 0.1, 3)
		netForm:ControlHelp("Per-tick movement a hand/part must exceed before an update is sent. 0 = always send (fixes slow parts freezing); higher saves bandwidth by skipping tiny moves.")

		local poseForm = ServerForm(t, "Poses")
		poseForm:CheckBox("Allow poses", "vrmod_sv_poses")
		poseForm:ControlHelp("Lets VR players play their playermodel's animations from the quick menu (Poses). Turning this off stops every active pose. Server setting: needs host or the RCON toggle.")

		local tpForm = ServerForm(t, "Teleportation")
		tpForm:CheckBox("Allow Teleportation", "vrmod_allow_teleport")
		tpForm:ControlHelp("Lets VR players teleport.")
		tpForm:NumSlider("Max distance", "vrmod_teleport_maxdist", 0, 1000, 0)
		tpForm:ControlHelp("Furthest a single teleport can go, in units.")

		local resetForm = ServerForm(t, "Defaults")
		local resetBtn = resetForm:Button("Reset Server Defaults")
		resetForm:ControlHelp("Resets every setting on the Server tabs: General, Pickup, Combat and Climbing.")
		function resetBtn:DoClick()
			ResetCvars({
				"vrmod_allow_teleport", "vrmod_teleport_maxdist",
				"vrmod_pickup_limit", "vrmod_pickup_npcs", "vrmod_pickup_no_phys",
				"vrmod_pickup_weight", "vrmod_pickup_range", "vrmod_selfdamage",
				"vrmod_pickup_players", "vrmod_pickup_players_adminprotect", "vrmod_hand_physics", "vrmod_hand_interp", "vrmod_foot_physics", "vrmod_foot_force",
				"vrmod_weight", "vrmod_weight_lag", "vrmod_weight_ramp",
				"sv_vrmod_melee", "vrmod_melee_damage", "vrmod_melee_velthreshold",
				"vrmod_melee_delay", "vrmod_melee_speedscale", "vrmod_melee_fist_collisionmodel",
				"sv_vrmod_kick", "vrmod_kick_damage", "vrmod_kick_velthreshold",
				"sv_vrmod_headbutt", "vrmod_headbutt_damage", "vrmod_headbutt_velthreshold",
				"vrmod_physmelee_force", "vrmod_physmelee_damage", "vrmod_physmelee_speed",
			}, true)
		end
	end

	-- ─────────────── Server > Pickup ───────────────
	do
		local t = vgui.Create("DScrollPanel", serverSheet)
		serverSheet:AddSheet("Pickup", t, "icon16/basket.png")

		local pickupForm = ServerForm(t, "Pickup & Physics")
		pickupForm:CheckBox("Weight limit", "vrmod_pickup_limit")
		pickupForm:ControlHelp("Only props at or under the Pickup weight can be picked up.")
		pickupForm:CheckBox("Pickup NPCs", "vrmod_pickup_npcs")
		pickupForm:ControlHelp("VR players can grab NPCs, which go limp as ragdolls while held.")
		pickupForm:CheckBox("Disable prop physics", "vrmod_pickup_no_phys")
		pickupForm:ControlHelp("Held props pass through every player, and drop with player collision off.")
		pickupForm:NumSlider("Pickup weight", "vrmod_pickup_weight", 1, 100, 0)
		pickupForm:ControlHelp("Heaviest prop that can be picked up with Weight limit on, in kg. Prop Weight's lag is scaled against it too.")
		pickupForm:NumSlider("Pickup range", "vrmod_pickup_range", 0.0, 10.0, 1)
		pickupForm:ControlHelp("How far from a hand something can be grabbed. Times 10 units.")
		pickupForm:CheckBox("Hand physics props", "vrmod_hand_physics")
		pickupForm:ControlHelp("Spawns solid physics props on VR players' hands so they can shove objects around. Off despawns them, which also stops hands blocking bullets and movement. Applies live, no rejoin needed.")
		pickupForm:CheckBox("Foot physics props", "vrmod_foot_physics")
		pickupForm:ControlHelp("The same physics props on VR players' feet, following the feet the body draws (FBT trackers included), so they can kick and shove objects. Applies live.")
		pickupForm:NumSlider("Kick push", "vrmod_foot_force", 0.05, 20, 2)
		pickupForm:ControlHelp("How hard feet push and kick things: scales the foot props' physics mass (1 = a hand's 20kg). Heavier feet also get stopped by fewer props. Applies live.")
		pickupForm:CheckBox("Interpolate hand poses", "vrmod_hand_interp")
		pickupForm:ControlHelp("Plays VR players' hand poses back smoothly, slightly behind, instead of jumping to each network packet. Smooths hand props and held props on uneven connections; off reacts a few milliseconds sooner.")
		pickupForm:CheckBox("Allow grabbing players", "vrmod_pickup_players")
		pickupForm:ControlHelp("VR players can pick up other players. The target is swapped for a ragdoll and dragged along by it, the same way NPCs are. Hard landings deal fall damage.")
		pickupForm:CheckBox("Protect higher ranks", "vrmod_pickup_players_adminprotect")
		pickupForm:ControlHelp("Refuses grabs where the target's usergroup outranks the grabber's. Uses CAMI inheritance when an admin mod provides it, otherwise superadmin > admin > user.")

		local weightForm = ServerForm(t, "Prop Weight")
		weightForm:CheckBox("Enable prop weight", "vrmod_weight")
		weightForm:ControlHelp("Heavy held props drag the hand behind the controller, scaled by mass against Pickup weight. Two-hand grips share the load. Off disables it for everyone; a hold in progress eases back to normal.")
		weightForm:NumSlider("Lag at max weight (s)", "vrmod_weight_lag", 0, 2, 2)
		weightForm:ControlHelp("How far behind the hand trails at the Pickup weight limit, as a smoothing time. 0 = no lag at any mass.")
		weightForm:NumSlider("Weight curve", "vrmod_weight_ramp", 0.25, 6, 2)
		weightForm:ControlHelp("1 = lag grows linearly with mass. Higher keeps light and mid props snappy and saves the drag for the heaviest.")
	end

	-- ─────────────── Server > Combat ───────────────
	do
		local t = vgui.Create("DScrollPanel", serverSheet)
		serverSheet:AddSheet("Combat", t, "icon16/asterisk_orange.png")

		local combatForm = ServerForm(t, "Combat")
		combatForm:CheckBox("Self damage", "vrmod_selfdamage")
		combatForm:ControlHelp("VR players' own bullets can hit their own body and head.")
		combatForm:CheckBox("Enable melee", "sv_vrmod_melee")
		combatForm:ControlHelp("Allows hand melee (punches and swings) for every VR player.")
		combatForm:NumSlider("Melee Damage", "vrmod_melee_damage", 0, 10, 0)
		combatForm:ControlHelp("Base damage of a punch.")
		combatForm:NumSlider("Melee Velocity Threshold", "vrmod_melee_velthreshold", 0.1, 10, 1)
		combatForm:ControlHelp("How fast a hand has to move to count as a hit. Times 50 units/s.")
		combatForm:NumSlider("Melee Delay", "vrmod_melee_delay", 0.01, 1, 2)
		combatForm:ControlHelp("Shortest time between two hits from one hand, in seconds.")
		combatForm:NumSlider("Relative speed multiplier", "vrmod_melee_speedscale", 0.001, 0.05, 3)
		combatForm:ControlHelp("How much extra damage a faster hit deals, up to 5 times.")
		combatForm:TextEntry("Collision Model", "vrmod_melee_fist_collisionmodel")
		combatForm:ControlHelp("Model used as the fist's collision shape for punches.")
		combatForm:CheckBox("Enable kicking", "sv_vrmod_kick")
		combatForm:ControlHelp("Allows kicks with full-body foot trackers.")
		combatForm:NumSlider("Kick Damage", "vrmod_kick_damage", 0, 25, 0)
		combatForm:ControlHelp("Flat damage a kick deals, whatever weapon is held.")
		combatForm:NumSlider("Kick Velocity Threshold", "vrmod_kick_velthreshold", 0.5, 10, 1)
		combatForm:ControlHelp("How fast a foot has to move to count as a kick.")
		combatForm:CheckBox("Enable headbutting", "sv_vrmod_headbutt")
		combatForm:ControlHelp("Allows headbutts.")
		combatForm:NumSlider("Headbutt Damage", "vrmod_headbutt_damage", 0, 15, 0)
		combatForm:ControlHelp("Flat damage a headbutt deals, whatever weapon is held.")
		combatForm:NumSlider("Headbutt Velocity Threshold", "vrmod_headbutt_velthreshold", 0.5, 10, 1)
		combatForm:ControlHelp("How fast the headset has to move to count as a headbutt.")
		combatForm:NumSlider("Weapon swing damage", "vrmod_physmelee_damage", 0, 10, 2)
		combatForm:ControlHelp("Multiplies weapon swing damage. A swing at the full-damage speed deals the weapon's own damage (HL2 crowbar 10); faster swings up to double.")
		combatForm:NumSlider("Full-damage swing speed", "vrmod_physmelee_speed", 50, 3000, 0)
		combatForm:ControlHelp("Weapon tip speed (units/s) that deals full damage. Raise it to make hard swings matter more.")
		combatForm:NumSlider("Weapon swing push", "vrmod_physmelee_force", 0.05, 20, 2)
		combatForm:ControlHelp("How hard weapons push and throw things: scales the weapon's physics mass and each hit's force. A heavier weapon also gets stopped by fewer props.")
	end

	-- ─────────────── Server > Climbing ───────────────
	do
		local t = vgui.Create("DScrollPanel", serverSheet)
		serverSheet:AddSheet("Climbing", t, "icon16/arrow_up.png")

		local climbForm = ServerForm(t, "Climbing")
		climbForm:CheckBox("Allow climbing", "vrmod_sv_climbing")
		climbForm:ControlHelp("Allows climbing for VR players.")
		climbForm:CheckBox("Force whitelist ledges", "vrmod_sv_climbing_ledgeonly")
		climbForm:ControlHelp("Every VR player can only grab near the top edges of surfaces.")
		climbForm:CheckBox("Force whitelist ladders", "vrmod_sv_climbing_ladderonly")
		climbForm:ControlHelp("Every VR player can only grab ladders.")
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
		hullForm:ControlHelp("1 = GMod default (16u wide). 0.625 = the classic VR hull (10u). 0.332 = default. 0.1 = smallest (1.6u). Only applies while the reduced hull is enabled.")
		-- Rarely touched: out of the way
		local advSection = vgui.Create("DForm", hullForm)
		advSection:SetName("Advanced")
		advSection:SetExpanded(false)
		hullForm:AddItem(advSection)
		advSection:CheckBox("Affects all non-VR players", "vrmod_smallhull_all")
		advSection:ControlHelp("Gives every player the reduced hull, not just VR players, so mixed lobbies fit through the same gaps. Server setting: needs host or the RCON toggle. Non-VR players may reach spots the map assumes are sealed.")
		advSection:CheckBox("Head anti-clip", "vrmod_anticlip")
		advSection:ControlHelp("On by default. Your hull follows your hips, so your head can lean past it; this pushes your view back out of walls, doors, windows and solid props instead of letting you look through them. NPCs, players, ragdolls and what you hold don't count. Disable if an addon's collision fights it (addons can also override it with the VRMod_AllowHeadAntiClip hook).")

		local resetBtn = hullForm:Button("Reset Hull Defaults")
		hullForm:ControlHelp("Puts every hull setting back to its default.")
		function resetBtn:DoClick()
			ResetCvars({"vrmod_smallhull", "vrmod_hullscale", "vrmod_anticlip"})
			ResetCvars({"vrmod_smallhull_all"}, true)
		end
	end


	-- ══════════════════════════════════════════════════════════════════
	-- DEBUG TAB
	-- ══════════════════════════════════════════════════════════════════
	do
		local t = vgui.Create("DScrollPanel", topSheet)
		topSheet:AddSheet("Debug", t, "icon16/bug.png")
		local f = vgui.Create("DForm", t)
		f:SetName("Debug")
		f:Dock(TOP)
		f:DockMargin(5, 5, 5, 0)
		f.Header:SetVisible(false)
		f.Paint = nil
		local LEVELS = {{"OFF", 0}, {"ERROR", 1}, {"WARN", 2}, {"INFO", 3}, {"DEBUG", 4}}
		local function LogLevel(lbl, cv, help)
			if not cv then return end
			local combo = f:ComboBox(lbl)
			for i = 1, #LEVELS do combo:AddChoice(LEVELS[i][1], LEVELS[i][2], LEVELS[i][2] == cv:GetInt()) end
			combo.OnSelect = function(_, _, _, data) RunConsoleCommand(cv:GetName(), data) end
			f:ControlHelp(help)
		end
		local function ProperSubName(s)
			if s == "api" then return "API" end
			if s == "ui" then return "UI" end
			return s:sub(1, 1):upper() .. s:sub(2)
		end
		local function Sub(subsystem)
			local cvarName = "vrmod_debug_" .. subsystem
			if not (GetConVar(cvarName) or vrmod.debug_cvars and vrmod.debug_cvars[subsystem]) then return end
			local name = ProperSubName(subsystem)
			f:CheckBox("Debug " .. name, cvarName)
			f:ControlHelp("Extra debug logging from the " .. name .. " subsystem.")
		end
		LogLevel("Console log level", GetConVar("vrmod_log_console"), "How much VRMod prints to the console: DEBUG is everything, OFF is nothing.")
		LogLevel("File log level", GetConVar("vrmod_log_file"), "How much VRMod writes to its log file in data/.")
		local order = vrmod.subsystemOrder or {"api", "utils", "core", "network", "input", "player", "physics", "pickup", "combat", "ui"}
		local listed = {}
		for _, subsystem in ipairs(order) do
			listed[subsystem] = true
			Sub(subsystem)
		end
		for subsystem in pairs(vrmod.debug_cvars or {}) do
			if not listed[subsystem] then Sub(subsystem) end
		end
		f:CheckBox("Visible wall collision", "vrmod_debug_collisions")
		f:ControlHelp("Draws the hand and weapon collision shapes, yellow while they touch something.")
		f:CheckBox("Show server hand props", "vrmod_debug_hull")
		f:ControlHelp("Draws the server's physics props on each VR hand in red, where the server has them.")
		f:CheckBox("Log hand contact timing", "vrmod_debug_hullerr")
		f:ControlHelp("Prints to the console when the server reports a hand or held prop stuck on something, with the round-trip and contact-prediction timing.")
		f:CheckBox("Grab debug overlay", "vrmod_debug_grab")
		f:ControlHelp("Draws where a held thing is meant to be on your side and the server's, and logs each grab to the console.")
		f:CheckBox("Redirect server prints to VR console (can cause lags)", "vrmod_console_redirect")
		f:ControlHelp("Sends VRMod's server log lines to VR players' consoles.")
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
				f:ControlHelp("Use the reload button to grip ArcVR weapons.")
				f:CheckBox("Magazine bump preload", "arcticvr_mag_bumpreload")
				f:ControlHelp("Bumping a magazine into the gun loads it.")
				f:CheckBox("Alternative frontgrip mode", "arcticvr_grip_alternative_mode")
				f:ControlHelp("ArcVR's alternative two-hand front grip behaviour.")
				f:NumSlider("Slide magnification", "arcticvr_slide_magnification", 1, 10, 2)
				f:ControlHelp("Scales how far the slide moves for your hand's pull.")
				f:NumSlider("Grip magnification", "arcticvr_grip_magnification", 1, 10, 2)
				f:ControlHelp("Scales how strongly the front grip moves the gun.")
				f:CheckBox("Disable reload with key", "arcticvr_disable_reloadkey")
				f:ControlHelp("The reload button no longer reloads ArcVR weapons.")
				f:CheckBox("Disable grab reload", "arcticvr_disable_grabreload")
				f:ControlHelp("Grabbing no longer reloads ArcVR weapons.")
			end)
			AddSection(t, "Virtual Stock & Fixes", function(f)
				f:CheckBox("Enable virtual stock", "arcticvr_virtualstock")
				f:ControlHelp("Steadies two-handed aim as if the gun had a stock against your shoulder.")
				f:NumSlider("Frontgrip power", "arcticvr_2h_sens", 0, 2, 2)
				f:ControlHelp("How strongly the front hand steers a two-handed gun.")
				f:CheckBox("Grenade pin enable", "arcticvr_grenade_pin_enable")
				f:ControlHelp("Grenades need their pin pulled before they're thrown.")
				f:CheckBox("Shoot system fix", "arcticvr_shootsys")
				f:ControlHelp("ArcVR's compatibility fix for its shooting system.")
				f:CheckBox("Misc client fix", "arcticvr_test_cl_misc_fix")
				f:ControlHelp("ArcVR's miscellaneous client-side fixes.")
			end)
			AddSection(t, "Physical Gunstock", function(f)
				f:CheckBox("Enable physical gunstock", "arcticvr_physstock_enable")
				f:ControlHelp("Offset applied in gun-local space when foregripping a two-handed non-pistol weapon")
				f:NumSlider("Pos X (forward)", "arcticvr_physstock_pos_x", -20, 20, 2)
				f:NumSlider("Pos Y (right)", "arcticvr_physstock_pos_y", -20, 20, 2)
				f:NumSlider("Pos Z (up)", "arcticvr_physstock_pos_z", -20, 20, 2)
				f:ControlHelp("Stock position along the gun's axes, in units.")
				f:NumSlider("Ang pitch", "arcticvr_physstock_ang_p", -45, 45, 2)
				f:NumSlider("Ang yaw", "arcticvr_physstock_ang_y", -45, 45, 2)
				f:NumSlider("Ang roll", "arcticvr_physstock_ang_r", -45, 45, 2)
				f:ControlHelp("Stock rotation, in degrees.")
			end)
			AddSection(t, "Mag Pouches", function(f)
				f:NumSlider("Default pouch distance", "arcticvr_defpouchdist", 0, 200, 2)
				f:ControlHelp("Reach of the default magazine pouch.")
				f:CheckBox("Hybrid pouch", "arcticvr_hybridpouch")
				f:ControlHelp("Adds ArcVR's hybrid magazine pouch.")
				f:NumSlider("Hybrid pouch distance", "arcticvr_hybridpouchdist", 0, 200, 1)
				f:ControlHelp("Reach of the hybrid pouch.")
				f:CheckBox("Head pouch", "arcticvr_headpouch")
				f:ControlHelp("Adds a magazine pouch at your head.")
				f:NumSlider("Head pouch distance", "arcticvr_headpouchdist", 0, 200, 1)
				f:ControlHelp("Reach of the head pouch.")
				f:CheckBox("Infinite pouch range", "arcticvr_infpouch")
				f:ControlHelp("Magazines can be taken from the pouch at any distance.")
			end)
			AddSection(t, "Server Settings", function(f)
				f:CheckBox("Allow reload key (all guns)", "arcticvr_allgun_allow_reloadkey")
				f:ControlHelp("Server: the reload button reloads every ArcVR gun.")
				f:CheckBox("Allow reload key (client)", "arcticvr_allgun_allow_reloadkey_client")
				f:ControlHelp("Client side of the reload button setting above.")
				f:CheckBox("Bump reload (all guns)", "arcticvr_bumpreload_allgun")
				f:ControlHelp("Server: bump reloading works on every ArcVR gun.")
				f:CheckBox("Bump reload (client)", "arcticvr_bumpreload_allgun_client")
				f:ControlHelp("Client side of the bump reload setting above.")
				f:CheckBox("Normalize default ammo", "arcticvr_defaultammo_normalize")
				f:ControlHelp("Evens out the ammo ArcVR weapons come with.")
				f:CheckBox("Alternate physics bullets", "arcticvr_physical_bullets")
				f:ControlHelp("Uses ArcVR's alternate physical bullets.")
				f:NumSlider("Mag pickup delay", "arcticvr_net_magtimertime", 0, 1, 2)
				f:ControlHelp("Delay before a dropped magazine can be picked up, in seconds.")
				f:CheckBox("Flick reload", "arcticvr_flickreload")
				f:ControlHelp("Flicking the gun reloads it.")
				f:CheckBox("Flick reload (dual wield)", "arcticvr_flickreload_dw")
				f:ControlHelp("Flick reloading while dual wielding.")
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
		importForm:ControlHelp("Whether the pasted settings are a client or a server preset.")

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
	-- Sorted by name for a stable tab order, each isolated so one broken addon
	-- can't take the rest (or the menu) down. String ids only: object-keyed
	-- hooks can't be sorted against them.
	local hooks = hook.GetTable().VRMod_Menu
	if hooks then
		local names = {}
		for k in pairs(hooks) do
			if isstring(k) then names[#names + 1] = k end
		end
		table.sort(names)
		for i = 1, #names do
			local ok, err = pcall(hooks[names[i]], frame)
			if not ok then ErrorNoHalt("[VRMod Menu] " .. names[i] .. ": " .. tostring(err) .. "\n") end
		end
	end
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