--[[
	cl_trackers_menu.lua
	Client > Trackers panel.

	Lists every tracker the game can currently see, whatever the source, and
	lets each one be labelled and assigned a role. Trackers arrive on "auto",
	which means they take part in FBT proximity matching at calibration -- so a
	plain 6-point setup needs nothing done here at all. Set a tracker to
	"object" and give it a label when you want to attach something to it.
]]
if SERVER then return end

local ROLE_CHOICES = {
	{ "auto",      "FBT (auto-assign)" },
	{ "pelvis",    "FBT - Waist (pinned)" },
	{ "leftfoot",  "FBT - Left Foot (pinned)" },
	{ "rightfoot", "FBT - Right Foot (pinned)" },
	{ "object",    "Object (attach by label)" },
	{ "off",       "Ignored" },
}

local ROLE_LABEL = {}
for i = 1, #ROLE_CHOICES do ROLE_LABEL[ROLE_CHOICES[i][1]] = ROLE_CHOICES[i][2] end

local SOURCE_LABEL = { xr = "OpenXR", osc = "OSC" }

function vrmod.BuildTrackerPanel(parent)
	local statusForm = vgui.Create("DForm", parent)
	statusForm:SetName("External Trackers (SlimeVR / VMC)")
	statusForm:Dock(TOP)
	statusForm:DockMargin(5, 5, 5, 0)
	statusForm:SetExpanded(true)

	statusForm:CheckBox("Receive trackers over OSC", "vrmod_trackers_osc")
	statusForm:ControlHelp("SlimeVR: Settings > OSC > VRChat OSC Trackers. Point it at this port.")
	statusForm:NumSlider("OSC port", "vrmod_trackers_oscport", 1024, 65535, 0)
	statusForm:ControlHelp("Not 9000 -- face tracking already uses that. Toggle the checkbox off and on after changing.")

	local status = vgui.Create("DLabel", statusForm)
	status:Dock(TOP)
	status:DockMargin(4, 4, 4, 2)
	status:SetDark(true)
	statusForm:AddItem(status)

	local calForm = vgui.Create("DForm", parent)
	calForm:SetName("FBT Calibration")
	calForm:Dock(TOP)
	calForm:DockMargin(5, 5, 5, 0)
	calForm:SetExpanded(true)
	calForm:NumSlider("Match radius", "vrmod_trackers_calradius", 1, 48, 0)
	calForm:ControlHelp("How far from a bone an auto tracker can sit and still be accepted. Stand with feet apart when calibrating.")

	local viewForm = vgui.Create("DForm", parent)
	viewForm:SetName("Debug Display")
	viewForm:Dock(TOP)
	viewForm:DockMargin(5, 5, 5, 0)
	viewForm:SetExpanded(true)
	viewForm:CheckBox("Show tracker positions", "vrmod_trackers_debug")
	viewForm:ControlHelp("Draws a white cube at every tracker, with an orange line along its forward axis. Remote players' object trackers are blue.")
	viewForm:CheckBox("Show tracker names", "vrmod_trackers_debuglabels")
	viewForm:ControlHelp("Label and role above each cube. Useful for working out which physical tracker is which.")

	local listForm = vgui.Create("DForm", parent)
	listForm:SetName("Detected Trackers")
	listForm:Dock(TOP)
	listForm:DockMargin(5, 5, 5, 0)
	listForm:SetExpanded(true)

	local list = vgui.Create("DListView", listForm)
	list:Dock(TOP)
	list:SetTall(180)
	list:SetMultiSelect(false)
	list:AddColumn("Label"):SetWidth(90)
	list:AddColumn("Source"):SetWidth(55)
	list:AddColumn("Role"):SetWidth(120)
	list:AddColumn("State")
	listForm:AddItem(list)

	local editForm = vgui.Create("DForm", parent)
	editForm:SetName("Selected Tracker")
	editForm:Dock(TOP)
	editForm:DockMargin(5, 5, 5, 5)
	editForm:SetExpanded(true)

	local labelEntry = editForm:TextEntry("Label")
	labelEntry:SetEnabled(false)

	local roleBox = vgui.Create("DComboBox", editForm)
	roleBox:SetEnabled(false)
	for i = 1, #ROLE_CHOICES do roleBox:AddChoice(ROLE_CHOICES[i][2], ROLE_CHOICES[i][1]) end
	editForm:AddItem(roleBox)
	editForm:ControlHelp("Auto trackers are matched to waist and feet by distance during FBT calibration. Object trackers are excluded from FBT and looked up by label.")

	local applyBtn = editForm:Button("Apply")
	applyBtn:SetEnabled(false)

	local selectedId

	local function SelectedSlot()
		return selectedId and vrmod.GetTracker(selectedId) or nil
	end

	local function Refresh()
		if not IsValid(list) then return end

		local active = vrmod.TrackerReceiverActive and vrmod.TrackerReceiverActive()
		local trackers = vrmod.GetTrackers()
		status:SetText(string.format("Receiver: %s   Trackers: %d   FBT-eligible: %d",
			active and "listening" or "off", #trackers, g_VR.fbtTrackerCount or 0))
		status:SizeToContents()

		-- Rebuild rather than diff: this runs twice a second on an open menu
		-- and the list is a dozen rows at most.
		local keep = selectedId
		list:Clear()
		for i = 1, #trackers do
			local s = trackers[i]
			local state = "no pose"
			if s.pose and s.pose.pos then
				local p = s.pose.pos
				state = vrmod.IsTrackerLive(s)
					and string.format("%.0f %.0f %.0f", p.x, p.y, p.z) or "stale"
			elseif s.raw then
				state = s.raw.active and "waiting for VR" or "stale"
			end
			local line = list:AddLine(s.label, SOURCE_LABEL[s.source] or s.source,
				ROLE_LABEL[s.role] or s.role, state)
			line.slotId = s.id
			if s.id == keep then list:SelectItem(line) end
		end
	end

	function list:OnRowSelected(_, line)
		selectedId = line.slotId
		local s = SelectedSlot()
		if not s then return end
		labelEntry:SetEnabled(true)
		labelEntry:SetValue(s.label)
		roleBox:SetEnabled(true)
		roleBox:SetValue(ROLE_LABEL[s.role] or s.role)
		applyBtn:SetEnabled(true)
	end

	function applyBtn:DoClick()
		local s = SelectedSlot()
		if not s then return end
		local _, role = roleBox:GetSelected()
		vrmod.SetTrackerRole(s.id, role or s.role, labelEntry:GetValue())
		-- Push the new label set to the server now instead of waiting out the
		-- half-second scan, so an attached object follows the moment you hit
		-- Apply rather than a beat later.
		if vrmod.RefreshObjectTrackers then vrmod.RefreshObjectTrackers() end
		Refresh()
	end

	local nextRefresh = 0
	list.Think = function()
		local t = RealTime()
		if t < nextRefresh then return end
		nextRefresh = t + 0.5
		Refresh()
	end

	Refresh()
end