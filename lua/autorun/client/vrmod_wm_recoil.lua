--[[
vrmod_wm_recoil.lua – Worldmodel weapon recoil for VRMod

Worldmodel-rendered guns feel flat because nothing kicks them. This adds a
small upward pitch impulse on each shot, scaled linearly by weapon damage
between a min and max kick. Shots are detected by mag-count drop, so it works
on any SWEP base without per-base hooks and wont fuck up melee. Only active while g_VR.wmActive.
]]

if SERVER then return end

-- ── Tunables (convars so they persist to cfg/cl.db) ─────────────────────
-- Kick is in degrees of pitch-up. Damage at/above MAXDMG gets MAXKICK;
-- damage at/below 0 gets MINKICK; linear between.
local cv_enabled  = CreateClientConVar("vrmod_wmrecoil_enabled",  "1",  true, false, "Enable worldmodel weapon recoil")
local cv_min      = CreateClientConVar("vrmod_wmrecoil_min",      "0.8", true, false, "Minimum recoil kick (degrees up)")
local cv_max      = CreateClientConVar("vrmod_wmrecoil_max",      "20.0", true, false, "Maximum recoil kick (degrees up)")
local cv_maxdmg   = CreateClientConVar("vrmod_wmrecoil_maxdmg",   "62",  true, false, "Damage at which recoil reaches max")
local cv_recover  = CreateClientConVar("vrmod_wmrecoil_recover",  "20",   true, false, "Recovery speed (kick decays toward 0 per second)")

-- ── Cached natives ──────────────────────────────────────────────────────
local LocalPlayer = LocalPlayer
local IsValid = IsValid
local CurTime = CurTime
local FrameTime = FrameTime
local math_Clamp = math.Clamp

-- ── State ────────────────────────────────────────────────────────────────
local curKick   = 0        -- current applied pitch-up (degrees), decays to 0
local lastWep   = nil      -- weapon entity tracked for clip changes
local lastClip  = -1       -- last seen clip count
local kickByDmg = {}       -- class -> resolved kick magnitude cache

-- Public state so the foregrip system can read the live kick (to orbit the
-- offhand) and request the half-recoil reduction while two-handing.
vrmod_wmrecoil = vrmod_wmrecoil or {}
vrmod_wmrecoil.kick = 0       -- live applied kick this frame (post-halving)
vrmod_wmrecoil.gripping = false  -- set true by foregrip while two-handed

-- Resolve a weapon's per-shot kick magnitude from its damage.
local function ResolveKick(wep)
	local class = wep:GetClass()
	local cached = kickByDmg[class]
	if cached then return cached end

	-- Damage: prefer Primary.Damage (most SWEP bases), else a sane default.
	local dmg = 0
	local prim = wep.Primary
	if prim and prim.Damage then dmg = prim.Damage end
	if dmg <= 0 and wep.GetDamage then dmg = wep:GetDamage() or 0 end

	local mn, mx = cv_min:GetFloat(), cv_max:GetFloat()
	local maxdmg = cv_maxdmg:GetFloat()
	local frac = maxdmg > 0 and math_Clamp(dmg / maxdmg, 0, 1) or 0
	local kick = mn + (mx - mn) * frac

	kickByDmg[class] = kick
	return kick
end

-- Detect a shot: clip count dropped on the active weapon this frame.
local function PollShot(wep)
	if wep ~= lastWep then
		lastWep = wep
		lastClip = wep:Clip1()
		return false
	end
	local clip = wep:Clip1()
	if clip < lastClip then
		lastClip = clip
		return true
	end
	lastClip = clip
	return false
end

-- Advance/decay kick, publish the value, and apply the dominant-hand pitch —
-- all in VRMod_Tracking, which fires before every VRMod_PreRender hook this
-- frame. Foregrip then reads a current-frame kick and an already-pitched
-- dominant pose, so its offhand orbit is deterministic regardless of file
-- load order.
hook.Add("VRMod_Tracking", "vrmod_wmrecoil", function()
	if not cv_enabled:GetBool() or not g_VR.wmActive then
		curKick = 0
		vrmod_wmrecoil.kick = 0
		return
	end

	local ply = LocalPlayer()
	local wep = ply:GetActiveWeapon()
	if not IsValid(wep) then curKick = 0 vrmod_wmrecoil.kick = 0 return end
	if wep.IsWMBase then curKick = 0 return end   -- wm_base drives its own recoil

	-- New shot adds kick (capped at max so rapid fire doesn't stack forever).
	if PollShot(wep) then
		curKick = math_Clamp(curKick + ResolveKick(wep), 0, cv_max:GetFloat())
	end

	-- Foregrip (two-handed) cuts felt recoil in half.
	local applied = vrmod_wmrecoil.gripping and curKick * 0.5 or curKick
	vrmod_wmrecoil.kick = applied

	if applied > 0 then
		-- Apply to the dominant-hand tracking pose (worldmodel renders from
		-- this) and the netframe (other players see it via the character model).
		local wepLeft = false
		local pose = g_VR.tracking[wepLeft and "pose_lefthand" or "pose_righthand"]
		if pose and pose.ang then
			pose.ang.p = pose.ang.p - applied  -- negative pitch = muzzle rises
		end

		local nf = g_VR.net
		nf = nf and nf[ply:SteamID()] and nf[ply:SteamID()].lerpedFrame
		if nf then
			if wepLeft then
				if nf.lefthandAng then nf.lefthandAng.p = nf.lefthandAng.p - applied end
			else
				if nf.righthandAng then nf.righthandAng.p = nf.righthandAng.p - applied end
			end
		end
	end

	-- Decay toward zero for next frame.
	if curKick > 0 then
		curKick = curKick - cv_recover:GetFloat() * FrameTime()
		if curKick < 0 then curKick = 0 end
	end
end)

-- Clear cache on convar changes so new tuning takes effect immediately.
cvars.AddChangeCallback("vrmod_wmrecoil_min",    function() kickByDmg = {} end, "wmrecoil")
cvars.AddChangeCallback("vrmod_wmrecoil_max",    function() kickByDmg = {} end, "wmrecoil")
cvars.AddChangeCallback("vrmod_wmrecoil_maxdmg", function() kickByDmg = {} end, "wmrecoil")

hook.Add("VRMod_Exit", "vrmod_wmrecoil_exit", function(ply)
	if ply ~= LocalPlayer() then return end
	curKick = 0
	lastWep = nil
	lastClip = -1
end)

concommand.Add("vrmod_wmrecoil_test", function()
	local wep = LocalPlayer():GetActiveWeapon()
	print("[WMRecoil] enabled:", cv_enabled:GetBool(), " wmActive:", g_VR.wmActive)
	print("  curKick:", curKick)
	if IsValid(wep) then
		local prim = wep.Primary
		print("  weapon:", wep:GetClass(), " dmg:", prim and prim.Damage or "?",
		      " resolvedKick:", ResolveKick(wep))
	end
end)