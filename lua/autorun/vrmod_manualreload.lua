-- vrmod_manualreload.lua (shared) -> lua/autorun/
-- Manual reloading: mag out/in + slide rack replace the canned reload.
-- Adapters: ArcCW, and a generic one for HL2 engine weapons + plain SWEPs.
-- Which weapons: per-class on/off (Weapon Fixer > Manual Reload, synced to the
-- server) or vrmod_manualreload_auto for every weapon with a magazine.
--
-- ArcCW gates through its own GetBuff_Hook -> hook.Call(buff, nil, wep, data):
-- global "Hook_PreReload" / "Hook_ShouldNotFire" block the canned reload and
-- unchambered fire without touching the base.
--
-- Generic: HL2 weapons are C++. Their Reload() can't be overridden from Lua and
-- ItemPostFrame auto-reloads whenever Clip1 == 0 with reserve left (and
-- auto-switches when clip and reserve are both 0) -- but only once
-- NextPrimaryFire has passed. So a shared StartCommand strips IN_RELOAD, strips
-- IN_ATTACK while empty/unchambered, and holds an empty gun's NextPrimaryFire
-- just ahead: neither ever runs, and Clip1 stays the truth (the native ammo
-- HUD reads 0 on an empty gun).
--
-- Visuals: BuildBonePositions callback on the player's viewmodel (the same
-- entity VRMod draws as g_VR.viewModel), identical on desktop and in VR.
--   mag   : mag bone + descendants matrix-scaled to zero while "vrmr_out"
--   slide : slide + children translated travel * pull along the barrel axis
-- The hand/pouch mag is a copy of the weapon's own VM model with every bone but
-- the mag subtree hidden, so it always matches the gun.
--
-- VR: reload button ejects. Left grip in the pouch takes a mag; it seats by
-- proximity to the gun's mag bone (ammo is drawn from reserve on insert). Left
-- grip on the slide and pull back to rack (racks at 90% travel). No slide set:
-- inserting into an empty gun also chambers.
-- Pump weapons (a bone named *pump*, HL2 adapter): the pouch hands out one
-- round (the model's shell bone), inserted at the loading gate (trapdoor) one
-- at a time; the pump is the slide and must be worked after every shot.
--
-- Foregrip mode 1: autorun_foregrip.lua hands managed viewmodel weapons'
-- support-hand grip to vrmod.manualreload (GripActive/GripZone/GripTarget/
-- OnGrip): model left hand, mirrored right hand, or the pump. A chambered
-- pump gun's pump is locked forward.
-- Revolvers (a bone named *cyl*, HL2 adapter): reload opens the cylinder,
-- again ejects (cases dump, live rounds go back to reserve), again shuts it; a
-- left grab on the open cylinder shuts it too, and with a live round in, so
-- does a push in or a flick of the gun; a downward slap spins it. The pouch
-- hands out the speed
-- loader (fills every empty chamber), else one round. Fired chambers stay
-- spent (NW2 "vrmr_spent") until ejected. No chamber, so never racked.
-- Grab hint (VR, vrmod_manualreload_hint): trigger held on a gun that can't
-- fire -> the gun part to work next glows (mag well / loading gate, slide /
-- pump, cylinder). The native ammo HUD shows the real count (0 when dry)
-- (it reads the real Clip1).
--
-- PC debug:  vrmod_manualreload 2   vrmod_manualreload_debug 1
--   vrmr out|in|rack|next|grab     ammo actions (bind next to R), grab = hold toggle
--   vrmr spin                      spin an open revolver cylinder
--   vrmr pull <0-1> | hide         visual-only slide hold / mag hide preview
--   vrmr mag|slide <bone|idx|none> override detected bone (saved per model)
--   vrmr travel <n> | axis x y z | lock 0/1 | reset | dump

AddCSLuaFile()

local IsValid = IsValid
-- NW_OUT doubles as "cylinder open" on revolvers.
-- NW_NORM: no mag part found, so the gun keeps its own reload (set by the
-- owner's client once its cfg is built; every gate stands aside).
local NW_OUT, NW_UNCH, NW_SPENT, NW_NORM = "vrmr_out", "vrmr_unch", "vrmr_spent", "vrmr_norm"
local OP_OUT, OP_IN, OP_RACK, OP_TRIG, OP_EJ, OP_SHUT, OP_FILL, OP_NORM = 0, 1, 2, 3, 4, 5, 6, 7
-- Per-class reload type on the wire (Auto = absent): mag / pump / revolver.
local KIND = {[0] = false, true, "rev", "semi"}

-- The client reads its own ConVar objects (assigned in the client section):
-- one native call, no userinfo round trip. The server reads userinfo.
local cvMode, cvAuto, cvNoSl
local function ModeOK(o)
	local m = cvMode and cvMode:GetInt() or o:GetInfoNum("vrmod_manualreload", 0)
	if m < 1 then return false end
	if m >= 2 then return true end
	if CLIENT then return g_VR.active == true end
	local v = vrmod
	return v and v.IsPlayerInVR and v.IsPlayerInVR(o) or false
end

------------------------------------------------------------------------------
-- Adapters
--   Eligible(w)          optional extra filter
--   Cap(w) Chamber(w)    rounds per mag / rounds held in chamber
--   Inf(w) Busy(w)       optional: infinite ammo / base mid-animation
--   Idle(w)              after rack, return the VM to its idle
--   Seq(e, w)            idle sequence for the mag-copy model
--   VM(w)                optional: expected VM model (guards weapon-switch lag)
--   slidelock            slide locks back on an empty / unchambered gun
------------------------------------------------------------------------------

local function anim(e, w, key)
	local a = w.Animations and w.Animations[key]
	local s = a and a.Source
	if istable(s) then s = s[1] end
	if isnumber(s) then return s end
	return isstring(s) and e:LookupSequence(s) or -1
end

local ARCCW = {
	name = "arccw",
	Eligible = function(w)
		return not (w.ShotgunReload or w.HybridReload or w.RevolverReload) and (w.Primary.ClipSize or 0) > 0
			and not (w:GetBuff_Override("Override_ShotgunReload") or w:HasBottomlessClip() or w:GetInUBGL())
	end,
	Cap = function(w) return w:GetCapacity() end,
	Chamber = function(w) return w:GetChamberSize() end,
	Inf = function(w) return w:HasInfiniteAmmo() end,
	Busy = function(w) return w:GetReloading() end,
	Idle = function(w) w:PlayIdleAnimation(true) end,
	VM = function(w) return w.ViewModel end,
	Seq = function(e, w)
		local s = anim(e, w, "idle")
		return s >= 0 and s or e:LookupSequence("idle")
	end,
}

-- class -> dry-fire sound (anything else gets the pistol click)
local DRY = {weapon_pistol = "Weapon_Pistol.Empty", weapon_smg1 = "Weapon_SMG1.Empty", weapon_ar2 = "Weapon_AR2.Empty", weapon_shotgun = "Weapon_Shotgun.Empty"}
local DRY_DEF = "Weapon_Pistol.Empty"

-- Everything that isn't ArcCW: HL2 engine weapons and plain SWEPs. Gated by
-- StartCommand + the empty-gun NextPrimaryFire hold, which works whether
-- Reload() lives in C++ or Lua.
local GEN = {
	name = "generic",
	slidelock = true,
	pumps = true,
	Eligible = function(w) return w:GetMaxClip1() > 0 end,
	Cap = function(w) return w:GetMaxClip1() end,
	Chamber = function() return 1 end,
	Idle = function(w) w:SendWeaponAnim(ACT_VM_IDLE) end,
	Seq = function(e) return e:SelectWeightedSequence(ACT_VM_IDLE) end,
}

-- Per-class opt in/out: true/false, nil = follow vrmod_manualreload_auto.
-- Client keeps its own table; the server holds each player's synced copy.
local clsTbl
local function Allowed(o, cls)
	local t = CLIENT and clsTbl or o.vrmrCls
	-- The client's one-shot sync (InitPostEntity) never arrives if an earlier
	-- hook on that event errors. Ask again until it does, every 2 s at most.
	if not t and SERVER and (o.vrmrAsk or 0) < CurTime() then
		o.vrmrAsk = CurTime() + 2
		net.Start("vrmr_cls")
		net.Send(o)
	end
	local v = t and t[cls]
	if v ~= nil then return v end
	if cvAuto then return cvAuto:GetBool() end
	return o:GetInfoNum("vrmod_manualreload_auto", 0) >= 1
end

-- Worldmodel mode has no viewmodel to work: the owner's client stands the
-- gun down (Managed nil there) and tells the server through NW_NORM, which
-- every gate already honours, so the gun keeps its own reload.
local function ManagedAny(w)
	local o = w:GetOwner()
	if not IsValid(o) or not o:IsPlayer() or not ModeOK(o) or not Allowed(o, w:GetClass()) then return end
	local ad = w.ArcCW and ARCCW or GEN
	if ad.Eligible and not ad.Eligible(w) then return end
	return ad
end
local function Managed(w)
	if CLIENT and g_VR and g_VR.wmActive then return end
	return ManagedAny(w)
end


-- The trigger drops the slide only while slide grabbing is off; with it on,
-- the slide has to be racked by hand. Userinfo, so both realms read it.
local function TrigChambers(o)
	if cvNoSl then return cvNoSl:GetBool() end
	return o:GetInfoNum("vrmod_manualreload_noslidegrab", 1) >= 1
end

-- Reload type from the VM model's bone names: *pump* = pump (true; one round
-- at a time into a tube, pumped after every shot), *cyl* = revolver ("rev"),
-- else magazine (false). Cached per model; same rule on both realms (server
-- reads its own VM's bones). A per-class override (Weapon Fixer: Auto / Mag /
-- Pump / Revolver) wins over the names.
local kindCache, pumpTbl, rackTbl = {}

-- Per-class "chambers on insert": no rack/pump needed after a load or a shot.
local function NoRack(o, cls)
	local t = CLIENT and rackTbl or o.vrmrNoRack
	return t and t[cls] or false
end
local function Kind(w, ad)
	if not ad.pumps then return false end
	-- nil = can't tell yet (owner / VM / bones not there): never cached, so a
	-- lookup right after spawn can't pin a revolver as a magazine for the map.
	local o = w:GetOwner()
	if not IsValid(o) or not o:IsPlayer() then return end
	local t = CLIENT and pumpTbl or o.vrmrPump
	local v = t and t[w:GetClass()]
	if v ~= nil then return v end
	local vm = o:GetViewModel(0)
	if not IsValid(vm) then return end
	local m = vm:GetModel()
	-- {kind from names, has a pump/forend, has a bolt}
	local r = kindCache[m]
	if r == nil then
		if vm:GetBoneCount() < 2 or vm:GetBoneName(0) == "__INVALIDBONE__" then return end
		local k, fore, bolt = false, false, false
		for i = 0, vm:GetBoneCount() - 1 do
			local n = vm:GetBoneName(i):lower()
			if n:find("pump", 1, true) then k = true
			elseif k ~= true and n:find("cyl", 1, true) then k = "rev" end
			if not (fore or n:find("bip01", 1, true) or n:find("hold", 1, true)) then
				fore = n:find("forend", 1, true) or n:find("fore_end", 1, true) or n:find("forearm", 1, true)
			end
			bolt = bolt or n:find("bolt", 1, true)
		end
		r = {k, k == true or fore and true, bolt and true}
		kindCache[m] = r
	end
	-- Base-declared tube feed (TacRP / ARC9 ShotgunReload): a pump/forend is
	-- pump action; a bolt and no pump is a semi-auto ("semi").
	if w.ShotgunReload then return (r[2] or not r[3]) or "semi" end
	return r[1]
end

-- Rounds in the tube/mag, excluding a chambered one.
local function Tube(w, real) return real - ((real > 0 and not w:GetNW2Bool(NW_UNCH)) and 1 or 0) end


------------------------------------------------------------------------------
-- Gates
------------------------------------------------------------------------------

hook.Add("Hook_PreReload", "vrmr", function(w)
	if not w:GetNW2Bool(NW_NORM) and Managed(w) then return true end
end)

-- ArcCW: an unchambered gun never fires; its trigger drops the slide
-- (chambers) when slide grabbing is off. ArcCW plays its own dry fire when the
-- clip is empty.
hook.Add("Hook_ShouldNotFire", "vrmr", function(w)
	if w:GetNW2Bool(NW_UNCH) and Managed(w) then
		if not TrigChambers(w:GetOwner()) then return true end
		w:SetNW2Bool(NW_UNCH, false)
		w:SetNextPrimaryFire(CurTime() + 0.3)
		if w.MyEmitSound then w:MyEmitSound("weapons/shotgun/shotgun_cock.wav", 75, 100, 1, CHAN_ITEM) end
		return true
	end
end)

-- Attack is stripped while empty/unchambered. Shotgun alt-fire would fire the
-- tube; SMG/AR2 alt-fire uses its own ammo and stays live.
local function StripFire(cmd, pump)
	cmd:RemoveKey(IN_ATTACK)
	if pump then cmd:RemoveKey(IN_ATTACK2) end
end

-- Server sounds emitted while a player's command runs are filtered from that
-- player (the engine assumes the client predicted them), so the owner gets
-- them by net instead.
local SND_DRY_ID, SND_SLIDE_ID = 0, 1
local SND_SLIDE = "weapons/shotgun/shotgun_cock.wav"
local function OwnerSound(ply, id)
	net.Start("vrmr_snd")
	net.WriteUInt(id, 1)
	net.Send(ply)
end

-- Empty: hold NextPrimaryFire just ahead, so ItemPostFrame's empty-clip
-- auto-reload and empty-gun auto-switch both wait for it. SetupMove, not
-- StartCommand: a client runs StartCommand once, while the command is built,
-- never when prediction replays it. Its hold was overwritten by the last
-- server value, so a client predicting more than the hold's 0.1s ahead (any
-- real ping) ran the canned reload/switch itself -- MP only: the host's
-- hold lands the frame it's set. ply.vrmrGen: the managed generic weapon,
-- refreshed by StartCommand each command.
hook.Add("SetupMove", "vrmr", function(ply)
	local w = ply.vrmrGen
	if w and w:IsValid() and w:Clip1() <= 0 and ply:GetActiveWeapon() == w then w:SetNextPrimaryFire(CurTime() + 0.1) end
end)

hook.Add("StartCommand", "vrmr", function(ply, cmd)
	local w = ply:GetActiveWeapon()
	if not IsValid(w) or w.ArcCW or w:GetNW2Bool(NW_NORM) or Managed(w) ~= GEN then ply.vrmrGen = nil return end
	ply.vrmrGen = w
	cmd:RemoveKey(IN_RELOAD)
	local cl, kind = w:Clip1(), Kind(w, GEN)
	-- A shot (clip dropped since last command): a pump leaves the next round in
	-- the tube until pumped, a revolver leaves a spent case in its chamber.
	-- Server-authoritative; the engine's own fire delay covers the NW2 latency.
	if SERVER then
		local last = w.vrmrClip
		w.vrmrClip = cl
		if last and cl < last then
			if kind == "rev" then
				w:SetNW2Int(NW_SPENT, w:GetNW2Int(NW_SPENT) + last - cl)
			elseif kind == true and cl > 0 and not NoRack(ply, w:GetClass()) then
				w:SetNW2Bool(NW_UNCH, true)
			end
		end
	end
	local pump = kind == true
	local atk = cmd:KeyDown(IN_ATTACK) or pump and cmd:KeyDown(IN_ATTACK2)
	-- A swallowed press (dry click / slide release) stays swallowed until the
	-- trigger is let go, so holding it can't turn into a shot a tick later.
	if ply.vrmrAtk then
		if atk then StripFire(cmd, pump) return end
		ply.vrmrAtk = nil
	end
	-- An open cylinder lines nothing up with the barrel.
	if not (cl <= 0 or w:GetNW2Bool(NW_UNCH) or kind == "rev" and w:GetNW2Bool(NW_OUT)) then return end
	StripFire(cmd, pump)
	if not atk then return end
	ply.vrmrAtk = true
	-- The client's StartCommand runs while the command is being BUILT, so the
	-- key it strips here never reaches the server: the server can't see this
	-- press at all. The client reports it instead (slide release / dry click).
	if CLIENT then
		net.Start("vrmr")
		net.WriteUInt(OP_TRIG, 3)
		net.WriteBool(false)
		net.SendToServer()
	end
end)

if SERVER then
	util.AddNetworkString("vrmr")
	util.AddNetworkString("vrmr_cls")
	util.AddNetworkString("vrmr_snd")

	local function ReadTbl(kind)
		local t = {}
		for _ = 1, net.ReadUInt(10) do
			local k = net.ReadString()
			if kind then t[k] = KIND[net.ReadUInt(2)] else t[k] = net.ReadBool() end
		end
		return t
	end
	net.Receive("vrmr_cls", function(_, ply)
		ply.vrmrCls = ReadTbl()
		ply.vrmrPump = ReadTbl(true)
		ply.vrmrNoRack = ReadTbl()
		ply:SetNW2Bool("vrmr_sync", true) -- debug HUD: server has the tables
	end)

	net.Receive("vrmr", function(_, ply)
		local op, noSlide = net.ReadUInt(3), net.ReadBool()
		local w = ply:GetActiveWeapon()
		if not IsValid(w) or not ply:Alive() then return end
		local ad = Managed(w)
		if not ad then return end
		if op == OP_NORM then
			w:SetNW2Bool(NW_NORM, noSlide)
			if noSlide then w:SetNW2Bool(NW_OUT, false) w:SetNW2Bool(NW_UNCH, false) end
			return
		end
		if w:GetNW2Bool(NW_NORM) or ad.Busy and ad.Busy(w) then return end
		noSlide = noSlide or NoRack(ply, w:GetClass())
		-- Debounce repeats of one op only: a blanket limit silently dropped an
		-- op sent right after a different one (loader in, then the push that
		-- shuts the cylinder), leaving the server out of step with the client.
		local t = CurTime()
		if ply.vrmrOp == op and (ply.vrmrT or 0) > t then return end
		ply.vrmrOp, ply.vrmrT = op, t + 0.1

		local real, at, kind = w:Clip1(), w:GetPrimaryAmmoType(), Kind(w, ad)
		local inf = ad.Inf and ad.Inf(w)
		if kind == "rev" then
			-- Double action: no chamber to rack. Open / eject / load / shut.
			local out = w:GetNW2Bool(NW_OUT)
			if op == OP_TRIG then
				OwnerSound(ply, SND_DRY_ID)
			elseif op == OP_OUT or op == OP_SHUT then
				w:SetNW2Bool(NW_OUT, op == OP_OUT)
			elseif not out then
				return
			elseif op == OP_EJ then
				-- Cases dump; live rounds go back to reserve.
				if real > 0 and not inf then ply:GiveAmmo(real, at, true) end
				w:SetClip1(0)
				w:SetNW2Int(NW_SPENT, 0)
			elseif op == OP_IN or op == OP_FILL then
				-- One round, or the speed loader into every empty chamber.
				local n = ad.Cap(w) - real - w:GetNW2Int(NW_SPENT)
				if op == OP_IN and n > 1 then n = 1 end
				local r = inf and n or ply:GetAmmoCount(at)
				if r < n then n = r end
				if n <= 0 then return end
				if not inf then ply:SetAmmo(r - n, at) end
				w:SetClip1(real + n)
			end
		elseif op == OP_OUT then
			if w:GetNW2Bool(NW_OUT) or kind then return end
			-- Chambered round stays in the gun; everything else returns to reserve.
			-- No slide = no chamber to keep one in.
			local keep = (noSlide or w:GetNW2Bool(NW_UNCH)) and 0 or math.min(real, ad.Chamber(w))
			if not inf and real > keep then ply:GiveAmmo(real - keep, at, true) end
			w:SetClip1(keep)
			w:SetNW2Bool(NW_UNCH, false)
			w:SetNW2Bool(NW_OUT, true)
		elseif op == OP_IN and kind then
			-- One round into the tube; an empty gun then needs a pump.
			if Tube(w, real) >= ad.Cap(w) then return end
			if not inf then
				local r = ply:GetAmmoCount(at)
				if r <= 0 then return end
				ply:SetAmmo(r - 1, at)
			end
			w:SetClip1(real + 1)
			if real == 0 and not noSlide then w:SetNW2Bool(NW_UNCH, true) end
		elseif op == OP_IN then
			if not w:GetNW2Bool(NW_OUT) then return end
			local load = ad.Cap(w)
			if not inf then
				local r = ply:GetAmmoCount(at)
				if r < load then load = r end
				ply:SetAmmo(r - load, at)
			end
			w:SetClip1(real + load)
			w:SetNW2Bool(NW_OUT, false)
			-- No slide configured: nothing to rack, so the gun comes up loaded.
			if real == 0 and load > 0 and not noSlide then w:SetNW2Bool(NW_UNCH, true) end
		elseif op == OP_RACK then
			-- Feeds a round when one is needed. Racking a loaded gun does not
			-- throw a live round away (double-pumps would eat ammo). A pump only
			-- works with a round waiting to be chambered.
			if kind and not (w:GetNW2Bool(NW_UNCH) and real > 0) then return end
			if w:GetNW2Bool(NW_UNCH) then w:SetNW2Bool(NW_UNCH, false) end
			ad.Idle(w)
		elseif op == OP_TRIG then
			-- Slide guns with slide grabbing off: the trigger drops the slide on
			-- a loaded mag (pumps still need the pump). Otherwise a dry click.
			local unch = w:GetNW2Bool(NW_UNCH)
			if unch and kind ~= true and TrigChambers(ply) then
				w:SetNW2Bool(NW_UNCH, false)
				OwnerSound(ply, SND_SLIDE_ID)
			elseif unch or w:Clip1() <= 0 then
				OwnerSound(ply, SND_DRY_ID)
			end
		end
		w.vrmrClip = w:Clip1()
	end)
	return
end

------------------------------------------------------------------------------
-- CLIENT
------------------------------------------------------------------------------

cvMode = CreateClientConVar("vrmod_manualreload", "0", true, true, "Manual reload: 0 off, 1 VR only, 2 always (PC debug)", 0, 2)
local cvDbg = CreateClientConVar("vrmod_manualreload_debug", "0", false, false, "Manual reload debug overlay", 0, 1)
CreateClientConVar("vrmod_manualreload_travel", "1.5", true, false, "Default slide travel (units)")
CreateClientConVar("vrmod_manualreload_pumptravel", "3", true, false, "Default pump travel (units)")
cvNoSl = CreateClientConVar("vrmod_manualreload_noslidegrab", "1", true, true, "Left hand can't grab slides (the trigger chambers); pumps stay grabbable", 0, 1)
CreateClientConVar("vrmod_manualreload_pouch", "2 7 -26", true, false, "Pouch offset from HMD: forward left up")
CreateClientConVar("vrmod_manualreload_reach", "7 5 4", true, false, "Grab radii: pouch slide insert")
-- Where the mag BONE sits in the left hand (hand space). The bone is the pivot,
-- so this is the same for every gun regardless of where its mag lives on the
-- model. Default = the palm point used for grabbing.
CreateClientConVar("vrmod_manualreload_magoff", "3 0 0 0 0 0", true, false, "Held mag bone in left-hand space: x y z pitch yaw roll")
-- Support-hand grip (foregrip mode 1): grab radius, the max distance between
-- the model's two hands before its left hand counts as "not on the gun", and
-- how far left of the right hand the mirrored fallback sits.
CreateClientConVar("vrmod_manualreload_grip", "7 20 2", true, false, "Support grip: radius  max hand gap  mirror side offset")
CreateClientConVar("vrmod_manualreload_gripoff", "0 0 0 0 0 0", true, false, "Mirrored support grip hand-space correction: x y z pitch yaw roll")

local FILE = "vrmod_manualreload.json"
local ovr = util.JSONToTable(file.Read(FILE, "DATA") or "") or {}
local cfgs = {} -- [model] = cfg | false
local RACK_T, RACK_AT, REARM, PUMP_HOME, PALM = 0.3, 0.9, 0.25, 0.1, 3
local LHAND = "ValveBiped.Bip01_L_Hand"
local L_HAND, R_HAND = LHAND, "ValveBiped.Bip01_R_Hand"
local pumpW, EMPTY = Vector(), {}
local lhP, lhA = Vector(), Angle()
local shP, shA -- left hand relative to the slide bone, captured at grab
local SND_GRAB, SND_IN, SND_OUT, SND_RACK, SND_DENY = "items/ammo_pickup.wav", "weapons/smg1/switch_single.wav",
	"weapons/smg1/switch_burst.wav", "weapons/shotgun/shotgun_cock.wav", "items/medshotno1.wav"
-- Revolver ops -> HL2 .357 soundscripts.
local REV_SND = {[OP_OUT] = "Weapon_357.OpenLoader", [OP_EJ] = "Weapon_357.RemoveLoader",
	[OP_IN] = "Weapon_357.ReplaceLoader", [OP_FILL] = "Weapon_357.ReplaceLoader", [OP_SHUT] = "Weapon_357.Spin"}
-- Model space: the slide racks back (-X); a cylinder swings out left (+Y) and
-- a little down.
local VEC0, BACK, FWD, REV_DIR = Vector(0, 0, 0), Vector(-1, 0, 0), Vector(1, 0, 0), Vector(0, 0.94, -0.34)
local off, palm = Vector(), Vector()
local pouchP, pouchA, pouchOff = Vector(), Angle(), Vector()
-- cCfg: the held gun's cfg while manual reload manages it. gCfg: the same
-- cfg for ANY viewmodel gun -- the support grip (foregrip mode 1) reads it
-- whatever the manual reload state; nothing else does.
local LP, hookedVM, cWep, cMdl, cCfg, cAd, pending, gCfg
local pull, rackT, preview, swing = 0, 0, false, 0
local spinAng, spinVel, gestT, wasOpen = 0, 0, 0, false -- revolver cylinder spin / gesture gate
local pumpedT = 0 -- our own pump just chambered; the server's word is still in flight
local held, hp, ha, hpt, slideGrab, slideStart, slideAx, racked, ours
local vmP, vmA, lastF, pouchOK = nil, nil, -1, false
local dbg = cvDbg:GetBool()

cvAuto = CreateClientConVar("vrmod_manualreload_auto", "0", true, true, "Manual reload on every weapon with a magazine unless turned off per weapon", 0, 1)
local cvHint = CreateClientConVar("vrmod_manualreload_hint", "1", true, false, "Reload helper: the part to work next glows while the trigger is held on a gun that can't fire", 0, 1)

-- Per-class opt in/out, synced to the server (it gates fire/reload too).
local CLS_FILE = "vrmod_manualreload_classes.json"
clsTbl = util.JSONToTable(file.Read(CLS_FILE, "DATA") or "")
	or {weapon_pistol = true, weapon_smg1 = true, weapon_ar2 = true, weapon_shotgun = true}

-- Per-class Auto(nil) / Mag(false) / Pump(true) / Revolver("rev").
local PUMP_FILE = "vrmod_manualreload_pump.json"
pumpTbl = util.JSONToTable(file.Read(PUMP_FILE, "DATA") or "") or {}
local RACK_FILE = "vrmod_manualreload_norack.json"
rackTbl = util.JSONToTable(file.Read(RACK_FILE, "DATA") or "") or {}

local function WriteTbl(t, kind)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	n = math.min(n, 1023)
	net.WriteUInt(n, 10)
	for k, v in pairs(t) do
		if n <= 0 then break end
		n = n - 1
		net.WriteString(k)
		if kind then net.WriteUInt(v == true and 1 or v == "rev" and 2 or v == "semi" and 3 or 0, 2) else net.WriteBool(v) end
	end
end

local function SyncCls()
	if not IsValid(LocalPlayer()) then return end
	net.Start("vrmr_cls")
	WriteTbl(clsTbl)
	WriteTbl(pumpTbl, true)
	WriteTbl(rackTbl)
	net.SendToServer()
end

local function SetCls(cls, v)
	clsTbl[cls] = v
	file.Write(CLS_FILE, util.TableToJSON(clsTbl))
	SyncCls()
	cWep = nil
end

hook.Add("InitPostEntity", "vrmr", SyncCls)
timer.Simple(0, SyncCls) -- autorefresh / late load
net.Receive("vrmr_cls", SyncCls) -- server asking: it never got them
local travel, ptravel, rP2, rS2, rI2, noSlideGrab
local corrP, corrA, hasCorr = Vector(), Angle(), false
local gripR2, gripGap2, gripSide = 49, 400, 2
local gofP, gofA, hasGof = Vector(), Angle(), false

local function Cache()
	travel = GetConVar("vrmod_manualreload_travel"):GetFloat()
	ptravel = GetConVar("vrmod_manualreload_pumptravel"):GetFloat()
	noSlideGrab = cvNoSl:GetBool()
	pouchOff = Vector(GetConVar("vrmod_manualreload_pouch"):GetString())
	local r = Vector(GetConVar("vrmod_manualreload_reach"):GetString())
	rP2, rS2, rI2 = r.x * r.x, r.y * r.y, r.z * r.z
	local t = string.Explode(" ", GetConVar("vrmod_manualreload_magoff"):GetString())
	corrP:SetUnpacked(tonumber(t[1]) or 0, tonumber(t[2]) or 0, tonumber(t[3]) or 0)
	corrA:SetUnpacked(tonumber(t[4]) or 0, tonumber(t[5]) or 0, tonumber(t[6]) or 0)
	hasCorr = not (corrP:IsZero() and corrA:IsZero())
	local g = Vector(GetConVar("vrmod_manualreload_grip"):GetString())
	gripR2, gripGap2, gripSide = g.x * g.x, g.y * g.y, g.z
	t = string.Explode(" ", GetConVar("vrmod_manualreload_gripoff"):GetString())
	gofP:SetUnpacked(tonumber(t[1]) or 0, tonumber(t[2]) or 0, tonumber(t[3]) or 0)
	gofA:SetUnpacked(tonumber(t[4]) or 0, tonumber(t[5]) or 0, tonumber(t[6]) or 0)
	hasGof = not (gofP:IsZero() and gofA:IsZero())
end
Cache()

-- Per-model override, else the pump or slide default.
local function Travel(c) return c.travel or (c.pa and ptravel or travel) end

local function Free(c)
	local t = c and c.copy
	if t then for i = 1, 2 do if IsValid(t[i]) then t[i]:Remove() end end end
end

-- Copy of the VM model posed at idle. Bones off the mag's ancestry are
-- zero-scaled once via ManipulateBoneScale (inherits down, fine since no mag
-- below them); the ancestry chain is zeroed per setup in a bone callback,
-- which does not propagate, so the mag subtree survives.
local function Copy(mdl, seq, keep, anc)
	local e = ClientsideModel(mdl, RENDERGROUP_OPAQUE)
	if not IsValid(e) then return end
	e:SetNoDraw(true)
	e:SetSequence(seq)
	e:SetCycle(0)
	if keep then
		for i = 0, e:GetBoneCount() - 1 do
			if not keep[i] then e:ManipulateBoneScale(i, VEC0) end
		end
		if anc[1] then
			e:AddCallback("BuildBonePositions", function(ent)
				for i = 1, #anc do
					local m = ent:GetBoneMatrix(anc[i])
					if m then m:Scale(VEC0) ent:SetBoneMatrix(anc[i], m) end
				end
			end)
		end
	end
	return e
end

-- Bone-name keywords + the matcher only matter while building a model's
-- cfg: scoped here so they don't count toward the main chunk's 200 locals.
local Build
do
	local MAG_K, MAG_X = {"mag", "clip", "drum"}, {"release", "catch", "well", "button", "lever", "latch", "magnif", "magnum"}
	local SLD_K, SLD_X = {"pump", "slide", "bolt"}, {"release", "catch", "stop", "lock", "button", "lever", "latch"}
	-- A charging handle (AR-15 style) is what the hand racks: searched on its own
	-- first, so a bolt can't outrank it or swallow it as its child.
	local CHG_K = {"charg"}
	-- Pump weapons: the "mag" is one round, inserted at the loading gate.
	local SHL_K, SHL_X = {"12g", "shell", "buck", "slug"}, {"eject", "case", "casing", "brass", "ramp", "lift", "carrier"}
	-- What the hand pumps: the forend (never an arm's forearm / hold bone).
	-- The bolt, when separate, rides along with it.
	local PMP_K, PMP_X = {"pump", "forend", "fore_end", "forearm", "slide"}, {"bip01", "hold", "release", "catch", "lock", "button", "lever", "latch"}
	local BLT_K = {"bolt"}
	local INS_K = {"trapdoor", "loadgate", "gate", "carrier", "ramp", "lift", "elevator"}
	-- Revolvers: the cylinder (or its crane) swings out; the "mag" is the speed
	-- loader, else one round. Round bones show one per loaded + spent chamber.
	local CYL_K, CYL_X, SPD_K = {"cyl"}, {"release"}, {"speed"}
	-- The drum that spins: a cyl bone that isn't its crane / axis / extractor.
	local SPIN_X = {"release", "pivot", "axis", "crane", "extract", "eject"}
	local RND_K, RND_X = {"round", "bullet", "shell", "cartridge"}, {"eject", "case", "casing", "brass", "speed", "release", "loader"}

	local function score(n, K, X)
		for i = 1, #X do if n:find(X[i], 1, true) then return end end
		for i = 1, #K do if n:find(K[i], 1, true) then return i end end
	end

	local function snap(v)
		local x, y, z = v.x, v.y, v.z
		local ax, ay, az = x < 0 and -x or x, y < 0 and -y or y, z < 0 and -z or z
		if ax >= ay and ax >= az then return Vector(x < 0 and -1 or 1, 0, 0) end
		if ay >= az then return Vector(0, y < 0 and -1 or 1, 0) end
		return Vector(0, 0, z < 0 and -1 or 1)
	end

	function Build(vm, ad, wep, mdl)
		local n = vm:GetBoneCount()
		local par, nm = {}, {}
		for i = 0, n - 1 do
			par[i] = vm:GetBoneParent(i)
			nm[i] = vm:GetBoneName(i):lower()
		end
		local function under(i, r)
			while i >= 0 do
				if i == r then return true end
				i = par[i]
			end
			return false
		end
		local function sub(r, incl)
			local t = {}
			for j = 0, n - 1 do
				if (incl or j ~= r) and under(j, r) then t[#t + 1] = j end
			end
			return t
		end
		-- Every topmost bone matching a keyword, best first (keyword priority,
		-- then largest subtree).
		local function pickAll(K, X)
			local r = {}
			for i = 0, n - 1 do
				local s = score(nm[i], K, X)
				if s then
					local p = par[i]
					while p >= 0 and not score(nm[p], K, X) do p = par[p] end
					if p < 0 then r[#r + 1] = {i, s, #sub(i)} end
				end
			end
			table.sort(r, function(a, b) return a[2] < b[2] or a[2] == b[2] and (a[3] > b[3] or a[3] == b[3] and a[1] < b[1]) end)
			for i = 1, #r do r[i] = r[i][1] end
			return r
		end

		local kind = Kind(wep, ad)
		if kind == nil then return end -- not ready: Resolve retries, nothing cached
		-- pump: tube-fed, one round at a time (pump action or semi). pa: the
		-- slide is a pump the support hand works; a semi's bolt is a slide.
		local pa, rev = kind == true, kind == "rev"
		local pump = pa or kind == "semi"
		-- Revolver rounds outside the speed loader, in chamber order (name digits).
		local spd, rnd = rev and pickAll(SPD_K, EMPTY)[1]
		if rev then
			rnd = {}
			for _, b in ipairs(pickAll(RND_K, RND_X)) do
				if not (spd and under(b, spd)) then rnd[#rnd + 1] = b end
			end
			local function num(b) return tonumber(nm[b]:match("(%d+)%D*$")) or 0 end
			table.sort(rnd, function(a, b) return num(a) < num(b) end)
		end

		-- Mag: every matching bone (ar2_mag + ar2_mag_loader2 ...), or the saved
		-- list. [1] is the pivot used for the held mag and the insert check.
		local o = ovr[mdl] or {}
		local om, mags = o.mag
		if om == nil then
			if pump then mags = pickAll(SHL_K, SHL_X)
			elseif rev then mags = {spd or rnd[1]}
			else mags = pickAll(MAG_K, MAG_X) end
			if not mags[1] and istable(wep.BulletBones) then
				local b = wep.BulletBones[1]
				if istable(b) then b = b[1] end
				b = isstring(b) and vm:LookupBone(b)
				if b and par[b] >= 0 then mags[1] = par[b] end
			end
		else
			mags = {}
			if om then
				for _, v in ipairs(istable(om) and om or {om}) do
					local b = vm:LookupBone(v)
					if b then mags[#mags + 1] = b end
				end
			end
		end
		local mag = mags[1]
		local sl
		if o.slide ~= nil then
			sl = o.slide and vm:LookupBone(o.slide) or nil
		elseif rev then
			sl = pickAll(CYL_K, CYL_X)[1]
		else
			sl = pa and (pickAll(PMP_K, PMP_X)[1] or pickAll(BLT_K, SLD_X)[1]) or pickAll(CHG_K, SLD_X)[1] or pickAll(SLD_K, SLD_X)[1]
		end

		local magB, mset
		if mag then
			magB, mset = {}, {}
			for i = 1, #mags do
				local t = sub(mags[i], true)
				for j = 1, #t do
					local b = t[j]
					if not mset[b] then mset[b], magB[#magB + 1] = true, b end
				end
			end
		end

		local c = {kind = kind, mag = mag, mags = mags, magB = magB, slide = sl, kids = sl and sub(sl), travel = o.travel, pump = pump, pa = pa, rev = rev,
			lock = ad.slidelock == true and not (pa or rev), speed = rev and mag and nm[mag]:find("speed", 1, true) ~= nil}
		if pa and sl and o.slide == nil then
			local b = pickAll(BLT_K, SLD_X)[1]
			if b and b ~= sl and not under(b, sl) then
				local k, t = c.kids, sub(b, true)
				for i = 1, #t do k[#k + 1] = t[i] end
			end
		end
		local sp = rev and pickAll(CYL_K, SPIN_X)[1]
		if sp then c.spin, c.spinB = sp, sub(sp, true) end
		-- Each round's bones (hidden past the loaded + spent count); rounds not
		-- parented under the cylinder still ride it out and spin with the drum.
		if rnd then
			local rb, k, sb = {}, c.kids, c.spinB
			for i = 1, #rnd do
				local t = sub(rnd[i], true)
				rb[i] = t
				if k and not under(rnd[i], sl) then for j = 1, #t do k[#k + 1] = t[j] end end
				if sb and not under(rnd[i], sp) then for j = 1, #t do sb[#sb + 1] = t[j] end end
			end
			c.rnd = rb
		end
		if o.lock ~= nil then c.lock = o.lock end
		-- Support grip: a chosen bone, forced mirror (false), or the model's own
		-- left hand when it actually sits on the gun (checked on the idle pose).
		c.grip = o.grip and vm:LookupBone(o.grip) or nil
		c.gripNone = o.grip == false
		local lhB, rhB = vm:LookupBone(L_HAND), vm:LookupBone(R_HAND)
		-- Insert point: saved bone, the pump gun's loading gate, else the mag pivot.
		if o.ins ~= nil then
			c.ins = o.ins and vm:LookupBone(o.ins) or nil
		elseif pump then
			c.ins = pickAll(INS_K, EMPTY)[1]
		elseif rev then
			c.ins = sl
		end

		-- Model-space idle pose: slide axis + mag origin come from an unscaled copy.
		local e = Copy(mdl, 0)
		if IsValid(e) then
			local s = ad.Seq(e, wep)
			s = s >= 0 and s or 0
			e:SetSequence(s)
			e:SetupBones()
			local m = sl and e:GetBoneMatrix(sl)
			if m then c.axis = rev and WorldToLocal(REV_DIR, angle_zero, vector_origin, m:GetAngles()) or snap((WorldToLocal(BACK, angle_zero, vector_origin, m:GetAngles()))) end
			-- Spin axis: the barrel axis, in the drum bone's frame.
			m = c.spin and e:GetBoneMatrix(c.spin)
			if m then c.spinAx = WorldToLocal(FWD, angle_zero, vector_origin, m:GetAngles()) end
			c.seq = s
			if lhB and rhB and not c.gripNone then
				local a, b = e:GetBoneMatrix(lhB), e:GetBoneMatrix(rhB)
				if a and b and a:GetTranslation():DistToSqr(b:GetTranslation()) <= gripGap2 then c.lh = lhB end
			end
			-- The gun's own grip, posed the way VRMod's auto offset puts the
			-- tracked hand on it (R_Hand rolled 180, less autoOffsetAddPos). The
			-- mirrored support grip mirrors this, so repositioning the gun hand
			-- doesn't drag the support hand off the gun.
			local rm = rhB and e:GetBoneMatrix(rhB)
			if rm then
				local add = g_VR.viewModelInfo and g_VR.viewModelInfo.autoOffsetAddPos
				c.rhB, c.rhOff = rhB, add and -add or Vector()
				local ra = rm:GetAngles()
				ra:RotateAroundAxis(ra:Forward(), 180)
				c.rhP, c.rhA = LocalToWorld(c.rhOff, angle_zero, rm:GetTranslation(), ra)
			end
			m = mag and e:GetBoneMatrix(mag)
			e:Remove()
			if m then
				local keep, anc = {}, {}
				-- A pump hand-loads one round: the copy is the pivot round only.
				if pump then
					for _, b in ipairs(sub(mag, true)) do keep[b] = true end
				else
					for b in pairs(mset) do keep[b] = true end
				end
				for i = 1, pump and 1 or #mags do
					local p = par[mags[i]]
					while p >= 0 and not keep[p] do
						keep[p] = true
						anc[#anc + 1] = p
						p = par[p]
					end
				end
				c.magPos = m:GetTranslation()
				c.magNeg = -c.magPos
				c.copy = {Copy(mdl, s, keep, anc), Copy(mdl, s, keep, anc)}
				c.mdl, c.keepT, c.anc = mdl, keep, anc -- for dropped-mag copies
				if not (IsValid(c.copy[1]) and IsValid(c.copy[2])) then Free(c) c.copy = nil end
			end
		end
		if o.axis then c.axis = Vector(o.axis[1], o.axis[2], o.axis[3]):GetNormalized() end
		if not c.axis then c.slide = nil end
		if not c.spinAx then c.spin = nil end
		return c
	end
end
local function norm(s) return (s:lower():gsub("\\", "/")) end

local function Resolve(wep, mdl)
	if wep ~= cWep then held, slideGrab, pull, swing, spinAng, spinVel = false, false, 0, 0, 0, 0 end
	cWep, cMdl, cCfg, cAd, gCfg = wep, mdl, nil, nil, nil
	if g_VR.wmActive or not vrmod.utils.IsValidWep(wep) then return end
	-- Built for every viewmodel gun (the support grip needs its bones);
	-- managed only when manual reload takes it.
	local ad = Managed(wep)
	local gad = ad or (wep.ArcCW and ARCCW or GEN)
	-- VM model can lag the weapon switch by a frame; retry until they agree.
	local want = gad.VM and gad.VM(wep)
	if want and norm(want) ~= norm(mdl) then cMdl = nil return end
	local c = cfgs[mdl]
	if c ~= nil then
		-- Built for another type (an override since, or an early read that
		-- came back as magazine)? Rebuild rather than keep it for the map.
		local k = Kind(wep, gad)
		if k == nil or k == c.kind then
			gCfg = c
			if not ad then return end
			cAd, cCfg = ad, c
			-- Tell the server whether this gun keeps its own reload.
			local v = not (c.mag or c.pump or c.rev)
			if wep:GetNW2Bool(NW_NORM) ~= v then
				net.Start("vrmr")
				net.WriteUInt(OP_NORM, 3)
				net.WriteBool(v)
				net.SendToServer()
			end
			return
		end
		Free(c)
		cfgs[mdl] = nil
	end
	if pending then cMdl = nil return end
	-- Never spawn entities from inside a bone callback; build next tick.
	pending = true
	timer.Simple(0, function()
		pending = nil
		if IsValid(hookedVM) and IsValid(wep) and hookedVM:GetModel() == mdl then
			cfgs[mdl] = Build(hookedVM, gad, wep, mdl)
		end
		cWep = nil
	end)
end

local function Hide(vm, t)
	for i = 1, #t do
		local m = vm:GetBoneMatrix(t[i])
		if m then
			m:Scale(VEC0)
			vm:SetBoneMatrix(t[i], m)
		end
	end
end

-- Spin the drum subtree about the barrel axis through the drum bone. Each
-- bone is re-expressed relative to the drum (WorldToLocal) and placed back
-- against the drum's rotated angle (LocalToWorld): a pure rigid transform.
-- Nothing is carried between calls, and each bone's own scale is written back,
-- so it can't drift. Zero-scaled bones (empty chambers) are skipped: hidden,
-- and a degenerate matrix has no angle to rotate.
local Spin
do
	local spAx, spA = Vector(), Angle()
	function Spin(vm, c)
		local m = vm:GetBoneMatrix(c.spin)
		if not m then return end
		local pp, pa = m:GetTranslation(), m:GetAngles()
		spAx:Set(c.spinAx)
		spAx:Rotate(pa)
		spA:Set(pa)
		spA:RotateAroundAxis(spAx, spinAng)
		local t = c.spinB
		for i = 1, #t do
			m = vm:GetBoneMatrix(t[i])
			if m then
				local sc = m:GetScale()
				if sc.x > 0 then
					local lp, la = WorldToLocal(m:GetTranslation(), m:GetAngles(), pp, pa)
					lp, la = LocalToWorld(lp, la, pp, spA)
					m:SetTranslation(lp)
					m:SetAngles(la)
					m:SetScale(sc)
					vm:SetBoneMatrix(t[i], m)
				end
			end
		end
	end
end

local function BBP(vm)
	local wep, mdl = LP:GetActiveWeapon(), vm:GetModel()
	if wep ~= cWep or mdl ~= cMdl then Resolve(wep, mdl) end
	pumpW:Zero() -- the support grip rides it: zero on guns this doesn't pose
	local c = cCfg
	if not c then return end

	-- Mag weapons: hidden while the mag is out. Pump weapons never eject; their
	-- round bone (shell, crossbow bolt) is hidden while nothing is loaded.
	-- Revolvers: every chamber past loaded + spent is emptied.
	if c.magB and (preview or not c.rev and wep:GetNW2Bool(NW_OUT) or c.pump and wep:Clip1() <= 0) then Hide(vm, c.magB) end
	local rb = c.rnd
	if rb then
		for i = wep:Clip1() + wep:GetNW2Int(NW_SPENT) + 1, #rb do Hide(vm, rb[i]) end
	end

	local sl = c.slide
	if not sl then return end
	local p = swing -- revolver: how far the cylinder is out
	if not c.rev then
		p = pull
		if rackT > 0 then
			local r = (RealTime() - rackT) / RACK_T
			if r >= 1 then
				rackT = 0
			else
				r = r < 0.5 and r * 2 or 2 - r * 2
				if r > p then p = r end
			end
		end
		-- Slide lock: held back while empty or unchambered (slidelock bases).
		if p < 1 and c.lock and (wep:Clip1() <= 0 or wep:GetNW2Bool(NW_UNCH)) then p = 1 end
	end
	if p <= 0 then return end

	local m = vm:GetBoneMatrix(sl)
	if not m then return end
	off:Set(c.axis)
	off:Rotate(m:GetAngles())
	off:Mul(Travel(c) * p)
	if c.pa then pumpW:Set(off) end -- the support hand rides the pump
	local v = m:GetTranslation()
	v:Add(off)
	m:SetTranslation(v)
	vm:SetBoneMatrix(sl, m)
	local k = c.kids
	for i = 1, #k do
		m = vm:GetBoneMatrix(k[i])
		if m then
			v = m:GetTranslation()
			v:Add(off)
			m:SetTranslation(v)
			vm:SetBoneMatrix(k[i], m)
		end
	end
	if spinAng ~= 0 and c.spin then Spin(vm, c) end
end

timer.Create("vrmr_vm", 0.5, 0, function()
	local lp = LocalPlayer()
	if not IsValid(lp) then return end
	local vm = lp:GetViewModel(0)
	if vm == hookedVM or not IsValid(vm) then return end
	if vm.vrmrCB then vm:RemoveCallback("BuildBonePositions", vm.vrmrCB) end -- autorefresh
	LP, hookedVM, cWep = lp, vm, nil
	vm.vrmrCB = vm:AddCallback("BuildBonePositions", BBP)
end)

local function Dirty() cWep = nil end
cvars.AddChangeCallback("vrmod_manualreload", Dirty, "vrmr")
cvars.AddChangeCallback("vrmod_manualreload_auto", Dirty, "vrmr")
cvars.AddChangeCallback("vrmod_manualreload_debug", function(_, _, v) dbg = v == "1" end, "vrmr")
for _, n in ipairs({"travel", "pumptravel", "noslidegrab", "pouch", "reach", "magoff", "grip", "gripoff"}) do cvars.AddChangeCallback("vrmod_manualreload_" .. n, Cache, "vrmr") end
hook.Add("VRMod_Start", "vrmr", Dirty)
hook.Add("VRMod_Exit", "vrmr", function() held, slideGrab, pull = false, false, 0 Dirty() end)

------------------------------------------------------------------------------
-- Dropped mags: on eject a mag-only copy starts at the gun's exact pose and
-- falls (gravity, world-brush trace, rests, then fades out after a few
-- seconds). Hand-simulated: VM models rarely carry a collision model, so
-- there is nothing to hand to VPhysics. Capped at MAX_DROPS.
------------------------------------------------------------------------------

local drops, MAX_DROPS, DROP_LIFE, GRAV = {}, 4, 6, 600
local dropF = -1
local trD = {start = Vector(), endpos = Vector(), mask = MASK_SOLID_BRUSHONLY}

-- In VR this runs from VRMod_Input, i.e. inside RenderScene: a model spawned
-- there never draws. Snapshot the pose now (it falls from here), spawn the
-- copy next tick. A drop evicted or expired before then is flagged dead.
local function DropMag()
	local c, w = cCfg, cWep
	if not (c and c.copy and c.mdl and not c.pump and vmP and IsValid(w)) or w:GetNW2Bool(NW_OUT) then return end
	if drops[MAX_DROPS] then
		local o = table.remove(drops, 1)
		o.dead = true
		if IsValid(o.e) then o.e:Remove() end
	end
	local d = {p = Vector(vmP), a = Angle(vmA), mp = c.magPos, vz = -40, t = RealTime() + DROP_LIFE}
	drops[#drops + 1] = d
	timer.Simple(0, function()
		local e = Copy(c.mdl, c.seq or 0, c.keepT, c.anc)
		if d.dead then
			if e then e:Remove() end
		elseif e then
			d.e = e
		else
			d.t = 0
		end
	end)
end

local function DropsThink()
	local fn = FrameNumber()
	if fn == dropF then return end
	dropF = fn
	local dt, now = FrameTime(), RealTime()
	for i = #drops, 1, -1 do
		local d = drops[i]
		if now > d.t then
			d.dead = true
			if IsValid(d.e) then d.e:Remove() end
			table.remove(drops, i)
		elseif not d.rest then
			d.vz = d.vz - GRAV * dt
			local dz = d.vz * dt
			-- Trace the mag itself, not the entity origin (that's the VM origin).
			local from = LocalToWorld(d.mp, angle_zero, d.p, d.a)
			trD.start:Set(from)
			from.z = from.z + dz
			trD.endpos:Set(from)
			local tr = util.TraceLine(trD)
			if tr.Hit then
				d.p.z = d.p.z + (tr.HitPos.z - trD.start.z) + 0.5
				d.rest = true
			else
				d.p.z = d.p.z + dz
			end
		end
	end
end

-- Dry click / slide release for the owner (see OwnerSound).
net.Receive("vrmr_snd", function()
	local w = LocalPlayer():GetActiveWeapon()
	if not IsValid(w) then return end
	w:EmitSound(net.ReadUInt(1) == SND_DRY_ID and (DRY[w:GetClass()] or DRY_DEF) or SND_SLIDE)
end)

local function act(op, quiet)
	gestT = RealTime() + 0.3 -- the hand motion that did this isn't a gesture
	local s = cCfg and cCfg.rev and REV_SND[op]
	if op == OP_OUT and not s then DropMag() end
	net.Start("vrmr")
	net.WriteUInt(op, 3)
	net.WriteBool(not (cCfg and cCfg.slide)) -- no slide part = chamber on insert
	net.SendToServer()
	if op == OP_IN or op == OP_FILL then held = false end
	if op == OP_RACK and cCfg and cCfg.pa then pumpedT = RealTime() + 0.3 end
	if s then
		LP:EmitSound(s)
	elseif op == OP_RACK then
		surface.PlaySound(SND_RACK)
		if not quiet then rackT = RealTime() end
	else
		surface.PlaySound(op == OP_IN and SND_IN or SND_OUT)
	end
end

-- Letting go ends the grab. A pump already pulled to the back counts as
-- pushed home (it would be), so the stroke isn't wasted.
local function EndSlide()
	if not slideGrab then return end
	if racked and cCfg and cCfg.pa then act(OP_RACK, true) end
	slideGrab, pull, racked = false, 0, false
end

local function TryHold()
	local w = cWep
	if not (cCfg and cCfg.copy and IsValid(w)) then return end
	if LP:GetAmmoCount(w:GetPrimaryAmmoType()) <= 0 then surface.PlaySound(SND_DENY) return end
	held = true
	surface.PlaySound(SND_GRAB)
end

-- Revolver, one step per press: open -> eject spent -> fill (no loader/round
-- part to hand-load, or asked) -> shut.
local function RevStep(w, fill)
	if not w:GetNW2Bool(NW_OUT) then act(OP_OUT)
	elseif w:GetNW2Int(NW_SPENT) > 0 then act(OP_EJ)
	elseif fill and w:Clip1() < w:GetMaxClip1() and LP:GetAmmoCount(w:GetPrimaryAmmoType()) > 0 then act(OP_FILL)
	else act(OP_SHUT) end
end

------------------------------------------------------------------------------
-- Per-frame interaction: pouch, held mag pose, proximity insert, slide pull.
-- Runs from VRMod_Tracking in VR and the render hook on desktop.
------------------------------------------------------------------------------

------------------------------------------------------------------------------
-- Revolver motion + VR gestures (cylinder out, left hand empty):
--   slap down on the drum  -> spin it (coasts down; shutting lands on a chamber)
--   push it in             -> shut   } only with a live round in
--   flick the gun          -> shut   }
-- Hand speeds are left-relative-to-right (world u/s), so walking or swinging
-- the gun doesn't read as a slap. The flick is the gun's own turn rate,
-- measured from its orientation frame to frame.
------------------------------------------------------------------------------

local RevMotion, RevGesture
do
	local SLAP_V, PUSH_V, FLICK, GEST_CD = 45, 35, 540, 0.3
	local flF, flU, relV = Vector(), Vector(), Vector()
	local flickN = 0 -- consecutive frames over the flick rate

	function RevMotion(w)
		local dt, open = FrameTime(), w:GetNW2Bool(NW_OUT)
		local s = swing + dt * (open and 8 or -8) -- ~0.12 s swing
		swing = s > 1 and 1 or s < 0 and 0 or s
		if open ~= wasOpen then
			wasOpen = open
			if open then gestT = RealTime() + 0.4 end -- the opening move isn't a flick
		end
		if spinVel > 0 then
			if open then
				spinAng = (spinAng + spinVel * dt) % 360
				spinVel = spinVel * (1 - dt * 1.5)
				if spinVel < 20 then spinVel = 0 end
			else
				local st = 360 / w:GetMaxClip1()
				spinAng, spinVel = math.floor(spinAng / st + 0.5) * st % 360, 0
			end
		elseif not open and swing <= 0 then
			spinAng = 0
		end
	end

	function RevGesture(w, c, vm, t)
		local dt = FrameTime()
		local f, u = vmA:Forward(), vmA:Up()
		local turn = math.min(f:Dot(flF), u:Dot(flU))
		flF:Set(f)
		flU:Set(u)
		flickN = dt > 0 and turn < math.cos(math.rad(FLICK * dt)) and flickN + 1 or 0
		if held or swing < 1 or dt <= 0 or RealTime() < gestT or not w:GetNW2Bool(NW_OUT) then return end
		local live = w:Clip1() > 0
		-- Two frames running: one doubled pose step (a dropped tracking update)
		-- reads as twice the turn rate for a single frame.
		if live and flickN >= 2 then
			act(OP_SHUT)
			gestT = RealTime() + GEST_CD
			return
		end
		local lv, rv = t.pose_lefthand.vel, t.pose_righthand.vel
		local cm, sm = vm:GetBoneMatrix(c.spin or c.slide), vm:GetBoneMatrix(c.slide)
		if not (lv and rv and cm and sm) or palm:DistToSqr(cm:GetTranslation()) > rS2 * 2.25 then return end
		relV:Set(lv)
		relV:Sub(rv)
		off:Set(c.axis) -- swing-out direction, world
		off:Rotate(sm:GetAngles())
		local vin, vdown = -relV:Dot(off), -relV.z
		if live and vin > PUSH_V and vin > vdown then
			act(OP_SHUT)
			gestT = RealTime() + GEST_CD
		elseif vdown > SLAP_V and c.spin then
			spinVel = math.min(spinVel + vdown * 12, 1800)
			LP:EmitSound("Weapon_357.Spin")
			gestT = RealTime() + 0.2
		end
	end
end

-- Worldmodel mode: on the flip, drop everything held and the cfg (Resolve
-- runs again once back on the viewmodel and resends NW_NORM as the gun
-- needs); while in it, keep the server's NW_NORM set (every 0.5s at most).
local lastWM, normT = false, 0
local function WMStandDown()
	local wm = g_VR.wmActive or false
	if wm ~= lastWM then
		lastWM, held, slideGrab, pull = wm, false, false, 0
		cWep, cCfg, cAd, gCfg = nil, nil, nil, nil
	end
	if not wm then return false end
	local w = LocalPlayer():GetActiveWeapon()
	if IsValid(w) and not w:GetNW2Bool(NW_NORM) and RealTime() > normT and ManagedAny(w) then
		normT = RealTime() + 0.5
		net.Start("vrmr")
		net.WriteUInt(OP_NORM, 3)
		net.WriteBool(true)
		net.SendToServer()
	end
	return true
end

local function Frame()
	local fn = FrameNumber()
	if fn == lastF then return end
	lastF, pouchOK, hp = fn, false, nil
	if WMStandDown() then return end
	local c, vm, w = cCfg, hookedVM, cWep
	if not c or not IsValid(vm) then return end
	if c.rev and IsValid(w) then RevMotion(w) end
	local t = g_VR and g_VR.active and g_VR.tracking
	local hmd = t and t.hmd
	if hmd then
		pouchA:SetUnpacked(0, hmd.ang.yaw, 0)
		pouchP:Set(hmd.pos)
		vmP, vmA = g_VR.viewModelPos, g_VR.viewModelAng
	else
		t = nil
		pouchA:SetUnpacked(0, LP:EyeAngles().yaw, 0)
		pouchP:Set(LP:EyePos())
		vmP, vmA = vm:GetPos(), vm:GetAngles()
	end
	off:Set(pouchOff)
	off:Rotate(pouchA)
	pouchP:Add(off)
	pouchOK = true

	local lp, la
	local lh = t and t.pose_lefthand
	if lh then
		lp, la = lh.pos, lh.ang
	else
		local b = LP:LookupBone(LHAND)
		local m = b and LP:GetBoneMatrix(b)
		if not m then return end
		lp, la = m:GetTranslation(), m:GetAngles()
	end
	palm:Set(la:Forward())
	palm:Mul(PALM)
	palm:Add(lp)
	lhP:Set(lp) -- raw, before foregrip pins the tracked pose
	lhA:Set(la)

	if held then
		-- Pivot on the mag bone: it lands exactly at the hand-space offset.
		local cp, ca = lp, la
		if hasCorr then cp, ca = LocalToWorld(corrP, corrA, lp, la) end
		local rh = t and t.pose_righthand
		if rh then
			-- Orientation only: the gun's grip angle on the right hand, mirrored
			-- onto the left, so the mag points the way it would in the gun.
			local _, a = WorldToLocal(vmP, vmA, rh.pos, rh.ang)
			a.y, a.r = -a.y, -a.r
			_, ca = LocalToWorld(vector_origin, a, cp, ca)
		end
		hpt, ha = cp, ca
		hp = LocalToWorld(c.magNeg, angle_zero, cp, ca)
		if rh and IsValid(w) and (c.pump and Tube(w, w:Clip1()) < w:GetMaxClip1() or not c.pump and w:GetNW2Bool(NW_OUT)
			and not (c.rev and w:Clip1() + w:GetNW2Int(NW_SPENT) >= w:GetMaxClip1())) then
			local gm = vm:GetBoneMatrix(c.ins or c.mag)
			if gm and cp:DistToSqr(gm:GetTranslation()) < rI2 then act(c.speed and OP_FILL or OP_IN) end
		end
	end
	if c.rev and t and vmA and IsValid(w) then RevGesture(w, c, vm, t) end

	if slideGrab and c.pa and IsValid(w) and (RealTime() < pumpedT or not (w:Clip1() > 0 and w:GetNW2Bool(NW_UNCH))) then
		-- The pump only moves with a round waiting to be chambered: chambered or
		-- empty it stays forward (and for a moment after our own pump, until the
		-- server's "chambered" arrives). The pull is re-zeroed so it starts from
		-- the hand once it unlocks.
		pull, racked = 0, false
		slideStart = WorldToLocal(palm, angle_zero, vmP, vmA)
	elseif slideGrab then
		local cur = WorldToLocal(palm, angle_zero, vmP, vmA)
		cur:Sub(slideStart)
		local p = cur:Dot(slideAx) / Travel(c)
		pull = p < 0 and 0 or p > 1 and 1 or p
		if c.pa then
			-- Two strokes: back to the stop, then forward to chamber. The rack
			-- lands on the return, so the pump only locks once it's home.
			if pull >= RACK_AT then
				racked = true
			elseif racked and pull <= PUMP_HOME then
				racked = false
				act(OP_RACK, true)
			end
		elseif pull >= RACK_AT and not racked then
			-- Slide: racks at the back; re-arms once home again, so one grab
			-- can work it any number of times.
			racked = true
			act(OP_RACK, true)
		elseif racked and pull <= REARM then
			racked = false
		end
	end
end

hook.Add("VRMod_Tracking", "vrmr", Frame)

local function NearPouch() return pouchOK and cCfg and cCfg.copy and palm:DistToSqr(pouchP) < rP2 end

local function SlideMatrix()
	local c = cCfg
	return c and c.slide and IsValid(hookedVM) and hookedVM:GetBoneMatrix(c.slide)
end

-- The slide's matrix if the left hand may take it right now. Pumps always;
-- an open cylinder always (a grab shuts it); other slides unless
-- vrmod_manualreload_noslidegrab (then the trigger chambers).
local function NearSlide()
	local c = cCfg
	if not c then return end
	if c.rev then
		if not (IsValid(cWep) and cWep:GetNW2Bool(NW_OUT)) then return end
	elseif noSlideGrab and not c.pa then
		return
	end
	local sm = SlideMatrix()
	if sm and palm:DistToSqr(sm:GetTranslation()) < rS2 then return sm end
end

-- Pull is measured in the gun's frame along the slide's back axis.
local function StartSlide(sm)
	slideGrab, racked = true, false
	shP, shA = WorldToLocal(lhP, lhA, sm:GetTranslation(), sm:GetAngles())
	slideStart = WorldToLocal(palm, angle_zero, vmP, vmA)
	off:Set(cCfg.axis)
	off:Rotate(sm:GetAngles())
	slideAx = WorldToLocal(off, angle_zero, vector_origin, vmA)
end

------------------------------------------------------------------------------
-- Right hand follows the gun's animation (universal, any viewmodel weapon).
-- The hand keeps its tracked offset from the model's R_Hand bone as posed at
-- idle, then rides that bone: at idle nothing moves (custom grip offsets stay
-- intact), during fire/reload/sway anims the hand goes where the model's hand
-- goes. Same pin as the foregrip: tracking pose (what VRMod draws, refreshed
-- from the controller next frame) + netFrame (what others see). VRMod_PreRender
-- runs after the VM is placed, so this never moves the gun.
------------------------------------------------------------------------------

-- Toggled from Weapon Fixer > Animations. Renamed from
-- vrmod_manualreload_rhfollow so the new default reaches saved configs.
local cvFollow = CreateClientConVar("vrmod_rhfollow", "1", true, false, "Right hand follows the viewmodel's hand animation", 0, 1)
local rhRest, rhPending, mySID = {} -- [model] = {bone, pos, ang} | false

local function ProbeRight(mdl, w)
	local e = ClientsideModel(mdl, RENDERGROUP_OTHER)
	if not IsValid(e) then return false end
	e:SetNoDraw(true)
	local b = e:LookupBone(R_HAND)
	local r = false
	if b then
		local s = (w.ArcCW and ARCCW or GEN).Seq(e, w)
		e:SetSequence(s >= 0 and s or 0)
		e:SetCycle(0)
		e:SetupBones()
		local m = e:GetBoneMatrix(b)
		if m then r = {b, m:GetTranslation(), m:GetAngles()} end
	end
	e:Remove()
	return r
end

-- The followed right-hand pose, worked out once per frame from the RAW
-- controller pose. Everything that needs the right hand (this pin, and the
-- mirrored support grip) reads this, so neither depends on which
-- VRMod_PreRender hook happens to run first.
local followF, followP, followA = -1

local function FollowRight()
	local fn = FrameNumber()
	if fn == followF then return followP, followA end
	followF, followP, followA = fn, nil, nil
	if not cvFollow:GetBool() or g_VR.wmActive or g_VR.gunInLeftHand then return end
	local vm, vp, va = g_VR.viewModel, g_VR.viewModelPos, g_VR.viewModelAng
	local rh = g_VR.tracking and g_VR.tracking.pose_righthand
	if not (IsValid(vm) and vp and rh) then return end
	local mdl = vm:GetModel()
	local r = rhRest[mdl]
	if r == nil then
		local w = LocalPlayer():GetActiveWeapon()
		if rhPending or not IsValid(w) then return end
		rhPending = true
		timer.Simple(0, function() -- no entity spawns inside the render
			rhPending = nil
			if IsValid(w) then rhRest[mdl] = ProbeRight(mdl, w) end
		end)
		return
	end
	if not r then return end
	-- Bones are relative to the VM's own origin, which can trail vp/va by a
	-- render: read them in model space, then place them in the current frame.
	vm:InvalidateBoneCache()
	vm:SetupBones()
	local m = vm:GetBoneMatrix(r[1])
	if not m then return end
	local bp, ba = WorldToLocal(m:GetTranslation(), m:GetAngles(), vm:GetPos(), vm:GetAngles())
	bp, ba = LocalToWorld(bp, ba, vp, va)
	local hp, ha = WorldToLocal(rh.pos, rh.ang, vp, va)
	hp, ha = WorldToLocal(hp, ha, r[2], r[3])
	followP, followA = LocalToWorld(hp, ha, bp, ba)
	return followP, followA
end

hook.Add("VRMod_PreRender", "vrmr_rhfollow", function()
	local hp, ha = FollowRight()
	if not hp then return end
	local rh = g_VR.tracking.pose_righthand
	rh.pos, rh.ang = Vector(hp), Angle(ha) -- copies: the cache stays raw-derived
	mySID = mySID or LocalPlayer():SteamID()
	local gn = g_VR.net and g_VR.net[mySID]
	local nf = gn and gn.lerpedFrame
	if nf then nf.righthandPos, nf.righthandAng = rh.pos, rh.ang end
end)

------------------------------------------------------------------------------
-- Foregrip mode 1 provider (autorun_foregrip.lua reads vrmod.manualreload).
-- Managed viewmodel weapons get a fixed support-hand pose instead of the
-- free pin-where-grabbed grip:
--   * the model's own left hand, if it sits on the gun at idle (within the
--     max hand gap of the right hand) -- the VR left-hand frame IS the
--     L_Hand bone frame, so the bone matrix is the hand pose as-is
--   * otherwise the right hand mirrored across the gun, a little left of it
--     (fallback finger pose: curled, index out)
--   * pump weapons ride the pump; a chosen grip bone takes the position
------------------------------------------------------------------------------

local MR = {}
if vrmod then vrmod.manualreload = MR end
timer.Simple(0, function() if vrmod then vrmod.manualreload = MR end end) -- VRMod loaded after us
local gv, gA = Vector(), Angle()
local fingOn = false
local zoneKind, gripKind -- "slide" (hand rides the slide, no two-hand aim) or "grip"

-- Every right-handed viewmodel gun, manual reload on or off
function MR.GripActive()
	return gCfg ~= nil and IsValid(hookedVM) and not g_VR.wmActive
end

local function GripTarget()
	local c, vm = gCfg or EMPTY, hookedVM
	local t = g_VR.tracking
	local rh = t and t.pose_righthand
	local vp, va = g_VR.viewModelPos, g_VR.viewModelAng
	if not (rh and vp and IsValid(vm)) then return end
	local tp, ta
	if c.lh then
		local m = vm:GetBoneMatrix(c.lh)
		if m then tp, ta = m:GetTranslation(), m:GetAngles() end
	end
	local mirrored = not tp
	if mirrored then
		-- Mirror the gun's own grip (see Build), not the tracked hand:
		-- repositioning moves the hand on the gun, not the gun's grip, so the
		-- support hand stays on the gun. With rhfollow it rides the live bone,
		-- following the animation like the gun hand. No hand bone: tracked hand.
		local p, a = c.rhP, c.rhA
		local m = p and cvFollow:GetBool() and vm:GetBoneMatrix(c.rhB)
		if m then
			local ba = m:GetAngles()
			ba:RotateAroundAxis(ba:Forward(), 180)
			p, a = LocalToWorld(c.rhOff, angle_zero, m:GetTranslation(), ba)
			p, a = WorldToLocal(p, a, vm:GetPos(), vm:GetAngles())
		elseif not p then
			p, a = WorldToLocal(rh.pos, rh.ang, vp, va)
		end
		gv:SetUnpacked(p.x, gripSide - p.y, p.z)
		gA:SetUnpacked(a.p, -a.y, -a.r)
		tp, ta = LocalToWorld(gv, gA, vp, va)
	end
	local b = c.grip or (c.pa and not c.lh and c.slide)
	local m = b and vm:GetBoneMatrix(b)
	if m then
		-- Bone marks where the palm goes; the hand origin sits behind it.
		tp = m:GetTranslation()
		gv:Set(ta:Forward())
		gv:Mul(PALM)
		tp:Sub(gv)
		if c.pa and b ~= c.slide then tp:Add(pumpW) end
	elseif c.pa then
		tp:Add(pumpW) -- the model's left hand isn't parented to the pump
	end
	-- The correction is for the synthesized (mirrored) grip only: the model's
	-- own hand and bone-placed grips are where they are meant to be.
	if mirrored and not m and hasGof then tp, ta = LocalToWorld(gofP, gofA, tp, ta) end
	return tp, ta
end
-- While racking a slide the hand stays where it took the slide, riding it.
function MR.GripTarget()
	if gripKind == "slide" then
		local c, vm = cCfg, hookedVM
		local m = slideGrab and shP and c and c.slide and IsValid(vm) and vm:GetBoneMatrix(c.slide)
		if not m then return end
		return LocalToWorld(shP, shA, m:GetTranslation(), m:GetAngles())
	end
	return GripTarget()
end

function MR.GripNoAim() return gripKind == "slide" end

-- Slide first (not a pump: the pump IS the support grip), then the support
-- zone. The pouch and a held mag keep the left grip.
function MR.GripZone(pos)
	local c = gCfg or EMPTY
	if held or NearPouch() then return false end
	if not c.pa and NearSlide() then
		if c.rev then return false end -- the vrmr input hook shuts it
		zoneKind = "slide"
		return true
	end
	local tp = GripTarget()
	zoneKind = "grip"
	return tp ~= nil and tp:DistToSqr(pos) < gripR2
end

-- Support-hand fingers. The model's own left hand when it's on the gun and the
-- right hand isn't on the Weapon Fixer fallback (a rig bad enough for that
-- mangles both hands); otherwise copy whatever the right hand is using right
-- now -- model pose or fallback -- mirrored. Right->left is (-p, y, -r): VRMod's
-- default closed tables are exactly that mirror of each other (y is the curl).
local function LeftPose(c)
	local fb = vrmod_gripfix and vrmod_gripfix.handFallback
	local fallback = fb and IsValid(cWep) and fb[cWep:GetClass()]
	if c.lh and c.seq and not fallback then
		if not c.lfing then c.lfing = vrmod.GetLeftHandFingerAnglesFromModel(cMdl, c.seq) end
		return c.lfing, c.lfing
	end
	local go, gc, o, k = g_VR.openHandAngles, g_VR.closedHandAngles, {}, {}
	for i = 1, 15 do
		local a, b = go[i + 15], gc[i + 15]
		o[i] = Angle(-a.p, a.y, -a.r)
		k[i] = Angle(-b.p, b.y, -b.r)
	end
	return o, k
end

function MR.OnGrip(on)
	if on == fingOn then return end
	fingOn = on
	if not vrmod.SetLeftHandOpenFingerAngles then return end
	local c = gCfg or EMPTY -- pump/slide grabs need cCfg (SlideMatrix): managed only
	if on then
		gripKind = zoneKind
		local o, k = LeftPose(c)
		vrmod.SetLeftHandOpenFingerAngles(o)
		vrmod.SetLeftHandClosedFingerAngles(k)
		-- Gripping a pump IS holding the pump; a slide grab is the slide.
		if (c.pa or gripKind == "slide") and not slideGrab and vmA then
			local sm = SlideMatrix()
			if sm then StartSlide(sm) end
		end
	else
		vrmod.SetLeftHandOpenFingerAngles(vrmod.GetDefaultLeftHandOpenFingerAngles())
		vrmod.SetLeftHandClosedFingerAngles(vrmod.GetDefaultLeftHandClosedFingerAngles())
		if c.pa or gripKind == "slide" then EndSlide() end
		gripKind = nil
	end
end

hook.Add("VRMod_Input", "vrmr", function(action, pressed)
	local c = cCfg
	if c == nil then return end
	if action == "boolean_reload" then
		if not pressed or not IsValid(cWep) then return end
		if c.rev then RevStep(cWep, not c.copy) return end
		if c and c.mag then
			if not c.pump and not cWep:GetNW2Bool(NW_OUT) then act(OP_OUT) end
		elseif c.pump or pumpTbl[cWep:GetClass()] then
			act(OP_IN) -- no round part to hand-load: one round per press
		end -- no mag part: +reload passes through to the gun's own reload
		return
	end
	if not c then return end
	if action ~= "boolean_left_pickup" then return end
	if not pressed then
		if held or slideGrab then
			ours = true
			timer.Simple(0, function() ours = nil end)
		end
		held = false
		EndSlide()
		return
	end
	if held or slideGrab or not vmA then return end
	local sm = NearSlide()
	if sm then
		if c.rev then act(OP_SHUT) else StartSlide(sm) end
	elseif NearPouch() then
		TryHold()
	end
end)

-- Swallow VRMod's default left grab/drop while this owns the left hand.
hook.Add("VRMod_AllowDefaultAction", "vrmr", function(action)
	if action ~= "boolean_left_pickup" or not cCfg then return end
	if held or slideGrab or ours or NearPouch() or NearSlide() then return false end
end)

-- Pouch mag (always) + held mag.
hook.Add("PostDrawOpaqueRenderables", "vrmr", function(depth, sky)
	if depth or sky then return end
	Frame()
	if drops[1] then
		DropsThink()
		for i = 1, #drops do
			local d = drops[i]
			local e = d.e
			if IsValid(e) then
				e:SetPos(d.p)
				e:SetAngles(d.a)
				e:SetupBones()
				e:DrawModel()
			end
		end
	end
	local c = cCfg
	if not (pouchOK and c and c.copy) then return end
	local e = c.copy[1]
	-- Out of reserve: the pouch is empty, so nothing shows there.
	local w = cWep
	if IsValid(w) and (LP:GetAmmoCount(w:GetPrimaryAmmoType()) > 0 or cAd and cAd.Inf and cAd.Inf(w)) then
		e:SetPos(LocalToWorld(c.magNeg, angle_zero, pouchP, pouchA))
		e:SetAngles(pouchA)
		e:SetupBones()
		e:DrawModel()
	end
	if hp then
		e = c.copy[2]
		e:SetPos(hp)
		e:SetAngles(ha)
		e:SetupBones()
		e:DrawModel()
	end
end)

-- Grab hint: empty -> the mag well (pump: loading gate); loaded but
-- unchambered -> the slide / pump, when the hand can take it. A hidden mag
-- bone keeps its translation, so the well still resolves with the mag out.
-- Drawn right after the VM: VRMod draws the VM from its own translucent hook
-- (weapon bases squash DepthRange for it), so a sprite drawn before it in
-- that pass is painted over -- and the well sits inside the grip.
-- Solid ignore-Z sphere: an additive glow sprite at this size washed out to
-- nothing on a lit gun.
local HINT_COL = Color(255, 190, 40, 70)

-- VR: analog, same 0.5 rule as HandleInput (inp is rebuilt every frame and its
-- synthesized boolean_primaryfire only lands on the frame the trigger changes).
-- Desktop: left mouse (IN_ATTACK is stripped while dry, so KeyDown can't see it).
local function Trigger()
	local inp = g_VR.active and g_VR.input
	if inp then return tonumber(inp.vector1_primaryfire) or tonumber(inp.trigger_right_axis) or 0 end
	return input.IsMouseDown(MOUSE_LEFT) and 1 or 0
end

hook.Add("PostDrawViewModel", "vrmr_hint", function(vm, _, w)
	local c = cCfg
	if vm ~= hookedVM or w ~= cWep or not c or not IsValid(w) or not cvHint:GetBool() or Trigger() < 0.5 then return end
	local b
	if c.rev then
		-- Shut and empty: open it. Open: eject / load / shut all happen there.
		if w:Clip1() > 0 and not w:GetNW2Bool(NW_OUT) then return end
		b = c.slide
	elseif w:Clip1() > 0 then
		if not w:GetNW2Bool(NW_UNCH) then return end
		b = (c.pa or not noSlideGrab) and c.slide
	else
		b = c.ins or c.mag
	end
	local m = b and vm:GetBoneMatrix(b)
	if not m then return end
	render.SetColorMaterialIgnoreZ()
	render.DrawSphere(m:GetTranslation(), 1.2 + math.sin(RealTime() * 10) * 0.4, 10, 10, HINT_COL)
end)

------------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------------

local function setOvr(mdl, k, v)
	local o = ovr[mdl] or {}
	o[k] = v
	ovr[mdl] = next(o) and o or nil
	file.Write(FILE, util.TableToJSON(ovr, true))
	Free(cfgs[mdl])
	cfgs[mdl] = nil
	cWep = nil
end

concommand.Add("vrmr", function(_, _, a)
	local vm = hookedVM
	if not IsValid(vm) then return end
	local s, mdl, w = a[1], vm:GetModel(), LP:GetActiveWeapon()
	if s == "out" then act(OP_OUT)
	elseif s == "in" then act(OP_IN)
	elseif s == "rack" then act(OP_RACK)
	elseif s == "grab" then if held then held = false else TryHold() end
	elseif s == "next" then
		if not IsValid(w) then return end
		if cCfg and cCfg.rev then RevStep(w, true) return end
		local un = w:GetNW2Bool(NW_UNCH)
		if cCfg and cCfg.pump then act(un and OP_RACK or OP_IN) return end
		act(w:GetNW2Bool(NW_OUT) and OP_IN or un and OP_RACK or OP_OUT)
	elseif s == "pull" then pull = math.Clamp(tonumber(a[2]) or 0, 0, 1)
	elseif s == "hide" then preview = not preview
	elseif s == "spin" then spinVel = math.min(spinVel + 900, 1800)
	elseif s == "mag" or s == "slide" then
		local b = a[2]
		if b ~= "none" then
			b = tonumber(b) or (b and vm:LookupBone(b))
			b = b and vm:GetBoneName(b)
			if not b or b == "__INVALIDBONE__" then MsgN("[VRMR] bone not found") return end
		else
			b = false
		end
		setOvr(mdl, s, b)
	elseif s == "travel" then setOvr(mdl, "travel", tonumber(a[2]))
	elseif s == "axis" then
		local x, y, z = tonumber(a[2]), tonumber(a[3]), tonumber(a[4])
		setOvr(mdl, "axis", x and y and z and {x, y, z} or nil)
	elseif s == "lock" then setOvr(mdl, "lock", a[2] == "1")
	elseif s == "reset" then
		ovr[mdl] = nil
		setOvr(mdl, "_", nil)
	elseif s == "dump" then
		local c, r = cCfg or {}, {}
		for i, b in ipairs(c.mags or {}) do r[b] = i == 1 and "  [MAG pivot]" or "  [MAG]" end
		if c.slide then r[c.slide] = "  [SLIDE]" end
		MsgN("[VRMR] ", mdl)
		for i = 0, vm:GetBoneCount() - 1 do
			MsgN(string.format("%3d <%3d  %s%s", i, vm:GetBoneParent(i), vm:GetBoneName(i), r[i] or ""))
		end
	else
		MsgN("[VRMR] vrmr out|in|rack|next|grab|spin | pull <0-1> | hide | mag|slide <bone|idx|none> | travel <n> | axis x y z | lock 0/1 | reset | dump")
	end
end)

------------------------------------------------------------------------------
-- Weapon Fixer tab: pick mag / slide bones for the held weapon's model.
-- Single-click + Add works in VR (no ctrl-multiselect needed).
------------------------------------------------------------------------------

local function BuildPanel(root)
	local g = vgui.Create("DForm", root)
	g:SetName("Manual Reload")
	g:Dock(TOP)
	g:DockMargin(5, 5, 5, 0)
	g:CheckBox("Manual reload (VR)", "vrmod_manualreload")
	g:CheckBox("Auto: every weapon with a magazine", "vrmod_manualreload_auto")
	g:ControlHelp("Weapons below override auto either way. HL2 pistol/SMG/AR2/shotgun start on.")
	g:CheckBox("Reload helper (trigger held on an empty gun: the part to grab glows)", "vrmod_manualreload_hint")
	g:CheckBox("Disable grabbing slides (trigger chambers; pumps still grab)", "vrmod_manualreload_noslidegrab")
	g:NumSlider("Default slide travel", "vrmod_manualreload_travel", 0, 6, 2)
	g:NumSlider("Default pump travel", "vrmod_manualreload_pumptravel", 0, 8, 2)
	local wchk = g:CheckBox("Manual reload on the held weapon")
	local Refresh
	local TYPE = {[true] = "Pump (one round at a time)", [false] = "Magazine", rev = "Revolver (cylinder)", semi = "Semi-auto tube (bolt)"}
	local AUTO = "Auto (bone named pump / cyl)"
	local pc = g:ComboBox("Reload type")
	pc:AddChoice(AUTO, "auto")
	pc:AddChoice(TYPE[false], "mag")
	pc:AddChoice(TYPE[true], "pump")
	pc:AddChoice(TYPE.semi, "semi")
	pc:AddChoice(TYPE.rev, "rev")
	local rchk = g:CheckBox("Chambers on insert (no rack/pump needed)")
	g:ControlHelp("Load the mag or round and it's ready to fire. Also skips the pump after each shot.")
	local cl = vgui.Create("DListView")
	cl:SetTall(120)
	cl:AddColumn("Weapon")
	cl:AddColumn("Manual reload"):SetFixedWidth(90)
	cl:AddColumn("Type"):SetFixedWidth(60)
	cl:AddColumn("Rack"):SetFixedWidth(50)
	g:AddItem(cl)
	local function RefreshCls()
		cl:Clear()
		local seen = {}
		for _, t in ipairs({clsTbl, pumpTbl, rackTbl}) do
			for k in pairs(t) do seen[k] = true end
		end
		for k in SortedPairs(seen) do
			local v, p = clsTbl[k], pumpTbl[k]
			cl:AddLine(k, v == nil and "auto" or v and "on" or "off", p == nil and "auto" or isstring(p) and p or p and "pump" or "mag", rackTbl[k] and "no" or "yes")
		end
		local w = LP:GetActiveWeapon()
		wchk:SetChecked(IsValid(w) and Allowed(LP, w:GetClass()) or false)
		local p = IsValid(w) and pumpTbl[w:GetClass()]
		pc:SetValue(p == nil and AUTO or TYPE[p]) -- display only, no OnSelect
		rchk:SetChecked(IsValid(w) and rackTbl[w:GetClass()] or false)
	end
	pc.OnSelect = function(_, _, _, d)
		local w = LP:GetActiveWeapon()
		if not IsValid(w) then return end
		local v
		if d == "pump" then v = true elseif d == "mag" then v = false elseif d == "rev" or d == "semi" then v = d end
		pumpTbl[w:GetClass()] = v
		file.Write(PUMP_FILE, util.TableToJSON(pumpTbl))
		SyncCls()
		-- Pump/mag changes which bones are the mag and slide: rebuild the model.
		if IsValid(hookedVM) then
			local m = hookedVM:GetModel()
			Free(cfgs[m])
			cfgs[m] = nil
		end
		cWep = nil
		timer.Simple(0.2, function() if Refresh then Refresh() end end)
	end
	rchk.OnChange = function(_, v)
		local w = LP:GetActiveWeapon()
		if not IsValid(w) then return end
		rackTbl[w:GetClass()] = v or nil
		file.Write(RACK_FILE, util.TableToJSON(rackTbl))
		SyncCls()
		RefreshCls()
	end
	wchk.OnChange = function(_, v)
		local w = LP:GetActiveWeapon()
		if not IsValid(w) then return end
		SetCls(w:GetClass(), v)
		RefreshCls()
	end
	g:Button("Remove selected (back to auto)").DoClick = function()
		for _, ln in ipairs(cl:GetSelected()) do
			local k = ln:GetColumnText(1)
			clsTbl[k], pumpTbl[k], rackTbl[k] = nil, nil, nil
		end
		file.Write(PUMP_FILE, util.TableToJSON(pumpTbl))
		file.Write(RACK_FILE, util.TableToJSON(rackTbl))
		SetCls("_", nil)
		RefreshCls()
	end

	local f = vgui.Create("DForm", root)
	f:SetName("Manual Reload - held weapon bones")
	f:Dock(TOP)
	f:DockMargin(5, 5, 5, 0)
	local info = f:Help("")
	local lv = vgui.Create("DListView")
	lv:SetTall(240)
	lv:SetMultiSelect(true)
	lv:AddColumn("#"):SetFixedWidth(28)
	lv:AddColumn("<"):SetFixedWidth(28)
	lv:AddColumn("Bone")
	lv:AddColumn("Role"):SetFixedWidth(80)
	f:AddItem(lv)

	function Refresh()
		if not IsValid(lv) then return end
		RefreshCls()
		lv:Clear()
		local vm = hookedVM
		if not IsValid(vm) then info:SetText("No viewmodel.") return end
		local c, r = cCfg or cfgs[vm:GetModel()], {} -- unmanaged: the debug build, if any
		if c then
			for _, b in ipairs(c.magB or {}) do r[b] = "mag" end
			for i, b in ipairs(c.mags or {}) do r[b] = i == 1 and "MAG pivot" or "MAG" end
			if c.slide then
				for _, b in ipairs(c.kids) do r[b] = "slide" end
				r[c.slide] = c.pa and "PUMP" or c.rev and "CYLINDER" or "SLIDE"
			end
			if c.ins then r[c.ins] = "INSERT" end
			if c.lh then r[c.lh] = "GRIP hand" end
			if c.grip then r[c.grip] = "GRIP" end
		end
		for i = 0, vm:GetBoneCount() - 1 do lv:AddLine(i, vm:GetBoneParent(i), vm:GetBoneName(i), r[i] or "") end
		local w = LP:GetActiveWeapon()
		info:SetText(string.format("%s\n%s\n%s", IsValid(w) and w:GetClass() or "-", vm:GetModel(),
			c and ((c.pump and (c.pa and "Managed, pump (mag = one round, slide = pump)." or "Managed, semi tube (mag = one round, slide = bolt).") or c.rev and "Managed, revolver (mag = loader/round, slide = cylinder)." or "Managed, mag-fed.")
				.. (c.grip and " Grip: bone." or c.lh and " Grip: model's left hand." or " Grip: mirrored right hand.")) or c == false and "Managed, but no mag/slide bones found." or "Not managed (mode off or unsupported weapon)."))
	end

	local function Sel()
		local vm, t = hookedVM, {}
		for _, ln in ipairs(lv:GetSelected()) do t[#t + 1] = tonumber(ln:GetValue(1)) end
		table.sort(t)
		for i = 1, #t do t[i] = vm:GetBoneName(t[i]) end
		return t
	end
	local function CurMags()
		local vm, t = hookedVM, {}
		for i, b in ipairs(cCfg and cCfg.mags or {}) do t[i] = vm:GetBoneName(b) end
		return t
	end
	local function Set(k, v)
		if not IsValid(hookedVM) then return end
		setOvr(hookedVM:GetModel(), k, v)
		timer.Simple(0.2, function() if IsValid(lv) then Refresh() end end)
	end

	-- One row per part: label + compact buttons (all single-click, VR-safe).
	local function Row(label, btns)
		local p = vgui.Create("DPanel")
		p:SetTall(22)
		p:SetPaintBackground(false)
		local l = vgui.Create("DLabel", p)
		l:SetText(label)
		l:SetDark(true)
		l:SetWide(48)
		l:Dock(LEFT)
		for i = 1, #btns do
			local x = vgui.Create("DButton", p)
			x:SetText(btns[i][1])
			x:SizeToContentsX(14)
			x:Dock(LEFT)
			x:DockMargin(2, 0, 0, 0)
			x.DoClick = btns[i][2]
		end
		f:AddItem(p)
	end

	Row("Mag", {
		{"Add", function()
			local t, have = CurMags(), {}
			for _, v in ipairs(t) do have[v] = true end
			for _, v in ipairs(Sel()) do if not have[v] then t[#t + 1] = v end end
			if t[1] then Set("mag", t) end
		end},
		{"Remove", function()
			local drop, t = {}, {}
			for _, v in ipairs(Sel()) do drop[v] = true end
			for _, v in ipairs(CurMags()) do if not drop[v] then t[#t + 1] = v end end
			Set("mag", t[1] and t or false)
		end},
		{"Pivot", function()
			local p = Sel()[1]
			if not p then return end
			local t = {p}
			for _, v in ipairs(CurMags()) do if v ~= p then t[#t + 1] = v end end
			Set("mag", t)
		end},
		{"None", function() Set("mag", false) end},
		{"Auto", function() Set("mag", nil) end},
	})
	Row("Slide", {
		{"Set", function() local v = Sel()[1] if v then Set("slide", v) end end},
		{"None", function() Set("slide", false) end},
		{"Auto", function() Set("slide", nil) end},
	})
	Row("Insert", {
		{"Set", function() local v = Sel()[1] if v then Set("ins", v) end end},
		{"Default", function() Set("ins", nil) end},
	})
	Row("Grip", {
		{"Set", function() local v = Sel()[1] if v then Set("grip", v) end end},
		{"Auto", function() Set("grip", nil) end},
		{"Mirror", function() Set("grip", false) end},
	})
	f:ControlHelp("Mag none: the gun reloads normally (pump: one round per press). Slide none: inserts chamber by themselves.")
	f:ControlHelp("Grip (support hand, foregrip mode 1): Auto uses the model's left hand if it sits on the gun, else the right hand mirrored. Set = palm goes on that bone. Pump guns grip the pump.")
	Row("Model", {
		{"Reset all to auto", function()
			if not IsValid(hookedVM) then return end
			ovr[hookedVM:GetModel()] = nil
			Set("_", nil)
		end},
		{"Refresh", Refresh},
	})

	local cb = f:CheckBox("Preview mag hidden")
	cb:SetChecked(preview)
	cb.OnChange = function(_, v) preview = v end
	cb = f:CheckBox("Slide locks back when empty")
	cb:SetChecked(cCfg and cCfg.lock == true or false)
	cb.OnChange = function(_, v) Set("lock", v) end
	local sp = f:NumSlider("Preview slide pull", nil, 0, 1, 2)
	sp:SetValue(pull)
	sp.OnValueChanged = function(_, v) pull = v end
	local st = f:NumSlider("Slide/pump travel (this model)", nil, 0, 8, 2)
	st:SetValue(cCfg and Travel(cCfg) or travel)
	st.OnValueChanged = function(_, v)
		timer.Create("vrmr_travel", 0.3, 1, function() Set("travel", v) end)
	end
	Refresh()
end

hook.Add("VRMod_WeaponFix_Tabs", "vrmr", function(tabs)
	tabs[#tabs + 1] = {"Manual Reload", BuildPanel, "icon16/arrow_refresh.png"}
end)

------------------------------------------------------------------------------
-- Debug overlay. PostDrawViewModel hooks run before the SWEP method, so on
-- desktop ArcCW's VM cam is still pushed; in VR it's VRMod's eye cam.
------------------------------------------------------------------------------

local COL_IN, COL_OUT, COL_AX, COL_P = Color(255, 220, 0), Color(255, 60, 60), Color(0, 255, 120), Color(0, 160, 255)
local AX = {Vector(1, 0, 0), Vector(0, 1, 0), Vector(0, 0, 1)}
local va, vb = Vector(), Vector()

local function cross(p, s, col)
	for i = 1, 3 do
		va:Set(AX[i]) va:Mul(s)
		vb:Set(p) vb:Sub(va)
		va:Add(p)
		render.DrawLine(vb, va, col, false)
	end
end

-- Debug wants the bones of whatever is held, managed or not: unmanaged
-- weapons get the same Build into the shared cache (built off the render).
local dbgPending
local function DbgCfg(vm, w)
	if cCfg then return cCfg end
	local mdl = vm:GetModel()
	local c = cfgs[mdl]
	if c ~= nil or dbgPending then return c end
	dbgPending = true
	timer.Simple(0, function()
		dbgPending = nil
		if IsValid(vm) and IsValid(w) and vm:GetModel() == mdl and cfgs[mdl] == nil then
			cfgs[mdl] = Build(vm, w.ArcCW and ARCCW or GEN, w, mdl)
		end
	end)
end

local labelAng = Angle()
local function Label(p, txt, col)
	cam.Start3D2D(p, labelAng, 0.025)
	surface.SetFont("BudgetLabel")
	surface.SetTextColor(col)
	surface.SetTextPos(6, -6)
	surface.DrawText(txt)
	cam.End3D2D()
end

local function Mark(vm, b, size, col, txt)
	local m = b and vm:GetBoneMatrix(b)
	if not m then return end
	local p = m:GetTranslation()
	cross(p, size, col)
	Label(p, txt .. "  " .. vm:GetBoneName(b), col)
	return m, p
end

-- Every bone the system uses, labelled. VM draw context, so it lines up on
-- desktop (ArcCW's VM cam is still pushed here) and in VR alike.
hook.Add("PostDrawViewModel", "vrmr_dbg", function(vm, _, w)
	if not dbg or vm ~= hookedVM or not IsValid(w) then return end
	local c = DbgCfg(vm, w)
	if not c then return end
	labelAng:Set(EyeAngles())
	labelAng:RotateAroundAxis(labelAng:Up(), -90)
	labelAng:RotateAroundAxis(labelAng:Forward(), 90)
	cam.IgnoreZ(true)
	local hidden = preview or w:GetNW2Bool(NW_OUT) or c.pump and w:Clip1() <= 0
	local mags = c.mags or EMPTY
	for i = 1, #mags do
		Mark(vm, mags[i], i == 1 and 0.6 or 0.4, hidden and COL_OUT or COL_IN,
			(c.pump and "ROUND" or c.rev and (c.speed and "LOADER" or "ROUND") or "MAG") .. (i == 1 and " pivot" or ""))
	end
	local m, p = Mark(vm, c.slide, 0.3, COL_P, c.pa and "PUMP" or c.rev and "CYL" or "SLIDE")
	if m then
		off:Set(c.axis)
		off:Rotate(m:GetAngles())
		off:Mul(Travel(c))
		off:Add(p)
		render.DrawLine(p, off, COL_AX, false)
	end
	if c.ins then Mark(vm, c.ins, 0.4, COL_AX, "INSERT") end
	if c.grip then Mark(vm, c.grip, 0.4, COL_AX, "GRIP")
	elseif c.lh then Mark(vm, c.lh, 0.4, COL_AX, "GRIP hand") end
	if cvFollow:GetBool() then
		local r = rhRest[vm:GetModel()]
		if r then Mark(vm, r[1], 0.4, COL_P, "R hand follow") end
	end
	cam.IgnoreZ(false)
end)

-- Grab zones (world space: matches the VM in VR, pouch only on desktop).
hook.Add("PostDrawTranslucentRenderables", "vrmr_dbg", function(depth, sky)
	if depth or sky or not dbg or not pouchOK then return end
	render.SetColorMaterial()
	render.DrawWireframeSphere(pouchP, math.sqrt(rP2), 10, 10, NearPouch() and COL_OUT or COL_P, true)
	if not (g_VR and g_VR.active) then return end
	cross(palm, 0.5, COL_AX)
	local sm = SlideMatrix()
	if sm then render.DrawWireframeSphere(sm:GetTranslation(), math.sqrt(rS2), 8, 8, slideGrab and COL_OUT or COL_AX, true) end
	if hp then
		render.DrawWireframeSphere(hpt, math.sqrt(rI2), 8, 8, COL_IN, true)
	end
	if MR.GripActive() then
		local tp, ta = GripTarget()
		if tp then
			render.DrawWireframeSphere(tp, math.sqrt(gripR2), 8, 8, fingOn and COL_OUT or COL_IN, true)
			render.DrawLine(tp, tp + ta:Forward() * 4, COL_AX, false)
		end
	end
end)

local L = {}
hook.Add("HUDPaint", "vrmr_dbg", function()
	if not dbg or not IsValid(hookedVM) then return end
	local w = LP:GetActiveWeapon()
	if not IsValid(w) then return end
	local vm = hookedVM
	local c = DbgCfg(vm, w)
	local k = Kind(w, w.ArcCW and ARCCW or GEN)
	L[1] = string.format("[VRMR] %s  %s  mode %d  %s  srv sync %s  type %s (%s)", w:GetClass(), cAd and cAd.name or "-", cvMode:GetInt(),
		cAd and (c and "managed" or "probing") or "unmanaged (bones shown for reference)", LP:GetNW2Bool("vrmr_sync") and "yes" or "NO",
		k == "rev" and "revolver" or k == "semi" and "semi" or k and "pump" or k == false and "mag" or "?", pumpTbl[w:GetClass()] ~= nil and "forced in Weapon Fixer" or "auto")
	L[2] = "model  " .. vm:GetModel()
	if c then
		local st = c.pump and "TUBE" or w:GetNW2Bool(NW_OUT) and (c.rev and "OPEN" or "OUT") or c.rev and "SHUT" or "IN"
		L[3] = c.mag and string.format("%s %s +%d (%d bones)  insert %s  %s  copy %s  held %s", c.pump and "shell " or "mag   ",
			vm:GetBoneName(c.mag), #c.mags - 1, #c.magB, vm:GetBoneName(c.ins or c.mag), st,
			c.copy and "ok" or "none", tostring(held == true)) or "mag    none  " .. st
		local ax = c.axis
		L[4] = c.slide and string.format("slide  %s  axis %.0f %.0f %.0f  travel %.2f  lock %s  grab %s", vm:GetBoneName(c.slide),
			ax.x, ax.y, ax.z, Travel(c), tostring(c.lock == true), tostring(slideGrab == true)) or "slide  none"
	else
		L[3], L[4] = "", ""
	end
	local real = w:Clip1()
	L[5] = string.format("clip %d  spent %d  reserve %d  chamber %s  pull %.2f%s", real, w:GetNW2Int(NW_SPENT),
		LP:GetAmmoCount(w:GetPrimaryAmmoType()),
		real <= 0 and "empty" or w:GetNW2Bool(NW_UNCH) and "NEEDS RACK" or "loaded", pull, preview and "  [hide preview]" or "")
	surface.SetFont("BudgetLabel")
	surface.SetTextColor(255, 255, 255, 255)
	local y = ScrH() * 0.3
	for i = 1, 5 do
		surface.SetTextPos(20, y)
		surface.DrawText(L[i])
		y = y + 14
	end
end)