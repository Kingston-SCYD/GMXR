-- lua/vrmod/input/cl_aimsteer.lua
-- Halo-style aim steering: point the right hand where you want to go and the
-- vehicle steers its nose toward it. Steer is proportional to the aim's yaw off
-- the nose (deadzone -> full lock at vrmod_vehicle_aimsteer_range) and flips
-- while reversing, so the nose still swings toward the aim point.
--
-- Written straight into vector2_steer.x at the source (VRMOD_GetActions, the
-- same hook point sh_lefthand uses for its trigger swap), so every existing
-- consumer -- the HL2 sidemove in sh_locomotion and Glide's analog stream --
-- picks it up with no changes of its own. Installed from the input subsystem,
-- i.e. before sh_lefthand wraps (pickup loads later), which keeps lefthand's
-- top-of-chain check intact on every VR start.
if SERVER then return end

local cvOn = CreateClientConVar("vrmod_vehicle_aimsteer", "0", true, false, "Steer ground vehicles by aiming the right hand (Halo-style)", 0, 1)
local cvRange = CreateClientConVar("vrmod_vehicle_aimsteer_range", "45", true, false, "Aim angle off the vehicle's nose that gives full steering lock", 5, 90)
local cvDead = CreateClientConVar("vrmod_vehicle_aimsteer_deadzone", "3", true, false, "Aim angle around the vehicle's nose that steers straight", 0, 20)

local on, range, dead
local function Refresh()
	on, dead = cvOn:GetBool(), cvDead:GetFloat()
	range = math.max(cvRange:GetFloat() - dead, 1) -- span from deadzone edge to full lock
end
Refresh()
cvars.AddChangeCallback("vrmod_vehicle_aimsteer", Refresh, "vrmod_aimsteer")
cvars.AddChangeCallback("vrmod_vehicle_aimsteer_range", Refresh, "vrmod_aimsteer")
cvars.AddChangeCallback("vrmod_vehicle_aimsteer_deadzone", Refresh, "vrmod_aimsteer")

local IsValid, LocalPlayer, CurTime = IsValid, LocalPlayer, CurTime
local sin, cos, rad = math.sin, math.cos, math.rad
local STICK = 0.15  -- stick deflection that takes over from the aim
local REVERSE = -30 -- forward speed (u/s) below which steering flips

-- Per-vehicle facts, resolved on entry instead of every frame: the entity
-- whose yaw is the nose (+ its offset) and whose velocity says "reversing".
-- HL2 vehicles and seats face local +Y (nose = yaw + 90); Glide chassis +X.
local curVeh, body, off, skip, retryUntil
local function Resolve(ply, veh)
	curVeh, body, off, skip = veh, veh, 90, false
	if not ply.GlideGetVehicle then return end
	local gv = ply:GlideGetVehicle()
	if IsValid(gv) then
		body, off = gv, 0
		local VT = Glide.VEHICLE_TYPE
		skip = gv.VehicleType == VT.PLANE or gv.VehicleType == VT.HELICOPTER -- steer.x is roll there
	else
		-- The seat can land a frame before its Glide parent; re-resolve for a
		-- second so an aircraft is never mistaken for a plain seat.
		retryUntil = retryUntil or CurTime() + 1
		if CurTime() < retryUntil then curVeh, skip = nil, true return end
	end
	retryUntil = nil
end

-- Swappable body: the wrapper looks this up each frame, so a lua refresh of
-- this file takes effect without stacking a second wrapper.
function vrmod.AimSteer(inp)
	if not on or g_VR.menuFocus or g_VR.wheelGrippedLeft or g_VR.wheelGrippedRight then return end
	local ply = LocalPlayer()
	local veh = ply:GetVehicle()
	if not IsValid(veh) then
		curVeh, retryUntil = nil, nil
		return
	end
	if veh ~= curVeh then Resolve(ply, veh) end
	if skip then return end
	local st = inp.vector2_steer
	if not st then
		st = {x = 0, y = 0}
		inp.vector2_steer = st
	end
	local sx = st.x
	if sx > STICK or sx < -STICK then return end

	-- Aim yaw off the nose, positive = left; normalised to -180..180 inline.
	local yaw = body:GetAngles().yaw + off
	local d = (g_VR.tracking.pose_righthand.ang.yaw - yaw) % 360
	if d > 180 then d = d - 360 end
	local a = d < 0 and -d or d
	if a <= dead then
		st.x = 0
		return
	end
	a = (a - dead) / range
	if a > 1 then a = 1 end
	-- Aim left (d > 0) steers left (negative x). Flipped while reversing.
	local v, y = body:GetVelocity(), rad(yaw)
	if cos(y) * v.x + sin(y) * v.y < REVERSE then a = -a end
	st.x = d > 0 and -a or a
end

if VRMOD_GetActions and not vrmod._aimSteerWrap then
	local f = VRMOD_GetActions
	local function wrap()
		local inp, changed = f()
		if inp then
			-- Deadzone first: the wheel's and aim steer's stick-takeover tests
			-- must see filtered drift. The wheel before aim steer, which
			-- stands aside while a hand is on it.
			-- Seat adjust spends the sticks before anything steers with them.
			local dz, sa, wh, fn = vrmod.StickDeadzone, vrmod.SeatAdjust, vrmod.WheelSteer, vrmod.AimSteer
			if dz then dz(inp) end
			if sa then sa(inp) end
			if wh then wh(inp) end
			if fn then fn(inp) end
		end
		return inp, changed
	end
	vrmod._aimSteerWrap = wrap
	VRMOD_GetActions = wrap
end