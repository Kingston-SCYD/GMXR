g_VR = g_VR or {}
vrmod = vrmod or {}
scripted_ents.Register({
	Type = "anim",
	Base = "vrmod_pickup"
}, "vrmod_pickup")

vrmod.AddCallbackedConvar("vrmod_pickup_limit", nil, 1, FCVAR_REPLICATED + FCVAR_NOTIFY + FCVAR_ARCHIVE, "", 0, 3, tonumber)
vrmod.AddCallbackedConvar("vrmod_pickup_range", nil, 3.5, FCVAR_REPLICATED + FCVAR_ARCHIVE, "", 0.0, 999.0, tonumber)
vrmod.AddCallbackedConvar("vrmod_pickup_weight", nil, 150, FCVAR_REPLICATED + FCVAR_ARCHIVE, "", 0, 10000, tonumber)
vrmod.AddCallbackedConvar("vrmod_pickup_npcs", nil, 1, FCVAR_REPLICATED + FCVAR_NOTIFY + FCVAR_ARCHIVE, "", 0, 3, tonumber)
vrmod.AddCallbackedConvar("vrmod_pickup_limit", nil, "1", FCVAR_REPLICATED + FCVAR_NOTIFY + FCVAR_ARCHIVE, "", 0, 3, tonumber)
vrmod.AddCallbackedConvar("vrmod_pickup_no_phys", nil, 0, FCVAR_REPLICATED + FCVAR_NOTIFY + FCVAR_ARCHIVE, "", 0, 3, tonumber)
if CLIENT then
	if g_VR then
		g_VR.cooldownLeft = false
		g_VR.cooldownRight = false
	end

	CreateClientConVar("vrmod_pickup_halos", "1", true, FCVAR_CLIENTCMD_CAN_EXECUTE + FCVAR_ARCHIVE)
	local pickupTargetEntLeft = nil
	local pickupTargetEntRight = nil
	local haloTargetsLeft = {}
	local haloTargetsRight = {}
	-- Cleanup clones only for normal props on drop
	hook.Add("VRMod_Drop", "vrmod_drop_cooldown", function(ply, ent)
		if not IsValid(ent) or vrmod.utils.IsIgnoredProp(ent) then return end
		for _, hand in ipairs({"Left", "Right"}) do
			if g_VR then
				local key = hand == "Left" and "cooldownLeft" or "cooldownRight"
				g_VR[key] = true
				timer.Simple(0.5, function() if g_VR then g_VR[key] = false end end)
			end
		end
	end)

hook.Add("PlayerDeath", "vrmod_pickup_death_cleanup", function(ply)
    if ply ~= LocalPlayer() then return end
    for _, key in ipairs({"heldEntityLeft", "heldEntityRight"}) do
        local ent = g_VR[key]
        if IsValid(ent) and ent.vrmod_grabData then
            ent.RenderOverride = nil
            ent.vrmod_grabData = nil
        end
        g_VR[key] = nil
    end
end)

	hook.Add("Tick", "vrmod_find_pickup_target", function()
		local ply = LocalPlayer()
		if not IsValid(ply) or not g_VR or not vrmod.IsPlayerInVR(ply) or not ply:Alive() then return end
		local pickupRange = GetConVar("vrmod_pickup_range"):GetFloat()
		local heldLeft = IsValid(g_VR.heldEntityLeft) and g_VR.heldEntityLeft or nil
		local heldRight = IsValid(g_VR.heldEntityRight) and g_VR.heldEntityRight or nil
		if not IsValid(g_VR.heldEntityLeft) then g_VR.heldEntityLeft = nil end
		if not IsValid(g_VR.heldEntityRight) then g_VR.heldEntityRight = nil end
		local rightHand = g_VR.tracking and g_VR.tracking.pose_righthand
		if rightHand and not heldRight then
			-- Allow right-hand scanning when the active weapon is in the left hand
			-- (right hand is free to pick up). Original check blocked ALL right-hand
			-- scanning whenever a valid weapon was active, breaking left-hand gameplay.
			local activeWep = ply:GetActiveWeapon()
			local rightBusy = false -- weapons don't block hand scanning; physics pickup system tracks held state via heldEntityRight
			if not rightBusy then
				pickupTargetEntRight = vrmod.utils.FindPickupTarget(ply, false, rightHand.pos, rightHand.ang, pickupRange)
			else
				pickupTargetEntRight = nil
			end
		else
			pickupTargetEntRight = nil
		end

		local leftHand = g_VR.tracking and g_VR.tracking.pose_lefthand
		if leftHand and not heldLeft then
			pickupTargetEntLeft = vrmod.utils.FindPickupTarget(ply, true, leftHand.pos, leftHand.ang, pickupRange)
		else
			pickupTargetEntLeft = nil
		end
	end)

	hook.Add("PostDrawOpaqueRenderables", "vrmod_draw_pickup_halo", function()
		if not GetConVar("vrmod_pickup_halos"):GetBool() then return end
		table.Empty(haloTargetsLeft)
		table.Empty(haloTargetsRight)
		local ply = LocalPlayer()
		local heldLeft, heldRight = g_VR.heldEntityLeft, g_VR.heldEntityRight
		local holdingRagdoll = IsValid(heldLeft) and heldLeft:GetNWBool("is_npc_ragdoll", false) or IsValid(heldRight) and heldRight:GetNWBool("is_npc_ragdoll", false)
		local function ShouldAddHalo(ent)
			if not IsValid(ent) then return false end
			if ent:GetClass() == "prop_ragdoll" and (ent == heldLeft or ent == heldRight) then return true end
			if ent == heldLeft or ent == heldRight or holdingRagdoll then return false end
			-- Check server flag for pickup validity, fallback to IsValidPickupTarget if flag missing
			local serverFlag = ent:GetNWBool("vrmod_pickup_valid_for_" .. ply:SteamID(), nil)
			if serverFlag == nil then
				-- If no server flag, fallback to your clientside logic
				return vrmod.utils.IsValidPickupTarget(ent, ply, false)
			end
			return serverFlag
		end

		if ShouldAddHalo(pickupTargetEntLeft) then haloTargetsLeft[#haloTargetsLeft + 1] = pickupTargetEntLeft end
		if ShouldAddHalo(pickupTargetEntRight) then haloTargetsRight[#haloTargetsRight + 1] = pickupTargetEntRight end
		if #haloTargetsLeft > 0 then halo.Add(haloTargetsLeft, Color(250, 100, 0), 1, 1, 1, true, true) end
		if #haloTargetsRight > 0 then halo.Add(haloTargetsRight, Color(0, 255, 255), 1, 1, 1, true, true) end
	end)

	function vrmod.Pickup(bLeftHand, bDrop)
		if bDrop then
			local heldKey = bLeftHand and "heldEntityLeft" or "heldEntityRight"
			local held = g_VR[heldKey]
if not IsValid(held) then
				-- No physics entity; drop active weapon if it's in this hand
				if bLeftHand == (false == true) then
					local ply = LocalPlayer()
					local wpn = IsValid(ply) and ply:GetActiveWeapon()
					if IsValid(wpn) and vrmod.utils.IsValidWep(wpn) then
						ply:ConCommand("drop")
					end
				end
				-- Always notify server — orphaned pickup may exist from
				-- NPC→ragdoll where entity hadn't replicated to client yet
				local rk = bLeftHand and "pendingRetryLeft" or "pendingRetryRight"
				local pendingIdx = g_VR[rk]
				if pendingIdx then
					timer.Remove("vrmod_pickup_retry_" .. pendingIdx)
					g_VR[rk] = nil
				end
				net.Start("vrmod_pickup")
				net.WriteBool(bLeftHand)
				net.WriteBool(true)
				net.SendToServer()
				return
			end
			if held.vrmod_grabData then
				local key = bLeftHand and "left" or "right"
				held.vrmod_grabData[key] = nil
				if not held.vrmod_grabData.left and not held.vrmod_grabData.right then
					held:SetRenderOrigin(nil)
					held:SetRenderAngles(nil)
					held.RenderOverride = nil
					held.vrmod_grabData = nil
				end
			end
			net.Start("vrmod_pickup")
			net.WriteBool(bLeftHand)
			net.WriteBool(true)
			net.SendToServer()
g_VR[heldKey] = nil

-- Two-hand force-drop: if the same entity was held by both hands and the
-- other grip is also released (below disengage threshold), drop immediately.
-- Bypasses the 3-frame debounce that can leave the entity stuck in one hand
-- when both grips release simultaneously with analog jitter.
local otherKey = bLeftHand and "heldEntityRight" or "heldEntityLeft"
if g_VR[otherKey] == held then
    local inp = g_VR.input
    local otherGrip = inp and tonumber(bLeftHand and inp.vector1_right_squeeze or inp.vector1_left_squeeze) or 1
    if otherGrip < 0.3 then
        vrmod.Pickup(not bLeftHand, true)
    end
end
		else
			local targetEnt = bLeftHand and pickupTargetEntLeft or pickupTargetEntRight
			if IsValid(targetEnt) then
				-- NPC grab requires trigger + grip
				if targetEnt:IsNPC() then
					if (tonumber(g_VR.input and g_VR.input[bLeftHand and "vector1_secondaryfire" or "vector1_primaryfire"]) or 0) < 0.5 then return end
				end
				if g_VR[bLeftHand and "heldEntityLeft" or "heldEntityRight"] ~= targetEnt then
					net.Start("vrmod_pickup")
					net.WriteBool(bLeftHand)
					net.WriteBool(false)
					net.WriteEntity(targetEnt)
					net.SendToServer()
				end
			end
		end
	end

	local function ProcessPickupClient(ply, ent, bLeftHand, localPos, localAng)
		local sid = ply:SteamID()
		if not g_VR.net[sid] then return end

		if ply == LocalPlayer() then
			g_VR[bLeftHand and "heldEntityLeft" or "heldEntityRight"] = ent
		end

		local isLocal = (ply == LocalPlayer())
		ent.vrmod_grabData = ent.vrmod_grabData or { sid = sid, isLocal = isLocal }
		ent.vrmod_grabData[bLeftHand and "left" or "right"] = { localPos = localPos, localAng = localAng }

		local gd = ent.vrmod_grabData
		ent.RenderOverride = function()
			if not IsValid(ent) or not gd then ent:DrawModel() return end
			local L, R = gd.left, gd.right
			if not L and not R then ent:DrawModel() return end

			local lPos, lAng, rPos, rAng
			if gd.isLocal then
				if L then
					local p = g_VR.tracking.pose_lefthand
					if p then lPos, lAng = p.pos, p.ang end
				end
				if R then
					local p = g_VR.tracking.pose_righthand
					if p then rPos, rAng = p.pos, p.ang end
				end
			else
				local nd = g_VR.net[gd.sid]
				local lf = nd and nd.lerpedFrame
				if lf then
					if L then lPos, lAng = lf.lefthandPos, lf.lefthandAng end
					if R then rPos, rAng = lf.righthandPos, lf.righthandAng end
				end
			end

			local wpos, wang
			if L and R and lPos and lAng and rPos and rAng then
				local pA, aA = LocalToWorld(L.localPos, L.localAng, lPos, lAng)
				local pB, aB = LocalToWorld(R.localPos, R.localAng, rPos, rAng)
				wpos = (pA + pB) * 0.5
				wang = LerpAngle(0.5, aA, aB)
			elseif L and lPos and lAng then
				wpos, wang = LocalToWorld(L.localPos, L.localAng, lPos, lAng)
			elseif R and rPos and rAng then
				wpos, wang = LocalToWorld(R.localPos, R.localAng, rPos, rAng)
			end

			if not wpos then ent:DrawModel() return end
			ent:SetPos(wpos)
			ent:SetAngles(wang)
			ent:SetupBones()
			ent:DrawModel()
		end

		hook.Call("VRMod_Pickup", nil, ply, ent)
	end

	net.Receive("vrmod_pickup", function()
		local ply = net.ReadEntity()
		local entIdx = net.ReadUInt(16)
		local ent = Entity(entIdx)
		if not IsValid(ply) then return end

		local bDrop = net.ReadBool()
		local bLeftHand = net.ReadBool()
		if bDrop then
			if not IsValid(ent) then return end
			if ply == LocalPlayer() then
				local heldKey = bLeftHand and "heldEntityLeft" or "heldEntityRight"
				if g_VR[heldKey] == ent then g_VR[heldKey] = nil end
			end
			if ent.vrmod_grabData then
				local key = bLeftHand and "left" or "right"
				ent.vrmod_grabData[key] = nil
				if not ent.vrmod_grabData.left and not ent.vrmod_grabData.right then
					ent.RenderOverride = nil
					ent.vrmod_grabData = nil
				end
			end
			hook.Call("VRMod_Drop", nil, ply, ent)
			return
		end

		local localPos = net.ReadVector()
		local localAng = net.ReadAngle()

		if IsValid(ent) then
			ProcessPickupClient(ply, ent, bLeftHand, localPos, localAng)
elseif entIdx > 0 then
			-- Entity not yet replicated (NPC ragdoll just created on server).
			-- Poll until it exists, then process.
			if ply == LocalPlayer() then
				local rk = bLeftHand and "pendingRetryLeft" or "pendingRetryRight"
				g_VR[rk] = entIdx
			end
			timer.Create("vrmod_pickup_retry_" .. entIdx, 0.05, 20, function()
				local e = Entity(entIdx)
if IsValid(e) then
					timer.Remove("vrmod_pickup_retry_" .. entIdx)
					if ply == LocalPlayer() then g_VR[bLeftHand and "pendingRetryLeft" or "pendingRetryRight"] = nil end
					ProcessPickupClient(ply, e, bLeftHand, localPos, localAng)
				end
			end)
		end
	end)

	net.Receive("vrmod_pickup_update", function()
		local entIdx = net.ReadUInt(16)
		local ent = Entity(entIdx)
		local bLeftHand = net.ReadBool()
		local localPos = net.ReadVector()
		local localAng = net.ReadAngle()
		if not IsValid(ent) or not ent.vrmod_grabData then return end
		local key = bLeftHand and "left" or "right"
		local g = ent.vrmod_grabData[key]
		if g then g.localPos, g.localAng = localPos, localAng end
	end)
end

if SERVER then
	util.AddNetworkString("vrmod_pickup")
	-- Drop function
	function vrmod.Drop(steamid, bLeft)
		vrmod.logger.Debug("Entering vrmod.Drop with steamid: " .. tostring(steamid) .. ", bLeft: " .. tostring(bLeft))
		local ply = player.GetBySteamID(steamid)
		if not IsValid(ply) then vrmod.logger.Debug("vrmod.Drop: invalid player for steamid " .. tostring(steamid)) end
		local handVel = Vector(0, 0, 0)
		if IsValid(ply) then handVel = bLeft and (vrmod.GetLeftHandVelocity(ply) or Vector(0, 0, 0)) or vrmod.GetRightHandVelocity(ply) or Vector(0, 0, 0) end
		vrmod.logger.Debug("vrmod.Drop: hand velocity: " .. tostring(handVel))
		local index, info = vrmod.utils.FindPickupBySteamIDAndHand(steamid, bLeft)
		if not index or not info then
			vrmod.logger.Debug("vrmod.Drop: no matching pickup entry found for steamid: " .. tostring(steamid))
			return
		end

		-- Per-hand ragdoll bone cleanup: remove only THIS hand's bones from the
		-- controller and bone map, so the other hand's bones remain active.
		local ent = info.ent
		if IsValid(ent) and ent:GetClass() == "prop_ragdoll" and info.ragdoll_bone_phys then
			local controller = vrmod.utils.GetPickupController and vrmod.utils.GetPickupController() or nil
			for _, bonePhys in ipairs(info.ragdoll_bone_phys) do
				if IsValid(bonePhys) then
					-- Remove from motion controller
					if IsValid(controller) and bonePhys ~= info.phys then
						controller:RemoveFromMotionController(bonePhys)
					end
					-- Restore normal mass/damping for released bones
					local origMasses = ent.vrmod_original_masses
					if origMasses then
						-- Find the phys index to restore original mass
						for i = 0, ent:GetPhysicsObjectCount() - 1 do
							if ent:GetPhysicsObjectNum(i) == bonePhys then
								if origMasses[i] then
									bonePhys:SetMass(origMasses[i])
								end
								bonePhys:SetDamping(0.5, 0.5)
								break
							end
						end
					end
				end
			end
			-- Clean up bone hand map entries for this hand
			if ent.vrmod_bone_hand_map then
				for physIdx, mappedInfo in pairs(ent.vrmod_bone_hand_map) do
					if mappedInfo == info then
						ent.vrmod_bone_hand_map[physIdx] = nil
					end
				end
				-- If no bones left in map, clean up and restore all bone damping
				if not next(ent.vrmod_bone_hand_map) then
					ent.vrmod_bone_hand_map = nil
					for i = 0, ent:GetPhysicsObjectCount() - 1 do
						local bp = ent:GetPhysicsObjectNum(i)
						if IsValid(bp) then bp:SetDamping(0.5, 0.5) end
					end
				end
			end
			info.ragdoll_bone_phys = nil
			vrmod.logger.Debug("vrmod.Drop: cleaned up ragdoll bone physics for " .. (bLeft and "left" or "right") .. " hand")
		end

			if IsValid(ent) and ent.vrmod_bone_hand_map and next(ent.vrmod_bone_hand_map) then
		info._skipControllerRemoval = true
	end


-- Rebuild two-hand state from heldItems if it was lost (hot-reload,
		-- mixed-generation grab), so the surviving grip keeps the prop.
		if IsValid(ent) and ent:GetClass() ~= "prop_ragdoll" and not ent.vrmod_twohand then
			local h = g_VR[steamid] and g_VR[steamid].heldItems
			local other = h and h[bLeft and 2 or 1]
			if other and other ~= info and other.ent == ent then
				vrmod.utils.SetupTwoHand(ply, ent, h[1], h[2], bLeft)
			end
		end
		if IsValid(ent) and ent.vrmod_twohand then
			vrmod.utils.CleanupTwoHand(info)
		end

		vrmod.logger.Debug("vrmod.Drop: found pickup entry, releasing...")
		vrmod.utils.ReleasePickupEntry(index, info, handVel)
	end

	function vrmod.Pickup(ply, bLeftHand, ent)
		ply.vrmod_pickup_left_hand = bLeftHand
		if not vrmod.utils.ValidatePickup(ply, bLeftHand, ent) then return end
		ent = vrmod.utils.HandleNPCRagdoll(ply, ent)
		local handPos, handAng = vrmod.utils.GetHandTransform(ply, bLeftHand)
		if not handPos or not handAng then return end
		if ent:GetClass() == "prop_ragdoll" then
			ent.vrmod_physOffsets = vrmod.utils.BuildRagdollOffsets(ent, handPos, handAng)
		end
		-- Use PASSABLE_DOOR for both ragdolls and props so held entities
		-- never collide with the player or VR hands while being carried
	local controller = vrmod.utils.InitPickupController()
	local info = vrmod.utils.CreatePickupInfo(ply, bLeftHand, ent, handPos, handAng)
	-- Set PASSABLE_DOOR after CreatePickupInfo snapshots the original collision group
	ent:SetCollisionGroup(COLLISION_GROUP_PASSABLE_DOOR)
		vrmod.utils.AttachPhysicsToController(info, controller)

		-- Two-hand prop grab detection: if both heldItems now reference the
		-- same non-ragdoll entity, enter two-hand mode.
		if ent:GetClass() ~= "prop_ragdoll" then
			local sid = ply:SteamID()
			local held = g_VR[sid] and g_VR[sid].heldItems
			if held and held[1] and held[2]
			   and IsValid(held[1].ent) and held[1].ent == held[2].ent then
				vrmod.utils.SetupTwoHand(ply, ent, held[1], held[2], bLeftHand)
			end
		end

		-- Ragdoll grab system:
		-- Each hand controls the single nearest bone. A per-bone map on the entity
		-- (ent.vrmod_bone_hand_map) tells PhysicsSimulate which hand's info to use
		-- for each bone, enabling simultaneous two-hand ragdoll manipulation.
		-- Connected bones follow naturally via ragdoll joint constraints.
		if ent:GetClass() == "prop_ragdoll" and IsValid(controller) then
			-- Initialize per-bone hand map if not present
			ent.vrmod_bone_hand_map = ent.vrmod_bone_hand_map or {}

			-- Build a set of bone physics indices already claimed by the OTHER hand
			local claimedByOtherHand = {}
			for physIdx, otherInfo in pairs(ent.vrmod_bone_hand_map) do
				if otherInfo and otherInfo ~= info and otherInfo.left ~= bLeftHand then
					claimedByOtherHand[physIdx] = true
				end
			end

			-- Build per-hand offsets so each hand's bones track relative to THAT hand
			local handOffsets = {}
			for i = 0, ent:GetPhysicsObjectCount() - 1 do
				local bonePhys = ent:GetPhysicsObjectNum(i)
				if IsValid(bonePhys) then
					local physPos, physAng = bonePhys:GetPos(), bonePhys:GetAngles()
					local lpos, lang = WorldToLocal(physPos, physAng, handPos, handAng)
					handOffsets[i] = { localPos = lpos, localAng = lang }
				end
			end
			info.vrmod_physOffsets = handOffsets

			-- Find nearest unclaimed bone to this hand
			local nearestPhys, nearestIdx, nearestDist, nearestIsRoot
			for i = 0, ent:GetPhysicsObjectCount() - 1 do
				local bonePhys = ent:GetPhysicsObjectNum(i)
				if IsValid(bonePhys) and not claimedByOtherHand[i] then
					local dist = bonePhys:GetPos():DistToSqr(handPos)
					if not nearestDist or dist < nearestDist then
						nearestPhys, nearestIdx, nearestDist, nearestIsRoot = bonePhys, i, dist, (bonePhys == info.phys)
					end
				end
			end

			-- Attach nearest unclaimed bone to this hand
			local bonePhysList = {}
			if nearestPhys then
				if not nearestIsRoot then
					controller:AddToMotionController(nearestPhys)
				end
				nearestPhys:Wake()
				nearestPhys:SetMass(8)
				nearestPhys:SetDamping(0, 0)
				bonePhysList[1] = nearestPhys
				ent.vrmod_bone_hand_map[nearestIdx] = info
			end
			-- Store refs on the info (not entity) for per-hand cleanup on drop
			info.ragdoll_bone_phys = bonePhysList
			-- Reduce damping on all bones so connected joints flow freely
			for i = 0, ent:GetPhysicsObjectCount() - 1 do
				local bp = ent:GetPhysicsObjectNum(i)
				if IsValid(bp) then bp:SetDamping(0, 0.5) end
			end
			vrmod.logger.Debug("Pickup: Attached " .. #bonePhysList .. " ragdoll bone physics to " .. (bLeftHand and "left" or "right") .. " hand controller for " .. tostring(ent))
		end

		vrmod.utils.SendPickupNetMessage(ply, ent, bLeftHand, info.localPos, info.localAng)
	end

	vrmod.NetReceiveLimited("vrmod_pickup", 10, 400, function(len, ply)
		local bLeft = net.ReadBool()
		local bDrop = net.ReadBool()
		vrmod.logger.Debug("Received net message vrmod_pickup, bLeft: " .. tostring(bLeft) .. ", bDrop: " .. tostring(bDrop) .. ", player: " .. tostring(ply))
		if bDrop then
			vrmod.logger.Debug("Calling vrmod.Drop for player: " .. tostring(ply:SteamID()) .. ", bLeft: " .. tostring(bLeft))
			vrmod.Drop(ply:SteamID(), bLeft)
		else
			local ent = net.ReadEntity()
			vrmod.logger.Debug("Calling vrmod.Pickup for entity: " .. tostring(ent))
			vrmod.Pickup(ply, bLeft, ent)
		end
	end)

	local function UpdatePickupFlags()
		vrmod.logger.Debug("Updating pickup flags for all players")
		for _, ply in ipairs(player.GetAll()) do
			local nearbyEntities = ents.FindInSphere(ply:GetPos(), 300)
			local cv = {
				vrmod_pickup_npcs = GetConVar("vrmod_pickup_npcs"):GetInt(),
				vrmod_pickup_limit = GetConVar("vrmod_pickup_limit"):GetInt(),
				vrmod_pickup_weight = GetConVar("vrmod_pickup_weight"):GetFloat()
			}

			vrmod.logger.Debug("Convar values: npcs=" .. cv.vrmod_pickup_npcs .. ", limit=" .. cv.vrmod_pickup_limit .. ", weight=" .. cv.vrmod_pickup_weight)
			for _, ent in ipairs(nearbyEntities) do
				local canPickup = vrmod.utils.CanPickupEntity(ent, ply, cv)
				-- Weapons don't need physics to be pickable (ManualWeaponPickupHook
				-- handles them via Give/SelectWeapon, not physics shadow)
				if not canPickup and vrmod.utils.IsImportantPickup(ent) then canPickup = true end
				vrmod.logger.Debug("Setting pickup flag for entity: " .. tostring(ent) .. ", player: " .. ply:SteamID() .. ", canPickup: " .. tostring(canPickup))
				ent:SetNWBool("vrmod_pickup_valid_for_" .. ply:SteamID(), canPickup)
			end
		end

		vrmod.logger.Debug("Finished updating pickup flags")
	end

	-- Run every second for performance
	timer.Create("VRMod_UpdatePickupFlags", 1, 0, UpdatePickupFlags)
	hook.Add("PlayerDeath", "vrmod_drop_items_on_death", function(ply)
		if not IsValid(ply) then return end
		local sid = ply:SteamID()
		-- Force drop for both hands
		vrmod.Drop(sid, true)
		vrmod.Drop(sid, false)
	end)

	hook.Add("AllowPlayerPickup", "vrmod", function(ply) return not g_VR[ply:SteamID()] end)
end
