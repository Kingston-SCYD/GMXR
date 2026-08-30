--[[
	sh_lefthand.lua — left-hand weapon support v9

	Attribution: grip press arms; equip within 0.6s commits. Direct
	vrmod_pickup send for ground SWEPs (server rejects duplicates once the
	ent is consumed). Weapon changes without a grip press reset to right.

	Viewmodels: VMI mirrored grip-preserving (A_L=(p,-y,-r),
	P_L=R(A_L)·R(A)^-1·P), cached until offsets or the mode change.
	`vrmod_lh_mirror` selects the position rule: 0 none, 1 grip-preserving
	(original), 2 reflect. See RebuildMirror for what each one costs you.

	Worldmodels: BuildBonePositions bone-shift. The engine bonemerges the wm
	to the player's RHand and poses it there with every holdtype/grip rule;
	the callback shifts every bone by the RH->LH delta (lhMat * rhMat^-1,
	InvertTR rigid inverse). Delta is measured INSIDE the callback from the
	owner's live attachments, so it shares the exact skeleton evaluation the
	bones came from — the gun can't ride the right hand while walking. The
	muzzle is read via GetAttachment AFTER the shift, so the engine derives it
	from the moved bones and it matches the model exactly (drives laser +
	flashlight; the flash particle follows the shifted attachment natively).
	vrmod_lh_offset does NOT apply — anim_attachment_LH is the actual palm.
	The PreRender hook re-registers at VRMod_Start (remove+add) to run LAST,
	after every wm-positioning hook.

	Correction knob `vrmod_lh_offset x y z p yw r` (default 1 -2 0,
	persisted; measured against mirror mode 1). `vrmod_lh_dbg` toggles triage prints. Holster hand match
	reads g_VR.gunInLeftHand (sh_holster patched); flag mirrored onto
	ArcticVR.GunInLeftHand for non-ArcVR weapons. Right-release drop
	suppressed via g_VR.antiDrop. Server: DropWeapon spawns from the left.
]]
g_VR = g_VR or {}
if SERVER then
	util.AddNetworkString("vrmod_lh")
	local leftHeld = {}
	net.Receive("vrmod_lh", function(_, ply) leftHeld[ply] = net.ReadBool() end)
	hook.Add("PlayerDisconnected", "vrmod_lefthand", function(ply) leftHeld[ply] = nil end)
	local function WrapDrop()
		local orig = net.Receivers and net.Receivers.dropweapon
		if not orig or orig == vrmod._lhDropWrap then return end
		local function wrap(len, ply)
			if not leftHeld[ply] then return orig(len, ply) end
			local rp, ra = vrmod.GetRightHandPos, vrmod.GetRightHandAng
			vrmod.GetRightHandPos, vrmod.GetRightHandAng = vrmod.GetLeftHandPos, vrmod.GetLeftHandAng
			local ok, err = pcall(orig, len, ply)
			vrmod.GetRightHandPos, vrmod.GetRightHandAng = rp, ra
			if not ok then ErrorNoHalt(err .. "\n") end
		end

		vrmod._lhDropWrap = wrap
		net.Receive("DropWeapon", wrap)
	end

	WrapDrop()
	hook.Add("InitPostEntity", "vrmod_lefthand", WrapDrop)
	return
end

-- ── CLIENT ──────────────────────────────────────────────────────────────
g_VR.gunInLeftHand = false
local IsValid, CurTime, LocalPlayer, LocalToWorld, hook_Add = IsValid, CurTime, LocalPlayer, LocalToWorld, hook.Add
local pendingLeft, pendingT = false, 0
local dropenable, cvRange, dbg
local ourAnti, arcSet = false, false

-- Global correction (hand space, pre-VMI), persisted; default 1 -2 0.
-- Measured in-headset against mirror mode 1 across the HL2 and CSS weapon
-- sets. The old 0 -4 0 was tuned to cancel the mode-1 swing on one weapon,
-- which cannot work in general: that swing scales with each weapon's grip
-- yaw, so a constant over-corrects the low-yaw weapons and under-corrects
-- the high-yaw ones. This pair corrects the hand-space seating instead and
-- leaves the per-weapon component to the mirror mode.
local LH_FILE = "vrmod_lh_offset.json"
local lhPos, lhAng = Vector(), Angle()
local hasCorr = false
do
	local t = util.JSONToTable(file.Read(LH_FILE, "DATA") or "") or {}
	lhPos:SetUnpacked(t[1] or 1, t[2] or -2, t[3] or 0)
	lhAng:SetUnpacked(t[4] or 0, t[5] or 0, t[6] or 0)
	hasCorr = not (lhPos:IsZero() and lhAng:IsZero())
end

concommand.Add("vrmod_lh_offset", function(_, _, args)
	if #args == 0 then
		print(("[LH] correction pos %.2f %.2f %.2f  ang %.2f %.2f %.2f"):format(lhPos.x, lhPos.y, lhPos.z, lhAng.p, lhAng.y, lhAng.r))
		return
	end

	lhPos:SetUnpacked(tonumber(args[1]) or 0, tonumber(args[2]) or 0, tonumber(args[3]) or 0)
	lhAng:SetUnpacked(tonumber(args[4]) or 0, tonumber(args[5]) or 0, tonumber(args[6]) or 0)
	hasCorr = not (lhPos:IsZero() and lhAng:IsZero())
	file.Write(LH_FILE, util.TableToJSON({lhPos.x, lhPos.y, lhPos.z, lhAng.p, lhAng.y, lhAng.r}))
end, nil, "Left-hand grip correction: x y z pitch yaw roll (no args = print)")
concommand.Add("vrmod_lh_dbg", function()
	dbg = not dbg
	print("[LH] debug " .. (dbg and "ON" or "OFF"))
end)

-- Grip press: arm attribution + direct SWEP grab; left release: drop
hook_Add("VRMod_Input", "vrmod_lefthand_input", function(action, pressed)
	if action == "boolean_left_pickup" then
		if pressed then
			pendingLeft, pendingT = true, CurTime()
			if not g_VR.menuFocus and not IsValid(g_VR.heldEntityLeft) then
				local p = g_VR.tracking.pose_lefthand
				cvRange = cvRange or GetConVar("vrmod_pickup_range")
				local tgt = p and vrmod.utils.FindPickupTarget(LocalPlayer(), true, p.pos, p.ang, cvRange:GetFloat())
				if dbg then print("[LH] left grip; target=" .. tostring(tgt)) end
				if IsValid(tgt) and tgt:IsWeapon() then
					net.Start("vrmod_pickup")
					net.WriteBool(true)
					net.WriteBool(false)
					net.WriteEntity(tgt)
					net.SendToServer()
				end
			end
		elseif g_VR.gunInLeftHand then
			-- mirror of sh_dropweapon's right-release drop
			dropenable = dropenable or GetConVar("vrmod_weapondrop_enable")
			if not dropenable:GetBool() or g_VR.antiDrop and not ourAnti then return end
			local hs = vrmod_holster
			if hs and (hs.IsHandInHolster(true) or hs.IsStoreSuppressed and hs.IsStoreSuppressed(true)) then return end
			local wpn = LocalPlayer():GetActiveWeapon()
			if not IsValid(wpn) then return end
			net.Start("DropWeapon")
			net.WriteBool(true)
			net.WriteVector(vrmod.GetLeftHandVelocity() * 2.5)
			net.WriteVector(vrmod.GetLeftHandAngularVelocity() * 2.5)
			net.WriteBool(not (hs and hs.CountWeapon) or hs.CountWeapon(wpn:GetClass()) <= 1)
			net.SendToServer()
		end
	elseif action == "boolean_right_pickup" and pressed then
		pendingLeft, pendingT = false, CurTime()
	end
end)

-- Worldmodel left-hand: the engine bonemerges the wm to the player's RHand
-- and poses it there with all holdtype rules. A BuildBonePositions callback
-- on the weapon shifts every bone by the RH->LH delta. Measuring the owner's
-- hand attachments INSIDE the callback (not in PreRender) keeps the delta
-- synced with the exact bones it shifts, so right-hand motion fully cancels
-- (no lag while walking). The shifted bones leave the muzzle ATTACHMENT at
-- the left hand for the flash particle; viewModelMuzzle is set here too for
-- the laser (drawn later, same frame).
local _rhM, _lhM = Matrix(), Matrix()
local _muzz = {}
local ovWep, cbID, iRH, iLH, muzIdx
local function BBP(self)
	if not (g_VR.gunInLeftHand and g_VR.wmActive) or iRH <= 0 or iLH <= 0 then return end
	local ow = self:GetOwner()
	if not IsValid(ow) then return end
	local rh, lh2 = ow:GetAttachment(iRH), ow:GetAttachment(iLH)
	if not rh or not lh2 then return end
	_rhM:SetTranslation(rh.Pos)
	_rhM:SetAngles(rh.Ang)
	_rhM:InvertTR()
	_lhM:SetTranslation(lh2.Pos)
	_lhM:SetAngles(lh2.Ang)
	local d = _lhM * _rhM
	for i = 0, self:GetBoneCount() - 1 do
		local m = self:GetBoneMatrix(i)
		if m then self:SetBoneMatrix(i, d * m) end
	end

	-- muzzle read AFTER the shift: the engine derives it from the bones we
	-- just moved, so it lands exactly where the (visually-correct) gun does.
	-- No manual d-mapping -> matches the model, fewer calls.
	local att = self:GetAttachment(muzIdx)
	if att then
		_muzz.Pos, _muzz.Ang = att.Pos, att.Ang
		g_VR.viewModelMuzzle = _muzz
	end
end

local function RestoreOverride()
	if IsValid(ovWep) and cbID then ovWep:RemoveCallback("BuildBonePositions", cbID) end
	ovWep, cbID = nil, nil
end

-- Commit on the frame the equip lands; weapon changes without a recent
-- grip press reset to right. 1 GetActiveWeapon + 1 compare per frame.
local lastWep, lastSent = NULL, false
hook_Add("VRMod_Tracking", "vrmod_lefthand", function()
	local wep = LocalPlayer():GetActiveWeapon()
	if wep == lastWep then return end
	lastWep = wep
	local left = false
	if pendingLeft and CurTime() - pendingT <= 0.6 and IsValid(wep) then
		-- wm-rendered weapons can have no viewmodel; accept them too
		if vrmod.utils.IsValidWep(wep) or wep.IsWMBase then
			left = true
		else
			local c = wep:GetClass()
			left = (g_VR.wmWeapons and g_VR.wmWeapons[c] or g_VR.wmForced and g_VR.wmForced[c]) and true or false
		end
	end

	pendingLeft = false
	g_VR.gunInLeftHand = left
	if not left then RestoreOverride() end
	if dbg then print("[LH] wep -> " .. tostring(wep) .. "  gunInLeftHand=" .. tostring(left)) end
	-- suppress sh_dropweapon's right-release drop via its antiDrop guard
	if left and not g_VR.antiDrop then
		g_VR.antiDrop, ourAnti = true, true
	elseif not left and ourAnti then
		g_VR.antiDrop, ourAnti = false, false
	end

	-- mirror onto ArcVR's flag for non-ArcVR weapons (foregrip et al)
	local arc = ArcticVR
	if arc then
		local arcWep = IsValid(wep) and wep.ArcticVR
		if left and not arcWep then
			arc.GunInLeftHand, arcSet = true, true
		elseif arcSet and (not left or arcWep) then
			arc.GunInLeftHand, arcSet = false, false
		end
	end

	if left ~= lastSent then
		lastSent = left
		net.Start("vrmod_lh")
		net.WriteBool(left)
		net.SendToServer()
	end
end)

-- Mirrored-VMI cache: rebuilt only when the vmi, its offsets or the mode change
local _mPos, _mAng = Vector(), Angle()
local cVmi, c1, c2, c3, c4, c5, c6

-- Position rule. All three reflect the ANGLE the same way -- (p,-y,-r) is the
-- correct reflection of an orientation across the hand's XZ plane -- and differ
-- only in what they do with the offset vector:
--
--   0 none     offset used verbatim. The gun sits in the left hand exactly
--              where it sits in the right.
--   1 grip     original: P_L = R(A_L)*R(A)^-1*P, re-expressing the offset in
--              the reflected basis. Keeps the offset's relationship to the
--              weapon's own axes, but it is a ROTATION about the hand origin,
--              not a reflection, so a weapon with a ~15u lever arm swings
--              sideways by roughly 0.5u per degree of its grip yaw. Weapons
--              with near-zero yaw look fine; ones near 10 deg are visibly off.
--   2 reflect  true reflection: negate the offset's Y as well as yaw and roll.
--
-- Measured across 15 weapons, mode 1's left-vs-right difference is a pure
-- rotation: the translation component is (0.19, -0.32, 0.26) with sd < 0.3,
-- i.e. nothing. That is why no constant vrmod_lh_offset can correct it -- the
-- error scales with each weapon's yaw instead of being the same every time.
local cv_mirror = CreateClientConVar("vrmod_lh_mirror", "1", true, false, "Left-hand grip mirroring: 0 = none, 1 = grip-preserving, 2 = reflect", 0, 2)
local mirrorMode = cv_mirror:GetInt()
cvars.AddChangeCallback("vrmod_lh_mirror", function(_, _, v)
	mirrorMode = tonumber(v) or 1
	cVmi = nil -- next frame fails the identity compare and rebuilds
end, "vrmod_lefthand")

local function RebuildMirror(vmi, op, oa)
	cVmi, c1, c2, c3, c4, c5, c6 = vmi, op.x, op.y, op.z, oa.p, oa.y, oa.r

	if mirrorMode == 0 then
		_mPos:SetUnpacked(c1, c2, c3)
		_mAng:SetUnpacked(c4, c5, c6)
		return
	end

	_mAng:SetUnpacked(c4, -c5, -c6)

	if mirrorMode == 2 then
		_mPos:SetUnpacked(c1, -c2, c3)
		return
	end

	local F, R, U = oa:Forward(), oa:Right(), oa:Up()
	local FL, RL, UL = _mAng:Forward(), _mAng:Right(), _mAng:Up()
	local cx, cy, cz = op:Dot(F), op:Dot(R), op:Dot(U)
	_mPos:SetUnpacked(cx * FL.x + cy * RL.x + cz * UL.x, cx * FL.y + cy * RL.y + cz * UL.y, cx * FL.z + cy * RL.z + cz * UL.z)
end

-- PreRender: re-registered at VRMod_Start so it runs LAST, after every
-- wm-positioning hook has placed the real weapon at the right hand
local function PreRender()
	if not g_VR.gunInLeftHand then return end
	local lh = g_VR.tracking.pose_lefthand
	if not lh then return end
	local pos, ang = lh.pos, lh.ang
	if hasCorr then pos, ang = LocalToWorld(lhPos, lhAng, pos, ang) end
	if g_VR.wmActive then
		-- registration only; BBP does the per-frame work at draw time
		local wep = g_VR.viewModel
		if not IsValid(wep) then return end
		if wep ~= ovWep then
			RestoreOverride()
			ovWep = wep
			cbID = wep:AddCallback("BuildBonePositions", BBP)
			local ow = LocalPlayer()
			iRH = ow:LookupAttachment("anim_attachment_RH")
			iLH = ow:LookupAttachment("anim_attachment_LH")
			local idx = wep:LookupAttachment("muzzle")
			muzIdx = idx > 0 and idx or 1
		end

		return
	end

	local vmi = g_VR.currentvmi
	if vmi then
		local op, oa = vmi.offsetPos, vmi.offsetAng
		if vmi ~= cVmi or op.x ~= c1 or op.y ~= c2 or op.z ~= c3 or oa.p ~= c4 or oa.y ~= c5 or oa.r ~= c6 then RebuildMirror(vmi, op, oa) end
		pos, ang = LocalToWorld(_mPos, _mAng, pos, ang)
	end

	g_VR.viewModelPos, g_VR.viewModelAng = pos, ang
	vrmod.utils.RefreshViewModelMuzzle(g_VR.viewModel)
end

hook_Add("VRMod_PreRender", "vrmod_lefthand", PreRender)

-- Trigger swap at the source: HandleInput derives fire booleans from the
-- vector1 floats it reads via the global VRMOD_GetActions every frame
local function InstallActionSwap()
	local f = VRMOD_GetActions
	if not f or f == vrmod._lhActWrap then return end
	local function wrap()
		local inp, changed = f()
		if inp and g_VR.gunInLeftHand then
			inp.vector1_primaryfire, inp.vector1_secondaryfire = inp.vector1_secondaryfire, inp.vector1_primaryfire
			inp.trigger_right_axis, inp.trigger_left_axis = inp.trigger_left_axis, inp.trigger_right_axis
		end
		return inp, changed
	end

	vrmod._lhActWrap = wrap
	VRMOD_GetActions = wrap
end

InstallActionSwap()
hook_Add("VRMod_Start", "vrmod_lefthand", function()
	InstallActionSwap()
	-- move our PreRender to the END of the hook order (Add-in-place keeps
	-- position; Remove+Add appends) so measurement sees the final transform
	hook.Remove("VRMod_PreRender", "vrmod_lefthand")
	hook_Add("VRMod_PreRender", "vrmod_lefthand", PreRender)
end)
hook_Add("VRMod_Exit", "vrmod_lefthand", function(ply)
	if ply ~= LocalPlayer() then return end
	g_VR.gunInLeftHand, pendingLeft, lastWep = false, false, NULL
	RestoreOverride()
	if ourAnti then
		g_VR.antiDrop, ourAnti = false, false
	end

	if arcSet and ArcticVR then
		ArcticVR.GunInLeftHand, arcSet = false, false
	end
end)