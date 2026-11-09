--[[
	cl_character_hik.lua -- Haï~'s cross-ik "FullTiger" solver as an alternative
	character IK (vrmod_characterik_solver 1).

	Copyright 2025 Haï~ (@vr_hai github.com/hai-vr)
	Licensed under the Apache License, Version 2.0 (the "License"); you may not
	use this file except in compliance with the License. You may obtain a copy
	at http://www.apache.org/licenses/LICENSE-2.0. Distributed on an "AS IS"
	BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND.

	Modified port for GMXR: HIKSpineSolver, HIKArmSolver, HIKLegSolver,
	HIKTwoBoneAlgorithms, MbusGeofunctions and MbusMathSolver re-expressed in
	Source space (right-handed, Z up) on native Angle/VMatrix types.

	IK frames: Forward runs to the next joint, Up is the solver's hint (spine:
	front, limbs: the way the elbow/knee points). Unity's humanoid
	post-rotations become per-bone rest offsets measured on the playermodel
	with the same rule the solver applies at runtime, so the reference pose
	reproduces exactly. Limb twist is anchored to the bone's hinge (local Z,
	the axis the classic solver bends around).

	arm_bend_lookup_table (21^3 floats, 262 KB) is exactly affine in its
	clamped input, so it ships as the 12 coefficients in LUT.

	Not ported (unused by GMXR's inputs): chest / lower-arm / lower-leg
	effectors, hand self-parenting, straddling, environmental grounding, fake
	double-jointed knees, debug draw.
]]
local HIK = {}
vrmod.hik = HIK

local _
local LocalToWorld, WorldToLocal, Vector, Matrix, LerpAngle, FrameNumber, RealFrameTime, sqrt = LocalToWorld, WorldToLocal, Vector, Matrix, LerpAngle, FrameNumber, RealFrameTime, math.sqrt
local V0, A0 = Vector(), Angle()
local FRONT = Vector(1, 0, 0)
local A_UPRIGHT = Vector(0, 0, 1):AngleEx(FRONT) -- upright pelvis/head; also HMD -> head IK
local A_FOOT = Vector(0, 0, -1):AngleEx(FRONT) -- foot IK: down the shin, toes forward
local ARM_PRIOR = Vector(-1, 0, -0.5) -- elbows point back/down
local S0, SD = 0.99, 0.05 -- HIKObjective.StruggleStart, End - Start
local ITER = 20 -- HIKSpineSolver.Iterations
local ARM_SHARE = 0.35 -- shoulders/elbows take this much of the anim blend
local HAND_HP = 2 -- hand swing high-pass (1/s): keeps the swing, drops the idle offset
local BLEND_LP = 15 -- anim blend low-pass (1/s): passes walk bob, kills frame jitter and sequence pops
-- Rows bx, by, bz of (x, y, z, 1) in lookup space (x out, y up, z front).
local L1, L2, L3, L4, L5, L6, L7, L8, L9, L10, L11, L12 = 0.448114, 0.083233, 0.075921, 0.161079, -0.032204, 0.520658, -0.006702, -0.057346, -0.183852, 0.095273, 0.506461, 0.020366
-- Reaching forward (aiming), the learned bend swings the elbow out to the
-- side -- chicken wing. Past ELBOW_FWD of forward reach (hand-direction dot
-- chest front) the bend pulls toward down (plus ELBOW_OUT of outward),
-- reaching ELBOW_DOWN of it at full forward reach.
local ELBOW_FWD, ELBOW_DOWN, ELBOW_OUT = 0.3, 0.85, 0.2

---------------------------------------------------------------------------
-- MATH
---------------------------------------------------------------------------
-- v minus its component along unit n, normalized. New vector.
local function PerpN(v, n)
	local r = n * -v:Dot(n)
	r:Add(v)
	r:Normalize()
	return r
end

-- HIKSpineSolver.SolveLerpVec: front, bent toward -up/+up as v leans front/back.
local function LerpVec(v, up, front)
	local d = v:Dot(front) / v:Length()
	local r
	if d >= 0 then
		r = front * (1 - d)
		r:Sub(up * d)
	else
		r = up * -d
		r:Add(front * (d + 1))
	end
	return r
end

-- MbusGeofunctions.ReprojectTwistToArm: rotate tw by the swing h -> a (unit).
local function Reproject(a, h, tw)
	if a:Dot(h) >= 0.9999 then return tw end
	local ax = a:Cross(h)
	local n = ax:Length()
	if n < 1e-6 then return tw end
	ax:Mul(1 / n)
	local ac, k2 = ax:Cross(a), tw:Dot(ax:Cross(h))
	ax:Mul(tw:Dot(ax))
	ac:Mul(k2)
	ax:Add(ac)
	return ax
end

-- HIKTwoBoneAlgorithms.ApplyCorrections: soft reach limit, hard fold limit.
local function Correct(len, u, l)
	local t = u + l
	if len >= t * S0 then
		local a = (len - t * S0) / (t * SD)
		a = a > 1 and 0 or 1 - a
		a = a * a
		return t * (S0 + (1 - S0) * (1 - a * a))
	end
	local mn = u > l and u - l or l - u
	return len < mn and mn or len
end

-- HIKTwoBoneAlgorithms.SolveBendPoint (law of cosines). d, b unit, b _|_ d.
local function Bend(root, d, len, u, l, b)
	local c = (len * len + u * u - l * l) / (2 * len * u)
	c = c > 1 and 1 or c < -1 and -1 or c
	local v = d * (c * u)
	v:Add(b * (sqrt(1 - c * c) * u))
	v:Add(root)
	return v
end

-- MbusMathSolver.ReachTowards on scalars (the FABRIK inner loop).
local function Reach(ox, oy, oz, px, py, pz, d)
	px, py, pz = px - ox, py - oy, pz - oz
	local l = sqrt(px * px + py * py + pz * pz)
	if l < 1e-6 then return ox, oy, oz + d end
	l = d / l
	return ox + px * l, oy + py * l, oz + pz * l
end

-- Elbow/knee "outside" in the reference pose: +-bone Right (hinge = local Z).
-- Sign from the pose's own bend when clear (~10 deg), else the prior.
local function Hinge(ang, root, mid, tip, prior)
	local r = ang:Right()
	local ud = (mid - root):GetNormalized()
	local fold = tip - mid
	local lim = fold:Length() * 0.17
	fold:Sub(ud * fold:Dot(ud))
	local s = fold:Dot(r)
	if s > lim or s >= -lim and r:Dot(prior) < 0 then r:Mul(-1) end
	return r
end

---------------------------------------------------------------------------
-- DEFINITION (HIKFullTiger.SolveDefinitionFromAnimator)
---------------------------------------------------------------------------
local BODY = {"Pelvis", "Spine", "Spine1", "Spine2", "Spine4", "Neck1", "Head1", "L_Thigh", "L_Calf", "L_Foot", "R_Thigh", "R_Calf", "R_Foot"}
local ARM = {"Clavicle", "UpperArm", "Forearm", "Hand", "Wrist", "Ulna"}

-- cm: ClientsideModel of the playermodel, Angle(0,0,0), after SetupBones.
-- Returns the definition, or nil + the missing bone.
function HIK.Build(cm)
	local id, p, a = {}, {}, {}
	local function get(n)
		local b = cm:LookupBone("ValveBiped.Bip01_" .. n)
		local m = b and cm:GetBoneMatrix(b)
		if not m then return end
		id[n], p[n], a[n] = b, m:GetTranslation(), m:GetAngles()
		return true
	end
	for i = 1, #BODY do
		if not get(BODY[i]) then return nil, BODY[i] end
	end
	for _, s in ipairs({"L_", "R_"}) do
		for i = 1, 6 do
			if not get(s .. ARM[i]) and i < 5 then return nil, s .. ARM[i] end
		end
		if cm:GetBoneParent(id[s .. "Clavicle"]) ~= id.Spine4 then return nil, "Spine4 (clavicle parent)" end
	end

	local hip, sp, ch, nk, hd = p.Pelvis, p.Spine, p.Spine2, p.Neck1, p.Head1
	local h = {
		pelvis = id.Pelvis, spine = id.Spine, spine1 = id.Spine1, spine2 = id.Spine2, spine4 = id.Spine4, neck = id.Neck1, head = id.Head1,
		ids = {}, tm = {}, D = {}, pb = {}, ps = {}, pc = {}, pv = {}, leg = {}, arm = {}, hl = Vector(),
	}
	-- Spine chain. Spine1 rides Spine, Spine4 rides Spine2 (rest-rigid), so
	-- the FABRIK nodes are Spine, Spine2 (chest), Neck1, Head1.
	_, h.pelvisInv = WorldToLocal(V0, A_UPRIGHT, V0, a.Pelvis)
	h.spineRel = WorldToLocal(sp, A0, hip, a.Pelvis)
	local v = ch - sp
	_, h.spineOff = WorldToLocal(V0, a.Spine, V0, v:AngleEx(LerpVec(v, A_UPRIGHT:Forward(), FRONT)))
	h.s1P, h.s1A = WorldToLocal(p.Spine1, a.Spine1, sp, a.Spine)
	h.chestRel = WorldToLocal(ch, A0, sp, a.Spine)
	local chIK = (nk - ch):AngleEx(LerpVec(hd - hip, A_UPRIGHT:Forward(), FRONT))
	_, h.chestOff = WorldToLocal(V0, a.Spine2, V0, chIK)
	_, h.chestInv = WorldToLocal(V0, chIK, V0, a.Spine2)
	h.s4P, h.s4A = WorldToLocal(p.Spine4, a.Spine4, ch, a.Spine2)
	h.neckRel = WorldToLocal(nk, A0, ch, a.Spine2)
	_, h.neckOff = WorldToLocal(V0, a.Neck1, V0, (hd - nk):AngleEx(FRONT))
	h.headRel = WorldToLocal(hd, A0, nk, a.Neck1)
	_, h.headOff = WorldToLocal(V0, a.Head1, V0, A_UPRIGHT)
	local ea = cm:LookupAttachment("eyes")
	local e = ea and ea > 0 and cm:GetAttachment(ea)
	h.eyeUp = e and math.Clamp(e.Pos.z - hd.z, 0, 10) or 3.5
	-- Standing eye height (eye height calibration maps onto it) and the rest
	-- head in entity space (the neutral the anim blend measures against).
	local org = cm:GetPos()
	h.eyeZ = hd.z + h.eyeUp - org.z
	h.headRestP, h.headRestA = hd - org, a.Head1
	h.sHp, h.sHa = Vector(), Angle()

	local hipToNeck, neckLen = hip:Distance(nk), nk:Distance(hd)
	h.d1, h.d2, h.d3 = sp:Distance(ch), ch:Distance(nk), neckLen
	h.hipToHead, h.maxLen = hip:Distance(hd), hipToNeck + neckLen
	h.ffK = (hipToNeck + neckLen * 0.75) / h.hipToHead
	-- Spine curvature, encoded against the upright rest hip/head frame.
	local s2h = hd - sp
	local s2hLen = s2h:Length()
	s2h:Mul(1 / s2hLen)
	local cr, toC, toN = PerpN(FRONT, s2h), ch - sp, nk - sp
	h.rsvX, h.rsvY = s2h.z, s2h.x
	h.crX, h.crY, h.nrX, h.nrY = s2h:Dot(toC) / s2hLen, cr:Dot(toC), s2h:Dot(toN) / s2hLen, cr:Dot(toN)
	h.maxDrop = (hip.z - cm:GetPos().z) * 0.6

	for si, s in ipairs({"L_", "R_"}) do
		-- Leg (HIKLegSolver)
		local T, K, F = p[s .. "Thigh"], p[s .. "Calf"], p[s .. "Foot"]
		local tA, kA = a[s .. "Thigh"], a[s .. "Calf"]
		local L = {thigh = id[s .. "Thigh"], calf = id[s .. "Calf"], foot = id[s .. "Foot"], u = T:Distance(K), l = K:Distance(F)}
		L.thighRel = WorldToLocal(T, A0, hip, a.Pelvis)
		L.calfRel = WorldToLocal(K, A0, T, tA)
		L.footRel = WorldToLocal(F, A0, K, kA)
		_, L.footInv = WorldToLocal(V0, A_FOOT, V0, a[s .. "Foot"])
		local bend = PerpN(Hinge(tA, T, K, F, FRONT), (F - T):GetNormalized())
		_, L.thighOff = WorldToLocal(V0, tA, V0, (K - T):AngleEx(bend))
		v = F - K
		local tw = Reproject(v:GetNormalized(), A_FOOT:Forward(), A_FOOT:Up())
		tw:Add(bend)
		_, L.calfOff = WorldToLocal(V0, kA, V0, v:AngleEx(tw))
		h.leg[si] = L

		-- Arm (HIKArmSolver)
		local C, U, E, H = p[s .. "Clavicle"], p[s .. "UpperArm"], p[s .. "Forearm"], p[s .. "Hand"]
		local cA, uA, hA = a[s .. "Clavicle"], a[s .. "UpperArm"], a[s .. "Hand"]
		local R = {side = si == 1 and -1 or 1, sh = C:Distance(U), u = U:Distance(E), l = E:Distance(H), tw = Vector(),
			clavB = id[s .. "Clavicle"], upperB = id[s .. "UpperArm"], foreB = id[s .. "Forearm"], handB = id[s .. "Hand"],
			hd = Vector(), avg = Vector(), hs = Vector(), eb = Vector()}
		R.clavP, R.clavA = WorldToLocal(C, cA, p.Spine4, a.Spine4)
		R.upperRel = WorldToLocal(U, A0, C, cA)
		bend = PerpN(Hinge(uA, U, E, H, ARM_PRIOR), (H - U):GetNormalized())
		_, R.upperOff = WorldToLocal(V0, uA, V0, (E - U):AngleEx(bend))
		-- Twist reference lives in hand space and equals the elbow direction
		-- at rest, so forearm half-twist is pure pronation from rest.
		local hf = hA:Forward()
		tw = PerpN(bend, hf)
		R.twL = WorldToLocal(tw, A0, V0, hA)
		v = H - E
		local fn = v:GetNormalized()
		local full, nt = Reproject(fn, hf, tw), PerpN(bend, fn)
		local half = nt + full
		if p[s .. "Wrist"] and p[s .. "Ulna"] then
			R.wrist = true
			_, R.foreOff = WorldToLocal(V0, a[s .. "Forearm"], V0, v:AngleEx(nt))
			_, R.wristOff = WorldToLocal(V0, a[s .. "Wrist"], V0, v:AngleEx(full))
			_, R.ulnaOff = WorldToLocal(V0, a[s .. "Ulna"], V0, v:AngleEx(half))
		else
			_, R.foreOff = WorldToLocal(V0, a[s .. "Forearm"], V0, v:AngleEx(half))
		end
		h.arm[si] = R
	end

	-- Written bones + every non-arm descendant (hair, jiggle, toes, cloth),
	-- which keeps its animated pose relative to its nearest written ancestor.
	local src, arm = {}, {[id.L_Clavicle] = true, [id.R_Clavicle] = true}
	for i = 1, #BODY do
		local b = id[BODY[i]]
		h.ids[i], src[b], h.tm[b], h.D[b] = b, b, Matrix(), Matrix()
	end
	for i = 0, cm:GetBoneCount() - 1 do
		local par = cm:GetBoneParent(i)
		if par >= 0 and not src[i] and not arm[i] then
			if arm[par] then
				arm[i] = true
			elseif src[par] then
				local n = #h.pb + 1
				src[i], h.pb[n], h.ps[n], h.pc[n] = src[par], i, src[par], Matrix()
			end
		end
	end
	return h
end

---------------------------------------------------------------------------
-- SOLVE (inside BuildBonePositions)
---------------------------------------------------------------------------
-- Writes a bone and keeps New * Anim^-1 for its descendants. anim is read
-- before SetBoneMatrix, which would otherwise hand back the new matrix.
local function Put(ply, h, b, pos, ang, anim)
	local tm, D = h.tm[b], h.D[b]
	anim = anim or ply:GetBoneMatrix(b)
	tm:SetTranslation(pos)
	tm:SetAngles(ang)
	ply:SetBoneMatrix(b, tm)
	if anim then
		anim:InvertTR()
		D:Set(tm)
		D:Mul(anim)
	else
		D:Identity()
	end
end

-- tp / ta: a target foot position and angle from the caller (planted, stepping
-- feet); otherwise the animated foot pushed by comp.
local function SolveLeg(ply, h, L, hip, pAng, mF, comp, tp, ta)
	local root = LocalToWorld(L.thighRel, A0, hip, pAng)
	local obj, fAng
	if tp then
		obj, fAng = Vector(tp), ta
	else
		obj, fAng = mF:GetTranslation(), mF:GetAngles()
		obj:Add(comp)
	end
	local _, fIK = LocalToWorld(V0, L.footInv, V0, fAng)
	local fFw, fUp = fIK:Forward(), fIK:Up()
	local d = obj - root
	local len = d:Length()
	if len < 1e-3 then d, len = fFw * 1e-3, 1e-3 end
	d:Mul(1 / len)
	local u, l = L.u, L.l
	len = Correct(len, u, l)
	-- Knee toward the toes and up, off the hip-foot line.
	local bend = fUp - fFw
	bend = PerpN(bend, d)
	if bend:IsZero() then bend = PerpN(fUp, d) end
	local knee = Bend(root, d, len, u, l, bend)
	local _, tA = LocalToWorld(V0, L.thighOff, V0, (knee - root):AngleEx(bend))
	obj = d * len
	obj:Add(root)
	obj:Sub(knee)
	local tw = Reproject(obj:GetNormalized(), fFw, fUp)
	tw:Add(bend)
	local _, cA = LocalToWorld(V0, L.calfOff, V0, obj:AngleEx(tw))
	local cPos = LocalToWorld(L.calfRel, A0, root, tA)
	Put(ply, h, L.thigh, root, tA)
	Put(ply, h, L.calf, cPos, cA)
	Put(ply, h, L.foot, LocalToWorld(L.footRel, A0, cPos, cA), fAng, mF)
end

-- aw > 0: the shoulder and elbow direction follow the animation that much
-- (aS4: animated Spine4 angles, read before body mode overwrote it).
-- hw > 0: the hand target takes that much of the animated hand's swing in
-- body space (eP/eA: render origin), band-passed (HAND_HP high, BLEND_LP
-- low). R.hd keeps the world offset for the early weapon passes.
-- q: low-pass step for the shoulder/elbow filters this call (0 = already
-- stepped this frame, reuse; 1 = snap). Anim bones are read only when q > 0.
local function SolveArm(ply, R, s4Pos, s4Ang, up, front, left, tgt, hAng, stretch, aw, aS4, hw, eP, eA, q)
	local side = R.side
	local hd, hs = R.hd, R.hs
	hd:SetUnpacked(0, 0, 0)
	if hw > 0 then
		local fn, last = FrameNumber(), R.avgF
		if fn ~= last then -- once per frame across stereo/spec passes
			local m = ply:GetBoneMatrix(R.handB)
			if m then
				local lp, avg = WorldToLocal(m:GetTranslation(), A0, eP, eA), R.avg
				if not last or fn - last > 2 then
					avg:Set(lp)
					hs:SetUnpacked(0, 0, 0)
				else
					local dt = RealFrameTime()
					local k = dt * HAND_HP
					k = k < 1 and k or 1
					hd:Set(lp)
					hd:Mul(k)
					avg:Mul(1 - k)
					avg:Add(hd)
					k = dt * BLEND_LP
					k = k < 1 and k or 1
					lp:Sub(avg)
					lp:Mul(k)
					hs:Mul(1 - k)
					hs:Add(lp)
				end
				R.avgF = fn
			end
		end
		hd:Set(hs)
		hd:Mul(hw)
		hd:Rotate(eA)
		tgt = tgt + hd
	end
	local cA = R.clavA
	if aw > 0 then
		if q > 0 then
			local m = ply:GetBoneMatrix(R.clavB)
			if m then
				local _, la = WorldToLocal(V0, m:GetAngles(), V0, aS4)
				R.sCa = R.sCa and q < 1 and LerpAngle(q, R.sCa, la) or la
			end
		end
		if R.sCa then cA = LerpAngle(aw, R.clavA, R.sCa) end
	end
	local cPos, cAng = LocalToWorld(R.clavP, cA, s4Pos, s4Ang)
	local root = LocalToWorld(R.upperRel, A0, cPos, cAng)
	local u, l, sc = R.u, R.l, 1
	local t = u + l
	local d = tgt - root
	local len = d:Length()
	if len < 1e-3 then d, len = up * -1e-3, 1e-3 end
	if stretch and len > t * 0.98 then
		sc = len / (t * 0.98)
		u, l, t = u * sc, l * sc, t * sc
	end
	local out = left * -side
	-- Shoulder: swing forward/inward and shrug as the reach extends.
	local ext = (len / t - 0.7) / (0.3 + R.sh / t)
	if ext > 0 then
		if ext > 1 then ext = 1 end
		local il = ext / len
		local fw, inw, uw = d:Dot(front) * il, -d:Dot(out) * il, d:Dot(up) * il
		fw = fw > 0 and fw or 0
		inw = inw > 0 and inw or 0
		fw = ext - (ext - fw) * (ext - inw) / ext
		if uw > 0 then cAng:RotateAroundAxis(front, -side * 60 * uw) end
		if fw > 0 then cAng:RotateAroundAxis(up, side * 60 * fw) end
		if uw > 0 or fw > 0 then
			root = LocalToWorld(R.upperRel, A0, cPos, cAng)
			d = tgt - root
			len = d:Length()
		end
	end
	d:Mul(1 / len)
	len = Correct(len, u, l)
	-- Elbow: Haï~'s trained bend (affine LUT) in chest space, clamped to +-1.
	local k = len / t
	local x, y, z = d:Dot(out) * k, d:Dot(up) * k, d:Dot(front) * k
	x = x > 1 and 1 or x < -1 and -1 or x
	y = y > 1 and 1 or y < -1 and -1 or y
	z = z > 1 and 1 or z < -1 and -1 or z
	local bend = out * (L1 * x + L2 * y + L3 * z + L4)
	bend:Add(up * (L5 * x + L6 * y + L7 * z + L8))
	bend:Add(front * (L9 * x + L10 * y + L11 * z + L12))
	if aw > 0 then
		-- Animated elbow direction off its own shoulder-hand line, filtered
		-- in body space.
		local eb = R.eb
		if q > 0 then
			local mu, mf, mh = ply:GetBoneMatrix(R.upperB), ply:GetBoneMatrix(R.foreB), ply:GetBoneMatrix(R.handB)
			if mu and mf and mh then
				local o = mu:GetTranslation()
				local e, w = mf:GetTranslation(), mh:GetTranslation()
				e:Sub(o)
				w:Sub(o)
				w:Normalize()
				e = PerpN(e, w)
				if not e:IsZero() then
					e = WorldToLocal(e, A0, V0, eA)
					if R.ebOK and q < 1 then
						e:Sub(eb)
						e:Mul(q)
						eb:Add(e)
					else
						eb:Set(e)
						R.ebOK = true
					end
				end
			end
		end
		if R.ebOK then
			local e = eb * aw
			e:Rotate(eA)
			bend:Normalize()
			bend:Mul(1 - aw)
			bend:Add(e)
		end
	end
	local fw = (d:Dot(front) - ELBOW_FWD) / (1 - ELBOW_FWD)
	if fw > 0 then
		fw = (fw < 1 and fw or 1) * ELBOW_DOWN
		local dn = out * ELBOW_OUT
		dn:Sub(up)
		dn:Normalize()
		bend:Normalize()
		bend:Mul(1 - fw)
		dn:Mul(fw)
		bend:Add(dn)
	end
	bend = PerpN(bend, d)
	if bend:IsZero() then bend = PerpN(up * -1, d) end
	local elbow = Bend(root, d, len, u, l, bend)
	local _, uA = LocalToWorld(V0, R.upperOff, V0, (elbow - root):AngleEx(bend))
	local f = d * len
	f:Add(root)
	f:Sub(elbow)
	local fn = f:GetNormalized()
	local tw = R.tw
	tw:Set(R.twL)
	tw:Rotate(hAng)
	local full, nt = Reproject(fn, hAng:Forward(), tw), PerpN(bend, fn)
	if R.wrist then
		_, R.fore = LocalToWorld(V0, R.foreOff, V0, f:AngleEx(nt))
		_, R.wristA = LocalToWorld(V0, R.wristOff, V0, f:AngleEx(full))
		nt:Add(full)
		_, R.ulnaA = LocalToWorld(V0, R.ulnaOff, V0, f:AngleEx(nt))
	else
		nt:Add(full)
		_, R.fore = LocalToWorld(V0, R.foreOff, V0, f:AngleEx(nt))
	end
	R.clavPos, R.clav, R.upper, R.hand, R.stretch, R.handPos = cPos, cAng, uA, hAng, sc, tgt
end

-- body: solve spine + head + legs (else arms only, on the animated torso).
-- comp: the shift PrePlayerDraw gave the model; feet are planted against it.
-- lift: added to the head target height (model eye height - calibrated eye
-- height). blend: 0..1 of the animation's head motion layered on the HMD;
-- shoulders/elbows take ARM_SHARE of it. hand: 0..1 of the animated hands'
-- swing (the caller zeroes it for the local player's own eyes). Every blend
-- input is low-passed (BLEND_LP) in body space.
-- Results: h.arm[1|2] (left|right) for the classic arm pass. False if a
-- needed bone matrix was missing.
-- twist: torso yaw minus hip yaw (deg), lean: sideways chest lean (deg,
-- + = right). hoff: optional world offset for the head target (the local
-- player's look-down view clearance; the body is moved by the same).
-- feet: optional {pos1, ang1, pos2, ang2} foot targets (left, right) that
-- replace the animated feet + comp. hipP / hipA: optional pelvis bone
-- position and angle replacing the animated pelvis (FBT's waist tracker). Body mode turns the spine / chest frames by them -- the
-- lower spine a fifth of the twist and a quarter of the lean, the chest the
-- rest -- before the FK and the head realign, so the arms solve off the
-- turned chest and the head still lands on the HMD.
function HIK.Solve(ply, h, frame, body, comp, hmdDist, stretch, lAng, rAng, lift, blend, hand, twist, lean, hoff, feet, hipP, hipA)
	twist, lean = twist or 0, lean or 0
	local s4Pos, s4Ang, chestIK, aS4, eP, eA
	local aw, q = blend * ARM_SHARE, 0
	if blend > 0 or hand > 0 then eP, eA = ply:GetPos(), ply:GetRenderAngles() end
	if blend > 0 then
		-- One low-pass step per frame; stereo/spec passes reuse it.
		local fn, last = FrameNumber(), h.lpF
		if not last or fn - last > 2 then
			q = 1
		elseif fn ~= last then
			q = RealFrameTime() * BLEND_LP
			q = q < 1 and q or 1
		end
		h.lpF = fn
	end
	if body then
		local mP, mL, mR = ply:GetBoneMatrix(h.pelvis), ply:GetBoneMatrix(h.leg[1].foot), ply:GetBoneMatrix(h.leg[2].foot)
		if not (mP and mL and mR) then return false end
		local mH = q > 0 and ply:GetBoneMatrix(h.head)
		if aw > 0 and q > 0 then
			local m = ply:GetBoneMatrix(h.spine4)
			aS4 = m and m:GetAngles()
			if not aS4 then aw = 0 end
		end
		local hip, pAng = hipP or mP:GetTranslation(), hipA or mP:GetAngles()
		local _, hipIK = LocalToWorld(V0, h.pelvisInv, V0, pAng)
		local _, headIK = LocalToWorld(V0, A_UPRIGHT, V0, frame.hmdAng)
		local hUp, hFr, eUp, eFr = hipIK:Forward(), hipIK:Up(), headIK:Forward(), headIK:Up()
		-- Weapon stances turn the pelvis off the body's facing (legs back,
		-- hips square to the gun) while the animated chest stays forward. The
		-- spine frames are built off the hips, so take that turn back out of
		-- them: all of it in the chest, half in the lower spine.
		local pf = WorldToLocal(hFr, A0, V0, ply:GetRenderAngles())
		local pd = math.deg(math.atan2(pf.y, pf.x))
		twist = twist - pd
		local hl = h.hl
		hl:SetUnpacked(-h.eyeUp, 0, -hmdDist)
		local head = LocalToWorld(hl, A0, frame.hmdPos, headIK)
		head.z = head.z + lift
		if hoff then head:Add(hoff) end
		-- Anim blend: the animated head's offset from the rest head placed at
		-- the render origin (walk bob, sway, idle posture; crouch excluded,
		-- that's the HMD's), added on top of the tracked head.
		local hD
		if blend > 0 then
			local sp = h.sHp
			if mH then
				local lp, la = WorldToLocal(mH:GetTranslation(), mH:GetAngles(), eP, eA)
				lp:Sub(h.headRestP)
				local _, da = WorldToLocal(V0, la, V0, h.headRestA)
				if q < 1 then
					lp:Sub(sp)
					lp:Mul(q)
					sp:Add(lp)
					h.sHa = LerpAngle(q, h.sHa, da)
				else
					sp:Set(lp)
					h.sHa = da
				end
			end
			local o = sp * blend
			o:Rotate(eA)
			head:Add(o)
			hD = h.sHa * blend
		end

		-- Hip corrections, head alignment mattering most.
		local hh = hip - head
		local dist, mx = hh:Length(), h.maxLen
		if dist < 1e-4 then return false end
		local ff = (0.01 + (h.ffK - 0.01) * (eUp:Dot(hUp) * 0.5 + 0.5)) * h.hipToHead
		if dist < ff then
			hh:Mul(ff / dist)
			dist = ff
		end
		if dist > mx then
			hh:Mul(mx / dist)
			dist = mx
		end
		-- Buckling: tension along the hips' up axis straightens the spine.
		local k = (hh:Dot(hUp) / dist * (h.rsvX >= 0 and -1 or 1) - 0.96) * 25
		if k > 0 then
			k = k > 1 and 1 or k
			hh:Mul(1 + (mx - dist) * k * k * (3 - 2 * k) / dist)
		end
		hip = head + hh

		-- Prime the chain and relax it with FABRIK (scalars, no allocations).
		local spine = LocalToWorld(h.spineRel, A0, hip, pAng)
		local sx, sy, sz = spine:Unpack()
		local tx, ty, tz = head:Unpack()
		local ku = h.rsvX * spine:Distance(head)
		local a, b = ku * h.crX, h.rsvY * h.crY
		local ux, uy, uz = hUp:Unpack()
		local fx, fy, fz = hFr:Unpack()
		local x1, y1, z1 = sx + ux * a + fx * b, sy + uy * a + fy * b, sz + uz * a + fz * b
		a, b = ku * (1 - h.nrX), h.rsvY * h.nrY
		ux, uy, uz = eUp:Unpack()
		fx, fy, fz = eFr:Unpack()
		local x2, y2, z2 = tx - ux * a + fx * b, ty - uy * a + fy * b, tz - uz * a + fz * b
		local x3, y3, z3
		local d1, d2, d3 = h.d1, h.d2, h.d3
		for _ = 1, ITER do
			x2, y2, z2 = Reach(tx, ty, tz, x2, y2, z2, d3)
			x1, y1, z1 = Reach(x2, y2, z2, x1, y1, z1, d2)
			x1, y1, z1 = Reach(sx, sy, sz, x1, y1, z1, d1)
			x2, y2, z2 = Reach(x1, y1, z1, x2, y2, z2, d2)
			x3, y3, z3 = Reach(x2, y2, z2, tx, ty, tz, d3)
		end

		-- Rotations from the chain, positions by FK from the rest offsets.
		local v = Vector(x1 - sx, y1 - sy, z1 - sz)
		local sA = v:AngleEx(LerpVec(v, hUp, hFr))
		if twist ~= 0 then sA:RotateAroundAxis(sA:Forward(), twist * 0.2 - pd * 0.3) end
		if lean ~= 0 then sA:RotateAroundAxis(sA:Up(), lean * 0.25) end
		local _, spA = LocalToWorld(V0, h.spineOff, V0, sA)
		local s1Pos, s1A = LocalToWorld(h.s1P, h.s1A, spine, spA)
		local cPos = LocalToWorld(h.chestRel, A0, spine, spA)
		hh:Mul(-1)
		v:SetUnpacked(x2 - x1, y2 - y1, z2 - z1)
		chestIK = v:AngleEx(LerpVec(hh, hUp, hFr))
		if twist ~= 0 then chestIK:RotateAroundAxis(chestIK:Forward(), twist * 0.8 - pd * 0.2) end
		if lean ~= 0 then chestIK:RotateAroundAxis(chestIK:Up(), lean * 0.75) end
		local _, cA = LocalToWorld(V0, h.chestOff, V0, chestIK)
		s4Pos, s4Ang = LocalToWorld(h.s4P, h.s4A, cPos, cA)
		local nPos = LocalToWorld(h.neckRel, A0, cPos, cA)
		v:SetUnpacked(x3 - x2, y3 - y2, z3 - z2)
		local _, nA = LocalToWorld(V0, h.neckOff, V0, v:AngleEx(eFr))
		local _, hA = LocalToWorld(V0, h.headOff, V0, headIK)
		if hD then _, hA = LocalToWorld(V0, hD, V0, hA) end
		-- Realign: shift the whole chain so the head lands on its target.
		v = head - LocalToWorld(h.headRel, A0, nPos, nA)
		hip:Add(v)
		spine:Add(v)
		s1Pos:Add(v)
		cPos:Add(v)
		s4Pos:Add(v)
		nPos:Add(v)
		Put(ply, h, h.pelvis, hip, pAng, mP)
		Put(ply, h, h.spine, spine, spA)
		Put(ply, h, h.spine1, s1Pos, s1A)
		Put(ply, h, h.spine2, cPos, cA)
		Put(ply, h, h.spine4, s4Pos, s4Ang)
		Put(ply, h, h.neck, nPos, nA)
		Put(ply, h, h.head, head, hA, mH or nil)
		if feet then
			SolveLeg(ply, h, h.leg[1], hip, pAng, mL, comp, feet[1], feet[2])
			SolveLeg(ply, h, h.leg[2], hip, pAng, mR, comp, feet[3], feet[4])
		else
			SolveLeg(ply, h, h.leg[1], hip, pAng, mL, comp)
			SolveLeg(ply, h, h.leg[2], hip, pAng, mR, comp)
		end

		local pb, ps, pc, pv, D = h.pb, h.ps, h.pc, h.pv, h.D
		for i = 1, #pb do
			local m = ply:GetBoneMatrix(pb[i])
			pv[i] = m ~= nil
			if m then
				local c = pc[i]
				c:Set(D[ps[i]])
				c:Mul(m)
				ply:SetBoneMatrix(pb[i], c)
			end
		end
	else
		local m4, m2 = ply:GetBoneMatrix(h.spine4), ply:GetBoneMatrix(h.spine2)
		if not (m4 and m2) then return false end
		s4Pos, s4Ang = m4:GetTranslation(), m4:GetAngles()
		aS4 = q > 0 and s4Ang
		_, chestIK = LocalToWorld(V0, h.chestInv, V0, m2:GetAngles())
	end

	local up, front, left = chestIK:Forward(), chestIK:Up(), chestIK:Right()
	if not aS4 then q = 0 end
	SolveArm(ply, h.arm[1], s4Pos, s4Ang, up, front, left, frame.lefthandPos, lAng, stretch, aw, aS4, hand, eP, eA, q)
	SolveArm(ply, h.arm[2], s4Pos, s4Ang, up, front, left, frame.righthandPos, rAng, stretch, aw, aS4, hand, eP, eA, q)
	return true
end

-- Extra SetupBones passes (PAC3, bonemerged weapons): lay the last solve back on.
-- A held worldmodel's bonemerge pass only sets up the bones it needs; the
-- rest are unwriteable there ("Bone is unwriteable"), so each bone is
-- checked readable first, the way the classic apply loop does.
function HIK.Reapply(ply, h)
	local ids, tm, pb, pc, pv = h.ids, h.tm, h.pb, h.pc, h.pv
	for i = 1, #ids do
		local b = ids[i]
		if ply:GetBoneMatrix(b) then ply:SetBoneMatrix(b, tm[b]) end
	end
	for i = 1, #pb do
		if pv[i] and ply:GetBoneMatrix(pb[i]) then ply:SetBoneMatrix(pb[i], pc[i]) end
	end
end
