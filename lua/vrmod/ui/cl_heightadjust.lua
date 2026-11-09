if SERVER then return end
local convars, convarValues = vrmod.GetConvars()

-- Mirror = a clientside copy of the local player wearing their live pose
-- reflected across a vertical plane MIRROR_DIST ahead of the head. Rendered in
-- the scene like any other model, so it has real stereo depth, world lighting
-- and occlusion -- no render target, no flat quad.
local MIRROR_DIST = 50

local ENT = FindMetaTable("Entity")
local GetBoneMatrix, SetBoneMatrix = ENT.GetBoneMatrix, ENT.SetBoneMatrix
local GetFlexWeight, SetFlexWeight = ENT.GetFlexWeight, ENT.SetFlexWeight
local math_AngleDifference, math_rad, math_cos, math_sin = math.AngleDifference, math.rad, math.cos, math.sin
local render_CullMode = render.CullMode
local render_OverrideColorWriteEnable, render_OverrideDepthEnable = render.OverrideColorWriteEnable, render.OverrideDepthEnable
local render_SuppressEngineLighting = render.SuppressEngineLighting
local cam_Start3D, cam_End3D = cam.Start3D, cam.End3D
local FrameNumber, LocalPlayer, IsValid = FrameNumber, LocalPlayer, IsValid

-- Plane yaw (snaps in 45 deg steps) and its unit normal
local mirrorYaw, fx, fy = 0, 1, 0
-- reflect: world reflection across the plane, rebuilt per frame. boneMat: scratch.
local reflect, boneMat, clonePos = Matrix(), Matrix(), Vector()
-- Passed to VRUtilMenuOpen and mutated in place; charik aliases the angle
local menuPos, menuAng = Vector(), Angle(0, -90, 90)
local clone, owner, flexN, snapFrame = nil, nil, 0, 0

local function GetEyeHeight()
	return convarValues.characterEyeHeight or 66.8
end

local function AutoScale()
	g_VR.scale = GetEyeHeight() / ((g_VR.tracking.hmd.pos.z - g_VR.origin.z) / g_VR.scale)
	convars.vrmod_scale:SetFloat(g_VR.scale)
end

-- Reflected copy of the owner's bone cache. A reflection flips handedness,
-- so the clone draws with clockwise culling.
local function CopyBones(ent, n)
	for i = 0, n - 1 do
		local m = GetBoneMatrix(owner, i)
		if m then
			boneMat:Set(reflect)
			boneMat:Mul(m)
			SetBoneMatrix(ent, i, boneMat)
		end
	end
end

local function OwnerColor() return owner:GetPlayerColor() end

local function BuildClone(ply)
	if IsValid(clone) then clone:Remove() end
	owner = ply
	clone = ClientsideModel(ply:GetModel(), RENDERGROUP_OPAQUE)
	if not IsValid(clone) then clone = nil return end
	clone:SetNoDraw(true)
	clone:DrawShadow(false)
	clone:SetSkin(ply:GetSkin())
	clone:SetMaterial(ply:GetMaterial())
	for i = 0, ply:GetNumBodyGroups() - 1 do clone:SetBodygroup(i, ply:GetBodygroup(i)) end
	clone.GetPlayerColor = OwnerColor
	clone:AddCallback("BuildBonePositions", CopyBones)
	flexN = ply:GetFlexNum()
end

-- Once per frame: plane + menu anchor, a clean pose on the player, then the
-- clone's bones. Clearing the eye positions fails every first-person gate
-- (head hide, FBT, pose, bone scaler/hider) for this one setup, the same way
-- spectator and RT views see us. The DrawModel is what runs PrePlayerDraw
-- (renderPos + IK + face flexes), so it stays but writes nothing.
-- ShouldDrawLocalPlayer is cached per view setup: with viewmodels (and so
-- hands-only, where nothing else draws the body) it is false here and
-- DrawModel silently skips, leaving the plain anim pose at the real origin.
-- An empty cam push re-queries it, as cl_vrmod's body draw does; skipped
-- when player draw is already on (worldmodels).
local function Snapshot(ply)
	local tr = g_VR.tracking.hmd
	local ad = math_AngleDifference(tr.ang.yaw, mirrorYaw)
	if ad > 45 or ad < -45 then
		mirrorYaw = mirrorYaw + (ad > 0 and 45 or -45)
		local r = math_rad(mirrorYaw)
		fx, fy = math_cos(r), math_sin(r)
		menuAng.y = mirrorYaw - 90
	end
	local hp = tr.pos
	local px, py = hp.x + fx * MIRROR_DIST, hp.y + fy * MIRROR_DIST
	menuPos:SetUnpacked(px - fy * 15, py + fx * 15, g_VR.origin.z + 75)

	-- x' = x - 2(n.x - d)n : linear I - 2nn^T, translation 2dn
	local d2, xy = 2 * (fx * px + fy * py), -2 * fx * fy
	reflect:SetUnpacked(
		1 - 2 * fx * fx, xy, 0, d2 * fx,
		xy, 1 - 2 * fy * fy, 0, d2 * fy,
		0, 0, 1, 0,
		0, 0, 0, 1)

	local allow, ro, el, er = g_VR.allowPlayerDraw, ply.RenderOverride, g_VR.eyePosLeft, g_VR.eyePosRight
	g_VR.allowPlayerDraw, ply.RenderOverride, g_VR.eyePosLeft, g_VR.eyePosRight = true, nil, nil, nil
	if not allow then cam_Start3D() cam_End3D() end
	render_OverrideColorWriteEnable(true, false)
	render_OverrideDepthEnable(true, false)
	render_SuppressEngineLighting(true)
	ply:DrawModel()
	render_SuppressEngineLighting(false)
	render_OverrideDepthEnable(false, false)
	render_OverrideColorWriteEnable(false, false)
	g_VR.allowPlayerDraw, ply.RenderOverride, g_VR.eyePosLeft, g_VR.eyePosRight = allow, ro, el, er
	if not allow then cam_Start3D() cam_End3D() end

	for i = 0, flexN - 1 do SetFlexWeight(clone, i, GetFlexWeight(ply, i)) end
	-- Render origin only drives lighting; the bones carry the pose
	local p = ply:GetPos()
	local s = 2 * (fx * p.x + fy * p.y) - d2
	clonePos:SetUnpacked(p.x - s * fx, p.y - s * fy, p.z)
	clone:SetPos(clonePos)
	clone:SetupBones()
end

local function DrawMirror(depth, skybox)
	if depth or skybox or not g_VR.active then return end
	local ply = LocalPlayer()
	if not ply:Alive() then return end
	local fn = FrameNumber()
	if fn ~= snapFrame then
		snapFrame = fn
		if not IsValid(clone) or clone:GetModel() ~= ply:GetModel() then BuildClone(ply) end
		if clone then Snapshot(ply) end
	end
	if not clone then return end
	render_CullMode(MATERIAL_CULLMODE_CW)
	clone:DrawModel()
	render_CullMode(MATERIAL_CULLMODE_CCW)
end

local function CloseMirror()
	hook.Remove("PostDrawOpaqueRenderables", "vrmod_heightmirror_draw")
	hook.Remove("VRMod_Input", "vrmod_heightmenu_input")
	if IsValid(clone) then clone:Remove() end
	clone, owner = nil, nil
end

function VRUtilOpenHeightMenu()
	if not g_VR.threePoints or VRUtilIsMenuOpen("heightmenu") then return end
	VRUtilMenuOpen("heightmenu", 300, 512, nil, nil, menuPos, menuAng, 0.1, true, CloseMirror)
	hook.Add("PostDrawOpaqueRenderables", "vrmod_heightmirror_draw", DrawMirror)

	local buttons, renderControls
	buttons = {
		{
			x = 250, y = 0, w = 50, h = 50,
			text = "X", font = "Trebuchet24", text_x = 25, text_y = 15,
			enabled = true,
			fn = function()
				VRUtilMenuClose("heightmenu")
				convars.vrmod_heightmenu:SetBool(false)
			end
		},
		{
			x = 250, y = 200, w = 50, h = 50,
			text = "+", font = "Trebuchet24", text_x = 25, text_y = 15,
			enabled = not convarValues.vrmod_seated,
			fn = function()
				g_VR.scale = g_VR.scale + 0.5
				convars.vrmod_scale:SetFloat(g_VR.scale)
			end
		},
		{
			x = 250, y = 255, w = 50, h = 50,
			text = "Auto\nScale", font = "Trebuchet24", text_x = 25, text_y = 0,
			enabled = not convarValues.vrmod_seated,
			fn = function() AutoScale() end
		},
		{
			x = 250, y = 310, w = 50, h = 50,
			text = "-", font = "Trebuchet24", text_x = 25, text_y = 15,
			enabled = not convarValues.vrmod_seated,
			fn = function()
				g_VR.scale = g_VR.scale - 0.5
				convars.vrmod_scale:SetFloat(g_VR.scale)
			end
		},
		{
			x = 0, y = 200, w = 50, h = 50,
			text = convarValues.vrmod_seated and "Disable\nSeated\nOffset" or "Enable\nSeated\nOffset",
			font = "Trebuchet18", text_x = 25, text_y = -2,
			enabled = true,
			fn = function()
				local newState = not convarValues.vrmod_seated
				convars.vrmod_seated:SetBool(newState)
				buttons[5].text = newState and "Disable\nSeated\nOffset" or "Enable\nSeated\nOffset"
				buttons[2].enabled = not newState
				buttons[3].enabled = not newState
				buttons[4].enabled = not newState
				buttons[6].enabled = newState
				renderControls()
			end
		},
		{
			x = 0, y = 255, w = 50, h = 50,
			text = "Auto\nOffset", font = "Trebuchet18", text_x = 25, text_y = 5,
			enabled = convarValues.vrmod_seated,
			fn = function()
				local offset = GetEyeHeight() - (g_VR.tracking.hmd.pos.z - convarValues.vrmod_seatedoffset - g_VR.origin.z)
				convars.vrmod_seatedoffset:SetFloat(offset)
			end
		},
		{
			x = 0, y = 370, w = 50, h = 40,
			text = "+", font = "Trebuchet24", text_x = 25, text_y = 8,
			enabled = true,
			fn = function()
				convars.vrmod_charactereyeheight:SetFloat(math.Clamp(GetEyeHeight() + 1, 30, 100))
				renderControls()
			end
		},
		{
			x = 0, y = 415, w = 50, h = 40,
			text = "-", font = "Trebuchet24", text_x = 25, text_y = 8,
			enabled = true,
			fn = function()
				convars.vrmod_charactereyeheight:SetFloat(math.Clamp(GetEyeHeight() - 1, 30, 100))
				renderControls()
			end
		},
	}

	renderControls = function()
		VRUtilMenuRenderStart("heightmenu")
		surface.SetDrawColor(0, 0, 0, 255)
		draw.DrawText("note: disable seated mode\nand stand IRL when adjusting scale", "Trebuchet18", 3, -2, color_black, TEXT_ALIGN_LEFT)
		draw.DrawText("Eye Height", "Trebuchet18", 25, 345, color_white, TEXT_ALIGN_CENTER)
		draw.DrawText(string.format("%.1f", GetEyeHeight()), "Trebuchet18", 75, 390, color_white, TEXT_ALIGN_LEFT)
		for _, btn in ipairs(buttons) do
			surface.SetDrawColor(0, 0, 0, btn.enabled and 255 or 128)
			surface.DrawRect(btn.x, btn.y, btn.w, btn.h)
			draw.DrawText(btn.text, btn.font, btn.x + btn.text_x, btn.y + btn.text_y, color_white, TEXT_ALIGN_CENTER)
		end
		VRUtilMenuRenderEnd()
	end

	renderControls()
	hook.Add("VRMod_Input", "vrmod_heightmenu_input", function(action, pressed)
		if g_VR.menuFocus == "heightmenu" and action == "boolean_primaryfire" and pressed then
			for _, btn in ipairs(buttons) do
				if btn.enabled and g_VR.menuCursorX > btn.x and g_VR.menuCursorX < btn.x + btn.w and g_VR.menuCursorY > btn.y and g_VR.menuCursorY < btn.y + btn.h then
					btn.fn()
				end
			end
		end
	end)
end

hook.Add("VRMod_Start", "vrmod_OpenHeightMenuOnStartup", function(ply)
	if ply == LocalPlayer() and convars.vrmod_heightmenu:GetBool() then
		timer.Create("vrmod_HeightMenuStartupWait", 1, 0, function()
			if g_VR.threePoints then
				timer.Remove("vrmod_HeightMenuStartupWait")
				VRUtilOpenHeightMenu()
			end
		end)
	end
end)

concommand.Add("vrmod_openheightmenu", function()
	if g_VR and g_VR.threePoints then VRUtilOpenHeightMenu() end
end)