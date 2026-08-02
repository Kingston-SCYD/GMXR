local _, convarValues = vrmod.GetConvars()
local cv_allowtp = CreateConVar("vrmod_allow_teleport", "1", FCVAR_REPLICATED, "Enable teleportation in VRMod", 0, 1)
local cv_usetp = CreateClientConVar("vrmod_allow_teleport_client", 0, true, FCVAR_ARCHIVE)
local cv_tp_hand = CreateClientConVar("vrmod_teleport_use_left", 0, true, FCVAR_ARCHIVE)
local cv_maxTpDist = CreateConVar("vrmod_teleport_maxdist", 50, FCVAR_ARCHIVE + FCVAR_NOTIFY + FCVAR_REPLICATED, "Maximum teleport distance for VRMod")
if SERVER then
	util.AddNetworkString("vrmod_teleport")
	vrmod.NetReceiveLimited("vrmod_teleport", 10, 100, function(len, ply) if cv_allowtp:GetBool() and g_VR[ply:SteamID()] ~= nil and (hook.Run("PlayerNoClip", ply, true) == true or ULib and ULib.ucl.query(ply, "ulx noclip") == true) then ply:SetPos(net.ReadVector()) end end)
	return
end

if SERVER then return end
local tpBeamMatrices, tpBeamEnt, tpBeamHitPos = {}, nil, nil
local zeroVec, zeroAng = Vector(), Angle()
local upVec = Vector(0, 0, 1)
local originVehicleLocalPos, originVehicleLocalAng = Vector(), Angle()
for i = 1, 17 do tpBeamMatrices[i] = Matrix() end

-- Native refs
local LocalToWorld = LocalToWorld
local WorldToLocal = WorldToLocal
local RealFrameTime = RealFrameTime
local math_sqrt = math.sqrt
local math_abs = math.abs
local bit_bor = bit.bor
local FrameTime = FrameTime

hook.Add("VRMod_Input", "teleport", function(action, pressed)
	if action == "boolean_teleport" and not LocalPlayer():InVehicle() and cv_allowtp:GetBool() and cv_usetp:GetBool() then
		if pressed then
			tpBeamEnt = ClientsideModel("models/vrmod/tpbeam.mdl")
			tpBeamEnt:SetRenderMode(RENDERMODE_TRANSCOLOR)
			tpBeamEnt.RenderOverride = function(self)
				render.SuppressEngineLighting(true)
				self:SetupBones()
				for i = 1, 17 do self:SetBoneMatrix(i - 1, tpBeamMatrices[i]) end
				self:DrawModel()
				render.SetColorModulation(1, 1, 1)
				render.SuppressEngineLighting(false)
			end

			hook.Add("VRMod_PreRender", "teleport", function()
				local controllerPos, controllerDir
				local maxDist = cv_maxTpDist:GetInt()
				if cv_tp_hand:GetBool() then
					controllerPos, controllerDir = g_VR.tracking.pose_lefthand.pos, g_VR.tracking.pose_lefthand.ang:Forward()
				else
					controllerPos, controllerDir = g_VR.tracking.pose_righthand.pos, g_VR.tracking.pose_righthand.ang:Forward()
				end

				prevPos = controllerPos
				local hit = false
				for i = 2, 17 do
					local d = i - 1
					local nextPos = controllerPos + controllerDir * maxDist * d + Vector(0, 0, -d * d * 3)
					local v = nextPos - prevPos
					if not hit then
						local tr = util.TraceLine({
							start = prevPos,
							endpos = prevPos + v,
							filter = function(ent) return ent ~= LocalPlayer() and not ent:GetNWBool("IsVRHand", false) end,
							mask = MASK_PLAYERSOLID
						})

						hit = tr.Hit
						if hit then
							tpBeamMatrices[1] = Matrix()
							tpBeamMatrices[1]:Translate(tr.HitPos + tr.HitNormal)
							tpBeamMatrices[1]:Rotate(tr.HitNormal:Angle() + Angle(90, 0, 90))
							if tr.HitNormal.z < 0.7 then
								tpBeamMatrices[1]:Scale(Vector(0.6, 0.6, 0.6))
								tpBeamEnt:SetColor(Color(255, 0, 0, 200))
								tpBeamHitPos = nil
							else
								tpBeamEnt:SetColor(Color(7, 255, 0, 200))
								tpBeamHitPos = tr.HitPos
							end
							tpBeamEnt:SetPos(tr.HitPos)
						end
					end

					tpBeamMatrices[i] = Matrix()
					tpBeamMatrices[i]:Translate(prevPos + v * 0.5)
					tpBeamMatrices[i]:Rotate(v:Angle() + Angle(-90, 0, 0))
					tpBeamMatrices[i]:Scale(Vector(0.5, 0.5, v:Length()))
					prevPos = nextPos
				end

				if not hit then
					tpBeamEnt:SetColor(Color(0, 0, 0, 0))
					tpBeamHitPos = nil
				end
			end)
		else
			tpBeamEnt:Remove()
			hook.Remove("VRMod_PreRender", "teleport")
			if tpBeamHitPos then
				net.Start("vrmod_teleport")
				net.WriteVector(tpBeamHitPos)
				net.SendToServer()
			end
		end
	end
end)

function VRUtilresetVehicleView()
	if not g_VR.threePoints and not LocalPlayer():InVehicle() then return end
	originVehicleLocalPos = nil
end

--[[──────────────────────────────────────────────────────────
  Locomotion start/stop

  Roomscale hull tracking (improved proportional):
  The hull chases the HMD's XY via a proportional error
  signal (followVec = error * gain).  Fixed gain of 20
  keeps steady-state lag ~4 source-units at walking pace.
  The proportional signal self-corrects for engine friction,
  speed caps, and acceleration lag — critical for movement
  mods (HL2-ifier etc.) where sv_stopspeed·sv_friction can
  kill low-velocity acceleration entirely.  Origin tracks
  the hull via pvel − followVec + gvel, with mismatch
  compensation gated on delivered > 0 so walls still work:
  friction (hull moving slowly) → compensate; wall (hull
  stopped) → let origin correct.
──────────────────────────────────────────────────────────]]
local FOLLOW_GAIN = 20

local function start()
	local ply = LocalPlayer()
	local followVec = zeroVec
	originVehicleLocalPos, originVehicleLocalAng = zeroVec, zeroAng
	local snapped = false
	local ncOn, ncLx, ncLy = false, 0, 0

	hook.Add("PreRender", "vrmod_locomotion", function()
		if not g_VR.threePoints then return end

		-- Vehicle mode
		if ply:InVehicle() then
			local v = ply:GetVehicle()
			local att = v:GetAttachment(v:LookupAttachment("vehicle_driver_eyes"))
			if not originVehicleLocalPos then
				local relV, relA = WorldToLocal(g_VR.origin, g_VR.originAngle, g_VR.tracking.hmd.pos, Angle(0, g_VR.tracking.hmd.ang.yaw, 0))
				g_VR.origin, g_VR.originAngle = LocalToWorld(relV + Vector(7, 0, 2), relA, att.Pos, att.Ang)
				originVehicleLocalPos, originVehicleLocalAng = WorldToLocal(g_VR.origin, g_VR.originAngle, att.Pos, att.Ang)
			end
			g_VR.origin, g_VR.originAngle = LocalToWorld(originVehicleLocalPos, originVehicleLocalAng, att.Pos, att.Ang)
			return
		end

		-- Exit vehicle
		if originVehicleLocalPos then
			originVehicleLocalPos = nil
			g_VR.originAngle = Angle(0, g_VR.originAngle.yaw, 0)
		end

		local origin = g_VR.origin

		-- Turning (smooth or snap)
		if convarValues.smoothTurn then
			local amt = -g_VR.input.vector2_smoothturn.x * convarValues.smoothTurnRate * RealFrameTime()
			if amt ~= 0 then
				local pos = ply:GetPos()
				g_VR.origin = LocalToWorld(origin - pos, zeroAng, pos, Angle(0, amt, 0))
				origin = g_VR.origin
				g_VR.originAngle.yaw = g_VR.originAngle.yaw + amt
			end
		else
			local axis = g_VR.input.vector2_smoothturn.x
			if axis > 0.5 or axis < -0.5 then
				if not snapped then
					local a = axis > 0 and -convarValues.snapTurnAngle or convarValues.snapTurnAngle
					local pos = ply:GetPos()
					g_VR.origin = LocalToWorld(origin - pos, zeroAng, pos, Angle(0, a, 0))
					origin = g_VR.origin
					g_VR.originAngle.yaw = g_VR.originAngle.yaw + a
					snapped = true
				end
			else
				snapped = false
			end
		end

		-- Follow HMD (proportional hull tracking)
		local pos = ply:GetPos()

		-- Noclip: glue the playspace to the hull's real per-frame
		-- displacement. The walk path below integrates pvel, but in noclip
		-- the engine owns the move: pvel*FrameTime never matches its actual
		-- displacement and the sub-15 deadzone drops slow flight outright,
		-- so integrating there slips the origin and offsets the playspace.
		-- Mirroring the hull delta keeps origin locked (and snaps cleanly
		-- with it on prediction corrections).
		if ply:GetMoveType() == MOVETYPE_NOCLIP then
			followVec = zeroVec
			if ncOn then
				origin.x = origin.x + pos.x - ncLx
				origin.y = origin.y + pos.y - ncLy
			else
				ncOn = true
			end
			origin.z = pos.z
			ncLx, ncLy = pos.x, pos.y
			return
		end
		ncOn = false

		local hmdPos = g_VR.tracking.hmd.pos
		followVec = Vector((hmdPos.x - pos.x) * FOLLOW_GAIN, (hmdPos.y - pos.y) * FOLLOW_GAIN, 0)
		if followVec:LengthSqr() > 262144 then
			origin.x = origin.x + pos.x - hmdPos.x
			origin.y = origin.y + pos.y - hmdPos.y
			origin.z = pos.z
			return
		end

		local ground = ply:GetGroundEntity()
		local gvel = IsValid(ground) and ground:GetVelocity() or zeroVec
		local pvel = ply:GetVelocity()
		local vel = pvel - followVec + gvel
		vel.z = 0
		-- Mismatch compensation: friction and speed caps cause
		-- pvel < followVec, making vel overshoot negative.
		-- Only compensate when the hull IS moving in the follow
		-- direction (delivered > 0). When delivered ≤ 0 the hull
		-- hit a wall or is stopped — let vel go negative so
		-- origin corrects and the player sees the wall.
		local fLen2 = followVec.x * followVec.x + followVec.y * followVec.y
		if fLen2 > 1 then
			local fLen = math_sqrt(fLen2)
			local fdx, fdy = followVec.x / fLen, followVec.y / fLen
			local delivered = pvel.x * fdx + pvel.y * fdy
			if delivered > 0 then
				local mismatch = fLen - delivered
				if mismatch > 0 then
					vel.x = vel.x + fdx * mismatch
					vel.y = vel.y + fdy * mismatch
				end
			end
		end
		if vel:Length() < 15 then vel = zeroVec end
		origin.x = origin.x + vel.x * FrameTime()
		origin.y = origin.y + vel.y * FrameTime()
		origin.z = pos.z
	end)

	hook.Add("CreateMove", "vrmod_locomotion", function(cmd)
		if not g_VR.threePoints then return end
		if ply:InVehicle() then
			cmd:SetForwardMove((g_VR.input.vector1_forward - g_VR.input.vector1_reverse) * 400)
			cmd:SetSideMove(g_VR.input.vector2_steer.x * 400)
			local _, ra = WorldToLocal(Vector(), g_VR.tracking.hmd.ang, Vector(), ply:GetVehicle():GetAngles())
			cmd:SetViewAngles(ra)
			cmd:SetButtons(bit_bor(cmd:GetButtons(), g_VR.input.boolean_turbo and IN_SPEED or 0, g_VR.input.boolean_handbrake and IN_JUMP or 0))
			return
		end

		local mt = ply:GetMoveType()
		cmd:SetButtons(bit_bor(cmd:GetButtons(), g_VR.input.boolean_jump and (convarValues.noCrouchJump and IN_JUMP or IN_JUMP + IN_DUCK) or 0, g_VR.input.boolean_sprint and IN_SPEED or 0, mt == MOVETYPE_LADDER and IN_FORWARD or 0, g_VR.tracking.hmd.pos.z < g_VR.origin.z + convarValues.crouchThreshold and IN_DUCK or 0))
		local va = g_VR.currentvmi and g_VR.currentvmi.wrongMuzzleAng and g_VR.tracking.pose_righthand.ang or g_VR.viewModelMuzzle and g_VR.viewModelMuzzle.Ang or g_VR.tracking.hmd.ang
		cmd:SetViewAngles(va:Forward():Angle())
		if mt == MOVETYPE_NOCLIP then
			cmd:SetForwardMove(math_abs(g_VR.input.vector2_walkdirection.y) > 0.5 and g_VR.input.vector2_walkdirection.y or 0)
			cmd:SetSideMove(math_abs(g_VR.input.vector2_walkdirection.x) > 0.5 and g_VR.input.vector2_walkdirection.x or 0)
			return
		end

		-- Stick input → world-space velocity
		local wdx = g_VR.input.vector2_walkdirection.x
		local wdy = g_VR.input.vector2_walkdirection.y
		local jv = LocalToWorld(Vector(wdy * math_abs(wdy), -wdx * math_abs(wdx), 0) * ply:GetMaxSpeed() * 0.9, zeroAng, zeroVec, Angle(0, convarValues.controllerOriented and g_VR.tracking.pose_lefthand.ang.yaw or g_VR.tracking.hmd.ang.yaw, 0))
		-- Combine roomscale velocity + stick, project into cmd space
		local wr = WorldToLocal(followVec + jv, zeroAng, zeroVec, Angle(0, va.yaw, 0))
		cmd:SetForwardMove(wr.x)
		cmd:SetSideMove(-wr.y)
	end)
end

local function stop()
	hook.Remove("CreateMove", "vrmod_locomotion")
	hook.Remove("PreRender", "vrmod_locomotion")
	hook.Remove("VRMod_PreRender", "teleport")
	if IsValid(tpBeamEnt) then tpBeamEnt:Remove() end
	vrmod.RemoveInGameMenuItem("Map Browser")
	vrmod.RemoveInGameMenuItem("Reset Vehicle View")
end

timer.Simple(0, function() vrmod.AddLocomotionOption("default", start, stop, options) end)