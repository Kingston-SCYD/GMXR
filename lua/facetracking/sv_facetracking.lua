-- sv_facetracking.lua
-- Receives mapped flex data from clients, applies server-side, broadcasts to others.
-- Gaze is relayed as two signed bytes; clients rebuild the eye target from
-- their own interpolated head pose, so the server never resolves it.

util.AddNetworkString("ft_flex")

local IsValid = IsValid
local bufID, bufWT = {}, {}

net.Receive("ft_flex", function(_, ply)
	if not IsValid(ply) then return end

	local cnt = net.ReadUInt(8)
	if cnt > 128 then return end

	for i = 1, cnt do
		local id = net.ReadUInt(8)
		local wt = net.ReadUInt(8)
		bufID[i], bufWT[i] = id, wt
		ply:SetFlexWeight(id, wt / 255)
	end

	local gaze = net.ReadBool()
	local gx, gy
	if gaze then
		gx = net.ReadInt(8)
		gy = net.ReadInt(8)
	end

	net.Start("ft_flex")
		net.WriteEntity(ply)
		net.WriteUInt(cnt, 8)
		for i = 1, cnt do
			net.WriteUInt(bufID[i], 8)
			net.WriteUInt(bufWT[i], 8)
		end
		net.WriteBool(gaze)
		if gaze then
			net.WriteInt(gx, 8)
			net.WriteInt(gy, 8)
		end
	net.SendOmit(ply)
end)