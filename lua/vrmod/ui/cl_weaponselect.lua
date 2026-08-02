-- VRMod Weapon Menu UI: wheel (default) + legacy HL2 grid, selectable via convar
if SERVER then return end

-- ============================================================================
-- Convar: 0 = radial wheel (default), 1 = legacy HL2 grid
-- ============================================================================
local cv_style = CreateClientConVar("vrmod_weaponmenu_style", "0", true, FCVAR_ARCHIVE,
	"Weapon menu style: 0 = radial wheel, 1 = legacy HL2 grid", 0, 1)
local cv_hand = CreateClientConVar("vrmod_menu_hand", "0", true, false,
	"Which hand menus spawn on: 0=right 1=left", 0, 1)

-- ============================================================================
-- Hot upvalues (Lua-side micro-opt: avoids per-frame _ENV lookups)
-- ============================================================================
local IsValid           = IsValid
local LocalPlayer       = LocalPlayer
local Angle             = Angle
local WorldToLocal      = WorldToLocal
local string_Explode    = string.Explode
local string_format     = string.format
local string_find       = string.find
local table_sort        = table.sort
local math_cos          = math.cos
local math_sin          = math.sin
local math_rad          = math.rad
local math_deg          = math.deg
local math_atan2        = math.atan2
local math_sqrt         = math.sqrt
local math_floor        = math.floor
local math_min          = math.min
local surface_SetDrawColor = surface.SetDrawColor
local surface_DrawPoly  = surface.DrawPoly
local surface_SetMaterial = surface.SetMaterial
local surface_DrawTexturedRect = surface.DrawTexturedRect
local draw_SimpleText   = draw.SimpleText
local draw_RoundedBox   = draw.RoundedBox
local input_SelectWeapon = input.SelectWeapon
local hook_Add          = hook.Add
local hook_Remove       = hook.Remove
local TEXT_ALIGN_LEFT   = TEXT_ALIGN_LEFT
local TEXT_ALIGN_RIGHT  = TEXT_ALIGN_RIGHT
local TEXT_ALIGN_CENTER = TEXT_ALIGN_CENTER
local TEXT_ALIGN_BOTTOM = TEXT_ALIGN_BOTTOM

-- ============================================================================
-- Reusable color cache (avoid per-frame Color() allocations)
-- ============================================================================
local C_BLACK_128   = Color(0, 0, 0, 128)
local C_BLACK_200   = Color(0, 0, 0, 200)
local C_BLACK_230   = Color(0, 0, 0, 230)
local C_YELLOW      = Color(255, 250, 0, 255)
local C_RED         = Color(255, 0, 0, 255)
local C_WHITE       = Color(255, 255, 255, 255)
local C_YELLOW_PURE = Color(255, 255, 0, 255)

-- ============================================================================
-- Fonts (created once at file load)
-- ============================================================================
-- Legacy grid fonts
surface.CreateFont("vrmod_HalfLife2", {
	font = "HalfLife2", extended = false, size = 50, weight = 0,
	blursize = 0, scanlines = 0, antialias = true,
})
surface.CreateFont("vrmod_HalfLife2Small", {
	font = "HalfLife2", extended = false, size = 25, weight = 0,
	blursize = 0, scanlines = 0, antialias = true,
})
surface.CreateFont("vrmod_Verdana37", {
	font = "Verdana", size = 37, weight = 600, antialias = true,
})

-- Wheel fonts (unique name per family — surface.CreateFont is a no-op on existing names)
local WHEEL_FONT = "vrmod_font_normal"
local WHEEL_FONT_MID = "vrmod_font_mid"
local WHEEL_FONT_SMALL = "vrmod_font_small"
local function RebuildWheelFonts(family)
	local tag = family:gsub("%s", "")
	WHEEL_FONT = "vrmod_wfn_" .. tag
	WHEEL_FONT_MID = "vrmod_wfm_" .. tag
	WHEEL_FONT_SMALL = "vrmod_wfs_" .. tag
	surface.CreateFont(WHEEL_FONT, { font = family, size = 20, antialias = true })
	surface.CreateFont(WHEEL_FONT_MID, { font = family, size = 16, weight = 600, antialias = true })
	surface.CreateFont(WHEEL_FONT_SMALL, { font = family, size = 12, antialias = true })
end
local cv_hud_font = CreateClientConVar("vrmod_hud_font", "Trebuchet MS", true, false, "Font family for VR weapon menu")
RebuildWheelFonts(cv_hud_font:GetString())
cvars.AddChangeCallback("vrmod_hud_font", function(_, _, val) RebuildWheelFonts(val) end, "vrmod_weaponselect")

-- Weapon menu color (mutates C_YELLOW / C_YELLOW_PURE in-place so all draw refs update)
local cv_hud_color = CreateClientConVar("vrmod_hud_color", "255,250,0,255", true, false, "Primary color for VR weapon menu")
local function UpdateMenuColor(str)
	local r, g, b, a = string.match(str, "(%d+),(%d+),(%d+),(%d+)")
	if not r then return end
	r, g, b, a = tonumber(r), tonumber(g), tonumber(b), tonumber(a)
	C_YELLOW.r, C_YELLOW.g, C_YELLOW.b, C_YELLOW.a = r, g, b, a
	C_YELLOW_PURE.r, C_YELLOW_PURE.g, C_YELLOW_PURE.b, C_YELLOW_PURE.a = r, g, b, a
end
UpdateMenuColor(cv_hud_color:GetString())
cvars.AddChangeCallback("vrmod_hud_color", function(_, _, val) UpdateMenuColor(val) end, "vrmod_weaponselect")

-- ============================================================================
-- Shared state
-- ============================================================================
local open = false
local lastWeaponClass = nil

-- ============================================================================
-- Legacy HL2-symbol overrides for grid style
-- ============================================================================
local LEGACY_OVERRIDES = {
	weapon_smg1      = {label = "a", font = "vrmod_HalfLife2"},
	weapon_shotgun   = {label = "b", font = "vrmod_HalfLife2"},
	weapon_crowbar   = {label = "c", font = "vrmod_HalfLife2"},
	weapon_pistol    = {label = "d", font = "vrmod_HalfLife2"},
	weapon_357       = {label = "e", font = "vrmod_HalfLife2"},
	weapon_crossbow  = {label = "g", font = "vrmod_HalfLife2"},
	weapon_physgun   = {label = "h", font = "vrmod_HalfLife2"},
	weapon_rpg       = {label = "i", font = "vrmod_HalfLife2"},
	weapon_bugbait   = {label = "j", font = "vrmod_HalfLife2"},
	weapon_frag      = {label = "k", font = "vrmod_HalfLife2"},
	weapon_ar2       = {label = "l", font = "vrmod_HalfLife2"},
	weapon_physcannon = {label = "m", font = "vrmod_HalfLife2"},
	weapon_stunstick = {label = "n", font = "vrmod_HalfLife2"},
	weapon_slam      = {label = "o", font = "vrmod_HalfLife2"},
}

-- ============================================================================
-- WHEEL STYLE (radial) — icon rendering helpers
-- ============================================================================
local ICON_SIZE      = 44
local DEFAULT_ICON   = Material("icon32/hand_point_090.png")
local DEFAULT_MODEL  = "models/dav0r/hoverball.mdl"

local iconMaterials = {}
local rtCache       = {}
local wireMat       = CreateMaterial("vrmod_wireframe_yellow", "Wireframe", {
	["$basetexture"] = "models/debug/debugwhite",
	["$color"]       = "[3 3 0]",
})

-- One reusable clientside model for icon rendering
local tempEnt = ClientsideModel(DEFAULT_MODEL, RENDER_GROUP_OPAQUE_ENTITY)
tempEnt:SetNoDraw(true)

local function GetIconRT(className)
	local rt = rtCache[className]
	if not rt then
		rt = GetRenderTarget("vrmod_rt_" .. className, ICON_SIZE, ICON_SIZE)
		rtCache[className] = rt
	end
	return rt
end

function RenderWeaponToMaterial(className)
	local cached = iconMaterials[className]
	if cached then return cached end

	local wepDef   = weapons.GetStored(className)
	local worldMdl = wepDef and wepDef.WorldModel or ""
	if string_find(worldMdl, "^models/weapons/c_") then worldMdl = "" end
	local model = worldMdl ~= "" and worldMdl
		or (vrmod.MODEL_OVERRIDES and vrmod.MODEL_OVERRIDES[className])
		or DEFAULT_MODEL

	util.PrecacheModel(model)
	local rt = GetIconRT(className)
	if not rt then return DEFAULT_ICON end

	tempEnt:SetModel(model)
	local mins, maxs = tempEnt:GetRenderBounds()
	local center = (mins + maxs) * 0.5
	local radius = (maxs - mins):Length() * 0.5
	local camPos = center + Vector(radius, radius, radius)
	local camAng = (center - camPos):Angle()

	render.PushRenderTarget(rt)
		render.Clear(0, 0, 0, 0, true, true)
		cam.Start3D(camPos, camAng, 35, 0, 0, ICON_SIZE, ICON_SIZE)
			render.SuppressEngineLighting(true)
			render.SetColorModulation(3, 3, 0)
			render.SetBlend(1)
			render.MaterialOverride(wireMat)
			tempEnt:DrawModel()
			render.MaterialOverride(nil)
			render.SetColorModulation(1, 1, 1)
			render.SuppressEngineLighting(false)
		cam.End3D()
	render.PopRenderTarget()

	local mat = CreateMaterial("vrmod_icon_mat_" .. className, "UnlitGeneric", {
		["$basetexture"]  = rt:GetName(),
		["$color"]        = "[10 10 0]",
		["$vertexcolor"]  = 1,
		["$vertexalpha"]  = 1,
	})
	iconMaterials[className] = mat
	return mat
end

-- Annular slice (ring segment) polygon
local function drawSlice(cx, cy, innerR, outerR, startDeg, endDeg, segCount, col)
	local poly = {}
	local span = endDeg - startDeg
	local n = 0
	for i = 0, segCount do
		local ang = math_rad(startDeg + span * (i / segCount))
		n = n + 1
		poly[n] = { x = cx + math_cos(ang) * outerR, y = cy + math_sin(ang) * outerR }
	end
	for i = segCount, 0, -1 do
		local ang = math_rad(startDeg + span * (i / segCount))
		n = n + 1
		poly[n] = { x = cx + math_cos(ang) * innerR, y = cy + math_sin(ang) * innerR }
	end
	surface_SetDrawColor(col)
	surface_DrawPoly(poly)
end

local function DrawIconLayered(x, y, size, material, repeats, alphaStep, scaleStep)
	surface_SetMaterial(material)
	for i = 1, repeats do
		local scale = 1 + (i - 1) * scaleStep
		local alpha = 255 - (i - 1) * alphaStep
		if alpha < 0 then alpha = 0 end
		surface_SetDrawColor(255, 255, 0, alpha)
		local s = size * scale
		surface_DrawTexturedRect(x - s * 0.5, y - s * 0.5, s, s)
	end
end

-- ============================================================================
-- WHEEL STYLE: opener
-- ============================================================================
local function OpenWheel()
	local innerClick = false

	-- Collect & sort weapons (single pass, then sort)
	local flatItems = {}
	local n = 0
	for _, wep in ipairs(LocalPlayer():GetWeapons()) do
		n = n + 1
		flatItems[n] = {
			wep     = wep,
			class   = wep:GetClass(),
			label   = wep:GetPrintName(),
			slot    = wep:GetSlot(),
			slotPos = wep:GetSlotPos(),
		}
	end
	table_sort(flatItems, function(a, b)
		if a.slot ~= b.slot then return a.slot < b.slot end
		return a.slotPos < b.slotPos
	end)

	-- Group by slot
	local slotMap, slots = {}, {}
	for i = 1, n do
		local item = flatItems[i]
		local g = slotMap[item.slot]
		if not g then
			g = { slot = item.slot, items = {} }
			slotMap[item.slot] = g
			slots[#slots + 1] = g
		end
		g.items[#g.items + 1] = item
	end
	table_sort(slots, function(a, b) return a.slot < b.slot end)

	local chosenSlot
	local prev = {
		hoveredSlot = -1, hoveredItem = -1,
		health = -1, suit = -1, clip = -1, total = -1, alt = -1,
	}
	local ply = LocalPlayer()

	-- Position panel
	local tmpAng = Angle(0, g_VR.tracking.hmd.ang.yaw - 90, 60)
	local rh = cv_hand:GetBool() and g_VR.tracking.pose_lefthand or g_VR.tracking.pose_righthand
	local pos, ang = WorldToLocal(
		rh.pos + rh.ang:Forward() * 7 + tmpAng:Right() * -3.68 + tmpAng:Forward() * -5.45,
		tmpAng, g_VR.origin, g_VR.originAngle)

	VRUtilMenuOpen("weaponmenu", 512, 512, nil, false, pos, ang, 0.025, true, function()
		hook_Remove("PreRender", "vrutil_hook_renderweaponselect")
		open = false

		-- Inner-circle click toggles empty <-> last weapon
		if innerClick then
			local aw = ply:GetActiveWeapon()
			local activeClass = IsValid(aw) and aw:GetClass() or nil
			if activeClass ~= "weapon_vrmod_empty" then
				lastWeaponClass = activeClass
				local emptyWep = ply:GetWeapon("weapon_vrmod_empty")
				if IsValid(emptyWep) then input_SelectWeapon(emptyWep) end
			elseif lastWeaponClass and lastWeaponClass ~= "weapon_vrmod_empty" then
				local prevWep = ply:GetWeapon(lastWeaponClass)
				if IsValid(prevWep) then input_SelectWeapon(prevWep) end
			end
			return
		end

		local sel = slots[chosenSlot or prev.hoveredSlot]
		local chosen = sel and sel.items[prev.hoveredItem]
		if chosen and IsValid(chosen.wep) then input_SelectWeapon(chosen.wep) end
	end)

	hook_Add("PreRender", "vrutil_hook_renderweaponselect", function()
		if g_VR.menuFocus ~= "weaponmenu" then return end

		-- Tunables
		local CX, CY              = 256, 256
		local INNER_R             = 60
		local OUTER_R             = 140
		local SLOT_MIN_DIST       = 40
		local SLOT_MAX_DIST       = INNER_R + 20
		local ICON_RADIUS_FACTOR  = 0.9
		local PETAL_HOVER_RADIUS  = ICON_SIZE * 0.75
		local SLICE_SEGMENTS      = 64

		-- Stats
		local hSlot, hItem = -1, -1
		local health, suit = ply:Health(), ply:Armor()
		local clip, total, alt = 0, 0, 0
		local aw = ply:GetActiveWeapon()
		if IsValid(aw) then
			clip  = aw:Clip1()
			total = ply:GetAmmoCount(aw:GetPrimaryAmmoType())
			alt   = ply:GetAmmoCount(aw:GetSecondaryAmmoType())
		end

		-- Cursor polar coords
		local dx = g_VR.menuCursorX - CX
		local dy = g_VR.menuCursorY - CY
		local dist = math_sqrt(dx * dx + dy * dy)
		local angDeg = math_deg(math_atan2(dy, dx))
		if angDeg < 0 then angDeg = angDeg + 360 end

		-- Slot hover
		local nSlots = #slots
		if dist > SLOT_MIN_DIST and dist < SLOT_MAX_DIST then
			local segSize = 360 / nSlots
			local idx = math_floor(angDeg / segSize) + 1
			if idx >= 1 and idx <= nSlots then
				hSlot = idx
				chosenSlot = idx
			end
		end
		innerClick = dist <= INNER_R

		-- Petal hover
		if chosenSlot then
			local sel = slots[chosenSlot]
			local items = sel.items
			local itemCount = #items
			local arc = math_min(90, itemCount * 20)
			local startAngle = (chosenSlot - 1) * 360 / nSlots - arc * 0.5
			local iconR = OUTER_R * ICON_RADIUS_FACTOR
			local hoverR2 = PETAL_HOVER_RADIUS * PETAL_HOVER_RADIUS
			local divisor = itemCount == 1 and 1 or (itemCount - 1)
			for i = 1, itemCount do
				local a = startAngle + (itemCount == 1 and 0 or (i - 1) * arc / divisor)
				local rad = math_rad(a)
				local rx = CX + math_cos(rad) * iconR
				local ry = CY + math_sin(rad) * iconR
				local ddx = g_VR.menuCursorX - rx
				local ddy = g_VR.menuCursorY - ry
				if ddx * ddx + ddy * ddy <= hoverR2 then
					hItem = i
					break
				end
			end
		end

		-- Dirty check (explicit - faster than pairs)
		if hSlot == prev.hoveredSlot and hItem == prev.hoveredItem
			and health == prev.health and suit == prev.suit
			and clip == prev.clip and total == prev.total and alt == prev.alt then
			return
		end
		prev.hoveredSlot, prev.hoveredItem = hSlot, hItem
		prev.health, prev.suit = health, suit
		prev.clip, prev.total, prev.alt = clip, total, alt

		VRUtilMenuRenderStart("weaponmenu")

		render.SetWriteDepthToDestAlpha(false)
		draw.NoTexture()

		-- Outer ring
		surface_SetDrawColor(C_BLACK_200)
		do
			local poly, p = {}, 0
			for i = 0, 32 do
				local a = math_rad(i / 32 * 360)
				p = p + 1
				poly[p] = { x = CX + math_cos(a) * (OUTER_R + 20), y = CY + math_sin(a) * (OUTER_R + 20) }
			end
			surface_DrawPoly(poly)
		end

		-- Inner ring
		surface_SetDrawColor(C_BLACK_230)
		do
			local poly, p = {}, 0
			for i = 0, 64 do
				local a = math_rad(i / 64 * 360)
				p = p + 1
				poly[p] = { x = CX + math_cos(a) * INNER_R, y = CY + math_sin(a) * INNER_R }
			end
			surface_DrawPoly(poly)
		end

		-- Slot slices + labels
		local sliceAngle = 360 / nSlots
		for i = 1, nSlots do
			local slot = slots[i]
			local sa, ea = (i - 1) * sliceAngle, i * sliceAngle
			drawSlice(CX, CY, INNER_R, INNER_R + 20, sa, ea, SLICE_SEGMENTS,
				hSlot == i and C_BLACK_230 or C_BLACK_200)
			local mid = (sa + ea) * 0.5
			local rad = math_rad(mid)
			local lx = CX + math_cos(rad) * (INNER_R + 10)
			local ly = CY + math_sin(rad) * (INNER_R + 10)
			draw_SimpleText(slot.slot + 1, WHEEL_FONT_MID, lx, ly,
				hSlot == i and C_WHITE or C_YELLOW_PURE,
				TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end

		-- Petal icons
		if chosenSlot then
			local sel = slots[chosenSlot]
			local items = sel.items
			local itemCount = #items
			local arc = math_min(90, itemCount * 20)
			local startAng = (chosenSlot - 1) * 360 / nSlots - arc * 0.5
			local iconR = OUTER_R * ICON_RADIUS_FACTOR
			local divisor = itemCount == 1 and 1 or (itemCount - 1)
			for i = 1, itemCount do
				local a = startAng + (itemCount == 1 and 0 or (i - 1) * arc / divisor)
				local rad = math_rad(a)
				local rx = CX + math_cos(rad) * iconR
				local ry = CY + math_sin(rad) * iconR
				DrawIconLayered(rx, ry, ICON_SIZE, RenderWeaponToMaterial(items[i].class), 10, 0, 0.01)
			end
		end

		-- Center label
		local name = "Select Slot"
		if chosenSlot and hItem >= 1 then
			name = slots[chosenSlot].items[hItem].label
		elseif hSlot >= 1 then
			name = slots[hSlot].slot + 1
		end
		draw_SimpleText(name, WHEEL_FONT, CX, CY, C_WHITE, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

		-- Stats strip (HEALTH / SUIT / AMMO / ALT)
		local healthCol = (health > 19) and C_YELLOW or C_RED
		local ammoCol   = (clip == 0 and total == 0) and C_RED or C_YELLOW
		local function ds(x, w, label, val, col)
			draw_RoundedBox(6, x, 20, w, 45, C_BLACK_128)
			draw_SimpleText(label, WHEEL_FONT_SMALL, x + 10, 50, col)
			draw_SimpleText(val, WHEEL_FONT_MID, x + w - 10, 55, col, TEXT_ALIGN_RIGHT)
		end
		ds(20,  120, "HEALTH", health, healthCol)
		ds(160, 110, "SUIT",   suit,   C_YELLOW)
		ds(290, 130, "AMMO",   string_format("%d / %d", clip, total), ammoCol)
		ds(440, 70,  "ALT",    alt,    C_YELLOW)

		VRUtilMenuRenderEnd()
	end)
end

-- ============================================================================
-- LEGACY GRID STYLE (HL2-symbol weapon select)
-- ============================================================================
local function OpenGrid()
	-- Build sorted item list (single pass: collect, then sort by slot/slotPos)
	local items = {}
	local n = 0
	for _, wep in ipairs(LocalPlayer():GetWeapons()) do
		local class = wep:GetClass()
		local ov = LEGACY_OVERRIDES[class]
		local labelKey = ov and ov.label or wep:GetPrintName()
		n = n + 1
		items[n] = {
			title   = wep:GetPrintName(),
			label   = language.GetPhrase(labelKey),
			font    = ov and ov.font or "HudSelectionText",
			wep     = wep,
			slot    = wep:GetSlot(),
			slotPos = wep:GetSlotPos(),
		}
	end
	table_sort(items, function(a, b)
		if a.slot ~= b.slot then return a.slot < b.slot end
		return a.slotPos < b.slotPos
	end)

	-- Compute per-slot row index + pre-compute pixel coords + pre-split labels
	local buttonWidth, buttonHeight = 82, 53
	local gap = (512 - buttonWidth * 6) / 5  -- == 4
	local stride_x = buttonWidth + gap
	local stride_y = buttonHeight + gap
	local currentSlot, actualSlotPos = -1, 0
	for i = 1, n do
		local it = items[i]
		if it.slot ~= currentSlot then
			currentSlot = it.slot
			actualSlotPos = 0
		end
		it.actualSlotPos = actualSlotPos
		actualSlotPos = actualSlotPos + 1
		-- Cache pixel positions to avoid recomputation each frame
		it.bx = it.slot * stride_x
		it.by = 114 + it.actualSlotPos * stride_y
		it.tx = buttonWidth * 0.5 + it.bx
		-- Pre-explode label so we don't allocate every frame
		it.parts = string_Explode(" ", it.label, false)
	end

	local prev = { hoveredItem = -1, health = -1, suit = -1, clip = -1, total = -1, alt = -1 }
	local ply = LocalPlayer()

	-- Position panel (legacy offsets, relative to chosen hand)
	local tmpAng = Angle(0, g_VR.tracking.hmd.ang.yaw - 90, 45)
	local rhPos = cv_hand:GetBool() and g_VR.tracking.pose_lefthand.pos or g_VR.tracking.pose_righthand.pos
	local pos, ang = WorldToLocal(
		rhPos + tmpAng:Forward() * -9 + tmpAng:Right() * -11 + tmpAng:Up() * -7,
		tmpAng, g_VR.origin, g_VR.originAngle)

	VRUtilMenuOpen("weaponmenu", 512, 512, nil, false, pos, ang, 0.03, true, function()
		hook_Remove("PreRender", "vrutil_hook_renderweaponselect")
		open = false
		local h = prev.hoveredItem
		if items[h] and IsValid(items[h].wep) then
			input_SelectWeapon(items[h].wep)
		end
	end)

	hook_Add("PreRender", "vrutil_hook_renderweaponselect", function()
		-- Hovered cell
		local hItem = -1
		if g_VR.menuFocus == "weaponmenu" then
			local hSlot    = math_floor(g_VR.menuCursorX / 86)
			local hSlotPos = math_floor((g_VR.menuCursorY - 114) / 57)
			for i = 1, n do
				local it = items[i]
				if it.slot == hSlot and it.actualSlotPos == hSlotPos then
					hItem = i
					break
				end
			end
		end

		-- Stats
		local health, suit = ply:Health(), ply:Armor()
		local clip, total, alt = 0, 0, 0
		local wep = ply:GetActiveWeapon()
		if IsValid(wep) then
			clip  = wep:Clip1()
			total = ply:GetAmmoCount(wep:GetPrimaryAmmoType())
			alt   = ply:GetAmmoCount(wep:GetSecondaryAmmoType())
		end

		-- Dirty check
		if hItem == prev.hoveredItem and health == prev.health and suit == prev.suit
			and clip == prev.clip and total == prev.total and alt == prev.alt then
			return
		end
		prev.hoveredItem = hItem
		prev.health, prev.suit = health, suit
		prev.clip, prev.total, prev.alt = clip, total, alt

		VRUtilMenuRenderStart("weaponmenu")

		-- HEALTH
		local healthCol = (health > 19) and C_YELLOW or C_RED
		draw_RoundedBox(8, 0, 0, 145, 53, C_BLACK_128)
		draw_SimpleText("HEALTH", "HudSelectionText", 10, 45, healthCol, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM)
		draw_SimpleText(health,    "vrmod_HalfLife2", 140, 50, healthCol, TEXT_ALIGN_RIGHT, TEXT_ALIGN_BOTTOM)

		-- SUIT
		draw_RoundedBox(8, 149, 0, 130, 53, C_BLACK_128)
		draw_SimpleText("SUIT", "HudSelectionText", 165, 45, C_YELLOW, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM)
		draw_SimpleText(suit,   "vrmod_HalfLife2", 270, 50, C_YELLOW, TEXT_ALIGN_RIGHT, TEXT_ALIGN_BOTTOM)

		-- AMMO
		local ammoCol = (clip == 0) and C_RED or C_YELLOW
		draw_RoundedBox(8, 283, 0, 150, 53, C_BLACK_128)
		draw_SimpleText("AMMO", "HudSelectionText", 290, 45, ammoCol, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM)
		draw_SimpleText(clip,   "vrmod_HalfLife2", 338, 50, ammoCol, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM)
		draw_SimpleText(total,  "vrmod_HalfLife2Small", 429, 47, ammoCol, TEXT_ALIGN_RIGHT, TEXT_ALIGN_BOTTOM)

		-- ALT
		draw_RoundedBox(8, 437, 0, 75, 53, C_BLACK_128)
		draw_SimpleText("ALT", "HudSelectionText", 440, 45, C_YELLOW, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM)
		draw_SimpleText(alt,   "vrmod_HalfLife2", 512, 50, C_YELLOW, TEXT_ALIGN_RIGHT, TEXT_ALIGN_BOTTOM)

		-- Hovered item title
		draw_RoundedBox(8, 0, 57, 512, 53, C_BLACK_128)
		local hov = items[hItem]
		draw_SimpleText(hov and hov.title or "", "vrmod_Verdana37", 256, 85,
			C_YELLOW, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

		-- Weapon buttons
		for i = 1, n do
			local it = items[i]
			draw_RoundedBox(8, it.bx, it.by, buttonWidth, buttonHeight,
				hItem == i and C_BLACK_200 or C_BLACK_128)
			local parts = it.parts
			local pn = #parts
			local centerY = it.by + buttonHeight * 0.5
			local base = pn * 6 - 6
			for j = 1, pn do
				draw_SimpleText(parts[j], it.font, it.tx,
					centerY - (base - (j - 1) * 12),
					C_YELLOW, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			end
		end

		VRUtilMenuRenderEnd()
	end)
end

-- ============================================================================
-- Public API: route to chosen style
-- ============================================================================
function VRUtilWeaponMenuOpen()
	if open then return end
	open = true
	if cv_style:GetInt() == 1 then
		OpenGrid()
	else
		OpenWheel()
	end
end

function VRUtilWeaponMenuClose()
	VRUtilMenuClose("weaponmenu")
end