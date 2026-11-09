if SERVER then return end
-- 6 x 4 grid per page. Registrations (vrmod.AddInGameMenuItem, cl_api) are a
-- persistent name-keyed list; slot/slotPos are only a preference, resolved
-- here on every open, so nothing a registrant does can wipe or cover another.
local COLS, ROWS = 6, 4
local PER = COLS * ROWS
local BW, BH, PX, PY, TOP = 82, 53, 86, 57, 230 -- button size, pitch, grid top
local TAB_Y = TOP - PY -- page tabs: one row above the grid
local floor, min, max, sort = math.floor, math.min, math.max, table.sort
local COL_IDLE, COL_HOVER, COL_TEXT = Color(0, 0, 0, 128), Color(0, 0, 0, 200), Color(255, 255, 255, 255)
local open = false

local function ByPriority(a, b)
	if a.f ~= b.f then return a.f end -- built-ins (forceSlot) place first
	if a.want ~= b.want then return a.want < b.want end
	return a.o < b.o
end

-- Each item takes its requested cell or the next free one in reading order
-- (right, then down, then on to the next page). slotPos past the last row
-- carries onto later pages: row 4 = page 2 row 0. Empty pages are dropped.
local function Layout()
	local src, list = g_VR.menuItems or {}, {}
	for i = 1, #src do
		local it = src[i]
		local pos = max(floor(it.slotPos or 0), 0)
		list[i] = {
			it = it, f = it.forced == true, o = it.order or 0,
			want = floor(pos / ROWS) * PER + (pos % ROWS) * COLS + min(max(floor(it.slot or 0), 0), COLS - 1),
		}
	end
	sort(list, ByPriority)
	local cells, used = {}, {}
	for i = 1, #list do
		local c = list[i].want
		while cells[c] do c = c + 1 end
		cells[c] = list[i].it
		used[floor(c / PER)] = true
	end
	local pages = {}
	for p in pairs(used) do pages[#pages + 1] = p end
	sort(pages)
	return cells, pages
end

local function DrawLabel(text, x, y)
	local lines = string.Explode(" ", tostring(text or ""), false)
	local n = #lines
	for j = 1, n do
		draw.SimpleText(lines[j], "HudSelectionText", x + BW / 2, y + BH / 2 - (n * 6 - 6 - (j - 1) * 12), COL_TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end
end

function g_VR.MenuOpen()
	if hook.Call("VRMod_OpenQuickMenu") == false then return end
	if open then
		if VRUtilIsMenuOpen("miscmenu") then return end
		-- Self-heal: flag desynced from the real menu state (a prior
		-- open/close errored mid-way) — resync instead of wedging forever.
		open = false
	end

	open = true
	local cells, pages = Layout()
	local nTabs = min(#pages, COLS)
	local page, hovered, tab = 1, nil, -1
	local dPage, dHover, dTab = -1, false, -2 -- force the first draw

	VRUtilMenuOpen("miscmenu", 512, 512, nil, true, Vector(4, 3, 9.5), Angle(0, -90, 60), 0.03, true, function()
		hook.Remove("PreRender", "vrutil_hook_renderigm")
		open = false
		-- isfunction: items may carry nil funcs. g_VR.active: close-all during
		-- VR exit must not fire the hovered action.
		if hovered and isfunction(hovered.func) and g_VR.active then hovered.func() end
	end)

	hook.Add("PreRender", "vrutil_hook_renderigm", function()
		if not VRUtilIsMenuOpen("miscmenu") then
			hook.Remove("PreRender", "vrutil_hook_renderigm")
			return
		end

		hovered, tab = nil, -1
		if g_VR.menuFocus == "miscmenu" then
			local x, y = g_VR.menuCursorX, g_VR.menuCursorY
			local col = floor(x / PX)
			if col >= 0 and col < COLS then
				if y >= TOP then
					local row = floor((y - TOP) / PY)
					if row < ROWS and pages[page] then hovered = cells[pages[page] * PER + row * COLS + col] end
				elseif nTabs > 1 and y >= TAB_Y and col < nTabs then
					-- Hover selects: the quick menu fires on release, so there
					-- is no click to page with. The page sticks after leaving.
					tab, page = col, col + 1
				end
			end
		end

		if page == dPage and hovered == dHover and tab == dTab then return end
		dPage, dHover, dTab = page, hovered, tab
		VRUtilMenuRenderStart("miscmenu")
		if nTabs > 1 then
			for t = 1, nTabs do
				local x = (t - 1) * PX
				draw.RoundedBox(8, x, TAB_Y, BW, BH, t == page and COL_HOVER or COL_IDLE)
				DrawLabel("Page " .. t, x, TAB_Y)
			end
		end
		local base = pages[page] and pages[page] * PER
		if base then
			for c = 0, PER - 1 do
				local it = cells[base + c]
				if it then
					local x, y = (c % COLS) * PX, TOP + floor(c / COLS) * PY
					draw.RoundedBox(8, x, y, BW, BH, it == hovered and COL_HOVER or COL_IDLE)
					DrawLabel(it == hovered and it.hint or it.name, x, y)
				end
			end
		end
		VRUtilMenuRenderEnd()
	end)
end

function g_VR.MenuClose()
	VRUtilMenuClose("miscmenu")
end