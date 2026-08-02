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

local eyeVec = Vector()
local function ComputeEyeTarget(ply, data)
	local lr = (data["v2/EyeLookOutRight"] or 0) + (data["v2/EyeLookInLeft"] or 0)
	local ll = (data["v2/EyeLookOutLeft"] or 0) + (data["v2/EyeLookInRight"] or 0)
	local lu = ((data["v2/EyeLookUpRight"] or 0) + (data["v2/EyeLookUpLeft"] or 0)) * 0.5
	local ld = ((data["v2/EyeLookDownRight"] or 0) + (data["v2/EyeLookDownLeft"] or 0)) * 0.5
	local ea = ply:EyeAngles()
	ea:RotateAroundAxis(ea:Right(), (ld - lu) * 22.5)
	ea:RotateAroundAxis(ea:Up(), (lr - ll) * 22.5)
	local f = ea:Forward()
	eyeVec:Set(ply:EyePos())
	eyeVec.x = eyeVec.x + f.x * 1000
	eyeVec.y = eyeVec.y + f.y * 1000
	eyeVec.z = eyeVec.z + f.z * 1000
	return eyeVec
end

-- ── Net: send mapped flexes ─────────────────────────────────────────────────

local function SendFlexData(ply)
	if not activeMap then return end
	local cnt = #activeMap
	if cnt == 0 or cnt > 128 then return end

	net.Start("ft_flex")
		net.WriteUInt(cnt, 8)
		for i = 1, cnt do
			local e = activeMap[i]
			net.WriteUInt(e.id, 8)
			net.WriteUInt(floor(Clamp(smoothed[e.id] or 0, 0, 1) * 255 + 0.5), 8)
		end
		local hasEye = vrmod.FaceTrackingActive()
		net.WriteBool(hasEye)
		if hasEye then net.WriteVector(ComputeEyeTarget(ply, lastData)) end
	net.SendToServer()
end

-- ── Net: receive remote player flex data ────────────────────────────────────

net.Receive("ft_flex", function()
	local ply = net.ReadEntity()
	local cnt = net.ReadUInt(8)

	if not IsValid(ply) or ply == LocalPlayer() or cnt == 0 then
		-- drain remaining bytes
		for _ = 1, cnt do net.ReadUInt(8); net.ReadUInt(8) end
		if net.ReadBool() then net.ReadVector() end
		return
	end

	local rd = remoteData[ply]
	if not rd then
		rd = { id = {}, wt = {}, n = 0, eye = nil }
		remoteData[ply] = rd
	end

	rd.n = cnt
	local ids, wts = rd.id, rd.wt
	for i = 1, cnt do
		ids[i] = net.ReadUInt(8)
		wts[i] = net.ReadUInt(8) / 255
	end
	if net.ReadBool() then
		rd.eye = net.ReadVector()
	else
		rd.eye = nil
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
	if not cv_enabled:GetBool() then
		if listening then Stop() end
		return
	end
	if not listening then Start() end
	if not listening then return end

	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then return end

	vrmod.FaceTrackingPoll()
	if not vrmod.FaceTrackingActive() then return end

	lastData = vrmod.FaceTrackingGetData()

	-- Rebuild known param list on count change
	local cnt = 0
	for _ in pairs(lastData) do cnt = cnt + 1 end
	if cnt ~= paramCount then
		paramCount = cnt
		local sorted = {}
		for k in pairs(lastData) do sorted[#sorted + 1] = k end
		table.sort(sorted)
		FaceTrack.knownParams = sorted
	end

	ResolveMapping(ply)
	if not activeMap then return end

	local alpha = Clamp(cv_smooth:GetFloat(), 0, 0.95)
	local oneMinusAlpha = 1 - alpha
	local mult = cv_mult:GetFloat()

	for i = 1, #activeMap do
		local entry = activeMap[i]
		local val = entry.bias
		local sources = entry.sources
		for j = 1, #sources do
			local src = sources[j]
			local raw = lastData[src.param]
			if raw then val = val + raw * src.scale end
		end
		val = val * mult
		local id = entry.id
		smoothed[id] = (smoothed[id] or 0) * alpha + val * oneMinusAlpha
	end

	local now = CurTime()
	if now - lastNetSend >= 1 / cv_rate:GetInt() then
		lastNetSend = now
		SendFlexData(ply)
	end
end)

-- ── PrePlayerDraw: apply flex weights after engine lip sync ──────────────────

hook.Add("PrePlayerDraw", "facetracking_flex", function(ply)
	if ply == LocalPlayer() then
		if not activeMap then return end
		for i = 1, #activeMap do
			local e = activeMap[i]
			ply:SetFlexWeight(e.id, smoothed[e.id] or 0)
		end
		ply:SetEyeTarget(ComputeEyeTarget(ply, lastData))
	else
		local rd = remoteData[ply]
		if not rd then return end
		local ids, wts, n = rd.id, rd.wt, rd.n
		for i = 1, n do
			ply:SetFlexWeight(ids[i], wts[i])
		end
		if rd.eye then ply:SetEyeTarget(rd.eye) end
	end
end)

-- ── Debug HUD ───────────────────────────────────────────────────────────────

local paramActivity = {}

hook.Add("HUDPaint", "facetracking_debug", function()
	if not cv_debug:GetBool() or not listening then return end
	local active = vrmod.FaceTrackingActive()
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
	draw.SimpleText(Format("FaceTrack: %s (%d params) mult=%.1fx",
		active and "RECEIVING" or "NO DATA", paramCount, cv_mult:GetFloat()),
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