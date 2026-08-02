-- vrmod_holstersystem_type2.lua
-- Combined holster system + menu. No external loaders required.

AddCSLuaFile()

-- ===================== CONVARS =====================
if CLIENT then
    CreateClientConVar("vrmod_pouch_enabled",            1,                      true, FCVAR_ARCHIVE, nil, 0, 1)
    CreateClientConVar("vrmod_pouch_visiblename",        1,                      true, FCVAR_ARCHIVE, nil, 0, 1)
    CreateClientConVar("vrmod_pouch_visiblename_hud",    1,                      true, FCVAR_ARCHIVE, nil, 0, 1)
    CreateClientConVar("vrmod_pouch_lefthandwep_enable", "0",                    true, FCVAR_ARCHIVE)
    CreateClientConVar("vrmod_holster_showmodels",       1,                      true, FCVAR_ARCHIVE, "Show holstered weapon world models", 0, 1)
    CreateClientConVar("vrmod_holster_prop_maxvolume",   5750,                   true, FCVAR_ARCHIVE, "Max OBB volume for holsterable props (0=no limit)", 0, 999999)
    CreateClientConVar("vrmod_holster_ragdolls",         1,                      true, FCVAR_ARCHIVE, "Allow holstering ragdolls", 0, 1)
    CreateClientConVar("vrmod_holster_ragdoll_models",   1,                      true, FCVAR_ARCHIVE, "Show ragdoll models on holster slots", 0, 1)
    CreateClientConVar("vrmod_holster_persist",         1,                      true, FCVAR_ARCHIVE, "Persist holstered weapons across map changes", 0, 1)

    for i = 1, 4 do
        CreateClientConVar("vrmod_pouch_weapon_" .. i, "", true, FCVAR_ARCHIVE)
        CreateClientConVar("vrmod_pouch_size_"   .. i, 12, true, FCVAR_ARCHIVE)
    end
end

-- ===================== SERVER =====================
if SERVER then
    util.AddNetworkString("vrmod_holster_spawn_entity")
    util.AddNetworkString("vrmod_holster_pickup_trigger")
    util.AddNetworkString("vrmod_holster_absorb_weapon")
    util.AddNetworkString("vrmod_lefthand_flag")
    util.AddNetworkString("vrmod_holster_cache_ammo")
    util.AddNetworkString("vrmod_holster_models_sync")
    util.AddNetworkString("vrmod_holster_ragdoll_sync")

    hook.Add("PlayerInitialSpawn", "HolsterAmmoCache_Init", function(ply)
        ply._holster_ammo = {}
        ply._holster_ragdolls = {}
    end)

    -- ── Server-side holster persistence across changelevel ────────────────
    local SV_PERSIST_DIR  = "vrmod"
    local SV_PERSIST_FILE = "vrmod/sv_holster_persist.json"

    hook.Add("ShutDown", "vrmod_holster_sv_persist_save", function()
        local allData = {}
        local any = false
        for _, ply in ipairs(player.GetAll()) do
            if not IsValid(ply) then continue end
            local sid = ply:SteamID()
            if not g_VR[sid] then continue end
            local slots = ply._holster_slots
            if not slots then continue end
            local plyData = { slots = {}, ammo = {} }
            local hasAnything = false
            for i = 1, 4 do
                local v = slots[i] or ""
                if v ~= "" and not string.find(v, "|", 1, true) then
                    plyData.slots[tostring(i)] = v
                    hasAnything = true
                    if ply._holster_ammo and ply._holster_ammo[i] then
                        plyData.ammo[tostring(i)] = ply._holster_ammo[i]
                    end
                end
            end
            if hasAnything then
                allData[sid] = plyData
                any = true
            end
        end
        if not any then
            if file.Exists(SV_PERSIST_FILE, "DATA") then file.Delete(SV_PERSIST_FILE) end
            return
        end
        if not file.IsDir(SV_PERSIST_DIR, "DATA") then file.CreateDir(SV_PERSIST_DIR) end
        file.Write(SV_PERSIST_FILE, util.TableToJSON(allData))
    end)

    hook.Add("PlayerInitialSpawn", "vrmod_holster_sv_persist_restore", function(ply)
        if not file.Exists(SV_PERSIST_FILE, "DATA") then return end
        local sid = ply:SteamID()
        timer.Simple(3, function()
            if not IsValid(ply) then return end
            if not file.Exists(SV_PERSIST_FILE, "DATA") then return end
            local raw = file.Read(SV_PERSIST_FILE, "DATA")
            if not raw or raw == "" then return end
            local allData = util.JSONToTable(raw)
            if not allData or not allData[sid] then return end
            local plyData = allData[sid]
            local slots = plyData.slots or {}
            local ammo  = plyData.ammo or {}
            for i_str, cls in pairs(slots) do
                if cls and cls ~= "" and not ply:HasWeapon(cls) then
                    if weapons.GetStored(cls) then
                        ply:Give(cls, true)
                    else
                        slots[i_str] = nil
                    end
                end
            end
            if not ply._holster_ammo then ply._holster_ammo = {} end
            for i_str, ammoData in pairs(ammo) do
                local i = tonumber(i_str)
                if i then
                    ply._holster_ammo[i] = {
                        lr = ammoData.lr or 0,
                        ch = ammoData.ch or 0,
                        mg = ammoData.mg or "",
                    }
                end
            end
            timer.Simple(0.1, function()
                if not IsValid(ply) then return end
                if ply:HasWeapon("weapon_vrmod_empty") then
                    ply:SelectWeapon("weapon_vrmod_empty")
                end
            end)
            allData[sid] = nil
            local remaining = false
            for _ in pairs(allData) do remaining = true break end
            if remaining then
                file.Write(SV_PERSIST_FILE, util.TableToJSON(allData))
            else
                file.Delete(SV_PERSIST_FILE)
            end
        end)
    end)

    hook.Add("PlayerDeath", "HolsterAmmoCache_Clear", function(ply)
        ply._holster_ammo = {}
        if ply._holster_ragdolls then
            for i, rag in pairs(ply._holster_ragdolls) do
                if IsValid(rag) then rag:Remove() end
            end
            ply._holster_ragdolls = {}
        end
    end)

    hook.Add("PlayerPostThink", "VRMod_EnsureEmptyHands", function(ply)
        if not ply:Alive() then return end
        if not g_VR[ply:SteamID()] then return end
        if ply:HasWeapon("weapon_vrmod_empty") then return end
        ply:Give("weapon_vrmod_empty")
        local wep = ply:GetActiveWeapon()
        if not IsValid(wep) then ply:SelectWeapon("weapon_vrmod_empty") end
    end)

    -- ── Holster model sync ───────────────────────────────────────────────
    net.Receive("vrmod_holster_models_sync", function(_, ply)
        if not ply._holster_slots then ply._holster_slots = {} end
        for i = 1, 4 do
            ply._holster_slots[i] = net.ReadString()
        end
        net.Start("vrmod_holster_models_sync")
        net.WriteEntity(ply)
        for i = 1, 4 do net.WriteString(ply._holster_slots[i]) end
        net.SendOmit(ply)
    end)

    hook.Add("PlayerInitialSpawn", "HolsterModels_SyncOnJoin", function(ply)
        timer.Simple(4, function()
            if not IsValid(ply) then return end
            for _, other in ipairs(player.GetAll()) do
                if other ~= ply and other._holster_slots then
                    net.Start("vrmod_holster_models_sync")
                    net.WriteEntity(other)
                    for i = 1, 4 do net.WriteString(other._holster_slots[i] or "") end
                    net.Send(ply)
                end
            end
        end)
    end)

    hook.Add("PlayerDeath", "HolsterModels_ClearOnDeath", function(ply)
        if not ply._holster_slots then return end
        for i = 1, 4 do ply._holster_slots[i] = "" end
        net.Start("vrmod_holster_models_sync")
        net.WriteEntity(ply)
        for i = 1, 4 do net.WriteString("") end
        net.Broadcast()
    end)

    net.Receive("vrmod_holster_cache_ammo", function(len, ply)
        local slot = net.ReadUInt(3)
        if slot < 1 or slot > 5 then return end
        if not ply._holster_ammo then ply._holster_ammo = {} end
        ply._holster_ammo[slot] = {
            lr = net.ReadUInt(16),
            ch = net.ReadUInt(8),
            mg = net.ReadString(),
        }
    end)

    net.Receive("vrmod_holster_absorb_weapon", function(len, ply)
        local ent = net.ReadEntity()
        if not IsValid(ent) then return end
        if ent:IsWeapon() then
            local ammotype = ent.Primary and ent.Primary.Ammo
            if ammotype then
                local rounds = (ent.AVR_LoadedRounds or 0) + (ent.AVR_Chambered or 0)
                if rounds == 0 then rounds = ent.Primary.ClipSize or 0 end
                if rounds > 0 then ply:GiveAmmo(rounds, ammotype) end
            end
        end
        ent:Remove()
    end)

    -- ── Server-side holster ragdolls ──────────────────────────────────────
    local holsterSlotOffsets  = { -21, -21, 11, 11 }
    local holsterSlotVertical = { -10, -10, 0, 0 }

    net.Receive("vrmod_holster_ragdoll_sync", function(len, ply)
        local slot = net.ReadUInt(3)
        local model = net.ReadString()
        if slot < 1 or slot > 5 then return end
        if not ply._holster_ragdolls then ply._holster_ragdolls = {} end

        -- Remove existing ragdoll in this slot
        local existing = ply._holster_ragdolls[slot]
        if IsValid(existing) then
            -- Clear tags; don't Remove — entity may be held by VRMod pickup
            existing:SetNWInt("vrmod_holster_slot", 0)
            existing:SetNWEntity("vrmod_holster_owner", NULL)
            -- Restore normal damping
            for i = 0, existing:GetPhysicsObjectCount() - 1 do
                local phys = existing:GetPhysicsObjectNum(i)
                if IsValid(phys) then phys:SetDamping(0, 0) end
            end
            ply._holster_ragdolls[slot] = nil
        end

        -- Empty model = clear only
        if model == "" then return end

        local skin = net.ReadUInt(8)
        local bgCount = net.ReadUInt(4)
        local bgs = {}
        for i = 0, bgCount - 1 do
            bgs[i] = net.ReadUInt(4)
        end

        local rag = ents.Create("prop_ragdoll")
        if not IsValid(rag) then return end
        rag:SetModel(model)
        rag:SetPos(ply:GetPos())
        rag:Spawn()
        rag:SetSkin(skin)
        for bg, val in pairs(bgs) do
            rag:SetBodygroup(bg, val)
        end
        rag:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
        rag:SetNWInt("vrmod_holster_slot", slot)
        rag:SetNWEntity("vrmod_holster_owner", ply)
        for i = 0, rag:GetPhysicsObjectCount() - 1 do
            local phys = rag:GetPhysicsObjectNum(i)
            if IsValid(phys) then
                phys:SetDamping(15, 15)
                phys:EnableGravity(true)
                phys:Wake()
            end
        end
        ply._holster_ragdolls[slot] = rag
    end)

    -- Position holster ragdolls each tick
    hook.Add("Think", "vrmod_holster_ragdoll_position", function()
        for _, ply in ipairs(player.GetAll()) do
            if not ply:Alive() or not ply._holster_ragdolls then continue end
            local hasAny = false
            for i = 1, 4 do
                if IsValid(ply._holster_ragdolls[i]) then hasAny = true break end
            end
            if not hasAny then continue end

            local pelvisBone = ply:LookupBone("ValveBiped.Bip01_Pelvis")
            if not pelvisBone then continue end
            local hipPos, hipAng = ply:GetBonePosition(pelvisBone)
            if not hipPos then continue end
            local headPos = ply:EyePos()
            local headAng = ply:EyeAngles()
            local bodyFwd = headAng:Forward()
            local hipRight = hipAng:Right()

            local positions = {
                headPos + headAng:Right() * 7,
                headPos - headAng:Right() * 7,
                hipPos  + hipRight * 16,
                hipPos  - hipRight * 16,
            }

            for i = 1, 4 do
                local rag = ply._holster_ragdolls[i]
                if not IsValid(rag) then continue end
                -- Ragdolls use half the forward offset to sit closer to the body
                local targetPos = positions[i] + bodyFwd * (holsterSlotOffsets[i] * 0.4) + Vector(0, 0, holsterSlotVertical[i])
                local phys = rag:GetPhysicsObjectNum(0)
                if IsValid(phys) then
                    phys:SetPos(targetPos)
                    phys:SetAngles(Angle(0, headAng.yaw + 180, 0))
                    phys:Wake()
                end
            end
        end
    end)

    net.Receive("vrmod_holster_spawn_entity", function(len, ply)
        local entClass   = net.ReadString()
        local entModel   = net.ReadString()
        local handPos    = net.ReadVector()
        local handAng    = net.ReadAngle()
        local isLeftHand = net.ReadBool()
        local slot       = net.ReadUInt(3)

        -- ── Prop/entity path: skip all weapon/DW logic ──
        if entModel ~= "" then
            local spawnedEnt
            -- Reuse existing holster ragdoll if one exists for this slot
            if entClass == "prop_ragdoll" and ply._holster_ragdolls and IsValid(ply._holster_ragdolls[slot]) then
                spawnedEnt = ply._holster_ragdolls[slot]
                ply._holster_ragdolls[slot] = nil
                spawnedEnt:SetNWInt("vrmod_holster_slot", 0)
                spawnedEnt:SetNWEntity("vrmod_holster_owner", NULL)
                spawnedEnt:SetPos(handPos)
                spawnedEnt:SetAngles(handAng)
                for i = 0, spawnedEnt:GetPhysicsObjectCount() - 1 do
                    local phys = spawnedEnt:GetPhysicsObjectNum(i)
                    if IsValid(phys) then
                        phys:SetDamping(0, 0)
                        phys:SetPos(handPos)
                        phys:EnableMotion(false)
                    end
                end
                spawnedEnt._holster_frozen = true
            else
                spawnedEnt = ents.Create(entClass)
                if not IsValid(spawnedEnt) then return end
                spawnedEnt:SetModel(entModel)
                spawnedEnt:SetPos(handPos)
                spawnedEnt:SetAngles(handAng)
                spawnedEnt:Spawn()
                local phys = spawnedEnt:GetPhysicsObject()
                if IsValid(phys) then phys:EnableMotion(false) end
                spawnedEnt._holster_frozen = true
            end
            timer.Simple(0.05, function()
                if not IsValid(ply) or not IsValid(spawnedEnt) then return end
                local hp = isLeftHand and vrmod.GetLeftHandPos(ply) or vrmod.GetRightHandPos(ply)
                local ha = isLeftHand and vrmod.GetLeftHandAng(ply) or vrmod.GetRightHandAng(ply)
                if hp and ha then spawnedEnt:SetPos(hp + ha:Forward() * 3) elseif hp then spawnedEnt:SetPos(hp) end
                net.Start("vrmod_holster_pickup_trigger")
                net.WriteBool(isLeftHand)
                net.WriteEntity(spawnedEnt)
                net.Send(ply)
            end)
            return
        end

        -- Pop cached ammo for this slot (per-instance state).
        if not ply._holster_ammo then ply._holster_ammo = {} end
        local cached = ply._holster_ammo[slot]
        ply._holster_ammo[slot] = nil






        net.Send(ply)

        -- ── DW entry: active ArcVR weapon + grabbing with the other hand ──
        local activeWep = ply:GetActiveWeapon()
        local activeInLeft = false
        if IsValid(activeWep) and activeWep.ArcticVR
           and ArcticVR and ArcticVR.InterceptPickup
           and isLeftHand ~= (not isLeftHand and activeInLeft or activeInLeft) then
        end

        local prevActiveInLeft = false
        if IsValid(activeWep) and activeWep.ArcticVR then
            prevActiveInLeft = not isLeftHand
            ply._avr_pickupHand = isLeftHand
            local awDef = weapons.GetStored(activeWep:GetClass())
            ply._dw_ammoCache = {
                lr = activeWep.LoadedRounds or 0,
                ch = activeWep.Chambered or 0,
                mg = activeWep.Magazine or "",
                fm = activeWep.Firemode or (awDef and awDef.Firemodes and awDef.Firemodes[1]) or 1,
            }

            local avrState = nil
            if cached then
                avrState = {
                    LoadedRounds = cached.lr,
                    Chambered    = cached.ch,
                    Magazine     = cached.mg ~= "" and cached.mg or nil,
                }
            else
                local existingWep = ply:GetWeapon(entClass)
                if IsValid(existingWep) and existingWep.ArcticVR then
                    avrState = {
                        LoadedRounds = existingWep.LoadedRounds or 0,
                        Chambered    = existingWep.Chambered or 0,
                        Magazine     = existingWep.Magazine,
                    }
                end
            end

            local isDuplicate = entClass == activeWep:GetClass()
            local tempEnt = ents.Create(entClass)
            if IsValid(tempEnt) then
                tempEnt:SetPos(handPos)
                tempEnt:Spawn()
                if avrState then
                    tempEnt.VRMod_ArcVR_Stasis = avrState
                    tempEnt.AVR_LoadedRounds = avrState.LoadedRounds
                    tempEnt.AVR_Chambered    = avrState.Chambered
                    tempEnt.AVR_Magazine     = avrState.Magazine
                end
                if ArcticVR.InterceptPickup(ply, tempEnt, entClass, isDuplicate, avrState) then
                    return
                end
                if IsValid(tempEnt) then tempEnt:Remove() end
            end
        end

        -- ── Fast path: weapon in inventory, no DW ──
        if ply:HasWeapon(entClass) then
            ply:SelectWeapon(entClass)
            if cached then
                local wep = ply:GetWeapon(entClass)
                if IsValid(wep) and wep.ArcticVR then
                    wep.LoadedRounds = cached.lr
                    wep.Chambered    = cached.ch
                    wep.Magazine     = cached.mg ~= "" and cached.mg or nil
                    if wep.SendWeapon then wep:SendWeapon(true, true) end
                end
            end
            return
        end

        -- Slow path: weapon not in inventory - give directly
        ply:Give(entClass, true)
        timer.Simple(0, function()
            if not IsValid(ply) then return end
            ply:SelectWeapon(entClass)
            if cached then
                local wep = ply:GetWeapon(entClass)
                if IsValid(wep) and wep.ArcticVR then
                    wep.LoadedRounds = cached.lr
                    wep.Chambered    = cached.ch
                    wep.Magazine     = cached.mg ~= "" and cached.mg or nil
                    if wep.SendWeapon then wep:SendWeapon(true, true) end
                end
            end
        end)
    end)

    hook.Add("VRMod_Pickup", "HolsterSystem_UnfreezeSpawn", function(ply, ent)
        if not IsValid(ent) or not ent._holster_frozen then return end
        for i = 0, ent:GetPhysicsObjectCount() - 1 do
            local phys = ent:GetPhysicsObjectNum(i)
            if IsValid(phys) then phys:EnableMotion(true) phys:Wake() end
        end
        ent._holster_frozen = nil
    end)
end

-- ===================== CLIENT =====================
vrmod_holster = vrmod_holster or {}
vrmod_holster.hands = vrmod_holster.hands or { left = "", right = "" }

function vrmod_holster.SetHand(isLeft, class)
    if isLeft then vrmod_holster.hands.left = class or ""
    else vrmod_holster.hands.right = class or "" end
end

function vrmod_holster.ClearHand(isLeft)
    if isLeft then vrmod_holster.hands.left = ""
    else vrmod_holster.hands.right = "" end
end

function vrmod_holster.GetHand(isLeft)
    return isLeft and vrmod_holster.hands.left or vrmod_holster.hands.right
end

-- Parse a holster slot string. Weapons: "weapon_class" → class, nil
-- Props/entities: "prop_physics|models/foo.mdl" → class, model
function vrmod_holster.ParseSlot(str)
    if not str or str == "" then return "", nil end
    local pipe = string.find(str, "|", 1, true)
    if not pipe then return str, nil end
    return string.sub(str, 1, pipe - 1), string.sub(str, pipe + 1)
end

function vrmod_holster.MakeSlot(class, model)
    if model and model ~= "" then return class .. "|" .. model end
    return class
end

function vrmod_holster.CountHolstered(class)
    if not class or class == "" then return 0 end
    local n = 0
    for i = 1, 4 do
        local cv = GetConVar("vrmod_pouch_weapon_" .. i)
        if cv then
            local slotClass = vrmod_holster.ParseSlot(cv:GetString())
            if slotClass == class then n = n + 1 end
        end
    end
    return n
end

function vrmod_holster.CountWeapon(class)
    if not class or class == "" then return 0 end
    local n = vrmod_holster.CountHolstered(class)
    if vrmod_holster.hands.left  == class then n = n + 1 end
    if vrmod_holster.hands.right == class then n = n + 1 end
    return n
end

if CLIENT then
    local POUCH_SLOTS = 4

    local pouch_positions = {}
    local pouch_sizes     = {}
    local holster_pickup_pending = {}
    local holster_ragdoll_data = {}
    local suppressStoreLeft  = 0
    local suppressStoreRight = 0

    -- Cache convar refs (GetConVar lookups are not free)
    local cv_enabled     = GetConVar("vrmod_pouch_enabled")
    local cv_visname     = GetConVar("vrmod_pouch_visiblename")
    local cv_vishud      = GetConVar("vrmod_pouch_visiblename_hud")
    local cv_lefthand    = GetConVar("vrmod_pouch_lefthandwep_enable")
    local cv_showmodels  = GetConVar("vrmod_holster_showmodels")
    local cv_maxvol      = GetConVar("vrmod_holster_prop_maxvolume")
    local cv_ragdolls    = GetConVar("vrmod_holster_ragdolls")
    local cv_ragmodels   = GetConVar("vrmod_holster_ragdoll_models")
    local cv_persist     = GetConVar("vrmod_holster_persist")
    local cv_slots, cv_sizes = {}, {}
    for i = 1, POUCH_SLOTS do
        cv_slots[i] = GetConVar("vrmod_pouch_weapon_" .. i)
        cv_sizes[i] = GetConVar("vrmod_pouch_size_" .. i)
        pouch_positions[i] = Vector(0, 0, 0)
        pouch_sizes[i] = cv_sizes[i]:GetFloat()
    end

    for i = 1, POUCH_SLOTS do
        cvars.AddChangeCallback("vrmod_pouch_size_" .. i, function(_, _, new)
            pouch_sizes[i] = tonumber(new)
        end, "vrmod_pouch_size_cb_" .. i)
    end

    -- ── Holster Map Persistence ──────────────────────────────────────────
    local PERSIST_PATH = "vrmod/holster_persist.json"
    local _holsterShuttingDown = false
    local _holsterRestoreGrace = 0

    hook.Add("ShutDown", "vrmod_holster_persist_save", function()
        _holsterShuttingDown = true
        if not cv_persist:GetBool() then return end
        local t = {}
        local any = false
        for i = 1, POUCH_SLOTS do
            local v = cv_slots[i]:GetString()
            if v ~= "" and not string.find(v, "|", 1, true) then
                t[tostring(i)] = v
                any = true
            end
        end
        if not any then
            if file.Exists(PERSIST_PATH, "DATA") then file.Delete(PERSIST_PATH) end
            return
        end
        if not file.IsDir("vrmod", "DATA") then file.CreateDir("vrmod") end
        file.Write(PERSIST_PATH, util.TableToJSON(t))
    end)

    hook.Add("InitPostEntity", "vrmod_holster_persist_restore", function()
        _holsterShuttingDown = false
        if not cv_persist:GetBool() then return end
        if not file.Exists(PERSIST_PATH, "DATA") then return end
        local raw = file.Read(PERSIST_PATH, "DATA")
        file.Delete(PERSIST_PATH)
        if not raw or raw == "" then return end
        local t = util.JSONToTable(raw)
        if not t then return end
        _holsterRestoreGrace = CurTime() + 10
        timer.Simple(1, function()
            for i = 1, POUCH_SLOTS do
                local v = t[tostring(i)]
                if v and v ~= "" then
                    RunConsoleCommand("vrmod_pouch_weapon_" .. i, v)
                end
            end
        end)
    end)

    -- ── Remote holster model sync ────────────────────────────────────────
    local remoteHolsters = {}
    local remoteModels = {}
    local remoteClasses = {}

    local function SendHolsterState()
        if not g_VR or not g_VR.active then return end
        net.Start("vrmod_holster_models_sync")
        for i = 1, POUCH_SLOTS do
            net.WriteString(cv_slots[i]:GetString())
        end
        net.SendToServer()
    end

    for i = 1, POUCH_SLOTS do
        cvars.AddChangeCallback("vrmod_pouch_weapon_" .. i, function()
            timer.Create("vrmod_holster_sync_send", 0.1, 1, SendHolsterState)
        end, "vrmod_holster_sync_cb_" .. i)
    end

    hook.Add("VRMod_Start", "HolsterModels_SendOnStart", function()
        timer.Simple(2, SendHolsterState)
    end)

    net.Receive("vrmod_holster_models_sync", function()
        local ply = net.ReadEntity()
        if not IsValid(ply) then
            for i = 1, POUCH_SLOTS do net.ReadString() end
            return
        end
        local sid = ply:SteamID()
        remoteHolsters[sid] = remoteHolsters[sid] or {}
        for i = 1, POUCH_SLOTS do
            remoteHolsters[sid][i] = net.ReadString()
        end
    end)

    hook.Add("VRMod_Exit", "HolsterModels_CleanupRemote", function(ply) end)

    gameevent.Listen("player_disconnect")
    hook.Add("player_disconnect", "HolsterModels_Disconnect", function(data)
        local sid = data.networkid
        if remoteModels[sid] then
            for i = 1, POUCH_SLOTS do
                if IsValid(remoteModels[sid][i]) then remoteModels[sid][i]:Remove() end
            end
            remoteModels[sid] = nil
        end
        remoteClasses[sid] = nil
        remoteHolsters[sid] = nil
    end)

    -- ---- Helpers ----
    local function IsVRReady()
        return g_VR and g_VR.active and g_VR.threePoints
    end

    local function HandPos(leftHand)
        return leftHand and g_VR.tracking.pose_lefthand.pos or g_VR.tracking.pose_righthand.pos
    end

    local function HandAng(leftHand)
        return leftHand and g_VR.tracking.pose_lefthand.ang or g_VR.tracking.pose_righthand.ang
    end

    local function InHolster(pos, i)
        local d = pouch_sizes[i]
        return pos:DistToSqr(pouch_positions[i]) < (d * d)
    end

    -- OBB volume of an entity (uses bounding box, not physics hull)
    local function EntOBBVolume(ent)
        local mn, mx = ent:OBBMins(), ent:OBBMaxs()
        local sz = mx - mn
        return sz.x * sz.y * sz.z
    end

    function vrmod_holster.IsHandInHolster(leftHand)
        if not IsVRReady() then return false end
        local hpos = HandPos(leftHand)
        for i = 1, POUCH_SLOTS do
            if InHolster(hpos, i) then return true end
        end
        return false
    end

    function vrmod_holster.StoreClass(leftHand, class, ammo)
        if not class or class == "" then return false end
        if not IsVRReady() then return false end
        local hpos = HandPos(leftHand)
        for i = 1, POUCH_SLOTS do
            if InHolster(hpos, i) then
                if cv_slots[i]:GetString() ~= "" then return false end
                RunConsoleCommand("vrmod_pouch_weapon_" .. i, class)
                if ammo then
                    net.Start("vrmod_holster_cache_ammo")
                    net.WriteUInt(i, 3)
                    net.WriteUInt(ammo.lr or 0, 16)
                    net.WriteUInt(ammo.ch or 0, 8)
                    net.WriteString(ammo.mg or "")
                    net.SendToServer()
                end
                surface.PlaySound("holster/uni_weapon_holster.wav")
                vrmod_holster.ClearHand(leftHand)
                return true
            end
        end
        return false
    end

    hook.Add("VRMod_Start", "HolsterSystem_Init", function()
        if not IsVRReady() then return end
        holster_pickup_pending = {}
    end)

    -- ---- Tracking: update holster world positions ----
    hook.Add("VRMod_Tracking", "vrmod_holster_follow_player", function()
        if not cv_enabled:GetBool() then return end
        if not IsVRReady() then return end
        local ply = LocalPlayer()
        if not IsValid(ply) or not ply:Alive() then return end
        if not g_VR.tracking.hmd then return end

        local headPos = g_VR.tracking.hmd.pos
        local bodyRight = Angle(0, g_VR.tracking.hmd.ang.yaw, 0):Right()
        local hh = headPos.z - ply:GetPos().z
        local hipZ = headPos.z - hh * 0.45
        local hx, hy = headPos.x, headPos.y
        local rx, ry = bodyRight.x, bodyRight.y
        pouch_positions[1] = Vector(hx + rx * 7,  hy + ry * 7,  headPos.z)
        pouch_positions[2] = Vector(hx - rx * 7,  hy - ry * 7,  headPos.z)
        pouch_positions[3] = Vector(hx + rx * 16, hy + ry * 16, hipZ)
        pouch_positions[4] = Vector(hx - rx * 16, hy - ry * 16, hipZ)
    end)

    -- ---- Equip from holster ----
    local function equipWeaponOrEntity(leftHand)
        if not cv_enabled:GetBool() then return end
        if not g_VR.active then return end
        local hpos = HandPos(leftHand)
        for i = 1, POUCH_SLOTS do
            if InHolster(hpos, i) then
                local wepclass = cv_slots[i]:GetString()
                if wepclass ~= "" then
                    RunConsoleCommand("vrmod_pouch_weapon_" .. i, "")
                    local spawnClass, spawnModel = vrmod_holster.ParseSlot(wepclass)
                    vrmod_holster.SetHand(leftHand, spawnClass)

                    if ArcticVR and not spawnModel then
                        ArcticVR.GunInLeftHand = leftHand
                        ArcticVR._serverFlagTime = CurTime()
                    end

                    net.Start("vrmod_holster_spawn_entity")
                    net.WriteString(spawnClass)
                    net.WriteString(spawnModel or "")
                    net.WriteVector(hpos)
                    net.WriteAngle(HandAng(leftHand))
                    net.WriteBool(leftHand)
                    net.WriteUInt(i, 3)
                    net.SendToServer()
                    surface.PlaySound("holster/uni_pistol_draw_0" .. math.random(1, 3) .. ".wav")
                    holster_pickup_pending[spawnClass] = { leftHand = leftHand, time = CurTime() }

                    -- Clear ragdoll data for this slot (server reuses the entity on pickup)
                    holster_ragdoll_data[i] = nil

                    local t = CurTime() + 1
                    if leftHand then suppressStoreLeft = t else suppressStoreRight = t end
                    return true
                end
                break
            end
        end
    end

    -- ---- Store to holster ----
    local storeActiveGuard = 0

    -- Store a held entity into a specific slot. Returns true on success.
    local function storeEntityToSlot(i, heldEntity, leftHand)
        local heldClass = heldEntity:GetClass()
        local heldModel = heldEntity:GetModel() or ""
        local isWeapon = heldEntity:IsWeapon()
        local isRagdoll = heldClass == "prop_ragdoll"

        if isRagdoll and not cv_ragdolls:GetBool() then return false end
        if heldEntity.ArcticVRMagazine then return false end
        if not isWeapon and not isRagdoll then
            local maxVol = cv_maxvol:GetFloat()
            if maxVol > 0 and EntOBBVolume(heldEntity) > maxVol then return false end
        end

        local slotStr = vrmod_holster.MakeSlot(heldClass, not isWeapon and heldModel or nil)
        RunConsoleCommand("vrmod_pouch_weapon_" .. i, slotStr)
        if isRagdoll then
            local rd = { skin = heldEntity:GetSkin(), bg = {} }
            local bgCount = heldEntity:GetNumBodyGroups()
            for bg = 0, bgCount - 1 do
                rd.bg[bg] = heldEntity:GetBodygroup(bg)
            end
            holster_ragdoll_data[i] = rd
            if cv_ragmodels:GetBool() then
                net.Start("vrmod_holster_ragdoll_sync")
                net.WriteUInt(i, 3)
                net.WriteString(heldModel)
                net.WriteUInt(rd.skin, 8)
                net.WriteUInt(bgCount, 4)
                for bg = 0, bgCount - 1 do
                    net.WriteUInt(rd.bg[bg], 4)
                end
                net.SendToServer()
            end
        else
            holster_ragdoll_data[i] = nil
        end
        vrmod.Pickup(leftHand, true)
        net.Start("vrmod_holster_absorb_weapon")
        net.WriteEntity(heldEntity)
        net.SendToServer()
        vrmod_holster.ClearHand(leftHand)
        surface.PlaySound("holster/uni_weapon_holster.wav")
        return true
    end

    local function storeWeapon(leftHand)
        local hpos = HandPos(leftHand)
        for i = 1, POUCH_SLOTS do
            if InHolster(hpos, i) then
                local slotOccupied = cv_slots[i]:GetString() ~= ""

                local activeWeapon = LocalPlayer():GetActiveWeapon()
                if IsValid(activeWeapon) and activeWeapon:GetClass() ~= "weapon_vrmod_empty" and CurTime() > storeActiveGuard then
                    local isLeft = g_VR.gunInLeftHand or (ArcticVR and ArcticVR.GunInLeftHand) or false
                    if (leftHand and isLeft) or (not leftHand and not isLeft) then
                        if slotOccupied then
                            local cls = activeWeapon:GetClass()
                            local getVel = isLeft and vrmod.GetLeftHandVelocity or vrmod.GetRightHandVelocity
                            local getAng = isLeft and vrmod.GetLeftHandAngularVelocity or vrmod.GetRightHandAngularVelocity
                            net.Start("DropWeapon")
                            net.WriteBool(true)
                            net.WriteVector(getVel() * 2.5)
                            net.WriteVector(getAng() * 2.5)
                            net.WriteBool(vrmod_holster.CountWeapon(cls) <= 1)
                            net.SendToServer()
                            vrmod_holster.ClearHand(leftHand)
                        else
                            LocalPlayer():ConCommand("vrmod_pouch_weapon_" .. i .. " " .. activeWeapon:GetClass())
                            storeActiveGuard = CurTime() + 0.5
                            if activeWeapon.ArcticVR then
                                net.Start("vrmod_holster_cache_ammo")
                                net.WriteUInt(i, 3)
                                net.WriteUInt(activeWeapon.LoadedRounds or 0, 16)
                                net.WriteUInt(activeWeapon.Chambered or 0, 8)
                                net.WriteString(activeWeapon.Magazine or "")
                                net.SendToServer()
                            end
                            surface.PlaySound("holster/uni_weapon_holster.wav")
                            LocalPlayer():ConCommand("use weapon_vrmod_empty")
                            vrmod_holster.ClearHand(leftHand)
                        end
                        return
                    end
                end

                local heldEntity = leftHand and g_VR.heldEntityLeft or g_VR.heldEntityRight
                if IsValid(heldEntity) then
                    -- Two-hand grab: both hands hold same entity.
                    -- Try right hand slot first, then left, then drop.
                    local otherHeld = leftHand and g_VR.heldEntityRight or g_VR.heldEntityLeft
                    if otherHeld == heldEntity then
                        local stored = false
                        -- Right hand zone first, then left
                        for _, tryLeft in ipairs({false, true}) do
                            local tryPos = HandPos(tryLeft)
                            for j = 1, POUCH_SLOTS do
                                if InHolster(tryPos, j) and cv_slots[j]:GetString() == "" then
                                    stored = storeEntityToSlot(j, heldEntity, leftHand)
                                    if stored then
                                        -- Drop from other hand too
                                        vrmod.Pickup(not leftHand, true)
                                        vrmod_holster.ClearHand(not leftHand)
                                    end
                                    break
                                end
                            end
                            if stored then break end
                        end
                        if not stored then
                            vrmod.Pickup(leftHand, true)
                            vrmod_holster.ClearHand(leftHand)
                        end
                        return
                    end

                    if not slotOccupied then
                        if not storeEntityToSlot(i, heldEntity, leftHand) then
                            vrmod.Pickup(leftHand, true)
                            vrmod_holster.ClearHand(leftHand)
                        end
                    elseif heldEntity:IsWeapon() then
                        local existingClass = vrmod_holster.ParseSlot(cv_slots[i]:GetString())
                        if heldEntity:GetClass() == existingClass then
                            net.Start("vrmod_holster_absorb_weapon")
                            net.WriteEntity(heldEntity)
                            net.SendToServer()
                            if leftHand then g_VR.heldEntityLeft = nil else g_VR.heldEntityRight = nil end
                            vrmod_holster.ClearHand(leftHand)
                            surface.PlaySound("holster/uni_weapon_holster.wav")
                            return
                        end
                    end
                    vrmod.Pickup(leftHand, true)
                    vrmod_holster.ClearHand(leftHand)
                    return
                end

                break
            end
        end
    end

    function vrmod_holster.SuppressStore(isLeft)
        local t = CurTime() + 1
        if isLeft then suppressStoreLeft = t else suppressStoreRight = t end
    end

    function vrmod_holster.IsStoreSuppressed(isLeft)
        return CurTime() < (isLeft and suppressStoreLeft or suppressStoreRight)
    end

    -- ---- Input ----
    hook.Add("VRMod_Input", "vrmod_holster_input", function(action, pressed)
        if not g_VR.active or not cv_enabled:GetBool() then return end
        if ArcticVR and ArcticVR.DualWield then return end

        -- Suppress holster interaction while climbing or when hand detects a climbable wall
        if vrmod.climbing then
            if vrmod.climbing.gripLeft or vrmod.climbing.gripRight then return end
            if action == "boolean_left_pickup" and vrmod.climbing.wallLeft then return end
            if action == "boolean_right_pickup" and vrmod.climbing.wallRight then return end
        end

        local now = CurTime()
        if action == "boolean_right_pickup" then
            if pressed then
                if vrmod_holster.IsHandInHolster(false) then equipWeaponOrEntity(false) end
            elseif now >= suppressStoreRight then
                storeWeapon(false)
            end
        elseif action == "boolean_left_pickup" then
            if pressed then
                if vrmod_holster.IsHandInHolster(true) then equipWeaponOrEntity(true) end
            elseif now >= suppressStoreLeft then
                storeWeapon(true)
            end
        end
    end)

    -- ---- Block VRMod default drop during holster draw or prop store ----
    hook.Add("VRMod_AllowDefaultAction", "vrmod_holster_block_drop", function(action)
        if action == "boolean_left_pickup" then
            if vrmod_holster.IsStoreSuppressed(true) then return false end
            if IsValid(g_VR.heldEntityLeft) and vrmod_holster.IsHandInHolster(true) then return false end
            if vrmod_holster.IsHandInHolster(true) then return false end
        end
        if action == "boolean_right_pickup" then
            if vrmod_holster.IsStoreSuppressed(false) then return false end
            if IsValid(g_VR.heldEntityRight) and vrmod_holster.IsHandInHolster(false) then return false end
            if vrmod_holster.IsHandInHolster(false) then return false end
        end
    end)

    -- ---- Net: server tells us entity is ready, trigger pickup ----
    net.Receive("vrmod_holster_pickup_trigger", function()
        local isLeftHand = net.ReadBool()
        local ent        = net.ReadEntity()
        timer.Simple(0.05, function()
            if not IsValid(ent) then return end
            net.Start("vrmod_pickup")
            net.WriteBool(isLeftHand)
            net.WriteBool(false)
            net.WriteEntity(ent)
            net.SendToServer()
        end)
    end)

    -- ---- VRMod_Pickup: holster ragdoll grab → unholster, and pending fallback ----
    hook.Add("VRMod_Pickup", "HolsterSystem_PickupFallback", function(ply, ent)
        if ply ~= LocalPlayer() then return end
        if not IsValid(ent) then return end

        -- Grabbing a holster display ragdoll acts as unholster
        local hSlot = ent:GetNWInt("vrmod_holster_slot", 0)
        if hSlot > 0 and ent:GetNWEntity("vrmod_holster_owner") == ply then
            RunConsoleCommand("vrmod_pouch_weapon_" .. hSlot, "")
            holster_ragdoll_data[hSlot] = nil
            -- Tell server to stop tracking this ragdoll (tags cleared server-side on pickup)
            net.Start("vrmod_holster_ragdoll_sync")
            net.WriteUInt(hSlot, 3)
            net.WriteString("")
            net.SendToServer()
            -- Suppress re-holster on grip release
            local isLeft = (g_VR.heldEntityLeft == ent)
            vrmod_holster.SuppressStore(isLeft)
            surface.PlaySound("holster/uni_pistol_draw_0" .. math.random(1, 3) .. ".wav")
            return
        end

        local cls = ent:GetClass()
        local data = holster_pickup_pending[cls]
        if data and CurTime() - data.time < 2.0 then
            if vrmod and vrmod.Pickup then vrmod.Pickup(data.leftHand, false) end
            holster_pickup_pending[cls] = nil
        end
    end)

    -- ---- Cleanup stale pending entries + stale holster slots ----
    local lastStaleCheck = 0
    hook.Add("Think", "HolsterSystem_CleanupPending", function()
        for cls, data in pairs(holster_pickup_pending) do
            if CurTime() - data.time >= 5.0 then
                holster_pickup_pending[cls] = nil
            end
        end

        local ply = LocalPlayer()
        if not IsValid(ply) then return end
        local alive = ply:Alive()
        if not alive and vrmod_holster._wasAlive then
            if not _holsterShuttingDown then
                for i = 1, POUCH_SLOTS do
                    RunConsoleCommand("vrmod_pouch_weapon_" .. i, "")
                end
                holster_ragdoll_data = {}
            end
            vrmod_holster.hands.left  = ""
            vrmod_holster.hands.right = ""
        end
        vrmod_holster._wasAlive = alive

        if CurTime() - lastStaleCheck < 5.0 then return end
        lastStaleCheck = CurTime()
        if not IsVRReady() then return end
        if not alive then return end
        if CurTime() < _holsterRestoreGrace then return end
        for i = 1, POUCH_SLOTS do
            local raw = cv_slots[i]:GetString()
            if raw ~= "" then
                local cls, mdl = vrmod_holster.ParseSlot(raw)
                if not mdl then
                    if not weapons.GetStored(cls) or not ply:HasWeapon(cls) then
                        RunConsoleCommand("vrmod_pouch_weapon_" .. i, "")
                    end
                end
            end
        end
    end)

    -- ---- HUD: holster slot names ----
    local hudColor = Color(255, 255, 0, 200)
    hook.Add("HUDPaint", "vrmod_holster_hud", function()
        if not cv_enabled:GetBool() or not cv_vishud:GetBool() or not g_VR.active then return end
        local sw, sh = ScrW(), ScrH()
        local lpos = g_VR.tracking.pose_lefthand.pos
        local rpos = g_VR.tracking.pose_righthand.pos
        for i = 1, POUCH_SLOTS do
            local raw = cv_slots[i]:GetString()
            if raw == "" then continue end
            local cls, mdl = vrmod_holster.ParseSlot(raw)
            local text = mdl and string.GetFileFromFilename(mdl):StripExtension() or cls
            if InHolster(lpos, i) then
                draw.SimpleText(text, "DermaLarge", sw * 0.05, sh * 0.9, hudColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            end
            if InHolster(rpos, i) then
                draw.SimpleText(text, "DermaLarge", sw * 0.95, sh * 0.9, hudColor, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
            end
        end
    end)

    -- ---- Holster world models (clientside) ────────────────────────────────
    local function GetSlotModel(slotStr)
        local cls, mdl = vrmod_holster.ParseSlot(slotStr)
        if mdl then return mdl end
        local stored = weapons.GetStored(cls)
        return stored and stored.WorldModel or ""
    end

    -- Returns true if this slot string is a ragdoll
    local function IsSlotRagdoll(slotStr)
        local cls = vrmod_holster.ParseSlot(slotStr)
        return cls == "prop_ragdoll"
    end

    -- Generic model manager for weapons and props (NOT ragdolls — those are server-side).
    local function EnsureModel(models, classes, slot, slotStr)
        if slotStr == "" or not slotStr or IsSlotRagdoll(slotStr) then
            if IsValid(models[slot]) then models[slot]:Remove() models[slot] = nil end
            classes[slot] = slotStr or ""
            return nil
        end
        if classes[slot] ~= slotStr then
            if IsValid(models[slot]) then models[slot]:Remove() end
            local mdl = GetSlotModel(slotStr)
            if mdl == "" then
                models[slot] = nil
                classes[slot] = slotStr
                return nil
            end
            local csm = ClientsideModel(mdl, RENDERGROUP_TRANSLUCENT)
            if not IsValid(csm) then
                classes[slot] = slotStr
                return nil
            end
            csm:SetNoDraw(true)
            models[slot] = csm
            classes[slot] = slotStr
        end
        return models[slot]
    end

    local function CleanupModels(models, classes)
        for i = 1, POUCH_SLOTS do
            if IsValid(models[i]) then models[i]:Remove() end
            models[i] = nil
            classes[i] = nil
        end
    end

    local holster_models = {}
    local holster_classes = {}

    hook.Add("VRMod_Exit", "vrmod_holster_cleanup_models", function()
        CleanupModels(holster_models, holster_classes)
    end)

    local slotOffsets  = { -21, -21, 11, 11 }
    local slotVertical = { -10, -10, 0, 0 }

    local function ComputeRemotePositions(ply, frame)
        local positions = {}
        local pelvisBone = ply:LookupBone("ValveBiped.Bip01_Pelvis")
        if not pelvisBone then return nil end
        local hipPos, hipAng = ply:GetBonePosition(pelvisBone)
        if not hipPos then return nil end
        local headPos = frame.hmdPos
        local headAng = frame.hmdAng
        if not headPos or not headAng then return nil end
        local hipRight = hipAng:Right()
        positions[1] = headPos + headAng:Right() * 7
        positions[2] = headPos - headAng:Right() * 7
        positions[3] = hipPos  + hipRight * 16
        positions[4] = hipPos  - hipRight * 16
        return positions, headAng.yaw
    end

    -- ---- World spheres + holstered models ----
    hook.Add("PostDrawTranslucentRenderables", "vrmod_holster_draw", function(depth, sky)
        if depth or sky then return end
        if not g_VR.active then return end

        local showModels = cv_showmodels:GetBool()

        -- ── Local player ──
        if cv_enabled:GetBool() and g_VR.threePoints then
            local showSpheres = cv_visname:GetBool()
            local bodyYaw = g_VR.tracking.hmd and g_VR.tracking.hmd.ang.yaw or 0
            local bodyFwd = Angle(0, bodyYaw, 0):Forward()

            for i = 1, POUCH_SLOTS do
                local pos  = pouch_positions[i]
                local size = pouch_sizes[i]
                local cls  = cv_slots[i] and cv_slots[i]:GetString() or ""

                if showSpheres then
                    render.SetColorMaterial()
                    render.DrawSphere(pos, size, 16, 50, Color(255, 255, 255, 128))
                    if cls ~= "" then
                        local eyeAng = EyeAngles()
                        eyeAng:RotateAroundAxis(eyeAng:Right(), 60)
                        cam.Start3D2D(pos, eyeAng, 0.1)
                        local labelCls, labelMdl = vrmod_holster.ParseSlot(cls)
                        local labelText = labelMdl and string.GetFileFromFilename(labelMdl):StripExtension() or labelCls
                        draw.SimpleText(labelText, "CloseCaption_Normal", 0, 0, Color(108, 81, 0), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                        cam.End3D2D()
                    end
                end

                -- Non-ragdoll models drawn manually; ragdolls self-render via Think physics
                if showModels and not IsSlotRagdoll(cls) then
                    local csm = EnsureModel(holster_models, holster_classes, i, cls)
                    if IsValid(csm) then
                        csm:SetPos(pos + bodyFwd * slotOffsets[i] + Vector(0, 0, slotVertical[i]))
                        csm:SetAngles(Angle(90, bodyYaw, 0))
                        csm:SetupBones()
                        csm:DrawModel()
                    end
                end
            end
        end

        -- ── Remote VR players (static models for everything including ragdolls) ──
        if not showModels then return end
        local lp = LocalPlayer()
        for sid, slots in pairs(remoteHolsters) do
            local netData = g_VR.net and g_VR.net[sid]
            if not netData or not netData.lerpedFrame then continue end
            local ply = player.GetBySteamID(sid)
            if not IsValid(ply) or ply == lp or not ply:Alive() then continue end

            local positions, yaw = ComputeRemotePositions(ply, netData.lerpedFrame)
            if not positions then continue end
            local fwd = Angle(0, yaw, 0):Forward()

            if not remoteModels[sid] then remoteModels[sid] = {} end
            if not remoteClasses[sid] then remoteClasses[sid] = {} end

            for i = 1, POUCH_SLOTS do
                local cls = slots[i] or ""
                local csm = EnsureModel(remoteModels[sid], remoteClasses[sid], i, cls)
                if IsValid(csm) then
                    csm:SetPos(positions[i] + fwd * slotOffsets[i] + Vector(0, 0, slotVertical[i]))
                    csm:SetAngles(Angle(90, yaw, 0))
                    csm:SetupBones()
                    csm:DrawModel()
                end
            end
        end
    end)

    -- Holster settings are integrated directly into cl_settings.lua.
end