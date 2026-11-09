AddCSLuaFile()

--[[
	VR Hull Reduction & Head Anti-Clip
	- Shrinks player collision hull for VR players (optionally for everyone)
	- Prevents HMD from clipping through walls by correcting g_VR.origin due to the smaller hull

	SetHull/SetHullDuck do NOT replicate, and respawn/model changes reset them
	on each realm at different, unordered moments. Any window where the client
	predicts with 16u while the server moves with the small hull resolves slopes
	differently (box corner rests at a different height), so every snapshot
	snaps origin.z: laggy movement and head bob on slopes, desktop included.

	Fix: no event timing at all. The small hull is (re)applied in SetupMove,
	which runs immediately before every simulated usercmd on the server AND for
	every predicted/re-predicted command on the client, so both realms always
	move the same command with the same hull whatever reset it in between.
	Restoring is transition-only (ResetHull) so other addons' hulls are untouched.
	Convars are read live in SetupMove: see the note there.
]]

local DEF_HALF = 16 -- GMod default player half-width
local SM_MINS, SM_MAXS, SM_DUCK = Vector(), Vector(), Vector()

local cvHull  = CreateConVar("vrmod_smallhull", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Use reduced collision hull for VR players", 0, 1)
-- Width scale only (height is left at default). 1 = GMod default (16), 0.625 = the old fixed 10-unit hull, 0.1 = smallest.
local cvScale = CreateConVar("vrmod_hullscale", "0.625", FCVAR_ARCHIVE + FCVAR_REPLICATED, "VR hull width scale: 1 = GMod default, down to 0.1", 0.1, 1)
-- Extends the reduced hull to everyone so mixed lobbies traverse identical geometry.
local cvAll   = CreateConVar("vrmod_smallhull_all", "0", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Apply the reduced hull to non-VR players as well", 0, 1)

local vr = setmetatable({}, {__mode = "k"}) -- players in VR, same on both realms
local sm = setmetatable({}, {__mode = "k"}) -- players currently on the small hull
local scale

-- Convars are read live, never cached: a replicated change reaches the
-- client's value but not reliably its change callback, and a cached copy
-- left the realms on different hulls every tick (full latch reset spam).
-- Live reads mean both realms see the same value for the same command.
-- Short-circuit order keeps the common path at 1-2 native calls.
hook.Add("SetupMove", "vrmod_vr_hull", function(ply)
	if not (cvHull:GetBool() and (vr[ply] or cvAll:GetBool())) then
		if sm[ply] then sm[ply] = nil ply:ResetHull() end
		return
	end
	local s = cvScale:GetFloat()
	if s ~= scale then
		scale = s
		local hw = DEF_HALF * s
		SM_MINS:SetUnpacked(-hw, -hw, 0)
		SM_MAXS:SetUnpacked(hw, hw, 72)
		SM_DUCK:SetUnpacked(hw, hw, 36)
	end
	sm[ply] = true
	ply:SetHull(SM_MINS, SM_MAXS)
	ply:SetHullDuck(SM_MINS, SM_DUCK)
end)

-- The g_VR entry is not necessarily populated/cleared yet when these fire,
-- so VR state is tracked here from the passed player instead. Restoring on
-- exit happens on that player's next move, same path as a convar change.
hook.Add("VRMod_Start", "vrmod_vr_hull", function(ply)
	if CLIENT and ply ~= LocalPlayer() then return end
	vr[ply] = true
end)

hook.Add("VRMod_Exit", "vrmod_vr_hull", function(ply)
	if ply then vr[ply] = nil end
end)

if CLIENT then
	-- HEAD ANTI-CLIP. The hull follows the hips, so the head can lean well past
	-- it: a head-sized hull is traced from the hull's centre at head height out
	-- to the HMD, and the view is pushed back by however far the head is past
	-- what it hits. Everything that would stop the body counts, not just the
	-- world: doors (func_door brushes and prop_door_rotating models alike),
	-- windows and solid props. The old brush-only mask never hit model
	-- entities and only world hits were acted on, so you could lean through
	-- all of them. Left out: bodies (NPCs and players walk into you),
	-- ragdolls, weapons, what you hold, and every collision group the player
	-- walks through (debris, weapons and VR hand props, passable doors...).
	-- In a vehicle, the world only: the vehicle's own body sits in the way.
	local cvAnticlip = CreateClientConVar("vrmod_anticlip", "1", true, false, "Push the VR view out of walls, doors and solid props in roomscale", 0, 1)
	local anticlipOn = cvAnticlip:GetBool()
	cvars.AddChangeCallback("vrmod_anticlip", function() anticlipOn = cvAnticlip:GetBool() end, "vrmod_head_anticlip")
	local HEAD_RADIUS = 1.4
	local SMOOTH_SPEED = 12
	local math_exp, RealFrameTime, LocalPlayer, IsValid = math.exp, RealFrameTime, LocalPlayer, IsValid
	local VUnpack, VSetU = FindMetaTable("Vector").Unpack, FindMetaTable("Vector").SetUnpacked
	local PASS = {}
	for _, g in ipairs({COLLISION_GROUP_DEBRIS, COLLISION_GROUP_DEBRIS_TRIGGER, COLLISION_GROUP_IN_VEHICLE, COLLISION_GROUP_WEAPON,
		COLLISION_GROUP_VEHICLE_CLIP, COLLISION_GROUP_PROJECTILE, COLLISION_GROUP_DOOR_BLOCKER, COLLISION_GROUP_PASSABLE_DOOR,
		COLLISION_GROUP_DISSOLVING, COLLISION_GROUP_PUSHAWAY, COLLISION_GROUP_WORLD}) do PASS[g] = true end
	local me, worldOnly
	local function HeadFilter(e)
		if not e:IsValid() then return true end -- the world, static props
		if worldOnly or e == me or e == g_VR.heldEntityLeft or e == g_VR.heldEntityRight then return false end
		return not (PASS[e:GetCollisionGroup()] or e:IsPlayer() or e:IsNPC() or e:IsNextBot() or e:IsRagdoll() or e:IsWeapon())
	end
	local trStart, trOut = Vector(), {}
	-- MASK_SOLID: model entities are only hit by masks with CONTENTS_MONSTER
	local trData = {
		start = trStart, output = trOut, mask = MASK_SOLID, filter = HeadFilter,
		mins = Vector(-HEAD_RADIUS, -HEAD_RADIUS, -HEAD_RADIUS),
		maxs = Vector( HEAD_RADIUS,  HEAD_RADIUS,  HEAD_RADIUS),
	}
	local correctionX, correctionY = 0, 0

	hook.Add("VRMod_Tracking", "vrmod_head_anticlip", function()
		if not g_VR or not g_VR.tracking then return end
		-- Toggle + addon override: return false from VRMod_AllowHeadAntiClip to
		-- suppress the origin correction (for addons with their own collision).
		-- Corrections reset so re-enabling can't snap the view sideways.
		if not anticlipOn or hook.Call("VRMod_AllowHeadAntiClip", nil) == false then
			correctionX, correctionY = 0, 0
			return
		end
		local ply = LocalPlayer()
		if not IsValid(ply) then return end

		local hmdPos = g_VR.tracking.hmd.pos
		local hx, hy, hz = VUnpack(hmdPos)
		local fx, fy = VUnpack(ply:GetPos())
		VSetU(trStart, fx, fy, hz)
		trData.endpos = hmdPos
		me, worldOnly = ply, ply:InVehicle()
		util.TraceHull(trData)

		local targetX, targetY = 0, 0
		if trOut.Hit then
			local px, py, pz = VUnpack(trOut.HitPos)
			local nx, ny, nz = VUnpack(trOut.HitNormal)
			local pushback = (hx - px) * nx + (hy - py) * ny + (hz - pz) * nz
			if pushback < 0 then
				local mag = HEAD_RADIUS - pushback
				targetX, targetY = nx * mag, ny * mag
			end
		end

		local blend = 1 - math_exp(-SMOOTH_SPEED * RealFrameTime())
		correctionX = correctionX + (targetX - correctionX) * blend
		correctionY = correctionY + (targetY - correctionY) * blend

		if correctionX * correctionX + correctionY * correctionY > 0.001 then
			-- g_VR.origin is a live reference: written in place, never cached
			local o = g_VR.origin
			local ox, oy, oz = VUnpack(o)
			VSetU(o, ox + correctionX, oy + correctionY, oz)
		end
	end)
end