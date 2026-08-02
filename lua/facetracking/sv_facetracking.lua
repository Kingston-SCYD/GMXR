-- sv_facetracking.lua
-- Receives mapped flex data from clients, applies server-side, broadcasts to others.

util.AddNetworkString("ft_flex")

local IsValid = IsValid
local bufID, bufWT = {}, {}

net.Receive("ft_flex", function(_, ply)
	if not IsValid(ply) then return end

	local cnt = net.ReadUInt(8)
	if cnt == 0 or cnt > 128 then return end

	for i = 1, cnt do
		bufID[i] = net.ReadUInt(8)
		bufWT[i] = net.ReadUInt(8)
		ply:SetFlexWeight(bufID[i], bufWT[i] / 255)
	end

	local hasEye = net.ReadBool()
	local eyeTarget
	if hasEye then
		eyeTarget = net.ReadVector()
		ply:SetEyeTarget(eyeTarget)
	end

	net.Start("ft_flex")
		net.WriteEntity(ply)
		net.WriteUInt(cnt, 8)
		for i = 1, cnt do
			net.WriteUInt(bufID[i], 8)
			net.WriteUInt(bufWT[i], 8)
		end
		net.WriteBool(hasEye)
		if hasEye then net.WriteVector(eyeTarget) end
	net.SendOmit(ply)
end)