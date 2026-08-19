--[[
vrmod_foregrip.lua – Two-handed weapon grip for VRMod
LookAt aiming (Halo CEVR / ArcVR style) + tacvr grab gating

The offhand pins exactly where the player grabbed -- the grip point gates
whether a grab latches, it never relocates or re-orients the hand model.
Zone resolution order:
  * wep.VRGripPos -- weapon-defined grip point in dominant-hand-local space
    (tacvr's LHandPos equivalent); zone is a 3.5u sphere around it
  * otherwise the shared box/sphere zone in front of the dominant hand
]]

if SERVER then return end

local GRIP_FORWARD = 17   -- units forward along barrel
local GRIP_BACK    = 5   -- units behind weapon hand
local GRIP_SIDE    = 9   -- left/right half-width
local GRIP_VERT    = 9   -- up/down half-height
local GRIP_RADIUS  = 12  -- sphere grab radius (scaled by cv_scale)
local GRIP_POINT_RADIUS = 3.5  -- grab radius around a weapon-defined grip point
local GRAB_GRACE   = 0.25 -- press-buffer window (tacvr inptime)
local LERP_DURATION = 0.1

local cv_sphere = CreateClientConVar("vrmod_foregrip_sphere", "0", true, false, "Foregrip grab zone shape: 1=sphere, 0=box")
local cv_scale  = CreateClientConVar("vrmod_foregrip_scale",  "1", true, false, "Foregrip sphere grab radius scale")

-- Two-hand aim tunables (archived; cached below, live-updated via callback)
local SHOULDER_SIDE = 5   -- shoulder offset right of head center
local SHOULDER_DOWN = 7   -- shoulder offset below eye level
local cv_stock     = CreateClientConVar("vrmod_foregrip_stock",      "0",    true, false, "Virtual stock blend: 0 = hands only, 1 = shoulder pivot only")
local cv_stockdist = CreateClientConVar("vrmod_foregrip_stock_dist", "10",   true, false, "Gun-hand distance to shoulder that engages the stock")
local cv_smooth    = CreateClientConVar("vrmod_foregrip_smooth",     "0",    true, false, "Aim smoothing speed (higher = snappier, 0 = off)")
local f_stock, f_stockdist, f_smooth = cv_stock:GetFloat(), cv_stockdist:GetFloat(), cv_smooth:GetFloat()
cvars.AddChangeCallback("vrmod_foregrip_stock",      function(_, _, v) f_stock     = tonumber(v) or 0 end, "vrmod_foregrip")
cvars.AddChangeCallback("vrmod_foregrip_stock_dist", function(_, _, v) f_stockdist = tonumber(v) or 0 end, "vrmod_foregrip")
cvars.AddChangeCallback("vrmod_foregrip_smooth",     function(_, _, v) f_smooth    = tonumber(v) or 0 end, "vrmod_foregrip")

local isGripping = false
local isReleasing = false
local lerpStart = nil
local gripOffset = Vector()
local gripAngOffset = Angle()
local gripBone = nil
-- Which reference frame gripOffset was captured in, and whether the capture
-- still has to happen. See ForegripRender for why both matter.
local gripPending = false
local gripWM = false

local ohHeld = false     -- offhand pickup button currently held
local pressT = 0         -- press time for the grace-window latch

-- Hand lerp state
local handStartPos, handStartAng
local cachedSID = nil

local LocalPlayer = LocalPlayer
local IsValid = IsValid
local SysTime = SysTime
local LocalToWorld = LocalToWorld
local WorldToLocal = WorldToLocal
local LerpAngle = LerpAngle
local LerpVector = LerpVector
local math_min = math.min
local math_sqrt = math.sqrt
local math_deg = math.deg
local math_rad = math.rad
local math_cos = math.cos
local math_sin = math.sin
local math_exp = math.exp
local math_atan2 = math.atan2
local math_NormalizeAngle = math.NormalizeAngle
local RealFrameTime = RealFrameTime
local Vector = Vector
local Angle = Angle

-- Two-hand aim state (reset on grab)
local smX, smY, smZ = 0, 0, 0   -- smoothed unit aim direction
local smValid = false
local stockRamp = 0             -- virtual stock engage ramp, 0..1 at 5/sec

local _recoilPivot = Angle(0, 0, 0)  -- reused each frame for offhand recoil orbit

local VISUAL_ONLY_FILE = "vrmod_foregrip_visualonly.json"
local visualOnlyWeapons = {}

vrmod_foregrip = vrmod_foregrip or {}
vrmod_foregrip.visualOnly = visualOnlyWeapons

local function VisualOnlyLoad()
	local raw = file.Read(VISUAL_ONLY_FILE, "DATA")
	if raw then
		visualOnlyWeapons = util.JSONToTable(raw) or {}
		vrmod_foregrip.visualOnly = visualOnlyWeapons
	end
end
local function VisualOnlySave()
	file.Write(VISUAL_ONLY_FILE, util.TableToJSON(visualOnlyWeapons, true))
end
VisualOnlyLoad()

function vrmod_foregrip.SetVisualOnly(class, enabled)
	visualOnlyWeapons[class] = enabled or nil
	VisualOnlySave()
end

local EXCLUDED_CLASSES = {
	weapon_fists = true,
	weapon_vrmod_empty = true,
}

local EXCLUDED_PREFIXES = {
	"arcticvr_",
	"catse_vr_gun",
	"cvrg_",
}

local NO_ROTATE_HOLD = {
	pistol = true,
	revolver = true,
	duel = true,
	slam = true,
}

local function IsValidForegrip(wep)
	if not IsValid(wep) then return false end
	if wep.IsWMBase then return false end   -- wm_base uses the offhand for the slide, not a foregrip
	local class = wep:GetClass()
	if EXCLUDED_CLASSES[class] then return false end
	for i = 1, #EXCLUDED_PREFIXES do
		if class:find(EXCLUDED_PREFIXES[i], 1, true) then return false end
	end
	return true
end

local function CalcGripOffsets(wepPos, wepAng, offPos, offAng)
	-- Left-hand weapons skip bone path: VM may not be repositioned yet
	-- due to PreRender hook ordering. Tracking fallback is always current.
	gripWM = g_VR.wmActive or false
	local vm = LocalPlayer():GetViewModel()
	if not g_VR.wmActive and IsValid(vm) then
		gripBone = vm:LookupBone("ValveBiped.Bip01_R_Hand")
		if not gripBone or gripBone < 0 then
			gripBone = vm:LookupBone("weapon_root")
		end
		if not gripBone or gripBone < 0 then
			gripBone = 0
		end
		vm:SetupBones()
		local mtx = vm:GetBoneMatrix(gripBone)
		if mtx then
			gripOffset, gripAngOffset = WorldToLocal(offPos, offAng, mtx:GetTranslation(), mtx:GetAngles())
			return
		end
	end
	-- Fallback: use last rendered VM position (consistent across all offset chains)
	gripBone = nil
	local wPos = g_VR.viewModelPos or wepPos
	local wAng = g_VR.viewModelAng or wepAng
	gripOffset, gripAngOffset = WorldToLocal(offPos, offAng, wPos, wAng)
end

-- Grab attempt: zone-test the offhand against the dominant hand and, on a
-- hit, fix the snap pose the hand will pin to. Returns true on latch.
local function TryGrab(wh, oh)
	local wep = LocalPlayer():GetActiveWeapon()
	if not IsValidForegrip(wep) or not (g_VR.currentvmi or g_VR.wmActive) then return false end

	local lp = WorldToLocal(oh.pos, angle_zero, wh.pos, wh.ang)
	local gp = wep.VRGripPos
	if gp then
		-- Weapon-defined grip point: sphere around it (tacvr: dist < 3.5)
		local r = GRIP_POINT_RADIUS * cv_scale:GetFloat()
		if lp:DistToSqr(gp) > r * r then return false end
	elseif cv_sphere:GetBool() then
		local r = GRIP_RADIUS * cv_scale:GetFloat()
		if lp:LengthSqr() >= r * r then return false end
	elseif not (lp.x > -GRIP_BACK and lp.x < GRIP_FORWARD
	        and lp.y > -GRIP_SIDE and lp.y < GRIP_SIDE
	        and lp.z > -GRIP_VERT and lp.z < GRIP_VERT) then
		return false
	end

	isGripping = true
	isReleasing = false
	lerpStart = SysTime()
	smValid = false      -- fresh grab: drop stale smoothed aim
	stockRamp = 0        -- and re-detect the shoulder from scratch
	handStartPos = Vector(oh.pos)
	handStartAng = Angle(oh.ang)
	-- Capture deferred to ForegripRender. Measuring here reads the
	-- viewmodel bones as they stood at input time -- before this
	-- frame's VRMod_Tracking has moved the viewmodel -- while the
	-- apply reads them after. Capturing at the same point in the
	-- frame that the apply runs makes the two agree by construction.
	gripPending = true
	return true
end

-- Two-hand aim: gun-hand -> offhand direction becomes the weapon's forward
-- axis; roll stays on the dominant hand. On top of the plain LookAt
-- (Quake VR / HL2VRU model):
--   * virtual stock -- while the gun hand is shouldered, the aim blends
--     toward the shoulder->offhand ray (H3VR-style pivot), on its own 5/sec
--     ramp so it fades in/out instead of snapping
--   * EMA smoothing (frame-rate independent) filters the controller jitter
--     that the short hand-to-hand baseline amplifies
--   * stacked-hands guard -- inside 3 units the direction is pure noise, so
--     hold the last stable aim instead of producing garbage yaw
-- No per-frame allocations except the returned Angle: the netframe takes
-- ownership of it, so it must be a unique object (never a reused one).
local function GetTwoHandedAngle(wepAng, offPos, wepPos, fraction, wepLeft)
	local dt = RealFrameTime()

	local dx, dy, dz = offPos.x - wepPos.x, offPos.y - wepPos.y, offPos.z - wepPos.z
	local len = math_sqrt(dx * dx + dy * dy + dz * dz)
	local held = false
	if len < 3 then
		if not smValid then return Angle(wepAng.p, wepAng.y, wepAng.r) end
		dx, dy, dz = smX, smY, smZ
		held = true   -- holding last stable aim: don't let the stock steer it
	else
		local inv = 1 / len
		dx, dy, dz = dx * inv, dy * inv, dz * inv
	end

	-- Virtual stock: blend toward the shoulder -> offhand ray
	local hmd = (not held and f_stock > 0) and g_VR.tracking.hmd or nil
	if hmd then
		local hp = hmd.pos
		local yr = math_rad(hmd.ang.y)
		local fx, fy = math_cos(yr), math_sin(yr)              -- yaw-only forward
		local side = wepLeft and -SHOULDER_SIDE or SHOULDER_SIDE -- right = (fy, -fx)
		local sx = hp.x + fy * side - fx * 2                    -- 2u behind head
		local sy = hp.y - fx * side - fy * 2
		local sz = hp.z - SHOULDER_DOWN

		local gx, gy, gz = wepPos.x - sx, wepPos.y - sy, wepPos.z - sz
		local shouldered = gx * gx + gy * gy + gz * gz < f_stockdist * f_stockdist
		stockRamp = stockRamp + (shouldered and dt * 5 or -dt * 5)
		if stockRamp < 0 then stockRamp = 0 elseif stockRamp > 1 then stockRamp = 1 end

		local k = f_stock * stockRamp
		if k > 0 then
			local ox, oy, oz = offPos.x - sx, offPos.y - sy, offPos.z - sz
			local ol = math_sqrt(ox * ox + oy * oy + oz * oz)
			if ol > 1 then
				local inv = 1 / ol
				dx = dx + (ox * inv - dx) * k
				dy = dy + (oy * inv - dy) * k
				dz = dz + (oz * inv - dz) * k
				local nl = math_sqrt(dx * dx + dy * dy + dz * dz)
				if nl > 0.001 then
					inv = 1 / nl
					dx, dy, dz = dx * inv, dy * inv, dz * inv
				end
			end
		end
	end

	-- Jitter smoothing: EMA, frame-rate independent
	if f_smooth > 0 and smValid then
		local a = 1 - math_exp(-dt * f_smooth)
		dx = smX + (dx - smX) * a
		dy = smY + (dy - smY) * a
		dz = smZ + (dz - smZ) * a
		local nl = math_sqrt(dx * dx + dy * dy + dz * dz)
		if nl > 0.001 then
			local inv = 1 / nl
			dx, dy, dz = dx * inv, dy * inv, dz * inv
		end
	end
	smX, smY, smZ, smValid = dx, dy, dz, true

	-- Direction -> pitch/yaw; roll stays on the dominant hand
	local pitch = math_deg(math_atan2(-dz, math_sqrt(dx * dx + dy * dy)))
	local yaw = math_deg(math_atan2(dy, dx))
	if fraction >= 1 then return Angle(pitch, yaw, wepAng.r) end
	return Angle(
		wepAng.p + math_NormalizeAngle(pitch - wepAng.p) * fraction,
		wepAng.y + math_NormalizeAngle(yaw - wepAng.y) * fraction,
		wepAng.r)
end

hook.Add("VRMod_Input", "Foregrip", function(action, pressed)
	if not g_VR.active then return end
	local wepLeft = ArcticVR and ArcticVR.GunInLeftHand or false
	if action ~= (wepLeft and "boolean_right_pickup" or "boolean_left_pickup") then return end
	local wh = wepLeft and g_VR.tracking.pose_lefthand or g_VR.tracking.pose_righthand
	local oh = wepLeft and g_VR.tracking.pose_righthand or g_VR.tracking.pose_lefthand
	if not wh or not oh then return end

	if pressed then
		ohHeld = true
		-- A press that misses the zone still arms a short grace window
		-- (tacvr's inptime buffer): sliding into the zone right after the
		-- press latches from ForegripTracking.
		if not TryGrab(wh, oh) then pressT = SysTime() end
	else
		ohHeld = false
		if isGripping then
			isReleasing = true
			isGripping = false
			gripPending = false
			lerpStart = SysTime()
		end
	end
end)

hook.Add("VRMod_Tracking", "ForegripTracking", function()
	if not g_VR.currentvmi and not g_VR.wmActive then return end
	if not isGripping and not isReleasing then
		-- Press-buffer latch: recent press, button still held, hand slid in
		if not (ohHeld and SysTime() - pressT < GRAB_GRACE) then return end
		local wepLeft = ArcticVR and ArcticVR.GunInLeftHand or false
		local wh = wepLeft and g_VR.tracking.pose_lefthand or g_VR.tracking.pose_righthand
		local oh = wepLeft and g_VR.tracking.pose_righthand or g_VR.tracking.pose_lefthand
		if not wh or not oh or not TryGrab(wh, oh) then return end
	end

	local wep = LocalPlayer():GetActiveWeapon()
	if not IsValid(wep) or NO_ROTATE_HOLD[wep:GetHoldType()] then return end
	local WA = vrmod.weaponadapter
	if visualOnlyWeapons[wep:GetClass()] or (WA and WA.IsVisualOnly(wep)) then
		if isReleasing then isReleasing = false; lerpStart = nil end
		return
	end

	local wepLeft = ArcticVR and ArcticVR.GunInLeftHand or false
	local wh = wepLeft and g_VR.tracking.pose_lefthand or g_VR.tracking.pose_righthand
	local oh = wepLeft and g_VR.tracking.pose_righthand or g_VR.tracking.pose_lefthand
	if not wh or not oh then
		isGripping = false
		isReleasing = false
		return
	end

	local frac = 1
	if lerpStart then
		frac = math_min((SysTime() - lerpStart) / LERP_DURATION, 1)
		if isReleasing then
			frac = 1 - frac
			if frac <= 0 then
				isReleasing = false
				lerpStart = nil
				return
			end
		elseif frac >= 1 then
			lerpStart = nil
		end
	end

	local newAng = GetTwoHandedAngle(wh.ang, oh.pos, wh.pos, frac, wepLeft)
	wh.ang = newAng

	local nf = cachedSID and g_VR.net and g_VR.net[cachedSID] and g_VR.net[cachedSID].lerpedFrame
	if nf then
		if wepLeft then
			nf.lefthandAng = newAng
			nf.lefthandPos = wh.pos
		else
			nf.righthandAng = newAng
			nf.righthandPos = wh.pos
		end
	end
end)

hook.Add("VRMod_PreRender", "ForegripRender", function()
	local hasWeapon = g_VR.currentvmi or g_VR.wmActive
	if not isGripping or not hasWeapon then
		if not hasWeapon then isGripping = false end
		if vrmod_wmrecoil then vrmod_wmrecoil.gripping = false end
		return
	end

	-- Tell the worldmodel recoil system we're two-handing (it halves recoil).
	if vrmod_wmrecoil then vrmod_wmrecoil.gripping = true end

	local wepLeft = ArcticVR and ArcticVR.GunInLeftHand or false
	local wh = wepLeft and g_VR.tracking.pose_lefthand or g_VR.tracking.pose_righthand
	local oh = wepLeft and g_VR.tracking.pose_righthand or g_VR.tracking.pose_lefthand
	if not wh or not oh then
		isGripping = false
		return
	end

	-- Capture on the first gripping frame, and re-capture if worldmodel mode
	-- flipped underneath us (the two modes resolve against different frames).
	if gripPending or gripWM ~= (g_VR.wmActive or false) then
		gripPending = false
		-- Capture the pose the hand was actually grabbed at. Snapping it to a
		-- rail point instead would visibly teleport and re-orient the hand
		-- model on grab -- the grip point gates the grab, it does not move it.
		CalcGripOffsets(wh.pos, wh.ang, handStartPos or oh.pos, handStartAng or oh.ang)
	end

	-- gripBone records WHICH frame gripOffset was measured in: a bone index
	-- means the viewmodel's hand bone, nil means the g_VR.viewModelPos origin.
	-- The apply has to use the same one. The old code fell through to the
	-- origin frame whenever the bone matrix came back nil, reinterpreting a
	-- bone-relative offset as origin-relative -- and the gap between those two
	-- frames is the grip offset itself, so the hand only visibly broke once
	-- the weapon fixer had moved the gun off the bone. Bail instead: holding
	-- last frame's hand for one frame is invisible, landing it a grip offset
	-- away is not.
	local aPos, aAng
	if gripBone and not g_VR.wmActive then
		local vm = LocalPlayer():GetViewModel()
		if not IsValid(vm) then return end
		-- RefreshViewModelMuzzle invalidates this cache on every call and, on
		-- the default rigid path, returns without rebuilding -- so without
		-- SetupBones the matrix here is still the previous frame's viewmodel
		-- position, and the offhand trails the gun while you move.
		vm:SetupBones()
		local mtx = vm:GetBoneMatrix(gripBone)
		if not mtx then return end
		aPos, aAng = LocalToWorld(gripOffset, gripAngOffset, mtx:GetTranslation(), mtx:GetAngles())
	else
		local wPos = g_VR.viewModelPos or wh.pos
		local wAng = g_VR.viewModelAng or wh.ang
		aPos, aAng = LocalToWorld(gripOffset, gripAngOffset, wPos, wAng)
	end

	if lerpStart then
		local frac = math_min((SysTime() - lerpStart) / LERP_DURATION, 1)
		aPos = LerpVector(frac, handStartPos, aPos)
		aAng = LerpAngle(frac, handStartAng, aAng)
	end

	-- Recoil orbit: the dominant hand pose has already been pitched up by the
	-- recoil system (in VRMod_Tracking) this frame, but aPos/aAng above were
	-- built from the un-pitched weapon/viewmodel position. Re-anchor the
	-- offhand from the raw dominant frame into the recoiled one so it follows
	-- the gun. wh.ang currently = raw - kick, so raw pitch = wh.ang.p + kick.
	local kick = vrmod_wmrecoil and vrmod_wmrecoil.kick or 0
	if kick > 0 then
		_recoilPivot.p, _recoilPivot.y, _recoilPivot.r = wh.ang.p + kick, wh.ang.y, wh.ang.r
		local lp, la = WorldToLocal(aPos, aAng, wh.pos, _recoilPivot)
		aPos, aAng = LocalToWorld(lp, la, wh.pos, wh.ang)
	end

	-- Pin offhand to grip: override tracking pose (VRMod renders from this)
	-- and netFrame (other players see this via character model).
	oh.pos = aPos
	oh.ang = aAng

	if wepLeft then
		vrmod.SetRightHandPose(aPos, aAng)
	else
		vrmod.SetLeftHandPose(aPos, aAng)
	end

	local nf = cachedSID and g_VR.net and g_VR.net[cachedSID] and g_VR.net[cachedSID].lerpedFrame
	if nf then
		if wepLeft then
			nf.righthandPos = aPos
			nf.righthandAng = aAng
		else
			nf.lefthandPos = aPos
			nf.lefthandAng = aAng
		end
	end
end)

hook.Add("VRMod_Exit", "ForegripExit", function(ply)
	if ply ~= LocalPlayer() then return end
	isGripping = false
	isReleasing = false
	lerpStart = nil
	gripBone = nil
	gripPending = false
	ohHeld = false
	if vrmod_wmrecoil then vrmod_wmrecoil.gripping = false end
end)

hook.Add("VRMod_Start", "ForegripCacheSID", function(ply)
	if ply == LocalPlayer() then cachedSID = ply:SteamID() end
end)

concommand.Add("vrmod_foregrip_test", function()
	local wep = LocalPlayer():GetActiveWeapon()
	local vm = LocalPlayer():GetViewModel()
	print("[Foregrip] Gripping:", isGripping, " Releasing:", isReleasing)
	print("  Weapon:", IsValid(wep) and wep:GetClass() or "None",
	      " HoldType:", IsValid(wep) and wep:GetHoldType() or "N/A")
	print("  Valid:", IsValidForegrip(wep),
	      " Rotation:", IsValid(wep) and not NO_ROTATE_HOLD[wep:GetHoldType() or ""] or false,
	      " VisualOnly:", IsValid(wep) and visualOnlyWeapons[wep:GetClass()] or false)
	print("  GripZone:", IsValid(wep) and wep.VRGripPos and tostring(wep.VRGripPos) or "default zone")
	local lh = g_VR.tracking.pose_lefthand
	local rh = g_VR.tracking.pose_righthand
	if lh and rh then
		local wepLeft = ArcticVR and ArcticVR.GunInLeftHand or false
		local wh = wepLeft and lh or rh
		local oh = wepLeft and rh or lh
		local lp = (WorldToLocal(oh.pos, angle_zero, wh.pos, wh.ang))
		if IsValid(wep) and wep.VRGripPos then
			print(string.format("  LocalOff: X:%.1f Y:%.1f Z:%.1f  point dist:%.1f  (r:%.1f)",
				lp.x, lp.y, lp.z, lp:Distance(wep.VRGripPos), GRIP_POINT_RADIUS * cv_scale:GetFloat()))
		elseif cv_sphere:GetBool() then
			print(string.format("  LocalOff: X:%.1f Y:%.1f Z:%.1f  dist:%.1f  (sphere r:%.1f)",
				lp.x, lp.y, lp.z, lp:Length(), GRIP_RADIUS * cv_scale:GetFloat()))
		else
			print(string.format("  LocalOff: X:%.1f Y:%.1f Z:%.1f  (box: X:-%.0f/+%.0f Y:±%.0f Z:±%.0f)",
				lp.x, lp.y, lp.z, GRIP_BACK, GRIP_FORWARD, GRIP_SIDE, GRIP_VERT))
		end
	end
	local sid = LocalPlayer():SteamID()
	local nf = g_VR.net and g_VR.net[sid] and g_VR.net[sid].lerpedFrame
	print("  NetFrame:", nf and "Yes" or "No")
	if gripBone and IsValid(vm) then
		print("  GripBone:", gripBone, "(", vm:GetBoneName(gripBone) or "?", ")")
	end
end)