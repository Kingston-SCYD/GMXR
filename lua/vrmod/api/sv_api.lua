g_VR = g_VR or {}
vrmod = vrmod or {}
local EmptyHandsWeapons = {
	["weapon_vrmod_empty"] = true,
	["vr_spooderman"] = true,
	-- add more here if needed
}
if SERVER then
	-- Hoist globals as upvalues
	local IsValid = IsValid
	local Vector = Vector
	local Angle = Angle
	local LocalToWorld = LocalToWorld
	local SysTime = SysTime
	local math_max = math.max
	local math_AngleDifference = math.AngleDifference

	vrmod.HandVelocityCache = vrmod.HandVelocityCache or {}

	function vrmod.NetReceiveLimited(msgName, maxCountPerSec, maxLen, callback)
		local msgCounts = {}
		net.Receive(msgName, function(len, ply)
			local t = msgCounts[ply] or { count = 0, time = 0 }
			msgCounts[ply], t.count = t, t.count + 1
			if SysTime() - t.time >= 1 then t.count, t.time = 1, SysTime() end
			if t.count > maxCountPerSec or len > maxLen then return end
			callback(len, ply)
		end)
	end

	function vrmod.IsPlayerInVR(ply)
		if not IsValid(ply) then return end
		return g_VR[ply:SteamID()] ~= nil
	end

	function vrmod.UsingEmptyHands(ply)
		local wep = ply and ply:GetActiveWeapon() or LocalPlayer():GetActiveWeapon()
		if not IsValid(wep) then return false end
		return EmptyHandsWeapons[wep:GetClass()] or false
	end

	function vrmod.GetHeldEntity(ply, hand)
		if not IsValid(ply) or not (hand == "left" or hand == "right") then return nil end
		local data = g_VR[ply:SteamID()]
		data = data and data.heldItems
		if not data then return nil end
		local info = data[hand == "left" and 1 or 2]
		if info and IsValid(info.ent) then return info.ent end
		return nil
	end

	----------------------------------------------------------------------
	-- Hoisted helpers (were redefined inside UpdateWorldPoses every call)
	----------------------------------------------------------------------
	local function AngDiff(a, b)
		return Angle(math_AngleDifference(a.p, b.p), math_AngleDifference(a.y, b.y), math_AngleDifference(a.r, b.r))
	end

	local function PredictPose(pos, ang, vel, angVel, dt)
		if not pos or not vel then return pos, ang end
		return pos + vel * dt, Angle(ang.p + angVel.p * dt, ang.y + angVel.y * dt, ang.r + angVel.r * dt)
	end

	----------------------------------------------------------------------
	-- UpdateWorldPoses: local→world conversion + velocity cache
	----------------------------------------------------------------------
	local function UpdateWorldPoses(ply, playerTable)
		-- FIX: guard latestFrame nil (no tick received yet)
		if not IsValid(ply) or not playerTable or not playerTable.latestFrame then return end
		-- Only update if timestamp changed (or first time)
		local lf = playerTable.latestFrame
		if playerTable.latestFrameWorld and playerTable.latestFrameWorld.ts == lf.ts then return end

		playerTable.latestFrameWorld = playerTable.latestFrameWorld or {}
		local lfw = playerTable.latestFrameWorld
		lfw.ts = lf.ts

		-- Base world reference
		local refPos = ply:GetPos()
		local refAng = ply:InVehicle() and ply:GetVehicle():GetAngles() or Angle()

		-- Convert local → world for all tracked parts
		lfw.hmdPos, lfw.hmdAng = LocalToWorld(lf.hmdPos or Vector(), lf.hmdAng or Angle(), refPos, refAng)
		lfw.lefthandPos, lfw.lefthandAng = LocalToWorld(lf.lefthandPos or Vector(), lf.lefthandAng or Angle(), refPos, refAng)
		lfw.righthandPos, lfw.righthandAng = LocalToWorld(lf.righthandPos or Vector(), lf.righthandAng or Angle(), refPos, refAng)
		if lf.waistPos then lfw.waistPos, lfw.waistAng = LocalToWorld(lf.waistPos, lf.waistAng or Angle(), refPos, refAng) end
		if lf.leftfootPos then lfw.leftfootPos, lfw.leftfootAng = LocalToWorld(lf.leftfootPos, lf.leftfootAng or Angle(), refPos, refAng) end
		if lf.rightfootPos then lfw.rightfootPos, lfw.rightfootAng = LocalToWorld(lf.rightfootPos, lf.rightfootAng or Angle(), refPos, refAng) end

		-- Velocity cache
		local sid = ply:SteamID()
		local cache = vrmod.HandVelocityCache[sid]
		if not cache then
			cache = {
				-- Core tracking (always present)
				hmdLastPos = lfw.hmdPos, hmdLastAng = lfw.hmdAng,
				lefthandLastPos = lfw.lefthandPos, lefthandLastAng = lfw.lefthandAng,
				righthandLastPos = lfw.righthandPos, righthandLastAng = lfw.righthandAng,
				hmdLastVelPos = lfw.hmdPos, hmdLastVelAng = lfw.hmdAng,
				lefthandLastVelPos = lfw.lefthandPos, lefthandLastVelAng = lfw.lefthandAng,
				righthandLastVelPos = lfw.righthandPos, righthandLastVelAng = lfw.righthandAng,
				hmdVel = Vector(), lefthandVel = Vector(), righthandVel = Vector(),
				hmdAngVel = Angle(), lefthandAngVel = Angle(), righthandAngVel = Angle(),
				-- FBT tracking (init with current or zero)
				waistLastPos = lfw.waistPos or Vector(), waistLastAng = lfw.waistAng or Angle(),
				leftfootLastPos = lfw.leftfootPos or Vector(), leftfootLastAng = lfw.leftfootAng or Angle(),
				rightfootLastPos = lfw.rightfootPos or Vector(), rightfootLastAng = lfw.rightfootAng or Angle(),
				waistLastVelPos = lfw.waistPos or Vector(), waistLastVelAng = lfw.waistAng or Angle(),
				leftfootLastVelPos = lfw.leftfootPos or Vector(), leftfootLastVelAng = lfw.leftfootAng or Angle(),
				rightfootLastVelPos = lfw.rightfootPos or Vector(), rightfootLastVelAng = lfw.rightfootAng or Angle(),
				waistVel = Vector(), leftfootVel = Vector(), rightfootVel = Vector(),
				waistAngVel = Angle(), leftfootAngVel = Angle(), rightfootAngVel = Angle(),
				lastTs = lfw.ts, lastVelUpdateTs = lfw.ts, avgDt = 0.011,
			}
			vrmod.HandVelocityCache[sid] = cache
		end

		-- Delta times
		local dt = lfw.ts - cache.lastTs
		local totalDt = lfw.ts - cache.lastVelUpdateTs

		if dt > 0 then cache.avgDt = cache.avgDt * 0.9 + dt * 0.1 end

		local minDt = math_max(0.01, cache.avgDt * 2)
		if dt > 0 and totalDt >= minDt then
			local invDt = 1 / totalDt
			-- Core velocities
			cache.hmdVel = (lfw.hmdPos - cache.hmdLastVelPos) * invDt
			cache.lefthandVel = (lfw.lefthandPos - cache.lefthandLastVelPos) * invDt
			cache.righthandVel = (lfw.righthandPos - cache.righthandLastVelPos) * invDt
			cache.hmdAngVel = AngDiff(lfw.hmdAng, cache.hmdLastVelAng) * invDt
			cache.lefthandAngVel = AngDiff(lfw.lefthandAng, cache.lefthandLastVelAng) * invDt
			cache.righthandAngVel = AngDiff(lfw.righthandAng, cache.righthandLastVelAng) * invDt
			-- FBT velocities (only when data present)
			if lfw.waistPos then
				cache.waistVel = (lfw.waistPos - cache.waistLastVelPos) * invDt
				cache.waistAngVel = AngDiff(lfw.waistAng, cache.waistLastVelAng) * invDt
			end
			if lfw.leftfootPos then
				cache.leftfootVel = (lfw.leftfootPos - cache.leftfootLastVelPos) * invDt
				cache.leftfootAngVel = AngDiff(lfw.leftfootAng, cache.leftfootLastVelAng) * invDt
			end
			if lfw.rightfootPos then
				cache.rightfootVel = (lfw.rightfootPos - cache.rightfootLastVelPos) * invDt
				cache.rightfootAngVel = AngDiff(lfw.rightfootAng, cache.rightfootLastVelAng) * invDt
			end
			-- Reset accumulation points
			cache.hmdLastVelPos = lfw.hmdPos
			cache.lefthandLastVelPos = lfw.lefthandPos
			cache.righthandLastVelPos = lfw.righthandPos
			cache.hmdLastVelAng = lfw.hmdAng
			cache.lefthandLastVelAng = lfw.lefthandAng
			cache.righthandLastVelAng = lfw.righthandAng
			if lfw.waistPos then cache.waistLastVelPos = lfw.waistPos; cache.waistLastVelAng = lfw.waistAng end
			if lfw.leftfootPos then cache.leftfootLastVelPos = lfw.leftfootPos; cache.leftfootLastVelAng = lfw.leftfootAng end
			if lfw.rightfootPos then cache.rightfootLastVelPos = lfw.rightfootPos; cache.rightfootLastVelAng = lfw.rightfootAng end
			cache.lastVelUpdateTs = lfw.ts
		end

		-- Update frame-to-frame tracking
		cache.hmdLastPos = lfw.hmdPos
		cache.lefthandLastPos = lfw.lefthandPos
		cache.righthandLastPos = lfw.righthandPos
		cache.hmdLastAng = lfw.hmdAng
		cache.lefthandLastAng = lfw.lefthandAng
		cache.righthandLastAng = lfw.righthandAng
		cache.waistLastPos = lfw.waistPos or cache.waistLastPos
		cache.leftfootLastPos = lfw.leftfootPos or cache.leftfootLastPos
		cache.rightfootLastPos = lfw.rightfootPos or cache.rightfootLastPos
		cache.waistLastAng = lfw.waistAng or cache.waistLastAng
		cache.leftfootLastAng = lfw.leftfootAng or cache.leftfootLastAng
		cache.rightfootLastAng = lfw.rightfootAng or cache.rightfootLastAng
		cache.lastTs = lfw.ts

		-- Extrapolation (~1 frame ahead)
		local h = cache.avgDt
		lfw.hmdPos, lfw.hmdAng = PredictPose(lfw.hmdPos, lfw.hmdAng, cache.hmdVel, cache.hmdAngVel, h)
		lfw.lefthandPos, lfw.lefthandAng = PredictPose(lfw.lefthandPos, lfw.lefthandAng, cache.lefthandVel, cache.lefthandAngVel, h)
		lfw.righthandPos, lfw.righthandAng = PredictPose(lfw.righthandPos, lfw.righthandAng, cache.righthandVel, cache.righthandAngVel, h)
		if lfw.waistPos then lfw.waistPos, lfw.waistAng = PredictPose(lfw.waistPos, lfw.waistAng, cache.waistVel, cache.waistAngVel, h) end
		if lfw.leftfootPos then lfw.leftfootPos, lfw.leftfootAng = PredictPose(lfw.leftfootPos, lfw.leftfootAng, cache.leftfootVel, cache.leftfootAngVel, h) end
		if lfw.rightfootPos then lfw.rightfootPos, lfw.rightfootAng = PredictPose(lfw.rightfootPos, lfw.rightfootAng, cache.rightfootVel, cache.rightfootAngVel, h) end
	end

	----------------------------------------------------------------------
	-- Internal helpers for API functions (single lookup path)
	----------------------------------------------------------------------
	-- Returns playerTable or nil (validates player + latestFrame in one call)
	local function GetPT(ply)
		if not IsValid(ply) then return end
		local pt = g_VR[ply:SteamID()]
		if pt and pt.latestFrame then return pt end
	end

	-- Returns velocity cache or nil (validates + ensures UpdateWorldPoses ran)
	local function GetCache(ply)
		if not IsValid(ply) then return end
		local sid = ply:SteamID()
		local cache = vrmod.HandVelocityCache[sid]
		if cache then return cache end
		local pt = g_VR[sid]
		if not pt or not pt.latestFrame then return end
		UpdateWorldPoses(ply, pt)
		return vrmod.HandVelocityCache[sid]
	end

	----------------------------------------------------------------------
	-- Table-driven API generation
	-- Replaces ~42 hand-written functions with loop-generated closures.
	-- Relative velocity functions now do a single cache lookup instead of
	-- calling two separate API functions (which each did IsValid+SteamID+lookup).
	----------------------------------------------------------------------
	local parts = {
		{ name = "HMD",       pos = "hmdPos",       ang = "hmdAng",       vel = "hmdVel",       angVel = "hmdAngVel" },
		{ name = "LeftHand",  pos = "lefthandPos",  ang = "lefthandAng",  vel = "lefthandVel",  angVel = "lefthandAngVel",  combo = true },
		{ name = "RightHand", pos = "righthandPos", ang = "righthandAng", vel = "righthandVel", angVel = "righthandAngVel", combo = true },
		{ name = "Waist",     pos = "waistPos",     ang = "waistAng",     vel = "waistVel",     angVel = "waistAngVel" },
		{ name = "LeftFoot",  pos = "leftfootPos",  ang = "leftfootAng",  vel = "leftfootVel",  angVel = "leftfootAngVel",  combo = true },
		{ name = "RightFoot", pos = "rightfootPos", ang = "rightfootAng", vel = "rightfootVel", angVel = "rightfootAngVel", combo = true },
	}

	for _, p in ipairs(parts) do
		local posK, angK, velK, angVelK = p.pos, p.ang, p.vel, p.angVel

		vrmod["Get" .. p.name .. "Pos"] = function(ply)
			local pt = GetPT(ply)
			if not pt then return Vector() end
			UpdateWorldPoses(ply, pt)
			return pt.latestFrameWorld[posK] or Vector()
		end

		vrmod["Get" .. p.name .. "Ang"] = function(ply)
			local pt = GetPT(ply)
			if not pt then return Angle() end
			UpdateWorldPoses(ply, pt)
			return pt.latestFrameWorld[angK] or Angle()
		end

		vrmod["Get" .. p.name .. "Pose"] = function(ply)
			local pt = GetPT(ply)
			if not pt then return Vector(), Angle() end
			UpdateWorldPoses(ply, pt)
			return pt.latestFrameWorld[posK] or Vector(), pt.latestFrameWorld[angK] or Angle()
		end

		vrmod["Get" .. p.name .. "Velocity"] = function(ply)
			local c = GetCache(ply)
			return c and c[velK] or Vector()
		end

		vrmod["Get" .. p.name .. "AngularVelocity"] = function(ply)
			local c = GetCache(ply)
			return c and c[angVelK] or Angle()
		end

		-- Relative (to HMD) — single cache lookup instead of 2 function calls
		if p.name ~= "HMD" then
			vrmod["Get" .. p.name .. "VelocityRelative"] = function(ply)
				local c = GetCache(ply)
				if not c then return Vector() end
				return (c[velK] or Vector()) - (c.hmdVel or Vector())
			end

			vrmod["Get" .. p.name .. "AngularVelocityRelative"] = function(ply)
				local c = GetCache(ply)
				if not c then return Angle() end
				return (c[angVelK] or Angle()) - (c.hmdAngVel or Angle())
			end
		end

		-- Combined (vel + angvel + relative) — hands and feet only
		if p.combo then
			vrmod["Get" .. p.name .. "Velocities"] = function(ply)
				local c = GetCache(ply)
				if not c then return Vector(), Angle(), Vector() end
				local v = c[velK] or Vector()
				return v, c[angVelK] or Angle(), v - (c.hmdVel or Vector())
			end
		end
	end

	----------------------------------------------------------------------
	-- Gesture helper (optimized: single lookup path, was 4 nested API calls)
	----------------------------------------------------------------------
	function vrmod.GetPullGestureStrength(ply, hand, targetPos)
		if not IsValid(ply) then return 0 end
		local sid = ply:SteamID()
		local pt = g_VR[sid]
		if not pt or not pt.latestFrame then return 0 end
		UpdateWorldPoses(ply, pt)
		local lfw = pt.latestFrameWorld
		local cache = vrmod.HandVelocityCache[sid]
		if not lfw or not cache then return 0 end
		local isLeft = hand == "left"
		local handPos = (isLeft and lfw.lefthandPos or lfw.righthandPos) or Vector()
		local partVel = (isLeft and cache.lefthandVel or cache.righthandVel) or Vector()
		local relVel = partVel - (cache.hmdVel or Vector())
		return relVel:Dot((targetPos - handPos):GetNormalized())
	end
end