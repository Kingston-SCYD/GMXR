if SERVER then util.AddNetworkString("VRBtnMsg") util.AddNetworkString("vrmod_pointer_use") end

-- POINTER USE. The menu pointer (vrmod_pointer_hand) also picks out map
-- objects: within POINT_REACH along that hand's forward, a button, door,
-- keypad, charger, ammo crate or vehicle gets the pointer beam, and the Use
-- bind uses it instead of whatever the HMD/weapon aim would find. Pointing at
-- anything else, or nothing, leaves Use exactly as it was. The client sends
-- its target only when it changes, so it is on the server well before the
-- press; the server swaps it in through FindUseEntity (range-checked), which
-- keeps the engine's own use rules (one-shot vs held for chargers, PlayerUse).
local POINT_REACH = 96
local POINT_CLASS = {
	func_button = true, func_rot_button = true, momentary_rot_button = true,
	func_door = true, func_door_rotating = true, prop_door_rotating = true,
	func_movelinear = true, func_tracktrain = true,
	func_recharge = true, func_healthcharger = true, item_healthcharger = true, item_suitcharger = true,
	item_ammo_crate = true, gmod_button = true, gmod_wire_button = true, gmod_wire_dynamic_button = true,
	gmod_wire_keypad = true, keypad = true, keypad_wire = true, sent_button = true,
	gmod_sent_vehicle_fphysics_base = true,
	jazz_cat = true, jazz_door = true, jazz_bus_selector = true, jazz_hub_selector = true,
}

if CLIENT then
	local cv = CreateClientConVar("vrmod_interactive_buttons", "1", true, FCVAR_CLIENTCMD_CAN_EXECUTE + FCVAR_ARCHIVE)
	hook.Add("VRMod_Input", "VRModButtonPresser", function(action, state)
		if not cv:GetBool() or not g_VR.active then return end
		local isLeft
		if action == "boolean_left_pickup" then isLeft = true
		elseif action == "boolean_right_pickup" then isLeft = false
		else return end
		net.Start("VRBtnMsg")
		net.WriteUInt(isLeft and (state and 3 or 2) or (state and 1 or 0), 2)
		net.SendToServer()
	end)
end

if SERVER then
	local IsValid = IsValid
	local ipairs = ipairs
	local bor = bit.bor

	local oneShot = {
		func_button = true, func_rot_button = true, func_door_rotating = true,
		item_ammo_crate = true, gmod_button = true, gmod_wire_button = true,
		sent_button = true, jazz_cat = true, jazz_door = true,
		jazz_bus_selector = true, jazz_hub_selector = true,
	}
	local continuous = {
		item_healthcharger = true,
		item_suitcharger = true,
		func_recharge = true,
		func_healthcharger = true,
	}

	local BTN_RANGE = 5
	local CHARGER_RANGE = 10
	local active = {} -- active[ply] = { left = bool, ent = Entity }

	local function FindChargerNear(ply, isLeft)
		local hp = isLeft and vrmod.GetLeftHandPos(ply) or vrmod.GetRightHandPos(ply)
		if not hp then return end
		for _, ent in ipairs(ents.FindInSphere(hp, CHARGER_RANGE)) do
			if continuous[ent:GetClass()] then return ent end
		end
	end

	local function StopCharging(ply)
		if not active[ply] then return end
		active[ply] = nil
		if not next(active) then
			hook.Remove("StartCommand", "VRMod_ChargerUse")
			hook.Remove("FindUseEntity", "VRMod_ChargerUse")
		end
	end

	local function EnableChargerHooks()
		hook.Add("StartCommand", "VRMod_ChargerUse", function(p, cmd)
			local data = active[p]
			if not data then return end
			if not IsValid(p) or not p:Alive() then StopCharging(p) return end
			local charger = FindChargerNear(p, data.left)
			if charger then
				data.ent = charger
				cmd:SetButtons(bor(cmd:GetButtons(), IN_USE))
			else
				StopCharging(p)
			end
		end)
		hook.Add("FindUseEntity", "VRMod_ChargerUse", function(p)
			local data = active[p]
			if data and IsValid(data.ent) then return data.ent end
		end)
	end

	net.Receive("VRBtnMsg", function(_, ply)
		local bits = net.ReadUInt(2)
		local isLeft = bits >= 2
		local pressed = bits % 2 == 1
		if not pressed then StopCharging(ply) return end
		if not ply:Alive() then return end
		local hp = isLeft and vrmod.GetLeftHandPos(ply) or vrmod.GetRightHandPos(ply)
		if not hp then return end
		for _, ent in ipairs(ents.FindInSphere(hp, CHARGER_RANGE)) do
			local class = ent:GetClass()
			if continuous[class] then
				active[ply] = { left = isLeft, ent = ent }
				EnableChargerHooks()
				return
			end
		end
		for _, ent in ipairs(ents.FindInSphere(hp, BTN_RANGE)) do
			if oneShot[ent:GetClass()] then
				ent:Use(ply, ply, USE_ON, 1)
				return
			end
		end
	end)

	hook.Add("PlayerDisconnected", "VRMod_BtnCleanup", function(ply) StopCharging(ply) end)
end

if CLIENT then
	local cvPU = CreateClientConVar("vrmod_pointer_use", "1", true, false, "Use bind acts on the button, door, keypad, charger or vehicle the menu pointer points at", 0, 1)
	local cvHand -- vrmod_pointer_hand (ui/cl_ui, loaded after this), resolved on first use
	local matBeam, matDot
	local COL = Color(255, 255, 255, 255)
	-- Class, or a vehicle (HL2, Glide, LVS): fixed per entity, cached
	local pointable = setmetatable({}, {__mode = "k"})
	local function Pointable(e)
		local p = pointable[e]
		if p == nil then
			p = POINT_CLASS[e:GetClass()] or e:IsVehicle() or e.IsGlideVehicle == true or e.LVS == true
			pointable[e] = p
		end
		return p
	end
	-- Your own body, what you hold and every VR hand prop (yours sits right
	-- at the pointer) are seen through; the world stops the ray
	local me, heldL, heldR
	local function PointFilter(e)
		if not e:IsValid() then return true end
		return not (e == me or e == heldL or e == heldR or e:GetNWBool("isVRHand"))
	end
	local out, pEnd = {}, Vector()
	local tr = {endpos = pEnd, mask = bit.bor(MASK_SOLID, CONTENTS_DEBRIS), filter = PointFilter, output = out}
	local beamStart, beamEnd, dot = Vector(), Vector(), Vector()
	local target, sent, sendAt, frame = nil, nil, 0, -1

	local function Send(e)
		sent, sendAt = e, SysTime() + 0.05 -- at most 20/s while sweeping
		net.Start("vrmod_pointer_use")
		net.WriteEntity(e or NULL)
		net.SendToServer()
	end

	-- Once per frame. No target while a menu has the pointer, in a vehicle,
	-- dead, or while that hand holds a weapon (Use keeps aiming with it).
	local function Update()
		target = nil
		if g_VR.menuFocus or not g_VR.tracking then return end
		local ply = LocalPlayer()
		if not ply:Alive() or ply:InVehicle() then return end
		cvHand = cvHand or GetConVar("vrmod_pointer_hand")
		local left = cvHand and cvHand:GetBool() or false
		if vrmod.utils.IsValidWep(ply:GetActiveWeapon()) and vrmod.utils.GunInLeftHand() == left then return end
		local pose = left and g_VR.tracking.pose_lefthand or g_VR.tracking.pose_righthand
		if not pose then return end
		local px, py, pz = pose.pos:Unpack()
		local dx, dy, dz = pose.ang:Forward():Unpack()
		pEnd:SetUnpacked(px + dx * POINT_REACH, py + dy * POINT_REACH, pz + dz * POINT_REACH)
		tr.start = pose.pos
		me, heldL, heldR = ply, g_VR.heldEntityLeft, g_VR.heldEntityRight
		util.TraceLine(tr)
		local e = out.Entity
		-- VRMod_PointerUse(e) == false: an addon handles it by hand (SwingDoors),
		-- so no beam and no Use swap. Asked only for a pointable hit.
		if not (out.Hit and e:IsValid() and Pointable(e)) or hook.Run("VRMod_PointerUse", e) == false then return end
		target = e
		local hx, hy, hz = out.HitPos:Unpack()
		beamStart:SetUnpacked(px, py, pz)
		beamEnd:SetUnpacked(hx, hy, hz)
		dot:SetUnpacked(hx - dx * 0.4, hy - dy * 0.4, hz - dz * 0.4) -- off the surface, toward you
	end

	local function Draw(depth, sky)
		if depth or sky then return end
		local fn = FrameNumber()
		if fn ~= frame then
			frame = fn
			Update()
			if not rawequal(target, sent) and SysTime() >= sendAt then Send(target) end
		end
		if not target then return end
		-- The menu pointer's own beam (its colour setting applies)
		matBeam = matBeam or Material("!vrmod_mat_beam")
		matDot = matDot or Material("sprites/light_glow02_add")
		render.SetMaterial(matBeam)
		render.DrawBeam(beamStart, beamEnd, 0.1, 0, 1, COL)
		render.SetMaterial(matDot)
		render.DrawSprite(dot, 1.5, 1.5, COL)
	end

	-- Hooked only while in VR with the option on
	local function Stop()
		hook.Remove("PostDrawTranslucentRenderables", "vrmod_pointer_use")
		target, frame = nil, -1
		if sent ~= nil then Send(nil) end
	end
	local function Sync(inVR)
		if inVR and cvPU:GetBool() then
			hook.Add("PostDrawTranslucentRenderables", "vrmod_pointer_use", Draw)
		else
			Stop()
		end
	end
	hook.Add("VRMod_Start", "vrmod_pointer_use", function(ply) if ply == LocalPlayer() then Sync(true) end end)
	hook.Add("VRMod_Exit", "vrmod_pointer_use", function(ply) if ply == LocalPlayer() then Stop() end end)
	cvars.AddChangeCallback("vrmod_pointer_use", function() Sync(g_VR.active) end, "vrmod_pointer_use")
end

if SERVER then
	-- [ply] = the entity that player's pointer is on
	local pointed = setmetatable({}, {__mode = "k"})
	vrmod.NetReceiveLimited("vrmod_pointer_use", 30, 64, function(_, ply)
		local e = net.ReadEntity()
		pointed[ply] = IsValid(e) and vrmod.IsPlayerInVR(ply) and e or nil
	end)
	-- Within reach of the eyes: the client's 96 from the hand, with slack
	-- for arm length and lag
	local REACH2 = 160 * 160
	hook.Add("FindUseEntity", "vrmod_pointer_use", function(ply)
		local e = pointed[ply]
		if not e then return end
		if not IsValid(e) then pointed[ply] = nil return end
		local eye = ply:EyePos()
		if e:NearestPoint(eye):DistToSqr(eye) <= REACH2 then return e end
	end)
	hook.Add("VRMod_Exit", "vrmod_pointer_use", function(ply) if IsValid(ply) then pointed[ply] = nil end end)
end