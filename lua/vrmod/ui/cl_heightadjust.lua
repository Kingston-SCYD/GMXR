if SERVER then return end
local convars, convarValues = vrmod.GetConvars()
local mirrorYaw = 0

local MIRROR_DIST = 50
local MIRROR_W = 100
local MIRROR_H = 100
local RT_W, RT_H = 640, 640

local rt_mirror, mat_mirror
local math_abs = math.abs
local math_AngleDifference = math.AngleDifference
local math_deg = math.deg
local math_atan = math.atan

local function GetEyeHeight()
	return convarValues.characterEyeHeight or 66.8
end

local function AutoScale()
	g_VR.scale = GetEyeHeight() / ((g_VR.tracking.hmd.pos.z - g_VR.origin.z) / g_VR.scale)
	convars.vrmod_scale:SetFloat(g_VR.scale)
end

local function SetupMirror()
	if not g_VR or not g_VR.tracking then return end
	local ply = LocalPlayer()

	if not rt_mirror then
		rt_mirror = GetRenderTargetEx("rt_vrmod_heightmirror", RT_W, RT_H, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_SEPARATE, bit.bor(256, 32768), 0, IMAGE_FORMAT_BGRA8888)
		mat_mirror = CreateMaterial("mat_vrmod_heightmirror", "UnlitGeneric", {
			["$basetexture"] = rt_mirror:GetName(),
			["$model"] = "1",
		})
	end

	-- Yaw tracking + menu anchoring
	hook.Add("Think", "vrmod_heightmirror_update", function()
		if not g_VR or not g_VR.tracking then return end
		if not g_VR.menus or not g_VR.menus.heightmenu then return end

		local ad = math_AngleDifference(g_VR.tracking.hmd.ang.yaw, mirrorYaw)
		if math_abs(ad) > 45 then mirrorYaw = mirrorYaw + (ad > 0 and 45 or -45) end

		local mirrorPos = Vector(g_VR.tracking.hmd.pos.x, g_VR.tracking.hmd.pos.y, g_VR.origin.z)
		mirrorPos:Add(Angle(0, mirrorYaw, 0):Forward() * MIRROR_DIST)
		local menuAng = Angle(0, mirrorYaw - 90, 90)
		g_VR.menus.heightmenu.pos = mirrorPos + Vector(0, 0, 75) + menuAng:Forward() * -15
		g_VR.menus.heightmenu.ang = menuAng
	end)

	-- Reflected camera render + mirror quad draw
	hook.Add("PostDrawOpaqueRenderables", "vrmod_heightmirror_draw", function(depth, skybox)
		if depth or skybox then return end
		if not g_VR or not g_VR.active then return end
		if g_VR.specCamRendering then return end

		-- Mirror plane position
		local mirrorFwd = Angle(0, mirrorYaw, 0):Forward()
		local mirrorPos = Vector(g_VR.tracking.hmd.pos.x, g_VR.tracking.hmd.pos.y, g_VR.origin.z)
		mirrorPos:Add(mirrorFwd * MIRROR_DIST)
		local mirrorCenter = mirrorPos + Vector(0, 0, MIRROR_H * 0.5)

		-- Reflect eye position across mirror plane (vertical mirror, only flip horizontal)
		local eyePos = EyePos()
		local normX, normY = -mirrorFwd.x, -mirrorFwd.y
		local d = (eyePos.x - mirrorPos.x) * normX + (eyePos.y - mirrorPos.y) * normY
		local camPos = Vector(eyePos.x - 2 * d * normX, eyePos.y - 2 * d * normY, eyePos.z)

		-- Reflect view angles: look from reflected position toward mirror center
		local camAng = (mirrorCenter - camPos):Angle()

		-- Set up reflected camera — negative aspect provides the mirror horizontal flip
		-- FOV computed from camera distance so mirror content is properly framed
		local dist = camPos:Distance(mirrorCenter)
		local mirrorFov = math_deg(2 * math_atan(MIRROR_W * 0.5 / dist))
		cam.Start({
			x = 0, y = 0, w = RT_W, h = RT_H,
			type = "3D",
			fov = mirrorFov,
			aspect = -(RT_W / RT_H),
			origin = camPos,
			angles = camAng,
		})

		render.PushRenderTarget(rt_mirror)
		render.Clear(140, 160, 180, 255, true, true)
		render.CullMode(MATERIAL_CULLMODE_CW)

		-- Guard: prevent other hooks from doing bone work in nested render
		g_VR.specCamRendering = true

		-- Draw player model in mirror
		local prevAllow = g_VR.allowPlayerDraw
		g_VR.allowPlayerDraw = true
		local ogRO = ply.RenderOverride
		ply.RenderOverride = nil

		-- Temporarily clear VR eye positions so the character system's head-hide
		-- check (ep == g_VR.eyePosLeft or ep == g_VR.eyePosRight) fails,
		-- keeping the head bone visible in the mirror
		local savedL, savedR = g_VR.eyePosLeft, g_VR.eyePosRight
		g_VR.eyePosLeft, g_VR.eyePosRight = nil, nil

		ply:DrawModel()

		g_VR.eyePosLeft, g_VR.eyePosRight = savedL, savedR

		ply.RenderOverride = ogRO
		g_VR.allowPlayerDraw = prevAllow

		g_VR.specCamRendering = false
		render.CullMode(MATERIAL_CULLMODE_CCW)
		render.PopRenderTarget()
		cam.End3D()

		-- Draw mirror quad
		render.SetMaterial(mat_mirror)
		render.DrawQuadEasy(mirrorCenter, -mirrorFwd, MIRROR_W, MIRROR_H, color_white, 0)
	end)
end

function VRUtilOpenHeightMenu()
	if not g_VR.threePoints or VRUtilIsMenuOpen("heightmenu") then return end
	SetupMirror()
	VRUtilMenuOpen("heightmenu", 300, 512, nil, nil, Vector(), Angle(), 0.1, true, function()
		hook.Remove("Think", "vrmod_heightmirror_update")
		hook.Remove("PostDrawOpaqueRenderables", "vrmod_heightmirror_draw")
		hook.Remove("VRMod_Input", "vrmod_heightmenu_input")
	end)

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