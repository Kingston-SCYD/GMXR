-- lua/vrmod/input/cl_wheel.lua
-- Steering wheel, after The Simpsons: Hit & Run VR (openxr_shared_vehicle.cpp):
-- squeeze a grip on the rim to take hold, turn it, and the wheel's angle
-- steers. A held hand rides the rim, turning with the wheel.
--
-- The wheel is, in order: a per-model calibration (vrmod_wheel_calibrate),
-- the vehicle's own steering bone (vrmod.utils.GetSteeringInfo -- centre at
-- the bone, spin axis the bone axis pointing at the driver's eyes, or the
-- upright one for handlebars), else a virtual wheel in front of the driver,
-- drawn as a ring. Plain seats only ever get a calibrated one. Resolved once
-- per seat, kept in the vehicle's space. A hand in reach of the rim gets a
-- tick and blocks getting out (use/exit, standing up).
--
-- Cosmetic hands, for when the stick or a physical (force feedback) wheel
-- steers. Neither steers; both close the hand round the rim.
--   vrmod_wheel_autohands: a hand touching the rim, or anywhere in the
--   "plateau" under it (flat top at the wheel, widening as it drops and
--   reaching back past it), takes the playermodel's driving-animation hand
--   for that side; until the animation is measured, the rim at its own
--   angle, riding the wheel round as it turns with the steer actually sent.
--   vrmod_wheel_animhands: the same rim and plateau test, but only ever the
--   playermodel's own driving-animation hand (GMod's normal arms), from a
--   hidden copy of the model playing the player's sequence and
--   vehicle_steer; no rim fallback. Out of it, the hand is the controller's
--   again. Wins over the other.
-- The same model copy puts the head at the playermodel's eyes, once per
-- seat (vrmod.SetSeatEye, sh_locomotion): seat eye attachments are made
-- for a stock player, not this one.
--
-- While the wheel steers, a bone wheel's model turns with it: the steering
-- bone and everything under it are posed in the turning wheel's frame, the
-- same frame the held hands ride, so model and hands can't drift apart. The
-- vehicle's own animation turns it less (its steer range, not the wheel's
-- lock) and takes over again once the wheel is let go and centred.
--
-- Steer goes into vector2_steer.x at the source (cl_aimsteer's VRMOD_GetActions
-- wrapper calls vrmod.WheelSteer), so the HL2 sidemove and Glide's stream pick
-- it up unchanged. Hands are pinned in VRMod_Tracking, ahead of collisions,
-- the viewmodel, body IK and the network frame. Grip state is last frame's
-- (input is read after tracking): one frame on the grab, unnoticeable.
if SERVER then return end

local cvOn = CreateClientConVar("vrmod_wheel", "1", true, false, "Grab and turn a steering wheel to steer vehicles", 0, 1)
local cvVirt = CreateClientConVar("vrmod_wheel_virtual", "1", true, false, "Vehicles with no steering wheel bone get a virtual wheel", 0, 1)
local cvShow = CreateClientConVar("vrmod_wheel_show", "0", true, false, "Draw the wheel ring on real wheels too", 0, 1)
local cvR = CreateClientConVar("vrmod_wheel_radius", "7", true, false, "Steering wheel rim radius (units)", 3, 20)
local cvLock = CreateClientConVar("vrmod_wheel_lock", "120", true, false, "Wheel turn from centre to full lock (degrees)", 30, 450)
local cvBarR = CreateClientConVar("vrmod_wheel_bar_radius", "11", true, false, "Handlebar half-width (units)", 4, 24)
local cvBarLock = CreateClientConVar("vrmod_wheel_bar_lock", "40", true, false, "Handlebar turn from centre to full lock (degrees)", 10, 90)
local cvAuto = CreateClientConVar("vrmod_wheel_autohands", "0", true, false, "Hands touching or behind the wheel rest on it without gripping (physical wheels)", 0, 1)
local cvAnim = CreateClientConVar("vrmod_wheel_animhands", "0", true, false, "A hand at the wheel goes where the playermodel's driving animation puts it", 0, 1)
local cvDbg = CreateClientConVar("vrmod_debug_wheel", "0", false, false, "Print how each vehicle's wheel was found, and draw it", 0, 1)

local IsValid, LocalPlayer, RealTime, RealFrameTime = IsValid, LocalPlayer, RealTime, RealFrameTime
local LocalToWorld, WorldToLocal = LocalToWorld, WorldToLocal
local sin, cos, atan2, exp, rad, sqrt = math.sin, math.cos, math.atan2, math.exp, math.rad, math.sqrt
local PI, TAU = math.pi, math.pi * 2
local GRAB, RELEASE = 0.55, 0.42 -- squeeze to take hold / to let go
-- The plateau: a hand rests on the wheel up to the rim's top, down to DROP
-- below its centre, the sides and the reach behind (from BEHIND) widening
-- one unit per unit dropped
local BEHIND, DROP = 24, 60
local SIDE_TH = {-PI / 2, PI / 2} -- a resting hand near the hub: 9 and 3 o'clock
local STICK = 0.15 -- stick deflection that takes over from a centring wheel
local SEG = 32
local POSE = {"pose_lefthand", "pose_righthand"}
local SQ = {"vector1_left_squeeze", "vector1_right_squeeze"}
local PK = {"boolean_left_pickup", "boolean_right_pickup"}
local HELD = {"heldEntityLeft", "heldEntityRight"}
local FLAG = {"wheelGrippedLeft", "wheelGrippedRight"} -- read by cl_aimsteer
local SIDE = {"left", "right"}
local COL_RING, COL_CAL = Color(220, 220, 230, 200), Color(255, 190, 60, 230)

local seat = false -- ply:GetVehicle() the wheel was resolved for
local body, owner, retry, nextTry -- wheel's entity; calibration key entity; re-resolve window
local cL, nL, aL = Vector(), Vector(), Vector() -- centre, spin axis (toward the driver), 12 o'clock: body space
local C, N, A, B = Vector(), Vector(), Vector(), Vector() -- the same in world, this frame; B = A x N
local R, LOCK, drawn = 7, 2, false
local angle, steer, steering, grabbed, locked, spinning = 0, 0, false, false, false, false
local curl = {0, 0}
g_VR.wheelCurl = curl
local RIGHT_OFF = Angle(0, 0, 180) -- cl_character's right hand bone offset
local shadow, sBones, animT, animAt = nil, nil, nil, 0 -- model copy, its bones, model->seat, settle time
local shadowFrame, eyeDone = -1, false
local _U, _D = Vector(), Vector() -- vehicle up; the wheel's facing, level
local animP, animA = {}, {}
local hold = {{}, {}} -- per hand: on, base, acc, last, lp, la, zone, grace
local spin, spinEnt, spinCB -- {bone, pos, ang} in the unturned wheel frame; their entity; BuildBonePositions id
local calib, calT, calR = false, nil, 0
local CC, CN, CA, CB = Vector(), Vector(), Vector(), Vector()
local _rot, _pt = Vector(), Vector()

local on, show, virtOn, auto, animH
local function Refresh()
	on, show, virtOn, auto, animH = cvOn:GetBool(), cvShow:GetBool(), cvVirt:GetBool(), cvAuto:GetBool(), cvAnim:GetBool()
	seat = false -- re-resolve with the new settings
end
Refresh()
for _, n in ipairs({"vrmod_wheel", "vrmod_wheel_virtual", "vrmod_wheel_show", "vrmod_wheel_autohands", "vrmod_wheel_animhands", "vrmod_wheel_radius", "vrmod_wheel_lock", "vrmod_wheel_bar_radius", "vrmod_wheel_bar_lock"}) do
	cvars.AddChangeCallback(n, Refresh, "vrmod_wheel")
end

local function Say(msg) chat.AddText(COL_CAL, "[VRMod] ", color_white, msg) end
local function Dbg(fmt, ...) if cvDbg:GetBool() then print("[Wheel] " .. string.format(fmt, ...)) end end

-- Calibrations: [model] = {cx, cy, cz, nx, ny, nz, r}, body space
local FILE = "vrmod/wheels.json"
local cal
local function Cal()
	cal = cal or util.JSONToTable(file.Read(FILE, "DATA") or "") or {}
	return cal
end
local function SaveCal()
	file.CreateDir("vrmod")
	file.Write(FILE, util.TableToJSON(cal))
end

local function Release(i)
	local h = hold[i]
	if not h.on then return end
	-- the grip's own release lands a few frames on: kept off pickup/drop
	h.on, h.grace = false, RealTime() + 0.3
	g_VR[FLAG[i]] = nil
end

local function Unspin()
	if spinCB and IsValid(spinEnt) then spinEnt:RemoveCallback("BuildBonePositions", spinCB) end
	spin, spinEnt, spinCB = nil, nil, nil
end

local function Clear()
	Release(1)
	Release(2)
	Unspin()
	hold[1].zone, hold[2].zone, hold[1].w, hold[2].w, hold[1].lp, hold[2].lp = false, false, 0, 0, nil, nil
	curl[1], curl[2] = 0, 0
	body, owner, drawn, animT, animAt, eyeDone = nil, nil, false, nil, RealTime() + 0.6, false
	angle, steer, steering, grabbed, locked, spinning = 0, 0, false, false, false, false
end

-- 12 o'clock turned t clockwise, as the driver sees it
local function Turn(out, t)
	local c, s = cos(t), sin(t)
	out:SetUnpacked(A.x * c + B.x * s, A.y * c + B.y * s, A.z * c + B.z * s)
end

-- The wheel's frame at its current angle: forward the spin axis
local function Frame()
	Turn(_rot, angle)
	return N:AngleEx(_rot)
end

-- Animation hands. The copy plays at the world origin, so its bones are in
-- model space; model -> seat comes once from where the real pelvis sits in
-- the seat (the pelvis isn't touched by the arm IK), after settling in with
-- the car near still. World hands = seat * model->seat * copy's hands.
local function Shadow(ply, v, now)
	if shadowFrame == FrameNumber() then return animT ~= nil end
	local mdl = ply:GetModel()
	if not IsValid(shadow) or shadow:GetModel() ~= mdl then
		if IsValid(shadow) then shadow:Remove() end
		shadow = ClientsideModel(mdl, RENDERGROUP_OTHER)
		if not IsValid(shadow) then return false end
		shadow:SetNoDraw(true)
		sBones = {shadow:LookupBone("ValveBiped.Bip01_Pelvis"), shadow:LookupBone("ValveBiped.Bip01_L_Hand"), shadow:LookupBone("ValveBiped.Bip01_R_Hand")}
		animT = nil
	end
	if not (sBones[1] and sBones[2] and sBones[3]) then return false end
	shadowFrame = FrameNumber()
	shadow:SetModelScale(ply:GetModelScale(), 0)
	shadow:SetSequence(ply:GetSequence())
	shadow:SetCycle(ply:GetCycle())
	-- The client reads pose parameters 0..1 and sets them in range
	local pp = ply:LookupPoseParameter("vehicle_steer")
	if pp >= 0 then
		local lo, hi = ply:GetPoseParameterRange(pp)
		shadow:SetPoseParameter("vehicle_steer", lo + ply:GetPoseParameter("vehicle_steer") * (hi - lo))
	end
	shadow:InvalidateBoneCache()
	shadow:SetupBones()
	local pm = shadow:GetBoneMatrix(sBones[1])
	if not pm then return false end
	local vp, va = v:GetPos(), v:GetAngles()
	if not animT then
		if now < animAt or v:GetVelocity():LengthSqr() > 400 then return false end
		local rb = ply:LookupBone("ValveBiped.Bip01_Pelvis")
		local rm = rb and ply:GetBoneMatrix(rb)
		if not rm then return false end
		local lp, la = WorldToLocal(rm:GetTranslation(), rm:GetAngles(), vp, va)
		if lp:LengthSqr() > 10000 then return false end -- body not drawn yet: stale
		local op, oa = WorldToLocal(vector_origin, angle_zero, pm:GetTranslation(), pm:GetAngles())
		local tp, ta = LocalToWorld(op, oa, lp, la)
		animT = {tp, ta}
		Dbg("model copy: pelvis %.0fu from the seat", lp:Length())
	end
	return true
end

local function AnimHands(ply, v, now)
	if not Shadow(ply, v, now) then return false end
	local vp, va = v:GetPos(), v:GetAngles()
	for i = 1, 2 do
		local hm = shadow:GetBoneMatrix(sBones[i + 1])
		if not hm then return false end
		local p, a = LocalToWorld(hm:GetTranslation(), hm:GetAngles(), animT[1], animT[2])
		p, a = LocalToWorld(p, a, vp, va)
		if i == 2 then a = a - RIGHT_OFF end -- pose = bone angle less the offset
		animP[i], animA[i] = p, a
	end
	return true
end

-- The playermodel's eyes in the world, seated
local function SeatEye(ply, v, now)
	if not Shadow(ply, v, now) then return end
	local ai = shadow:LookupAttachment("eyes")
	local at = ai and ai > 0 and shadow:GetAttachment(ai)
	local p = at and at.Pos
	if not p then
		local hb = shadow:LookupBone("ValveBiped.Bip01_Head1")
		local m = hb and shadow:GetBoneMatrix(hb)
		if not m then return end
		p = m:GetTranslation()
		p.z = p.z + 3.5
	end
	p = LocalToWorld(p, angle_zero, animT[1], animT[2])
	return (LocalToWorld(p, angle_zero, v:GetPos(), v:GetAngles()))
end

-- World centre and spin axis onto e. 12 o'clock is the vehicle's up laid
-- in the wheel's plane (its forward for upright handlebars): only angle
-- changes steer, so any fixed reference does.
local function SetWheel(e, c, n, r, lock)
	local bp, ba = e:GetPos(), e:GetAngles()
	local a = ba:Up()
	a:Sub(n * a:Dot(n))
	if a:LengthSqr() < 0.09 then
		a = ba:Forward()
		a:Sub(n * a:Dot(n))
	end
	a:Normalize()
	cL:Set((WorldToLocal(c, angle_zero, bp, ba)))
	nL:Set((WorldToLocal(n, angle_zero, vector_origin, ba)))
	aL:Set((WorldToLocal(a, angle_zero, vector_origin, ba)))
	body, R, LOCK = e, r, rad(lock)
	return a
end

-- BuildBonePositions on the wheel's vehicle: the captured bones, re-posed
-- in the wheel frame turned to the wheel's angle (C/N/A/B are this frame's,
-- from the tracking hook ahead of the render)
local function Spin(e)
	if not spinning or e ~= body then return end
	local W = Frame()
	for k = 1, #spin do
		local s = spin[k]
		local m = e:GetBoneMatrix(s[1])
		if m then
			local p, a = LocalToWorld(s[2], s[3], C, W)
			m:SetTranslation(p)
			m:SetAngles(a)
			e:SetBoneMatrix(s[1], m)
		end
	end
end

local function Branch(e, id, out)
	out[#out + 1] = id
	local k = e:GetChildBones(id)
	if k then
		for j = 1, #k do Branch(e, k[j], out) end
	end
	return out
end

-- The steering bone and its children, as they sit now (the vehicle at rest
-- has its wheel centred), in the unturned wheel frame
local function Capture(e, bone, c, n, a)
	local W0, list = n:AngleEx(a), {}
	local ids = Branch(e, bone, {})
	for j = 1, #ids do
		local m = e:GetBoneMatrix(ids[j])
		if m then
			local p, q = WorldToLocal(m:GetTranslation(), m:GetAngles(), c, W0)
			list[#list + 1] = {ids[j], p, q}
		end
	end
	spin, spinEnt, spinCB = list, e, e:AddCallback("BuildBonePositions", Spin)
	return #list
end

local function Resolve(ply, v)
	Clear()
	seat, calib = v, false
	if not (on and IsValid(v)) then return end
	local hmd = g_VR.tracking.hmd
	if not hmd then return end
	local ent, bone, kind, glide, boneName = vrmod.utils.GetSteeringInfo(ply)
	if not IsValid(ent) or kind == "aircraft" then return end -- steer.x is roll there
	local p = v:GetParent()
	if glide then
		if ply.GlideGetSeatIndex and ply:GlideGetSeatIndex() ~= 1 then return end -- passenger
	elseif IsValid(p) then
		-- Glide's seat can land before its vehicle does: wait for it (retry)
		if p.VehicleType ~= nil then return end
		if p.GetDriverSeat and p:GetDriverSeat() ~= v then return end -- passenger
		if not bone then ent = p end
	end
	owner = ent
	local bars = kind == "motorcycle"
	local r, lock = (bars and cvBarR or cvR):GetFloat(), (bars and cvBarLock or cvLock):GetFloat()
	local mdl = ent:GetModel() or ""
	local k = Cal()[mdl]
	if k then
		local bp, ba = ent:GetPos(), ent:GetAngles()
		SetWheel(ent, LocalToWorld(Vector(k[1], k[2], k[3]), angle_zero, bp, ba), LocalToWorld(Vector(k[4], k[5], k[6]), angle_zero, vector_origin, ba), k[7], lock)
		Dbg("%s: calibrated, radius %.1f", mdl, k[7])
		return
	end
	local hp = hmd.pos
	-- The driver's eyes: the seat's attachment (locomotion seats the head
	-- there), else the head itself
	local eye, ai = hp, v:LookupAttachment("vehicle_driver_eyes")
	local at = ai and ai > 0 and v:GetAttachment(ai)
	if at then eye = at.Pos end
	if bone then
		ent:SetupBones()
		local m = ent:GetBoneMatrix(bone)
		local wc = m and m:GetTranslation()
		-- Out of arm's reach it's no steering wheel (a "steer" match on a
		-- road wheel's knuckle, say)
		local dist = wc and wc:Distance(eye) or -1
		if m and dist < 48 then
			local wa = m:GetAngles()
			local ref
			if bars then
				ref = ent:GetUp()
			else
				ref = eye - wc
				ref:Normalize()
			end
			-- The spin axis is one of the bone's own; which one varies per
			-- rig. Only one closely facing the eyes (upright for bars) is
			-- trusted: the old loose pick could land on an axis lying in the
			-- rim, turning the grab plane 90 degrees off the real wheel. A
			-- rig whose axes don't line up with the spin gets the eye line.
			local ax, best, bd = {wa:Forward(), wa:Right(), wa:Up()}, nil, 0.8
			for j = 1, 3 do
				local d = ax[j]:Dot(ref)
				local ad = d < 0 and -d or d
				if ad > bd then best, bd = d < 0 and -ax[j] or ax[j], ad end
			end
			local n = best or ref
			local nb = Capture(ent, bone, wc, n, SetWheel(ent, wc, n, r, lock))
			Dbg("%s: bone %s, %.0fu from the eyes, axis %s (dot %.2f), %d bones turned", mdl, tostring(boneName), dist, best and "from bone" or "eye line", best and bd or 1, nb)
			return
		end
		Dbg("%s: bone %s rejected (%.0fu from the eyes)", mdl, tostring(boneName), dist)
	end
	if not virtOn or not IsValid(p) and v:GetClass() == "prop_vehicle_prisoner_pod" then return end
	-- Virtual: SHAR's default place, scaled to metres. Seats face local +Y,
	-- Glide chassis +X.
	local mpu = g_VR.scale > 0 and g_VR.scale or 38.7
	local f = glide and ent:GetForward() or -v:GetRight()
	local up = ent:GetUp()
	f:Sub(up * f:Dot(up))
	f:Normalize()
	local tilt = bars and 0.3 or 0.5
	SetWheel(ent, hp + f * (0.45 * mpu) - up * ((bars and 0.35 or 0.3) * mpu), bars and up * cos(tilt) - f * sin(tilt) or up * sin(tilt) - f * cos(tilt), r, lock)
	drawn = true
	Dbg("%s: virtual", mdl)
end

-- Both hands on the rim, both grips held a second: centre between them,
-- radius half their spread, axis toward the head across that spread.
local function Calibrate(t, inp, now)
	local lp, rp, hmd = t.pose_lefthand, t.pose_righthand, t.hmd
	if not (lp and rp and hmd and IsValid(owner)) then calib = false return end
	lp, rp = lp.pos, rp.pos
	CC:SetUnpacked((lp.x + rp.x) * 0.5, (lp.y + rp.y) * 0.5, (lp.z + rp.z) * 0.5)
	CA:Set(rp)
	CA:Sub(lp)
	calR = CA:Length() * 0.5
	CA:Normalize()
	CN:Set(hmd.pos)
	CN:Sub(CC)
	CN:Sub(CA * CN:Dot(CA))
	CN:Normalize()
	CB:Set(CA:Cross(CN)) -- 12 o'clock, for the ring
	CA:Set(CB:Cross(CN))
	local l = inp and (tonumber(inp[SQ[1]]) or (inp[PK[1]] and 1 or 0)) or 0
	local r = inp and (tonumber(inp[SQ[2]]) or (inp[PK[2]] and 1 or 0)) or 0
	if l < GRAB or r < GRAB or g_VR.menuFocus or calR < 3 then
		calT = nil
		return
	end
	calT = calT or now
	if now - calT < 1 then return end
	local bp, ba = owner:GetPos(), owner:GetAngles()
	local c = WorldToLocal(CC, angle_zero, bp, ba)
	local n = WorldToLocal(CN, angle_zero, vector_origin, ba)
	local mdl = owner:GetModel()
	Cal()[mdl] = {c.x, c.y, c.z, n.x, n.y, n.z, calR}
	SaveCal()
	calib, seat = false, false -- re-resolve onto it
	if vrmod.Haptic then
		vrmod.Haptic("left", "click")
		vrmod.Haptic("right", "click")
	end
	Say(string.format("Wheel saved for %s (radius %.1f).", mdl, calR))
end

-- Per frame, split out of the tracking hook (Lua's 60-upvalue cap)
-- Seat changes and the once-per-seat head height
local function Seat(ply, v, now)
	if v ~= seat then
		Resolve(ply, v)
		retry, nextTry = IsValid(v) and now + 1, now + 0.1
	elseif not body and retry and now >= nextTry then
		if now < retry then
			Resolve(ply, v)
			nextTry = now + 0.1
		else
			retry = nil
		end
	end
	-- Head to the playermodel's eyes, once per seat; given up after 3s
	-- (the car never settled, or the body isn't drawn)
	if not eyeDone and IsValid(v) and now >= animAt and vrmod.SetSeatEye then
		local e = SeatEye(ply, v, now)
		if e and vrmod.SetSeatEye(e) then
			eyeDone = true
			Dbg("head set to the playermodel's eyes")
		elseif now > animAt + 3 then
			eyeDone = true
		end
	end
end

-- The wheel's angle and the steer it sends
local function Settle(dt, ring, animOK, sum, n, inp)
	if ring then
		-- The steer actually sent (last frame's, after aim steer) turns the
		-- wheel, through SHAR's response backwards; eased so a digital stick
		-- doesn't snap it
		local st = inp and inp.vector2_steer
		local sx = st and st.x or 0
		sx = sx > 1 and 1 or sx < -1 and -1 or sx
		local a = sx < 0 and -sx or sx
		a = a > 0 and (a * 0.98 + 0.02) ^ (1 / 1.15) or 0
		angle = angle + ((sx < 0 and -a or a) * LOCK - angle) * (1 - exp(-dt * 12))
		steer, steering, grabbed, locked = 0, false, false, false
	else
		if n > 0 then
			local tg = sum / n
			angle = angle + (tg - angle) * (1 - exp(-dt * 180))
			local was = locked
			locked = tg >= LOCK or tg <= -LOCK
			if locked and not was and vrmod.Haptic then
				for i = 1, 2 do
					if hold[i].on then vrmod.Haptic(SIDE[i], "tick") end
				end
			end
		else
			locked = false
			-- Let go, it centres itself
			if angle ~= 0 then
				angle = angle * exp(-dt * 10)
				if angle < 0.005 and angle > -0.005 then angle = 0 end
			end
		end
		-- SHAR's response: x^1.15 past a 2% deadzone
		local s = angle / LOCK
		local a = (s < 0 and -s or s) ^ 1.15
		a = a > 0.02 and (a - 0.02) / 0.98 or 0
		steer, steering, grabbed = s < 0 and -a or a, n > 0 or angle ~= 0, n > 0
	end
	-- The bone wheel turns with ours while we steer, or on the rim fallback;
	-- animation hands keep the vehicle's own turn, as their arms do
	spinning = steering or ring and not animOK

end

-- Pin held hands to the rim, ease cosmetic ones onto their targets
local function Pin(t, animOK, ring)
	local Wf
	for i = 1, 2 do
		local h, pose, k = hold[i], t[POSE[i]], 0
		if pose then
			if h.on then
				Wf = Wf or Frame()
				pose.pos, pose.ang = LocalToWorld(h.lp, h.la, C, Wf)
			elseif h.w > 0 then
				local tp, ta
				if animOK then
					tp, ta = animP[i], animA[i]
				elseif ring and h.lp then
					Wf = Wf or Frame()
					tp, ta = LocalToWorld(h.lp, h.la, C, Wf)
				end
				if tp then
					k = h.w
					pose.pos, pose.ang = LerpVector(k, pose.pos, tp), LerpAngle(k, pose.ang, ta)
				end
			end
		end
		-- Laid on the wheel, the hand closes round it (cl_vrmod's curl pass)
		curl[i] = k
	end
end

hook.Add("VRMod_Tracking", "vrmod_wheel", function()
	local ply, now = LocalPlayer(), RealTime()
	local v = ply:GetVehicle()
	Seat(ply, v, now)
	local t, inp = g_VR.tracking, g_VR.input
	if calib then return Calibrate(t, inp, now) end
	if not body then return end
	if not body:IsValid() then return Clear() end

	local bp, ba = body:GetPos(), body:GetAngles()
	C:Set(cL)
	C:Rotate(ba)
	C:Add(bp)
	N:Set(nL)
	N:Rotate(ba)
	A:Set(aL)
	A:Rotate(ba)
	B:SetUnpacked(A.y * N.z - A.z * N.y, A.z * N.x - A.x * N.z, A.x * N.y - A.y * N.x)

	local dt = RealFrameTime()
	-- Cosmetic hands: the stick or a physical wheel steers, the hands only show it
	local ring = auto and not animH
	local animOK = (animH or ring) and AnimHands(ply, v, now)
	if ring or animH then -- the plateau's axes
		_U:Set(ba:Up())
		_D:Set(_U)
		_D:Mul(-N:Dot(_U))
		_D:Add(N)
		_D:Normalize()
	end
	local sum, n, tol, kRest = 0, 0, R * 0.65, 1 - exp(-dt * 15)
	local tol2, atol2 = tol * tol, R * R * 0.81
	for i = 1, 2 do
		local pose, h = t[POSE[i]], hold[i]
		if pose then
			local p = pose.pos
			local dx, dy, dz = p.x - C.x, p.y - C.y, p.z - C.z
			local ax = dx * N.x + dy * N.y + dz * N.z
			local ca, cb = dx * A.x + dy * A.y + dz * A.z, dx * B.x + dy * B.y + dz * B.z
			local r = sqrt(ca * ca + cb * cb)
			local th, e, was = atan2(cb, ca), r - R, h.zone
			e, ax = e * e, ax * ax
			h.zone = e < tol2 and ax < atol2
			if h.zone and not (was or h.on) and vrmod.Haptic then vrmod.Haptic(SIDE[i], "tick") end
			if ring or animH then
				local w = h.w or 0
				local want = false
				-- Animation hands have nothing to show until it's measured
				if (ring or animOK) and not IsValid(g_VR[HELD[i]]) then
					want = h.zone
					if not want then
						-- the plateau: u up, b toward the driver, s across
						local u, b = dx * _U.x + dy * _U.y + dz * _U.z, dx * _D.x + dy * _D.y + dz * _D.z
						local down = u < 0 and -u or 0
						if u <= R and down <= DROP and b < R and b > -(BEHIND + down) then
							local s2, half = dx * dx + dy * dy + dz * dz - u * u - b * b, R + tol + down
							want = s2 < half * half
						end
					end
				end
				if want then
					if w == 0 and ring then
						-- On the rim at its own angle (9/3 near the hub), held in the
						-- turning wheel's frame so it rides the wheel round
						local rt = r > R * 0.3 and th or SIDE_TH[i]
						local c, s = cos(rt) * R, sin(rt) * R
						_pt:SetUnpacked(C.x + A.x * c + B.x * s, C.y + A.y * c + B.y * s, C.z + A.z * c + B.z * s)
						h.lp, h.la = WorldToLocal(_pt, pose.ang, C, Frame())
					end
					w = w + (1 - w) * kRest
				elseif w > 0 then
					w = w * (1 - kRest)
					if w < 0.01 then w = 0 end
				end
				h.w = w
			else
				h.w = 0
				local g = inp and (tonumber(inp[SQ[i]]) or (inp[PK[i]] and 1 or 0)) or 0
				if h.on then
					if g <= RELEASE or IsValid(g_VR[HELD[i]]) then
						Release(i)
					else
						-- Turn since the grab, unwrapped frame to frame (hand over
						-- hand past half a turn). Near the hub the angle is noise.
						if r > R * 0.3 then
							h.acc, h.last = h.acc + (th - h.last + PI) % TAU - PI, th
						end
						-- Past lock the hand slips on the rim: coming back turns at once
						local tg = h.base + h.acc
						if tg > LOCK then
							tg, h.acc = LOCK, LOCK - h.base
						elseif tg < -LOCK then
							tg, h.acc = -LOCK, -LOCK - h.base
						end
						sum, n = sum + tg, n + 1
					end
				elseif h.zone and g >= GRAB and not g_VR.menuFocus and not IsValid(g_VR[HELD[i]]) then
					-- The hand keeps the pose it took hold in, in the turning wheel's frame
					h.on, h.base, h.acc, h.last = true, angle, 0, th
					h.lp, h.la = WorldToLocal(p, pose.ang, C, Frame())
					g_VR[FLAG[i]] = true
					if vrmod.Haptic then vrmod.Haptic(SIDE[i], "grab") end
				end
			end
		end
	end

	Settle(dt, ring, animOK, sum, n, inp)
	Pin(t, animOK, ring)
end)

-- Called by cl_aimsteer's VRMOD_GetActions wrapper, after the deadzone
function vrmod.WheelSteer(inp)
	if not steering then return end
	local st = inp.vector2_steer
	if not st then
		st = {x = 0, y = 0}
		inp.vector2_steer = st
	end
	if not grabbed then
		local sx = st.x
		if sx > STICK or sx < -STICK then
			angle, steering = 0, false
			return
		end
	end
	st.x = steer
end

-- A hand in reach of the rim, or on it, or a calibration running
function vrmod.WheelBusy()
	return body ~= nil and (hold[1].on or hold[2].on or hold[1].zone or hold[2].zone) or calib
end

-- A grip on (or just off) the rim is the wheel's: no physics grab, and no
-- weapon drop on its release. Something already held still drops. Use/exit
-- don't get you out while a hand is at the wheel (vehiclevr's stand-up exit
-- asks WheelBusy too).
local PICK = {boolean_left_pickup = 1, boolean_right_pickup = 2}
local EXIT = {boolean_use = true, boolean_exit = true}
hook.Add("VRMod_AllowDefaultAction", "vrmod_wheel", function(action)
	if EXIT[action] then
		if vrmod.WheelBusy() then return false end
		return
	end
	local i = PICK[action]
	if not i or not (body or calib) then return end
	local h = hold[i]
	if (calib or h.on or h.zone or (h.w or 0) > 0 or RealTime() < (h.grace or 0)) and not IsValid(g_VR[HELD[i]]) then return false end
end)

local function Ring(c, a, b, r, t, col)
	render.SetColorMaterial()
	render.StartBeam(SEG + 1)
	for k = 0, SEG do
		local u = t + k * TAU / SEG
		local x, y = cos(u) * r, sin(u) * r
		_pt:SetUnpacked(c.x + a.x * x + b.x * y, c.y + a.y * x + b.y * y, c.z + a.z * x + b.z * y)
		render.AddBeam(_pt, 0.4, k / SEG, col)
	end
	render.EndBeam()
	-- 12 o'clock, turning with the wheel
	local x, y = cos(t) * r, sin(t) * r
	_pt:SetUnpacked(c.x + a.x * x + b.x * y, c.y + a.y * x + b.y * y, c.z + a.z * x + b.z * y)
	render.DrawBeam(c, _pt, 0.3, 0, 1, col)
end

hook.Add("PostDrawTranslucentRenderables", "vrmod_wheel_draw", function(depth, sky)
	-- Headset only: not into the spectator camera's view
	if depth or sky or not g_VR.active or g_VR.specCamRendering then return end
	if calib then
		if calR >= 3 then Ring(CC, CA, CB, calR, 0, COL_CAL) end
	elseif body and (drawn or show or cvDbg:GetBool()) then
		Ring(C, A, B, R, angle, COL_RING)
	end
end)

-- vrmod_wheel_calibrate: fit the wheel for this vehicle's model to your
-- hands. "reset" forgets it.
concommand.Add("vrmod_wheel_calibrate", function(_, _, args)
	local mdl = IsValid(owner) and owner:GetModel()
	if args[1] == "reset" then
		if mdl and Cal()[mdl] then
			cal[mdl] = nil
			SaveCal()
			seat = false
			Say("Wheel calibration for " .. mdl .. " removed.")
		else
			Say("This vehicle has no wheel calibration.")
		end
		return
	end
	if calib then
		calib, seat = false, false
		Say("Wheel calibration cancelled.")
		return
	end
	if not (g_VR.active and mdl) then
		Say("Sit in a driver's seat in VR first.")
		return
	end
	Release(1)
	Release(2)
	Unspin()
	curl[1], curl[2] = 0, 0
	body, calib, calT, calR, retry = nil, true, nil, 0, nil
	Say("Hold the rim at 9 and 3 o'clock and squeeze both grips for a second.")
end)

hook.Add("VRMod_Exit", "vrmod_wheel", function(ply)
	if ply ~= LocalPlayer() then return end
	Clear()
	if IsValid(shadow) then shadow:Remove() end
	seat, calib, retry = false, false, nil
end)