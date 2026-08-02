-- lua/vrmod/cl_dermapopups.lua
-- Mirrors VGUI popups onto VR menu quads.
-- Popups used to be keyed by class name ("popup_dframe"), so every DFrame
-- shared one uid -> one render target -> one menus[] entry. A second frame was
-- therefore invisible (it drew the first frame's RT) and only ever repainted
-- from the click handler, which is where the "one click behind" lag came from.
-- Each panel now owns a numbered slot; slots of dead panels are recycled so the
-- RT count stays bounded by peak concurrent popups.
if SERVER then return end

local meta = getmetatable(vgui.GetWorldPanel())
local orig = meta.MakePopup
local IsValid, timer_Simple = IsValid, timer.Simple
local ANCHOR_POS, ANCHOR_ANG = Vector(10, 10, 5), Angle(0, -90, 50)

local active = {}    -- [uid] = panel being mirrored each frame
local slotOwner = {} -- [slot] = panel owning "popup<slot>" and its RT

local function AcquireUID(panel)
	local uid = panel.vrmodPopupUID
	if uid then return uid end
	local n = #slotOwner
	local slot = n + 1
	for i = 1, n do
		if not IsValid(slotOwner[i]) then
			slot = i
			break
		end
	end
	slotOwner[slot] = panel
	uid = "popup" .. slot
	panel.vrmodPopupUID = uid
	return uid
end

local function GrayPaint(_, w, h)
	surface.SetDrawColor(175, 174, 187)
	surface.DrawRect(0, 0, w, h)
end

meta.MakePopup = function(self, ...)
	orig(self, ...)
	if not g_VR.threePoints or not IsValid(self) then return end
	local uid = AcquireUID(self)
	timer_Simple(0.1, function()
		if not IsValid(self) then return end
		self:SetPaintedManually(true)
		local panel = self
		local name = panel:GetName()
		if name == "DMenu" or name == "DImage" or name == "DPanel" then
			local child = panel:GetChildren()[1]
			if IsValid(child) then
				panel = child
				panel.Paint = GrayPaint
			end
		end
		active[uid] = panel
		VRUtilMenuOpen(uid, ScrW(), ScrH(), panel, true, ANCHOR_POS, ANCHOR_ANG, 0.03, true, function()
			active[uid] = nil
			timer_Simple(0.1, function()
				if not g_VR.active and IsValid(self) then
					self:MakePopup()
					self:RequestFocus()
				end
			end)
		end)
		VRUtilMenuRenderPanel(uid)
	end)
end

-- Repaint every mirrored popup, not just the last one registered.
hook.Add("Think", "update_all_popups", function()
	for uid, panel in pairs(active) do
		if IsValid(panel) then
			VRUtilMenuRenderPanel(uid)
		else
			active[uid] = nil
		end
	end
end)
