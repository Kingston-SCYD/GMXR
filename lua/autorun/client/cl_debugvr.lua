--[[
	cl_debugvr.lua — vrmod_debugvr console command
	Enters VR player state without XR hardware.
	HMD follows EyePos/EyeAngles; hands track the view so you can
	aim them at props. Broadcasts as VR player so character IK,
	networking, and all VRMod hooks treat the player as if in VR.

	+attack1 (mouse1) = left-hand grip, +attack2 (mouse2) = right-hand
	grip — drives the full pickup/holster/gravglove path for grab debug.

	Arrow keys simulate physical headset movement (playspace offset).
	SHIFT accelerates, PGUP/PGDN adjust height. R resets offset.

	Place in: lua/autorun/client/
]]

if SERVER then return end

local active = false
local LTW = LocalToWorld
local HOOK = "vrmod_debugvr"
local IsKeyDown = input.IsKeyDown
local FT = FrameTime

-- Hand offsets from HMD (same as SetupHandSimulation in cl_vrmod)
local L_OFF, R_OFF = Vector(0, 10, -30), Vector(0, -10, -30)
local HAND_ANG = Angle(90, 0, 0)

-- Playspace offset: simulates physical movement of the headset
local hmdOff = Vector()
local OFF_SPEED = 32 -- units/sec base
local OFF_FAST = 4   -- shift multiplier

-- Grip edge state (mouse1 = left hand, mouse2 = right hand)
local gripL, gripR = false, false

-- Drive a hand's grip: set input state, curl the whole hand, then fire the
-- pickup input hook so the real grab pipeline (pickup/holster/gravgloves) runs.
local function SetGrip(left, on)
	local inp = g_VR.input
	local v = on and 1 or 0
	if left then
		inp.boolean_left_pickup = on
		inp.vector1_left_squeeze = v
		local c = inp.skeleton_lefthand.fingerCurls
		c[1], c[2], c[3], c[4], c[5] = v, v, v, v, v
		hook.Call("VRMod_Input", nil, "boolean_left_pickup", on)
	else
		inp.boolean_right_pickup = on
		inp.vector1_right_squeeze = v
		local c = inp.skeleton_righthand.fingerCurls
		c[1], c[2], c[3], c[4], c[5] = v, v, v, v, v
		hook.Call("VRMod_Input", nil, "boolean_right_pickup", on)
	end
end

local function DebugStart()
	if active then print("[VR Debug] Already active") return end
	if g_VR.active then print("[VR Debug] Real VR session active — exit first") return end

	local ply = LocalPlayer()
	if not IsValid(ply) then return end

	-- Fake display/RT dimensions (no actual RTs created)
	local sw, sh = ScrW(), ScrH()
	g_VR.rtWidth = sw
	g_VR.rtHeight = sh
	g_VR.displayInfo = {ipd = 0.064, eyez = 0, fovLeft = 90, fovRight = 90}

	-- View params (read by various subsystems)
	g_VR.view = {
		x = 0, y = 0, w = sw * 0.5, h = sh,
		aspect = 1, aspectratio = 1, fov = 90,
		drawmonitors = true, drawviewmodel = false,
		znear = 1, dopostprocess = false,
	}

	-- Scale
	local cv = GetConVar("vrmod_scale")
	g_VR.scale = cv and cv:GetFloat() or 1

	-- Origin
	g_VR.origin = ply:GetPos()
	g_VR.originAngle = Angle(0, ply:EyeAngles().yaw, 0)

	-- Input defaults — preserve existing table, zero everything
	g_VR.input = g_VR.input or {}
	for k, v in pairs(g_VR.input) do
		if isbool(v) then g_VR.input[k] = false
		elseif isnumber(v) then g_VR.input[k] = 0
		elseif istable(v) and v.x then v.x, v.y = 0, 0
		end
	end
	g_VR.input.skeleton_lefthand = g_VR.input.skeleton_lefthand or {fingerCurls = {0, 0, 0, 0, 0}}
	g_VR.input.skeleton_righthand = g_VR.input.skeleton_righthand or {fingerCurls = {0, 0, 0, 0, 0}}

	-- Tracking
	local ep, ea = ply:EyePos(), ply:EyeAngles()
	g_VR.tracking = {
		hmd = {pos = ep, ang = ea, vel = Vector(), angvel = Angle()},
		pose_lefthand = {pos = Vector(), ang = Angle(), vel = Vector(), angvel = Angle()},
		pose_righthand = {pos = Vector(), ang = Angle(), vel = Vector(), angvel = Angle()},
	}
	g_VR.threePoints = true
	g_VR.sixPoints = false

	-- Place hands at initial positions (full view basis so they aim where you look)
	gripL, gripR = false, false
	g_VR.tracking.pose_lefthand.pos, g_VR.tracking.pose_lefthand.ang = LTW(L_OFF, HAND_ANG, ep, ea)
	g_VR.tracking.pose_righthand.pos, g_VR.tracking.pose_righthand.ang = LTW(R_OFF, HAND_ANG, ep, ea)

	-- Network: broadcast as VR player to server + other clients
	if VRUtilNetworkInit then VRUtilNetworkInit() end

	-- Reset playspace offset
	hmdOff.x, hmdOff.y, hmdOff.z = 0, 0, 0

	-- Think hook: drive tracking each frame (replaces XR render-loop pump)
	hook.Add("Think", HOOK, function()
		local lp = LocalPlayer()
		if not IsValid(lp) or not active then return end

		-- Arrow-key playspace offset (relative to current yaw)
		local dt = FT()
		local spd = OFF_SPEED * dt
		if IsKeyDown(KEY_LSHIFT) or IsKeyDown(KEY_RSHIFT) then spd = spd * OFF_FAST end

		if IsKeyDown(KEY_UP) or IsKeyDown(KEY_DOWN) or IsKeyDown(KEY_LEFT) or IsKeyDown(KEY_RIGHT) or IsKeyDown(KEY_PAGEUP) or IsKeyDown(KEY_PAGEDOWN) then
			local a = lp:EyeAngles()
			local fwd, rt = a:Forward(), a:Right()
			-- Flatten to horizontal plane
			fwd.z, rt.z = 0, 0
			fwd:Normalize()
			rt:Normalize()
			if IsKeyDown(KEY_UP) then hmdOff:Add(fwd * spd) end
			if IsKeyDown(KEY_DOWN) then hmdOff:Sub(fwd * spd) end
			if IsKeyDown(KEY_RIGHT) then hmdOff:Add(rt * spd) end
			if IsKeyDown(KEY_LEFT) then hmdOff:Sub(rt * spd) end
			if IsKeyDown(KEY_PAGEUP) then hmdOff.z = hmdOff.z + spd end
			if IsKeyDown(KEY_PAGEDOWN) then hmdOff.z = hmdOff.z - spd end
		end
		if IsKeyDown(KEY_R) then hmdOff.x, hmdOff.y, hmdOff.z = 0, 0, 0 end

		local p, a = lp:EyePos(), lp:EyeAngles()
		p:Add(hmdOff)

		local yw = Angle(0, a.yaw, 0)
		g_VR.tracking.hmd.pos = p
		g_VR.tracking.hmd.ang = a
		g_VR.view.angles = a
		g_VR.origin = lp:GetPos()
		g_VR.originAngle = yw
		g_VR.characterYaw = a.yaw

		-- Hands track the full view (pitch + yaw) so you can aim them at props
		g_VR.tracking.pose_lefthand.pos, g_VR.tracking.pose_lefthand.ang = LTW(L_OFF, HAND_ANG, p, a)
		g_VR.tracking.pose_righthand.pos, g_VR.tracking.pose_righthand.ang = LTW(R_OFF, HAND_ANG, p, a)

		-- +attack1 → left grip, +attack2 → right grip (edge-triggered)
		local a1 = lp:KeyDown(IN_ATTACK)
		if a1 ~= gripL then gripL = a1 SetGrip(true, a1) end
		local a2 = lp:KeyDown(IN_ATTACK2)
		if a2 ~= gripR then gripR = a2 SetGrip(false, a2) end

		-- Fire tracking hook so character IK, holsters, etc.
		hook.Call("VRMod_Tracking")

		-- Update viewmodel position if utils available
		local u = vrmod.utils
		if u and u.UpdateViewModelPos then
			u.UpdateViewModelPos(g_VR.tracking.pose_righthand.pos, g_VR.tracking.pose_righthand.ang)
		end

		-- Network: update local player frame for broadcast
		if VRUtilNetUpdateLocalPly then VRUtilNetUpdateLocalPly() end
	end)

	-- CalcView: third-person VR-style view
	hook.Add("CalcView", HOOK, function(_, _, _, fov)
		if not active then return end
		return {
			origin = g_VR.tracking.hmd.pos,
			angles = g_VR.tracking.hmd.ang,
			fov = fov,
			drawviewer = true,
		}
	end)

	-- Show local player (third person)
	hook.Add("ShouldDrawLocalPlayer", HOOK, function()
		if active then return true end
	end)

	-- Hide viewmodel
	hook.Add("PreDrawViewModel", HOOK, function()
		if active then return true end
	end)

	-- No vrmod.StartLocomotion() — debug mode uses normal Source Engine
	-- keyboard/mouse movement. VR locomotion's CreateMove would override
	-- cmd:SetForwardMove/SetSideMove with zero stick input + non-zero
	-- followVec (HMD-to-origin offset), causing constant backward drift.

	g_VR.active = true
	active = true
	print("[VR Debug] Started — vrmod_debugvr again to stop")
	print("[VR Debug] mouse1/mouse2 = grip L/R, arrows = playspace, PGUP/DN = height, SHIFT = fast, R = reset")
end

local function DebugStop()
	if not active then print("[VR Debug] Not active") return end

	-- Release any active grips so held props drop cleanly before teardown
	if gripL then SetGrip(true, false) end
	if gripR then SetGrip(false, false) end
	gripL, gripR = false, false

	active = false
	g_VR.active = false
	g_VR.threePoints = false
	g_VR.sixPoints = false
	g_VR.tracking = {}
	g_VR.displayInfo = nil
	hmdOff.x, hmdOff.y, hmdOff.z = 0, 0, 0

	hook.Remove("Think", HOOK)
	hook.Remove("CalcView", HOOK)
	hook.Remove("ShouldDrawLocalPlayer", HOOK)
	hook.Remove("PreDrawViewModel", HOOK)

	if VRUtilNetworkCleanup then VRUtilNetworkCleanup() end

	-- Debug start fires VRMod_Start (via the net join round-trip), whose
	-- handlers collapse the spawnmenu divider and set up other VR-only UI.
	-- Run VRMod_Exit locally so those handlers (restore_spawnmenu, etc.) undo
	-- themselves immediately — the net round-trip doesn't reliably re-fire it
	-- for the local player, which left the spawnmenu unusable after exit.
	local lp = LocalPlayer()
	if IsValid(lp) then hook.Run("VRMod_Exit", lp, lp:SteamID()) end

	print("[VR Debug] Stopped")
end

concommand.Add("vrmod_debugvr", function()
	if active then DebugStop() else DebugStart() end
end)