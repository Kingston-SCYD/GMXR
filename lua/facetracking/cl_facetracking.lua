-- cl_facetracking.lua
if not vrmod then return end
if not vrmod.FaceTrackingStart then return end

FaceTrack = FaceTrack or {}

local IsValid     = IsValid
local LocalPlayer = LocalPlayer
local CurTime     = CurTime
local RealTime    = RealTime
local Clamp       = math.Clamp
local floor       = math.floor
local abs         = math.abs
local sin, sqrt   = math.sin, math.sqrt
local pairs       = pairs
local ipairs      = ipairs
local Format      = string.format

local cv_enabled  = CreateClientConVar("ft_enabled", "1", true, false, "Enable face tracking")
local cv_port     = CreateClientConVar("ft_port", "9000", true, false, "VRCFaceTracking OSC port")
local cv_rate     = CreateClientConVar("ft_rate", "30", true, false, "Net update rate (Hz)")
local cv_smooth   = CreateClientConVar("ft_smooth", "0.5", true, false, "Smoothing factor 0-0.95")
local cv_debug    = CreateClientConVar("ft_debug", "0", false, false, "Show debug HUD overlay")
local cv_debugcnt = CreateClientConVar("ft_debug_count", "20", false, false, "Debug HUD param count")
local cv_mult     = CreateClientConVar("ft_multiplier", "1", true, false, "Global flex multiplier")
local cv_gaze     = CreateClientConVar("ft_gaze", "1", true, false, "Drive playermodel eyes from eye tracking (OpenXR, else OSC)")
local cv_eyesonly = CreateClientConVar("ft_eyesonly", "0", true, false, "Use tracking for eye gaze only; leave every other flex alone")

local FTPoll, FTActive, FTGetData = vrmod.FaceTrackingPoll, vrmod.FaceTrackingActive, vrmod.FaceTrackingGetData
local GetEyeGaze = vrmod.GetEyeGaze   -- nil on modules without XR_EXT_eye_gaze_interaction

FaceTrack.DEFAULT_MAP = {
	jaw_drop               = {{ "v2/JawOpen", 1.5 }},
	jaw_clencher           = {{ "v2/JawOpen", -1 }, bias = 1 },
	jaw_sideways           = {{ "v2/JawRight", 0.5 }, { "v2/JawLeft", -0.5 }, bias = 0.5 },
	left_mouth_drop        = {{ "v2/JawOpen", 1.2 }},
	right_mouth_drop       = {{ "v2/JawOpen", 1.2 }},
	left_inner_raiser      = {{ "v2/BrowInnerUpLeft", 1 }},
	right_inner_raiser     = {{ "v2/BrowInnerUpRight", 1 }},
	left_outer_raiser      = {{ "v2/BrowOuterUpLeft", 1 }},
	right_outer_raiser     = {{ "v2/BrowOuterUpRight", 1 }},
	left_lowerer           = {{ "v2/BrowLowererLeft", 0.6 }, { "v2/BrowPinchLeft", 0.4 }},
	right_lowerer          = {{ "v2/BrowLowererRight", 0.6 }, { "v2/BrowPinchRight", 0.4 }},
	left_lid_closer        = {{ "v2/EyeOpenLeft", -1 }, bias = 1 },
	right_lid_closer       = {{ "v2/EyeOpenRight", -1 }, bias = 1 },
	left_lid_raiser        = {{ "v2/EyeWideLeft", 1 }},
	right_lid_raiser       = {{ "v2/EyeWideRight", 1 }},
	left_squint            = {{ "v2/EyeSquintLeft", 1 }},
	right_squint           = {{ "v2/EyeSquintRight", 1 }},
	left_cheek_raiser      = {{ "v2/CheekSquintLeft", 1 }},
	right_cheek_raiser     = {{ "v2/CheekSquintRight", 1 }},
	left_cheek_puffer      = {{ "v2/CheekPuffLeft", 1 }},
	right_cheek_puffer     = {{ "v2/CheekPuffRight", 1 }},
	left_corner_puller     = {{ "v2/MouthCornerPullLeft", 0.7 }, { "v2/MouthCornerSlantLeft", 0.3 }},
	right_corner_puller    = {{ "v2/MouthCornerPullRight", 0.7 }, { "v2/MouthCornerSlantRight", 0.3 }},
	left_corner_depressor  = {{ "v2/MouthFrownLeft", 1 }},
	right_corner_depressor = {{ "v2/MouthFrownRight", 1 }},
	left_stretcher         = {{ "v2/MouthStretchLeft", 1 }},
	right_stretcher        = {{ "v2/MouthStretchRight", 1 }},
	left_funneler          = {{ "v2/LipFunnelUpperLeft", 0.5 }, { "v2/LipFunnelLowerLeft", 0.5 }},
	right_funneler         = {{ "v2/LipFunnelUpperRight", 0.5 }, { "v2/LipFunnelLowerRight", 0.5 }},
	left_puckerer          = {{ "v2/LipPuckerUpperLeft", 0.5 }, { "v2/LipPuckerLowerLeft", 0.5 }},
	right_puckerer         = {{ "v2/LipPuckerUpperRight", 0.5 }, { "v2/LipPuckerLowerRight", 0.5 }},
	left_dimpler           = {{ "v2/MouthDimpleLeft", 1 }},
	right_dimpler          = {{ "v2/MouthDimpleRight", 1 }},
	left_presser           = {{ "v2/MouthPressLeft", 1 }},
	right_presser          = {{ "v2/MouthPressRight", 1 }},
	presser                = {{ "v2/MouthPressLeft", 0.5 }, { "v2/MouthPressRight", 0.5 }},
	left_upper_raiser      = {{ "v2/MouthUpperUpLeft", 1 }},
	right_upper_raiser     = {{ "v2/MouthUpperUpRight", 1 }},
	lower_lip              = {{ "v2/MouthLowerDownLeft", 0.5 }, { "v2/MouthLowerDownRight", 0.5 }},
	left_wrinkler          = {{ "v2/NoseSneerLeft", 1 }},
	right_wrinkler         = {{ "v2/NoseSneerRight", 1 }},
	mouth_sideways         = {{ "v2/MouthUpperRight", 0.25 }, { "v2/MouthLowerRight", 0.25 },
	                          { "v2/MouthUpperLeft", -0.25 }, { "v2/MouthLowerLeft", -0.25 }, bias = 0.5 },
	tongue_up              = {{ "v2/TongueOut", 1 }},
}

-- ── State ───────────────────────────────────────────────────────────────────

local listening     = false
local lastModel     = ""
local activeMap     = nil   -- sorted array of { id, name, sources, bias }
local currentMapSrc = nil
local smoothed      = {}    -- [flexID] = float
local lastNetSend   = 0
local lastData      = {}
local paramCount    = 0
local remoteData    = {}    -- [Entity] = { id={}, wt={}, n=0, eye=Vector|nil }

FaceTrack.knownParams = {}

FaceTrack.GetListening     = function() return listening end
FaceTrack.GetActiveMap     = function() return activeMap end
FaceTrack.GetSmoothed      = function() return smoothed end
FaceTrack.GetLastData      = function() return lastData end
FaceTrack.GetParamCount    = function() return paramCount end
FaceTrack.GetCurrentMapSrc = function() return currentMapSrc end
FaceTrack.GetLastModel     = function() return lastModel end

local function ModelOverridePath(mdl)
	local name = string.match(mdl, "([^/\\]+)%.mdl$")
	return name and ("facetracking/" .. name .. ".json") or nil
end

local function LoadModelOverride(mdl)
	local path = ModelOverridePath(mdl)
	if not path or not file.Exists(path, "DATA") then return nil end
	local raw = file.Read(path, "DATA")
	if not raw then return nil end
	local tbl = util.JSONToTable(raw)
	if tbl then print("[FaceTrack] Loaded override: " .. path) end
	return tbl
end

-- ── Resolve ─────────────────────────────────────────────────────────────────

local function ResolveMapping(ply)
	local mdl = ply:GetModel()
	if mdl == lastModel and activeMap then return end
	lastModel = mdl
	currentMapSrc = LoadModelOverride(mdl) or table.Copy(FaceTrack.DEFAULT_MAP)
	activeMap = {}
	smoothed = {}
	local flexCount = ply:GetFlexNum()
	for flexName, entry in pairs(currentMapSrc) do
		local flexID = ply:GetFlexIDByName(flexName)
		if flexID and flexID >= 0 and flexID < flexCount then
			local sources = {}
			for i, src in ipairs(entry) do
				sources[i] = { param = src[1], scale = src[2] }
			end
			activeMap[#activeMap + 1] = {
				id = flexID, name = flexName,
				sources = sources, bias = entry.bias or 0,
			}
			smoothed[flexID] = 0
		end
	end
	table.sort(activeMap, function(a, b) return a.id < b.id end)
end

function FaceTrack.ForceResolve()
	lastModel = ""
	activeMap = nil
end

function FaceTrack.SaveMapping()
	if not currentMapSrc or lastModel == "" then return false end
	if activeMap then
		for _, entry in ipairs(activeMap) do
			local tbl = {}
			for i, src in ipairs(entry.sources) do
				tbl[i] = { src.param, src.scale }
			end
			tbl.bias = entry.bias
			currentMapSrc[entry.name] = tbl
		end
	end
	file.CreateDir("facetracking")
	local path = ModelOverridePath(lastModel)
	if not path then return false end
	file.Write(path, util.TableToJSON(currentMapSrc, true))
	print("[FaceTrack] Saved to data/" .. path)
	return true
end

function FaceTrack.LiveUpdateFlex(flexID, sources, bias)
	if not activeMap then return end
	for _, entry in ipairs(activeMap) do
		if entry.id == flexID then
			entry.sources = sources
			entry.bias = bias or 0
			return
		end
	end
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local flexName = ply:GetFlexName(flexID)
	if not flexName then return end
	activeMap[#activeMap + 1] = {
		id = flexID, name = flexName,
		sources = sources, bias = bias or 0,
	}
	smoothed[flexID] = 0
end

function FaceTrack.LiveRemoveFlex(flexID)
	if not activeMap then return end
	for i, entry in ipairs(activeMap) do
		if entry.id == flexID then
			table.remove(activeMap, i)
			smoothed[flexID] = nil
			return
		end
	end
end

-- ── Eye tracking ────────────────────────────────────────────────────────────
-- Headset eye tracking via OpenXR XR_EXT_eye_gaze_interaction. The module
-- returns the gaze ray's x/y in view space (+right, +up), i.e. the sine of its
-- deflection off the head; only that pair is sent. Each client rebuilds the
-- target from its own interpolated HMD pose at draw, so eyes stay locked to
-- the head instead of trailing it by a net tick. Independent of the OSC face
-- receiver: either source runs without the other.

local EYE_DIST  = 128    -- convergence distance, units
local GAZE_Q    = 1 / 127
local GAZE_HOLD = 0.4    -- keep the last gaze through blinks before releasing

local gazeX, gazeY, gazeSeen, gazeSent, gazeWhy = 0, 0, 0, false, -1
local GAZE_WHY = { [-1] = "off / not in VR", [0] = "unavailable (see console)", "binding inactive", "eyes untracked" }

-- OSC gaze fallback: VRCFT v2, VRCFT v1 / Steam Link's single-float
-- Left/RightEyeX/Y, or VRChat's native multi-float eye addresses. A sender uses one address at a time, so the
-- source is resolved when the param set changes, not probed per frame. A
-- native message lands as <address>/0..N in one go, so its probe key being
-- present means every index is.
local DEG, HALF_DEG = math.pi / 180, math.pi / 360
local OSC_GAZE = {
	"v2/EyeLeftX",
	"LeftEyeX",
	"/tracking/eye/LeftRightPitchYaw/3",
	"/tracking/eye/CenterPitchYaw/1",
	"/tracking/eye/CenterPitchYawDist/1",
	"/tracking/eye/LeftRightVec/5",
	"/tracking/eye/CenterVec/2",
	"/tracking/eye/CenterVecFull/2",
}
local oscGaze, gazeOsc = 0, false

local function ResolveOscGaze(d)
	oscGaze = 0
	for i = 1, #OSC_GAZE do
		if d[OSC_GAZE[i]] then oscGaze = i return end
	end
end

-- Degrees: +pitch down, +yaw right. Vectors: Unity axes, x right, y up.
local function ReadOscGaze(d)
	local m = oscGaze
	if m == 1 then
		return ((d["v2/EyeLeftX"] or 0) + (d["v2/EyeRightX"] or 0)) * 0.5,
			d["v2/EyeY"] or ((d["v2/EyeLeftY"] or 0) + (d["v2/EyeRightY"] or 0)) * 0.5
	elseif m == 2 then
		-- Single floats each; a missing right eye mirrors the left instead of halving it.
		-- Y is +down here (confirmed in headset), the opposite of every other source.
		local lx, ly = d.LeftEyeX, d.LeftEyeY or 0
		return (lx + (d.RightEyeX or lx)) * 0.5, -(d.EyesY or (ly + (d.RightEyeY or ly)) * 0.5)
	elseif m == 3 then
		return sin((d["/tracking/eye/LeftRightPitchYaw/1"] + d["/tracking/eye/LeftRightPitchYaw/3"]) * HALF_DEG),
			-sin((d["/tracking/eye/LeftRightPitchYaw/0"] + d["/tracking/eye/LeftRightPitchYaw/2"]) * HALF_DEG)
	elseif m == 4 then
		return sin(d["/tracking/eye/CenterPitchYaw/1"] * DEG), -sin(d["/tracking/eye/CenterPitchYaw/0"] * DEG)
	elseif m == 5 then
		return sin(d["/tracking/eye/CenterPitchYawDist/1"] * DEG), -sin(d["/tracking/eye/CenterPitchYawDist/0"] * DEG)
	elseif m == 6 then
		return (d["/tracking/eye/LeftRightVec/0"] + d["/tracking/eye/LeftRightVec/3"]) * 0.5,
			(d["/tracking/eye/LeftRightVec/1"] + d["/tracking/eye/LeftRightVec/4"]) * 0.5
	elseif m == 7 then
		return d["/tracking/eye/CenterVec/0"], d["/tracking/eye/CenterVec/1"]
	end
	local x, y, z = d["/tracking/eye/CenterVecFull/0"], d["/tracking/eye/CenterVecFull/1"], d["/tracking/eye/CenterVecFull/2"]
	local l = sqrt(x * x + y * y + z * z)
	if l > 0 then return x / l, y / l end
end
local localGaze = { on = false }   -- same shape as remoteData entries

-- Head-local target (Source axes: x fwd, y left, z up), pre-scaled.
local function StoreGaze(t, x, y)
	local q = x * x + y * y
	if q > 0.96 then q = 0.96 end
	t.f, t.l, t.u, t.on = sqrt(1 - q) * EYE_DIST, -x * EYE_DIST, y * EYE_DIST, true
end

local gazeVec = Vector()
local function ApplyGaze(ply, t)
	local fr = g_VR and g_VR.net
	fr = fr and fr[t.sid]
	fr = fr and fr.lerpedFrame
	gazeVec:SetUnpacked(t.f, t.l, t.u)
	if fr and fr.hmdAng then
		gazeVec:Rotate(fr.hmdAng)
		gazeVec:Add(fr.hmdPos)
	else
		gazeVec:Rotate(ply:EyeAngles())
		gazeVec:Add(ply:EyePos())
	end
	ply:SetEyeTarget(gazeVec)
end

-- ── Net: send mapped flexes ─────────────────────────────────────────────────

local function SendFlexData(cnt, gz)
	if cnt > 128 then cnt = 0 end
	net.Start("ft_flex")
		net.WriteUInt(cnt, 8)
		for i = 1, cnt do
			local id = activeMap[i].id
			net.WriteUInt(id, 8)
			net.WriteUInt(floor(Clamp(smoothed[id] or 0, 0, 1) * 255 + 0.5), 8)
		end
		net.WriteBool(gz)
		if gz then
			net.WriteInt(floor(Clamp(gazeX, -1, 1) * 127 + 0.5), 8)
			net.WriteInt(floor(Clamp(gazeY, -1, 1) * 127 + 0.5), 8)
		end
	net.SendToServer()
end

-- ── Net: receive remote player flex data ────────────────────────────────────

net.Receive("ft_flex", function()
	local ply = net.ReadEntity()
	if not IsValid(ply) or ply == LocalPlayer() then return end

	local rd = remoteData[ply]
	if not rd then
		rd = { id = {}, wt = {}, n = 0, on = false, sid = ply:SteamID() }
		remoteData[ply] = rd
	end

	local cnt = net.ReadUInt(8)
	rd.n = cnt
	local ids, wts = rd.id, rd.wt
	for i = 1, cnt do
		ids[i] = net.ReadUInt(8)
		wts[i] = net.ReadUInt(8) / 255
	end
	if net.ReadBool() then
		local x = net.ReadInt(8) * GAZE_Q
		StoreGaze(rd, x, net.ReadInt(8) * GAZE_Q)
	else
		rd.on = false
	end
end)

hook.Add("EntityRemoved", "facetracking_cleanup", function(ent)
	remoteData[ent] = nil
end)

-- ── Start / stop ────────────────────────────────────────────────────────────

local function Start()
	if listening then return end
	local port = cv_port:GetInt()
	if vrmod.FaceTrackingStart(port) then
		listening = true
		print("[FaceTrack] Started on port " .. port)
	else
		print("[FaceTrack] Failed to bind port " .. port)
	end
end

local function Stop()
	if not listening then return end
	vrmod.FaceTrackingStop()
	listening = false
	activeMap = nil
	lastModel = ""
	smoothed = {}
	lastData = {}
	paramCount = 0
end

FaceTrack.Start = Start
FaceTrack.Stop  = Stop

-- ── Think ───────────────────────────────────────────────────────────────────

hook.Add("Think", "facetracking_core", function()
	if cv_enabled:GetBool() then
		if not listening then Start() end
	elseif listening then
		Stop()
	end

	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then return end

	local alpha = Clamp(cv_smooth:GetFloat(), 0, 0.95)
	local oneMinusAlpha = 1 - alpha
	local cnt, ftLive = 0, false

	if listening then
		FTPoll()
		if FTActive() then
			ftLive = true
			lastData = FTGetData()

			-- Rebuild known param list on count change
			local n = 0
			for _ in pairs(lastData) do n = n + 1 end
			if n ~= paramCount then
				paramCount = n
				local sorted = {}
				for k in pairs(lastData) do sorted[#sorted + 1] = k end
				table.sort(sorted)
				FaceTrack.knownParams = sorted
				ResolveOscGaze(lastData)
			end

			if cv_eyesonly:GetBool() then
				-- Hand the face back once: zero every mapped flex locally and on
				-- the server copy (it networks to everyone), then stop driving.
				if activeMap then
					for i = 1, #activeMap do smoothed[activeMap[i].id] = 0 end
					SendFlexData(#activeMap, localGaze.on)
					activeMap = nil
				end
			else
				ResolveMapping(ply)
				local mult = cv_mult:GetFloat()
				for i = 1, #activeMap do
					local entry = activeMap[i]
					local val, hit = entry.bias, false
					local sources = entry.sources
					for j = 1, #sources do
						local raw = lastData[sources[j].param]
						if raw then val = val + raw * sources[j].scale; hit = true end
					end
					-- No source params at all = neutral, not the bias: an unsent
					-- EyeOpen left lid_closer at its bias of 1 (eyes shut).
					if not hit then val = 0 end
					local id = entry.id
					smoothed[id] = (smoothed[id] or 0) * alpha + val * mult * oneMinusAlpha
				end
				cnt = #activeMap
			end
		end
	end

	-- OpenXR: x, y | false, reason | nothing (no gaze action this session).
	-- OSC fills in whenever OpenXR has nothing this frame.
	local gx, gy
	gazeWhy = -1
	if cv_gaze:GetBool() then
		if GetEyeGaze and g_VR.active then
			gx, gy = GetEyeGaze()
			gazeWhy = gx == nil and 0 or gy
		end
		gazeOsc = not gx and ftLive and oscGaze ~= 0
		if gazeOsc then gx, gy = ReadOscGaze(lastData) end
	end
	local rt = RealTime()
	if gx then
		if not localGaze.on then gazeX, gazeY = gx, gy end   -- no ease-in from a stale pose
		gazeX = gazeX * alpha + gx * oneMinusAlpha
		gazeY = gazeY * alpha + gy * oneMinusAlpha
		gazeSeen = rt
		localGaze.sid = localGaze.sid or ply:SteamID()
		StoreGaze(localGaze, gazeX, gazeY)
	elseif localGaze.on and rt - gazeSeen > GAZE_HOLD then
		localGaze.on = false
	end

	-- One "gaze off" packet after release so remotes drop back to the default look
	local gz = localGaze.on
	if cnt == 0 and not gz and not gazeSent then return end
	local now = CurTime()
	if now - lastNetSend >= 1 / cv_rate:GetInt() then
		lastNetSend = now
		SendFlexData(cnt, gz)
		gazeSent = gz
	end
end)

-- ── PrePlayerDraw: apply flex weights after engine lip sync ──────────────────
-- Eye target goes here too: the engine re-interpolates m_viewtarget each frame,
-- and SetupWeights reads it during this player's draw.

hook.Add("PrePlayerDraw", "facetracking_flex", function(ply)
	local g
	if ply == LocalPlayer() then
		g = localGaze
		if activeMap then
			for i = 1, #activeMap do
				local id = activeMap[i].id
				ply:SetFlexWeight(id, smoothed[id] or 0)
			end
		end
	else
		g = remoteData[ply]
		if not g then return end
		local ids, wts = g.id, g.wt
		for i = 1, g.n do ply:SetFlexWeight(ids[i], wts[i]) end
	end
	if g.on then ApplyGaze(ply, g) end
end)

-- ── Debug HUD ───────────────────────────────────────────────────────────────

local paramActivity = {}

hook.Add("HUDPaint", "facetracking_debug", function()
	if not cv_debug:GetBool() then return end
	local active = listening and FTActive()
	local data, now = lastData, RealTime()
	for name, val in pairs(data) do
		local prev = paramActivity[name]
		if not prev then
			paramActivity[name] = { val = val, time = now }
		else
			if abs(val - prev.val) > 0.001 then prev.time = now end
			prev.val = val
		end
	end
	local sorted = {}
	for name, val in pairs(data) do
		sorted[#sorted + 1] = { name = name, value = val,
			lastChange = paramActivity[name] and paramActivity[name].time or 0 }
	end
	table.sort(sorted, function(a, b) return a.lastChange > b.lastChange end)
	local x, y, lineH, barW = 10, 10, 16, 120
	draw.SimpleText(Format("FaceTrack: %s (%d params) mult=%.1fx | gaze: %s",
		active and "RECEIVING" or "NO DATA", paramCount, cv_mult:GetFloat(),
		localGaze.on and Format("%s %+.2f %+.2f", gazeOsc and OSC_GAZE[oscGaze] or "OpenXR", gazeX, gazeY)
			or not GetEyeGaze and "module not rebuilt"
			or (GAZE_WHY[gazeWhy] or "?") .. (oscGaze == 0 and ", no OSC gaze" or "")),
		"DermaDefault", x, y, active and Color(80, 220, 80) or Color(220, 80, 80))
	if activeMap then
		y = y + lineH
		draw.SimpleText(Format("Model: %s | %d flexes mapped", lastModel, #activeMap),
			"DermaDefault", x, y, Color(180, 180, 180))
	end
	y = y + lineH + 4
	local shown = math.min(#sorted, cv_debugcnt:GetInt())
	for i = 1, shown do
		local p = sorted[i]
		local age = now - p.lastChange
		local a = age < 2 and 255 or (age < 5 and floor(255 * (1 - (age - 2) / 3)) or 100)
		draw.SimpleText(Format("%-36s", p.name), "DermaDefault", x, y, Color(220, 220, 220, a))
		local bx = x + 250
		surface.SetDrawColor(40, 40, 40, a)
		surface.DrawRect(bx, y + 1, barW, lineH - 2)
		if p.value < 0 then surface.SetDrawColor(255, 100, 60, a)
		else surface.SetDrawColor(60, 160, 255, a) end
		surface.DrawRect(bx, y + 1, floor(Clamp(abs(p.value), 0, 1) * barW), lineH - 2)
		draw.SimpleText(Format("%.3f", p.value), "DermaDefault", bx + barW + 6, y, Color(200, 200, 200, a))
		y = y + lineH
	end
end)

hook.Add("ShutDown", "facetracking_core", function() Stop() end)
cvars.AddChangeCallback("ft_enabled", function(_, _, val)
	if tobool(val) then Start() else Stop() end
end, "facetracking_core")
cvars.AddChangeCallback("ft_port", function()
	if listening then Stop() Start() end
end, "facetracking_core")

concommand.Add("ft_reload_map", function() FaceTrack.ForceResolve() end)
concommand.Add("ft_export_map", function() FaceTrack.SaveMapping() end)

include("facetracking/cl_facetracking_ui.lua")
print("[FaceTrack] Loaded. Type ft_menu to open settings.")