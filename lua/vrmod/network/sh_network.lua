g_VR = g_VR or {}
local _, convarValues = vrmod.GetConvars()
vrmod.AddCallbackedConvar("vrmod_net_tickrate", nil, tostring(math.ceil(1 / engine.TickInterval())), FCVAR_REPLICATED, nil, nil, nil, tonumber, nil)
-- Hot-path hoists: the codec runs per net tick on both realms, the lerp runs
-- every PreRender, so library functions live in upvalues (no _ENV lookups).
local net_WriteFloat, net_ReadFloat = net.WriteFloat, net.ReadFloat
local net_WriteUInt, net_ReadUInt = net.WriteUInt, net.ReadUInt
local bor, band = bit.bor, bit.band
local SysTime, IsValid = SysTime, IsValid
-- Precomputed finger keys (no per-use "finger" .. i concat)
local FINGERS = {}
for i = 1, 10 do FINGERS[i] = "finger" .. i end

-- Full-precision position codec. net.WriteVector uses Source coordinate
-- compression (a coarse fixed-point grid), which makes slow VR hand motion
-- snap cell-to-cell. Positions go over the wire as raw float32 instead so
-- fine movement survives. Angles use the same float codec: net.WriteAngle is
-- also quantized, and that error is multiplied by any hand-to-prop offset, so
-- it shows up as shimmer on offset-mounted props/weapons.
local function netWriteVec(v)
	net_WriteFloat(v.x)
	net_WriteFloat(v.y)
	net_WriteFloat(v.z)
end
local function netReadVec()
	return Vector(net_ReadFloat(), net_ReadFloat(), net_ReadFloat())
end
local function netWriteAng(a)
	net_WriteFloat(a.p)
	net_WriteFloat(a.y)
	net_WriteFloat(a.r)
end
local function netReadAng()
	return Angle(net_ReadFloat(), net_ReadFloat(), net_ReadFloat())
end
-- HELPERS
local function netReadFrame()
	local frame = {
		--ts = net.ReadFloat(),
		ts = net.ReadDouble(),
		characterYaw = net_ReadUInt(7) * 2.85714,
	}
	for i = 1, 10 do
		frame[FINGERS[i]] = net_ReadUInt(7) / 100
	end
	frame.hmdPos = netReadVec()
	frame.hmdAng = netReadAng()
	frame.lefthandPos = netReadVec()
	frame.lefthandAng = netReadAng()
	frame.righthandPos = netReadVec()
	frame.righthandAng = netReadAng()
	if net.ReadBool() then
		frame.waistPos = netReadVec()
		frame.waistAng = netReadAng()
		frame.leftfootPos = netReadVec()
		frame.leftfootAng = netReadAng()
		frame.rightfootPos = netReadVec()
		frame.rightfootAng = netReadAng()
	end
	frame.stickMoving = net.ReadBool()
	frame.eyeHeight = net.ReadFloat()
	frame.headToHmd = net.ReadFloat()
	return frame
end

local cv_eyeheight, cv_headtohmd
local function buildClientFrame(relative)
	local lp = LocalPlayer()
	if not IsValid(lp) then return nil end
	-- Determine character yaw with Glide support
	local vehicle = g_VR.vehicle.current
	local characterYaw
	if g_VR.vehicle.inside and IsValid(vehicle) then
		local rawYaw = vehicle:GetAngles().yaw
		rawYaw = (rawYaw + 180) % 360 - 180
		local MAX_YAW = 90
		characterYaw = math.Clamp(rawYaw, -MAX_YAW, MAX_YAW)
	else
		characterYaw = g_VR.characterYaw or 0
	end

	local tracking = g_VR.tracking
	local frame = {
		characterYaw = characterYaw,
		hmdPos = tracking.hmd.pos,
		hmdAng = tracking.hmd.ang,
	}

	local netTab = g_VR.net and g_VR.net[lp:SteamID()]
	local netFrame = netTab and netTab.lerpedFrame
	-- Handle hands: use netFrame if gripping, otherwise tracking
	if g_VR.wheelGrippedLeft and netFrame then
		frame.lefthandPos = netFrame.lefthandPos
		frame.lefthandAng = netFrame.lefthandAng
	else
		frame.lefthandPos = tracking.pose_lefthand.pos
		frame.lefthandAng = tracking.pose_lefthand.ang
	end

	if g_VR.wheelGrippedRight and netFrame then
		frame.righthandPos = netFrame.righthandPos
		frame.righthandAng = netFrame.righthandAng
	else
		frame.righthandPos = tracking.pose_righthand.pos
		frame.righthandAng = tracking.pose_righthand.ang
	end

	-- Assign fingers using loop
	local curlsL = g_VR.input.skeleton_lefthand.fingerCurls
	local curlsR = g_VR.input.skeleton_righthand.fingerCurls
	for i = 1, 5 do
		frame[FINGERS[i]] = curlsL[i]
		frame[FINGERS[i + 5]] = curlsR[i]
	end

	if g_VR.sixPoints then
		frame.waistPos = tracking.pose_waist.pos
		frame.waistAng = tracking.pose_waist.ang
		frame.leftfootPos = tracking.pose_leftfoot.pos
		frame.leftfootAng = tracking.pose_leftfoot.ang
		frame.rightfootPos = tracking.pose_rightfoot.pos
		frame.rightfootAng = tracking.pose_rightfoot.ang
	end

	if relative then frame = vrmod.utils.ConvertToRelativeFrame(frame) end
	-- Non-spatial fields: set AFTER ConvertToRelativeFrame which may create
	-- a new table containing only known position/angle fields.
	local wd = g_VR.input and g_VR.input.vector2_walkdirection
	frame.stickMoving = wd and (wd.x * wd.x + wd.y * wd.y) > 0.04 or false
	-- ConVar objects are stable: resolve the registry lookup once, keep only
	-- :GetFloat() in the per-tick path.
	cv_eyeheight = cv_eyeheight or GetConVar("vrmod_charactereyeheight")
	cv_headtohmd = cv_headtohmd or GetConVar("vrmod_characterheadtohmddist")
	frame.eyeHeight = cv_eyeheight and cv_eyeheight:GetFloat() or 66.8
	frame.headToHmd = cv_headtohmd and cv_headtohmd:GetFloat() or 6.3
	return frame
end

-- Yaw crush shared by full + delta writers: normalize to 0-360, pack 0-127
local function netWriteYaw(yaw)
	local tmp = yaw + math.ceil(math.abs(yaw) / 360) * 360
	net_WriteUInt((tmp - math.floor(tmp / 360) * 360) * 0.35, 7)
end

local function netWriteFrame(frame)
	--net.WriteFloat(SysTime())
	net.WriteDouble(SysTime())
	netWriteYaw(frame.characterYaw)
	for i = 1, 10 do
		net_WriteUInt(frame[FINGERS[i]] * 100, 7)
	end
	netWriteVec(frame.hmdPos)
	netWriteAng(frame.hmdAng)
	netWriteVec(frame.lefthandPos)
	netWriteAng(frame.lefthandAng)
	netWriteVec(frame.righthandPos)
	netWriteAng(frame.righthandAng)
	net.WriteBool(frame.waistPos ~= nil)
	if frame.waistPos then
		netWriteVec(frame.waistPos)
		netWriteAng(frame.waistAng)
		netWriteVec(frame.leftfootPos)
		netWriteAng(frame.leftfootAng)
		netWriteVec(frame.rightfootPos)
		netWriteAng(frame.rightfootAng)
	end
	net.WriteBool(frame.stickMoving or false)
	net.WriteFloat(frame.eyeHeight or 66.8)
	net.WriteFloat(frame.headToHmd or 6.3)
end

-- =============================================================================
-- DELTA COMPRESSION (client -> server optimization)
-- Instead of sending every field every tick, the client sends a 6-bit bitmask
-- followed by only the field groups that changed. The server reconstructs full
-- frames and relays them to other clients using the original netWriteFrame.
-- =============================================================================
-- Delta mask values (1 << bit), precomputed so send/read paths do plain
-- band/bor against constants instead of per-call bit.lshift chains.
local BM_YAW       = 1  -- bit 0: characterYaw changed
local BM_FINGERS   = 2  -- bit 1: any of 10 finger curls changed
local BM_HMD       = 4  -- bit 2: hmd pos/ang changed
local BM_LEFTHAND  = 8  -- bit 3: left hand pos/ang changed
local BM_RIGHTHAND = 16 -- bit 4: right hand pos/ang changed
local BM_FULLBODY  = 32 -- bit 5: fullbody tracking present (waist/feet)
local BM_KEYFRAME  = 31 -- yaw|fingers|hmd|lefthand|righthand

local KEYFRAME_INTERVAL    = 30 -- force a full frame every N ticks to resync

-- Thresholds for "changed" detection. FIXED and intentionally tiny: the delta
-- mask exists to skip genuinely idle parts, not to rate-limit slow movement.
-- Server-side consumers (pickup shadow controller, muzzle reads, server API)
-- need the full-precision stream, so slow motion always transmits.
-- vrmod_net_minsend no longer gates networking anywhere -- it is purely the
-- playermodel IK re-solve threshold, read by cl_character's UpdateIK (via the
-- eps argument of vrmod.utils.FramesAreEqual). Registration stays here so the
-- convar remains replicated and the settings UI keeps working.
local POS_DELTA_SQR = 0.01 * 0.01 -- source units, squared
local ANG_DELTA     = 0.05        -- degrees
local FINGER_DELTA  = 0.02        -- 2% curl

vrmod.AddCallbackedConvar("vrmod_net_minsend", nil, "0.1",
	FCVAR_REPLICATED, "Min movement (units) before the VR playermodel IK re-solves. Does not affect networking.",
	0, 0.1, tonumber, nil)

local function deltaPosChanged(a, b)
	if not a or not b then return true end
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return (dx * dx + dy * dy + dz * dz) > POS_DELTA_SQR
end

local function deltaAngChanged(a, b)
	if not a or not b then return true end
	return math.abs(math.AngleDifference(a.p, b.p)) > ANG_DELTA
		or math.abs(math.AngleDifference(a.y, b.y)) > ANG_DELTA
		or math.abs(math.AngleDifference(a.r, b.r)) > ANG_DELTA
end

local function deltaFingersChanged(frame, base)
	for i = 1, 10 do
		local key = FINGERS[i]
		if math.abs((frame[key] or 0) - (base[key] or 0)) > FINGER_DELTA then return true end
	end
	return false
end

local function buildDeltaMask(frame, base)
	local mask = 0
	if math.abs(math.AngleDifference(frame.characterYaw or 0, base.characterYaw or 0)) > ANG_DELTA then
		mask = bor(mask, BM_YAW)
	end
	if deltaFingersChanged(frame, base) then
		mask = bor(mask, BM_FINGERS)
	end
	if deltaPosChanged(frame.hmdPos, base.hmdPos) or deltaAngChanged(frame.hmdAng, base.hmdAng) then
		mask = bor(mask, BM_HMD)
	end
	if deltaPosChanged(frame.lefthandPos, base.lefthandPos) or deltaAngChanged(frame.lefthandAng, base.lefthandAng) then
		mask = bor(mask, BM_LEFTHAND)
	end
	if deltaPosChanged(frame.righthandPos, base.righthandPos) or deltaAngChanged(frame.righthandAng, base.righthandAng) then
		mask = bor(mask, BM_RIGHTHAND)
	end
	if frame.waistPos ~= nil then
		mask = bor(mask, BM_FULLBODY)
	end
	return mask
end

-- Write only changed field groups (client -> server)
local function netWriteDeltaFrame(frame, baseFrame)
	net.WriteDouble(SysTime())
	-- Build mask: for keyframes (no base), set all bits EXCEPT fullbody unless data exists
	local mask
	if not baseFrame then
		mask = frame.waistPos ~= nil and bor(BM_KEYFRAME, BM_FULLBODY) or BM_KEYFRAME
	else
		mask = buildDeltaMask(frame, baseFrame)
	end
	net_WriteUInt(mask, 6)

	if band(mask, BM_YAW) ~= 0 then
		netWriteYaw(frame.characterYaw)
	end
	if band(mask, BM_FINGERS) ~= 0 then
		for i = 1, 10 do
			net_WriteUInt((frame[FINGERS[i]] or 0) * 100, 7)
		end
	end
	if band(mask, BM_HMD) ~= 0 then
		netWriteVec(frame.hmdPos)
		netWriteAng(frame.hmdAng)
	end
	if band(mask, BM_LEFTHAND) ~= 0 then
		netWriteVec(frame.lefthandPos)
		netWriteAng(frame.lefthandAng)
	end
	if band(mask, BM_RIGHTHAND) ~= 0 then
		netWriteVec(frame.righthandPos)
		netWriteAng(frame.righthandAng)
	end
	if band(mask, BM_FULLBODY) ~= 0 then
		netWriteVec(frame.waistPos)
		netWriteAng(frame.waistAng)
		netWriteVec(frame.leftfootPos)
		netWriteAng(frame.leftfootAng)
		netWriteVec(frame.rightfootPos)
		netWriteAng(frame.rightfootAng)
	end
	net.WriteBool(frame.stickMoving or false)
	net.WriteFloat(frame.eyeHeight or 66.8)
	net.WriteFloat(frame.headToHmd or 6.3)
	return mask
end

-- Read delta frame on server, merge with previous frame to reconstruct full state
local function netReadDeltaFrame(baseFrame)
	local frame = {}
	frame.ts = net.ReadDouble()
	local mask = net.ReadUInt(6)

	-- Start from base frame defaults (or zero defaults if no base yet);
	-- branch hoisted out of the field loop
	if baseFrame then
		frame.characterYaw = baseFrame.characterYaw or 0
		for i = 1, 10 do
			local key = FINGERS[i]
			frame[key] = baseFrame[key] or 0
		end
		frame.hmdPos = baseFrame.hmdPos or Vector()
		frame.hmdAng = baseFrame.hmdAng or Angle()
		frame.lefthandPos = baseFrame.lefthandPos or Vector()
		frame.lefthandAng = baseFrame.lefthandAng or Angle()
		frame.righthandPos = baseFrame.righthandPos or Vector()
		frame.righthandAng = baseFrame.righthandAng or Angle()
		-- fullbody from base (may be nil — that's fine, means no fullbody)
		frame.waistPos = baseFrame.waistPos
		frame.waistAng = baseFrame.waistAng
		frame.leftfootPos = baseFrame.leftfootPos
		frame.leftfootAng = baseFrame.leftfootAng
		frame.rightfootPos = baseFrame.rightfootPos
		frame.rightfootAng = baseFrame.rightfootAng
	else
		frame.characterYaw = 0
		for i = 1, 10 do frame[FINGERS[i]] = 0 end
		frame.hmdPos, frame.hmdAng = Vector(), Angle()
		frame.lefthandPos, frame.lefthandAng = Vector(), Angle()
		frame.righthandPos, frame.righthandAng = Vector(), Angle()
	end

	-- Overwrite with fields present in the delta
	if band(mask, BM_YAW) ~= 0 then
		frame.characterYaw = net_ReadUInt(7) * 2.85714
	end
	if band(mask, BM_FINGERS) ~= 0 then
		for i = 1, 10 do
			frame[FINGERS[i]] = net_ReadUInt(7) / 100
		end
	end
	if band(mask, BM_HMD) ~= 0 then
		frame.hmdPos = netReadVec()
		frame.hmdAng = netReadAng()
	end
	if band(mask, BM_LEFTHAND) ~= 0 then
		frame.lefthandPos = netReadVec()
		frame.lefthandAng = netReadAng()
	end
	if band(mask, BM_RIGHTHAND) ~= 0 then
		frame.righthandPos = netReadVec()
		frame.righthandAng = netReadAng()
	end
	if band(mask, BM_FULLBODY) ~= 0 then
		frame.waistPos = netReadVec()
		frame.waistAng = netReadAng()
		frame.leftfootPos = netReadVec()
		frame.leftfootAng = netReadAng()
		frame.rightfootPos = netReadVec()
		frame.rightfootAng = netReadAng()
	else
		-- Unset bit = sender has no fullbody THIS tick (FBT off / trackers
		-- dropped). Inheriting base waist/feet kept stale FBT data on the
		-- relay forever.
		frame.waistPos, frame.waistAng = nil, nil
		frame.leftfootPos, frame.leftfootAng = nil, nil
		frame.rightfootPos, frame.rightfootAng = nil, nil
	end

	frame.stickMoving = net.ReadBool()
	frame.eyeHeight = net.ReadFloat()
	frame.headToHmd = net.ReadFloat()
	return frame
end

if CLIENT then
	vrmod.AddCallbackedConvar("vrmod_net_delay", nil, "0.1", nil, nil, nil, nil, tonumber, nil)
 
	local BUFFER_SIZE = 16
	-- Precomputed part keys, parts 1-3 always present, 4-6 FBT-optional
	local PKEYS, AKEYS = {}, {}
	for i, p in ipairs({"hmd", "lefthand", "righthand", "waist", "leftfoot", "rightfoot"}) do
		PKEYS[i], AKEYS[i] = p .. "Pos", p .. "Ang"
	end
	local LocalPlayer, LocalToWorld, math_Clamp = LocalPlayer, LocalToWorld, math.Clamp
	local player_GetBySteamID = player.GetBySteamID
	local lastSentFrame
	local deltaTickCounter = 0
 
	-- === SEND ===
	-- Baseline rule: lastSentFrame may only advance for groups actually
	-- written to the wire. The old full CopyFrame after every send dragged
	-- the baseline along with sub-threshold motion (slow hand aiming; higher
	-- tickrates shrink per-tick deltas further), so those groups were NEVER
	-- retransmitted -- remote hands froze while the rest kept moving. The
	-- periodic keyframe also never fired: the counter wraps inside 0..29 so
	-- "< KEYFRAME_INTERVAL" was always true, and one lost unreliable packet
	-- desynced the server base forever. Keyframe now fires on counter wrap.
	local function mergeGroup(dst, src, pk, ak)
		local sp = src[pk]
		if not sp then dst[pk], dst[ak] = nil, nil return end
		local dp = dst[pk]
		if dp then
			dp:Set(sp)
			dst[ak]:Set(src[ak])
		else
			dst[pk], dst[ak] = Vector(sp), Angle(src[ak])
		end
	end

	local function SendFrame(frame)
		net.Start("vrutil_net_tick", true)
		-- WriteVector/WriteAngle are lossy -- components land in coarse buckets.
		-- The server drives the physgun and every other GetAimVector consumer
		-- off these, so the quantisation showed up as a held prop shaking as
		-- the angle crossed bucket boundaries while you moved. Full floats,
		-- matching how the rest of the frame data is sent.
		local muz = g_VR.viewModelMuzzle
		local mp = muz and muz.Pos or vector_origin
		local ma = muz and muz.Ang or angle_zero
		net.WriteFloat(mp.x) net.WriteFloat(mp.y) net.WriteFloat(mp.z)
		net.WriteFloat(ma.p) net.WriteFloat(ma.y) net.WriteFloat(ma.r)
		local base = deltaTickCounter ~= 0 and lastSentFrame or nil
		local mask = netWriteDeltaFrame(frame, base)
		net.SendToServer()
		if not base then
			lastSentFrame = vrmod.utils.CopyFrame(frame) -- keyframe: full resync
		else
			local lsf = lastSentFrame
			if band(mask, BM_YAW) ~= 0 then lsf.characterYaw = frame.characterYaw end
			if band(mask, BM_FINGERS) ~= 0 then
				for i = 1, 10 do
					local k = FINGERS[i]
					lsf[k] = frame[k]
				end
			end
			if band(mask, BM_HMD) ~= 0 then mergeGroup(lsf, frame, "hmdPos", "hmdAng") end
			if band(mask, BM_LEFTHAND) ~= 0 then mergeGroup(lsf, frame, "lefthandPos", "lefthandAng") end
			if band(mask, BM_RIGHTHAND) ~= 0 then mergeGroup(lsf, frame, "righthandPos", "righthandAng") end
			if band(mask, BM_FULLBODY) ~= 0 then
				mergeGroup(lsf, frame, "waistPos", "waistAng")
				mergeGroup(lsf, frame, "leftfootPos", "leftfootAng")
				mergeGroup(lsf, frame, "rightfootPos", "rightfootAng")
			end
		end
		deltaTickCounter = (deltaTickCounter + 1) % KEYFRAME_INTERVAL
	end
 
	-- Transmit timer factored out so the rate can change live (see the
	-- vrmod_net_tickrate callback below). Send rate is clamped to 10..100 Hz
	-- regardless of the convar's raw value.
	local function StartTransmitTimer()
		local rate = math.Clamp(GetConVar("vrmod_net_tickrate"):GetFloat(), 10, 100)
		timer.Create("vrmod_transmit", 1 / rate, 0, function()
			if not (g_VR.threePoints and g_VR.active) then return end
			local frame = buildClientFrame(true)
			if not lastSentFrame or not vrmod.utils.FramesAreEqual(frame, lastSentFrame) then
				SendFrame(frame)
			end
		end)
	end

	-- Recreate the timer in place when the (replicated) rate changes, so admin
	-- edits from the Server tab take effect without a VR restart.
	cvars.AddChangeCallback("vrmod_net_tickrate", function()
		if timer.Exists("vrmod_transmit") then
			deltaTickCounter = 0 -- next packet is a keyframe: clean resync at the new rate
			StartTransmitTimer()
		end
	end, "vrmod_net_tickrate_live")

	function VRUtilNetworkInit()
		deltaTickCounter = 0
		lastSentFrame = nil
		StartTransmitTimer()
		net.Start("vrutil_net_join", true)
		net.WriteBool(GetConVar("vrmod_althead"):GetBool())
		net.WriteBool(GetConVar("vrmod_floatinghands"):GetBool())
		net.SendToServer()
		-- Send characterIK state separately so the join wire format stays stable
		local cvIK = GetConVar("vrmod_characterik")
		net.Start("vrmod_characterik_sync")
		net.WriteBool(cvIK and cvIK:GetBool() or true)
		net.SendToServer()
		-- Send character calibration (eyeHeight + headToHmdDist)
		local cvEye = GetConVar("vrmod_charactereyeheight")
		local cvHmd = GetConVar("vrmod_characterheadtohmddist")
		local eyeVal = cvEye and cvEye:GetFloat() or 66.8
		local hmdVal = cvHmd and cvHmd:GetFloat() or 6.3
		net.Start("vrmod_charcal_sync")
		net.WriteFloat(eyeVal)
		net.WriteFloat(hmdVal)
		net.SendToServer()
	end
 
	-- === INTERPOLATION (in place) ===
	-- Each player tab owns a persistent lerpedFrame + pooled Vector/Angle
	-- objects (v._lfPool) mutated every PreRender. Old path allocated a table
	-- + ~12 Vectors/Angles per player per frame; this allocates nothing in
	-- steady state. Ring-buffer frames are never written. Snapshots of
	-- lerpedFrame must go through vrmod.utils.CopyFrame (cl_character does).
	local function LerpFrameInto(v, a, b, t)
		local lf, pool = v.lerpedFrame, v._lfPool
		if not pool then
			lf, pool = {}, {}
			v.lerpedFrame, v._lfPool = lf, pool
		end
		local yA = a.characterYaw or 0
		-- (d + 180) % 360 - 180 == math.NormalizeAngle, inlined (pure arithmetic)
		lf.characterYaw = yA + (((b.characterYaw or 0) - yA + 180) % 360 - 180) * t
		for i = 1, 10 do
			local k = FINGERS[i]
			local fa = a[k] or 0
			lf[k] = fa + ((b[k] or 0) - fa) * t
		end
		for i = 1, 6 do
			local pk, ak = PKEYS[i], AKEYS[i]
			local aP, bP = a[pk], b[pk]
			if not aP and not bP then
				lf[pk], lf[ak] = nil, nil
			else
				local j = i + i
				local ov, oa = pool[j - 1], pool[j]
				if not ov then
					ov, oa = Vector(), Angle()
					pool[j - 1], pool[j] = ov, oa
				end
				if aP and bP then
					-- Native in-place lerp, 0 allocs: ov = aP + (bP - aP) * t;
					-- Angle:Normalize wraps to -180..180 == LerpAngle shortest path
					ov:Set(bP) ov:Sub(aP) ov:Mul(t) ov:Add(aP)
					local aA = a[ak]
					oa:Set(b[ak]) oa:Sub(aA) oa:Normalize() oa:Mul(t) oa:Add(aA)
				else -- part present in only one frame: copy it
					ov:Set(bP or aP)
					oa:Set(b[ak] or a[ak])
				end
				lf[pk], lf[ak] = ov, oa
			end
		end
		lf.stickMoving = b.stickMoving
		lf.eyeHeight = b.eyeHeight
		lf.headToHmd = b.headToHmd
		return lf
	end
 
	-- === MAIN LERP (runs every PreRender at monitor refresh rate) ===
	local VEH_FWD_ANG = Angle(0, 90, 0)
	local function LerpOtherVRPlayers()
		local lp = LocalPlayer()
		local playTime = SysTime() - (convarValues.vrmod_net_delay or 0.1)
 
		for steamid, v in pairs(g_VR.net) do
			-- Cached entity: player.GetBySteamID scans every player per call
			-- (O(players^2) across this loop). Re-resolve only on slot change.
			local ply = v._ply
			if not (IsValid(ply) and ply:SteamID() == steamid) then
				ply = player_GetBySteamID(steamid)
				v._ply = ply
				if not IsValid(ply) then continue end
			end
			-- Dormant players are not drawn: skip the solve, hold last frame
			if ply == lp or ply:IsDormant() then continue end
 
			local buf = v.frameBuffer
			local count = v.bufCount or 0
			if count == 0 then continue end
			local head = v.bufHead
 
			-- Find frame pair straddling playTime
			local bestIdx = -1
			for i = 0, count - 1 do
				local f = buf[(head + i) % BUFFER_SIZE + 1]
				if f and f._recvTime <= playTime then bestIdx = i else break end
			end
 
			local frameA, frameB
			if bestIdx == -1 then
				-- All frames in future — use oldest
				frameA = buf[head % BUFFER_SIZE + 1]
				frameB = frameA
			elseif bestIdx == count - 1 then
				-- Past all frames — hold on newest (no wild extrapolation)
				frameB = buf[(head + count - 1) % BUFFER_SIZE + 1]
				frameA = frameB
			else
				frameA = buf[(head + bestIdx) % BUFFER_SIZE + 1]
				frameB = buf[(head + bestIdx + 1) % BUFFER_SIZE + 1]
			end
 
			-- Compute lerped frame (a == b with t = 0 is an exact snap copy)
			local lf
			if frameA == frameB or not frameA or not frameB then
				local src = frameB or frameA
				if not src then continue end
				lf = LerpFrameInto(v, src, src, 0)
			else
				local dt = frameB._recvTime - frameA._recvTime
				local t = dt > 0.001 and math_Clamp((playTime - frameA._recvTime) / dt, 0, 1) or 1
				lf = LerpFrameInto(v, frameA, frameB, t)
			end
 
			-- Transform relative -> world. Frames are relative to plyPos with
			-- zero angle outside vehicles (ConvertToRelativeFrame), so the
			-- common case is a pure in-place translation: no LocalToWorld,
			-- no allocation.
			local plyPos = ply:GetPos()
			if ply:InVehicle() then
				local plyAng = ply:GetVehicle():GetAngles()
				local _, fwdAng = LocalToWorld(vector_origin, VEH_FWD_ANG, vector_origin, plyAng)
				lf.characterYaw = fwdAng.yaw
				for i = 1, 6 do
					local pk = PKEYS[i]
					local p = lf[pk]
					if p then
						local ak = AKEYS[i]
						lf[pk], lf[ak] = LocalToWorld(p, lf[ak], plyPos, plyAng)
					end
				end
			else
				for i = 1, 6 do
					local p = lf[PKEYS[i]]
					if p then p:Add(plyPos) end
				end
			end
		end
	end
 
	-- === LOCAL PLAYER UPDATE (unchanged) ===
	function VRUtilNetUpdateLocalPly(relative)
		local tab = g_VR.net[LocalPlayer():SteamID()]
		if g_VR.threePoints and tab then
			tab.lerpedFrame = buildClientFrame(relative)
			return tab.lerpedFrame
		end
	end
 
	-- === CLEANUP (unchanged) ===
	function VRUtilNetworkCleanup()
		timer.Remove("vrmod_transmit")
		lastSentFrame = nil
		deltaTickCounter = 0
		net.Start("vrutil_net_exit")
		net.SendToServer()
	end
 
	-- === RECEIVE REMOTE FRAMES — ring buffer instead of overwrite ===
	net.Receive("vrutil_net_tick", function(len)
		local ply = net.ReadEntity()
		if not IsValid(ply) or ply == LocalPlayer() then return end
		local steamid = ply:SteamID()
		local tab = g_VR.net[steamid]
		if not tab then return end
		if (tab.bufCount or 0) == 0 then
			print("[VRNet] First tick for " .. ply:Nick() .. " (" .. steamid .. ")")
		end
 
		local frame = netReadFrame()
		frame._recvTime = SysTime()
 
		-- Init buffer if missing (handles players who joined before this code loaded)
		if not tab.frameBuffer then
			tab.frameBuffer = {}
			tab.bufHead = 0
			tab.bufCount = 0
		end
 
		local buf = tab.frameBuffer
		local writeIdx
		if tab.bufCount < BUFFER_SIZE then
			writeIdx = (tab.bufHead + tab.bufCount) % BUFFER_SIZE + 1
			tab.bufCount = tab.bufCount + 1
		else
			writeIdx = tab.bufHead % BUFFER_SIZE + 1
			tab.bufHead = (tab.bufHead + 1) % BUFFER_SIZE
		end
		buf[writeIdx] = frame
 
		-- Compat: external code may read lastFrame
		tab.lastFrame = frame
		tab.playbackTime = frame.ts
	end)
 
	-- === PLAYER JOIN — buffer fields added ===
	net.Receive("vrutil_net_join", function(len)
		local ply = net.ReadEntity()
		if not IsValid(ply) then return end
		local sid = ply:SteamID()
		local prev = g_VR.net[sid]
		g_VR.net[sid] = {
			characterAltHead = net.ReadBool(),
			dontHideBullets = net.ReadBool(),
			-- Preserve per-player state that arrives via separate sync messages;
			-- join re-fires on respawn and would otherwise wipe calibration data.
			characterIK = prev and prev.characterIK,
			charEyeHeight = prev and prev.charEyeHeight,
			charHeadToHmd = prev and prev.charHeadToHmd,
			lastFrame = nil,
			playbackTime = 0,
			frameBuffer = {},
			bufHead = 0,
			bufCount = 0,
		}
		hook.Add("PreRender", "vrutil_hook_netlerp", LerpOtherVRPlayers)
		hook.Run("VRMod_Start", ply)
	end)
 
	net.Receive("vrmod_characterik_sync", function()
		local ply = net.ReadEntity()
		if not IsValid(ply) then return end
		local sid = ply:SteamID()
		if g_VR.net[sid] then g_VR.net[sid].characterIK = net.ReadBool() end
	end)

	cvars.AddChangeCallback("vrmod_characterik", function(_, _, new)
		if not g_VR.active then return end
		net.Start("vrmod_characterik_sync")
		net.WriteBool(new ~= "0" and new ~= "")
		net.SendToServer()
	end, "vrmod_net_charik_sync")

	net.Receive("vrmod_charcal_sync", function()
		local ply = net.ReadEntity()
		if not IsValid(ply) then return end
		local sid = ply:SteamID()
		if g_VR.net[sid] then
			g_VR.net[sid].charEyeHeight = net.ReadFloat()
			g_VR.net[sid].charHeadToHmd = net.ReadFloat()
		end
	end)

	local function SendCharCal()
		if not g_VR.active then return end
		local cvEye = GetConVar("vrmod_charactereyeheight")
		local cvHmd = GetConVar("vrmod_characterheadtohmddist")
		net.Start("vrmod_charcal_sync")
		net.WriteFloat(cvEye and cvEye:GetFloat() or 66.8)
		net.WriteFloat(cvHmd and cvHmd:GetFloat() or 6.3)
		net.SendToServer()
	end
	cvars.AddChangeCallback("vrmod_charactereyeheight", SendCharCal, "vrmod_net_charcal")
	cvars.AddChangeCallback("vrmod_characterheadtohmddist", SendCharCal, "vrmod_net_charcal2")

	-- === PLAYER EXIT (unchanged) ===
	local swepOriginalFovs = {}
	local swepOriginalFlips = {}
	net.Receive("vrutil_net_exit", function(len)
		local steamid = net.ReadString()
		if game.SinglePlayer() then steamid = LocalPlayer():SteamID() end
		local ply = player.GetBySteamID(steamid)
		g_VR.net[steamid] = nil
		if table.Count(g_VR.net) == 0 then hook.Remove("PreRender", "vrutil_hook_netlerp") end
		if ply == LocalPlayer() then
			for k, v in pairs(swepOriginalFovs) do
				local wep = ply:GetWeapon(k)
				if IsValid(wep) then wep.ViewModelFOV = v end
			end
			swepOriginalFovs = {}
			for k, v in pairs(swepOriginalFlips) do
				local wep = ply:GetWeapon(k)
				if IsValid(wep) then wep.ViewModelFlip = v end
			end
			swepOriginalFlips = {}
		end
		hook.Run("VRMod_Exit", ply, steamid)
	end)
 
	-- === SWITCH WEAPON (unchanged — kept verbatim from original) ===
	net.Receive("vrutil_net_switchweapon", function(len)
		local class = net.ReadString()
		local vm = net.ReadString()
		local isMag = string.StartWith(class, "avr_mag_")
		local lp = LocalPlayer()
		if g_VR.net[lp:SteamID()] == nil then return end
		if isMag then return end
		-- The waitforwm timer below only removes ITSELF, and only on a class
		-- match, so switching WM -> VM leaks a live 0-interval timer that can
		-- later stomp g_VR.viewModel with a weapon entity while wmActive is
		-- false. Every switch supersedes the last one; kill it here.
		timer.Remove("vrutil_waitforwm")
 
		if class == "" or vm == "" then
			g_VR.viewModel = nil
			g_VR.openHandAngles = g_VR.defaultOpenHandAngles
			g_VR.closedHandAngles = g_VR.defaultClosedHandAngles
			g_VR.currentvmi = nil
			g_VR.viewModelMuzzle = nil
			g_VR.wmActive = false
			local weapon = lp:GetActiveWeapon()
			if IsValid(weapon) then weapon:SetNoDraw(true) end
			local viewModel = lp:GetViewModel()
			if IsValid(viewModel) then viewModel:SetNoDraw(false) end
			return
		end
 
		-- Worldmodel mode: global convar, per-weapon override, the forced
		-- registry (g_VR.ForceWorldModel / wm_base), or a weapon whose instance
		-- inherits IsWMBase. These MUST render worldmodel -- the viewmodel branch
		-- below SetNoDraw(true)s the weapon, killing its DrawWorldModel. GetWeapon
		-- (by class) is reliable here even though the ACTIVE weapon may not have
		-- swapped yet, and the instance carries inherited base fields (unlike
		-- weapons.GetStored, which only sees a child's own table).
		local aw = lp:GetWeapon(class)
		if GetConVar("vrmod_useworldmodels"):GetBool()
		or (g_VR.wmWeapons and g_VR.wmWeapons[class])
		or (g_VR.wmForced and g_VR.wmForced[class])
		or (IsValid(aw) and aw.IsWMBase) then
			g_VR.wmActive = true
			vrmod.SetRightHandOpenFingerAngles(g_VR.zeroHandAngles)
			vrmod.SetRightHandClosedFingerAngles(g_VR.zeroHandAngles)
			g_VR.currentvmi = nil
			timer.Create("vrutil_waitforwm", 0, 0, function()
				local aw = lp:GetActiveWeapon()
				if IsValid(aw) and aw:GetClass() == class then
					timer.Remove("vrutil_waitforwm")
					-- Both other branches SetNoDraw(true) the weapon entity and
					-- nothing ever clears it. Dropping runs the vm == "" branch
					-- against the STILL-ACTIVE real weapon (SelectWeapon is
					-- deferred a tick), so any weapon that survived a drop
					-- without being stripped -- holster copy, DW ghost -- comes
					-- back hidden, and worldmodel mode has nothing left to draw.
					aw:SetNoDraw(false)
					g_VR.viewModel = aw
				end
			end)
			return
		end

		g_VR.wmActive = false
		-- Drop the outgoing weapon's muzzle. GetViewModel() is grabbed below
		-- before the engine has swapped the viewmodel's model over, so without
		-- this the aim vector and laser keep reporting the PREVIOUS weapon's
		-- attachment for the deploy gap -- the displacement on first grab.
		g_VR.viewModelMuzzle = nil
		local wep = lp:GetActiveWeapon()
		if IsValid(wep) then wep:SetNoDraw(true) end
		local viewModel = lp:GetViewModel()
		if IsValid(viewModel) then
			viewModel:SetNoDraw(false)
			g_VR.viewModel = viewModel
		end
 
		wep = lp:GetWeapon(class)
		if IsValid(wep) and wep.ViewModelFOV then
			if not swepOriginalFovs[class] then swepOriginalFovs[class] = wep.ViewModelFOV end
			wep.ViewModelFOV = GetConVar("fov_desired"):GetFloat()
		end
 
		-- Neutralize ViewModelFlip — VR positions the viewmodel directly,
		-- engine flip mirrors the Y axis causing auto-offset to be inverted.
		if IsValid(wep) and wep.ViewModelFlip then
			if swepOriginalFlips[class] == nil then swepOriginalFlips[class] = true end
			wep.ViewModelFlip = false
		end
 
		local vmi = g_VR.viewModelInfo[class] or {}
		local model = isMag and vm or vmi.modelOverride ~= nil and vmi.modelOverride or vm
		if vmi.offsetPos == nil or vmi.offsetAng == nil then
			vmi.offsetPos, vmi.offsetAng = Vector(0, 0, 0), Angle(0, 0, 0)
			vmi.autoComputed = true -- never persisted; recomputed per session
			local cm = ClientsideModel(model)
			if IsValid(cm) then
				cm:SetupBones()
				local bone = cm:LookupBone("ValveBiped.Bip01_R_Hand")
				if bone then
					local boneMat = cm:GetBoneMatrix(bone)
					local bonePos, boneAng = boneMat:GetTranslation(), boneMat:GetAngles()
					boneAng:RotateAroundAxis(boneAng:Forward(), 180)
					vmi.offsetPos, vmi.offsetAng = WorldToLocal(Vector(0, 0, 0), Angle(0, 0, 0), bonePos, boneAng)
					vmi.offsetPos = vmi.offsetPos + g_VR.viewModelInfo.autoOffsetAddPos
				end
				cm:Remove()
			end
		end
 
		vmi.closedHandAngles = vrmod.GetRightHandFingerAnglesFromModel(model)
		vrmod.SetRightHandClosedFingerAngles(vmi.closedHandAngles)
		vrmod.SetRightHandOpenFingerAngles(vmi.closedHandAngles)
		g_VR.viewModelInfo[class] = vmi
		g_VR.currentvmi = vmi
	end)
 
	-- === AUTOSTART / VEHICLE HOOKS (unchanged) ===
	hook.Add("CreateMove", "vrutil_hook_joincreatemove", function(cmd)
		hook.Remove("CreateMove", "vrutil_hook_joincreatemove")
		timer.Simple(2, function()
			net.Start("vrutil_net_requestvrplayers")
			net.SendToServer()
		end)
		timer.Simple(2, function()
			if SysTime() < 120 then GetConVar("vrmod_autostart"):SetBool(false) end
			if GetConVar("vrmod_autostart"):GetBool() then
				timer.Create("vrutil_timer_tryautostart", 1, 0, function()
					local pm = LocalPlayer():GetModel()
					if pm ~= nil and pm ~= "models/player.mdl" and pm ~= "" then
						VRUtilClientStart()
						timer.Remove("vrutil_timer_tryautostart")
					end
				end)
			end
		end)
	end)
 
	net.Receive("vrutil_net_entervehicle", function(len) hook.Call("VRMod_EnterVehicle", nil) end)
	net.Receive("vrutil_net_exitvehicle", function(len) hook.Call("VRMod_ExitVehicle", nil) end)
end

if SERVER then
	util.AddNetworkString("vrutil_net_join")
	util.AddNetworkString("vrutil_net_exit")
	util.AddNetworkString("vrutil_net_switchweapon")
	util.AddNetworkString("vrutil_net_tick")
	util.AddNetworkString("vrutil_net_requestvrplayers")
	util.AddNetworkString("vrutil_net_entervehicle")
	util.AddNetworkString("vrutil_net_exitvehicle")
	util.AddNetworkString("vrmod_characterik_sync")
	util.AddNetworkString("vrmod_charcal_sync")
	-- maxLen is in BITS. FBT keyframes run ~1500 bits (hmd+hands+fullbody+
	-- muzzle); 1200 silently dropped every FBT tick. 210/sec covers 100 Hz
	-- plus timer catch-up bursts after client hitches.
	vrmod.NetReceiveLimited("vrutil_net_tick", 210, 2400, function(len, ply)
		vrmod.logger.Debug("received net_tick, len: " .. len)
		local steamid = ply:SteamID()
		if g_VR[steamid] == nil then return end
		local viewHackPos = Vector(net.ReadFloat(), net.ReadFloat(), net.ReadFloat())
		local viewHackAng = Angle(net.ReadFloat(), net.ReadFloat(), net.ReadFloat())
		-- Store muzzle/VR viewmodel info
		g_VR[steamid].muzzlePos = viewHackPos
		g_VR[steamid].muzzleAng = viewHackAng
		-- Read delta-compressed frame, merging with the last known frame for this player
		local baseFrame = g_VR[steamid].latestFrame
		local frame = netReadDeltaFrame(baseFrame)
		g_VR[steamid].latestFrame = frame
		if not viewHackPos:IsZero() and util.IsInWorld(viewHackPos) then
			ply.viewOffset = viewHackPos - ply:EyePos() + ply.viewOffset
			ply:SetCurrentViewOffset(ply.viewOffset)
			ply:SetViewOffset(Vector(0, 0, ply.viewOffset.z))
		else
			ply:SetCurrentViewOffset(ply.originalViewOffset)
			ply:SetViewOffset(ply.originalViewOffset)
		end

		--relay frame to everyone except sender
		net.Start("vrutil_net_tick", true)
		net.WriteEntity(ply)
		netWriteFrame(frame)
		--net.Broadcast()
		net.SendOmit(ply)
	end)

	vrmod.NetReceiveLimited("vrutil_net_join", 5, 2, function(len, ply)
		if g_VR[ply:SteamID()] ~= nil then return end
		ply:DrawShadow(false)
		ply.originalViewOffset = ply:GetViewOffset()
		ply.viewOffset = Vector(0, 0, 0)
		--add gt entry
		g_VR[ply:SteamID()] = {
			--store join values so we can re-send joins to players that connect later
			characterAltHead = net.ReadBool(),
			dontHideBullets = net.ReadBool(),
		}

		ply:Give("weapon_vrmod_empty")
		ply:SelectWeapon("weapon_vrmod_empty")
		--relay join message to everyone except players that aren't fully loaded in yet
		local omittedPlayers = {}
		for k, v in ipairs(player.GetAll()) do
			if not v.hasRequestedVRPlayers then omittedPlayers[#omittedPlayers + 1] = v end
		end

		net.Start("vrutil_net_join")
		net.WriteEntity(ply)
		net.WriteBool(g_VR[ply:SteamID()].characterAltHead)
		net.WriteBool(g_VR[ply:SteamID()].dontHideBullets)
		net.SendOmit(omittedPlayers)
		hook.Run("VRMod_Start", ply)
	end)

	vrmod.NetReceiveLimited("vrmod_characterik_sync", 10, 1, function(len, ply)
		local steamid = ply:SteamID()
		if not g_VR[steamid] then return end
		g_VR[steamid].characterIK = net.ReadBool()
		net.Start("vrmod_characterik_sync")
		net.WriteEntity(ply)
		net.WriteBool(g_VR[steamid].characterIK)
		net.Broadcast()
	end)

	vrmod.NetReceiveLimited("vrmod_charcal_sync", 10, 1, function(len, ply)
		local steamid = ply:SteamID()
		if not g_VR[steamid] then return end
		g_VR[steamid].charEyeHeight = net.ReadFloat()
		g_VR[steamid].charHeadToHmd = net.ReadFloat()
		net.Start("vrmod_charcal_sync")
		net.WriteEntity(ply)
		net.WriteFloat(g_VR[steamid].charEyeHeight)
		net.WriteFloat(g_VR[steamid].charHeadToHmd)
		net.Broadcast()
	end)

	local function net_exit(steamid)
		if g_VR[steamid] ~= nil then
			g_VR[steamid] = nil
			local ply = player.GetBySteamID(steamid)
			if ply.originalViewOffset then
				ply:SetCurrentViewOffset(ply.originalViewOffset)
				ply:SetViewOffset(ply.originalViewOffset)
			end

			net.Start("vrutil_net_exit")
			net.WriteString(steamid)
			net.Broadcast()
			hook.Run("VRMod_Exit", ply)
		end
	end

	vrmod.NetReceiveLimited("vrutil_net_exit", 5, 0, function(len, ply) net_exit(ply:SteamID()) end)
	hook.Add("PlayerDisconnected", "vrutil_hook_playerdisconnected", function(ply) net_exit(ply:SteamID()) end)
	net.Receive("vrutil_net_requestvrplayers", function(len, ply)
		ply.hasRequestedVRPlayers = true
		for k, v in pairs(g_VR) do
			if type(k) == "string" and k:match("^STEAM_[0-5]:[01]:%d+$") then
				local vrPly = player.GetBySteamID(k)
				if IsValid(vrPly) then
					net.Start("vrutil_net_join")
					net.WriteEntity(vrPly)
					net.WriteBool(v.characterAltHead)
					net.WriteBool(v.dontHideBullets)
					net.Send(ply)
					if v.characterIK ~= nil then
						net.Start("vrmod_characterik_sync")
						net.WriteEntity(vrPly)
						net.WriteBool(v.characterIK)
						net.Send(ply)
					end
					if v.charEyeHeight then
						net.Start("vrmod_charcal_sync")
						net.WriteEntity(vrPly)
						net.WriteFloat(v.charEyeHeight)
						net.WriteFloat(v.charHeadToHmd or 6.3)
						net.Send(ply)
					end
				else
					vrmod.logger.Err("Invalid SteamID \"" .. k .. "\" found in player table")
				end
			end
		end
	end)

	-- Suppress Draconic's turn-in-place animation for VR players by keeping TurnCD
	-- pinned ahead of CurTime(), so the ct > ply.TurnCD gate never opens.
	hook.Add("PlayerTick", "vrmod_fix_drc_turn", function(ply, cmd)
		if not (g_VR[ply:SteamID()] and g_VR[ply:SteamID()].latestFrame) then return end
		ply.TurnCD = CurTime() + 1
	end)

	-- Expand server PVS to the VR player's actual HMD position.
	-- Frame positions are relative to ply:GetPos() with Angle(0,0,0)
	-- (vehicle angle when seated). Without this, crouching in tight
	-- geometry (vents, tunnels) puts the engine-side EyePos in a
	-- different vis-leaf than the HMD, so entities are never sent.
	hook.Add("SetupPlayerVisibility", "vrmod_pvs", function(ply)
		local vrData = g_VR[ply:SteamID()]
		if not vrData then return end
		local frame = vrData.latestFrame
		if not frame or not frame.hmdPos then return end
		local pp = ply:GetPos()
		if ply:InVehicle() then
			local veh = ply:GetVehicle()
			if IsValid(veh) then
				AddOriginToPVS(LocalToWorld(frame.hmdPos, angle_zero, pp, veh:GetAngles()))
				return
			end
		end
		AddOriginToPVS(pp + frame.hmdPos)
	end)

	hook.Add("PlayerDeath", "vrutil_hook_playerdeath", function(ply, inflictor, attacker)
		if g_VR[ply:SteamID()] ~= nil then
			net.Start("vrutil_net_exit")
			net.WriteString(ply:SteamID())
			net.Broadcast()
		end
	end)

	hook.Add("PlayerSpawn", "vrutil_hook_playerspawn", function(ply)
		local steamid = ply:SteamID()
		local vrData = g_VR[steamid]
		if vrData == nil then return end
		ply:Give("weapon_vrmod_empty")
		-- Defer broadcast one tick: at PlayerSpawn the playermodel has not been
		-- applied yet, so clients would build bone info against "models/player.mdl".
		-- That left the client's CharacterInit with stale bones and the player
		-- stuck in desktop animations until a model change re-triggered init.
		timer.Simple(0, function()
			if not IsValid(ply) or g_VR[steamid] == nil then return end
			net.Start("vrutil_net_join")
			net.WriteEntity(ply)
			net.WriteBool(vrData.characterAltHead)
			net.WriteBool(vrData.dontHideBullets)
			net.Broadcast()
		end)
	end)

	hook.Add("PlayerSwitchWeapon", "vrutil_hook_playerswitchweapon", function(ply, old, new)
		if g_VR[ply:SteamID()] ~= nil then
			net.Start("vrutil_net_switchweapon", true)
			local class, vm = vrmod.utils.WepInfo(new)
			if class and vm then
				timer.Simple(0, function() vrmod.utils.ComputePhysicsParams(vm) end)
				net.WriteString(class)
				net.WriteString(vm)
			else
				net.WriteString("")
				net.WriteString("")
			end

			net.Send(ply)
			timer.Simple(0, function() end)
		end
	end)

	hook.Add("PlayerEnteredVehicle", "vrutil_hook_playerenteredvehicle", function(ply, veh)
		if g_VR[ply:SteamID()] ~= nil then
			net.Start("vrutil_net_entervehicle", true)
			net.Send(ply)
			ply:SetAllowWeaponsInVehicle(1)
		end
	end)

	hook.Add("PlayerLeaveVehicle", "vrutil_hook_playerleavevehicle", function(ply, veh)
		if g_VR[ply:SteamID()] ~= nil then
			net.Start("vrutil_net_exitvehicle", true)
			net.Send(ply)
		end
	end)
end