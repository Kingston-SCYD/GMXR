if CLIENT then
	g_VR = g_VR or {}
	g_VR.menuFocus = false
	g_VR.menuCursorX = 0
	g_VR.menuCursorY = 0

	local str_match = string.match
	local tbl_remove = table.remove

	local _, convarValues = vrmod.GetConvars()
	local uioutline = CreateClientConVar("vrmod_ui_outline", 0, true, FCVAR_ARCHIVE, nil, 0, 1)
	local cv_pointer = CreateClientConVar("vrmod_pointer_hand", "0", true, false, "Which hand points at menus: 0=right 1=left", 0, 1)
	local cv_float = CreateClientConVar("vrmod_menu_float", "1", true, false, "Menus float in world instead of attaching to hand", 0, 1)
	local cv_qmfloat = CreateClientConVar("vrmod_quickmenu_float", "0", true, false, "Quick menu floats in world instead of attaching to hand", 0, 1)
	local cv_menuscale = CreateClientConVar("vrmod_menu_scale", "1", true, false, "Scale multiplier for popup menus", 0.1, 2)
	local rt_beam = GetRenderTarget("vrmod_rt_beam", 64, 64, false)
	local mat_beam = CreateMaterial("vrmod_mat_beam", "UnlitGeneric", {
		["$basetexture"] = rt_beam:GetName(),
		["$ignorez"] = 1,
		["$vertexcolor"] = 1,
		["$vertexalpha"] = 1
	})

	local BEAM_COLOR = Color(255, 255, 255, 255)
	local VEC_HALF = Vector(0.50, 0.50, 0.50)
	local VEC_ONE = Vector(1, 1, 1)

	local function UpdateBeamColor(colorString)
		local r, g, b, a = str_match(colorString, "(%d+),(%d+),(%d+),(%d+)")
		r, g, b, a = tonumber(r), tonumber(g), tonumber(b), tonumber(a)
		if not (r and g and b and a) then return end
		mat_beam:SetVector("$color", Vector(r / 255, g / 255, b / 255))
		mat_beam:SetFloat("$alpha", a / 255)
		render.PushRenderTarget(rt_beam)
		render.Clear(r, g, b, a)
		render.PopRenderTarget()
	end

	vrmod.AddCallbackedConvar("vrmod_test_ui_testver", nil, 0, nil, "", 0, 1, tonumber)
	vrmod.AddCallbackedConvar("vrmod_beam_color", nil, "203,109,109,255", nil, "", nil, nil, nil, function(newValue) UpdateBeamColor(newValue) end)
	g_VR.menus = {}
	local menus = g_VR.menus
	local menuOrder = {}
	local menusExist = false
	local prevFocusPanel = nil
	local floatAnchorPos, floatAnchorAng
	UpdateBeamColor(convarValues.vrmod_beam_color)

	function VRUtilMenuRenderPanel(uid)
		local m = menus[uid]
		if not m or not m.panel or not m.panel:IsValid() then return end
		render.PushRenderTarget(m.rt)
		cam.Start2D()
		render.Clear(0, 0, 0, 0, true, true)
		local oldclip = DisableClipping(false)
		render.SetWriteDepthToDestAlpha(false)
		m.panel:PaintManual()
		render.SetWriteDepthToDestAlpha(true)
		DisableClipping(oldclip)
		cam.End2D()
		render.PopRenderTarget()
	end

	function VRUtilMenuRenderStart(uid)
		render.PushRenderTarget(menus[uid].rt)
		cam.Start2D()
		render.Clear(0, 0, 0, 0, true, true)
		render.SetWriteDepthToDestAlpha(true)
	end

	function VRUtilMenuRenderEnd()
		cam.End2D()
		render.PopRenderTarget()
	end

	function VRUtilIsMenuOpen(uid)
		return menus[uid] ~= nil
	end

	function VRUtilRenderMenuSystem()
		if not menusExist then return end
		g_VR.menuFocus = false
		local leftHand = cv_pointer:GetBool()
		local pointerPose = leftHand and g_VR.tracking.pose_lefthand or g_VR.tracking.pose_righthand
		local attachPose  = leftHand and g_VR.tracking.pose_righthand or g_VR.tracking.pose_lefthand
		local cursorX, cursorY = 0, 0
		local menuFocusDist = 99999
		local menuFocusPanel = nil
		local menuFocusCursorWorldPos = nil
		local staleMenus = nil
		local tms = render.GetToneMappingScaleLinear()
		render.SetToneMappingScaleLinear(g_VR.view.dopostprocess and VEC_HALF or VEC_ONE)
		local menuScale = cv_menuscale:GetFloat()
		local pPos, pDir = pointerPose.pos, pointerPose.ang:Forward()
		for _, v in ipairs(menuOrder) do
			local uid = v.uid
			if v.panel then
				if not IsValid(v.panel) or not v.panel:IsVisible() then
					staleMenus = staleMenus or {}
					staleMenus[#staleMenus + 1] = uid
					continue
				end
			end

			local pos, ang = v.pos, v.ang
			if v.worldFixed then
				pos, ang = v.worldPos, v.worldAng
				v.scale = 0.02
			elseif uid ~= "heightmenu" then
				v.scale = 0.02
				if v.attachment then
					pos, ang = LocalToWorld(pos, ang, attachPose.pos, attachPose.ang)
				else
					pos, ang = LocalToWorld(pos, ang, g_VR.origin, g_VR.originAngle)
				end
			end
			if uid ~= "miscmenu" and uid ~= "weaponmenu" and uid ~= "heightmenu" then
				v.scale = v.scale * menuScale
			end

			cam.IgnoreZ(true)
			cam.Start3D2D(pos, ang, v.scale)
			surface.SetDrawColor(255, 255, 255, 255)
			surface.SetMaterial(v.mat)
			surface.DrawTexturedRect(0, 0, v.width, v.height)
			if uioutline:GetBool() then
				surface.SetDrawColor(255, 0, 0, 255)
				surface.DrawOutlinedRect(0, 0, v.width, v.height)
			end
			cam.End3D2D()
			cam.IgnoreZ(false)

			if v.cursorEnabled then
				local normal = ang:Up()
				local A = normal:Dot(pDir)
				if A < 0 then
					local B = normal:Dot(pos - pPos)
					if B < 0 then
						local dist = B / A
						local cursorWorldPos = pPos + pDir * dist
						local tp = WorldToLocal(cursorWorldPos, angle_zero, pos, ang)
						local invScale = 1 / v.scale
						cursorX = tp.x * invScale
						cursorY = -tp.y * invScale
						if cursorX > 0 and cursorY > 0 and cursorX < v.width and cursorY < v.height and dist < menuFocusDist then
							g_VR.menuFocus = uid
							menuFocusDist = dist
							menuFocusPanel = v.panel
							v.lastCursorX = cursorX
							v.lastCursorY = cursorY
							menuFocusCursorWorldPos = cursorWorldPos
						end
					end
				end
			end
		end

		render.SetToneMappingScaleLinear(tms)
		if menuFocusPanel ~= prevFocusPanel then
			if IsValid(prevFocusPanel) then prevFocusPanel:SetMouseInputEnabled(false) end
			if IsValid(menuFocusPanel) then menuFocusPanel:SetMouseInputEnabled(true) end
			gui.EnableScreenClicker(menuFocusPanel ~= nil)
			prevFocusPanel = menuFocusPanel
		end

		local focus = g_VR.menuFocus
		if focus and menus[focus] then
			g_VR.menuCursorX = menus[focus].lastCursorX
			g_VR.menuCursorY = menus[focus].lastCursorY
			input.SetCursorPos(menus[focus].lastCursorX, menus[focus].lastCursorY)
			render.SetMaterial(mat_beam)
			render.DrawBeam(pPos, menuFocusCursorWorldPos, 0.1, 0, 1, BEAM_COLOR)
		end

		render.DepthRange(0, 1)
		if staleMenus then
			for _, uid in ipairs(staleMenus) do VRUtilMenuClose(uid) end
		end
	end

	function VRUtilMenuOpen(uid, width, height, panel, attachment, pos, ang, scale, cursorEnabled, closeFunc)
		if menus[uid] and panel and menus[uid].panel ~= panel and IsValid(menus[uid].panel) then
			local n = 2
			while menus[uid .. n] do n = n + 1 end
			uid = uid .. n
		end
		VRUtilMenuClose(uid)
		local rt = GetRenderTarget("vrmod_rt_ui_" .. uid, width, height, false)
		local m = {
			uid = uid,
			panel = panel,
			closeFunc = closeFunc,
			attachment = attachment,
			pos = pos,
			ang = ang,
			scale = scale,
			cursorEnabled = cursorEnabled,
			rt = rt,
			width = width,
			height = height,
			lastCursorX = 0,
			lastCursorY = 0
		}
		menus[uid] = m
		menuOrder[#menuOrder + 1] = m

		local matName = "vrmod_mat_ui_" .. uid
		local mat = Material("!" .. matName)
		m.mat = not mat:IsError() and mat or CreateMaterial(matName, "UnlitGeneric", {
			["$basetexture"] = rt:GetName(),
			["$translucent"] = 1
		})

		if panel then
			panel:SetPaintedManually(true)
			VRUtilMenuRenderPanel(uid)
		end

		render.PushRenderTarget(rt)
		render.Clear(0, 0, 0, 0)
		render.PopRenderTarget()
		-- The quick menu ("miscmenu") has its own float toggle so it can keep
		-- the classic hand-attached feel while regular popups float, or float too.
		local floatThis = uid == "miscmenu" and cv_qmfloat:GetBool() or uid ~= "miscmenu" and cv_float:GetBool()
		if floatThis and attachment and g_VR.tracking then
			if not floatAnchorPos then
				local ap = cv_pointer:GetBool() and g_VR.tracking.pose_righthand or g_VR.tracking.pose_lefthand
				floatAnchorPos = Vector(ap.pos)
				floatAnchorAng = Angle(ap.ang)
			end
			m.worldPos, m.worldAng = LocalToWorld(pos, ang, floatAnchorPos, floatAnchorAng)
			m.worldFixed = true
		end
		menusExist = true
	end

	function VRUtilMenuClose(uid)
		-- Snapshot first: closeFuncs may open/close menus, and mutating
		-- `menus` during pairs() is undefined behavior in Lua 5.1.
		local closing, n = nil, 0
		for k, v in pairs(menus) do
			if k == uid or not uid then
				n = n + 1
				closing = closing or {}
				closing[n] = v
			end
		end

		for i = 1, n do
			local v = closing[i]
			-- Unregister BEFORE running closeFunc: if closeFunc errors, the
			-- entry must not survive with a poisoned closeFunc that re-errors
			-- on every future VRUtilMenuOpen/Close and permanently wedges the
			-- menu system.
			menus[v.uid] = nil
			for k2, v2 in ipairs(menuOrder) do
				if v2 == v then
					tbl_remove(menuOrder, k2)
					break
				end
			end

			if IsValid(v.panel) then v.panel:SetPaintedManually(false) end
			if v.closeFunc then
				local ok, err = pcall(v.closeFunc)
				if not ok then ErrorNoHalt("[VRMod UI] closeFunc error (" .. tostring(v.uid) .. "): " .. tostring(err) .. "\n") end
			end
		end

		if not next(menus) then
			hook.Remove("PostDrawTranslucentRenderables", "vrutil_hook_drawmenus")
			g_VR.menuFocus = false
			menusExist = false
			floatAnchorPos = nil
			floatAnchorAng = nil
			gui.EnableScreenClicker(false)
		end
	end

	-- Only position the OS cursor at the instant of press/release,
	-- never continuously — continuous SetCursorPos drags the real cursor
	-- across the screen every frame, triggering hover/focus on DComboBox
	-- dropdowns and other VGUI elements that spawn real popup panels.
	hook.Add("VRMod_Input", "ui", function(action, pressed)
		if not g_VR.menuFocus then return end
		local mouseButton
		if action == "boolean_primaryfire" or action == "boolean_car_mouse_left" then
			mouseButton = MOUSE_LEFT
		elseif action == "boolean_secondaryfire" or action == "boolean_car_mouse_right" then
			mouseButton = MOUSE_RIGHT
		elseif action == "boolean_sprint" then
			mouseButton = MOUSE_MIDDLE
		end
		if not mouseButton then return end

		local menu = menus[g_VR.menuFocus]
		if menu then
			input.SetCursorPos(menu.lastCursorX, menu.lastCursorY)
		end
		if pressed then
			gui.InternalMousePressed(mouseButton)
		else
			gui.InternalMouseReleased(mouseButton)
		end
		-- Panel may have been closed/changed by the click
		if g_VR.menuFocus then
			VRUtilMenuRenderPanel(g_VR.menuFocus)
		end
	end)
end

concommand.Add("vrmod_vgui_reset", function()
	-- nil uid = close all; VRUtilMenuClose snapshots internally, so this is
	-- safe even when closeFuncs open/close other menus mid-teardown.
	if g_VR and g_VR.menus then VRUtilMenuClose() end
end)