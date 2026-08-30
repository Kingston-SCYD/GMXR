AddCSLuaFile()

--[[
	VR Hull Reduction & Head Anti-Clip
	- Shrinks player collision hull for VR players (optionally for everyone)
	- Prevents HMD from clipping through walls by correcting g_VR.origin due to the smaller hull

	SetHull/SetHullDuck do NOT replicate. Client prediction runs movement
	with whatever hull is set locally, if it differs from the server's hull
	the two disagree every tick on slopes (different TryPlayerMove / StepMove
	resolutions) and the resulting per-tick corrections show as jitter.
	The apply/restore path now runs on BOTH realms to keep them in lockstep. (jockstep like jockstrap eheheheheeh)

	Respawn resets hulls engine-side on BOTH realms, so the re-apply listens to
	the shared player_spawn gameevent rather than the PlayerSpawn hook, which is
	server-only. With the hook the server kept the small hull after a respawn
	while the client silently reverted to 16u and predicted against it.
]]

local DEF_HALF  = 16 -- GMod default player half-width
local STAND_TOP = 72
local DUCK_TOP  = 36
local DEF_MINS      = Vector(-DEF_HALF, -DEF_HALF, 0)
local DEF_MAXS      = Vector( DEF_HALF,  DEF_HALF, STAND_TOP)
local DEF_DUCK_MAXS = Vector( DEF_HALF,  DEF_HALF, DUCK_TOP)

-- Scratch vectors: SetHull/SetHullDuck copy into the collision property, so
-- these can be mutated and reused instead of allocating three per call.
local SM_MINS = Vector()
local SM_MAXS = Vector()
local SM_DUCK = Vector()

local cvHull  = CreateConVar("vrmod_smallhull", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Use reduced collision hull for VR players", 0, 1)
-- Width scale only (height is left at default). 1 = GMod default (16), 0.625 = the old fixed 10-unit hull, 0.1 = smallest.
local cvScale = CreateConVar("vrmod_hullscale", "0.625", FCVAR_ARCHIVE + FCVAR_REPLICATED, "VR hull width scale: 1 = GMod default, down to 0.1", 0.1, 1)
-- Extends the reduced hull to everyone so mixed lobbies traverse identical geometry.
local cvAll   = CreateConVar("vrmod_smallhull_all", "0", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Apply the reduced hull to non-VR players as well", 0, 1)

local function SetHullFor(ply, small)
	if small then
		local hw = DEF_HALF * cvScale:GetFloat()
		SM_MINS:SetUnpacked(-hw, -hw, 0)
		SM_MAXS:SetUnpacked(hw, hw, STAND_TOP)
		SM_DUCK:SetUnpacked(hw, hw, DUCK_TOP)
		ply:SetHull(SM_MINS, SM_MAXS)
		ply:SetHullDuck(SM_MINS, SM_DUCK)
	else
		ply:SetHull(DEF_MINS, DEF_MAXS)
		ply:SetHullDuck(DEF_MINS, DEF_DUCK_MAXS)
	end
end

-- ply:IsInVR() is not a VRMod method; use the canonical g_VR state per realm.
-- Clientside only LocalPlayer matters: SetHull on a remote player's clientside
-- entity does nothing for prediction, so skip those calls entirely.
local function ShouldShrink(ply)
	if not cvHull:GetBool() then return false end
	if CLIENT then
		if ply ~= LocalPlayer() then return false end
		return cvAll:GetBool() or (g_VR and g_VR.active) == true
	end
	return cvAll:GetBool() or (g_VR and g_VR[ply:SteamID()]) ~= nil
end

-- VR entry/exit: the g_VR entry is not necessarily populated/cleared yet when
-- these fire, so the VR state is passed explicitly rather than read back.
hook.Add("VRMod_Start", "vrmod_vr_hull", function(ply)
	if CLIENT and ply ~= LocalPlayer() then return end
	SetHullFor(ply, cvHull:GetBool())
end)

hook.Add("VRMod_Exit", "vrmod_vr_hull", function(ply)
	if CLIENT and ply ~= LocalPlayer() then return end
	SetHullFor(ply, cvHull:GetBool() and cvAll:GetBool())
end)

-- Source resets hulls on respawn; re-apply once the respawn settles. The
-- deferral also covers Player(uid) not resolving yet on the spawning client.
gameevent.Listen("player_spawn")
hook.Add("player_spawn", "vrmod_vr_hull", function(data)
	if not cvHull:GetBool() then return end
	local uid = data.userid
	timer.Simple(0, function()
		local ply = Player(uid)
		if IsValid(ply) and ShouldShrink(ply) then SetHullFor(ply, true) end
	end)
end)

-- Runs on both realms: replicated convar updates fire this clientside too, so
-- toggling mid-game keeps prediction in lockstep. Unconditional SetHullFor
-- (not gated on ShouldShrink) so turning an option back off also restores.
local function ReapplyHulls()
	if CLIENT then
		local lp = LocalPlayer()
		if IsValid(lp) then SetHullFor(lp, ShouldShrink(lp)) end
		return
	end
	for _, ply in player.Iterator() do
		SetHullFor(ply, ShouldShrink(ply))
	end
end

cvars.AddChangeCallback("vrmod_smallhull",     ReapplyHulls, "vrmod_vr_hull")
cvars.AddChangeCallback("vrmod_hullscale",     ReapplyHulls, "vrmod_vr_hull")
cvars.AddChangeCallback("vrmod_smallhull_all", ReapplyHulls, "vrmod_vr_hull")

if CLIENT then
	local cvAnticlip = CreateClientConVar("vrmod_anticlip", "1", true, false, "Push the VR view out of walls in roomscale", 0, 1)
	local HEAD_RADIUS = 1.4
	local HEAD_TRACE_MINS = Vector(-HEAD_RADIUS, -HEAD_RADIUS, -HEAD_RADIUS)
	local HEAD_TRACE_MAXS = Vector( HEAD_RADIUS,  HEAD_RADIUS,  HEAD_RADIUS)
	local SMOOTH_SPEED = 12
	local trData = {mins = HEAD_TRACE_MINS, maxs = HEAD_TRACE_MAXS, mask = MASK_SOLID_BRUSHONLY}
	local correctionX, correctionY = 0, 0

	hook.Add("VRMod_Tracking", "vrmod_head_anticlip", function()
		if not g_VR or not g_VR.tracking then return end
		-- Toggle + addon override: return false from VRMod_AllowHeadAntiClip to
		-- suppress the origin correction (for addons with their own collision).
		-- Corrections reset so re-enabling can't snap the view sideways.
		if not cvAnticlip:GetBool() or hook.Run("VRMod_AllowHeadAntiClip") == false then
			correctionX, correctionY = 0, 0
			return
		end
		local ply = LocalPlayer()
		if not IsValid(ply) then return end

		local dt = RealFrameTime()
		local hmdPos = g_VR.tracking.hmd.pos
		local feetPos = ply:GetPos()
		trData.start = Vector(feetPos.x, feetPos.y, hmdPos.z)
		trData.endpos = hmdPos
		trData.filter = ply
		local tr = util.TraceHull(trData)

		local targetX, targetY = 0, 0
		if tr.Hit and tr.HitWorld and tr.Fraction < 1 then
			local pushback = (hmdPos - tr.HitPos):Dot(tr.HitNormal)
			if pushback < 0 then
				local n = tr.HitNormal
				local mag = -pushback + HEAD_RADIUS
				targetX, targetY = n.x * mag, n.y * mag
			end
		end

		local blend = 1 - math.exp(-SMOOTH_SPEED * dt)
		correctionX = Lerp(blend, correctionX, targetX)
		correctionY = Lerp(blend, correctionY, targetY)

		if correctionX * correctionX + correctionY * correctionY > 0.001 then
			g_VR.origin.x = g_VR.origin.x + correctionX
			g_VR.origin.y = g_VR.origin.y + correctionY
		end
	end)
end