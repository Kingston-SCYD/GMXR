if SERVER then util.AddNetworkString("VRBtnMsg") end

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