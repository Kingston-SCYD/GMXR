-- Prop weight: held props drag the hand pose behind the controller, scaled by
-- mass against vrmod_pickup_weight through a ramp curve. Two-hand grips split
-- the load by lever arm, so each hand lags by its own share. Smoothing runs in
-- playspace (origin-relative) so locomotion, teleport and snap turn never trail.
-- The pose is edited inside VRMod_Tracking, upstream of hand collisions and the
-- netframe, so the server pickup target, other players and throws all follow.
-- Server settings (Server > Pickup): replicated, so every client runs the
-- host's values; vrmod_weight 0 turns prop weight off for everyone.
g_VR = g_VR or {}

local NW = "vrw_m"
local FL = FCVAR_ARCHIVE + FCVAR_REPLICATED
local cvOn   = CreateConVar("vrmod_weight", "1", FL + FCVAR_NOTIFY, "Held prop mass drags the hand pose (0 disables prop weight)", 0, 1)
local cvLag  = CreateConVar("vrmod_weight_lag", "0.3", FL, "Hand smoothing time constant (s) at max pickup weight", 0, 2)
local cvRamp = CreateConVar("vrmod_weight_ramp", "2", FL, "Ramp exponent on mass/max (1 = linear, >1 keeps light props snappy)", 0.25, 6)

if SERVER then
	-- Server-authoritative mass (weight tool, ragdoll totals), stamped per grab
	local function Stamp(ent)
		if not IsValid(ent) then return end
		local om, m = ent.vrmod_original_masses, 0
		for i = 0, ent:GetPhysicsObjectCount() - 1 do
			local p = ent:GetPhysicsObjectNum(i)
			if IsValid(p) then m = m + (om and om[i] or p:GetMass()) end
		end
		if m > 0 then ent:SetNWFloat(NW, m) end
	end

	-- Must never return a value: VRMod_Pickup == false blocks the grab
	hook.Add("VRMod_Pickup", "vrmod_weight", function(ply, ent)
		if not cvOn:GetBool() then return end
		if not (ent:IsNPC() or ent:IsPlayer()) then Stamp(ent) return end
		-- NPC/player grabs swap to a ragdoll after this hook; stamp it next tick
		local sid, i = ply:SteamID(), ply.vrmod_pickup_left_hand and 1 or 2
		timer.Simple(0, function()
			local d = g_VR[sid]
			local h = d and d.heldItems and d.heldItems[i]
			if h then Stamp(h.ent) end
		end)
	end)
	return
end

local cvMax

local IsValid, WorldToLocal, LocalToWorld, RealFrameTime, exp = IsValid, WorldToLocal, LocalToWorld, RealFrameTime, math.exp
local TAU_RATE = 6 -- 1/s: lag eases in on grab and out on release, no snap
local tau, live, w = {0, 0}, {false, false}, {0, 0}
-- Playspace-local smoothed state: position, forward, up (fwd/up lerp + AngleEx
-- is gimbal-safe where per-component Euler lerp spins near pitch 90)
local sP, sF, sU = {Vector(), Vector()}, {Vector(), Vector()}, {Vector(), Vector()}

local function Mass(e)
	local m = e:GetNWFloat(NW, 0)
	if m > 0 then return m end
	local p = e:GetPhysicsObject() -- fallback until the NW stamp lands
	return IsValid(p) and p:GetMass() or 0
end

hook.Add("VRMod_Tracking", "vrmod_weight", function()
	-- Off and fully eased out: nothing to do. Turned off mid-hold, the lag
	-- eases out below instead of snapping.
	local on = cvOn:GetBool()
	if not on and tau[1] == 0 and tau[2] == 0 then return end
	local t = g_VR.tracking
	local pL, pR = t and t.pose_lefthand, t and t.pose_righthand
	if not (pL and pR) then return end
	local hL, hR = g_VR.heldEntityLeft, g_VR.heldEntityRight
	local okL, okR = on and IsValid(hL), on and IsValid(hR)
	if okL and hL == hR then
		-- Two-hand lever split: the hand nearer the centre of mass carries more
		local m, c = Mass(hL), hL:WorldSpaceCenter()
		local dL, dR = c:Distance(pL.pos), c:Distance(pR.pos)
		local s = dL + dR
		local l = s > 0 and m * dR / s or m * 0.5
		w[1], w[2] = l, m - l
	else
		w[1] = okL and Mass(hL) or 0
		w[2] = okR and Mass(hR) or 0
	end
	if w[1] == 0 and w[2] == 0 and tau[1] == 0 and tau[2] == 0 then return end

	local dt = RealFrameTime()
	if dt <= 0 then return end
	cvMax = cvMax or GetConVar("vrmod_pickup_weight")
	local max = cvMax and cvMax:GetFloat() or 35
	if max <= 0 then max = 35 end
	local lag, ramp = cvLag:GetFloat(), cvRamp:GetFloat()
	local k = 1 - exp(-dt * TAU_RATE)
	local org, oa = g_VR.origin, g_VR.originAngle -- live refs, read per frame

	for i = 1, 2 do
		local f = w[i] / max
		local c = tau[i]
		c = c + ((f < 1 and f ^ ramp or 1) * lag - c) * k
		if w[i] == 0 and c < 0.002 then c = 0 end
		tau[i] = c
		if c == 0 then
			live[i] = false
		else
			local pose = i == 1 and pL or pR
			local lp, la = WorldToLocal(pose.pos, pose.ang, org, oa)
			local P, F, U = sP[i], sF[i], sU[i]
			if live[i] then
				local a = 1 - exp(-dt / c)
				lp:Sub(P) lp:Mul(a) P:Add(lp)
				local v = la:Forward() v:Sub(F) v:Mul(a) F:Add(v)
				v = la:Up() v:Sub(U) v:Mul(a) U:Add(v)
				pose.pos, pose.ang = LocalToWorld(P, F:AngleEx(U), org, oa)
				-- Smoothed playspace velocity: heavy props throw as heavy
				lp:Div(dt) lp:Rotate(oa) pose.vel = lp
			else
				live[i] = true
				P:Set(lp) F:Set(la:Forward()) U:Set(la:Up())
			end
		end
	end
end)