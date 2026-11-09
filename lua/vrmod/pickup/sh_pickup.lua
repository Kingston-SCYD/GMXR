g_VR = g_VR or {}
vrmod = vrmod or {}
scripted_ents.Register({
	Type = "anim",
	Base = "vrmod_pickup"
}, "vrmod_pickup")

vrmod.AddCallbackedConvar("vrmod_pickup_limit", nil, 1, FCVAR_REPLICATED + FCVAR_NOTIFY + FCVAR_ARCHIVE, "", 0, 3, tonumber)
vrmod.AddCallbackedConvar("vrmod_pickup_range", nil, 3.5, FCVAR_REPLICATED + FCVAR_ARCHIVE, "", 0.0, 999.0, tonumber)
vrmod.AddCallbackedConvar("vrmod_pickup_weight", nil, 100, FCVAR_REPLICATED + FCVAR_ARCHIVE, "", 0, 100, tonumber)
vrmod.AddCallbackedConvar("vrmod_pickup_npcs", nil, 1, FCVAR_REPLICATED + FCVAR_NOTIFY + FCVAR_ARCHIVE, "", 0, 3, tonumber)
vrmod.AddCallbackedConvar("vrmod_pickup_no_phys", nil, 0, FCVAR_REPLICATED + FCVAR_NOTIFY + FCVAR_ARCHIVE, "", 0, 3, tonumber)
if CLIENT then
	if g_VR then
		g_VR.cooldownLeft = false
		g_VR.cooldownRight = false
	end

	CreateClientConVar("vrmod_pickup_halos", "1", true, FCVAR_CLIENTCMD_CAN_EXECUTE + FCVAR_ARCHIVE)

	-- vrmod_debug_grab 1: where a held thing is meant to be, on both sides.
	-- Per hand: white = raw controller, cyan = hand as drawn (after
	-- collisions), green = where this client draws the held thing (a
	-- ragdoll: its grabbed bone), yellow = the server's target for it, red =
	-- where the server has it, magenta = the hand pose the server drove from.
	--   corr    hand pushed off the controller by collisions, now
	--   hand    server's hand vs yours: latency, or "frame" = stale source
	--   offset  server's grip offset vs this client's: ~0 or the two sides
	--           anchored the grab to different poses (not valid two-handed)
	--   sag     server's object off its own target: blocked, or dragged
	-- Grab press / ack / server pickup also log to console. Userinfo: the
	-- server only sends its side to players with it on.
	local cvDbg = CreateClientConVar("vrmod_debug_grab", "0", false, true, "Grab debug: overlay + console log", 0, 1)
	local dbgSv = {}
	net.Receive("vrmod_grab_dbg", function()
		local idx, i = net.ReadUInt(16), net.ReadBool() and 1 or 2
		local d = dbgSv[i] or {}
		dbgSv[i] = d
		d.idx, d.fresh, d.t = idx, net.ReadBool(), SysTime()
		d.hp, d.ha, d.tp, d.ta, d.sp, d.sa = net.ReadVector(), net.ReadAngle(), net.ReadVector(), net.ReadAngle(), net.ReadVector(), net.ReadAngle()
	end)
	local C_RAW, C_FIN, C_CL, C_TGT, C_SV, C_HAND = Color(255, 255, 255), Color(0, 255, 255), Color(0, 255, 0), Color(255, 255, 0), Color(255, 0, 0), Color(255, 0, 255)
	local BONE_MAX, BONE_MIN, UP4, dbgLines = Vector(1.5, 1.5, 1.5), Vector(-1.5, -1.5, -1.5), Vector(0, 0, 5), {}
	local function DrawGrabDebug(depth, sky)
		if depth or sky then return end
		local tr = g_VR.tracking
		local hmd = tr and tr.hmd
		if not hmd then return end
		local now, wsa, fmt = SysTime(), Angle(0, hmd.ang.y - 90, 90), string.format
		render.SetColorMaterial()
		for i = 1, 2 do
			local left = i == 1
			local fin = tr[left and "pose_lefthand" or "pose_righthand"]
			local rp = vrmod.utils.RawHandPose(left)
			if fin and rp then
				render.DrawWireframeSphere(rp, 0.6, 6, 6, C_RAW, true)
				render.DrawWireframeSphere(fin.pos, 0.8, 6, 6, C_FIN, true)
				render.DrawLine(rp, fin.pos, C_FIN, true)
				local n = 1
				dbgLines[1] = fmt("%s corr %.2f", left and "L" or "R", rp:Distance(fin.pos))
				local ent = g_VR[left and "heldEntityLeft" or "heldEntityRight"]
				local g = IsValid(ent) and ent.vrmod_grabData
				g = g and g[left and "left" or "right"]
				if g then
					local mn, mx = BONE_MIN, BONE_MAX
					if ent:GetClass() ~= "prop_ragdoll" then mn, mx = ent:OBBMins(), ent:OBBMaxs() end
					local cp, ca = LocalToWorld(g.localPos, g.localAng, fin.pos, fin.ang)
					render.DrawWireframeBox(cp, ca, mn, mx, C_CL, true)
					local d = dbgSv[i]
					n = 2
					if d and d.idx == ent:EntIndex() and now - d.t < 0.5 then
						render.DrawWireframeBox(d.tp, d.ta, mn, mx, C_TGT, true)
						render.DrawWireframeBox(d.sp, d.sa, mn, mx, C_SV, true)
						render.DrawWireframeSphere(d.hp, 0.8, 6, 6, C_HAND, true)
						render.DrawLine(fin.pos, d.hp, C_HAND, true)
						local lp = WorldToLocal(d.tp, d.ta, d.hp, d.ha)
						dbgLines[2] = fmt("hand %.2f %s  offset %.2f  sag %.2f", d.hp:Distance(fin.pos), d.fresh and "fresh" or "FRAME", lp:Distance(g.localPos), d.sp:Distance(d.tp))
					else
						dbgLines[2] = "no server data"
					end
				end
				cam.Start3D2D(fin.pos + UP4, wsa, 0.03)
				surface.SetFont("Trebuchet24")
				surface.SetTextColor(255, 255, 255)
				for k = 1, n do
					surface.SetTextPos(0, (k - 1) * 26)
					surface.DrawText(dbgLines[k])
				end
				cam.End3D2D()
			end
		end
	end
	local function DbgToggle(on)
		if on then hook.Add("PostDrawTranslucentRenderables", "vrmod_debug_grab", DrawGrabDebug)
		else hook.Remove("PostDrawTranslucentRenderables", "vrmod_debug_grab") end
	end
	cvars.AddChangeCallback("vrmod_debug_grab", function(_, _, v) DbgToggle(v ~= "0") end, "vrmod_debug_grab")
	DbgToggle(cvDbg:GetBool())
	local pickupTargetEntLeft = nil
	local pickupTargetEntRight = nil
	local haloTargetsLeft = {}
	local haloTargetsRight = {}

	-- Held props draw at the hand in their own engine pass, so they keep what
	-- every other model gets: lighting, projected textures, fog, colour/alpha
	-- and translucent sorting. Drawing them by hand from a post-opaque hook
	-- lost that state (NH2's dark maps, lit by a projected flashlight: held
	-- props went invisible). Gate poses the prop on its first draw each frame
	-- -- after tracking, hand collisions and net lerp -- with render
	-- origin/angles only, so GetPos and client collision stay real. The engine
	-- culls on last frame's pose; a view that skipped it gets the fallback.
	local heldDraw, posed, drawn = {}, {}, {}
	local FrameNumber, band, DEPTH = FrameNumber, bit.band, STUDIO_SHADOWDEPTHTEXTURE
	-- World pose from whichever grips have a hand pose; nil: none (network pose)
	local function HeldPose(gd)
		local L, R = gd.left, gd.right
		local lp, la, rp, ra
		if gd.isLocal then
			local t = g_VR.tracking
			local p = L and t.pose_lefthand
			if p then lp, la = p.pos, p.ang end
			p = R and t.pose_righthand
			if p then rp, ra = p.pos, p.ang end
		else
			local nd = g_VR.net[gd.sid]
			local f = nd and nd.lerpedFrame
			if not f then return end
			if L then lp, la = f.lefthandPos, f.lefthandAng end
			if R then rp, ra = f.righthandPos, f.righthandAng end
		end
		if lp and rp then
			local pA, aA = LocalToWorld(L.localPos, L.localAng, lp, la)
			local pB, aB = LocalToWorld(R.localPos, R.localAng, rp, ra)
			pA:Add(pB)
			pA:Mul(0.5)
			return pA, LerpAngle(0.5, aA, aB)
		end
		if lp then return LocalToWorld(L.localPos, L.localAng, lp, la) end
		if rp then return LocalToWorld(R.localPos, R.localAng, rp, ra) end
	end
	local function Gate(self, flags)
		local fn = FrameNumber()
		if posed[self] ~= fn then
			posed[self] = fn
			local gd = heldDraw[self]
			if gd then
				local p, a = HeldPose(gd)
				self:SetRenderOrigin(p)
				self:SetRenderAngles(a)
				self:InvalidateBoneCache()
			end
		end
		if band(flags or 0, DEPTH) == 0 then drawn[self] = true end
		self:DrawModel(flags)
	end
	-- This hand lets go of ent; the last hand off restores its own drawing
	local function ClearGrab(ent, left)
		local gd = ent.vrmod_grabData
		if not gd then return end
		gd[left and "left" or "right"] = nil
		if gd.left or gd.right then return end
		ent.vrmod_grabData, heldDraw[ent], posed[ent], drawn[ent] = nil, nil, nil, nil
		if ent.RenderOverride == Gate then ent.RenderOverride = nil end
		ent:SetRenderOrigin(nil)
		ent:SetRenderAngles(nil)
	end
	-- Per view, after both passes: draw what the engine culled this view
	hook.Add("PostDrawTranslucentRenderables", "vrmod_held_draw", function(depth, sky)
		if depth or sky or not next(heldDraw) then return end
		for ent in pairs(heldDraw) do
			if not ent:IsValid() then
				heldDraw[ent], posed[ent], drawn[ent] = nil, nil, nil
			else
				if not (drawn[ent] or ent:IsDormant()) then ent:DrawModel() end
				drawn[ent] = nil
			end
		end
	end)

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
        if IsValid(ent) then
            ClearGrab(ent, true)
            ClearGrab(ent, false)
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

	-- Once per frame: this fires in every view (both eyes, spectator, monitors,
	-- depth/skybox passes) and VR halo.Add keeps one list for the whole frame.
	local cvHalos = GetConVar("vrmod_pickup_halos")
	local COL_HALO_L, COL_HALO_R = Color(250, 100, 0), Color(0, 255, 255)
	local haloFrame = -1
	hook.Add("PostDrawOpaqueRenderables", "vrmod_draw_pickup_halo", function(depth, sky)
		if depth or sky then return end
		local fn = FrameNumber()
		if fn == haloFrame or not cvHalos:GetBool() then return end
		haloFrame = fn
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
		if #haloTargetsLeft > 0 then halo.Add(haloTargetsLeft, COL_HALO_L, 1, 1, 1, true, true) end
		if #haloTargetsRight > 0 then halo.Add(haloTargetsRight, COL_HALO_R, 1, 1, 1, true, true) end
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
			ClearGrab(held, bLeftHand)
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
					-- Grip offset measured now, on the raw controller pose (see
					-- CaptureRawPose), and that pose: the server anchors props
					-- and ragdoll bones to it. Flagged: senders without it
					-- (holster draw, left-hand weapon grabs) read false.
					local rp, ra = vrmod.utils.RawHandPose(bLeftHand)
					net.WriteBool(rp ~= nil)
					if rp then
						local lp, la = vrmod.utils.GrabOffset(targetEnt, rp, ra)
						net.WriteVector(lp)
						net.WriteAngle(la)
						net.WriteVector(rp)
						net.WriteAngle(ra)
						if cvDbg:GetBool() then
							local f = g_VR.tracking[bLeftHand and "pose_lefthand" or "pose_righthand"]
							print(string.format("[VRMod Grab] press %s %s corr %.2f surf %.2f |off| %.2f", bLeftHand and "L" or "R", tostring(targetEnt), f and rp:Distance(f.pos) or -1, targetEnt:NearestPoint(rp):Distance(rp), lp:Length()))
						end
					end
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

		if isLocal and cvDbg:GetBool() then
			print(string.format("[VRMod Grab] held %s %s |off| %.2f", bLeftHand and "L" or "R", tostring(ent), localPos:Length()))
		end
		-- A ragdoll draws its bones where the server's physics has them (world
		-- space); moving its origin here did nothing but a SetupBones a draw
		if ent:GetClass() == "prop_ragdoll" then
			hook.Call("VRMod_Pickup", nil, ply, ent)
			return
		end
		ent.RenderOverride = Gate
		heldDraw[ent] = ent.vrmod_grabData
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
			ClearGrab(ent, bLeftHand)
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

	-- hP/hA: the client's raw controller pose at the press, which its
	-- offset was measured on. Props and ragdoll bones are anchored to that,
	-- not to a pose a collision had pushed or the network had delayed.
	-- Trusted near the hand the server has.
	local WorldToLocal = WorldToLocal
	function vrmod.Pickup(ply, bLeftHand, ent, cPos, cAng, hP, hA)
		ply.vrmod_pickup_left_hand = bLeftHand
		if not vrmod.utils.ValidatePickup(ply, bLeftHand, ent) then return end
		ent = vrmod.utils.HandleNPCRagdoll(ply, ent)
		if not IsValid(ent) then return end
		local handPos, handAng, fresh = vrmod.utils.GetHandTransform(ply, bLeftHand)
		if not handPos or not handAng then return end
		local dHand = hP and hP:Distance(handPos) or -1
		local src = fresh and "fresh" or "frame"
		if hP and dHand <= 64 then handPos, handAng, src = hP, hA, "client" end
		local rag = ent:GetClass() == "prop_ragdoll"
		local controller = vrmod.utils.InitPickupController()
		local info = vrmod.utils.CreatePickupInfo(ply, bLeftHand, ent, handPos, handAng, cPos, cAng)
		-- After CreatePickupInfo snapshots the original collision group. A
		-- held prop keeps it, so it still hits other players: its holder
		-- passes through it by the owner rule (PatchOwnerCollision) and its
		-- hands by sv_physhands' Held. PASSABLE_DOOR, which every player
		-- passes through, only where that rule isn't set: ragdolls, and
		-- vrmod_pickup_no_phys.
		if rag or GetConVar("vrmod_pickup_no_phys"):GetBool() then ent:SetCollisionGroup(COLLISION_GROUP_PASSABLE_DOOR) end
		vrmod.utils.AttachPhysicsToController(info, controller)

		if not rag then
			-- Both heldItems on the same prop: two-hand mode
			local held = g_VR[ply:SteamID()]
			held = held and held.heldItems
			if held and held[1] and held[2] and IsValid(held[1].ent) and held[1].ent == held[2].ent then
				vrmod.utils.SetupTwoHand(ply, ent, held[1], held[2], bLeftHand)
			end
		elseif IsValid(controller) then
			-- Each hand drives the nearest bone the other hand hasn't claimed;
			-- ent.vrmod_bone_hand_map tells PhysicsSimulate which hand drives
			-- which bone, so both hands can hold one ragdoll. Connected bones
			-- follow through the joints. Offsets for every bone are kept per
			-- hand: the root rides along on the latest hand's.
			local map = ent.vrmod_bone_hand_map or {}
			ent.vrmod_bone_hand_map = map
			local offsets, best, bestIdx, bestD = {}, nil, nil, nil
			for i = 0, ent:GetPhysicsObjectCount() - 1 do
				local bp = ent:GetPhysicsObjectNum(i)
				if IsValid(bp) then
					local p = bp:GetPos()
					local lp, la = WorldToLocal(p, bp:GetAngles(), handPos, handAng)
					offsets[i] = {localPos = lp, localAng = la}
					local o = map[i]
					if not (o and o ~= info and o.left ~= bLeftHand) then
						local d = p:DistToSqr(handPos)
						if not bestD or d < bestD then best, bestIdx, bestD = bp, i, d end
					end
					bp:SetDamping(0, 0.5) -- connected joints flow freely
				end
			end
			info.vrmod_physOffsets = offsets
			info.ragdoll_bone_phys = {best}
			if best then
				if best ~= info.phys then controller:AddToMotionController(best) end
				best:Wake()
				best:SetMass(8)
				map[bestIdx] = info
				-- The grabbed bone's offset: the client's debug draw reads it
				local o = offsets[bestIdx]
				info.localPos, info.localAng = o.localPos, o.localAng
			end
		end

		vrmod.utils.SendPickupNetMessage(ply, ent, bLeftHand, info.localPos, info.localAng)
		if ply:GetInfoNum("vrmod_debug_grab", 0) ~= 0 then
			ply:PrintMessage(HUD_PRINTCONSOLE, string.format("[VRMod Grab] sv %s %s hand=%s (client vs server %.2f) offset=%s |off| %.2f", bLeftHand and "L" or "R", tostring(ent), src, dHand, info.offSrc or "?", info.localPos:Length()))
		end
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
			local cPos, cAng, hP, hA
			if net.ReadBool() then cPos, cAng, hP, hA = net.ReadVector(), net.ReadAngle(), net.ReadVector(), net.ReadAngle() end
			vrmod.logger.Debug("Calling vrmod.Pickup for entity: " .. tostring(ent))
			vrmod.Pickup(ply, bLeft, ent, cPos, cAng, hP, hA)
		end
	end)

	local _pickupCv = {}
	local function UpdatePickupFlags()
		vrmod.logger.Debug("Updating pickup flags for all players")
		local cv = _pickupCv
		cv.vrmod_pickup_npcs = GetConVar("vrmod_pickup_npcs"):GetInt()
		cv.vrmod_pickup_limit = GetConVar("vrmod_pickup_limit"):GetInt()
		cv.vrmod_pickup_weight = GetConVar("vrmod_pickup_weight"):GetFloat()
		local CanPickup, IsImportant = vrmod.utils.CanPickupEntity, vrmod.utils.IsImportantPickup
		for _, ply in ipairs(player.GetAll()) do
			local nearbyEntities = ents.FindInSphere(ply:GetPos(), 300)
			local key = "vrmod_pickup_valid_for_" .. ply:SteamID()
			for i = 1, #nearbyEntities do
				local ent = nearbyEntities[i]
				-- Weapons don't need physics to be pickable (ManualWeaponPickupHook
				-- handles them via Give/SelectWeapon, not physics shadow)
				ent:SetNWBool(key, (CanPickup(ent, ply, cv) or IsImportant(ent)) and true or false)
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