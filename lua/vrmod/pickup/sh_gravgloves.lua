-- sh_gravgloves.lua
-- Half-Life: Alyx style Gravity Gloves for VRMod
-- Point → Lock (grip) → Flick → Catch/Miss
-- Per-hand: each hand independently targets, locks, pulls, and catches

g_VR = g_VR or {}
vrmod = vrmod or {}

vrmod.AddCallbackedConvar("vrmod_gravgloves", nil, "0", FCVAR_REPLICATED + FCVAR_ARCHIVE, "Enable gravity gloves", 0, 1, tonumber)
vrmod.AddCallbackedConvar("vrmod_gravgloves_range", nil, "1500", FCVAR_REPLICATED + FCVAR_ARCHIVE, "Max targeting range", 100, 5000, tonumber)
vrmod.AddCallbackedConvar("vrmod_gravgloves_speed", nil, "900", FCVAR_REPLICATED + FCVAR_ARCHIVE, "Pull speed (units/sec)", 200, 2000, tonumber)

local CATCH_RADIUS_SQR = 55 * 55
local FLICK_THRESHOLD = 50
local ARC_UP = 180
local PULL_TIMEOUT = 3.5
local CONE_COS = 0.906
local math_sqrt = math.sqrt
local math_Clamp = math.Clamp

local SKIP_CLASS = {
	prop_ragdoll = true, base_anim = true, viewmodel = true,
	predicted_viewmodel = true, entityflame = true, env_spritetrail = true,
}

------------------------------------------------------------------------
-- CLIENT
------------------------------------------------------------------------
if CLIENT then

CreateClientConVar("vrmod_gravgloves_debug", "0", true, false, "1=state, 2=scans")

-- Per-hand state: 1=right, 2=left
local target    = {nil, nil}
local locked    = {false, false}
local pulling   = {nil, nil}
local pullStart = {0, 0}

local COL_TARGET = {Color(100, 200, 255), Color(255, 100, 100)}
local COL_LOCKED = {Color(50, 255, 200),  Color(255, 180, 50)}
local COL_PULL   = {Color(30, 255, 180),  Color(255, 130, 30)}
local haloEnts = {{nil}, {nil}}

local POSE_KEYS = {"pose_righthand", "pose_lefthand"}
local VEL_FN    = {vrmod.GetRightHandVelocity, vrmod.GetLeftHandVelocity}
local GRIP_ACTIONS = {"boolean_right_pickup", "boolean_left_pickup"}
local HELD_KEYS = {"heldEntityRight", "heldEntityLeft"}
local HAPTIC_IDS = {"vibration_right", "vibration_left"}

local function GripHeld(i) return g_VR.input[GRIP_ACTIONS[i]] == true end
local function HeldEnt(i)  return g_VR[HELD_KEYS[i]] end

local function HapticBuzz(i, dur, freq, amp)
	VRMOD_TriggerHaptic(HAPTIC_IDS[i], 0, dur, freq, amp)
end

local function ClearHand(i)
	target[i] = nil
	locked[i] = false
	pulling[i] = nil
end

local function ClearBoth()
	for i = 1, 2 do ClearHand(i) end
end

------------------------------------------------------------------------
-- Debug (compact)
------------------------------------------------------------------------
local _dbgCV
local function dbgLevel()
	_dbgCV = _dbgCV or GetConVar("vrmod_gravgloves_debug")
	return _dbgCV and _dbgCV:GetInt() or 0
end

local function dbg(...)
	if dbgLevel() >= 1 then print("[GravGloves]", ...) end
end

------------------------------------------------------------------------
-- Targeting: cone scan per-hand
------------------------------------------------------------------------
local _dbgScanTime = 0
local _visTr = {mask = MASK_SOLID_BRUSHONLY}
local function FindGravTarget(pose, ply, handIdx, maxRange, nearSqr, maxWeight)
	local handPos = pose.pos
	local fwd = pose.ang:Forward()
	local otherIdx = 3 - handIdx
	local otherTarget = target[otherIdx]
	local otherPull = pulling[otherIdx]

	local candidates = ents.FindInCone(handPos, fwd, maxRange, CONE_COS)
	local best, bestScore = nil, math.huge
	local maxRangeSqr = maxRange * maxRange

	local doLog = false
	if dbgLevel() >= 2 then
		local now = CurTime()
		if now - _dbgScanTime > 2 then
			_dbgScanTime = now
			doLog = true
			dbg("scan H"..handIdx..":", #candidates, "range:", maxRange)
		end
	end

	for k = 1, #candidates do
		local ent = candidates[k]
		if not IsValid(ent) or ent == ply then continue end
		if ent:EntIndex() < 0 then continue end
		local class = ent:GetClass()
		if SKIP_CLASS[class] then continue end
		if ent:IsWorld() or ent:IsPlayer() or ent:IsNPC() or ent:IsWeapon() then continue end
		if ent.vrmod_gravpull then continue end
		if ent == otherTarget or ent == otherPull then continue end

		local epos = ent:GetPos()
		local distSqr = handPos:DistToSqr(epos)
		if distSqr < nearSqr or distSqr > maxRangeSqr then continue end
		if ent:GetMoveType() ~= MOVETYPE_VPHYSICS then continue end

		if maxWeight then
			local phys = ent:GetPhysicsObject()
			if IsValid(phys) and phys:GetMass() > maxWeight then continue end
		end

		-- Visibility: reject if world geometry blocks line of sight
		_visTr.start = handPos
		_visTr.endpos = epos
		local tr = util.TraceLine(_visTr)
		if tr.Hit then continue end

		local toEnt = epos - handPos
		toEnt:Normalize()
		local dot = fwd:Dot(toEnt)
		local angleScore = (dot - CONE_COS) / (1 - CONE_COS)
		local distScore = 1 - math_sqrt(distSqr) / maxRange
		local score = -(angleScore * 0.5 + distScore * 0.5)
		if score < bestScore then
			best, bestScore = ent, score
		end
	end

	return best
end

------------------------------------------------------------------------
-- Think: per-hand targeting, flick detection, catch/miss
------------------------------------------------------------------------
hook.Add("Think", "vrmod_gravgloves", function()
	if not g_VR or not g_VR.threePoints then return end
	local cvEnabled = GetConVar("vrmod_gravgloves")
	if not cvEnabled or not cvEnabled:GetBool() then return end
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then return end
	local tracking = g_VR.tracking
	if not tracking or not tracking.hmd then return end
	local hmdPos = tracking.hmd.pos
	local now = CurTime()

	-- Cache convars once per frame, not per hand
	local cvRange = GetConVar("vrmod_gravgloves_range")
	local cvPickupRange = GetConVar("vrmod_pickup_range")
	local cvWeight = GetConVar("vrmod_pickup_weight")
	local maxRange = cvRange and cvRange:GetFloat() or 1500
	local nearRange = cvPickupRange and cvPickupRange:GetFloat() * 10 or 400
	local nearSqr = nearRange * nearRange
	local maxWeight = cvWeight and cvWeight:GetFloat() or nil

	for i = 1, 2 do
		local pose = tracking[POSE_KEYS[i]]
		if not pose then ClearHand(i) continue end
		if IsValid(HeldEnt(i)) then ClearHand(i) continue end

		-- ── Pulling: check for catch ──
		if IsValid(pulling[i]) then
			if now - pullStart[i] > PULL_TIMEOUT then
				dbg(i == 1 and "R" or "L", "pull timeout")
				ClearHand(i)
				continue
			end
			if pose.pos:DistToSqr(pulling[i]:GetPos()) < CATCH_RADIUS_SQR then
				if GripHeld(i) then
					dbg(i == 1 and "R" or "L", "CATCH!", pulling[i])
					net.Start("vrmod_gravglove_catch")
					net.WriteEntity(pulling[i])
					net.WriteBool(i == 2)
					net.SendToServer()
					HapticBuzz(i, 120, 80, 0.9)
				else
					dbg(i == 1 and "R" or "L", "miss (grip released)")
				end
				ClearHand(i)
			end
			continue
		end

		-- ── Locked: waiting for flick ──
		if locked[i] then
			if not IsValid(target[i]) then ClearHand(i) continue end
			if not GripHeld(i) then
				dbg(i == 1 and "R" or "L", "grip released, unlock")
				locked[i] = false
				continue
			end
			local vel = VEL_FN[i]()
			local toHead = hmdPos - pose.pos
			toHead:Normalize()
			local flickSpeed = vel:Dot(toHead)
			if flickSpeed > FLICK_THRESHOLD then
				dbg(i == 1 and "R" or "L", "FLICK!", math.floor(flickSpeed), target[i])
				net.Start("vrmod_gravglove_pull")
				net.WriteEntity(target[i])
				net.WriteBool(i == 2)
				net.SendToServer()
				pulling[i] = target[i]
				pullStart[i] = now
				locked[i] = false
				HapticBuzz(i, 100, 60, 0.8)
			end
			continue
		end

		-- ── Idle: find target for this hand ──
		target[i] = FindGravTarget(pose, ply, i, maxRange, nearSqr, maxWeight)
	end
end)

------------------------------------------------------------------------
-- Input: grip press → lock on target (per-hand)
------------------------------------------------------------------------
hook.Add("VRMod_Input", "vrmod_gravgloves", function(action, pressed)
	if not pressed then return end
	local cvEnabled = GetConVar("vrmod_gravgloves")
	if not cvEnabled or not cvEnabled:GetBool() then return end

	for i = 1, 2 do
		if action == GRIP_ACTIONS[i]
			and IsValid(target[i])
			and not IsValid(HeldEnt(i))
			and not locked[i]
			and not IsValid(pulling[i])
		then
			local o = 3 - i
			if target[i] == target[o] and (locked[o] or IsValid(pulling[o])) then continue end
			locked[i] = true
			HapticBuzz(i, 50, 40, 0.3)
			dbg(i == 1 and "R" or "L", "LOCKED on", target[i])
		end
	end
end)

------------------------------------------------------------------------
-- Block normal pickup while locked or pulling (per-hand)
------------------------------------------------------------------------
hook.Add("VRMod_AllowDefaultAction", "vrmod_gravgloves", function(action)
	for i = 1, 2 do
		if action == GRIP_ACTIONS[i] and (locked[i] or IsValid(pulling[i])) then
			return false
		end
	end
end)

------------------------------------------------------------------------
-- Halos (per-hand, independent colors)
------------------------------------------------------------------------
hook.Add("PreDrawHalos", "vrmod_gravgloves", function()
	if not g_VR or not g_VR.threePoints then return end

	for i = 1, 2 do
		local ent = pulling[i] or target[i]
		if not IsValid(ent) then continue end
		local ht = haloEnts[i]
		ht[1] = ent
		local col, blur
		if IsValid(pulling[i]) then
			col, blur = COL_PULL[i], 3
		elseif locked[i] then
			col, blur = COL_LOCKED[i], 2
		else
			col, blur = COL_TARGET[i], 1
		end
		halo.Add(ht, col, blur, blur, 1, true, true)
	end
end)

------------------------------------------------------------------------
-- Cleanup (merged exit + death)
------------------------------------------------------------------------
hook.Add("VRMod_Exit", "vrmod_gravgloves", function(ply)
	if ply ~= LocalPlayer() then return end
	ClearBoth()
end)

hook.Add("PlayerDeath", "vrmod_gravgloves", function(ply)
	if ply ~= LocalPlayer() then return end
	ClearBoth()
end)

end -- CLIENT

------------------------------------------------------------------------
-- SERVER
------------------------------------------------------------------------
if SERVER then

util.AddNetworkString("vrmod_gravglove_pull")
util.AddNetworkString("vrmod_gravglove_catch")

local pulls = {}
local pullCount = 0

local function RemovePull(idx)
	local p = pulls[idx]
	if IsValid(p.ent) then
		p.ent:SetCollisionGroup(p.origGroup)
		p.ent.vrmod_gravpull = nil
		local phys = p.ent:GetPhysicsObject()
		if IsValid(phys) then phys:EnableGravity(true) end
	end
	pulls[idx] = pulls[pullCount]
	pulls[pullCount] = nil
	pullCount = pullCount - 1
end

local function FindPull(ent)
	for idx = 1, pullCount do
		if pulls[idx].ent == ent then return idx end
	end
end

------------------------------------------------------------------------
-- Net: pull request (flick detected, per-hand)
------------------------------------------------------------------------
vrmod.NetReceiveLimited("vrmod_gravglove_pull", 5, 300, function(_, ply)
	if not IsValid(ply) or not ply:Alive() then return end
	local cv = GetConVar("vrmod_gravgloves")
	if not cv or not cv:GetBool() then return end

	local ent = net.ReadEntity()
	local isLeft = net.ReadBool()
	if not IsValid(ent) or FindPull(ent) then return end

	local phys = ent:GetPhysicsObject()
	if not IsValid(phys) or not phys:IsMoveable() then return end

	local maxWeight = GetConVar("vrmod_pickup_weight")
	if maxWeight and phys:GetMass() > maxWeight:GetFloat() then return end

	local handPos = isLeft and vrmod.GetLeftHandPos(ply) or vrmod.GetRightHandPos(ply)
	local cvRange = GetConVar("vrmod_gravgloves_range")
	local maxRange = cvRange and cvRange:GetFloat() or 1500
	if handPos:DistToSqr(ent:GetPos()) > maxRange * maxRange then return end

	local origGroup = ent:GetCollisionGroup()
	ent:SetCollisionGroup(COLLISION_GROUP_PASSABLE_DOOR)
	ent.vrmod_gravpull = true

	phys:EnableGravity(false)
	phys:Wake()
	local dir = handPos - ent:GetPos()
	dir:Normalize()
	local cvSpeed = GetConVar("vrmod_gravgloves_speed")
	local speed = cvSpeed and cvSpeed:GetFloat() or 900
	phys:SetVelocity(dir * speed + Vector(0, 0, ARC_UP))

	pullCount = pullCount + 1
	pulls[pullCount] = {
		ent = ent, ply = ply, isLeft = isLeft,
		startTime = CurTime(), origGroup = origGroup,
	}
end)

------------------------------------------------------------------------
-- Net: catch (per-hand, atomic snap + pickup)
------------------------------------------------------------------------
vrmod.NetReceiveLimited("vrmod_gravglove_catch", 5, 300, function(_, ply)
	if not IsValid(ply) or not ply:Alive() then return end

	local ent = net.ReadEntity()
	local isLeft = net.ReadBool()
	if not IsValid(ent) then return end

	local idx = FindPull(ent)
	if idx then RemovePull(idx) end

	local handPos = isLeft and vrmod.GetLeftHandPos(ply) or vrmod.GetRightHandPos(ply)
	ent:SetPos(handPos)
	local phys = ent:GetPhysicsObject()
	if IsValid(phys) then
		phys:SetVelocity(vector_origin)
		phys:EnableGravity(true)
	end

	vrmod.Pickup(ply, isLeft, ent)
end)

------------------------------------------------------------------------
-- Server Think: per-entity homing toward the requesting hand
------------------------------------------------------------------------
hook.Add("Think", "vrmod_gravgloves", function()
	if pullCount == 0 then return end
	local dt = FrameTime()
	local now = CurTime()
	local cvSpeed = GetConVar("vrmod_gravgloves_speed")
	local baseSpeed = cvSpeed and cvSpeed:GetFloat() or 900

	local idx = 1
	while idx <= pullCount do
		local p = pulls[idx]
		local remove = false

		if not IsValid(p.ent) or not IsValid(p.ply) or not p.ply:Alive() then
			remove = true
		elseif now - p.startTime > PULL_TIMEOUT then
			remove = true
		else
			local phys = p.ent:GetPhysicsObject()
			if not IsValid(phys) then
				remove = true
			else
				local handPos = p.isLeft and vrmod.GetLeftHandPos(p.ply) or vrmod.GetRightHandPos(p.ply)
				local toHand = handPos - p.ent:GetPos()
				local distSqr = toHand:LengthSqr()

				if distSqr < CATCH_RADIUS_SQR then
					phys:SetVelocity(vector_origin)
					remove = true
				else
					local dist = math_sqrt(distSqr)
					local scale = math_Clamp(dist / 250, 0.2, 1)
					toHand:Normalize()
					local spd = baseSpeed * scale
					local tgtX, tgtY, tgtZ = toHand.x * spd, toHand.y * spd, toHand.z * spd
					local t = math_Clamp(dt * (6 + 800 / dist), 0, 0.85)
					local curVel = phys:GetVelocity()
					phys:SetVelocity(Vector(
						curVel.x + (tgtX - curVel.x) * t,
						curVel.y + (tgtY - curVel.y) * t,
						curVel.z + (tgtZ - curVel.z) * t
					))
				end
			end
		end

		if remove then RemovePull(idx)
		else idx = idx + 1 end
	end
end)

------------------------------------------------------------------------
-- Server cleanup
------------------------------------------------------------------------
hook.Add("PlayerDisconnected", "vrmod_gravgloves", function(ply)
	local idx = 1
	while idx <= pullCount do
		if pulls[idx].ply == ply then RemovePull(idx)
		else idx = idx + 1 end
	end
end)

hook.Add("EntityRemoved", "vrmod_gravgloves", function(ent)
	local idx = 1
	while idx <= pullCount do
		if pulls[idx].ent == ent then
			pulls[idx].ent = NULL
			RemovePull(idx)
		else idx = idx + 1 end
	end
end)

end -- SERVER