if SERVER then return end

------------------------------------------------------------------------
-- Render Target Setup
------------------------------------------------------------------------
local vrScrH = CreateClientConVar("vrmod_ScrH_hud", ScrH(), true, FCVAR_ARCHIVE)
local vrScrW = CreateClientConVar("vrmod_ScrW_hud", ScrW(), true, FCVAR_ARCHIVE)

------------------------------------------------------------------------
-- Curved Plane Mesh (front-facing mode)
------------------------------------------------------------------------
local function CurvedPlane(w, h, segments, degrees, matrix)
	matrix = matrix or Matrix()
	degrees = math.rad(degrees)
	local mesh = Mesh()
	local verts = {}
	local startAng = (math.pi - degrees) / 2
	local segLen = 0.5 * math.tan(degrees / segments)
	local scale = w / (segLen * segments)
	local zoffset = math.sin(startAng) * 0.5 * scale
	for i = 0, segments - 1 do
		local fraction = i / segments
		local nextFraction = (i + 1) / segments
		local ang1 = startAng + fraction * degrees
		local ang2 = startAng + nextFraction * degrees
		local x1 = math.cos(ang1) * -0.5 * scale
		local x2 = math.cos(ang2) * -0.5 * scale
		local z1 = math.sin(ang1) * 0.5 * scale - zoffset
		local z2 = math.sin(ang2) * 0.5 * scale - zoffset
		verts[#verts + 1] = { pos = matrix * Vector(x1, 0, z1), u = fraction, v = 0 }
		verts[#verts + 1] = { pos = matrix * Vector(x2, 0, z2), u = nextFraction, v = 0 }
		verts[#verts + 1] = { pos = matrix * Vector(x2, h, z2), u = nextFraction, v = 1 }
		verts[#verts + 1] = { pos = matrix * Vector(x2, h, z2), u = nextFraction, v = 1 }
		verts[#verts + 1] = { pos = matrix * Vector(x1, h, z1), u = fraction, v = 1 }
		verts[#verts + 1] = { pos = matrix * Vector(x1, 0, z1), u = fraction, v = 0 }
	end
	mesh:BuildFromTriangles(verts)
	return mesh
end

------------------------------------------------------------------------
-- CRT Barrel Distortion Mesh (arm modes)
------------------------------------------------------------------------
local function RebuildCRTMesh(w, h, distortion)
	local meshObj = Mesh()
	local cols, rows = 16, 12
	local cellW, cellH = w / cols, h / rows
	mesh.Begin(meshObj, MATERIAL_QUADS, cols * rows)
	for y = 0, rows - 1 do
		for x = 0, cols - 1 do
			local function GetVert(ix, iy)
				local u, v = ix / cols, iy / rows
				local cu, cv = u - 0.5, v - 0.5
				local r2 = cu * cu + cv * cv
				local distFactor = 1.0 + (distortion * r2 * 2.5)
				local nu = 0.5 + cu * distFactor
				local nv = 0.5 + cv * distFactor
				local alpha = 255
				if nu < 0 or nu > 1 or nv < 0 or nv > 1 then alpha = 0 end
				return (ix * cellW) - w / 2, (iy * cellH) - h / 2, 0, 1 - nu, nv, alpha
			end
			local x1, y1, z1, u1, v1, a1 = GetVert(x, y)
			local x2, y2, z2, u2, v2, a2 = GetVert(x + 1, y)
			local x3, y3, z3, u3, v3, a3 = GetVert(x + 1, y + 1)
			local x4, y4, z4, u4, v4, a4 = GetVert(x, y + 1)
			mesh.Position(Vector(x1, y1, z1)); mesh.Color(255, 255, 255, a1); mesh.TexCoord(0, u1, v1); mesh.AdvanceVertex()
			mesh.Position(Vector(x2, y2, z2)); mesh.Color(255, 255, 255, a2); mesh.TexCoord(0, u2, v2); mesh.AdvanceVertex()
			mesh.Position(Vector(x3, y3, z3)); mesh.Color(255, 255, 255, a3); mesh.TexCoord(0, u3, v3); mesh.AdvanceVertex()
			mesh.Position(Vector(x4, y4, z4)); mesh.Color(255, 255, 255, a4); mesh.TexCoord(0, u4, v4); mesh.AdvanceVertex()
		end
	end
	mesh.End()
	return meshObj
end

------------------------------------------------------------------------
-- Shared RT and Material
------------------------------------------------------------------------
local rt = GetRenderTarget("vrmod_hud", vrScrW:GetInt(), vrScrH:GetInt(), false)
local mat = Material("!vrmod_hud")
mat = not mat:IsError() and mat or CreateMaterial("vrmod_hud", "UnlitGeneric", {
	["$basetexture"] = rt:GetName(),
	["$translucent"] = 1,
	["$vertexalpha"] = 1,
	["$vertexcolor"] = 1,
	["$nocull"] = 1,
})

------------------------------------------------------------------------
-- Beam material for interactive pointer (our own, not cl_ui's)
------------------------------------------------------------------------
local beamRT = GetRenderTarget("vrmod_hud_interact_beam", 64, 64, false)
local beamMat = CreateMaterial("vrmod_hud_interact_beam", "UnlitGeneric", {
	["$basetexture"] = beamRT:GetName(),
	["$ignorez"] = 1,
	["$vertexcolor"] = 1,
	["$vertexalpha"] = 1,
})
local beamRTInitialized = false
local function EnsureBeamRT()
	if beamRTInitialized then return end
	beamRTInitialized = true
	render.PushRenderTarget(beamRT)
	render.Clear(255, 255, 255, 255)
	render.PopRenderTarget()
end

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------
local hudMeshes = {}
local hudMesh = nil
local function noop() end
-- Install-once render dispatcher. The old pattern (capture `orig`, replace
-- VRUtilRenderMenuSystem, restore in RemoveHUD, recapture in AddHUD) formed
-- mutual-recursion cycles when another addon wrapped the same global and
-- both sides re-wrapped after a restore/recapture -> stack overflow.
-- This wrapper installs exactly once per file load, is never restored, and
-- dispatches through hudDrawFn (nil = HUD off).
local hudDrawFn = nil
local wrapInstalled = false
local wrapToken = {}
local wrapFrame, wrapDepth = -1, 0
local FrameNumber = FrameNumber
local function EnsureWrapInstalled()
	if wrapInstalled then return end
	wrapInstalled = true
	-- Newest file instance wins; stale wrappers from autorefresh go inert.
	g_VR.hudWrapToken = wrapToken
	local base = VRUtilRenderMenuSystem or noop
	VRUtilRenderMenuSystem = function()
		-- Frame-reset depth guard: legit calls (one per eye pass) are
		-- sequential and return to 0; recursion through a foreign wrapper
		-- cycle nests past the cap instead of overflowing the stack.
		-- Self-heals next frame even if base() errors mid-call.
		local fn = FrameNumber()
		if fn ~= wrapFrame then
			wrapFrame = fn
			wrapDepth = 0
		end
		if wrapDepth > 4 then return end
		wrapDepth = wrapDepth + 1
		if hudDrawFn and g_VR.hudWrapToken == wrapToken then hudDrawFn() end
		base()
		wrapDepth = wrapDepth - 1
	end
end
local convars, convarValues = vrmod.GetConvars()

local armHUD = {
	forearmBoneIndex = -1,
	crtMesh = nil,
	crtLastParams = { w = 0, h = 0, dist = 0 },
	hudWidth = 400,
	hudHeight = 300,
}

local HUD_MODE_FRONT = 0
local HUD_MODE_LEFT  = 1
local HUD_MODE_RIGHT = 2

local HUD_ATTACH_FOREARM = 0
local HUD_ATTACH_HAND    = 1

local HUD_INTERACT_RELOAD    = 0
local HUD_INTERACT_QUICKMENU = 1
local HUD_INTERACT_DISABLED  = 2

local ARM_BONE_NAMES = {
	[HUD_MODE_LEFT]  = "ValveBiped.Bip01_L_Forearm",
	[HUD_MODE_RIGHT] = "ValveBiped.Bip01_R_Forearm",
}

------------------------------------------------------------------------
-- Get arm attachment pose
------------------------------------------------------------------------
local function GetArmPose()
	local mode = convarValues.vrmod_hudmode or HUD_MODE_FRONT
	local attach = convarValues.vrmod_hudattach or HUD_ATTACH_FOREARM

	if attach == HUD_ATTACH_HAND then
		if mode == HUD_MODE_LEFT then
			return vrmod.GetLeftHandPose()
		else
			return vrmod.GetRightHandPose()
		end
	end

	local ply = LocalPlayer()
	if not IsValid(ply) then return nil, nil end

	local boneName = ARM_BONE_NAMES[mode]
	if not boneName then return nil, nil end

	if armHUD.forearmBoneIndex == -1 then
		armHUD.forearmBoneIndex = ply:LookupBone(boneName) or -1
	end

	if armHUD.forearmBoneIndex ~= -1 then
		local boneMatrix = ply:GetBoneMatrix(armHUD.forearmBoneIndex)
		if boneMatrix then
			local bonePos = boneMatrix:GetTranslation()
			-- Sanity gate: on death or addon ragdolls (L4D SI grabs etc.) the
			-- player entity's bones freeze at the last animated pose while the
			-- view moves on. If the forearm bone is nowhere near the tracked
			-- controller, the model is no longer following the player — fall
			-- through to the controller pose so the HUD doesn't hang frozen
			-- in the world. 4096 = 64u squared.
			local tracked = g_VR.tracking
			local hand = tracked and (mode == HUD_MODE_LEFT and tracked.pose_lefthand or tracked.pose_righthand)
			if not hand or bonePos:DistToSqr(hand.pos) < 4096 then return bonePos, boneMatrix:GetAngles() end
		end
	end

	if mode == HUD_MODE_LEFT then
		return vrmod.GetLeftHandPose()
	else
		return vrmod.GetRightHandPose()
	end
end

------------------------------------------------------------------------
-- Draw arm-attached HUD via 3D2D
------------------------------------------------------------------------
local function DrawArmHUD(pos, ang)
	local armScale = convarValues.vrmod_hudarmscale or 0.05
	local w = armHUD.hudWidth
	local h = armHUD.hudHeight
	local rtW = vrScrW:GetInt()
	local rtH = vrScrH:GetInt()

	cam.Start3D2D(pos, ang, armScale)
		local aspectRT = rtW / rtH
		local aspectHUD = w / h
		local drawW, drawH
		if aspectRT > aspectHUD then
			drawW = w
			drawH = w / aspectRT
		else
			drawH = h
			drawW = h * aspectRT
		end

		local bgAlpha = convarValues.vrmod_hudtestalpha or 0
		if bgAlpha > 0 then
			surface.SetDrawColor(0, 0, 0, bgAlpha)
			surface.DrawRect(-w / 2, -h / 2, w, h)
		end

		local crtAmt = convarValues.vrmod_hudcrt or 0
		if crtAmt > 0 then
			if not IsValid(armHUD.crtMesh)
				or armHUD.crtLastParams.w ~= drawW
				or armHUD.crtLastParams.h ~= drawH
				or math.abs(armHUD.crtLastParams.dist - crtAmt) > 0.01 then
				if IsValid(armHUD.crtMesh) then armHUD.crtMesh:Destroy() end
				armHUD.crtMesh = RebuildCRTMesh(drawW, drawH, crtAmt)
				armHUD.crtLastParams = { w = drawW, h = drawH, dist = crtAmt }
			end
			render.SetMaterial(mat)
			armHUD.crtMesh:Draw()
		else
			surface.SetDrawColor(255, 255, 255, 255)
			surface.SetMaterial(mat)
			surface.DrawTexturedRectUV(-drawW / 2, -drawH / 2, drawW, drawH, 1, 0, 0, 1)
		end
	cam.End3D2D()
end

------------------------------------------------------------------------
-- Interactive HUD Pointer System
-- Defined BEFORE AddHUD. Works in all modes (front + arm).
-- vrmod_hudinteract: 0=reload, 1=quickmenu, 2=disabled
------------------------------------------------------------------------
local hudInteractive = false
local hudCursorWorldPos = nil
local hudCursorX, hudCursorY = -1, -1
local hudLastWorldPos = nil
local hudLastWorldAng = nil

local dummyPopup = nil

local function EnableHUDInteraction()
	if hudInteractive then return end
	hudInteractive = true
	gui.EnableScreenClicker(true)
	
	-- Create an invisible popup to force VGUI to register InternalMousePressed on non-DFrame elements
	if not IsValid(dummyPopup) then
		dummyPopup = vgui.Create("DPanel")
		dummyPopup:SetSize(0,0)
		dummyPopup:MakePopup()
		dummyPopup:SetKeyboardInputEnabled(false)
		dummyPopup:SetMouseInputEnabled(false)
		dummyPopup:SetAlpha(0)
	end
end

local function DisableHUDInteraction()
	if not hudInteractive then return end
	hudInteractive = false
	hudCursorWorldPos = nil
	hudCursorX, hudCursorY = -1, -1
	gui.EnableScreenClicker(false)
	
	if IsValid(dummyPopup) then
		dummyPopup:Remove()
	end
end

local function UpdateHUDWorldPose(pos, ang)
	hudLastWorldPos = pos
	hudLastWorldAng = ang
end

-- General ray-plane intersection.
-- Returns t (distance along ray), or nil if no valid intersection.
local function RayPlaneIntersect(rayOrigin, rayDir, planePoint, planeNormal)
	local denom = planeNormal:Dot(rayDir)
	if math.abs(denom) < 0.0001 then return nil end -- parallel
	local t = planeNormal:Dot(planePoint - rayOrigin) / denom
	if t <= 0 then return nil end -- behind ray origin
	return t
end

local function TraceHandToHUD()
	if not hudLastWorldPos or not hudLastWorldAng then return nil, nil, nil end
	if not g_VR or not g_VR.tracking or not g_VR.tracking.pose_righthand then return nil, nil, nil end

	local handPos = g_VR.tracking.pose_righthand.pos
	local handDir = g_VR.tracking.pose_righthand.ang:Forward()
	local mode = convarValues.vrmod_hudmode or HUD_MODE_FRONT

	if mode == HUD_MODE_FRONT then
		-- Front mode: HUD plane faces the player.
		-- Plane is at hudLastWorldPos, normal = HMD forward (pointing away from player).
		-- Hand is behind the plane pointing forward — general intersection handles this.
		local normal = hudLastWorldAng:Forward()
		local t = RayPlaneIntersect(handPos, handDir, hudLastWorldPos, normal)
		if not t then return nil, nil, nil end

		local hitWorldPos = handPos + handDir * t

		-- Project hit offset onto HMD right/up to get screen coords.
		-- The HUD mesh spans rtW*scale wide and rtH*scale tall, centered.
		local toHit = hitWorldPos - hudLastWorldPos
		local hmdRight = hudLastWorldAng:Right()
		local hmdUp = hudLastWorldAng:Up()

		local rtW = vrScrW:GetInt()
		local rtH = vrScrH:GetInt()
		local hudScale = convarValues.vrmod_hudscale or 0.05
		local halfW = rtW * hudScale / 2
		local halfH = rtH * hudScale / 2

		local localX = toHit:Dot(hmdRight)
		local localY = toHit:Dot(-hmdUp) -- screen Y is inverted vs world up

		if math.abs(localX) > halfW or math.abs(localY) > halfH then
			return nil, nil, nil
		end

		local screenX = ((localX + halfW) / (halfW * 2)) * ScrW()
		local screenY = ((localY + halfH) / (halfH * 2)) * ScrH()

		return screenX, screenY, hitWorldPos
	else
		-- Arm mode: 3D2D plane, normal = ang:Up()
		local normal = hudLastWorldAng:Up()
		local t = RayPlaneIntersect(handPos, handDir, hudLastWorldPos, normal)
		if not t then return nil, nil, nil end

		local hitWorldPos = handPos + handDir * t

		local localPos = WorldToLocal(hitWorldPos, Angle(0, 0, 0), hudLastWorldPos, hudLastWorldAng)
		local armScale = convarValues.vrmod_hudarmscale or 0.05

		local localX = localPos.x / armScale
		local localY = -localPos.y / armScale

		local w = armHUD.hudWidth
		local h = armHUD.hudHeight
		local hudX = localX + w / 2
		local hudY = localY + h / 2

		if hudX < 0 or hudX > w or hudY < 0 or hudY > h then
			return nil, nil, nil
		end

		local screenX = (hudX / w) * ScrW()
		local screenY = (hudY / h) * ScrH()

		return screenX, screenY, hitWorldPos
	end
end

local function DrawHUDBeam()
	if not hudInteractive or not hudCursorWorldPos then return end
	if not g_VR.tracking or not g_VR.tracking.pose_righthand then return end

	EnsureBeamRT()
	render.SetMaterial(beamMat)
	render.DrawBeam(
		g_VR.tracking.pose_righthand.pos,
		hudCursorWorldPos,
		0.1, 0, 1,
		Color(100, 200, 255, 200)
	)
end

------------------------------------------------------------------------
-- RemoveHUD / AddHUD
------------------------------------------------------------------------
local function RemoveHUD()
	hook.Remove("VRMod_PreRender", "hud")
	hook.Remove("HUDShouldDraw", "vrmod_hud")
	-- Never restore VRUtilRenderMenuSystem: the permanent dispatcher stays
	-- installed and goes inert via hudDrawFn = nil.
	hudDrawFn = nil
end

local function AddHUD()
	RemoveHUD()
	if not g_VR.active or not convarValues.vrmod_hud then return end

	local mode = convarValues.vrmod_hudmode or HUD_MODE_FRONT

	armHUD.forearmBoneIndex = -1
	if IsValid(armHUD.crtMesh) then armHUD.crtMesh:Destroy() end
	armHUD.crtMesh = nil
	armHUD.crtLastParams = { w = 0, h = 0, dist = 0 }

	DisableHUDInteraction()

	-- Blacklist
	local blacklist = {}
	for k, v in ipairs(string.Explode(",", convarValues.vrmod_hudblacklist)) do
		blacklist[v] = #v > 0 and true or blacklist[v]
	end
	if table.Count(blacklist) > 0 then
		hook.Add("HUDShouldDraw", "vrmod_hud", function(name)
			if blacklist[name] then return false end
		end)
	end

	if mode == HUD_MODE_FRONT then
		local mtx = Matrix()
		mtx:Translate(Vector(0, 0, vrScrH:GetInt() * convarValues.vrmod_hudscale / 2))
		mtx:Rotate(Angle(0, -90, -90))
		local meshName = convarValues.vrmod_hudscale .. "_" .. convarValues.vrmod_hudcurve
		hudMeshes[meshName] = hudMeshes[meshName] or CurvedPlane(
			vrScrW:GetInt() * convarValues.vrmod_hudscale,
			vrScrH:GetInt() * convarValues.vrmod_hudscale,
			10, convarValues.vrmod_hudcurve, mtx
		)
		hudMesh = hudMeshes[meshName]

		hook.Add("VRMod_PreRender", "hud", function()
			if not g_VR.threePoints then return end
			render.PushRenderTarget(rt)
			render.OverrideAlphaWriteEnable(true, true)
			render.Clear(0, 0, 0, convarValues.vrmod_hudtestalpha, true, true)
			render.RenderHUD(0, 0, vrScrW:GetInt(), vrScrH:GetInt())
			render.OverrideAlphaWriteEnable(false)
			render.PopRenderTarget()
			mtx:Identity()
			mtx:Translate(g_VR.tracking.hmd.pos + g_VR.tracking.hmd.ang:Forward() * convarValues.vrmod_huddistance)
			mtx:Rotate(g_VR.tracking.hmd.ang)
		end)

		hudDrawFn = function()
			-- Store HUD world pose for pointer: center of HUD plane + HMD angles
			if g_VR.tracking and g_VR.tracking.hmd then
				local hudPos = g_VR.tracking.hmd.pos + g_VR.tracking.hmd.ang:Forward() * convarValues.vrmod_huddistance
				UpdateHUDWorldPose(hudPos, g_VR.tracking.hmd.ang)
			end

			render.SetMaterial(mat)
			cam.PushModelMatrix(mtx)
			render.DepthRange(0, 0.01)
			hudMesh:Draw()
			render.DepthRange(0, 1)
			cam.PopModelMatrix()

			DrawHUDBeam()
		end

		EnsureWrapInstalled()
	else
		hook.Add("VRMod_PreRender", "hud", function()
			if not g_VR.threePoints then return end
			render.PushRenderTarget(rt)
			render.OverrideAlphaWriteEnable(true, true)
			render.Clear(0, 0, 0, convarValues.vrmod_hudtestalpha, true, true)
			render.RenderHUD(0, 0, vrScrW:GetInt(), vrScrH:GetInt())
			render.OverrideAlphaWriteEnable(false)
			render.PopRenderTarget()
		end)

		hudDrawFn = function()
			local armPos, armAng = GetArmPose()
			if armPos and armAng then
				local offsetPos = Vector(
					convarValues.vrmod_hudarm_x or 5,
					convarValues.vrmod_hudarm_y or -3,
					convarValues.vrmod_hudarm_z or 1
				)
				local offsetAng = Angle(
					convarValues.vrmod_hudarm_p or 0,
					convarValues.vrmod_hudarm_yaw or 180,
					convarValues.vrmod_hudarm_r or 90
				)
				local finalPos, finalAng = LocalToWorld(offsetPos, offsetAng, armPos, armAng)
				UpdateHUDWorldPose(finalPos, finalAng)
				DrawArmHUD(finalPos, finalAng)
				DrawHUDBeam()
			end
		end

		EnsureWrapInstalled()
	end
end

------------------------------------------------------------------------
-- ConVars
------------------------------------------------------------------------
vrmod.AddCallbackedConvar("vrmod_hud", nil, 1, nil, nil, nil, nil, tobool, AddHUD)
vrmod.AddCallbackedConvar("vrmod_hudblacklist", nil, "", nil, nil, nil, nil, nil, AddHUD)
vrmod.AddCallbackedConvar("vrmod_hudcurve", nil, "60", nil, nil, nil, nil, tonumber, AddHUD)
vrmod.AddCallbackedConvar("vrmod_hudscale", nil, "0.05", nil, nil, nil, nil, tonumber, AddHUD)
vrmod.AddCallbackedConvar("vrmod_huddistance", nil, "60", nil, nil, nil, nil, tonumber)
vrmod.AddCallbackedConvar("vrmod_hudtestalpha", nil, "0", nil, nil, nil, nil, tonumber)
vrmod.AddCallbackedConvar("vrmod_hudmode", nil, "0", nil, nil, nil, nil, tonumber, AddHUD)
vrmod.AddCallbackedConvar("vrmod_hudattach", nil, "0", nil, nil, nil, nil, tonumber, AddHUD)
vrmod.AddCallbackedConvar("vrmod_hudarmscale", nil, "0.05", nil, nil, nil, nil, tonumber, AddHUD)
vrmod.AddCallbackedConvar("vrmod_hudcrt", nil, "0.15", nil, nil, nil, nil, tonumber)
vrmod.AddCallbackedConvar("vrmod_hudarm_x", nil, "5", nil, nil, nil, nil, tonumber)
vrmod.AddCallbackedConvar("vrmod_hudarm_y", nil, "-3", nil, nil, nil, nil, tonumber)
vrmod.AddCallbackedConvar("vrmod_hudarm_z", nil, "1", nil, nil, nil, nil, tonumber)
vrmod.AddCallbackedConvar("vrmod_hudarm_p", nil, "0", nil, nil, nil, nil, tonumber)
vrmod.AddCallbackedConvar("vrmod_hudarm_yaw", nil, "180", nil, nil, nil, nil, tonumber)
vrmod.AddCallbackedConvar("vrmod_hudarm_r", nil, "90", nil, nil, nil, nil, tonumber)
vrmod.AddCallbackedConvar("vrmod_hudinteract", nil, "0", nil, nil, nil, nil, tonumber)

------------------------------------------------------------------------
-- Interactive cursor tracking (Think)
------------------------------------------------------------------------
hook.Add("Think", "vrmod_hud_interactive_cursor", function()
	if not hudInteractive then return end
	if not g_VR or not g_VR.active then
		DisableHUDInteraction()
		return
	end

	local sx, sy, worldHit = TraceHandToHUD()
	if sx and sy then
		hudCursorX, hudCursorY = sx, sy
		hudCursorWorldPos = worldHit
		input.SetCursorPos(math.floor(sx), math.floor(sy))
	else
		hudCursorWorldPos = nil
		hudCursorX, hudCursorY = -1, -1
	end
end)

------------------------------------------------------------------------
-- Interactive input: hold-to-use + click routing
------------------------------------------------------------------------
hook.Add("VRMod_Input", "vrmod_hud_interactive", function(action, pressed)
	if not g_VR or not g_VR.active then return end
	if not convarValues.vrmod_hud then return end

	local interactMode = convarValues.vrmod_hudinteract or 0
	if interactMode == HUD_INTERACT_DISABLED then return end

	local toggleAction
	if interactMode == HUD_INTERACT_QUICKMENU then
		toggleAction = "boolean_spawnmenu"
	else
		toggleAction = "boolean_reload"
	end

	-- Hold to use: press = enable, release = disable
	if action == toggleAction then
		if pressed then
			EnableHUDInteraction()
		else
			DisableHUDInteraction()
		end
		return
	end

	if not hudInteractive then return end
	if hudCursorX < 0 or hudCursorY < 0 then return end

	local mouseButton = nil
	if action == "boolean_primaryfire" then
		mouseButton = MOUSE_LEFT
	elseif action == "boolean_secondaryfire" then
		mouseButton = MOUSE_RIGHT
	end

	if mouseButton then
		input.SetCursorPos(math.floor(hudCursorX), math.floor(hudCursorY))
		if pressed then
			gui.InternalMousePressed(mouseButton)
		else
			gui.InternalMouseReleased(mouseButton)
		end
	end
end)

------------------------------------------------------------------------
-- VR lifecycle
------------------------------------------------------------------------
hook.Add("VRMod_Start", "hud", function(ply)
	if ply ~= LocalPlayer() then return end
	AddHUD()
end)

hook.Add("VRMod_Exit", "hud", function(ply)
	if ply ~= LocalPlayer() then return end
	DisableHUDInteraction()
	RemoveHUD()
	if IsValid(armHUD.crtMesh) then armHUD.crtMesh:Destroy() end
	armHUD.crtMesh = nil
	armHUD.forearmBoneIndex = -1
end)