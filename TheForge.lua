-- The Forge: Quests, Untergrund-Farmen, Verkauf, Ausruestung und Schmiedeplanung.
-- In Potassium ausfuehren. Farmen mit Schalter starten; offene Schmiedeminispiele werden automatisch bedient.
local Planner = {}

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

function Planner.matches(name, target)
    if name == target then return true end
    if type(name) ~= "string" or type(target) ~= "string" or name:sub(1, #target) ~= target then return false end
    return name:sub(#target + 1):match("^%d+$") ~= nil
end
function Planner.mobName(name, definitions)
    for candidate in pairs(definitions) do if Planner.matches(name, candidate) then return candidate end end
    return nil
end
-- Abbaubar: genug Schaden UND die richtige Spitzhacke, falls der Stein bestimmte verlangt
-- (Rock-Daten RequiredPickaxes, z. B. Thunder Core / Sakura Crystal nur mit Yin-Yang oder Dev's Bane Pickaxe).
function Planner.canMine(rock, power, pickaxeName, requiredDamage)
    if type(rock) ~= "table" or (requiredDamage or rock.RequiredDamage or math.huge) > power then return false end
    return type(rock.RequiredPickaxes) ~= "table" or table.find(rock.RequiredPickaxes, pickaxeName) ~= nil
end

do
    local variants = {Pebble = true, Rock = true, Vein = true, Boulder = true, Crystal = true, Core = true}
    function Planner.rockFamily(name)
        local family, variant = name:match("^(.+)%s+(%S+)$")
        if variant and variants[variant] then return family end
        return nil
    end
end

function Planner.respawnRockMatches(job, name, area)
    local pool = job.areas[area]
    if job.sameFamily then
        local family = Planner.rockFamily(name)
        return pool ~= nil and family ~= nil and pool[family] == true
    end
    return pool == true or job.family[name:match("^(%S+)%s") or name] == true
end

function Planner.worldLabel(name, world)
    return "[" .. (({"I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"})[world] or "?") .. "] " .. name
end

function Planner.depth(value)
    if not finite(value) then value = 3.5 end
    return math.floor(math.clamp(value, 0, 12) * 10 + 0.5) / 10
end

function Planner.setDepth(settings, key, value)
    local depth = Planner.depth(type(value) == "string" and tonumber(value) or value)
    if depth ~= settings[key] then
        settings[key], settings.AutoRange = depth, false
    end
end

function Planner.ownMiningHit(previous, current, lastPlayer, golem, playerName)
    return finite(previous) and finite(current) and current < previous and lastPlayer == playerName and golem ~= true
end

function Planner.blockThreat(distance, facing, parryable)
    return parryable ~= false and finite(distance) and distance <= 16 and distance >= 0
        and finite(facing) and facing >= 0.1
end
function Planner.parryDelay(impact, latency)
    if not finite(impact) then impact = 0.35 end
    if not finite(latency) then latency = 0 end
    return math.max(0, math.clamp(impact, 0.1, 1.2) - 0.15 - math.clamp(latency, 0, 0.5))
end

local areaLocks = { ["Goblin Cave"] = "UnlockedGoblinCaveDoor", DemoniteCave = "UnlockedDemoniteCaveDoor",
    FallenAngel = "UnlockedFallenAngelCaveDoor", Island3RedCave = "UnlockedRedCaveDoor", Island3RedCave2 = "UnlockedRedCaveDoor",
    Island3CorruptionCave = "UnlockedRedCaveDoor" }
function Planner.areaUnlocked(name, flags)
    return not areaLocks[name] or not not (flags or {})[areaLocks[name]]
end
function Planner.setback(distance, dt, speed)
    return finite(distance) and distance > math.max(12, math.max(0, dt) * speed * 3 + 4)
end

function Planner.underOffset(reach, misses, requested, autoRange)
    local maximum = Planner.depth(requested)
    if autoRange == false then return maximum end
    if not finite(reach) or reach <= 0 then reach = 4 end
    local initial = math.min(maximum, math.max(1.5, reach * 0.65), math.max(1.5, reach - 0.75))
    return math.max(math.min(1.5, maximum), initial - math.max(0, misses or 0) * 0.35)
end

function Planner.pending(data, definitions, ores, rocks)
    local jobs, reserved, unsupported = {}, {}, {}
    local function reserve(name, amount)
        if ores[name] and finite(amount) and amount > 0 then reserved[name] = (reserved[name] or 0) + math.ceil(amount) end
    end
    local ids = {}
    for id in pairs(data.Quests or {}) do table.insert(ids, id) end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local quest, definition = data.Quests[id], definitions[id] or {}
        local complete = true
        for index, progress in ipairs(quest.Progress or {}) do
            local objective = (definition.Objectives or {})[index] or {}
            local required = progress.requiredAmount or 1
            local current = progress.currentProgress or 0
            local kind, target = progress.questType or objective.Type, progress.target or objective.Target
            local bring = objective.Bring
            if not bring and kind == "Extra" then
                local amount, name = tostring(objective.Description or ""):match("[Bb]ring%s+(%d+)%s+(.+)")
                if amount then
                    name = name:gsub("[%.!]$", "")
                    if not ores[name] and ores[name:gsub("s$", "")] then name = name:gsub("s$", "") end
                    if ores[name] then bring = {[name] = tonumber(amount)} end
                end
            end
            if bring then
                for name, amount in pairs(bring) do reserve(name, amount) end
            elseif kind == "Collect" and ores[target] then
                reserve(target, required)
            end
            if current < required or current <= 0 then
                complete = false
                -- Typ "any": job wird weiter unten bewusst auf nil gesetzt, wenn der Auftrag nicht eingetragen werden soll.
                local job: any = {quest = id, index = index, target = target, remaining = math.max(1, required - current), npc = definition.Npc}
                if bring then
                    job.kind, job.bring = "Talk", true -- Abgabe beim NPC (FinishQuest im Dialog)
                    for name, amount in pairs(bring) do
                        if (data.Inventory[name] or 0) < amount then
                            table.insert(jobs, {kind = "Ore", target = name, remaining = amount - (data.Inventory[name] or 0), quest = id, index = index})
                            job = nil
                        end
                    end
                elseif kind == "Collect" and type(objective.Pickups) == "table" and next(objective.Pickups) then
                    -- Fundstueck-Quest (z. B. Warrior Skulls): Pickups = {{Name = Proximity-Modell, Flag = MiscDialogues-Flagge}}
                    job.kind, job.pickups = "Pickup", objective.Pickups
                elseif kind == "Kill" and type(target) == "string" then
                    -- auch "Mutation:Hell" usw. (z. B. Quest "Two Halves"): passende Mobs erkennt Planner.killMatches
                    job.kind = "Kill"
                elseif (kind == "Mine" or kind == "Collect") and rocks[target] then
                    job.kind = "Mine"
                elseif (kind == "Collect" or kind == "Mine") and ores[target] then
                    job.kind = "Ore"
                elseif kind == "Talk" and type(target) == "string" then
                    job.kind, job.npc = "Talk", target
                else
                    table.insert(unsupported, id .. ": " .. tostring(kind) .. " / " .. tostring(target))
                    job = nil
                end
                if job then table.insert(jobs, job) end
            end
        end
        if complete and not definition.AutoComplete and definition.Npc then
            table.insert(jobs, {kind = "Talk", npc = definition.Npc, quest = id, turnIn = true})
        end
    end
    return jobs, reserved, unsupported
end

function Planner.currentWorld(islands, placeId)
    for index, island in pairs(islands) do if island.PlaceId == placeId then return index, island.Name end end
    return nil, nil
end

-- Kill-Ziel pruefen: normaler Mob-Name ("Brute Oni") oder Mutation ("Mutation:Hell" -> Attribut Mutation/EventMutation == "Hell").
function Planner.killMatches(modelName, target, mutation, eventMutation)
    local wanted = type(target) == "string" and target:match("^Mutation:(.+)$")
    if wanted then return mutation == wanted or eventMutation == wanted end
    return Planner.matches(modelName, target)
end

function Planner.jobWorld(job, definitions, npcInfo, current, presentNpcs)
    -- Mutierte Mobs gibt es auf jeder Insel: solche Kill-Auftraege gelten immer fuer die aktuelle Welt.
    if job.kind == "Kill" and type(job.target) == "string" and job.target:find("^Mutation:") then return current end
    local definition = definitions[job.quest] or {}
    local objective = (definition.Objectives or {})[job.index] or {}
    local function npcWorld(names)
        if type(names) ~= "string" then return nil end
        if npcInfo[names] and npcInfo[names].Island then return npcInfo[names].Island end
        local localNpc = false
        for name in names:gmatch("[^,]+") do
            if npcInfo[name] and npcInfo[name].Island then return npcInfo[name].Island end
            if presentNpcs and presentNpcs[name] then localNpc = true end
        end
        if localNpc then return current end
        return nil
    end
    if objective.Island then return objective.Island end
    if job.kind == "Talk" then
        local world = npcWorld(job.npc)
        if world then return world end
    end
    return definition.Island or npcWorld(definition.Npc or job.npc)
end

function Planner.worldJobs(jobs, definitions, npcInfo, current, presentNpcs)
    local allowed, skipped = {}, {}
    for _, job in ipairs(jobs) do
        local world = Planner.jobWorld(job, definitions, npcInfo, current, presentNpcs)
        if current ~= nil and world == current then
            table.insert(allowed, job)
        else
            table.insert(skipped, {quest = job.quest, index = job.index, target = job.target or job.npc, world = world,
                reason = (current == nil or world == nil) and "Welt nicht sicher zugeordnet" or "Andere Welt"})
        end
    end
    return allowed, skipped
end

function Planner.selection(selection, ores)
    local result = {}
    for name, enabled in pairs(type(selection) == "table" and selection or {}) do
        if enabled == true and ores[name] then result[name] = true end
    end
    return result
end

function Planner.rockHasSelectedOre(rockOres, selection)
    for _, name in ipairs(rockOres or {}) do if selection[name] == true then return true end end
    return false
end

function Planner.rockMatches(name, rockOres, selectedOres, selectedRocks)
    selectedOres, selectedRocks = selectedOres or {}, selectedRocks or {}
    local ores, rocks = next(selectedOres) ~= nil, next(selectedRocks) ~= nil
    return (ores or rocks) and (not rocks or selectedRocks[name] == true)
        and (not ores or Planner.rockHasSelectedOre(rockOres, selectedOres))
end
function Planner.orePower(name, ores)
    local value = ores[name] and ores[name].Multiplier
    return finite(value) and value >= 0 and value or 0
end
function Planner.sortedChoices(choices, ores)
    local names = {}
    for name in pairs(choices) do table.insert(names, name) end
    table.sort(names, function(a, b)
        if ores then
            local left, right = Planner.orePower(a, ores), Planner.orePower(b, ores)
            if left ~= right then return left > right end
        end
        return a < b
    end)
    return names
end
local settingKeys = {"AutoSell", "AutoForge", "AutoEquip", "AutoBlock", "TargetPickaxe", "CraftTarget", "Speed",
    "MobDepth", "OreDepth", "AutoRange", "FarmMode", "SelectedOres", "SelectedMobs", "SelectedRocks", "Noclip",
    "SkipNearEnemies", "AutoRestart", "MenuKey", "AntiAfk", "FastAttack", "KillRadius", "SellBelowMultiplier", "SellAtStashPercent",
    "RareFirst", "AutoRejoin", "ShowCounter", "OreEsp", "EspMinMultiplier", "TargetEsp", "PathLine", "ClashFocus", "GoalClass", "GoalDps", "GoalQuality",
    "AutoAcceptQuests", "PreferredQuests", "EnemySkipRadius", "GoalUseFavorites", "GoalMetric", "GoalTarget", "BestAvoidNegative", "GoalHud"}
function Planner.savedSettings(settings)
    local result = {}
    for _, key in ipairs(settingKeys) do
        local value = settings[key]
        if type(value) == "table" then result[key] = Planner.selection(value, value)
        elseif type(value) == "boolean" or type(value) == "string" or finite(value) then result[key] = value end
    end
    return result
end

function Planner.dominates(better, worse)
    if not better or not worse then return false end
    local strict = false
    for key, value in pairs(worse) do
        if not finite(value) or not finite(better[key] or 0) or (better[key] or 0) < value - 0.00001 then return false end
        if (better[key] or 0) > value + 0.00001 then strict = true end
    end
    for key, value in pairs(better) do
        if not finite(value) then return false end
        if value < (worse[key] or 0) - 0.00001 then return false end
        if value > (worse[key] or 0) + 0.00001 then strict = true end
    end
    return strict
end

function Planner.hasRunes(item)
    for _, rune in pairs(item.Runes or {}) do if not rune.IsEmpty then return true end end
    return false
end

function Planner.equipmentSales(data, slotOf, metrics)
    local result = {}
    local equipped = {}
    for _, item in pairs(data.Equipped or {}) do equipped[item.GUID or item.Name or ""] = true end
    for _, item in ipairs(data.Inventory.Equipments or {}) do
        local id, slot = item.GUID or item.Name, slotOf(item)
        if id and slot and not equipped[id] and not (data.Favorites or {})[id] and not Planner.hasRunes(item) then
            local candidate = table.clone(data.Equipped or {})
            candidate[slot] = item
            local baseline = metrics(candidate)
            for _, replacement in ipairs(data.Inventory.Equipments or {}) do
                if replacement ~= item and slotOf(replacement) == slot then
                    candidate[slot] = replacement
                    if Planner.dominates(metrics(candidate), baseline) then
                        result[id] = true
                        break
                    end
                end
            end
        end
    end
    return result
end

function Planner.oreSales(data, ores, reserved, metrics, recipeSize)
    local result, candidates = {}, {}
    for name, count in pairs(data.Inventory or {}) do
        if ores[name] and finite(count) and count > 0 then table.insert(candidates, name) end
    end
    table.sort(candidates)
    for _, name in ipairs(candidates) do
        local surplus = math.floor(data.Inventory[name] - (reserved[name] or 0))
        if surplus > 0 and not (data.Favorites or {})[name] then
            local obsolete = false
            for _, replacement in ipairs(candidates) do
                if replacement ~= name and data.Inventory[replacement] - (reserved[replacement] or 0) >= recipeSize
                    and Planner.dominates(metrics(replacement), metrics(name)) then
                    obsolete = true
                    break
                end
            end
            -- Auch gute Erze finanzieren die Spitzhacke, sobald ein Rezeptvorrat und alle Reservierungen gedeckt sind.
            local amount = obsolete and surplus or math.floor(data.Inventory[name] - math.max(reserved[name] or 0, recipeSize))
            if amount > 0 then result[name] = amount end
        end
    end
    return result
end

Planner.ForgeOreSlots = 4

function Planner.recipeFitsForge(recipe)
    if type(recipe) ~= "table" or not next(recipe) then return false end
    local count, slots = 0, 0
    for _, amount in pairs(recipe) do
        slots += 1
        if slots > Planner.ForgeOreSlots or not finite(amount) or amount <= 0 or amount % 1 ~= 0 then return false end
        count += amount
    end
    return count >= 3
end

function Planner.availableRecipe(recipe, inventory, reserved)
    if not Planner.recipeFitsForge(recipe) then return false end
    for name, amount in pairs(recipe) do
        if (inventory[name] or 0) - (reserved[name] or 0) < amount then return false end
    end
    return true
end

function Planner.quote(data, price, shopMultiplier)
    if not finite(price) or price <= 0 or not finite(shopMultiplier) or shopMultiplier <= 0 then return nil end
    return price * (data.Race == "Goblin" and 0.88 or 1) * shopMultiplier
end

-- RUNTIME_START
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local env = (type(getgenv) == "function" and getgenv()) or _G
if game.GameId ~= 7671049560 then warn("[ForgeHelper] This script is for The Forge."); return end
local previousHelper = env.ForgeProgressionHelper
local previousSettings = {}
if previousHelper then
    for _, key in ipairs(settingKeys) do
        previousSettings[key] = previousHelper[key]
    end
    previousSettings.BlockedAreas, previousSettings.AreaUnlockStamp = previousHelper.BlockedAreas, previousHelper.AreaUnlockStamp
    previousHelper:Destroy()
end
local legacyModes = {["Nur Erze"] = "Ores Only", ["Nur Mobs"] = "Mobs Only"}
previousSettings.FarmMode = legacyModes[previousSettings.FarmMode] or previousSettings.FarmMode
-- Interne Module duerfen weitere Spielmodule nur im normalen Client-Kontext laden.
local setIdentity = setthreadidentity or setidentity
if type(setIdentity) == "function" then setIdentity(2) end
local Shared = ReplicatedStorage:WaitForChild("Shared", 15)
assert(Shared, "The Forge: Shared unavailable")
local Knit = require(Shared.Packages.Knit)
-- Nach einem Rejoin startet das Script frueher als das Spiel: auf Knit und die Spielerdaten warten (max. 90 s).
pcall(function() Knit.OnStart():timeout(90):await() end)
local PC = Knit.GetController("PlayerController")
do
    local waitStart = os.clock()
    while not (PC.Replica and PC.Status) and os.clock() - waitStart < 90 do task.wait(0.5) end
end
assert(PC.Replica and PC.Status, "The Forge: player data not ready")
local UI = Knit.GetController("UIController")
local FC = Knit.GetController("ForgeController")
local Equipment = require(Shared.Data.Equipments)
local Runes = require(Shared.Data.Runes)
local Sets = require(Shared.Data.ArmorSets)
local Definitions = require(Shared.Data.Quests)
local Islands = require(Shared.Data.Islands)
local QuestLog = require(Shared.Data.QuestLog)
local Rocks = require(Shared.Data.Rock)
local Caves = require(Shared.Data.Cave)
local Enemies = require(Shared.Data.Enemies)
local OreList = require(Shared.Data.Ore)
local Proximities = require(Shared.Data.Proximities)
local Rarity = require(Shared.ItemRarity)
local Ores = {}
for _, ore in pairs(OreList) do if type(ore) == "table" and ore.Name then Ores[ore.Name] = ore end end
local ToolController = Knit.GetController("ToolController")
local InventoryService = Knit.GetService("InventoryService")
local ProximityService = Knit.GetService("ProximityService")
local DialogueService = Knit.GetService("DialogueService")
local CharacterService = Knit.GetService("CharacterService")
local player = Players.LocalPlayer
local availableOres, availableMobs, availableRocks = {}, {}, {}
local currentWorld, currentWorldName = Planner.currentWorld(Islands.Data, game.PlaceId)
local function addRockOres(name)
    if not Rocks[name] then return end
    availableRocks[name] = true
    for _, ore in ipairs(Rocks[name] and Rocks[name].Ores or {}) do if Ores[ore] then availableOres[ore] = true end end
end
for _, folder in ipairs(workspace.Rocks:GetChildren()) do
    for _, spawn in ipairs(Caves[folder.Name] and Caves[folder.Name].Rocks or {}) do addRockOres(spawn.Name) end
end
for _, rock in ipairs(workspace.Rocks:GetDescendants()) do if rock:IsA("Model") then addRockOres(rock.Name) end end
-- Mob-Art eines Modells ("Brute Oni13" -> "Brute Oni"); auch fuer Mobs, die nicht in Shared.Data.Enemies stehen.
local function mobKey(model)
    return Planner.mobName(model.Name, Enemies) or (model.Name:gsub("%d+$", ""))
end
for name, enemy in pairs(Enemies) do if enemy.Island == currentWorldName then availableMobs[name] = true end end
-- Alle Mob-Arten dieser Welt, auch wenn gerade keiner lebt: jeder Spawn-Bereich listet seine Gegner
-- im Attribut "Enemies" (z. B. "Brute Oni,Frostburn Oni,Warlord Oni").
local mobSpawns = workspace:FindFirstChild("Debris") and workspace.Debris:FindFirstChild("MobSpawns")
for _, area in ipairs(mobSpawns and mobSpawns:GetChildren() or {}) do
    for name in tostring(area:GetAttribute("Enemies") or ""):gmatch("[^,]+") do
        name = name:match("^%s*(.-)%s*$")
        if name ~= "" then availableMobs[name] = true end
    end
end
for _, mob in ipairs(workspace.Living:GetChildren()) do
    if mob:GetAttribute("IsNpc") and not mob:GetAttribute("DpsDummy") and not Players:GetPlayerFromCharacter(mob) then
        availableMobs[mobKey(mob)] = true
    end
end
local api = {Running = false, AutoSell = true, AutoForge = true, AutoEquip = true, AutoBlock = false, Defending = false, BlocksAttempted = 0, ParriesConfirmed = 0, TargetPickaxe = "Kitsune Pickaxe", CraftTarget = "", CraftRequested = false, Speed = 55, MobDepth = 3.5, OreDepth = 3.5, AutoRange = true, FarmMode = "Ores Only", SelectedOres = {}, OrePosition = "Above", State = "Ready", LastError = ""}
api.Noclip, api.BlockedAreas, api.SelectedMobs, api.SelectedRocks = false, {}, {}, {}
api.Enabled, api.AutoForgeMinigames = false, true
api.SkipNearEnemies, api.AutoRestart, api.WantRunning = true, false, false
api.MenuKey = "RightControl"
api.AntiAfk, api.FastAttack = true, true
api.RareFirst, api.AutoRejoin = false, false
-- Schmiede-Ziel (z. B. Katana mit 250 Schaden oder Heavy Chestplate mit 900 Leben bei 90 % Qualitaet).
-- GoalMetric: "Damage" (Schaden pro Treffer wie im Spiel und auf theforge.gg) oder "DPS"; Ruestungen immer "Health".
-- GoalDps ist nur noch der alte gespeicherte Wert (wird unten einmalig nach GoalTarget uebernommen).
api.GoalClass, api.GoalDps, api.GoalQuality, api.ForgeGoalActive = "", 0, 90, false
api.GoalMetric, api.GoalTarget = "Damage", 0
api.BestAvoidNegative = true -- Best Craftable: weniger Leben/Ausdauer/Tempo durch Erz-Traits zieht von der Bewertung ab
api.GoalUseFavorites = true -- Schmiede-Ziel darf Favoriten-Erze verwenden (Auto Sell verkauft Favoriten trotzdem nie)
-- Quests: verfuegbare Quests automatisch annehmen; bevorzugte Quests (Quest-ID -> true) werden zuerst erledigt
api.AutoAcceptQuests, api.PreferredQuests = true, {}
api.EnemySkipRadius = 20 -- Skip Rocks Near Enemies: Gegner in diesem Umkreis (Studs)
api.ManualFly = false    -- Titelleisten-Schalter: selbst fliegen (W/A/S/D, Leertaste hoch, Strg runter), nicht gespeichert
api.ClashFocus = false -- Celestial Clash: waehrend das Event laeuft alles andere ignorieren und fuer die eigene Seite kaempfen
-- Visuals: Zaehler unten links, Erz-ESP, ESP fuers aktuelle Ziel, Fluglinie zum Ziel
api.ShowCounter, api.OreEsp, api.EspMinMultiplier, api.TargetEsp, api.PathLine = true, false, 5, true, true
api.GoalHud = true -- Anzeige ueber der Quest-Liste, solange fuer ein Schmiede-Ziel gefarmt wird
api.KillRadius, api.KillCenter = 120, nil -- Kill All greift nur Mobs in diesem Radius um den Startpunkt an
-- Auto Sell: Erze unter diesem Multiplikator verkaufen (0 = aus), sobald der Stash diesen Fuellstand erreicht.
api.SellBelowMultiplier, api.SellAtStashPercent = 0, 95
api.RemovedLavaZones = 0
api.AreaUnlockStamp = "<unread>"
api.AvailableOres, api.AvailableMobs, api.AvailableRocks = availableOres, availableMobs, availableRocks
local settingsFile, savedWindow = "ForgeProgressionHelper.settings.json", nil
local loadedSettings = {}
if type(isfile) == "function" and type(readfile) == "function" then
    for _, file in ipairs({settingsFile, settingsFile .. ".bak"}) do
        if isfile(file) then
            local ok, saved = pcall(function() return HttpService:JSONDecode(readfile(file)) end)
            if ok and type(saved) == "table" and saved.version == 1 and type(saved.settings) == "table" then
                loadedSettings, savedWindow = Planner.savedSettings(saved.settings), saved.window
                break
            else warn("[ForgeHelper] Ignoring invalid settings: " .. file) end
        end
    end
end
for _, settings in ipairs({loadedSettings, previousSettings}) do
    for key, value in pairs(settings) do if type(value) == type(api[key]) then api[key] = value end end
end
api.MobDepth, api.OreDepth = Planner.depth(api.MobDepth), Planner.depth(api.OreDepth)
api.Speed = finite(api.Speed) and math.clamp(api.Speed, 1, 200) or 55
api.KillRadius = finite(api.KillRadius) and math.clamp(api.KillRadius, 20, 500) or 120
api.SellBelowMultiplier = finite(api.SellBelowMultiplier) and math.clamp(api.SellBelowMultiplier, 0, 30) or 0
api.SellAtStashPercent = finite(api.SellAtStashPercent) and math.clamp(api.SellAtStashPercent, 50, 100) or 95
api.EspMinMultiplier = finite(api.EspMinMultiplier) and math.clamp(api.EspMinMultiplier, 0, 30) or 5
api.GoalQuality = finite(api.GoalQuality) and math.clamp(api.GoalQuality, 50, 100) or 90
api.GoalDps = finite(api.GoalDps) and math.max(0, api.GoalDps) or 0
api.GoalTarget = finite(api.GoalTarget) and math.max(0, api.GoalTarget) or 0
if api.GoalMetric ~= "Damage" and api.GoalMetric ~= "DPS" then api.GoalMetric = "Damage" end
-- Alte Einstellung "Target DPS" uebernehmen, damit ein gespeichertes Ziel nicht verloren geht.
-- Geplant wird jetzt nach Schaden (wie im Spiel und auf theforge.gg); DPS bleibt im Menue waehlbar.
if api.GoalTarget <= 0 and api.GoalDps > 0 then api.GoalTarget, api.GoalMetric = api.GoalDps, "Damage" end
api.GoalDps = 0
api.EnemySkipRadius = finite(api.EnemySkipRadius) and math.clamp(api.EnemySkipRadius, 5, 60) or 20
api.SelectedOres = Planner.selection(api.SelectedOres, availableOres)
api.SelectedMobs = Planner.selection(api.SelectedMobs, availableMobs)
api.SelectedRocks = Planner.selection(api.SelectedRocks, availableRocks)
if not pcall(function() return Enum.KeyCode[api.MenuKey] end) then api.MenuKey = "RightControl" end
if api.FarmMode ~= "Ores Only" and api.FarmMode ~= "Mobs Only" and api.FarmMode ~= "Kill All Mobs" and api.FarmMode ~= "Gold" and api.FarmMode ~= "Forging" then api.FarmMode = "Quests" end
-- Farm-Modus "Forging" arbeitet den Schmiede-Plan ab (ersetzt den frueheren Schalter "Get Materials & Craft")
api.ForgeGoalActive = api.FarmMode == "Forging"
env.ForgeProgressionHelper = api
-- blocked ist bewusst KEINE weak table: Instance-Schluessel in weak tables koennen vom GC entfernt werden,
-- obwohl der Stein noch existiert -> Sperre war weg und der Bot flog trotzdem hin.
local connections, collision, blocked = {}, {}, {}
local cooldown: {[string]: number} = {} -- Abklingzeiten pro Schluessel (z. B. "Forge", "Talk:<Quest>")
local destroyed, generation, destination, saved, character, root, humanoid = false, 0, nil, nil, nil, nil, nil
local report, build, lastPlan = nil, nil, 0
local stopMiningInput, mineFromInput, releaseBlock, attackFrame, releaseForge
local followAttack
local lastDriven
local holdFrame -- Position, an der der Charakter ohne Ziel schwebt (statt mit Kollision im Boden zu landen)
local movementPaused = false -- waehrend des Verkaufsdialogs: Flug und Noclip aus, der Spieldialog positioniert den Spieler
local unlockStamp = api.AreaUnlockStamp
-- STATISTIK: wird bei jedem Druck auf START zurueckgesetzt und im Overview-Tab angezeigt.
local stats = {startTime = nil, goldStart = 0, oresMined = 0, rocksBroken = 0, kills = 0, sold = 0, soldGold = 0, deaths = 0, lastOreTotal = nil}
api.Stats = stats

local function data() return PC.Replica.Data end
local function track(connection) table.insert(connections, connection); return connection end
-- LAVA_CLEANUP_START
local function removeLavaZone(zone)
    if destroyed or not zone:IsA("BasePart") or not zone:IsDescendantOf(workspace) then return end
    if zone.Name ~= "LavaDamageZone" and not CollectionService:HasTag(zone, "LavaDamageZone") then return end
    zone.CanTouch = false
    zone:Destroy()
    api.RemovedLavaZones += 1
end
-- LAVA_CLEANUP_END
track(CollectionService:GetInstanceAddedSignal("LavaDamageZone"):Connect(function(zone) task.defer(removeLavaZone, zone) end))
-- Nur Lava-Teile pruefen: sonst wird fuer jeden Effekt/jedes Partikel im Workspace ein Thread erzeugt.
track(workspace.DescendantAdded:Connect(function(zone) if zone.Name == "LavaDamageZone" then task.defer(removeLavaZone, zone) end end))
for _, zone in ipairs(CollectionService:GetTagged("LavaDamageZone")) do removeLavaZone(zone) end
for _, zone in ipairs(workspace:GetDescendants()) do if zone.Name == "LavaDamageZone" then removeLavaZone(zone) end end
local regionFolder = workspace:FindFirstChild("Debris") and workspace.Debris:FindFirstChild("Regions")
-- Set statt Liste: die alte Liste wuchs bei jedem neu hinzugefuegten Teil endlos (auch Duplikate/geloeschte Teile)
-- und wurde jeden Frame komplett durchlaufen.
local regionParts = {}
if regionFolder then
    for _, part in ipairs(regionFolder:GetDescendants()) do if part:IsA("BasePart") then regionParts[part] = true end end
    track(regionFolder.DescendantAdded:Connect(function(part) if part:IsA("BasePart") then regionParts[part] = true end end))
    track(regionFolder.DescendantRemoving:Connect(function(part) regionParts[part] = nil end))
end
local function areaAt(point)
    local name, smallest = nil, math.huge
    for part in pairs(regionParts) do
        if part.Parent and part:IsA("BasePart") then
            local offset = part.CFrame:PointToObjectSpace(point)
            if math.abs(offset.X) <= part.Size.X / 2 and math.abs(offset.Z) <= part.Size.Z / 2 and math.abs(offset.Y) < 80 then
                if not Planner.areaUnlocked(part.Name, data().MiscDialogues) then return part.Name, false end
                local size = part.Size.X * part.Size.Z
                if size < smallest then name, smallest = part.Name, size end
            end
        end
    end
    return name or ("cell:" .. game.PlaceId .. ":" .. math.floor(point.X / 80) .. ":" .. math.floor(point.Y / 80) .. ":" .. math.floor(point.Z / 80)), true
end
-- FPS: areaAt laeuft ueber alle Gebietsteile. Ergebnis pro 8-Stud-Zelle 2 s merken,
-- statt es jeden Frame fuer jeden Stein/Mob neu zu berechnen.
local accessible
do
    local cache, cacheAt = {}, 0
    accessible = function(point)
        local now = os.clock()
        if now - cacheAt > 2 then table.clear(cache); cacheAt = now end
        local key = math.floor(point.X / 8) .. ":" .. math.floor(point.Y / 8) .. ":" .. math.floor(point.Z / 8)
        local entry = cache[key]
        if not entry then
            local area, unlocked = areaAt(point)
            entry = {unlocked, area}
            cache[key] = entry
        end
        -- Sperren sind Ablaufzeiten (os.time); alte Dauer-Sperren (true) aus frueheren Versionen gelten nicht mehr
        local untilTime = api.BlockedAreas[entry[2]]
        return entry[1] and not (type(untilTime) == "number" and untilTime > os.time()), entry[2]
    end
end
-- Boden-Oberflaeche: Strahl von (position + upOffset) nach unten, ohne Spieler/Mobs (Living) und Drops (Debris).
local function surfaceAt(position, upOffset)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = {workspace.Living} -- enthaelt auch den eigenen Charakter
    local debris = workspace:FindFirstChild("Debris")
    if debris then table.insert(ignore, debris) end
    params.FilterDescendantsInstances = ignore
    local result = workspace:Raycast(position + Vector3.new(0, upOffset, 0), Vector3.new(0, -(upOffset + 40), 0), params)
    return result and result.Position
end
local function restoreCollisions()
    -- Kollision geht wieder an, waehrend der Charakter noch im Boden steckt (z. B. unter einem Mob): erst hochsetzen,
    -- sonst bleibt man stecken.
    local body = next(collision) and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    local human = body and player.Character:FindFirstChildOfClass("Humanoid")
    if body and human and human.Health > 0 then
        local floor = surfaceAt(body.Position, 15)
        if floor and floor.Y > body.Position.Y + 0.5 then
            body.CFrame = CFrame.new(floor + Vector3.new(0, human.HipHeight + body.Size.Y / 2 + 0.5, 0))
            body.AssemblyLinearVelocity = Vector3.zero
        end
    end
    for part, previous in pairs(collision) do if part.Parent then part.CanCollide = previous end end
    table.clear(collision)
end
-- MOB_PHYSICS_START
local mobPhysicsState
local function setMobPhysics(enabled)
    if not humanoid or not humanoid.Parent or humanoid.Health <= 0 then mobPhysicsState = nil; return end
    if enabled then
        if not mobPhysicsState then mobPhysicsState, lastDriven = humanoid:GetState(), nil end
        -- Humanoid ground support otherwise counters gradual noclip movement through floors.
        if humanoid:GetState() ~= Enum.HumanoidStateType.Physics then humanoid:ChangeState(Enum.HumanoidStateType.Physics) end
    elseif mobPhysicsState then
        local previous = mobPhysicsState
        mobPhysicsState, lastDriven = nil, nil
        humanoid:ChangeState(previous)
    end
end
-- MOB_PHYSICS_END
local function log(text)
    -- Kein print mehr: bei Fast Attack wechselte der Status bis zu 60x pro Sekunde und die Konsole lief voll (Lag).
    -- Der aktuelle Status steht im Menue unter Overview -> Status.
    api.State = text
end
function api:SaveSettings()
    local ok, why = pcall(function()
        assert(type(writefile) == "function", "writefile unavailable")
        local layout
        local window = self.MenuWindow and self.MenuWindow.Root
        if window then
            layout = {x = window.AbsolutePosition.X, y = window.AbsolutePosition.Y, width = window.AbsoluteSize.X, height = window.AbsoluteSize.Y, maximized = self.MenuWindow.Maximized == true}
            if layout.maximized and typeof(self.MenuWindow.Size) == "UDim2" then
                layout.width, layout.height = self.MenuWindow.Size.X.Offset, self.MenuWindow.Size.Y.Offset
            end
        end
        local encoded = HttpService:JSONEncode({version = 1, settings = Planner.savedSettings(self), window = layout})
        if type(isfile) == "function" and type(readfile) == "function" and isfile(settingsFile) then
            local previous = readfile(settingsFile)
            local valid, decoded = pcall(HttpService.JSONDecode, HttpService, previous)
            if valid and type(decoded) == "table" and decoded.version == 1 and type(decoded.settings) == "table" then writefile(settingsFile .. ".bak", previous) end
        end
        writefile(settingsFile, encoded)
    end)
    if ok then log("Settings saved") else log("Could not save settings: " .. tostring(why)) end
    return ok, why
end
local function await(promise)
    local ok, value = promise:timeout(12):await()
    if not ok then error(tostring(value)) end
    return value
end
local function slotOf(item)
    if item.Name and Equipment:GetItemType(item.Name) == "Pickaxe" then return "Pickaxe" end
    if item.Type then
        if Equipment.Items.Weapon[item.Type] then return "Weapon" end
        if Equipment.Items.Armor[item.Type] then
            -- Slot ueber die Grundart ("LightChestplate" usw.): Namen wie "Ninja's Armor" enthalten das Wort nicht
            local base = Equipment:GetItemBaseType(item.Type) or ""
            for _, slot in ipairs({"Helmet", "Chestplate", "Leggings"}) do
                if base:find(slot, 1, true) or item.Type:find(slot, 1, true) then return slot end
            end
        end
    end
    return nil
end

local function metrics(loadout)
    local ok, result = pcall(function()
        local runes, health, runeSlots = {}, 100, 0
        for _, item in pairs(loadout) do
            runeSlots += Equipment:GetRuneSlots(item)
            for _, rune in pairs(Runes:GetRunesFromItem(item)) do table.insert(runes, rune) end
            if Equipment.Items.Armor[item.Type] then local _, amount = Equipment:CalculateHealth(item); health += amount or 0 end
        end
        for _, rune in pairs(Sets.GetRunes(loadout, function(name) return Equipment:GetItemBaseType(name) end)) do table.insert(runes, rune) end
        local traits = Runes:GetCombinedTraits(runes)
        local vector = {}
        for key, value in pairs(traits) do
            assert(finite(value), "Unknown trait value: " .. tostring(key))
            vector["Trait:" .. key] = (key:sub(1, 8) == "Negative" or Runes:ShouldUseLowest(key)) and -value or value
        end
        vector.Health = health * math.max(0.01, 1 + ((traits.HealthBoost or 0) - (traits.NegativeHealthBoost or 0)) / 100)
        vector.RuneSlots = runeSlots
        vector.Defense = Equipment:CalculateArmorDamageReduction(loadout)
        vector.Discount = 1 - Sets.ShopMultiplier(loadout)
        local weapon = loadout.Weapon
        if weapon then
            local _, damage = Equipment:CalculateDamage(weapon)
            local speed = Equipment:CalculateAttackSpeed(nil, weapon) * (1 + (traits.AttackSpeedBoost or 0) / 100)
            vector.DPS = damage * (1 + (traits.DamageBoost or 0) / 100) * speed / math.max(0.01, Equipment:GetBaseAttackTime(Equipment:GetItemBaseType(weapon.Type)) or 1)
        end
        if loadout.Pickaxe then
            local base = Equipment:GetItemData(loadout.Pickaxe.Name)
            vector.MinePower = base["Mine Power"] or 0
            vector.MineSpeed = base["Mine Speed"] or 0
            vector.Luck = base["Luck Boost"] or 0
        end
        return vector
    end)
    if not ok then api.LastError = tostring(result); return nil end
    return result
end

local oreVectors = {}
local function oreMetrics(name)
    if oreVectors[name] then return oreVectors[name] end
    local vector = {Multiplier = Ores[name].Multiplier or 0}
    for _, kind in ipairs({"Weapon", "Armor"}) do
        local itemType = kind == "Weapon" and "Dagger" or "Light Helmet"
        local traits = Runes:GetCombinedTraits(Runes:GetRunesFromItem({Type = itemType, Ores = {[name] = 1}, Quality = 100}))
        for key, value in pairs(traits) do
            assert(finite(value), "Incomparable ore trait")
            vector[kind .. key] = (key:sub(1, 8) == "Negative" or Runes:ShouldUseLowest(key)) and -value or value
        end
    end
    oreVectors[name] = vector
    return vector
end

local function recipeCount(recipe)
    local total = 0
    for _, count in pairs(recipe) do total += count end
    return total
end
local function reserveRecipe(reserved, recipe)
    for name, count in pairs(recipe or {}) do reserved[name] = (reserved[name] or 0) + count end
end

function api:Stop(reason)
    if releaseForge and not FC.ForgeActive then releaseForge() end
    self.Running, self.Enabled = false, false
    generation += 1
    if stopMiningInput then stopMiningInput() end
    if releaseBlock then releaseBlock() end
    setMobPhysics(false)
    followAttack = nil
    lastDriven = nil
    destination = nil
    restoreCollisions()
    if humanoid and humanoid.Parent and saved then humanoid.AutoRotate = saved.autoRotate end
    -- Nur bei kurzer Strecke zum Startpunkt zuruecksetzen: ein Sprung quer ueber die Karte loeste vermutlich
    -- die Anti-Teleport-Kicks ("Anti-TP") aus. Sonst bleibt man stehen (aus dem Boden hebt restoreCollisions).
    if root and root.Parent and saved and saved.root == root and not FC.ForgeActive and (root.Position - saved.cframe.Position).Magnitude < 20 then
        root.CFrame = saved.cframe
        root.AssemblyLinearVelocity, root.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
    end
    saved, holdFrame, movementPaused = nil, nil, false
    log(reason or "Stopped; movement restored")
end
function api:Destroy()
    if destroyed then return end
    self.WantRunning = false
    self:Stop("Closed")
    destroyed = true
    if releaseForge then releaseForge() end
    for _, connection in ipairs(connections) do connection:Disconnect() end
    if self.DestroyMenu then self.DestroyMenu() elseif self.Gui then self.Gui:Destroy() end
    if self.DestroyVisuals then pcall(self.DestroyVisuals) end
    if self.StopManualFly then pcall(self.StopManualFly) end
    if env.ForgeProgressionHelper == self then env.ForgeProgressionHelper = nil end
end
function api:Start()
    if destroyed or self.Running then return false end
    self.Enabled = true
    self.SelectedOres = Planner.selection(self.SelectedOres, availableOres)
    self.SelectedMobs = Planner.selection(self.SelectedMobs, availableMobs)
    self.SelectedRocks = Planner.selection(self.SelectedRocks, availableRocks)
    -- Ein wartender Craft (Knopf "Craft" bei Best Craftable) braucht keine Erz-/Mob-Auswahl
    if not self.PendingCraft and self.FarmMode == "Ores Only" and not next(self.SelectedOres) and not next(self.SelectedRocks) then log("Select at least one ore or rock; utilities are active"); return false end
    if not self.PendingCraft and self.FarmMode == "Mobs Only" and not next(self.SelectedMobs) then log("Select at least one mob; utilities are active"); return false end
    character = player.Character
    root = character and character:FindFirstChild("HumanoidRootPart")
    humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not root or not humanoid or humanoid.Health <= 0 or (root.Anchored and not FC.ForgeActive) then log("Cannot start: check character"); return false end
    saved = {root = root, cframe = root.CFrame, autoRotate = humanoid.AutoRotate}
    humanoid.AutoRotate = false
    self.Running = true
    generation += 1
    log("Started: " .. self.FarmMode)
    return true
end
track(player.CharacterRemoving:Connect(function()
    if api.Enabled and api.Running and stats.startTime then stats.deaths += 1 end
    api:Stop(api.AutoRestart and api.WantRunning and "Character changed: auto restart pending" or "Character changed: enable farming again") end))
track(RunService.PreSimulation:Connect(function(dt)
    -- Physik-Modus (keine Bodenhaftung des Humanoids): beim Mob-Farmen immer, sonst waehrend jeder Flugstrecke.
    -- Vorher nur bei Mobs -> beim Flug zu Erzen/NPCs durch Boeden und Decken drueckte die Bodenhaftung den Charakter
    -- zurueck und er blieb zwischen zwei Ebenen stecken. Am Ziel (unter 2,5 Studs) wieder normaler Zustand.
    setMobPhysics(api.Enabled and api.Running and destination ~= nil and not FC.ForgeActive and (
        (followAttack ~= nil and followAttack.kind == "Kill")
        or (root ~= nil and root.Parent ~= nil and (root.Position - destination.Position).Magnitude > 2.5)))
    local current = player.Character
    -- Waehrend des Farmens immer noclip: sonst wird die Kollision wieder aktiv, waehrend man unter einem Mob
    -- oder in einem Stein steckt, und man bleibt im Boden haengen.
    if ((api.Enabled and ((api.Running and not movementPaused) or api.Noclip)) or (api.ManualFly and api.Noclip)) and current and not FC.ForgeActive then
        for _, part in ipairs(current:GetDescendants()) do
            if part:IsA("BasePart") then
                if collision[part] == nil then collision[part] = part.CanCollide end
                part.CanCollide = false
            end
        end
    else restoreCollisions() end
    if not api.Enabled or not api.Running then return end
    if not root or not root.Parent or not humanoid or humanoid.Health <= 0 then api:Stop("Dead / character unavailable"); return end
    if FC.ForgeActive or movementPaused then destination, lastDriven, holdFrame = nil, nil, nil; return end
    if not destination then
        -- Kein Ziel: an der aktuellen Stelle schweben, statt mit noclip durch die Welt zu fallen.
        if not holdFrame then
            holdFrame = root.CFrame
            -- Kein Ziel mehr (z. B. Mob ueber uns gestorben): nicht unter dem Boden warten, sondern an die Oberflaeche.
            local floor = surfaceAt(root.Position, math.max(api.MobDepth, 3) + 3)
            if floor and floor.Y > root.Position.Y + 0.5 then
                holdFrame = CFrame.new(floor + Vector3.new(0, humanoid.HipHeight + root.Size.Y / 2 + 0.5, 0))
            end
        end
        -- hinfliegen statt springen (ein Sprung kann die Anti-Teleport-Pruefung des Spiels ausloesen)
        local gap = (holdFrame.Position - root.Position).Magnitude
        root.CFrame = gap < 0.05 and holdFrame or root.CFrame:Lerp(holdFrame, math.min(1, api.Speed * dt / gap))
        root.AssemblyLinearVelocity, root.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
        lastDriven = nil
        return
    end
    holdFrame = nil
    if lastDriven and Planner.setback((root.Position - lastDriven).Magnitude, dt, api.Speed) then
        local _, area = accessible(destination.Position)
        -- Sperre laeuft ab: 10 min, bei jedem weiteren Rueckteleport doppelt so lange (max. 2 h). Frueher galt sie fuer
        -- immer -> ein einzelner Rueckteleport (Lag, Mob-Stoss) sperrte z. B. die ganze Spinnenhoehle samt Icy Boulder.
        local memory = env.ForgeHelperMemory
        memory.areaHits = memory.areaHits or {}
        local hits = (memory.areaHits[area] or 0) + 1
        memory.areaHits[area] = hits
        local minutes = math.min(120, 10 * 2 ^ (hits - 1))
        api.BlockedAreas[area] = os.time() + minutes * 60
        api:Stop(string.format("Server teleport detected; area blocked for %d min: %s", minutes, area))
        return
    end
    if not accessible(destination.Position) then api:Stop("Area locked or blocked"); return end
    if followAttack then
        destination = attackFrame(followAttack.target, followAttack.kind)
        if not destination then return end
    end
    local delta = destination.Position - root.Position
    root.CFrame = root.CFrame:Lerp(destination, math.min(1, api.Speed * dt / math.max(delta.Magnitude, 0.001)))
    lastDriven = root.Position
    root.AssemblyLinearVelocity, root.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
end))

local function station()
    local prompt = workspace.Proximity:FindFirstChild("Forge")
    return prompt and prompt:FindFirstChild("Station") and prompt.Station.Value, prompt
end
local function itemChance(itemType, count, forgeStation)
    local kind = Equipment:GetItemType(itemType)
    local base = Equipment:GetItemBaseType(itemType)
    if not (forgeStation and kind and base and Rarity[kind]) then return 0 end
    local name = Rarity:ResolveStation(forgeStation.Name, data())
    local classes = {}
    for _, config in ipairs(Rarity[kind]) do
        if #Rarity:GetAvailableItems(name, kind, config.name, data()) > 0 then table.insert(classes, table.clone(config)) end
    end
    local available = Rarity:GetAvailableItems(name, kind, base, data())
    local variantWeight, weight = 0, 0
    for _, variant in ipairs(available) do
        weight += 1 / (variant.Chance or 1)
        if variant.Name == itemType then variantWeight = 1 / (variant.Chance or 1) end
    end
    if weight == 0 then return 0 end
    for _, value in ipairs(Rarity:CalculateProbabilities(count, classes)) do
        if value.name == base then return value.chance / 100 * variantWeight / weight end
    end
    return 0
end
local function buildScore(vector)
    if not vector then return -math.huge end
    return math.max(1, vector.Health or 100) ^ 0.4 * math.max(1, vector.DPS or 1) ^ 0.6
end
local function planBuild(reserved)
    local forgeStation = station()
    if not forgeStation then return nil end
    local inventory, accessible = data().Inventory, {}
    local pickaxe = data().Equipped.Pickaxe
    local power = pickaxe and Equipment:CalculatePickaxeDamage(pickaxe) or 0
    for _, rock in ipairs(workspace.Rocks:GetDescendants()) do
        if rock:IsA("Model") and Planner.canMine(Rocks[rock.Name], power, pickaxe and pickaxe.Name) then
            for _, name in ipairs(Rocks[rock.Name].Ores or {}) do if Ores[name] then accessible[name] = true end end
        end
    end
    for name, count in pairs(inventory) do if Ores[name] and type(count) == "number" and count > (reserved[name] or 0) then accessible[name] = true end end
    local names = {}
    for name in pairs(accessible) do table.insert(names, name) end
    table.sort(names, function(a, b)
        if Ores[a].Multiplier == Ores[b].Multiplier then return a < b end
        return (Ores[a].Multiplier or 0) > (Ores[b].Multiplier or 0)
    end)
    -- shortcut: Mischungen der acht staerksten erreichbaren Erze; fuer globale Rezeptsuche erweitern.
    while #names > 8 do table.remove(names) end
    if #names == 0 then return nil end
    local target, bestBase, bestRelative = api.CraftTarget, nil, 0
    local baseline = metrics(data().Equipped)
    local stationName = Rarity:ResolveStation(forgeStation.Name, data())
    for _, kind in ipairs({"Armor", "Weapon"}) do
        for _, config in ipairs(Rarity[kind]) do
            for _, variant in ipairs(Rarity:GetAvailableItems(stationName, kind, config.name, data())) do
                local item = {Type = variant.Name, Quality = 100, Upgrade = 0, Ores = {[names[1]] = 1}, Runes = {}}
                local slot = slotOf(item)
                if slot and (target == "" or target == variant.Name) then
                    local candidate = table.clone(data().Equipped)
                    candidate[slot] = item
                    local relative = buildScore(metrics(candidate)) - buildScore(baseline)
                    if relative > bestRelative or (target ~= "" and bestBase == nil) then
                        bestRelative, bestBase = relative, {itemType = variant.Name, slot = slot}
                    end
                end
            end
        end
    end
    if not bestBase then return nil end
    local bestCount, bestEfficiency, chance = 0, 0, 0
    for count = 3, 80 do
        local probability = itemChance(bestBase.itemType, count, forgeStation)
        if probability / count > bestEfficiency then bestCount, bestEfficiency, chance = count, probability / count, probability end
    end
    if bestCount < 3 then return nil end
    local best, bestValue = nil, -math.huge
    local function consider(recipe)
        local fractions, value = {}, 0
        for name, amount in pairs(recipe) do fractions[name] = amount / bestCount; value += amount * (Ores[name].PriceMultiplier or Ores[name].Multiplier or 1) * 15 end
        local candidate = table.clone(data().Equipped)
        candidate[bestBase.slot] = {Type = bestBase.itemType, Quality = 100, Upgrade = 0, Ores = fractions, Runes = {}}
        local vector = metrics(candidate)
        local score = buildScore(vector)
        if score > bestValue then
            bestValue = score
            best = {itemType = bestBase.itemType, slot = bestBase.slot, recipe = recipe, chance = chance, metrics = vector,
                gain = score / math.max(1, buildScore(baseline)) - 1, materialValue = value, count = bestCount}
        end
    end
    for _, name in ipairs(names) do consider({[name] = bestCount}) end
    for _, main in ipairs(names) do
        for _, trait in ipairs(names) do
            if main ~= trait then
                local amount = math.ceil(bestCount * 0.3)
                consider({[main] = bestCount - amount, [trait] = amount})
            end
        end
    end
    return best
end

function api:Refresh()
    if type(setIdentity) == "function" then setIdentity(2) end
    local flags = {}
    for key, value in pairs(data().MiscDialogues or {}) do if key:sub(1, 8) == "Unlocked" then table.insert(flags, key .. ":" .. tostring(value)) end end
    table.sort(flags)
    local stamp = table.concat(flags, "|")
    if unlockStamp ~= "<unread>" and stamp ~= unlockStamp then table.clear(self.BlockedAreas) end
    unlockStamp, self.AreaUnlockStamp = stamp, stamp
    local allJobs, reserved, unsupported = Planner.pending(data(), Definitions, Ores, Rocks)
    local world, worldName = Planner.currentWorld(Islands.Data, game.PlaceId)
    local presentNpcs = {}
    local proximity = workspace:FindFirstChild("Proximity")
    if proximity then for _, npc in ipairs(proximity:GetChildren()) do presentNpcs[npc.Name] = true end end
    local jobs, skipped = Planner.worldJobs(allJobs, Definitions, QuestLog.Npcs or {}, world, presentNpcs)
    for name in pairs(self.SelectedOres) do reserved[name] = math.max(reserved[name] or 0, data().Inventory[name] or 0) end
    build = self.FarmMode == "Gold" and planBuild(reserved) or nil -- Upgrade-Schmieden nur im Modus "Gold"
    reserveRecipe(reserved, build and build.recipe)
    -- Erze fuer das aktive Schmiede-Ziel nicht verkaufen
    local goalPlan = self.ForgeGoalActive and self.ForgeGoal and self.ForgeGoal.plan
    reserveRecipe(reserved, goalPlan and goalPlan.reservedOres)
    local equipmentSales = self.FarmMode == "Gold" and Planner.equipmentSales(data(), slotOf, metrics) or {}
    local oreSales = self.FarmMode == "Gold" and Planner.oreSales(data(), Ores, reserved, oreMetrics, build and build.count or 12) or {}
    local shop = Proximities.Shop[self.TargetPickaxe]
    local quote = shop and Planner.quote(data(), shop.Price, Sets.ShopMultiplier(data().Equipped))
    local owned = false
    for _, item in ipairs(data().Inventory.Equipments or {}) do if item.Name == self.TargetPickaxe then owned = true end end
    report = {jobs = jobs, reserved = reserved, unsupported = unsupported, skippedWorldJobs = skipped,
        world = {index = world, name = worldName or "Unknown", placeId = game.PlaceId}, equipmentSales = equipmentSales, oreSales = oreSales,
        gold = data().Gold or 0, quote = quote, owned = owned, remaining = quote and math.max(0, quote - (data().Gold or 0)) or nil,
        currentStats = metrics(data().Equipped), build = build}
    lastPlan = os.clock()
    return report
end
function api:GetStatus()
    return {enabled = self.Enabled, running = self.Running, state = self.State, error = self.LastError, target = self.TargetPickaxe, lastCraft = self.LastCraft, plan = report,
        farmMode = self.FarmMode, selectedOres = self.SelectedOres, selectedMobs = self.SelectedMobs, selectedRocks = self.SelectedRocks, blockedAreas = self.BlockedAreas, removedLavaZones = self.RemovedLavaZones,
        skipNearEnemies = self.SkipNearEnemies, autoRestart = self.AutoRestart,
        defense = {enabled = self.AutoBlock, active = self.Defending, attempts = self.BlocksAttempted, confirmedParries = self.ParriesConfirmed},
        movement = {mobDepth = self.MobDepth, oreDepth = self.OreDepth, autoRange = self.AutoRange, actualDepth = self.UnderDistance, targetKind = self.UnderTarget,
            orePosition = self.OrePosition, activeOrePosition = self.ActiveOrePosition}}
end
function api:Export()
    local text = HttpService:JSONEncode(self:GetStatus())
    print("[ForgeHelper-Plan] " .. text)
    if type(writefile) == "function" then
        local name = "ForgePlan-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999)) .. ".json"
        writefile(name, text)
        log("Plan exported: " .. name)
        return name
    end
    log("Plan printed; writefile unavailable")
    return nil
end

local function alive(token) return api.Enabled and api.Running and generation == token and not destroyed end
local function goTo(frame, token, timeout)
    followAttack = nil
    if not accessible(frame.Position) then log("Destination is in a locked area"); return false end
    if stopMiningInput then stopMiningInput() end
    destination = frame
    local start = os.clock()
    while alive(token) and (root.Position - frame.Position).Magnitude > 1.7 do
        if os.clock() - start > (timeout or 25) then destination = nil; return false end
        task.wait(0.1)
    end
    return alive(token)
end
local function npcAt(name)
    for _, option in ipairs(string.split(name or "", ",")) do
        local npc = workspace.Proximity:FindFirstChild(option)
        if npc then return npc end
    end
    return nil
end
local function approach(npc, token)
    if not npc then return false end
    local position = npc:GetPivot().Position
    local frame = CFrame.lookAt(position + Vector3.new(0, 1, 4), position)
    return goTo(frame, token)
end
local function talk(npc, token)
    if not approach(npc, token) then return false end
    await(ProximityService:Dialogue(npc))
    return alive(token)
end
local function sell(token, items, isEquipment)
    if not next(items) then return false end
    local npc = npcAt(isEquipment and "Marbles" or "Greedy Cey")
    if not npc then return false end
    if not approach(npc, token) then return false end
    -- Nach der Anreise erneut pruefen: Quests, Favoriten oder Ausruestung koennen sich geaendert haben.
    api:Refresh()
    items = isEquipment and report.equipmentSales or report.oreSales
    if not next(items) or not alive(token) or not api.AutoSell then return false end
    local module = UI.Modules[isEquipment and "WeaponSell" or "MiscSell"]
    if not module or not module.SellInfo then return false end
    local before = HttpService:JSONEncode(data().Inventory)
    module.SellInfo.Basket = items
    module.SellInfo.Price = "Automatik"
    log("Selling confirmed surplus at " .. npc.Name)
    await(ProximityService:Dialogue(npc))
    if not alive(token) or not api.AutoSell then return false end
    await(DialogueService:RunCommand("SellConfirm", {Basket = items}))
    task.wait(2)
    if before == HttpService:JSONEncode(data().Inventory) then
        log("Sale not confirmed; items retained")
    else
        log("Inventory updated after sale")
    end
    return true
end

-- AUTO_SELL_START
-- Verkauft alle Erze unter api.SellBelowMultiplier, sobald der Stash api.SellAtStashPercent erreicht.
-- Gleicher Ablauf wie im Spiel (live geprueft): MiscSell.SellInfo.Basket setzen ->
-- ProximityService:ForceDialogue(Greedy Cey, "SellConfirmMisc") -> Antwort "Deal." klicken
-- (deren Command-Node ruft DialogueService:RunCommand("SellConfirm", {Basket = ...}) auf).
local lastSellCheck, sellRetryAt = 0, 0
local function stashFill()
    -- Dieselbe Rechnung wie die Stash-Anzeige im Spiel (z. B. 166 / 494).
    local inventory = UI.Modules and UI.Modules.Inventory
    if not inventory then return nil end
    local okTotal, total = pcall(inventory.CalculateTotal, inventory, "Stash")
    local okCapacity, capacity = pcall(inventory.GetBagCapacity, inventory)
    if not okTotal or not okCapacity or not finite(total) or not finite(capacity) or capacity <= 0 then return nil end
    return total, capacity
end
local function sellBasket()
    local basket, count = {}, 0
    local goal = api.FarmMode == "Forging" and api.ForgeGoalActive and api.ForgeGoal
    local goalPlan = goal and goal.refresh(true)
    if goal and (not goalPlan or goalPlan.error) then return basket, count, "waiting for a valid forging plan" end
    local _, questReserve = Planner.pending(data(), Definitions, Ores, Rocks)
    local favorites = data().Favorites or {}
    for name, amount in pairs(data().Inventory) do
        local ore = Ores[name]
        if ore and finite(amount) and amount > 0 and not favorites[name]
            and finite(ore.Multiplier) and ore.Multiplier < api.SellBelowMultiplier then
            local keep = (questReserve[name] or 0) + (build and build.recipe and build.recipe[name] or 0)
                + (goalPlan and goalPlan.reservedOres[name] or 0)
            local amountToSell = math.floor(amount - keep)
            if amountToSell > 0 then basket[name], count = amountToSell, count + amountToSell end
        end
    end
    return basket, count
end
local function dealButton()
    local billboard = player.PlayerGui:FindFirstChild("ResponseBillboard", true)
    local list = billboard and billboard:FindFirstChild("List")
    for _, frame in ipairs(list and list:GetChildren() or {}) do
        local button = frame:IsA("Frame") and frame.Visible and frame:FindFirstChild("Button")
        if button and button:IsA("GuiButton") and button.Text:find("Deal") then return button end
    end
    return nil
end
local function autoSellOres(token)
    if not api.AutoSell or api.SellBelowMultiplier <= 0 then return false end
    if os.clock() < sellRetryAt or os.clock() - lastSellCheck < 2 then return false end
    lastSellCheck = os.clock()
    local total, capacity = stashFill()
    if not total or total / capacity * 100 < api.SellAtStashPercent then return false end
    local basket, count, waiting = sellBasket()
    if count == 0 then
        sellRetryAt = os.clock() + (waiting and 5 or 15)
        log(waiting and ("Auto Sell: " .. waiting) or string.format("Stash %d/%d: no unreserved ores below %.1fx to sell",
            total, capacity, api.SellBelowMultiplier))
        return false
    end
    sellRetryAt = os.clock() + 30
    if stopMiningInput then stopMiningInput() end
    local before, goldBefore = {}, data().Gold or 0
    for name in pairs(basket) do before[name] = data().Inventory[name] or 0 end
    local function sold()
        for name, amount in pairs(before) do if (data().Inventory[name] or 0) < amount then return true end end
        return false
    end
    if data().Gamepasses and data().Gamepasses.SellAnywhere then
        -- Gamepass "Sell Anywhere": das Spiel verkauft ohne Anreise.
        log(string.format("Auto Sell: selling %d ores (Sell Anywhere)", count))
        await(InventoryService:SellAnywhere(basket))
    else
        local npc = npcAt("Greedy Cey")
        if not npc then
            sellRetryAt = os.clock() + 60
            log("Auto Sell: stash full, but Greedy Cey is not on this island")
            return false
        end
        log(string.format("Auto Sell: flying to Greedy Cey (%d ores, stash %d/%d)", count, total, capacity))
        if not approach(npc, token) then return false end
        basket, count = sellBasket() -- nach der Anreise neu berechnen
        if count == 0 or not alive(token) or not api.AutoSell then return false end
        table.clear(before)
        for name in pairs(basket) do before[name] = data().Inventory[name] or 0 end
        local misc = UI.Modules.MiscSell
        if not misc or not misc.SellInfo then error("Auto Sell: MiscSell module unavailable") end
        misc.SellInfo.Basket = basket
        misc.SellInfo.Price = count .. " ores"
        movementPaused, destination, followAttack = true, nil, nil
        local ok, why = pcall(function()
            ProximityService:ForceDialogue(npc, "SellConfirmMisc")
            local button
            local deadline = os.clock() + 12
            repeat task.wait(0.2); button = dealButton() until button or os.clock() > deadline or not alive(token)
            if not alive(token) then return end
            log("Auto Sell: confirming \"Deal.\"")
            if button and type(firesignal) == "function" then
                firesignal(button.MouseButton1Click) -- wie ein echter Klick: verkauft und schliesst den Dialog
            else
                await(DialogueService:RunCommand("SellConfirm", {Basket = basket}))
            end
            local waitUntil = os.clock() + 5
            while not sold() and os.clock() < waitUntil do task.wait(0.2) end
        end)
        movementPaused = false
        if not ok then error(why) end
    end
    local waitUntil = os.clock() + 5
    while not sold() and os.clock() < waitUntil do task.wait(0.2) end
    if sold() then
        sellRetryAt = os.clock() + 5
        if stats.startTime then
            stats.sold += count
            stats.soldGold += math.max(0, (data().Gold or 0) - goldBefore)
        end
        log(string.format("Auto Sell: sold %d ores below %.1fx", count, api.SellBelowMultiplier))
    else
        log("Auto Sell: sale not confirmed by the server; ores kept")
    end
    return true
end
-- AUTO_SELL_END

local activeTarget, activeJob, targetHealth, targetTime = nil, nil, nil, 0
local rangeMisses, lastRangeAdjust = 0, 0
local lastSwing = 0
local function weaponReach()
    local weapon = data().Equipped.Weapon
    if not weapon then return 4 end
    local definition = Equipment:GetItemData(weapon.Type)
    local base = Equipment.BaseTypes[Equipment:GetItemBaseType(weapon.Type)]
    local reach = math.huge
    for _, size in ipairs(base and base.Combat and base.Combat.HitboxSize or {}) do
        if typeof(size) == "Vector3" and size.Z > 0 then reach = math.min(reach, size.Z) end
    end
    return reach == math.huge and 4 or reach * (definition and definition.RangeMultiplier or 1)
end
local function healthOf(target, kind)
    if not target or not target.Parent then return 0 end
    if kind == "Kill" then local h = target:FindFirstChildOfClass("Humanoid"); return h and h.Health or 0 end
    return target:GetAttribute("IsBroken") and 0 or (target:GetAttribute("Health") or 0)
end
-- ENEMY_SKIP_START
-- Reichweite: api.EnemySkipRadius (Regler unter Farming & Distance, Standard 20 Studs)
local ENEMY_SKIP_SECONDS = 180 -- uebersprungene Steine bleiben mindestens 3 Minuten gesperrt
-- Steine werden zusaetzlich ueber ihre Position gesperrt, damit auch ein neu gespawnter Stein am selben Platz gesperrt bleibt.
local blockedSpots, lastBlockSweep = {}, 0
local function spotKey(target)
    local p = target:GetPivot().Position
    return math.floor(p.X / 3 + 0.5) .. ":" .. math.floor(p.Y / 3 + 0.5) .. ":" .. math.floor(p.Z / 3 + 0.5)
end
local function blockTarget(target, seconds)
    local now = os.clock()
    if now - lastBlockSweep > 10 then
        lastBlockSweep = now
        for key, untilTime in pairs(blocked) do if untilTime <= now then blocked[key] = nil end end
        for key, untilTime in pairs(blockedSpots) do if untilTime <= now then blockedSpots[key] = nil end end
    end
    local untilTime = now + seconds
    blocked[target] = math.max(blocked[target] or 0, untilTime)
    if not target:FindFirstChildOfClass("Humanoid") then
        local key = spotKey(target)
        blockedSpots[key] = math.max(blockedSpots[key] or 0, untilTime)
    end
end
local function isBlocked(target)
    local now = os.clock()
    if (blocked[target] or 0) > now then return true end
    return not target:FindFirstChildOfClass("Humanoid") and (blockedSpots[spotKey(target)] or 0) > now
end
local enemyCache, enemyCacheAt = {}, 0
local function enemyNear(position, radius)
    if os.clock() - enemyCacheAt > 0.1 then
        enemyCacheAt = os.clock()
        table.clear(enemyCache)
        for _, mob in ipairs(workspace.Living:GetChildren()) do
            local mobRoot = mob:FindFirstChild("HumanoidRootPart")
            if mobRoot and mob:GetAttribute("IsNpc") and not mob:GetAttribute("DpsDummy")
                and not Players:GetPlayerFromCharacter(mob) and healthOf(mob, "Kill") > 0 then
                table.insert(enemyCache, mobRoot.Position)
            end
        end
    end
    for _, p in ipairs(enemyCache) do if (p - position).Magnitude <= radius then return true end end
    return false
end
-- Steine, die die angelegte Spitzhacke NICHT abbauen darf (z. B. Soul Boulder/Spirit Rock: nur Spirit-, Yin-Yang- oder
-- Dev's-Bane-Spitzhacke; oder zu hoher RequiredDamage). Der Schlag des Spiels trifft den Stein direkt vor dem
-- Charakter -> liegt so ein Stein dicht neben dem Ziel, hackte der Bot auf ihn ("needs Yin-Yang Pickaxe").
-- Solche Ziele werden uebersprungen. (Als Planner-Feld statt neuer lokaler Variable: Limit 200 Register.)
Planner.forbiddenRocks = {list = {}, at = -math.huge}
function Planner.forbiddenNeighbor(target, power, pickaxeName)
    local cache = Planner.forbiddenRocks
    if os.clock() - cache.at > 2 then
        cache.at = os.clock()
        table.clear(cache.list)
        for _, rock in ipairs(workspace.Rocks:GetDescendants()) do
            local rockData = rock:IsA("Model") and Rocks[rock.Name]
            if rockData and rock:GetAttribute("IsInitiated") and healthOf(rock, "Mine") > 0
                and not Planner.canMine(rockData, power, pickaxeName, rock:GetAttribute("RequiredDamage")) then
                table.insert(cache.list, {position = rock:GetPivot().Position, reach = rock:GetExtentsSize().Magnitude / 2})
            end
        end
    end
    if #cache.list == 0 then return false end
    local position, targetReach = target:GetPivot().Position, nil
    for _, entry in ipairs(cache.list) do
        local distance = (entry.position - position).Magnitude
        if distance < 40 then
            targetReach = targetReach or target:GetExtentsSize().Magnitude / 2
            -- Abstand der Huellkugeln unter 3 Studs -> der Schlag kann den verbotenen Stein treffen
            if distance - entry.reach - targetReach <= 3 then return true end
        end
    end
    return false
end
-- ENEMY_SKIP_END
local function eligible(target, job, power)
    -- FPS: billige Pruefungen zuerst, die teure Gebietspruefung (accessible) ganz zum Schluss.
    if not target:IsA("Model") then return false end
    if job.kind == "Kill" then
        if not (target:GetAttribute("IsNpc") == true and not target:GetAttribute("DpsDummy")) then return false end
        if not (job.all or (job.fillers and job.fillers[mobKey(target)])
            or job.selected and job.selected[mobKey(target)] == true
            or not job.selected and Planner.killMatches(target.Name, job.target, target:GetAttribute("Mutation"), target:GetAttribute("EventMutation"))) then return false end
        if healthOf(target, "Kill") <= 0 or isBlocked(target) or Players:GetPlayerFromCharacter(target) then return false end
        local position = target:GetPivot().Position
        if job.center and (position - job.center).Magnitude > (job.radius or api.KillRadius) then return false end
        if job.points then
            -- Mob-Respawn-Hilfe: nur Mobs im Spawn-Gebiet der fehlenden Quest-Art (gleiche Art anderswo bringt nichts)
            local near = false
            for _, point in ipairs(job.points) do
                if (position - point).Magnitude <= job.radius then near = true; break end
            end
            if not near then return false end
        end
        return accessible(position)
    end
    local rock = Rocks[target.Name]
    if not rock or not target:GetAttribute("IsInitiated") or healthOf(target, "Mine") <= 0 then return false end
    local pickaxeName = (data().Equipped.Pickaxe or {}).Name
    if not Planner.canMine(rock, power, pickaxeName, target:GetAttribute("RequiredDamage")) then return false end
    local wanted = job.kind == "Gold" or (job.kind == "SelectedOre" and Planner.rockMatches(target.Name, rock.Ores, job.selected, job.rocks))
        or (job.kind == "Mine" and target.Name == job.target) or (job.kind == "Ore" and table.find(rock.Ores or {}, job.target) ~= nil)
        or (job.kind == "Respawn" and Planner.respawnRockMatches(job, target.Name, target.Parent and target.Parent.Parent and target.Parent.Parent.Name or ""))
    if not wanted or isBlocked(target) then return false end
    if Planner.forbiddenNeighbor(target, power, pickaxeName) then return false end
    local position = target:GetPivot().Position
    if api.SkipNearEnemies and enemyNear(position, api.EnemySkipRadius) then
        -- Nur den Stein, den wir gerade ansteuern/abbauen, 3 Minuten sperren. Vorher wurde bei jeder Suche JEDER
        -- Stein neben irgendeinem Mob gesperrt -> uebrig blieben nur Steine am Kartenrand, der Bot flog dorthin
        -- und nach Ablauf der Sperren wieder zurueck.
        if target == activeTarget then blockTarget(target, ENEMY_SKIP_SECONDS) end
        return false
    end
    return accessible(position)
end
local function goldRate(target, power)
    local rock, sum, weights = Rocks[target.Name], 0, 0
    for _, name in ipairs(rock.Ores or {}) do
        local ore = Ores[name]
        if ore then
            local weight = 1 / math.max(1, ore.Chance or 1)
            sum += (ore.PriceMultiplier or ore.Multiplier or 1) * 15 * weight
            weights += weight
        end
    end
    local drops = rock.SpawnCountRange and (rock.SpawnCountRange[1] + rock.SpawnCountRange[2]) / 2 or 1
    -- shortcut: Erwartungswert aus Erzgewichten; der Server kann Luck und Zusatzdrops anders anwenden.
    return sum / math.max(0.001, weights) * drops / math.max(1, (target:GetAttribute("Health") or rock.Health) / math.max(1, power))
end
-- Seltenheit eines Steins = hoechster Multiplikator unter seinen moeglichen Erzen
-- (bei einer Erz-Auswahl nur unter den ausgewaehlten Erzen).
local function rockRarity(target, job)
    local best = 0
    local selected = job.kind == "SelectedOre" and job.selected and next(job.selected) and job.selected or nil
    for _, name in ipairs(Rocks[target.Name] and Rocks[target.Name].Ores or {}) do
        local counts
        if job.kind == "Ore" then counts = name == job.target else counts = not selected or selected[name] == true end
        if counts then best = math.max(best, Planner.orePower(name, Ores)) end
    end
    return best
end
local function findTarget(job)
    local pickaxe = data().Equipped.Pickaxe
    local power = pickaxe and Equipment:CalculatePickaxeDamage(pickaxe) or 0
    local jobKey = job.kind .. ":" .. tostring(job.target)
    if activeTarget and activeJob == jobKey and eligible(activeTarget, job, power) then return activeTarget end
    -- Statistik: Das bisherige Ziel ist weg, weil es kaputt/tot ist (Leben 0) -> zaehlen.
    if stats.startTime and activeTarget and activeJob == jobKey and (targetHealth or 0) > 0 and healthOf(activeTarget, job.kind) <= 0 then
        if job.kind == "Kill" then stats.kills += 1 else stats.rocksBroken += 1 end
        targetHealth = 0
    end
    local rareFirst = api.RareFirst and (job.kind == "SelectedOre" or job.kind == "Ore" or job.kind == "Mine")
    local folder = job.kind == "Kill" and workspace:FindFirstChild("Living") or workspace:FindFirstChild("Rocks")
    if not folder then return nil end
    local best, bestScore = nil, math.huge
    local targets = job.kind == "Kill" and folder:GetChildren() or folder:GetDescendants()
    for _, target in ipairs(targets) do
        if eligible(target, job, power) then
            local distance = (target:GetPivot().Position - root.Position).Magnitude
            local score = job.kind == "Gold" and (distance / api.Speed + 1) / math.max(0.001, goldRate(target, power)) or distance
            -- Seltene Erze zuerst: hoeherer Multiplikator gewinnt immer, bei Gleichstand der naehere Stein.
            if rareFirst then score = distance - rockRarity(target, job) * 1e6 end
            if score < bestScore then best, bestScore = target, score end
        end
    end
    if best then
        activeTarget, activeJob = best, job.kind .. ":" .. tostring(job.target)
        targetHealth, targetTime = healthOf(best, job.kind), os.clock()
        rangeMisses, lastRangeAdjust = 0, os.clock()
    end
    return best
end
attackFrame = function(target, kind)
    if not target or not target.Parent then return nil end
    local position = target:GetPivot().Position
    local targetRoot = target:FindFirstChild(kind == "Kill" and "HumanoidRootPart" or "Hitbox")
    if targetRoot and targetRoot:IsA("BasePart") then
        position = targetRoot.Position
    end
    local requested = kind == "Kill" and api.MobDepth or api.OreDepth
    local under = Planner.underOffset(kind == "Kill" and weaponReach() or 4.5, rangeMisses, requested, api.AutoRange)
    local frame
    if kind == "Kill" then
        local stand = position - Vector3.new(0, under, 0)
        frame = CFrame.lookAt(stand, position, Vector3.zAxis)
    else
        if not targetRoot or not targetRoot:IsA("BasePart") then return nil end
        local boxFrame, size = targetRoot.CFrame, targetRoot.Size
        local top = (math.abs(boxFrame.RightVector.Y) * size.X + math.abs(boxFrame.UpVector.Y) * size.Y + math.abs(boxFrame.LookVector.Y) * size.Z) / 2
        -- Standhoehe nur bei Automatic Range erzwingen; manuell darf die Hoehe bis 0 gehen.
        if api.AutoRange then under = math.max(under, humanoid.HipHeight + root.Size.Y / 2) end
        frame = CFrame.new(position + Vector3.new(0, top + under, 0))
        api.ActiveOrePosition = "Above"
    end
    api.UnderDistance, api.UnderTarget = under, kind == "Kill" and "Mob" or "Ore"
    return frame
end
-- attacking: true, solange wirklich geschlagen/abgebaut wird -> nur dann laeuft die Schleife jeden Frame (Fast Attack).
local swingState = {attacking = false, service = Knit.GetService("ToolService")}
local function attack(target, job, token)
    swingState.attacking = false
    if api.Defending then return end
    followAttack = {target = target, kind = job.kind}
    destination = attackFrame(target, job.kind)
    if not destination then return end
    -- Mobs bewegen sich staendig: bis 4 Studs Abstand trotzdem zuschlagen (vorher 1,2 -> viele Schlaege fielen aus).
    if (root.Position - destination.Position).Magnitude > (job.kind == "Kill" and 4 or 1.2) then
        if stopMiningInput then stopMiningInput() end
        targetTime, lastRangeAdjust = os.clock(), os.clock()
        log((job.kind == "Kill" and "Moving below " or "Moving above ") .. target.Name)
        return
    end
    -- Beim Abbauen: Gegner innerhalb von 10 Studs -> Stein ueberspringen und naechsten nehmen.
    -- (nicht im Clash: dort sind ueberall Mobs, Kristalle/Steine sollen trotzdem abgebaut werden)
    if job.kind ~= "Kill" and job.kind ~= "ClashMine" and api.SkipNearEnemies and enemyNear(root.Position, api.EnemySkipRadius) then
        blockTarget(target, ENEMY_SKIP_SECONDS)
        activeTarget, destination, followAttack = nil, nil, nil
        if stopMiningInput then stopMiningInput() end
        log("Enemy within " .. api.EnemySkipRadius .. " studs: skipping " .. target.Name)
        return
    end
    local toolName = job.kind == "Kill" and "Weapon" or "Pickaxe"
    local tool = character:FindFirstChild(toolName) or player.Backpack:FindFirstChild(toolName)
    if not tool then log("Missing tool: " .. toolName); return end
    if tool.Parent ~= character then humanoid:EquipTool(tool); task.wait(0.2) end
    if not alive(token) or api.Defending then return end
    log((job.label or job.quest and job.quest .. ": " or (job.kind == "SelectedOre" and "Ore farming: " or (job.kind == "Kill" and job.all and "Kill all: " or job.kind == "Kill" and job.selected and "Mob farming: " or "Kitsune gold: "))) .. target.Name)
    swingState.attacking = true
    if job.kind == "Kill" then
        if stopMiningInput then stopMiningInput() end
        -- Max. 20 Schlaege/s: oefter bringt nichts (Server-Cooldown).
        -- Direkt ToolService aufrufen (gibt sofort ein Promise zurueck); ToolController:ToolActivated wartet
        -- bei manchen Werkzeugen jedes Mal 0,1 s und bremst damit die Schleife.
        if os.clock() - lastSwing >= 0.05 then
            lastSwing = os.clock()
            swingState.service:ToolActivated(tool.Name)
        end
    else mineFromInput(target) end
    local health = healthOf(target, job.kind)
    local ownHit = job.kind == "Kill" and health ~= targetHealth or Planner.ownMiningHit(targetHealth, health, target:GetAttribute("LastHitPlayer"), target:GetAttribute("LastHitGolem"), player.Name)
    if ownHit then
        targetHealth, targetTime, lastRangeAdjust = health, os.clock(), os.clock()
    elseif api.AutoRange and os.clock() - lastRangeAdjust > 3 then
        rangeMisses += 1
        lastRangeAdjust = os.clock()
        log("No own hit: checking distance")
    end
    targetHealth = health
    if os.clock() - targetTime > 16 then
        blockTarget(target, 45)
        activeTarget, destination = nil, nil
        log("No progress: switching target")
    end
end

local VirtualInput = game:GetService("VirtualInputManager")
local forgeMouseDown, forgeHook, forgeOriginal, forgeStarted = false, nil, nil, 0
local forgeBusy = false
local forgeEpoch = 0
local function virtual(method, ...)
    if type(setIdentity) == "function" then setIdentity(8) end
    local result = table.pack(pcall(VirtualInput[method], VirtualInput, ...))
    if type(setIdentity) == "function" then setIdentity(2) end
    if not result[1] then error(result[2]) end
    return table.unpack(result, 2, result.n)
end
local miningMouseDown, miningMousePoint, miningPulse = false, nil, 0
stopMiningInput = function()
    if miningMouseDown then
        pcall(virtual, "SendMouseButtonEvent", miningMousePoint.X, miningMousePoint.Y, 0, false, game, 0)
        miningMouseDown = false
    end
end
local function miningClickPoint(view)
    for _, point in ipairs({Vector2.new(view.X - 120, view.Y - 230), Vector2.new(2, 2), Vector2.new(view.X - 2, 2), Vector2.new(2, view.Y - 2), Vector2.new(view.X - 2, view.Y - 2)}) do
        local blockedByGui = false
        for _, object in ipairs(player.PlayerGui:GetGuiObjectsAtPosition(point.X, point.Y)) do
            if object.Active or object:IsA("GuiButton") then blockedByGui = true; break end
        end
        if not blockedByGui then return Vector2.new(math.max(1, math.floor(point.X)), math.max(1, math.floor(point.Y))) end
    end
    return nil
end
mineFromInput = function(target)
    if api.Defending then return end
    local camera = workspace.CurrentCamera
    local box = target:FindFirstChild("Hitbox")
    if not camera or not box then return end
    if miningMouseDown then
        if os.clock() - miningPulse >= 0.6 then
            virtual("SendMouseButtonEvent", miningMousePoint.X, miningMousePoint.Y, 0, false, game, 0)
            miningMouseDown, miningPulse = false, os.clock()
        end
    elseif os.clock() - miningPulse >= (api.FastAttack and 0.03 or 0.12) then
        miningMousePoint = miningClickPoint(camera.ViewportSize)
        if not miningMousePoint then log("No free click point: minimize the menu"); return end
        virtual("SendMouseButtonEvent", miningMousePoint.X, miningMousePoint.Y, 0, true, game, 0)
        miningMouseDown, miningPulse = true, os.clock()
    end
end
local blockSession
local attackTimings, warnings = {}, setmetatable({}, {__mode = "k"})
local function attackTimingKey(attacker)
    local key = Planner.mobName(attacker.Name, Enemies) or attacker.Name
    local human = attacker:FindFirstChildOfClass("Humanoid")
    local animator = human and human:FindFirstChildOfClass("Animator")
    local chosen
    if animator then
        for _, animation in ipairs(animator:GetPlayingAnimationTracks()) do
            if animation.Priority.Value >= Enum.AnimationPriority.Action.Value and animation.Animation
                and (not chosen or animation.TimePosition < chosen.TimePosition) then chosen = animation end
        end
    end
    return chosen and key .. ":" .. chosen.Animation.AnimationId or key
end
-- BLOCK_RELEASE_START
releaseBlock = function()
    local session = blockSession
    blockSession, api.Defending = nil, false
    if not session then return end
    if session.blocking then pcall(ToolController.StopBlock, ToolController) end
    if player.Character == session.character and session.humanoid.Health > 0 and session.weapon.Parent == session.character then
        if session.previous and session.previous ~= session.weapon and (session.previous.Parent == player.Backpack or session.previous.Parent == session.character) then
            session.humanoid:EquipTool(session.previous)
        elseif not session.previous then session.humanoid:UnequipTools() end
    end
end
-- BLOCK_RELEASE_END
local function prepareDefense(attacker)
    if blockSession then return blockSession.attacker == attacker and blockSession or nil end
    if destroyed or not api.Enabled or not api.AutoBlock or FC.ForgeActive or ToolController.isBlocking then return end
    if typeof(attacker) ~= "Instance" or not attacker:IsA("Model") or not attacker:GetAttribute("IsNpc") or attacker:GetAttribute("DpsDummy") then return end
    local current = player.Character
    local body = current and current:FindFirstChild("HumanoidRootPart")
    local human = current and current:FindFirstChildOfClass("Humanoid")
    local enemy = attacker:FindFirstChild("HumanoidRootPart")
    local enemyHuman = attacker:FindFirstChildOfClass("Humanoid")
    if not body or not human or human.Health <= 0 or body.Anchored or not enemy or not enemyHuman or enemyHuman.Health <= 0 then return end
    local offset = body.Position - enemy.Position
    local flat = Vector3.new(offset.X, 0, offset.Z)
    local look = Vector3.new(enemy.CFrame.LookVector.X, 0, enemy.CFrame.LookVector.Z)
    local facing = flat.Magnitude < 1 and 1 or (look.Magnitude > 0 and look.Unit:Dot(flat.Unit) or 0)
    if not Planner.blockThreat(offset.Magnitude, facing, true) then return end
    local weapon = current:FindFirstChild("Weapon") or player.Backpack:FindFirstChild("Weapon")
    if not weapon then return end
    local session = {character = current, humanoid = human, weapon = weapon, previous = weapon.Parent == current and weapon or current:FindFirstChildOfClass("Tool"), attacker = attacker, deadline = os.clock() + 1.5}
    blockSession, api.Defending = session, true
    stopMiningInput()
    task.spawn(function()
        if type(setIdentity) == "function" then setIdentity(2) end
        local ok, why = pcall(function()
            if blockSession ~= session then return end
            if weapon.Parent ~= current then human:EquipTool(weapon) end
            while blockSession == session and api.AutoBlock and not FC.ForgeActive and player.Character == current and human.Health > 0 and os.clock() < session.deadline do task.wait() end
        end)
        if blockSession == session then releaseBlock() end
        if not ok then api.LastError = tostring(why); warn("[ForgeHelper] Auto block: " .. tostring(why)) end
    end)
    return session
end
local function defend(attacker, parryable)
    if parryable == false then if blockSession and blockSession.attacker == attacker then releaseBlock() end; return end
    local session = prepareDefense(attacker)
    if not session or session.scheduled then return end
    local key = attackTimingKey(attacker)
    local impact = attackTimings[key] or 0.35
    local latency = 0
    pcall(function() latency = player:GetNetworkPing() end)
    warnings[attacker] = {time = os.clock(), key = key}
    session.scheduled, session.deadline = true, os.clock() + impact + 0.25
    task.delay(Planner.parryDelay(impact, latency), function()
        if blockSession ~= session or not api.Enabled or not api.AutoBlock or destroyed or FC.ForgeActive or player.Character ~= session.character or session.humanoid.Health <= 0 then return end
        if type(setIdentity) == "function" then setIdentity(2) end
        local ok, why = pcall(function()
            ToolController:StartBlock()
            session.blocking = ToolController.isBlocking == true
            if session.blocking then api.BlocksAttempted += 1; log("Blocking incoming attack") end
        end)
        if not ok then api.LastError = tostring(why); releaseBlock() end
    end)
end
local effects = ReplicatedStorage.Assets.Effects
local parryIndicator = effects:FindFirstChild("ParryIndicator")
local parryEffect = effects:FindFirstChild("Parry")
track(workspace.Living.DescendantAdded:Connect(function(value)
    if value.Name == "Attacking" and value.Parent and value.Parent.Name == "Status" then prepareDefense(value.Parent.Parent) end
end))
track(Knit.GetService("EffectService").Event:Connect(function(module, method, subject, parryable, details)
    if method ~= "effect" then return end
    if parryIndicator and module == parryIndicator:FindFirstChild("Handler") then
        defend(subject, parryable)
    elseif parryEffect and module == parryEffect:FindFirstChild("Handler") and subject == player.Character and blockSession and blockSession.blocking then
        api.ParriesConfirmed += 1
        local warning = warnings[blockSession.attacker]
        if warning then attackTimings[warning.key] = os.clock() - warning.time end
        log("Perfect block confirmed")
    elseif typeof(module) == "Instance" and module.Parent.Name == "LightAttack" and subject == player.Character and type(details) == "table" then
        local warning = warnings[details.Attacker]
        if warning then
            local elapsed = os.clock() - warning.time
            if elapsed >= 0.1 and elapsed <= 1.2 then attackTimings[warning.key] = elapsed end
            warnings[details.Attacker] = nil
        end
    end
end))
local function mouseButton(down, x, y)
    if down == forgeMouseDown then return end
    virtual("SendMouseButtonEvent", math.floor(x or 1), math.floor(y or 1), 0, down, game, 0)
    forgeMouseDown = down
end
releaseForge = function()
    forgeEpoch += 1
    if forgeMouseDown then pcall(mouseButton, false) end
    if forgeHook and forgeHook.CreateNote == forgeOriginal.wrapper then forgeHook.CreateNote = forgeOriginal.original end
    forgeHook, forgeOriginal = nil, nil
end
local function assistForge()
    releaseBlock()
    assert(type(firesignal) == "function" and type(fireclickdetector) == "function", "Forge helper: firesignal/fireclickdetector unavailable")
    local forgeGui = UI.PlayerGui.Forge
    local hammer = FC.Minigames and FC.Minigames.HammerMinigame
    assert(hammer and type(hammer.CreateNote) == "function", "Hammer minigame unavailable")
    assert(FC.ItemType ~= "Golem", "Forge helper supports weapons and armor")
    local previousItems = {}
    for _, item in ipairs(data().Inventory.Equipments or {}) do if item.GUID then previousItems[item.GUID] = true end end
    local epoch = forgeEpoch
    local function assisting() return not destroyed and forgeEpoch == epoch end
    forgeHook = hammer
    local original = hammer.CreateNote
    local wrapper
    wrapper = function(self, parameters, ...)
        if not assisting() then return original(self, parameters, ...) end
        local born = workspace:GetServerTimeNow()
        local captured = false
        local connection = forgeGui.HammerMinigame.ChildAdded:Connect(function(button)
            if captured or not button:IsA("GuiButton") then return end
            captured = true
            task.delay(math.max(0, parameters.Lifetime * 25 / 44 - (workspace:GetServerTimeNow() - born)), function()
                if assisting() and button.Parent then firesignal(button.MouseButton1Click) end
            end)
        end)
        local results = table.pack(pcall(original, self, parameters, ...))
        connection:Disconnect()
        if not results[1] then error(results[2]) end
        return table.unpack(results, 2, results.n)
    end
    forgeOriginal = {wrapper = wrapper, original = original}
    hammer.CreateNote = wrapper
    forgeStarted = os.clock()
    local lastMoldClick, meltPress = 0, false
    while assisting() and FC.ForgeActive do
        if os.clock() - forgeStarted > 180 then error("Forging exceeded 180 seconds; check manually") end
        local melt, pour = forgeGui.MeltMinigame, forgeGui.PourMinigame
        if melt.Visible then
            local heater = melt.Heater
            if not meltPress then firesignal(heater.Top.MouseButton1Down); meltPress = true end
            local fraction = math.floor(os.clock() * 8) % 2 == 0 and 0 or 1
            virtual("SendMouseMoveEvent", math.floor(heater.AbsolutePosition.X + heater.AbsoluteSize.X / 2),
                math.floor(heater.AbsolutePosition.Y + heater.AbsoluteSize.Y * fraction), game)
            log("Forging: smelting automatically")
        elseif pour.Visible then
            local frame = pour.Frame
            local middle = frame.Area.Position.Y.Scale + frame.Area.Size.Y.Scale / 2
            mouseButton(frame.Line.Position.Y.Scale > middle, frame.AbsolutePosition.X + frame.AbsoluteSize.X / 2, frame.AbsolutePosition.Y + frame.AbsoluteSize.Y / 2)
            log("Forging: following pour line")
        elseif forgeGui.HammerMinigame.Visible then
            mouseButton(false)
            local mold = workspace.Debris:FindFirstChild("Mold")
            if mold and mold:FindFirstChild("ClickDetector") and not mold:GetAttribute("IsDestroyed") and os.clock() - lastMoldClick > 0.4 then
                fireclickdetector(mold.ClickDetector)
                lastMoldClick = os.clock()
            end
            log("Forging: timing hammer strikes")
        elseif FC.Sequence == "Showcase" then
            mouseButton(false)
            for _, item in ipairs(data().Inventory.Equipments or {}) do
                if item.GUID and not previousItems[item.GUID] and (not api.LastCraft or api.LastCraft.guid ~= item.GUID) then
                    api.LastCraft = {guid = item.GUID, itemType = item.Type, quality = item.Quality}
                    print(string.format("[ForgeHelper] Server result: %s | Quality %.2f%%", tostring(item.Type), item.Quality or 0))
                end
            end
            local button = forgeGui.EndScreen:FindFirstChild("AcceptButton", true)
            if button and button.Visible then firesignal(button.Activated) end
            log("Forging: keeping result; checking server quality")
        elseif FC.Sequence == "OreSelect" and os.clock() - forgeStarted > 2 then
            releaseForge()
            return
        end
        task.wait(0.035)
    end
    releaseForge()
end
-- plan: {itemType, recipe, count, lockClass?, goal?}; ohne Angabe der automatisch geplante Bau (build).
local function craft(token, plan)
    plan = plan or build
    local forgeStation, prompt = station()
    if not (forgeStation and prompt and plan) or not (plan.goal or api.AutoForge) then return false end
    if not Planner.recipeFitsForge(plan.recipe) then return false end
    if not approach(prompt, token) then return false end
    local _, questReserve = Planner.pending(data(), Definitions, Ores, Rocks)
    if not Planner.availableRecipe(plan.recipe, data().Inventory, questReserve) or not alive(token) then return false end
    local mouse = game:GetService("UserInputService"):GetMouseLocation()
    virtual("SendMouseMoveEvent", math.floor(mouse.X), math.floor(mouse.Y), game)
    assert(type(firesignal) == "function" and type(fireclickdetector) == "function", "Forge helper unavailable in this executor")
    log("Opening forge for " .. tostring(plan.lockClass or plan.itemType))
    await(ProximityService:Forge(prompt))
    local start = os.clock()
    while alive(token) and not (FC.ForgeActive and FC.Sequence == "OreSelect" and FC.Minigames) and os.clock() - start < 10 do task.wait(0.1) end
    if not alive(token) or not FC.ForgeActive or FC.Sequence ~= "OreSelect" then return false end
    task.wait(0.7)
    if not (plan.goal or api.AutoForge) or not Planner.availableRecipe(plan.recipe, data().Inventory, questReserve) then return false end
    UI.Modules.Forge:SelectItemType(Equipment:GetItemType(plan.itemType))
    UI.Modules.Forge:ClearMolds()
    assert(not next(UI.Modules.Forge.addedOres), "Forge already contains a manual ore selection")
    for name, count in pairs(plan.recipe) do for _ = 1, count do UI.Modules.Forge:AddOre(name) end end
    assert(recipeCount(UI.Modules.Forge.addedOres) == plan.count, "Ore selection was not fully applied")
    if plan.lockClass then
        -- Klassen-Sperre wie der Schloss-Knopf im Schmiede-Menue: ab lock_min_ores Erzen 100 % diese Klasse.
        UI.Modules.Forge.LockedClass = plan.lockClass
        pcall(UI.Modules.Forge.UpdateProbabilities, UI.Modules.Forge)
    end
    FC.Ores, FC.ItemType = table.clone(UI.Modules.Forge.addedOres), Equipment:GetItemType(plan.itemType)
    FC:ChangeSequence("Melt")
    assistForge()
    if FC.ForgeActive and FC.Sequence == "OreSelect" then UI.Modules.Forge:Close() end
    return true
end

local function equipUpgrade(token)
    local baseline = metrics(data().Equipped)
    local best, score = nil, buildScore(baseline)
    for _, item in ipairs(data().Inventory.Equipments or {}) do
        local slot = slotOf(item)
        if slot and item ~= data().Equipped[slot] then
            local loadout = table.clone(data().Equipped)
            loadout[slot] = item
            local vector = metrics(loadout)
            if Planner.dominates(vector, baseline) and buildScore(vector) >= score then best, score = item, buildScore(vector) end
        end
    end
    if best and alive(token) and api.AutoEquip then
        destination = nil
        log("Equipping upgrade: " .. tostring(best.Type or best.Name))
        await(CharacterService:EquipItem(best))
        task.wait(0.4)
        return true
    end
    return false
end

local function questDialogue(npc, job, token)
    if not talk(npc, token) then return false end
    -- Oeffnen fuehrt die nativen CheckQuest/FinishQuest-Bedingungen des NPCs aus.
    task.wait(0.7)
    local quest = data().Quests[job.quest]
    -- Abgabe/Abschluss wie der Klick auf "I brought what you asked for." / "It's done.": den FinishQuest-Knoten
    -- im Dialogbaum dieses NPCs ausfuehren (der Baum ist der, in dem auch die Quest vergeben wird).
    if quest and (job.turnIn or job.bring) and api.QuestTools then
        local giver = api.QuestTools.givers()[job.quest]
        local finish = giver and giver.Parent and giver.Parent:FindFirstChild("FinishQuest")
        local module = finish and finish:FindFirstChildWhichIsA("ModuleScript")
        if module and alive(token) then
            local ok, node = pcall(require, module)
            if ok and type(node) == "table" and type(node.Run) == "function" then
                pcall(node.Run)
                task.wait(0.5)
                return true
            end
        end
    end
    if quest and job.turnIn then
        local suffix = job.quest:match("Quest(%d+)$")
        local known = npc.Name == "Captain Rowan" and suffix and "FinishQuest" .. suffix or "FinishQuest"
        local folderName = ({["Captain Rowan"] = "CaptainRowan", Nord = "Mining", UmutTheBrave = "Zombie"})[npc.Name] or npc.Name:gsub(" ", "")
        local folder = ReplicatedStorage.Dialogues:FindFirstChild(folderName)
        local valid = false
        if folder then
            for _, module in ipairs(folder:GetDescendants()) do
                if module:IsA("ModuleScript") and module.Name == "Condition" and module.Parent.Name == "FinishQuest" then valid = true end
            end
        end
        if valid and alive(token) then await(DialogueService:RunCommand(known)) end
    end
    return true
end

-- QUEST_TOOLS_START
-- Quests annehmen: im Dialogbaum des NPCs gibt es einen Befehls-Knoten mit Attribut GivesQuest = Quest-ID;
-- dessen Modul ruft DialogueService:RunCommand("Give...") auf (wie beim Klick im Dialog). Erledigte Quests stehen
-- in Data.CompletedQuests, Voraussetzungen in Quests[id].Prerequisites.
-- Fundstuecke: Pickups {Name = Proximity-Modell, Flag = Data.MiscDialogues-Flagge}, eingesammelt ueber
-- ProximityService:Functionals(Modell) (wie der Interact-Knopf).
-- Versuchs-Merker ueberleben ein Neuladen des Scripts (in getgenv), damit nicht jeder START dieselben Wege fliegt
env.ForgeHelperMemory = env.ForgeHelperMemory or {acceptTried = {}, acceptFails = {}, talkTries = {}}
local questTools = {acceptTried = env.ForgeHelperMemory.acceptTried, acceptFails = env.ForgeHelperMemory.acceptFails,
    lastAcceptScan = 0, pickupTried = {}, talkTries = env.ForgeHelperMemory.talkTries}
api.QuestTools = questTools -- questDialogue (weiter oben definiert) braucht die Dialog-Knoten
do
    local giverNodes
    function questTools.givers()
        if not giverNodes then
            giverNodes = {}
            for _, node in ipairs(ReplicatedStorage.Dialogues:GetDescendants()) do
                local id = node:IsA("Configuration") and node:GetAttribute("GivesQuest")
                if type(id) == "string" and node:FindFirstChildWhichIsA("ModuleScript") and not giverNodes[id] then giverNodes[id] = node end
            end
        end
        return giverNodes
    end
    -- Quests, die man hier gerade annehmen kann (NPC geladen, noch nicht aktiv/erledigt, Voraussetzungen erfuellt)
    function questTools.available()
        local d, list = data(), {}
        local completed = d.CompletedQuests or {}
        -- NPCs, die gerade schon eine Quest von uns laufen haben (ein NPC gibt immer nur eine Quest gleichzeitig)
        local busyNpc = {}
        for activeId in pairs(d.Quests or {}) do
            local activeDef = Definitions[activeId]
            if type(activeDef) == "table" and activeDef.Npc then busyNpc[activeDef.Npc] = true end
        end
        for id, node in pairs(questTools.givers()) do
            local def = Definitions[id]
            if type(def) == "table" and not (d.Quests or {})[id] and not completed[id] and not busyNpc[def.Npc] then
                local ready = true
                for _, previous in ipairs(def.Prerequisites or {}) do if not completed[previous] then ready = false; break end end
                -- Quest-Ketten ohne eingetragene Voraussetzung: "HazelQuest2" erst, wenn "HazelQuest1" erledigt ist
                local prefix, number = id:match("^(.-)(%d+)$")
                number = tonumber(number)
                if ready and prefix and number and number > 1 then
                    local previousId = prefix .. tostring(number - 1)
                    if Definitions[previousId] and not completed[previousId] then ready = false end
                end
                local npc = ready and npcAt(def.Npc)
                if npc then table.insert(list, {id = id, node = node, npc = npc, name = def.Name or id}) end
            end
        end
        -- bevorzugte zuerst, dann nach Name
        table.sort(list, function(a, b)
            local pa, pb = api.PreferredQuests[a.id] == true, api.PreferredQuests[b.id] == true
            if pa ~= pb then return pa end
            return tostring(a.name) < tostring(b.name)
        end)
        return list
    end
    function questTools.accept(token)
        if not api.AutoAcceptQuests or os.clock() - questTools.lastAcceptScan < 20 then return false end
        questTools.lastAcceptScan = os.clock()
        for _, entry in ipairs(questTools.available()) do
            if (questTools.acceptTried[entry.id] or 0) < os.clock() then
                -- Klappt das Annehmen nicht (z. B. Level zu niedrig), wird die Pause jedes Mal laenger: 10 min, 1 h, 2 h ...
                questTools.acceptFails = questTools.acceptFails or {}
                local fails = questTools.acceptFails[entry.id] or 0
                questTools.acceptTried[entry.id] = os.clock() + (fails == 0 and 600 or math.min(7200, 3600 * fails))
                log("Accepting quest: " .. tostring(entry.name))
                if talk(entry.npc, token) then
                    task.wait(0.6)
                    local ok, module = pcall(require, entry.node:FindFirstChildWhichIsA("ModuleScript"))
                    if ok and type(module) == "table" and type(module.Run) == "function" then pcall(module.Run) end
                    task.wait(1)
                end
                if data().Quests[entry.id] then
                    questTools.acceptFails[entry.id] = nil
                    log("Quest accepted: " .. tostring(entry.name))
                else
                    questTools.acceptFails[entry.id] = fails + 1
                end
                lastPlan = 0
                return true
            end
        end
        return false
    end
    -- Fundstueck-Quest: naechstes noch nicht genommenes Pickup auf dieser Insel einsammeln
    function questTools.pickup(job, token)
        local flags = data().MiscDialogues or {}
        for _, pickup in ipairs(job.pickups or {}) do
            local model = type(pickup) == "table" and workspace.Proximity:FindFirstChild(tostring(pickup.Name))
            if model and not flags[pickup.Flag] and (questTools.pickupTried[pickup.Name] or 0) < os.clock() then
                questTools.pickupTried[pickup.Name] = os.clock() + 45
                log("Quest item: collecting " .. pickup.Name)
                if approach(model, token) then
                    task.wait(0.3)
                    await(ProximityService:Functionals(model))
                    task.wait(0.5)
                end
                lastPlan = 0
                return true
            end
        end
        return false
    end
    -- Respawn-Hilfe: Gibt es die Quest-Steinart gerade nicht (z. B. Icy Boulder), andere Steine in den Gebieten
    -- abbauen, in denen sie spawnt. Jedes Gebiet (workspace.Rocks.<Gebiet>.<SpawnLocation>.<Stein>) hat mehr
    -- Spawn-Punkte als Steine; ein abgebauter Stein macht Platz und dort spawnt eine Steinart des Gebiets nach.
    -- Welche Art wo spawnt, weiss nur der Server -> gemerkt wird, wo eine Art schon einmal stand (ueberlebt Neuladen).
    env.ForgeRockAreas = env.ForgeRockAreas or {}
    local rockAreas, areaScanAt = env.ForgeRockAreas, -math.huge
    function questTools.respawnJob(jobs, sameFamily)
        local folder = workspace:FindFirstChild("Rocks")
        if not folder then return nil end
        if os.clock() - areaScanAt > 10 then
            areaScanAt = os.clock()
            for _, area in ipairs(folder:GetChildren()) do
                for _, entry in ipairs(Caves[area.Name] and Caves[area.Name].Rocks or {}) do
                    if Rocks[entry.Name] then
                        rockAreas[entry.Name] = rockAreas[entry.Name] or {}
                        rockAreas[entry.Name][area.Name] = true
                    end
                end
                for _, spawn in ipairs(area:GetChildren()) do
                    for _, rock in ipairs(spawn:GetChildren()) do
                        if Rocks[rock.Name] then
                            rockAreas[rock.Name] = rockAreas[rock.Name] or {}
                            rockAreas[rock.Name][area.Name] = true
                        end
                    end
                end
            end
        end
        local pickaxe = data().Equipped.Pickaxe
        local power = pickaxe and Equipment:CalculatePickaxeDamage(pickaxe) or 0
        local job, names = {kind = "Respawn", areas = {}, family = {}, sameFamily = sameFamily}, {}
        for _, quest in ipairs(jobs) do
            if quest.kind == "Mine" or quest.kind == "Ore" then
                for name, rock in pairs(Rocks) do
                    local wanted = (quest.kind == "Mine" and name == quest.target) or (quest.kind == "Ore" and table.find(rock.Ores or {}, quest.target) ~= nil)
                    -- Steine, die die Spitzhacke nicht schafft, bringen nichts -> nicht dafuer Platz machen
                    if wanted and Planner.canMine(rock, power, pickaxe and pickaxe.Name) then
                        if rockAreas[name] and next(rockAreas[name]) then
                            local family = sameFamily and Planner.rockFamily(name)
                            if not sameFamily or family then
                                for area in pairs(rockAreas[name]) do
                                    if family then
                                        job.areas[area] = job.areas[area] or {}
                                        job.areas[area][family] = true
                                    else
                                        job.areas[area] = true
                                    end
                                end
                                names[quest.target] = true
                            end
                        elseif not sameFamily and quest.kind == "Mine" then
                            -- ponytail: noch nie gesehen -> Steine derselben Familie ("Icy Boulder" -> "Icy ..."), grob, aber selten noetig
                            job.family[name:match("^(%S+)%s") or name] = true
                            names[quest.target] = true
                        end
                    end
                end
            end
        end
        if not next(names) then return nil end
        local list = {}
        for name in pairs(names) do table.insert(list, name) end
        table.sort(list)
        job.target = table.concat(list, "/")
        job.label = "Making room for " .. table.concat(list, " / ") .. " to respawn: "
        return job
    end
    -- Mob-Respawn-Hilfe, genau wie bei Steinen: Jedes Spawn-Gebiet (workspace.Debris.MobSpawns.<Gebiet>, Attribut
    -- "Enemies" = Arten des Gebiets, Kinder = SpawnLocation-Teile) hat nur begrenzt Platz. Toetet der Bot nur die
    -- Quest-Art, fuellt sich das Gebiet mit den anderen Arten und die Quest-Art spawnt nie mehr nach
    -- (live gesehen: I4_HolyCave_01 voller Brute Oni, kein Frostburn Oni). Gibt es die Quest-Art gerade nicht,
    -- werden die ANDEREN Arten in genau diesen Gebieten getoetet, bis sie wieder auftaucht.
    function questTools.mobRespawnJob(jobs)
        local spawns = workspace:FindFirstChild("Debris") and workspace.Debris:FindFirstChild("MobSpawns")
        if not spawns then return nil end
        local job, names = {kind = "Kill", fillers = {}, points = {}, radius = 60}, {}
        for _, quest in ipairs(jobs) do
            -- Mutationen ("Mutation:Hell") und Bosse haben kein festes Spawn-Gebiet
            if quest.kind == "Kill" and type(quest.target) == "string" and not quest.target:find("^Mutation:") then
                for _, area in ipairs(spawns:GetChildren()) do
                    local others, hasTarget = {}, false
                    for name in tostring(area:GetAttribute("Enemies") or ""):gmatch("[^,]+") do
                        name = name:match("^%s*(.-)%s*$")
                        if name == quest.target then hasTarget = true elseif name ~= "" then table.insert(others, name) end
                    end
                    if hasTarget and #others > 0 then
                        names[quest.target] = true
                        for _, name in ipairs(others) do job.fillers[name] = true end
                        for _, point in ipairs(area:GetChildren()) do
                            if point:IsA("BasePart") then table.insert(job.points, point.Position) end
                        end
                    end
                end
            end
        end
        if not next(names) then return nil end
        for name in pairs(names) do job.fillers[name] = nil end -- Quest-Arten nimmt schon der normale Quest-Job
        if not next(job.fillers) then return nil end
        local list = {}
        for name in pairs(names) do table.insert(list, name) end
        table.sort(list)
        job.target = "respawn:" .. table.concat(list, "/")
        job.label = "Making room for " .. table.concat(list, " / ") .. " to respawn: "
        return job
    end
end
-- QUEST_TOOLS_END

-- CELESTIAL_CLASH_START
-- Regeln aus Shared.Data.Events.TwilightWar (live ausgelesen): Die Front verschiebt sich pro
--   Kristall +1 %, Altar-Waechter +0,5 %, gehaltenem Altar +0,5 %/min, Mob-Kill +0,15 %.
-- Reihenfolge: 1) Stein-Rennen am Altar (eigene Seite), 2) Altaere/Arenen, die nicht uns gehoeren
--   (erst Waechter toeten, dann im Kreis stehen), 3) Kristalle der eigenen Seite, 4) Mobs toeten.
-- Ausserhalb des Events (oder ohne gewaehlte Seite) laeuft der normale Farm-Modus weiter.
local clashStep
do
    local okConfig, TwilightWar = pcall(require, Shared.Data.Events.TwilightWar)
    if not okConfig or type(TwilightWar) ~= "table" then TwilightWar = {} end
    local Clash = TwilightWar.Clash or {}
    local crystalList, crystalListAt = {}, 0
    local function clashState() return ReplicatedStorage:FindFirstChild("ClashState") end
    api.ClashLive = function()
        local state = clashState()
        return state ~= nil and state:GetAttribute("Live") == true
    end
    api.ClashNextIn = function()
        local state = clashState()
        local nextAt = state and state:GetAttribute("NextAt")
        return finite(nextAt) and math.max(0, nextAt - os.time()) or nil
    end
    local function crystals()
        if os.clock() - crystalListAt > 2 then
            crystalListAt = os.clock()
            table.clear(crystalList)
            for _, object in ipairs(workspace.Rocks:GetDescendants()) do
                if object.Name == "ClashCrystal" and object:IsA("Model") then table.insert(crystalList, object) end
            end
        end
        return crystalList
    end
    local function nearest(list, valid)
        local best, bestDistance = nil, math.huge
        for _, item in ipairs(list) do
            if valid(item) then
                local distance = (item:GetPivot().Position - root.Position).Magnitude
                if distance < bestDistance then best, bestDistance = item, distance end
            end
        end
        return best
    end
    local function focus(target, label)
        -- Ziel fuer Target-ESP, Fluglinie, Statistik und "kein Fortschritt"-Erkennung setzen
        if activeTarget ~= target then
            activeTarget, activeJob = target, "Clash:" .. label
            targetHealth, targetTime = healthOf(target, "Mine"), os.clock()
            rangeMisses, lastRangeAdjust = 0, os.clock()
        end
    end
    clashStep = function(token)
        if not api.ClashLive() then return false end
        local side = player:GetAttribute("TwilightSide")
        if type(side) ~= "string" or not (TwilightWar.Sides and TwilightWar.Sides[side]) then
            log("Clash Focus: pick a side on the Events page first")
            return false
        end
        if Clash.Islands and currentWorld and not Clash.Islands[currentWorld] then
            log("Clash Focus: no Celestial Clash on this island (islands 2-4)")
            return false
        end
        -- 1) Stein-Rennen: "Altar contested! Mine your side's stone to take it."
        local stones = workspace.Rocks:FindFirstChild("ClashStones")
        if stones then
            local holder = nearest(stones:GetChildren(), function(item)
                local stone = item:FindFirstChild("ClashStone")
                return stone ~= nil and stone:GetAttribute("Side") == side and (stone:GetAttribute("Health") or 0) > 0 and not isBlocked(item)
            end)
            local stone = holder and holder:FindFirstChild("ClashStone")
            -- ponytail: Aufbau der Rennsteine noch nicht live gesehen; abgebaut wird das Teil mit direktem "Hitbox"-Kind.
            local mineTarget = holder and (holder:FindFirstChild("Hitbox") and holder or stone and stone:FindFirstChild("Hitbox") and stone)
            if mineTarget then
                focus(mineTarget, "stone")
                attack(mineTarget, {kind = "ClashMine", label = "Clash stone race: "}, token)
                return true
            end
        end
        -- 2) Altaere/Arenen, die nicht uns gehoeren: zuerst einnehmen (Waechter toeten, dann im Kreis stehen)
        local altar = nearest(CollectionService:GetTagged(Clash.ShrineTag or "ClashShrine"), function(item)
            return item:IsDescendantOf(workspace) and item:GetAttribute("Owner") ~= side and accessible(item:GetPivot().Position)
        end)
        if altar then
            local center = altar:GetPivot().Position
            local altarName = tostring(altar:GetAttribute("ShrineName") or altar.Name)
            if (altar:GetAttribute("Guardians") or 0) > 0 then
                local job = {kind = "Kill", all = true, center = center, radius = (Clash.Guardians and Clash.Guardians.Spread or 10) + 25,
                    target = "guardians:" .. altar.Name, label = "Clash guardians (" .. altarName .. "): "}
                local guardian = findTarget(job)
                if guardian then attack(guardian, job, token); return true end
            end
            -- "Stand inside to turn it to your side." (Radius 18): auf dem Boden mitten im Kreis stehen
            if stopMiningInput then stopMiningInput() end
            followAttack, activeTarget, activeJob = nil, nil, nil
            -- Boden direkt am Altar-Punkt suchen (Strahl knapp darueber starten): bei 12 Studs Abstand traf der Strahl
            -- das Arena-Dach, der Einnahme-Punkt liegt aber darunter.
            local floor = surfaceAt(center, 2)
            destination = CFrame.new((floor or center) + Vector3.new(0, humanoid.HipHeight + root.Size.Y / 2 + 0.5, 0))
            log(string.format("Clash: capturing %s (control %s)", altarName, tostring(altar:GetAttribute("Control") or 0)))
            return true
        end
        -- 3) Kristalle der eigenen Seite (+1 % Front pro Kristall)
        local crystal = nearest(crystals(), function(item)
            return item.Parent ~= nil and item:GetAttribute("Side") == side and (item:GetAttribute("Health") or 0) > 0
                and item:FindFirstChild("Hitbox") ~= nil and not isBlocked(item) and accessible(item:GetPivot().Position)
        end)
        if crystal then
            focus(crystal, "crystal")
            attack(crystal, {kind = "ClashMine", label = "Clash crystal: "}, token)
            return true
        end
        -- 4) Alles gehoert uns, keine Kristalle: Mobs toeten (+0,15 % pro Kill)
        local job = {kind = "Kill", all = true, target = "clash", label = "Clash kills: "}
        local mob = findTarget(job)
        if mob then
            attack(mob, job, token)
        else
            if stopMiningInput then stopMiningInput() end
            destination = nil
            log("Clash: your side holds every altar; waiting for crystals or mobs")
        end
        return true
    end
end
-- CELESTIAL_CLASH_END

-- FORGE_GOAL_START
-- Ziel: z. B. "Katana mit 250 Schaden" oder "Heavy Chestplate mit 900 Leben". Rechnung wie im Spiel (live geprueft,
--   stimmt mit theforge.gg ueberein): Schaden/Leben wachsen linear mit dem Durchschnitts-Multiplikator der Erze
--   (nach Anzahl gewichtet) und mit (1 + Qualitaet/100). Mit lock_min_ores Erzen wird die Klasse gesperrt (100 %),
--   die Variante darin ist Zufall -> geplant wird fuer die SCHWAECHSTE Variante, damit das Ziel sicher erreicht wird.
-- Rezept: 1 oder 2 Erzsorten aus Inventar (ohne Favoriten/Quest-Bedarf) und auf dieser Insel abbaubaren Erzen,
--   so dass moeglichst wenig gefarmt werden muss. Traits werden nicht eingerechnet (koennen nur mehr DPS geben).
local forgeGoal = {plan = nil, attempts = 0, lastPlanAt = 0, result = nil}
api.ForgeGoal = forgeGoal
do
    -- Erz-Crafting des Spiels (Shared.CraftCatalog / OreCraftService, live geprueft):
    -- an der Craft-Station StartCrafting(Station) -> CraftRequest(Erz, Anzahl); fertig nach Anzahl x CraftTime,
    -- das Spiel holt fertige Erze alle 3 s selbst ins Inventar (CheckCraftCompletions).
    local okCatalog, CraftCatalog = pcall(require, Shared.CraftCatalog)
    if not okCatalog then CraftCatalog = nil end
    local function formatDuration(seconds)
        seconds = math.max(0, math.floor(seconds or 0))
        if seconds >= 3600 then return string.format("%dh %02dm", seconds // 3600, (seconds % 3600) // 60) end
        if seconds >= 60 then return string.format("%dm %02ds", seconds // 60, seconds % 60) end
        return seconds .. "s"
    end
    local function thousands(n)
        return (tostring(math.floor((n or 0) + 0.5)):reverse():gsub("(%d%d%d)", "%1."):reverse():gsub("^%.", ""))
    end
    forgeGoal.formatDuration = formatDuration
    local OreCraftService = Knit.GetService("OreCraftService")
    -- nutzbarer Bestand: ohne Favoriten und ohne Quest-Bedarf (die werden nie verschmiedet/vercraftet)
    local questReserveCache, questReserveAt = {}, 0
    function forgeGoal.usable(itemName)
        if os.clock() - questReserveAt > 2 then
            local _, reserve = Planner.pending(data(), Definitions, Ores, Rocks)
            questReserveCache, questReserveAt = reserve, os.clock()
        end
        if not api.GoalUseFavorites and (data().Favorites or {})[itemName] then return 0 end
        local amount = data().Inventory[itemName]
        return type(amount) == "number" and math.max(0, math.floor(amount - (questReserveCache[itemName] or 0))) or 0
    end
    local function stationName()
        local forgeStation = station()
        return forgeStation and Rarity:ResolveStation(forgeStation.Name, data())
    end
    -- Werte exakt wie das Spiel (Shared.Data.Equipments, live geprueft):
    --   Multiplikator = Durchschnitt der Erz-Multiplikatoren (nach Anzahl gewichtet; "neutrale" Erze wie Bismuth zaehlen
    --                   nur, wenn ausschliesslich neutrale Erze drin sind) x (1 + Qualitaet / 100)
    --   Schaden  = Grundschaden der Klasse x DamageMultiplier der Variante x Multiplikator   (= "DMG" auf theforge.gg)
    --   DPS      = Schaden x AttackSpeedMultiplier der Variante / mittlere Angriffszeit der Klasse
    --   Leben    = Grundleben der Ruestung x Multiplikator
    local function itemDamage(item)
        local ok, flat, final = pcall(Equipment.CalculateDamage, Equipment, item)
        if not ok then return nil end
        local damage = finite(final) and final or flat
        return finite(damage) and damage or nil
    end
    local function itemDps(item)
        local damage = itemDamage(item)
        local okSpeed, speed = pcall(Equipment.CalculateAttackSpeed, Equipment, nil, item)
        local okTime, baseTime = pcall(Equipment.GetBaseAttackTime, Equipment, Equipment:GetItemBaseType(item.Type))
        if not (damage and okSpeed and okTime) or not finite(speed) or not finite(baseTime) or baseTime <= 0 then return nil end
        return damage * speed / baseTime
    end
    local function itemHealth(item)
        local ok, flat, final = pcall(Equipment.CalculateHealth, Equipment, item)
        if not ok then return nil end
        local health = finite(final) and final or flat
        return finite(health) and health or nil
    end
    forgeGoal.itemDps, forgeGoal.itemDamage, forgeGoal.itemHealth = itemDps, itemDamage, itemHealth
    local metricUnits = {Damage = "damage", DPS = "DPS", Health = "health"}
    local function metricValue(item, metric)
        if metric == "Health" then return itemHealth(item) end
        if metric == "DPS" then return itemDps(item) end
        return itemDamage(item)
    end
    forgeGoal.metricValue = metricValue
    local armorClasses = {}
    for _, config in ipairs(Rarity.Armor or {}) do armorClasses[config.name] = true end
    local function classKind(className) return armorClasses[className] and "Armor" or "Weapon" end
    local function prettyClass(className)
        if className == "SwordShield" then return "Sword & Shield" end
        return (tostring(className):gsub("(%l)(%u)", "%1 %2"))
    end
    -- Ruestungen werden immer nach Leben geplant, Waffen nach der gewaehlten Kennzahl (Schaden oder DPS).
    local function goalMetric(className) return classKind(className) == "Armor" and "Health" or api.GoalMetric end
    forgeGoal.classKind, forgeGoal.prettyClass, forgeGoal.goalMetric = classKind, prettyClass, goalMetric
    local function formatValue(value, metric)
        if not finite(value) then return "?" end
        -- Schaden mit 2 Nachkommastellen wie theforge.gg, DPS und Leben gerundet
        if metric == "Damage" then return string.format("%.2f", value) end
        return tostring(math.floor(value + 0.5))
    end
    forgeGoal.formatValue = formatValue
    local function isNeutral(oreName) return Ores[oreName] and Ores[oreName].NeutralMultiplier == true end
    -- Spielmodule (ItemRarity) duerfen nur mit Client-Identitaet 2 geladen werden; Menue-Callbacks laufen mit 8.
    local function asClient(fn, ...)
        local getIdentity = getthreadidentity or getidentity
        local previous = type(getIdentity) == "function" and getIdentity() or nil
        if type(setIdentity) == "function" then setIdentity(2) end
        local results = table.pack(pcall(fn, ...))
        if previous and type(setIdentity) == "function" then setIdentity(previous) end
        if not results[1] then error(results[2], 0) end
        return table.unpack(results, 2, results.n)
    end
    forgeGoal.asClient = asClient
    -- ALLE FREIGESCHALTETEN INSELN: Heimat-Insel jedes Erzes steht in der Ordnerstruktur Shared.Data.Ore."Island N".
    -- Auch Unterordner zaehlen (live: "Island 4/Spirit" mit Yin, Yang, Seedheart ..., "Island 3/Raven", "Island 3/Heart");
    -- vorher wurden nur direkte Kinder gelesen -> diese Erze galten auf anderen Inseln als unerreichbar.
    -- Event-Erze ("Events": Candy Ore, Pumpkinite, Verdantite) und Raid-Erze ("Raid" = Tower of Hell: Bizzarite, Echotite,
    -- Frost Core, Frost Star, Tetrinite) gibt es nicht dauerhaft -> nie zum Abbauen/Craften einplanen.
    local oreHome, eventOres = {}, {}
    for _, folder in ipairs(Shared.Data.Ore:GetChildren()) do
        local index = tonumber(folder.Name:match("^Island (%d+)$"))
        local isEvent = folder.Name == "Events" or folder.Name == "Raid"
        for _, module in ipairs(folder:GetDescendants()) do
            if module:IsA("ModuleScript") then
                if index then oreHome[module.Name] = index end
                if isEvent then eventOres[module.Name] = true end
            end
        end
    end
    forgeGoal.eventOres = eventOres
    local function unlockedIslands()
        local set, list = {}, {}
        for index, island in pairs(Islands.Data) do
            local ok, meets = pcall(Islands.MeetsRequirements, island.Name, data())
            if (ok and meets) or index == currentWorld then set[index] = true; table.insert(list, index) end
        end
        table.sort(list)
        return set, list
    end
    forgeGoal.unlockedIslands = unlockedIslands
    -- Schmiede einer Insel (Name wie Rarity:ResolveStation, z. B. "Island4")
    local function forgeStationFor(island)
        if island == currentWorld then return stationName() end
        return "Island" .. tostring(island)
    end
    local function classAt(island, className)
        local name = forgeStationFor(island)
        return name and #Rarity:GetAvailableItems(name, classKind(className), className, data()) > 0
    end
    -- Insel zum Schmieden: die aktuelle, wenn ihre Schmiede die Klasse hat, sonst die erste freigeschaltete mit der Klasse
    local function forgeIslandFor(className)
        if currentWorld and classAt(currentWorld, className) then return currentWorld end
        local _, list = unlockedIslands()
        -- hoehere Inseln zuerst: dort gibt es meist mehr/bessere Varianten und man muss fuer Erze ohnehin oft hin
        for index = #list, 1, -1 do if classAt(list[index], className) then return list[index] end end
        return nil
    end
    local function classesRaw()
        -- Waffen- und Ruestungsklassen (Helm, Hose, Brustplatte jeweils Light/Medium/Heavy), die irgendeine
        -- freigeschaltete Schmiede herstellen kann
        local list = {}
        for _, kind in ipairs({"Weapon", "Armor"}) do
            for _, config in ipairs(Rarity[kind] or {}) do
                local cfg = Rarity:GetItemDataConfig(config.name) or {}
                local island = cfg.lock_min_ores and forgeIslandFor(config.name)
                if island then
                    table.insert(list, {name = config.name, label = prettyClass(config.name), kind = kind, lock = cfg.lock_min_ores,
                        island = island, here = island == currentWorld})
                end
            end
        end
        return list
    end
    function forgeGoal.classes() return asClient(classesRaw) end

    local function craftLock(group)
        if not CraftCatalog or type(group) ~= "table" or type(group.Station) ~= "string" then
            return "Could not verify access to this crafting station."
        end
        local ok, locked = pcall(CraftCatalog.Lock, group, data(), nil)
        if not ok then return "Could not verify access to " .. group.Station end
        if not locked then return nil end
        if group.Station == "Galaxy Guardian" then
            return "Finish Silas's questline through Restless Dead and use the Dynamite Key to open the Void Cave."
        end
        return group.Station .. " crafting is locked."
    end

    -- Was ist erreichbar? Inventar (ohne Favoriten/Quest-Bedarf), mit dieser Spitzhacke auf freigeschalteten Inseln
    -- abbaubar oder an einer Craft-Station craftbar. Event-/Raid-Erze (Tower of Hell usw.) werden nie abgebaut/gecraftet.
    -- evaluate(rezept) -> Plan mit Abbau-, Craft- und Reise-Schritten oder nil, wenn das Rezept nicht machbar ist.
    function forgeGoal.context()
        -- Erreichbar ist ein Erz, wenn es im Inventar liegt (ohne Favoriten/Quest-Bedarf), auf dieser Insel abbaubar ist
        -- oder an einer Craft-Station dieser Insel gecraftet werden kann. Der Rezeptbaum wird bis zu abbaubaren Erzen
        -- aufgeloest (wie theforge.gg/crafting), Gold und Craft-Zeit werden mitgerechnet.
        local pickaxe = data().Equipped.Pickaxe
        local power = pickaxe and Equipment:CalculatePickaxeDamage(pickaxe) or 0
        local unlocked = unlockedIslands()
        -- minable[Erz] = Insel, auf der es mit dieser Spitzhacke abbaubar ist (aktuelle Insel bevorzugt)
        local minable, rockNeed = {}, {}
        for rockName in pairs(availableRocks) do
            local rockData = Rocks[rockName]
            if Planner.canMine(rockData, power, pickaxe and pickaxe.Name) then
                for _, oreName in ipairs(rockData.Ores or {}) do minable[oreName] = currentWorld end
            end
        end
        for _, rockData in pairs(Rocks) do
            -- nur Steine, die diese Spitzhacke ueberhaupt abbauen darf (Schaden wird unten verglichen)
            if Planner.canMine(rockData, math.huge, pickaxe and pickaxe.Name) then
                for _, oreName in ipairs(rockData.Ores or {}) do
                    rockNeed[oreName] = math.min(rockNeed[oreName] or math.huge, rockData.RequiredDamage or math.huge)
                end
            end
        end
        for oreName, island in pairs(oreHome) do
            if not minable[oreName] and unlocked[island] and (rockNeed[oreName] or math.huge) <= power then minable[oreName] = island end
        end
        for oreName in pairs(eventOres) do minable[oreName] = nil end -- Event/Raid: nur aus dem Inventar
        local TRAVEL_SECONDS = 90 -- Aufschlag fuer jede andere Insel, die besucht werden muss
        local realHave, baseStock = {}, {}
        for itemName, amount in pairs(data().Inventory) do
            if type(amount) == "number" and amount > 0 then
                local usable = forgeGoal.usable(itemName)
                realHave[itemName], baseStock[itemName] = usable, usable
            end
        end
        -- Erze, die gerade in Craft-Slots entstehen, zaehlen als bald verfuegbar
        for _, slot in pairs(data().OreCraftSlots or {}) do
            if type(slot) == "table" and slot.Ore and not slot.Locked then
                baseStock[slot.Ore] = (baseStock[slot.Ore] or 0) + (tonumber(slot.Amount) or 1)
            end
        end
        local craftCache, craftLocks = {}, {}
        local function craftInfo(oreName)
            if craftCache[oreName] == nil then
                local info = false
                if CraftCatalog and not eventOres[oreName] then
                    local okRecipe, recipeData = pcall(CraftCatalog.Recipe, oreName)
                    local okGroup, group = pcall(CraftCatalog.GroupOf, oreName)
                    if okRecipe and type(recipeData) == "table" and type(recipeData.Recipe) == "table" and okGroup and type(group) == "table"
                        and type(group.Station) == "string" then
                        local island = group.Island or (workspace.Proximity:FindFirstChild(group.Station) and currentWorld)
                        craftLocks[oreName] = craftLock(group)
                        if not craftLocks[oreName] and island and unlocked[island] then
                            info = {recipe = recipeData.Recipe, time = tonumber(recipeData.CraftTime) or 0, station = group.Station, island = island}
                        end
                    end
                end
                craftCache[oreName] = info
            end
            return craftCache[oreName] or nil, craftLocks[oreName]
        end
        local MINE_SECONDS = 12 -- grobe Zeit pro abgebautem Erz, um Abbauen gegen Craft-Zeit abzuwaegen
        local function obtain(oreName, amount, state, depth)
            local have = state.stock[oreName] or 0
            local use = math.min(have, amount)
            state.stock[oreName] = have - use
            state.used[oreName] = (state.used[oreName] or 0) + use
            local rest = amount - use
            if rest <= 0 then return true end
            local function visit(island)
                if island ~= currentWorld and not state.islands[island] then state.islands[island] = true; state.work += TRAVEL_SECONDS end
            end
            if minable[oreName] then
                state.mine[oreName] = (state.mine[oreName] or 0) + rest
                state.mineIsland[oreName] = minable[oreName]
                state.work += rest * MINE_SECONDS
                visit(minable[oreName])
                return true
            end
            if depth >= 6 then return false end
            local info, reason = craftInfo(oreName)
            if not info then return false, reason end
            for ingredient, per in pairs(info.recipe) do
                if ingredient == "Gold" then state.gold += per * rest
                else
                    local ready, blocked = obtain(ingredient, per * rest, state, depth + 1)
                    if not ready then return false, blocked end
                end
            end
            -- nach den Zutaten eintragen -> die Liste ist schon in Craft-Reihenfolge
            table.insert(state.crafts, {ore = oreName, amount = rest, station = info.station, island = info.island, seconds = info.time * rest, recipe = info.recipe})
            state.work += info.time * rest
            visit(info.island)
            return true
        end
        -- ignoreGold = true: Plan auch liefern, wenn das Gold fuer die Crafts gerade nicht reicht (state.gold zeigt den Bedarf)
        local function evaluate(recipe, ignoreGold)
            local state = {stock = setmetatable({}, {__index = baseStock}), used = {}, mine = {}, mineIsland = {}, crafts = {}, islands = {}, gold = 0, work = 0}
            for oreName, amount in pairs(recipe) do
                local ready, blocked = obtain(oreName, amount, state, 0)
                if not ready then return nil, blocked end
            end
            if not ignoreGold and state.gold > (data().Gold or 0) then return nil end
            return state
        end
        return {pickaxe = pickaxe, power = power, unlocked = unlocked, minable = minable, realHave = realHave,
            baseStock = baseStock, craftInfo = craftInfo, evaluate = evaluate}
    end
    function forgeGoal.forgeFor(className)
        local island = forgeIslandFor(className)
        return island, island and forgeStationFor(island)
    end
    -- Festes Rezept (Best Possible -> "Farm & Craft"): genau diese Erze besorgen und mit Klassen-Sperre schmieden.
    -- Wird in einer eigenen Datei gemerkt, damit es nach Inselreisen (Script wird neu geladen) weiterlaeuft.
    forgeGoal.fixedFile = "ForgeHelper.goalfixed.json"
    function forgeGoal.setFixed(fixed)
        api.GoalFixed = fixed
        pcall(function()
            if fixed then writefile(forgeGoal.fixedFile, HttpService:JSONEncode(fixed))
            elseif isfile(forgeGoal.fixedFile) then delfile(forgeGoal.fixedFile) end
        end)
    end
    pcall(function()
        if type(isfile) == "function" and isfile(forgeGoal.fixedFile) then
            local saved = HttpService:JSONDecode(readfile(forgeGoal.fixedFile))
            if type(saved) == "table" and type(saved.class) == "string" and type(saved.recipe) == "table" then api.GoalFixed = saved end
        end
    end)
    function forgeGoal.fixedPlan(fixed)
        if not Planner.recipeFitsForge(fixed.recipe) then
            return {error = "Saved forge recipe is invalid. The forge accepts up to " .. Planner.ForgeOreSlots .. " ore types. Recalculate it under Find the strongest gear."}
        end
        local className, label = fixed.class, prettyClass(fixed.class)
        local forgeIsland = forgeIslandFor(className)
        if not forgeIsland then return {error = "No unlocked island has a forge for " .. label .. "."} end
        local ctx = forgeGoal.context()
        local state, blocked = ctx.evaluate(fixed.recipe, true)
        if not state then return {error = blocked or ("Best Possible recipe for " .. label .. " is no longer obtainable – recalculate it.")} end
        local count, missing, waiting = 0, {}, {}
        for oreName, n in pairs(fixed.recipe) do
            count += n
            local ready = math.min(n, ctx.realHave[oreName] or 0)
            if ready < n then missing[oreName] = n - ready end
        end
        for oreName, used in pairs(state.used) do
            if used > (ctx.realHave[oreName] or 0) then waiting[oreName] = used - (ctx.realHave[oreName] or 0) end
        end
        local mineTotal, craftSeconds = 0, 0
        for _, n in pairs(state.mine) do mineTotal += n end
        for _, step in ipairs(state.crafts) do
            craftSeconds += step.seconds
        end
        local kind = classKind(className)
        local variants = Rarity:GetAvailableItems(forgeStationFor(forgeIsland), kind, className, data())
        return {fixed = true, className = className, label = label, kind = kind, metric = kind == "Armor" and "Health" or "Damage",
            count = count, recipe = fixed.recipe, missing = missing, reservedOres = state.used, mine = state.mine, mineIsland = state.mineIsland,
            forgeIsland = forgeIsland, mineTotal = mineTotal, crafts = state.crafts, craftSeconds = craftSeconds, gold = state.gold,
            waiting = waiting, missingTotal = mineTotal + #state.crafts + (next(waiting) and 1 or 0),
            itemType = variants[1] and variants[1].Name or fixed.sample, lockClass = className, goal = true}
    end
    function forgeGoal.compute()
        if api.GoalFixed then return forgeGoal.fixedPlan(api.GoalFixed) end
        local className, target, quality = api.GoalClass, api.GoalTarget, api.GoalQuality
        local kind, metric = classKind(className), goalMetric(className)
        local label = prettyClass(className)
        if className == "" then return {error = "Choose an item class (weapon or armor)."} end
        if not finite(target) or target <= 0 then
            return {error = string.format("Enter a target %s for %s.", metricUnits[metric], label)}
        end
        local forgeIsland = forgeIslandFor(className)
        local name = forgeIsland and forgeStationFor(forgeIsland)
        if not name then return {error = "No unlocked island has a forge for " .. label .. "."} end
        local count = (Rarity:GetItemDataConfig(className) or {}).lock_min_ores
        if not count then return {error = label .. " cannot be class-locked."} end
        -- Wert je Variante pro 1x Erz-Durchschnitt (Referenz: Iron bzw. ein nicht-neutrales Erz). Alle Werte wachsen
        -- linear mit dem Durchschnitt, deshalb reicht eine Referenz.
        local refName = Ores.Iron and not isNeutral("Iron") and "Iron"
        if not refName then
            for oreName, ore in pairs(Ores) do
                if finite(ore.Multiplier) and ore.Multiplier > 0 and not isNeutral(oreName) then refName = oreName; break end
            end
        end
        local refMult = Ores[refName].Multiplier
        local variants, weakest, weightSum = {}, nil, 0
        for _, variant in ipairs(Rarity:GetAvailableItems(name, kind, className, data())) do
            local probe = {Type = variant.Name, Quality = quality, Upgrade = 0, Ores = {[refName] = 1}, Runes = {}}
            local value = metricValue(probe, metric)
            if value and value > 0 then
                local entry = {name = variant.Name, perMult = value / refMult, weight = 1 / (variant.Chance or 1)}
                table.insert(variants, entry)
                weightSum += entry.weight
                if not weakest or entry.perMult < weakest.perMult then weakest = entry end
            end
        end
        if not weakest then return {error = "No variants of " .. label .. " available at this forge."} end
        local needed = target / weakest.perMult
        -- Erreichbarkeit (Inventar, abbaubar, craftbar) kommt aus forgeGoal.context(), das auch Best Possible nutzt
        local ctx = forgeGoal.context()
        local pickaxe, power, unlocked = ctx.pickaxe, ctx.power, ctx.unlocked
        local minable, realHave, craftInfo, evaluate = ctx.minable, ctx.realHave, ctx.craftInfo, ctx.evaluate
        local candidates = {}
        for oreName in pairs(Ores) do
            local mult = Planner.orePower(oreName, Ores)
            -- Neutrale Erze (Bismuth, Verdantite, Fichilliumorite) ignoriert das Spiel im Durchschnitt, sobald ein normales
            -- Erz dabei ist -> sie wuerden das Rezept nicht wie berechnet senken/heben. Darum nie einplanen.
            if not isNeutral(oreName) and mult > 0 and evaluate({[oreName] = 1}) then table.insert(candidates, {name = oreName, mult = mult}) end
        end
        local best
        local function optimize(goalMult)
            best = nil
            local function consider(recipe, avg)
                local state = evaluate(recipe)
                if not state then return end
                local score = state.work + (avg - goalMult) * 10 -- zuerst wenig Arbeit (Abbauen + Craft-Zeit), dann wenig Ueberschuss
                if not best or score < best.score then best = {recipe = recipe, avg = avg, score = score, state = state} end
            end
            for _, high in ipairs(candidates) do
                if high.mult >= goalMult then
                    consider({[high.name] = count}, high.mult)
                    for _, low in ipairs(candidates) do
                        if low.mult < goalMult then
                            local h = math.ceil(count * (goalMult - low.mult) / (high.mult - low.mult) - 1e-9)
                            local l = count - h
                            if h > 0 and l > 0 then consider({[high.name] = h, [low.name] = l}, (high.mult * h + low.mult * l) / count) end
                        end
                    end
                end
            end
        end
        optimize(needed)
        -- Ziel zu hoch: stattdessen das Bestmoegliche planen (hoechster erreichbarer Durchschnitts-Multiplikator).
        local capped = false
        if not best then
            capped = true
            local mults = {}
            for _, entry in ipairs(candidates) do table.insert(mults, entry.mult) end
            table.sort(mults, function(a, b) return a > b end)
            for _, mult in ipairs(mults) do
                optimize(mult)
                if best then break end
            end
            if not best then return {error = "No ores obtainable on your unlocked islands for " .. label .. "."} end
        end
        -- Bessere Erze, die gerade nicht gehen, mit Grund (Spitzhacke zu schwach, Zutat fehlt, nicht auf dieser Insel)
        local function blocker(oreName, depth)
            if (realHave[oreName] or 0) > 0 or minable[oreName] then return nil end
            if depth >= 4 then return nil end
            local info, blocked = craftInfo(oreName)
            if blocked then return blocked end
            if info then
                for ingredient in pairs(info.recipe) do
                    if ingredient ~= "Gold" then
                        local reason = blocker(ingredient, depth + 1)
                        if reason then return depth == 0 and ("craft needs " .. ingredient .. ": " .. reason) or (ingredient .. " → " .. reason) end
                    end
                end
                return nil
            end
            local lowest, special
            for rockName, rockData in pairs(Rocks) do
                if type(rockData) == "table" and table.find(rockData.Ores or {}, oreName) then
                    if not Planner.canMine(rockData, math.huge, pickaxe and pickaxe.Name) then
                        special = special or {rock = rockName, pickaxes = rockData.RequiredPickaxes}
                    elseif not lowest or (rockData.RequiredDamage or 0) < lowest.need then
                        lowest = {need = rockData.RequiredDamage or 0, rock = rockName}
                    end
                end
            end
            local home = oreHome[oreName]
            if home and not unlocked[home] then return "Island " .. home .. " is not unlocked" end
            if lowest then
                return string.format("needs %d pickaxe power (%s%s), you have %d", lowest.need, lowest.rock, home and (", Island " .. home) or "", power)
            end
            if special then return string.format("needs %s (%s)", table.concat(special.pickaxes, " or "), special.rock) end
            return "not obtainable on your unlocked islands"
        end
        local blocked = {}
        local better = {}
        for oreName in pairs(Ores) do
            if Planner.orePower(oreName, Ores) > best.avg + 0.001 and not isNeutral(oreName) then table.insert(better, oreName) end
        end
        table.sort(better, function(a, b) return Planner.orePower(a, Ores) < Planner.orePower(b, Ores) end)
        for _, oreName in ipairs(better) do
            local reason = blocker(oreName, 0)
            if reason then table.insert(blocked, string.format("%s %g×: %s", oreName, Planner.orePower(oreName, Ores), reason)) end
            if #blocked >= 3 then break end
        end
        local state = best.state
        local fractions, missing, waiting = {}, {}, {}
        for oreName, n in pairs(best.recipe) do
            fractions[oreName] = n / count
            local ready = math.min(n, realHave[oreName] or 0)
            if ready < n then missing[oreName] = n - ready end
        end
        for oreName, used in pairs(state.used) do
            if used > (realHave[oreName] or 0) then waiting[oreName] = used - (realHave[oreName] or 0) end -- kommt aus laufenden Crafts
        end
        local mineTotal, craftSeconds = 0, 0
        for _, n in pairs(state.mine) do mineTotal += n end
        for _, step in ipairs(state.crafts) do craftSeconds += step.seconds end
        -- Werte jeder Variante mit dem echten Rezept (gleiche Spielfunktionen wie beim fertigen Item)
        local rows = {}
        local range = {Damage = {math.huge, 0}, DPS = {math.huge, 0}, Health = {math.huge, 0}}
        local metricsShown = kind == "Armor" and {"Health"} or {"Damage", "DPS"}
        for _, v in ipairs(variants) do
            local item = {Type = v.name, Quality = quality, Upgrade = 0, Ores = best.recipe, Runes = {}}
            local parts = {}
            for _, shown in ipairs(metricsShown) do
                local value = metricValue(item, shown) or 0
                range[shown][1], range[shown][2] = math.min(range[shown][1], value), math.max(range[shown][2], value)
                table.insert(parts, formatValue(value, shown) .. (shown == "Damage" and " dmg" or shown == "DPS" and " DPS" or " HP"))
            end
            table.insert(rows, string.format("%s %s (%d%%)", v.name, table.concat(parts, " · "), math.floor(v.weight / weightSum * 100 + 0.5)))
        end
        local itemMultiplier = best.avg * (1 + quality / 100)
        return {className = className, label = label, kind = kind, metric = metric, target = target, quality = quality,
            itemMultiplier = itemMultiplier, range = range,
            minValue = range[metric][1], maxValue = range[metric][2],
            count = count, recipe = best.recipe, missing = missing,
            reservedOres = state.used,
            mine = state.mine, mineIsland = state.mineIsland, forgeIsland = forgeIsland,
            mineTotal = mineTotal, crafts = state.crafts, craftSeconds = craftSeconds, gold = state.gold, waiting = waiting,
            missingTotal = mineTotal + #state.crafts + (next(waiting) and 1 or 0),
            avg = best.avg, needed = needed, variants = rows, capped = capped, blocked = blocked,
            itemType = weakest.name, lockClass = className, goal = true}
    end
    function forgeGoal.describe()
        local plan = forgeGoal.plan
        local text
        if not plan then text = "No plan yet."
        elseif plan.error then text = plan.error
        else
            -- Rezept, Abbau- und Craft-Schritte stehen als Liste mit Erz-Bildern darunter.
            local todo
            if plan.missingTotal == 0 then
                todo = "All materials ready – forges in Farm Mode \"Forging\"."
            else
                todo = string.format("To do: mine %d ores · craft %d step%s (%s) · %s gold%s", plan.mineTotal, #plan.crafts, #plan.crafts == 1 and "" or "s",
                    formatDuration(plan.craftSeconds), thousands(plan.gold), next(plan.waiting) and " · waiting for running crafts" or "")
            end
            if plan.fixed then
                -- Festes Rezept aus "Best Possible"
                return string.format("BEST POSSIBLE: %s · %d ores (class lock)%s\n%s%s", plan.label, plan.count,
                    plan.forgeIsland and plan.forgeIsland ~= currentWorld and (" · forged on Island " .. plan.forgeIsland) or "", todo,
                    forgeGoal.result and ("\n" .. forgeGoal.result) or "")
            end
            local unit = metricUnits[plan.metric]
            local targetText = formatValue(plan.target, plan.metric) .. " " .. unit
            local head = plan.capped
                and string.format("⚠ %s is not reachable here – planning the BEST POSSIBLE instead.\n%s · %d ores (class lock) · ore multiplier %.2f× (target needs %.2f×)",
                    targetText, plan.label, plan.count, plan.avg, plan.needed)
                or string.format("%s · %d ores (class lock) · ore multiplier %.2f× (%s needs %.2f×)", plan.label, plan.count, plan.avg, targetText, plan.needed)
            if plan.forgeIsland and plan.forgeIsland ~= currentWorld then head = head .. " · forged on Island " .. plan.forgeIsland end
            -- Wie theforge.gg: "Multiplier" = Erz-Durchschnitt; das Spiel rechnet mit Durchschnitt x (1 + Qualitaet/100).
            local stats
            if plan.kind == "Armor" then
                stats = string.format("Health at %d%% quality: %s – %s", math.floor(plan.quality), formatValue(plan.range.Health[1], "Health"), formatValue(plan.range.Health[2], "Health"))
            else
                stats = string.format("Damage at %d%% quality: %s – %s · DPS: %s – %s", math.floor(plan.quality),
                    formatValue(plan.range.Damage[1], "Damage"), formatValue(plan.range.Damage[2], "Damage"),
                    formatValue(plan.range.DPS[1], "DPS"), formatValue(plan.range.DPS[2], "DPS"))
            end
            text = string.format("%s\nItem multiplier: %.2f× = ore %.2f× × %.2f (%d%% quality)\n%s\nVariants: %s\n%s%s",
                head, plan.itemMultiplier, plan.avg, 1 + plan.quality / 100, math.floor(plan.quality), stats, table.concat(plan.variants, ", "), todo,
                #plan.blocked > 0 and ("\nBetter ores blocked: " .. table.concat(plan.blocked, " · ")) or "")
        end
        return text .. (forgeGoal.result and ("\n" .. forgeGoal.result) or "")
    end
    function forgeGoal.refresh(force)
        if force or not forgeGoal.plan or os.clock() - forgeGoal.lastPlanAt > 5 then
            local ok, plan = pcall(asClient, forgeGoal.compute)
            forgeGoal.plan, forgeGoal.lastPlanAt = ok and plan or {error = "Plan error: " .. tostring(plan)}, os.clock()
        end
        return forgeGoal.plan
    end
    -- Reise zu einer anderen Insel ueber den Reise-Dienst des Spiels (PortalService:TeleportToIsland).
    -- Vorher Einstellungen speichern und ein Fortsetzen-Merker schreiben; Potassium laedt das Script danach neu
    -- (queueonteleport) und das Ziel laeuft auf der neuen Insel weiter.
    local PortalService = Knit.GetService("PortalService")
    forgeGoal.loader = [[
        if not game:IsLoaded() then game.Loaded:Wait() end
        task.wait(5)
        if isfile("ForgeHelper.lua") then
            local chunk, err = loadstring(readfile("ForgeHelper.lua"), "ForgeHelper")
            if chunk then chunk() else warn("[ForgeHelper] reload failed: " .. tostring(err)) end
        end
    ]]
    forgeGoal.resumeFile = "ForgeHelper.goal"
    local travelBlockedUntil = 0
    function forgeGoal.travel(island, why)
        local target = Islands.Data[island]
        if not target or island == currentWorld or os.clock() < travelBlockedUntil then return false end
        travelBlockedUntil = os.clock() + 60
        if stopMiningInput then stopMiningInput() end
        destination = nil
        log(string.format("Forge goal: traveling to %s (%s)", target.Name, why))
        api:SaveSettings()
        pcall(writefile, forgeGoal.resumeFile, tostring(os.time()))
        if type(queueonteleport) == "function" then pcall(queueonteleport, forgeGoal.loader) end
        local ok, result = pcall(function() return PortalService:TeleportToIsland(target.Name):await() end)
        if not ok or result == false then
            pcall(delfile, forgeGoal.resumeFile)
            log("Forge goal: travel to " .. target.Name .. " failed: " .. tostring(result))
            return false
        end
        return true
    end
    function forgeGoal.step(token)
        local plan = forgeGoal.refresh(false)
        if plan.error then log("Forge goal: " .. plan.error); return false end
        if plan.missingTotal == 0 then
            -- Schmieden: auf der Insel, deren Schmiede die Klasse hat
            if plan.forgeIsland and plan.forgeIsland ~= currentWorld then
                return forgeGoal.travel(plan.forgeIsland, "forge for " .. plan.label)
            end
            if cooldown.Forge and cooldown.Forge > os.clock() then return false end
            cooldown.Forge = os.clock() + 30
            local before = {}
            for _, item in ipairs(data().Inventory.Equipments or {}) do if item.GUID then before[item.GUID] = true end end
            forgeBusy = true
            local ok, crafted = pcall(craft, token, plan)
            forgeBusy = false
            releaseForge()
            if not ok then error(crafted) end
            forgeGoal.plan = nil
            if crafted then
                task.wait(1)
                local item
                for _, entry in ipairs(data().Inventory.Equipments or {}) do if entry.GUID and not before[entry.GUID] then item = entry end end
                -- Ergebnis mit derselben Kennzahl pruefen wie geplant (Schaden, DPS oder Leben)
                local value = item and metricValue(item, plan.metric)
                local shown = string.format("%s %s", formatValue(value, plan.metric), metricUnits[plan.metric])
                forgeGoal.attempts += 1
                -- Bei zu hohem Ziel gilt das Bestmoegliche (schwaechste Variante, kleine Toleranz fuer Qualitaet) als erreicht.
                local wanted = plan.fixed and -math.huge or (plan.capped and plan.minValue * 0.97 or plan.target)
                if plan.fixed then forgeGoal.setFixed(nil) end -- Best Possible: einmal schmieden, dann fertig
                if (plan.fixed and item ~= nil) or (value and value >= wanted) then
                    api.ForgeGoalActive = false
                    forgeGoal.result = string.format("✔ Done: %s with %s (quality %.1f%%)", item.Type, shown, item.Quality or 0)
                elseif forgeGoal.attempts >= 3 then
                    api.ForgeGoalActive = false
                    forgeGoal.result = string.format("Stopped after 3 tries – last: %s %s", tostring(item and item.Type), shown)
                else
                    forgeGoal.result = string.format("Try %d: %s %s – below target, forging again", forgeGoal.attempts, tostring(item and item.Type), shown)
                end
                log("Forge goal: " .. forgeGoal.result)
            end
            return true
        end
        -- 0) Stash fast voll (z. B. tausende Quartz fuer eine starke Waffe passen nicht gleichzeitig hinein):
        --    zwischendurch schon umcraften (viele Rohstoffe -> wenige gecraftete Erze) und erst dann weiter abbauen.
        local stashTotal, stashCapacity = stashFill()
        local stashShare = stashTotal and stashTotal / stashCapacity or 0
        if #plan.crafts > 0 and stashShare >= 0.7 and forgeGoal.craftOres(token, plan, true, stashShare < 1) then return true end
        if plan.mineTotal > 0 and stashShare >= 1 then
            if stopMiningInput then stopMiningInput() end
            destination = nil
            log(string.format("Forge goal: stash full (%d/%d) – waiting for crafts / Auto Sell to free space", stashTotal, stashCapacity))
            return true
        end
        -- 1) Rohstoffe abbauen (auch Zutaten fuer Crafts): erst auf dieser Insel, dann auf die naechste reisen
        if plan.mineTotal > 0 then
            local localJobs, elsewhere = {}, nil
            for oreName, amount in pairs(plan.mine) do
                local island = plan.mineIsland[oreName]
                if island == currentWorld then
                    local job = {kind = "Ore", target = oreName, remaining = amount, label = "Forge goal (" .. oreName .. "): "}
                    local rock = findTarget(job)
                    if rock then attack(rock, job, token); return true end
                    table.insert(localJobs, job)
                elseif island and (not elsewhere or island < elsewhere.island) then
                    elsewhere = {island = island, ore = oreName}
                end
            end
            if stashShare < 0.7 and #plan.crafts > 0 and forgeGoal.craftOres(token, plan, true, true) then return true end
            if #localJobs > 0 then
                local respawn = questTools.respawnJob(localJobs, true)
                local filler = respawn and findTarget(respawn)
                if filler then attack(filler, respawn, token); return true end
                log("Forge goal: waiting for a mineable rock with " .. localJobs[1].target .. " on this island")
                return false
            end
            if elsewhere then return forgeGoal.travel(elsewhere.island, "mine " .. elsewhere.ore) end
            log("Forge goal: no rocks with the missing ores loaded nearby")
            return false
        end
        -- 2) Erze craften (in Rezept-Reihenfolge, sobald die Zutaten wirklich im Inventar liegen)
        if #plan.crafts > 0 then return forgeGoal.craftOres(token, plan) end
        -- 3) Laufende Crafts abwarten
        if next(plan.waiting) then
            if stopMiningInput then stopMiningInput() end
            destination = nil
            log("Forge goal: waiting for ore crafting to finish")
            return true
        end
        return false
    end
    -- Bei Teilmengen hat ein Craft auf der aktuellen Insel Vorrang vor einer Reise.
    function forgeGoal.craftOres(token, plan, batchOnly, localOnly)
        local slots, unlocked, free = data().OreCraftSlots or {}, 0, 0
        for _, slot in pairs(slots) do
            if type(slot) == "table" and not slot.Locked then
                unlocked += 1
                if slot.Ore == nil then free += 1 end
            end
        end
        if free == 0 then
            if batchOnly then return false end
            destination = nil
            log(unlocked == 0 and "Forge goal: no ore crafting slots available yet" or "Forge goal: all unlocked ore crafting slots are busy")
            return true
        end
        local missingGold, elsewhere
        for _, craftStep in ipairs(plan.crafts) do
            -- so viele Crafts, wie die Zutaten im Inventar gerade hergeben (auch Teilmengen -> macht Platz im Stash)
            local amount = craftStep.amount
            for ingredient, per in pairs(craftStep.recipe) do
                if ingredient ~= "Gold" then amount = math.min(amount, math.floor(forgeGoal.usable(ingredient) / math.max(per, 1))) end
            end
            local goldPerOre = craftStep.recipe.Gold
            if amount > 0 and goldPerOre and goldPerOre > 0 then
                local gold = data().Gold or 0
                if gold < goldPerOre then missingGold = math.min(missingGold or math.huge, goldPerOre - gold) end
                amount = math.min(amount, math.floor(gold / goldPerOre))
            end
            if amount >= 1 then
                if craftStep.island and craftStep.island ~= currentWorld then
                    elsewhere = elsewhere or craftStep
                    continue
                end
                local stationModel = workspace.Proximity:FindFirstChild(craftStep.station)
                if not stationModel then log("Forge goal: craft station not loaded: " .. craftStep.station); return false end
                log(string.format("Forge goal: flying to %s to craft %d× %s", craftStep.station, amount, craftStep.ore))
                if not approach(stationModel, token) or not alive(token) then return false end
                local okGroup, group = pcall(CraftCatalog.GroupOf, craftStep.ore)
                local blocked = craftLock(okGroup and group)
                if blocked then log("Forge goal: " .. blocked); forgeGoal.plan = nil; return false end
                await(OreCraftService:StartCrafting(craftStep.station))
                await(OreCraftService:CraftRequest(craftStep.ore, amount))
                pcall(function() OreCraftService:CheckCraftCompletions() end)
                forgeGoal.plan = nil -- neu planen: die Erze stecken jetzt im Craft-Slot
                log(string.format("Forge goal: crafting %d× %s (%s)%s", amount, craftStep.ore, formatDuration(craftStep.seconds / craftStep.amount * amount),
                    batchOnly and " – freeing stash space" or ""))
                return true
            end
        end
        if elsewhere and not localOnly then return forgeGoal.travel(elsewhere.island, "craft " .. elsewhere.ore .. " at " .. elsewhere.station) end
        if batchOnly then return false end
        destination = nil
        log(missingGold and string.format("Forge goal: need %s more gold to start the next ore craft", thousands(missingGold))
            or "Forge goal: waiting for ingredients from running crafts")
        return true
    end
end
-- FORGE_GOAL_END

-- BEST_CRAFT_START
-- "Best Craftable": die besten Items, die man JETZT mit den Erzen im Inventar an dieser Schmiede herstellen kann,
-- fuer jede Waffen- und Ruestungsklasse (mit Klassen-Sperre, also genau lock_min_ores Erze).
-- Bewertet mit den echten Spielformeln (Shared.Data.Equipments / Shared.Data.Runes, live ausgelesen):
--   Traits: ein Erz gibt seine Traits erst ab 10 % Anteil (dann 10 % Staerke), volle Staerke ab 30 %; jeder Trait gilt
--           nur fuer Waffen oder Ruestung (Whitelist). Gleiche Werte addieren sich (stackable) oder es zaehlt der
--           hoechste/niedrigste. Das rechnen Runes:GetRunesFromItem/GetCombinedTraits des Spiels selbst aus.
--   Waffe:  erwarteter DPS = Schaden x Treffer pro Sekunde (Varianten-Tempo / Angriffszeit der Klasse) x Lethality
--           x Attack Speed x Krit-Erwartung (Grundkrit 1,45x) + grob geschaetzte Procs (Burn, Poison, Explosion,
--           Lightning, Smite, Snow ...; mit Abklingzeit begrenzt). Die Variante ist Zufall -> nach Chance gewichtet.
--   Ruestung: Gesamt-Leben mit deiner uebrigen angelegten Ausruestung x (Vitality - Negative Vitality), Shield als
--           effektives Leben.
--   "Avoid Negative Traits": weniger Leben (Waffe), Ausdauer und Lauftempo ziehen von der Bewertung ab.
api.BestCraft = {result = nil, running = false, slots = {"Weapon", "Helmet", "Chestplate", "Leggings"}}
do
    local bestCraft = api.BestCraft
    local B = {owner = nil :: {[string]: string}?} -- Hilfsfunktionen als Tabellenfelder (Limit 200 lokale Variablen im Hauptteil)
    function B.commas(n) -- 12345 -> "12.345"
        return (tostring(math.floor((n or 0) + 0.5)):reverse():gsub("(%d%d%d)", "%1."):reverse():gsub("^%.", ""))
    end
    -- Bedeutungen aus den Trait-Beschreibungen des Spiels (Runes.TraitPool[...].Description, live ausgelesen):
    -- Explosion/Smite/Lightning/Frost Slash/Blackhole/Starfall = Chance pro Treffer auf X % Waffenschaden (Lightning und
    -- Starfall mit Abklingzeit). Snow und Ice verlangsamen/frieren nur ein (kein Schaden) -> nicht als Schaden gezaehlt.
    B.procs = { -- {Chance, Schaden in % des Treffers, Abklingzeit}
        {"ExplosionChance", "ExplosionDamage"}, {"SmiteChance", "SmiteDamage"}, {"LightningChance", "LightningDamage", "LightningCooldown"},
        {"FrostSlashChance", "FrostSlashDamage"}, {"BlackholeChance", "BlackholeDamage", "BlackholeCooldown"},
        {"StarfallChance", "StarfallDamage", "StarfallCooldown"},
    }
    B.dots = {{"BurnChance", "FireDamage", "BurnDuration"}, {"PoisonChance", "PoisonDamage", "PoisonDuration"}} -- Schaden pro Sekunde
    function B.penalty(t, kind)
        if not api.BestAvoidNegative then return 1 end
        local loss = 0.5 * (t.NegativeStaminaBoost or 0) + 0.5 * (t.NegativeMoveSpeed or 0)
        if kind == "Weapon" then loss += (t.NegativeHealthBoost or 0) end -- bei Ruestung steckt es schon im Leben
        return math.max(0.2, 1 - loss / 100)
    end
    -- c: Klassenwerte pro 1x Erz-Durchschnitt (dmg, hps, dmgHps bzw. hp, othersHp)
    function B.weapon(t, avg, c)
        -- Berserker wirkt nur unter 35 % Leben -> nur ein Drittel seiner Laufzeit angerechnet
        local boost = (t.DamageBoost or 0) / 100
            + (t.BerserkerDamage or 0) / 100 * math.min(1, (t.BerserkerDuration or 0) / math.max(1, t.BerserkerCooldown or 60)) / 3
            + (t.MoonBoost or 0) / 100 * 0.5 -- Moon Knight nur nachts (etwa die Haelfte der Zeit)
        local speed = 1 + (t.AttackSpeedBoost or 0) / 100
        local critChance = math.min(1, (t.CriticalChance or 0) / 100)
        local crit = 1 + critChance * (0.45 + (t.CriticalDamage or 0) / 100)
        local echo = 1 + math.min(1, (t.ReverberationChance or 0) / 100) -- Reverberation: Chance, dass ein Treffer doppelt trifft
        local hit, hps = avg * c.dmg * (1 + boost), c.hps * speed
        local dps = avg * c.dmgHps * (1 + boost) * speed * crit * echo
        -- Glacier Explosion nur bei Krits; Stellar Mark zuendet alle X Treffer
        if (t.GlacierExplosionChance or 0) > 0 then dps += hps * critChance * t.GlacierExplosionChance / 100 * (t.GlacierExplosionDamage or 0) / 100 * hit end
        if (t.StellarMarkDamage or 0) > 0 and (t.StellarMarkHits or 0) > 0 then dps += hps / t.StellarMarkHits * t.StellarMarkDamage / 100 * hit end
        for _, proc in ipairs(B.procs) do
            local chance, damage = (t[proc[1]] or 0) / 100, (t[proc[2]] or 0) / 100
            if chance > 0 and damage > 0 then
                local rate = hps * chance
                if proc[3] and (t[proc[3]] or 0) > 0 then rate = math.min(rate, 1 / t[proc[3]]) end
                dps += rate * damage * hit
            end
        end
        for _, dot in ipairs(B.dots) do
            local chance, damage, duration = (t[dot[1]] or 0) / 100, (t[dot[2]] or 0) / 100, t[dot[3]] or 0
            if chance > 0 and damage > 0 and duration > 0 then dps += damage * hit * math.min(1, hps * chance * duration) end
        end
        return dps * B.penalty(t, "Weapon"), dps, hit, hps
    end
    function B.armor(t, avg, c)
        local total = (100 + c.othersHp + avg * c.hp) * math.max(0.01, 1 + ((t.HealthBoost or 0) - (t.NegativeHealthBoost or 0)) / 100)
        -- Shield (Spieltext): "Reduce incoming physical damage by X %. Has Y % chance per hit." -> X hoechstens 100 %
        local block = math.clamp((t.ShieldChance or 0) / 100 * math.min(100, t.ShieldPercentage or 0) / 100, 0, 0.95)
        local ehp = total / (1 - block)
        return ehp * B.penalty(t, "Armor"), total, ehp
    end
    function B.runesOf(items)
        local list = {}
        for _, item in ipairs(items) do
            local ok, runes = pcall(Runes.GetRunesFromItem, Runes, item)
            if ok then for _, rune in pairs(runes) do table.insert(list, rune) end end
        end
        return list
    end
    function B.traits(baseRunes, item)
        local list = table.clone(baseRunes)
        for _, rune in pairs(Runes:GetRunesFromItem(item)) do table.insert(list, rune) end
        return Runes:GetCombinedTraits(list)
    end
    -- Bestes Rezept mit n Erzen aus dem Pool: Startloesungen (hoechste Multiplikatoren; je Trait-Erz eine Variante mit
    -- 30 % Anteil), dann Bergsteigen mit Tausch von 1 Erz bzw. 10 %/20 % des Rezepts. Erze unter 10 % Anteil geben
    -- keine Traits -> ein Erz mit schlechten Traits wird so automatisch klein gehalten oder entfernt.
    function B.optimize(job)
        local n, evals = job.n, 0
        local function evaluate(counts)
            local fractions, sum, weight, neutralSum = {}, 0, 0, 0
            for name, k in pairs(counts) do
                if k > 0 then
                    fractions[name] = k / n
                    local ore = job.info[name]
                    if ore.neutral then neutralSum += ore.mult * k else sum += ore.mult * k; weight += k end
                end
            end
            local avg = weight > 0 and sum / weight or neutralSum / n
            evals += 1
            if evals % 120 == 0 then task.wait() end -- Spiel nicht einfrieren
            -- Best Possible: nur Rezepte, die als Ganzes wirklich zu bekommen sind (gemeinsame Zutaten, Gold)
            if job.feasible and not job.feasible(counts) then return -math.huge, avg, nil, fractions end
            local traits = B.traits(job.baseRunes, {Type = job.sample, Ores = fractions})
            return job.score(traits, avg), avg, traits, fractions
        end
        local function greedy(seedOre, seedAmount)
            local counts, left, slots = {}, n, Planner.ForgeOreSlots
            if seedOre then
                counts[seedOre.name], left, slots = seedAmount, left - seedAmount, slots - 1
            end
            -- Reserve enough capacity in the remaining slots before taking a scarce ore.
            local capacity = {}
            capacity[#job.byMult + 1] = table.create(slots + 1, 0)
            for index = #job.byMult, 1, -1 do
                local ore = job.byMult[index]
                local existing = counts[ore.name] or 0
                local cost = existing > 0 and 0 or 1
                local tail = capacity[index + 1]
                local row = {}
                for free = 0, slots do
                    row[free + 1] = tail[free + 1]
                    if free >= cost then row[free + 1] = math.max(row[free + 1], ore.have - existing + tail[free - cost + 1]) end
                end
                capacity[index] = row
            end
            if left > capacity[1][slots + 1] then return nil end
            for index, ore in ipairs(job.byMult) do
                if left <= 0 then break end
                local existing = counts[ore.name] or 0
                local cost = existing > 0 and 0 or 1
                local take = math.min(left, ore.have - existing)
                if take > 0 and cost <= slots and left - take <= capacity[index + 1][slots - cost + 1] then
                    counts[ore.name], left, slots = existing + take, left - take, slots - cost
                end
            end
            return left <= 0 and counts or nil
        end
        local starts = {greedy()}
        for _, ore in ipairs(job.traitOres) do
            local k = math.min(ore.have, math.ceil(n * 0.3))
            if k >= math.ceil(n * 0.1) then
                local start = greedy(ore, k)
                if start then table.insert(starts, start) end
            end
        end
        local steps = {1}
        for _, share in ipairs({0.1, 0.2}) do
            local k = math.ceil(n * share)
            if k > steps[#steps] then table.insert(steps, k) end
        end
        local best
        for _, counts in ipairs(starts) do
            local score = evaluate(counts)
            for _ = 1, 40 do
                local move, moveScore = nil, score
                local names = {}
                for name, k in pairs(counts) do if k > 0 then table.insert(names, name) end end
                for _, a in ipairs(names) do
                    local ka = counts[a]
                    for _, ore in ipairs(job.moves) do
                        local b = ore.name
                        if b ~= a then
                            local kb = counts[b] or 0
                            local needsSwap = kb == 0 and #names >= Planner.ForgeOreSlots
                            for index = 1, needsSwap and 1 or #steps do
                                local k = needsSwap and ka or steps[index]
                                if k <= ka and kb + k <= ore.have then
                                    counts[a], counts[b] = k < ka and ka - k or nil, kb + k
                                    local s = evaluate(counts)
                                    if s > moveScore * (1 + 1e-9) then move, moveScore = {a, b, k}, s end
                                    counts[a], counts[b] = ka, kb > 0 and kb or nil
                                end
                            end
                        end
                    end
                end
                if not move then break end
                counts[move[1]] = counts[move[1]] - move[3]
                if counts[move[1]] <= 0 then counts[move[1]] = nil end
                counts[move[2]] = (counts[move[2]] or 0) + move[3]
                score = moveScore
            end
            if not best or score > best.score then best = {score = score, counts = table.clone(counts)} end
        end
        if not best or best.score == -math.huge then return nil end
        local score, avg, traits, fractions = evaluate(best.counts)
        if not traits then return nil end
        return {counts = best.counts, score = score, avg = avg, traits = traits, fractions = fractions}
    end
    -- Trait-Liste eines Rezepts (nur die Traits dieses Items), gruppiert nach Trait, Nachteile mit Warnzeichen
    function B.statOwner()
        if B.owner then return B.owner end
        local owner = {}
        for id, trait in pairs(Runes.TraitPool) do
            for stat in pairs(type(trait.Stats) == "table" and trait.Stats or {}) do owner[stat] = id end
        end
        B.owner = owner
        return owner
    end
    -- Traits eines Items als Liste {name, value, negative}: Vorteile zuerst, Nachteile (Negative ..., Backfire) danach
    function B.traitList(t)
        local owner, groups, order = B.statOwner(), {}, {}
        for stat, value in pairs(t) do
            if finite(value) and value ~= 0 then
                local id = owner[stat] or stat
                if not groups[id] then groups[id] = {}; table.insert(order, id) end
                table.insert(groups[id], {stat = stat, value = value})
            end
        end
        table.sort(order)
        local good, bad = {}, {}
        local function round(value) return math.floor(value * 10 + 0.5) / 10 end
        for _, id in ipairs(order) do
            local trait = Runes.TraitPool[id]
            local name = trait and trait.Name or id
            local negative = id:sub(1, 8) == "Negative" or id == "DemonBackfire"
            local stats = groups[id]
            local value
            if #stats == 1 then
                value = string.format("%s%g%%", negative and "−" or "+", round(stats[1].value))
            else
                -- z. B. Burn: Chance / Dauer / Schaden
                table.sort(stats, function(a, b) return a.stat < b.stat end)
                local parts = {}
                for _, entry in ipairs(stats) do
                    local unit = entry.stat:find("Duration$") and "s" or (entry.stat:find("Cooldown$") and "s cd" or "")
                    table.insert(parts, round(entry.value) .. unit)
                end
                value = "(" .. table.concat(parts, " / ") .. ")"
            end
            table.insert(negative and bad or good, {name = name, value = value, negative = negative})
        end
        for _, entry in ipairs(bad) do table.insert(good, entry) end
        return good
    end
    function B.recipeText(counts)
        local list = {}
        for name, k in pairs(counts) do table.insert(list, {name = name, k = k}) end
        table.sort(list, function(a, b)
            if a.k ~= b.k then return a.k > b.k end
            return a.name < b.name
        end)
        local parts = {}
        for _, entry in ipairs(list) do table.insert(parts, entry.name .. " ×" .. entry.k) end
        return table.concat(parts, ", ")
    end
    -- Klassenwerte je Variante bei Erz-Durchschnitt 1 (nach Chance gewichtet) und die uebrige angelegte Ausruestung
    -- (deren Traits addieren sich mit dem neuen Item)
    function B.classSetup(class, quality, equipped, refName, refMult)
        local c, weightSum, sample, slot = {dmg = 0, hps = 0, dmgHps = 0, hp = 0, othersHp = 0}, 0, nil, nil
        local rows = {}
        for _, variant in ipairs(class.variants) do
            local item = {Type = variant.Name, Quality = quality, Upgrade = 0, Ores = {[refName] = 1}, Runes = {}}
            local w = 1 / (variant.Chance or 1)
            weightSum += w
            sample = sample or variant.Name
            if class.kind == "Weapon" then
                local damage = (forgeGoal.itemDamage(item) or 0) / refMult
                local okSpeed, speed = pcall(Equipment.CalculateAttackSpeed, Equipment, nil, item)
                local okTime, baseTime = pcall(Equipment.GetBaseAttackTime, Equipment, Equipment:GetItemBaseType(variant.Name))
                local hps = okSpeed and okTime and finite(speed) and finite(baseTime) and baseTime > 0 and speed / baseTime or 0
                c.dmg += w * damage; c.hps += w * hps; c.dmgHps += w * damage * hps
                table.insert(rows, {name = variant.Name, w = w, damage = damage, hps = hps})
            else
                local hp = (forgeGoal.itemHealth(item) or 0) / refMult
                c.hp += w * hp
                slot = slot or slotOf({Type = variant.Name})
                table.insert(rows, {name = variant.Name, w = w, hp = hp})
            end
        end
        for key in pairs({dmg = 1, hps = 1, dmgHps = 1, hp = 1}) do c[key] /= weightSum end
        local others = {}
        for equippedSlot, item in pairs(equipped) do
            if type(item) == "table" and equippedSlot ~= "Pickaxe" and equippedSlot ~= (class.kind == "Weapon" and "Weapon" or slot) then
                table.insert(others, item)
                if class.kind == "Armor" and Equipment.Items.Armor[item.Type] then c.othersHp += forgeGoal.itemHealth(item) or 0 end
            end
        end
        return c, rows, weightSum, sample, slot, others
    end
    -- Fertige Kartendaten fuer ein Rezept (Werte mit den Spielfunktionen, Traits, Varianten, Vergleich)
    function B.entryFor(class, best, c, rows, weightSum, sample, slot, others, quality, equipped)
        local own = Runes:GetCombinedTraits(Runes:GetRunesFromItem({Type = sample, Ores = best.fractions}))
        local variantList = {}
        for _, row in ipairs(rows) do table.insert(variantList, {name = row.name, chance = row.w / weightSum * 100}) end
        table.sort(variantList, function(a, b) return a.chance > b.chance end)
        local entry = {class = class.name, label = forgeGoal.prettyClass(class.name), kind = class.kind, n = class.n, slot = slot,
            recipe = best.counts, recipeText = B.recipeText(best.counts), avg = best.avg, score = best.score,
            traits = B.traitList(own), variants = variantList, sample = sample, fractions = best.fractions, quality = quality}
        local low, high = math.huge, 0
        for _, row in ipairs(rows) do
            local item = {Type = row.name, Quality = quality, Upgrade = 0, Ores = best.fractions, Runes = {}}
            local value = (class.kind == "Weapon" and forgeGoal.itemDamage(item) or forgeGoal.itemHealth(item)) or 0
            low, high = math.min(low, value), math.max(high, value)
        end
        if class.kind == "Weapon" then
            local _, dps, _, hps = B.weapon(best.traits, best.avg, c)
            entry.dps, entry.hps, entry.damageLow, entry.damageHigh = dps, hps, low, high
        else
            local _, total, ehp = B.armor(best.traits, best.avg, c)
            entry.total, entry.ehp, entry.hpLow, entry.hpHigh = total, ehp, low, high
            local current = slot and equipped[slot]
            if type(current) == "table" and current.Type then
                local currentScore, _, currentEhp = B.armor(B.traits(B.runesOf(others), current), 1, {hp = forgeGoal.itemHealth(current) or 0, othersHp = c.othersHp})
                entry.currentEhp, entry.currentType, entry.currentScore = currentEhp, current.Type, currentScore
            end
        end
        return entry
    end
    -- Bewertung der aktuell angelegten Waffe (gleiche Formel, mit Upgrade-Stufe)
    function B.currentWeapon(equipped)
        local weapon = equipped.Weapon
        if type(weapon) ~= "table" or not weapon.Type then return nil end
        local damage = forgeGoal.itemDamage(weapon) or 0
        local okSpeed, speed = pcall(Equipment.CalculateAttackSpeed, Equipment, nil, weapon)
        local okTime, baseTime = pcall(Equipment.GetBaseAttackTime, Equipment, Equipment:GetItemBaseType(weapon.Type))
        local hps = okSpeed and okTime and finite(speed) and finite(baseTime) and baseTime > 0 and speed / baseTime or 0
        local others = {}
        for equippedSlot, item in pairs(equipped) do
            if type(item) == "table" and equippedSlot ~= "Pickaxe" and equippedSlot ~= "Weapon" then table.insert(others, item) end
        end
        local _, dps = B.weapon(B.traits(B.runesOf(others), weapon), 1, {dmg = damage, hps = hps, dmgHps = damage * hps})
        return {type = weapon.Type, dps = dps}
    end
    -- Tausch-Kandidaten fuer den Optimierer: die staerksten Erze + Erze mit Traits fuer diese Item-Art
    function B.fillMoves(job, byMult, kind, maxStrong, maxTrait)
        local seen = {}
        for i, ore in ipairs(byMult) do
            if i > maxStrong then break end
            table.insert(job.moves, ore); seen[ore.name] = true
        end
        for _, ore in ipairs(byMult) do
            local relevant = false
            for _, trait in ipairs(ore.traits or {}) do
                if not trait.Whitelist or table.find(trait.Whitelist, kind) then relevant = true end
            end
            if relevant and #job.traitOres < maxTrait then
                table.insert(job.traitOres, ore)
                if not seen[ore.name] then table.insert(job.moves, ore); seen[ore.name] = true end
            end
        end
    end
    function B.matchesSlot(className, target)
        return target == "Weapon" or className:find(target, 1, true) ~= nil
    end

    -- BEST POSSIBLE: das beste Item, das man ueberhaupt bekommen kann. Erze: Inventar + auf freigeschalteten Inseln mit
    -- dieser Spitzhacke abbaubar + craftbar (abbau-/craftbare zaehlen als unbegrenzt). Event- und Raid-Erze (Tower of Hell)
    -- sind ganz ausgeschlossen, auch aus dem Inventar, weil man sie nicht dauerhaft nachfarmen kann.
    -- target = "Weapon", "Helmet", "Chestplate" oder "Leggings".
    function B.computePossible(target, progress)
        local ctx = forgeGoal.context()
        local quality = api.GoalQuality
        local kind = target == "Weapon" and "Weapon" or "Armor"
        -- Wie viele Stueck jedes Erzes sind hoechstens zu bekommen? (Bestand + abbauen + craften, mit deinem Gold.)
        -- Beispiel: Yin-Yang wird aus Yin und Yang gecraftet; die braucht eine Spitzhacke, die du nicht hast -> nur so viele,
        -- wie dein Bestand an Yin/Yang hergibt. Binaere Suche bis zur groessten Erzzahl einer Klasse.
        local maxN = 0
        for _, config in ipairs(Rarity[kind] or {}) do maxN = math.max(maxN, config.lock_min_ores or 0) end
        local pool, info = {}, {}
        for name, ore in pairs(Ores) do
            if finite(ore.Multiplier) and ore.Multiplier > 0 and not forgeGoal.eventOres[name] and ctx.evaluate({[name] = 1}) then
                local low, high = 1, maxN
                if ctx.evaluate({[name] = maxN}) then low = maxN end
                while low < high do
                    local mid = math.ceil((low + high) / 2)
                    if ctx.evaluate({[name] = mid}) then low = mid else high = mid - 1 end
                end
                local entry = {name = name, mult = ore.Multiplier, neutral = ore.NeutralMultiplier == true, have = low, traits = ore.Traits}
                table.insert(pool, entry)
                info[name] = entry
            end
        end
        if #pool == 0 then return {error = "No obtainable ores found."} end
        local byMult = table.clone(pool)
        table.sort(byMult, function(a, b)
            if a.neutral ~= b.neutral then return not a.neutral end
            if a.mult ~= b.mult then return a.mult > b.mult end
            return a.name < b.name
        end)
        local equipped = data().Equipped or {}
        local refName = Ores.Iron and "Iron" or byMult[1].name
        local refMult = Ores[refName].Multiplier
        local classes = {}
        for _, config in ipairs(Rarity[kind] or {}) do
            if config.lock_min_ores and B.matchesSlot(config.name, target) then
                local island, station = forgeGoal.forgeFor(config.name)
                local variants = station and Rarity:GetAvailableItems(station, kind, config.name, data()) or {}
                if #variants > 0 then table.insert(classes, {kind = kind, name = config.name, n = config.lock_min_ores, variants = variants, island = island}) end
            end
        end
        if #classes == 0 then return {error = "No unlocked forge can make " .. target:lower() .. "."} end
        local results, cache = {}, {}
        for index, class in ipairs(classes) do
            if progress then progress(string.format("Best possible %s: %d/%d %s …", target:lower(), index, #classes, forgeGoal.prettyClass(class.name))) end
            local c, rows, weightSum, sample, slot, others = B.classSetup(class, quality, equipped, refName, refMult)
            local job = {n = class.n, info = info, byMult = byMult, sample = sample, baseRunes = B.runesOf(others), traitOres = {}, moves = {}}
            job.score = kind == "Weapon" and function(t, avg) return (B.weapon(t, avg, c)) end or function(t, avg) return (B.armor(t, avg, c)) end
            job.feasible = function(counts) return ctx.evaluate(counts) ~= nil end -- ganzes Rezept machbar (Zutaten, Gold)?
            B.fillMoves(job, byMult, kind, 14, 10)
            -- Waffen mit gleicher Erzzahl haben dasselbe beste Rezept (Klassenwerte wirken nur als Faktor) -> wiederverwenden
            local key = kind .. ":" .. class.n
            local best = kind == "Weapon" and cache[key] and B.rescore(job, cache[key]) or B.optimize(job)
            if best then
                if kind == "Weapon" then cache[key] = best.counts end
                local entry = B.entryFor(class, best, c, rows, weightSum, sample, slot, others, quality, equipped)
                entry.island = class.island
                table.insert(results, entry)
            end
        end
        local top
        for _, entry in ipairs(results) do if not top or entry.score > top.score then top = entry end end
        if not top then return {error = "No recipe found for " .. target:lower() .. "."} end
        if kind == "Weapon" then top.current = B.currentWeapon(equipped) end
        -- Was muss dafuer passieren? (gleiche Planung wie das Schmiede-Ziel: abbauen, craften, reisen)
        local state = ctx.evaluate(top.recipe) or ctx.evaluate(top.recipe, true)
        local effort = {mine = 0, crafts = 0, craftSeconds = 0, gold = 0, islands = {}}
        local craftedBy = {}
        if state then
            for _, n in pairs(state.mine) do effort.mine += n end
            for _, step in ipairs(state.crafts) do
                effort.crafts += 1; effort.craftSeconds += step.seconds
                craftedBy[step.ore] = (craftedBy[step.ore] or 0) + step.amount
            end
            effort.gold = state.gold
            effort.goldShort = state.gold > (data().Gold or 0)
            for island in pairs(state.islands) do table.insert(effort.islands, island) end
            table.sort(effort.islands)
        end
        top.effort, top.requirements = effort, {}
        for oreName, need in pairs(top.recipe) do
            local have = ctx.realHave[oreName] or 0
            local status
            if have >= need then status = "ready"
            elseif craftedBy[oreName] then status = "craft " .. (need - have)
            elseif state and state.mine[oreName] then
                local island = state.mineIsland[oreName]
                status = "mine " .. (need - have) .. (island and island ~= currentWorld and (" · I" .. island) or "")
            else status = "get " .. (need - have) end
            table.insert(top.requirements, {name = oreName, need = need, have = have, status = status})
        end
        table.sort(top.requirements, function(a, b)
            if a.need ~= b.need then return a.need > b.need end
            return a.name < b.name
        end)
        return {kind = kind, target = target, best = top, possible = true, quality = quality}
    end
    -- Bekanntes Rezept fuer eine andere Klasse neu bewerten (gleiche Erze, andere Klassenwerte)
    function B.rescore(job, counts)
        local fractions, sum, weight, neutralSum = {}, 0, 0, 0
        for name, k in pairs(counts) do
            fractions[name] = k / job.n
            local ore = job.info[name]
            if ore.neutral then neutralSum += ore.mult * k else sum += ore.mult * k; weight += k end
        end
        local avg = weight > 0 and sum / weight or neutralSum / job.n
        local traits = B.traits(job.baseRunes, {Type = job.sample, Ores = fractions})
        return {counts = table.clone(counts), score = job.score(traits, avg), avg = avg, traits = traits, fractions = fractions}
    end
    function B.compute(target, progress)
        local forgeStation = station()
        if not forgeStation then return {error = "No forge loaded on this island – go near a forge."} end
        local stationName = Rarity:ResolveStation(forgeStation.Name, data())
        local quality = api.GoalQuality
        local kind = target == "Weapon" and "Weapon" or "Armor"
        -- Erz-Pool: nutzbarer Bestand (ohne Quest-Bedarf; Favoriten wie bei "Goal: Use Favorite Ores")
        local pool, info = {}, {}
        for name in pairs(data().Inventory) do
            local ore = Ores[name]
            local have = ore and forgeGoal.usable(name) or 0
            if have > 0 and finite(ore.Multiplier) then
                local entry = {name = name, mult = ore.Multiplier, neutral = ore.NeutralMultiplier == true, have = have, traits = ore.Traits}
                table.insert(pool, entry)
                info[name] = entry
            end
        end
        if #pool == 0 then return {error = "No usable ores in your inventory."} end
        local byMult = table.clone(pool)
        table.sort(byMult, function(a, b)
            if a.neutral ~= b.neutral then return not a.neutral end
            if a.mult ~= b.mult then return a.mult > b.mult end
            return a.name < b.name
        end)
        local stock = {}
        for _, ore in ipairs(pool) do table.insert(stock, ore.have) end
        table.sort(stock, function(a, b) return a > b end)
        local maxForgeable = 0
        for i = 1, math.min(#stock, Planner.ForgeOreSlots) do maxForgeable += stock[i] end
        local equipped = data().Equipped or {}
        local refName = Ores.Iron and "Iron" or byMult[1].name
        local refMult = Ores[refName].Multiplier
        local results = {kind = kind, weapons = {}, armor = {}, skipped = {}, quality = quality, station = stationName}
        local classes = {}
        for _, config in ipairs(Rarity[kind] or {}) do
            if config.lock_min_ores and B.matchesSlot(config.name, target) then
                local variants = Rarity:GetAvailableItems(stationName, kind, config.name, data())
                if #variants > 0 then table.insert(classes, {kind = kind, name = config.name, n = config.lock_min_ores, variants = variants}) end
            end
        end
        if #classes == 0 then return {error = "No " .. target:lower() .. " recipes at this forge."} end
        for index, class in ipairs(classes) do
            if progress then progress(string.format("Calculating %d/%d: %s …", index, #classes, forgeGoal.prettyClass(class.name))) end
            if maxForgeable < class.n then
                table.insert(results.skipped, string.format("%s (needs %d ores)", forgeGoal.prettyClass(class.name), class.n))
            else
                local c, rows, weightSum, sample, slot, others = B.classSetup(class, quality, equipped, refName, refMult)
                local job = {n = class.n, info = info, byMult = byMult, sample = sample, baseRunes = B.runesOf(others), traitOres = {}, moves = {}}
                job.score = class.kind == "Weapon" and function(t, avg) return (B.weapon(t, avg, c)) end or function(t, avg) return (B.armor(t, avg, c)) end
                -- Tausch-Kandidaten: die 15 staerksten Erze + alle Erze mit Traits fuer diese Item-Art
                local seen = {}
                for i, ore in ipairs(byMult) do
                    if i <= 15 then table.insert(job.moves, ore); seen[ore.name] = true end
                end
                for _, ore in ipairs(byMult) do
                    local relevant = false
                    for _, trait in ipairs(ore.traits or {}) do
                        if not trait.Whitelist or table.find(trait.Whitelist, class.kind) then relevant = true end
                    end
                    if relevant then
                        table.insert(job.traitOres, ore)
                        if not seen[ore.name] then table.insert(job.moves, ore); seen[ore.name] = true end
                    end
                end
                local best = B.optimize(job)
                if best then
                    local own = Runes:GetCombinedTraits(Runes:GetRunesFromItem({Type = sample, Ores = best.fractions}))
                    local variantList = {}
                    for _, row in ipairs(rows) do
                        table.insert(variantList, {name = row.name, chance = row.w / weightSum * 100})
                    end
                    table.sort(variantList, function(a, b) return a.chance > b.chance end)
                    local entry = {class = class.name, label = forgeGoal.prettyClass(class.name), kind = class.kind, n = class.n, slot = slot,
                        recipe = best.counts, recipeText = B.recipeText(best.counts), avg = best.avg, score = best.score,
                        traits = B.traitList(own), variants = variantList, sample = sample, fractions = best.fractions, quality = quality}
                    if class.kind == "Weapon" then
                        local _, dps, _, hps = B.weapon(best.traits, best.avg, c)
                        local low, high = math.huge, 0
                        for _, row in ipairs(rows) do
                            local damage = forgeGoal.itemDamage({Type = row.name, Quality = quality, Upgrade = 0, Ores = best.fractions, Runes = {}}) or 0
                            low, high = math.min(low, damage), math.max(high, damage)
                        end
                        entry.dps, entry.hps, entry.damageLow, entry.damageHigh = dps, hps, low, high
                        table.insert(results.weapons, entry)
                    else
                        local _, total, ehp = B.armor(best.traits, best.avg, c)
                        local low, high = math.huge, 0
                        for _, row in ipairs(rows) do
                            local hp = forgeGoal.itemHealth({Type = row.name, Quality = quality, Upgrade = 0, Ores = best.fractions, Runes = {}}) or 0
                            low, high = math.min(low, hp), math.max(high, hp)
                        end
                        -- Vergleich mit dem angelegten Teil im selben Slot
                        local current = slot and equipped[slot]
                        if type(current) == "table" and current.Type then
                            local currentTraits = B.traits(job.baseRunes, current)
                            local cc = {hp = forgeGoal.itemHealth(current) or 0, othersHp = c.othersHp}
                            local currentScore, _, currentEhp = B.armor(currentTraits, 1, cc)
                            entry.currentEhp, entry.currentType, entry.currentScore = currentEhp, current.Type, currentScore
                        end
                        entry.total, entry.ehp, entry.hpLow, entry.hpHigh = total, ehp, low, high
                        table.insert(results.armor, entry)
                    end
                end
            end
        end
        table.sort(results.weapons, function(a, b) return a.score > b.score end)
        -- aktuelle Waffe zum Vergleich (gleiche Formel, mit Upgrade-Stufe)
        local weapon = equipped.Weapon
        if type(weapon) == "table" and weapon.Type then
            local damage = forgeGoal.itemDamage(weapon) or 0
            local okSpeed, speed = pcall(Equipment.CalculateAttackSpeed, Equipment, nil, weapon)
            local okTime, baseTime = pcall(Equipment.GetBaseAttackTime, Equipment, Equipment:GetItemBaseType(weapon.Type))
            local hps = okSpeed and okTime and finite(speed) and finite(baseTime) and baseTime > 0 and speed / baseTime or 0
            local others = {}
            for equippedSlot, item in pairs(equipped) do
                if type(item) == "table" and equippedSlot ~= "Pickaxe" and equippedSlot ~= "Weapon" then table.insert(others, item) end
            end
            local _, dps = B.weapon(B.traits(B.runesOf(others), weapon), 1, {dmg = damage, hps = hps, dmgHps = damage * hps})
            results.currentWeapon = {type = weapon.Type, dps = dps}
        end
        -- Ruestung nach Gewinn gegenueber dem angelegten Teil im gewaehlten Slot bewerten.
        local best, bestValue = nil, -math.huge
        for _, entry in ipairs(kind == "Weapon" and results.weapons or results.armor) do
            local value = kind == "Weapon" and entry.score or (entry.score - (entry.currentScore or 0))
            if not best or value > bestValue then best, bestValue = entry, value end
        end
        if not best then return {error = string.format("Up to %d ore types fit in the forge. Your four largest stacks contain %d ores. %s",
            Planner.ForgeOreSlots, maxForgeable, table.concat(results.skipped, ", "))} end
        if kind == "Weapon" then best.current = results.currentWeapon end
        results.best, results.bestValue = best, bestValue
        return results
    end
    bestCraft.target = nil
    function bestCraft.run(target)
        target = target or bestCraft.target
        if not target or not table.find(bestCraft.slots, target) then return end
        bestCraft.target = target
        if bestCraft.running then bestCraft.again = true; return end -- laeuft schon: danach mit neuer Auswahl wiederholen
        bestCraft.running = true
        local function show(state)
            if bestCraft.onUpdate then pcall(bestCraft.onUpdate, state) end
        end
        repeat
            bestCraft.again = false
            local wanted = bestCraft.target
            show({loading = "Calculating the best " .. wanted:lower() .. " from your inventory …"})
            local ok, result = pcall(forgeGoal.asClient, B.compute, wanted, function(text) show({loading = text}) end)
            bestCraft.result = ok and result or {error = "Best Craftable error: " .. tostring(result)}
        until not bestCraft.again
        bestCraft.running = false
        show(bestCraft.result)
    end
    -- Best Possible rechnen (target = "Weapon", "Helmet", "Chestplate", "Leggings") und an die zweite Karte melden
    function bestCraft.runPossible(target)
        target = target or bestCraft.possibleTarget
        if not target then return end
        bestCraft.possibleTarget = target
        if bestCraft.possibleRunning then bestCraft.possibleAgain = true; return end
        bestCraft.possibleRunning = true
        local function show(state)
            if bestCraft.onPossibleUpdate then pcall(bestCraft.onPossibleUpdate, state) end
        end
        repeat
            bestCraft.possibleAgain = false
            local wanted = bestCraft.possibleTarget
            show({loading = "Calculating the best possible " .. wanted:lower() .. " (all obtainable ores) …"})
            local ok, result = pcall(forgeGoal.asClient, B.computePossible, wanted, function(text) show({loading = text}) end)
            bestCraft.possibleResult = ok and result or {error = "Best Possible error: " .. tostring(result)}
        until not bestCraft.possibleAgain
        bestCraft.possibleRunning = false
        show(bestCraft.possibleResult)
    end
    -- "Farm & Craft": festes Rezept als Schmiede-Ziel setzen, Farm-Modus "Forging" und Farmen starten.
    -- Der Modus baut fehlende Erze ab, craftet Zwischen-Erze, reist zu anderen Inseln und schmiedet am Ende.
    function bestCraft.farmPossible()
        local best = bestCraft.possibleResult and bestCraft.possibleResult.best
        if not best then return false, "Nothing calculated yet" end
        forgeGoal.setFixed({class = best.class, recipe = table.clone(best.recipe), label = best.label, kind = best.kind, slot = best.slot, sample = best.sample})
        forgeGoal.attempts, forgeGoal.result, forgeGoal.plan = 0, nil, nil
        local option = api.MenuOptions and api.MenuOptions.ForgeFarmMode
        if api.FarmMode ~= "Forging" then
            if option then pcall(option.SetValue, option, "Forging") end
            api.FarmMode = "Forging"
        end
        api.ForgeGoalActive = true
        api.WantRunning = true
        if not api.Running and not api:Start() then return false, tostring(api.State) end
        return true
    end
    -- Plan fuer den Craft-Knopf: genau dieses Rezept mit Klassen-Sperre schmieden
    function bestCraft.plan()
        local best = bestCraft.result and bestCraft.result.best
        if not best then return nil end
        local count = 0
        for _, k in pairs(best.recipe) do count += k end
        return {itemType = best.sample, recipe = table.clone(best.recipe), count = count, lockClass = best.class, goal = true, label = best.label}
    end
end
-- BEST_CRAFT_END

local lastSale, lastEquip = -60, -5
-- FARM_STEP_START
local function step(token)
    swingState.attacking = false
    if not api.Enabled then return end
    if not report or os.clock() - lastPlan > 12 then api:Refresh() end
    if api.Defending then return end
    if FC.ForgeActive then if stopMiningInput then stopMiningInput() end; destination = nil; log("Forge active; farming paused"); return end
    -- Craft-Knopf bei Best Craftable: zur Schmiede fliegen und genau dieses Rezept mit Klassen-Sperre schmieden
    if api.PendingCraft then
        local plan = api.PendingCraft
        api.PendingCraft = nil
        if stopMiningInput then stopMiningInput() end
        local before = {}
        for _, item in ipairs(data().Inventory.Equipments or {}) do if item.GUID then before[item.GUID] = true end end
        log("Best Craftable: forging " .. tostring(plan.label))
        forgeBusy = true
        local ok, crafted = pcall(craft, token, plan)
        forgeBusy = false
        releaseForge()
        local message
        if not ok then message = "Craft failed: " .. tostring(crafted)
        elseif not crafted then message = "Craft not possible (forge not reachable or ores missing)"
        else
            task.wait(1)
            for _, item in ipairs(data().Inventory.Equipments or {}) do
                if item.GUID and not before[item.GUID] then
                    message = string.format("✔ Crafted %s · quality %.1f%%", tostring(item.Type), item.Quality or 0)
                end
            end
            message = message or "✔ Crafted"
        end
        log("Best Craftable: " .. message)
        if api.BestCraft.onCrafted then pcall(api.BestCraft.onCrafted, message) end
        -- nur fuer den Craft gestartet -> wieder anhalten
        if api.CraftStartedBot then api.CraftStartedBot = false; api:Stop("Best Craftable: " .. message) end
        lastPlan = 0
        return
    end
    -- Auto Sell laeuft in jedem Farm-Modus, sobald der Stash voll genug ist.
    -- Celestial Clash hat Vorrang vor allem anderen (auch Auto Sell und Quests), solange das Event laeuft.
    if api.ClashFocus and clashStep(token) then return end
    if autoSellOres(token) then lastPlan = 0; return end
    -- Farm-Modus "Forging": den Schmiede-Plan abarbeiten (abbauen, umcraften, reisen, mit Klassen-Sperre schmieden)
    if api.FarmMode == "Forging" then
        if api.ForgeGoalActive then
            if forgeGoal.step(token) then lastPlan = 0 else
                -- Nichts zu tun (kein passender Stein, z. B. weil der aktuelle wegen eines Gegners uebersprungen wurde):
                -- altes Ziel loeschen. Vorher flog/baute der Bot am uebersprungenen Stein neben dem Gegner weiter.
                if stopMiningInput then stopMiningInput() end
                destination = nil
            end
        else
            if stopMiningInput then stopMiningInput() end
            destination = nil
            log("Forging: " .. tostring(forgeGoal.result or "goal finished – change the goal (class / target) to forge again"))
        end
        return
    end
    if api.FarmMode == "Kill All Mobs" then
        -- Jeder geladene Gegner, naechster zuerst.
        -- Zentrum = Stelle beim START; bleibt auch nach Tod/Auto Restart gleich.
        api.KillCenter = api.KillCenter or root.Position
        local job = {kind = "Kill", all = true, center = api.KillCenter}
        local target = findTarget(job)
        if target then attack(target, job, token) else
            if stopMiningInput then stopMiningInput() end
            -- Keine Mobs im Radius: zurueck zum Startpunkt statt irgendwo zu schweben.
            followAttack = nil
            destination = (root.Position - api.KillCenter).Magnitude > 3 and CFrame.new(api.KillCenter) or nil
            log("No enemies within " .. api.KillRadius .. " studs of start point")
        end
        return
    end
    if api.FarmMode == "Ores Only" or api.FarmMode == "Mobs Only" then
        local mobs = api.FarmMode == "Mobs Only"
        local selected = mobs and api.SelectedMobs or api.SelectedOres
        if not next(selected) and (mobs or not next(api.SelectedRocks or {})) then api:Stop(mobs and "Mob selection empty; choose mobs" or "Ore / rock selection empty; choose targets"); return end
        local job = {kind = mobs and "Kill" or "SelectedOre", selected = selected, rocks = not mobs and api.SelectedRocks or nil}
        local target = findTarget(job)
        if target then attack(target, job, token) else
            if stopMiningInput then stopMiningInput() end
            destination = nil
            log(mobs and "No attackable mobs loaded nearby" or "No matching rocks loaded or mineable with this pickaxe")
        end
        return
    end
    -- Farm-Modus "Gold": fuer die Ziel-Spitzhacke sparen und kaufen, Ausruestung wechseln/verkaufen,
    -- Upgrades schmieden, sonst Gold abbauen. Keine Quests.
    if api.FarmMode == "Gold" then
        if not report.quote then api:Stop("Unknown target pickaxe: " .. api.TargetPickaxe); return end
        if not report.owned and report.remaining == 0 then
            local vendor = npcAt(api.TargetPickaxe)
            if not vendor then destination = nil; log("Gold goal reached; vendor not loaded on this island"); return end
            if approach(vendor, token) and alive(token) then
                api:Refresh()
                local definition = Proximities.Shop[api.TargetPickaxe]
                if report.remaining == 0 and (not definition.Condition or definition.Condition(player)) then
                    log("Buying " .. api.TargetPickaxe .. " with game gold")
                    await(ProximityService:Purchase(vendor, 1))
                    task.wait(1)
                    api:Refresh()
                    if report.owned then api.WantRunning = false; api:Stop("Goal reached: " .. api.TargetPickaxe) else error("Pickaxe purchase not confirmed") end
                end
            end
            return
        end
        if api.AutoEquip and os.clock() - lastEquip > 5 then
            lastEquip = os.clock()
            if equipUpgrade(token) then lastPlan = 0; return end
        end
        if api.AutoSell and os.clock() - lastSale > 60 then
            lastSale = os.clock()
            -- Erze verkauft autoSellOres (Multiplikator-Regler); hier nur schlechtere Ausruestung.
            if sell(token, report.equipmentSales, true) then lastPlan = 0; return end
        end
        if api.AutoForge and build and (api.CraftRequested or report.owned) then
            local _, reserved = Planner.pending(data(), Definitions, Ores, Rocks)
            if Planner.availableRecipe(build.recipe, data().Inventory, reserved) then
                if not cooldown.Forge or cooldown.Forge < os.clock() then
                    cooldown.Forge = os.clock() + 90
                    forgeBusy = true
                    local ok, why = pcall(craft, token)
                    forgeBusy = false
                    releaseForge()
                    if not ok then error(why) end
                    if why then api.CraftRequested = false end
                    lastPlan = 0
                    return
                end
            else
                -- Fehlende Erze fuer das Upgrade-Rezept abbauen
                for name, amount in pairs(build.recipe) do
                    local missing = amount + (reserved[name] or 0) - (data().Inventory[name] or 0)
                    if missing > 0 then
                        local job = {kind = "Ore", target = name, remaining = missing}
                        local target = findTarget(job)
                        if target then attack(target, job, token); return end
                    end
                end
            end
        end
        if not report.owned then
            local job = {kind = "Gold"}
            local target = findTarget(job)
            if target then attack(target, job, token); return end
        end
        destination = nil
        if stopMiningInput then stopMiningInput() end
        log(report.owned and "Gold: " .. api.TargetPickaxe .. " already owned – choose a new Target Pickaxe" or "Gold: no mineable rocks loaded on this island")
        return
    end
    -- Modus "Quests": NUR Quests (Sparen/Kaufen, Ausruestung und Upgrade-Schmieden macht der Modus "Gold").
    -- Auto Sell und Clash Focus laufen weiter, weil sie eigene Schalter haben.
    -- Neue Quests annehmen (alle 20 s pruefen; bevorzugte zuerst)
    if questTools.accept(token) then return end
    -- Bevorzugte Quests zuerst erledigen, Reihenfolge sonst unveraendert
    local jobs = {}
    for _, job in ipairs(report.jobs) do if job.quest and api.PreferredQuests[job.quest] then table.insert(jobs, job) end end
    for _, job in ipairs(report.jobs) do if not (job.quest and api.PreferredQuests[job.quest]) then table.insert(jobs, job) end end
    for _, job in ipairs(jobs) do
        if job.kind == "Pickup" then
            if questTools.pickup(job, token) then return end
        elseif job.kind == "Talk" then
            local npc = npcAt(job.npc)
            local key = "Talk:" .. tostring(job.quest)
            if npc and (not cooldown[key] or cooldown[key] < os.clock()) then
                -- Bringt das Gespraech nichts (Quest unveraendert), wird die Pause jedes Mal laenger
                -- (30 s, 1, 2, 4 ... max. 15 min) -> kein staendiges Hin- und Herfliegen quer ueber die Karte.
                local function progressKey()
                    local quest = data().Quests[job.quest]
                    if not quest then return "done" end
                    local parts = {}
                    for _, p in ipairs(quest.Progress or {}) do table.insert(parts, tostring(p.currentProgress)) end
                    return table.concat(parts, ",")
                end
                local before = progressKey()
                cooldown[key] = os.clock() + 30
                log("Quest dialogue: " .. npc.Name)
                questDialogue(npc, job, token)
                task.wait(0.5)
                local tries = questTools.talkTries
                if progressKey() == before then
                    tries[key] = (tries[key] or 0) + 1
                    cooldown[key] = os.clock() + math.min(900, 30 * 2 ^ tries[key])
                else
                    tries[key] = nil
                end
                lastPlan = 0
                return
            end
        else
            local target = findTarget(job)
            if target then
                attack(target, job, token)
                return
            end
        end
    end
    -- Quest-Mobart gerade nicht da: die anderen Arten in ihren Spawn-Gebieten toeten, damit sie nachspawnt.
    local mobRespawn = questTools.mobRespawnJob(jobs)
    local mobFiller = mobRespawn and findTarget(mobRespawn)
    if mobFiller then attack(mobFiller, mobRespawn, token); return end
    -- Quest-Steinart gerade nicht da: andere Steine in ihren Spawn-Gebieten abbauen, damit sie nachspawnt.
    -- Taucht sie auf, nimmt die Schleife oben sie sofort (der Quest-Job wird jeden Schritt zuerst geprueft).
    local respawn = questTools.respawnJob(jobs)
    local filler = respawn and findTarget(respawn)
    if filler then attack(filler, respawn, token); return end
    destination = nil
    if stopMiningInput then stopMiningInput() end
    log("Quests: nothing to do on this island right now (no matching mobs/rocks/NPCs loaded)")
end
-- FARM_STEP_END

-- Erz-Bild aus dem Spiel (ReplicatedStorage.Assets.OreIcons.<Name>, dieselben Bilder wie im Inventar).
api.OreIcon = function(name, size)
    local assets = ReplicatedStorage:FindFirstChild("Assets")
    local folder = assets and assets:FindFirstChild("OreIcons")
    local template = folder and folder:FindFirstChild(name)
    if not template then return nil end
    local icon = template:Clone()
    icon.Name, icon.AnchorPoint, icon.Position = "Icon", Vector2.zero, UDim2.new()
    icon.Size, icon.BackgroundTransparency = UDim2.fromOffset(size, size), 1
    -- Die Vorlagen im Spiel sind teils ausgeblendet -> Kopie ausdruecklich sichtbar machen und nach vorne holen.
    icon.Visible, icon.ZIndex = true, 5
    if icon:IsA("ImageLabel") or icon:IsA("ImageButton") then icon.ImageTransparency = 0 end
    for _, child in ipairs(icon:GetDescendants()) do
        if child:IsA("GuiObject") then child.Visible, child.ZIndex = true, 6 end
    end
    for _, child in ipairs(icon:GetDescendants()) do
        if child:IsA("UIAspectRatioConstraint") or child:IsA("UISizeConstraint") then child:Destroy() end
    end
    return icon
end

-- STATS_START
local function oreTotal()
    local total = 0
    for name, count in pairs(data().Inventory) do if Ores[name] and finite(count) then total += count end end
    return total
end
local function resetStats()
    table.clear(stats)
    stats.startTime, stats.goldStart, stats.lastOreTotal = os.clock(), data().Gold or 0, oreTotal()
    stats.oresMined, stats.rocksBroken, stats.kills, stats.sold, stats.soldGold, stats.deaths = 0, 0, 0, 0, 0, 0
end
local function commas(n)
    local s = tostring(math.floor(math.abs(n) + 0.5))
    s = s:reverse():gsub("(%d%d%d)", "%1."):reverse():gsub("^%.", "")
    return (n < 0 and "-" or "") .. s
end
local function updateStats()
    if not stats.startTime then return end
    -- Abgebaute Erze = jede Zunahme im Inventar (Verkaufen/Schmieden senkt die Zahl und wird ignoriert).
    local current = oreTotal()
    if stats.lastOreTotal and current > stats.lastOreTotal then stats.oresMined += current - stats.lastOreTotal end
    stats.lastOreTotal = current
end
local function statsText()
    if not stats.startTime then return "Press START to begin a session." end
    local seconds = os.clock() - stats.startTime
    local hours = math.max(seconds / 3600, 1 / 3600)
    local gold = (data().Gold or 0) - stats.goldStart
    return string.format("Runtime %dh %02dm | Gold %s%s (%s/h)\nOres mined %s (%s/h) | Rocks broken %s\nKills %s (%s/h) | Deaths %s\nAuto Sell: %s ores for %s gold",
        seconds // 3600, (seconds % 3600) // 60, gold >= 0 and "+" or "", commas(gold), commas(gold / hours),
        commas(stats.oresMined), commas(stats.oresMined / hours), commas(stats.rocksBroken),
        commas(stats.kills), commas(stats.kills / hours), commas(stats.deaths),
        commas(stats.sold), commas(stats.soldGold))
end
-- STATS_END

-- Fluent-modded, feste Version: 1593b693e0645fc4a53223a418c0f035faf7cb15 (MIT).
local menu
local function createMenu()
    if type(setIdentity) == "function" then setIdentity(8) end
    local file = "Fluent-modded-1593b693.lua"
    local source
    if type(readfile) == "function" and type(isfile) == "function" and isfile(file) then
        source = readfile(file)
    else
        source = game:HttpGet("https://raw.githubusercontent.com/StyearX/Fluent-modded/1593b693e0645fc4a53223a418c0f035faf7cb15/dist/main.lua")
    end
    local chunk, why = loadstring(source, "FluentModded_1593b693")
    assert(chunk, why)
    local Fluent = chunk()
    assert(type(Fluent) == "table" and type(Fluent.CreateWindow) == "function", "Fluent-modded failed to load")
    -- Echte Maus-/Touch-Callbacks laufen als Client; CoreGui wuerde dort Plugin-Rechte verlangen.
    for index, screen in ipairs({Fluent.GUI, Fluent.ScrollGUI, Fluent.PopupGUI}) do
        screen.Parent = player:WaitForChild("PlayerGui")
        screen.ResetOnSpawn = false
        screen.DisplayOrder = 10000 + index
    end
    local nativeDestroy = Fluent.Destroy
    api.DestroyMenu = function()
        if type(setIdentity) == "function" then setIdentity(8) end
        local popup = Fluent.PopupGUI
        local ok, err = pcall(nativeDestroy, Fluent)
        if popup and popup.Parent then popup:Destroy() end
        if type(setIdentity) == "function" then setIdentity(2) end
        if not ok then warn("[ForgeHelper] Closing Fluent: " .. tostring(err)) end
    end
    Fluent.Destroy = function() api:Destroy() end
    Fluent:SetErrorHandler(function(message)
        api.LastError = tostring(message)
        warn("[ForgeHelper] Menu: " .. tostring(message))
    end)
    local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1000, 800)
    -- Eigenes Theme "Forge Green": sehr dunkler, leicht gruener Hintergrund mit gruenen Akzenten (wie die Vorlage)
    local themeName = "Charcoal"
    pcall(function()
        local g, dark = Color3.fromRGB(34, 197, 94), Color3.fromRGB(14, 17, 15)
        local registered = Fluent:RegisterCustomTheme("Forge Green", {
            Accent = g, AcrylicMain = dark, AcrylicBorder = Color3.fromRGB(38, 54, 45),
            AcrylicGradient = ColorSequence.new(Color3.fromRGB(18, 22, 20), Color3.fromRGB(10, 12, 11)), AcrylicNoise = 1,
            TitleBarLine = Color3.fromRGB(30, 70, 46), Tab = Color3.fromRGB(26, 34, 30),
            Element = Color3.fromRGB(22, 27, 24), ElementBorder = Color3.fromRGB(40, 52, 45), InElementBorder = Color3.fromRGB(32, 42, 36),
            ElementTransparency = 0.05, ToggleSlider = g, ToggleToggled = Color3.fromRGB(8, 10, 9), SliderRail = Color3.fromRGB(48, 60, 53),
            CheckboxUnchecked = Color3.fromRGB(48, 60, 53), CheckboxChecked = g, CheckboxCheck = Color3.fromRGB(8, 10, 9),
            ProgressBarRail = Color3.fromRGB(48, 60, 53), ProgressBarFill = g,
            DropdownFrame = Color3.fromRGB(22, 27, 24), DropdownHolder = Color3.fromRGB(16, 20, 18), DropdownBorder = Color3.fromRGB(40, 52, 45),
            DropdownOption = g, Keybind = Color3.fromRGB(22, 27, 24), Input = Color3.fromRGB(18, 22, 20), InputFocused = Color3.fromRGB(12, 15, 13),
            InputIndicator = g, Dialog = Color3.fromRGB(18, 22, 20), DialogHolder = Color3.fromRGB(14, 17, 15), DialogHolderLine = Color3.fromRGB(10, 12, 11),
            DialogButton = Color3.fromRGB(22, 27, 24), DialogButtonBorder = Color3.fromRGB(40, 52, 45), DialogBorder = Color3.fromRGB(40, 52, 45),
            DialogInput = Color3.fromRGB(22, 27, 24), DialogInputLine = g, Text = Color3.fromRGB(240, 245, 242), SubText = Color3.fromRGB(160, 178, 168),
            IconColor = Color3.fromRGB(185, 210, 195), Hover = g, HoverChange = 0.05, ShineEnabled = false, StrokeShine = false,
            StrokeDark = Color3.fromRGB(40, 52, 45),
        })
        if registered ~= false then themeName = "Forge Green" end
    end)
    local window = Fluent:CreateWindow({
        Title = "THE FORGE", SubTitle = "Progression Helper", TabWidth = viewport.X < 600 and 120 or 155,
        Size = UDim2.fromOffset(math.max(340, math.min(740, viewport.X - 32)), math.max(340, math.min(580, viewport.Y - 60))),
        Acrylic = false, Theme = themeName, MinimizeKey = Enum.KeyCode[api.MenuKey],
        ScreenGuiName = "ForgeProgressionHelper", Search = true, Animated = false,
    })
    api.Gui, api.Fluent, api.MenuWindow = Fluent.GUI, Fluent, window
    local titlebar = window.TitleBar.Frame
    titlebar.Active = true
    -- Der native Fluent-Handler verliert schnelle Mausbewegungen ausserhalb der Titelleiste.
    if type(getconnections) == "function" then
        for _, signal in ipairs({titlebar.InputBegan, titlebar.InputChanged}) do
            for _, connection in ipairs(getconnections(signal)) do connection:Disable() end
        end
    end
    local drag = Instance.new("UIDragDetector")
    drag.Name = "ForgeWindowDrag"
    drag.ResponseStyle = Enum.UIDragDetectorResponseStyle.CustomOffset
    drag.Parent = titlebar
    local dragStart, windowStart
    track(drag.DragStart:Connect(function(position)
        if window.Maximized then window.Maximize(false, true, true) end
        dragStart, windowStart = position, window.Root.Position
    end))
    track(drag.DragContinue:Connect(function(position)
        if dragStart then
            local delta = position - dragStart
            window.Position = windowStart + UDim2.fromOffset(delta.X, delta.Y)
            window.Root.Position = window.Position
        end
    end))
    track(drag.DragEnd:Connect(function() dragStart = nil end))
    if type(savedWindow) == "table" and finite(savedWindow.x) and finite(savedWindow.y) and finite(savedWindow.width) and finite(savedWindow.height) then
        local width = math.clamp(savedWindow.width, 340, math.max(340, viewport.X - 32))
        local height = math.clamp(savedWindow.height, 340, math.max(340, viewport.Y - 60))
        local x = math.clamp(savedWindow.x, 8, math.max(8, viewport.X - width - 8))
        local y = math.clamp(savedWindow.y, 8, math.max(8, viewport.Y - height - 8))
        window.Size, window.Position = UDim2.fromOffset(width, height), UDim2.fromOffset(x + width * window.Root.AnchorPoint.X, y + height * window.Root.AnchorPoint.Y)
        window.Root.Size, window.Root.Position = window.Size, window.Position
        if savedWindow.maximized == true then window.Maximize(true, true, true) end
    end
    local function headerButton(name, text, width, right)
        local button = Instance.new("TextButton")
        button.Name, button.Text, button.Font, button.TextSize = name, text, Enum.Font.GothamBold, 12
        button.AnchorPoint, button.Position = Vector2.new(1, 0), UDim2.new(1, -right, 0, 4)
        button.Size, button.BackgroundColor3 = UDim2.new(0, width, 1, -8), Color3.fromRGB(30, 37, 33)
        button.TextColor3, button.BorderSizePixel, button.ZIndex = Color3.fromRGB(245, 245, 245), 0, titlebar.ZIndex + 5
        local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 6); corner.Parent = button
        local stroke = Instance.new("UIStroke"); stroke.Color, stroke.Thickness, stroke.Parent = Color3.fromRGB(48, 62, 54), 1, button
        stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        button.Parent = titlebar
        return button
    end
    api.MasterButton = headerButton("ForgeMasterToggle", "START  ○", 76, 118)
    api.SaveButton = headerButton("ForgeSaveSettings", "SAVE", 46, 198)
    local titleStack = titlebar:FindFirstChild("TitleTextStack", true)
    if titleStack and titleStack.Parent:IsA("GuiObject") then
        titleStack.Parent.Size = UDim2.new(1, -334, 1, 0)
        titleStack.Parent.ClipsDescendants = true
    end
    api.UpdateMasterButton = function()
        local on = api.Enabled or (api.AutoRestart and api.WantRunning)
        api.MasterButton.Text = on and "STOP  ●" or "START  ○"
        api.MasterButton.BackgroundColor3 = on and Color3.fromRGB(26, 140, 72) or Color3.fromRGB(30, 37, 33)
        local stroke = api.MasterButton:FindFirstChildOfClass("UIStroke")
        if stroke then stroke.Color = on and Color3.fromRGB(74, 222, 128) or Color3.fromRGB(48, 62, 54) end
    end
    track(api.MasterButton.Activated:Connect(function()
        if api.Enabled or (api.AutoRestart and api.WantRunning) then
            api.WantRunning = false
            api:Stop("Master automation stopped")
        else
            api.WantRunning, api.KillCenter = true, nil
            resetStats()
            api:Start()
        end
        api.UpdateMasterButton()
    end))
    -- Celestial-Clash-Schalter mit dem Event-Symbol des Spiels, direkt rechts neben dem Titel.
    local clashButton = Instance.new("ImageButton")
    clashButton.Name, clashButton.Image, clashButton.ScaleType = "ForgeClashFocus", "rbxassetid://76675518651391", Enum.ScaleType.Fit
    clashButton.Size, clashButton.Position = UDim2.new(0, 28, 1, -8), UDim2.new(1, -314, 0, 4)
    clashButton.BorderSizePixel, clashButton.ZIndex, clashButton.AutoButtonColor = 0, titlebar.ZIndex + 5, true
    Instance.new("UICorner", clashButton).CornerRadius = UDim.new(0, 5)
    local clashStroke = Instance.new("UIStroke", clashButton)
    clashStroke.Thickness, clashStroke.Color = 1.5, Color3.fromRGB(255, 200, 90)
    clashButton.Parent = titlebar
    api.ClashButton = clashButton
    -- Flug-Schalter (selbst fliegen) direkt rechts neben dem Clash-Schalter
    local flyButton = Instance.new("TextButton")
    flyButton.Name, flyButton.Text, flyButton.Font, flyButton.TextSize = "ForgeManualFly", "✈", Enum.Font.GothamBold, 18
    flyButton.Size, flyButton.TextColor3, flyButton.BorderSizePixel = UDim2.new(0, 28, 1, -8), Color3.fromRGB(240, 240, 240), 0
    flyButton.ZIndex, flyButton.AutoButtonColor = titlebar.ZIndex + 5, true
    Instance.new("UICorner", flyButton).CornerRadius = UDim.new(0, 5)
    local flyStroke = Instance.new("UIStroke", flyButton)
    flyStroke.Thickness, flyStroke.Color, flyStroke.ApplyStrokeMode = 1.5, Color3.fromRGB(110, 200, 255), Enum.ApplyStrokeMode.Border
    flyButton.Parent = titlebar
    api.FlyButton = flyButton
    track(flyButton.Activated:Connect(function()
        api.ManualFly = not api.ManualFly
        log(api.ManualFly and "Manual fly ON: W/A/S/D, Space up, Ctrl/Q down (only while the bot is not farming)" or "Manual fly OFF")
        api.UpdateClashButton()
    end))
    api.UpdateClashButton = function()
        local on = api.ClashFocus == true
        clashButton.BackgroundColor3 = on and Color3.fromRGB(150, 105, 30) or Color3.fromRGB(55, 55, 60)
        clashButton.ImageTransparency, clashStroke.Enabled = on and 0 or 0.45, on
        flyButton.BackgroundColor3 = api.ManualFly and Color3.fromRGB(35, 110, 160) or Color3.fromRGB(55, 55, 60)
        flyButton.TextTransparency, flyStroke.Enabled = api.ManualFly and 0 or 0.35, api.ManualFly == true
        -- Position: hinter dem Titeltext (THE FORGE  Progression Helper), sonst links neben SAVE.
        local stack = titlebar:FindFirstChild("TitleTextStack", true)
        if stack and stack:IsA("GuiObject") then
            local right = stack.AbsolutePosition.X
            for _, label in ipairs(stack:GetDescendants()) do
                if label:IsA("TextLabel") and label.Visible and label.Text ~= "" then
                    right = math.max(right, label.AbsolutePosition.X + label.TextBounds.X)
                end
            end
            local x = right - titlebar.AbsolutePosition.X + 10
            if x > 20 and x < titlebar.AbsoluteSize.X - 324 then clashButton.Position = UDim2.new(0, x, 0, 4) end
        end
        flyButton.Position = clashButton.Position + UDim2.fromOffset(34, 0)
    end
    track(clashButton.Activated:Connect(function()
        api.ClashFocus = not api.ClashFocus
        activeTarget, activeJob, destination, followAttack = nil, nil, nil, nil
        log(api.ClashFocus and "Clash Focus ON: during Celestial Clash everything else is ignored" or "Clash Focus OFF")
        api.UpdateClashButton()
    end))
    track(api.SaveButton.Activated:Connect(function()
        local ok = api:SaveSettings()
        api.SaveButton.Text = ok and "SAVED" or "ERROR"
        task.delay(1.5, function() if not destroyed then api.SaveButton.Text = "SAVE" end end)
    end))
    api.MenuOptions = Fluent.Options
    local tabs = {
        Main = window:AddTab({Title = "Overview", Icon = "home"}),
        Farm = window:AddTab({Title = "Farming & Distance", Icon = "sprout"}),
        Gear = window:AddTab({Title = "Selling & Equipment", Icon = "coins"}),
        Combat = window:AddTab({Title = "Combat", Icon = "swords"}),
        Forge = window:AddTab({Title = "Forging", Icon = "anvil"}),
        Visuals = window:AddTab({Title = "Visuals", Icon = "image"}),
        Quests = window:AddTab({Title = "Quests", Icon = "trophy"}),
    }
    api.MenuTabs = tabs
    menu = {
        Status = tabs.Main:AddParagraph({Title = "Status", Content = "Reading game state ..."}),
        World = tabs.Main:AddParagraph({Title = "Current World", Content = "Detecting world ..."}),
        Gold = tabs.Main:AddParagraph({Title = "Savings Goal (Gold mode)", Content = "Calculating price ..."}),
        Stats = tabs.Main:AddParagraph({Title = "Statistics (since START)", Content = "Press START to begin a session."}),
    }
    tabs.Main:AddDropdown("ForgeFarmMode", {
        Title = "Farm Mode", Values = {"Ores Only", "Mobs Only", "Kill All Mobs", "Quests", "Gold", "Forging"}, Default = api.FarmMode,
        Description = "Quests = only quests. Gold = save for the Target Pickaxe and buy it, equip / sell / craft upgrades. Forging = works through the Goal Plan from the Forging tab.",
        Callback = function(value)
            if (value == "Ores Only" or value == "Mobs Only" or value == "Kill All Mobs" or value == "Quests" or value == "Gold" or value == "Forging") and value ~= api.FarmMode then
                api.ForgeGoalActive = value == "Forging"
                forgeGoal.attempts, forgeGoal.result = 0, nil
                api:Stop("Farm mode changed; enable farming again")
                api.FarmMode, lastPlan, api.KillCenter = value, 0, nil
                activeTarget, activeJob, destination = nil, nil, nil
            end
        end,
    })
    tabs.Main:AddToggle("ForgeAutoRejoin", {
        Title = "Auto Rejoin", Default = api.AutoRejoin,
        Description = "Rejoins after a kick or disconnect and reloads workspace/ForgeHelper.lua. If farming was running, it resumes automatically.",
        Callback = function(value) api.AutoRejoin = value end,
    })
    tabs.Main:AddToggle("ForgeAntiAfk", {
        Title = "Anti AFK", Default = api.AntiAfk,
        Description = "Prevents the 20 minute idle kick.",
        Callback = function(value) api.AntiAfk = value end,
    })
    tabs.Main:AddToggle("ForgeAutoRestart", {
        Title = "Auto Restart (Persistent)", Default = api.AutoRestart,
        Description = "Keeps farming running: restarts after death, errors or internal stops until you press STOP.",
        Callback = function(value) api.AutoRestart = value end,
    })
    -- Eigene Taste zum Ein-/Ausblenden des Menues.
    local menuKeybind = tabs.Main:AddKeybind("ForgeMenuKey", {
        Title = "Menu Toggle Key", Mode = "Toggle", Default = api.MenuKey,
        Description = "Click, then press a key. Press SAVE to keep it.",
        ChangedCallback = function(key)
            if typeof(key) == "EnumItem" and table.find(Enum.KeyCode:GetEnumItems(), key) then
                api.MenuKey, Fluent.MinimizeKey = key.Name, key
            end
        end,
    })
    Fluent.MinimizeKeybind = menuKeybind
    -- Target Pickaxe: alle kaufbaren Spitzhacken (Shop des Spiels) als Liste mit Bild, sortiert nach Mine Power.
    -- Das Spiel hat fuer Spitzhacken kein 2D-Bild, nur das 3D-Modell (Assets.Equipments.Pickaxes.<Name>)
    -- -> das Modell wird in einem kleinen ViewportFrame neben dem Namen gezeigt.
    -- 3D-Modell aus dem Spiel als Bild (ViewportFrame); fuer Spitzhacken, Waffen und Ruestungen
    local function modelViewport(model, size, name)
        local viewport = Instance.new("ViewportFrame")
        viewport.Name, viewport.BackgroundTransparency = name or "ModelIcon", 1
        viewport.Size = size and UDim2.fromOffset(size, size) or UDim2.fromScale(1, 1)
        viewport.Ambient, viewport.LightColor, viewport.LightDirection = Color3.fromRGB(190, 190, 190), Color3.new(1, 1, 1), Vector3.new(-1, -1, -1)
        for _, object in ipairs(model:GetDescendants()) do
            if object:IsA("BaseScript") or object:IsA("Sound") or object:IsA("ParticleEmitter") or object:IsA("BillboardGui") then object:Destroy() end
        end
        model.Parent = viewport
        local center, extents = model:GetBoundingBox()
        local camera = Instance.new("Camera")
        camera.FieldOfView = 30
        local distance = extents.Magnitude / 2 / math.tan(math.rad(15))
        local direction = (center.RightVector + center.LookVector * 0.35 + center.UpVector * 0.25).Unit
        camera.CFrame = CFrame.lookAt(center.Position + direction * distance, center.Position, center.UpVector)
        camera.Parent = viewport
        viewport.CurrentCamera = camera
        return viewport
    end
    local function pickaxeViewport(name, size)
        local equipments = ReplicatedStorage:FindFirstChild("Assets") and ReplicatedStorage.Assets:FindFirstChild("Equipments")
        local folder = equipments and equipments:FindFirstChild("Pickaxes")
        local template = folder and folder:FindFirstChild(name)
        if not (template and template:IsA("Model")) then return nil end
        return modelViewport(template:Clone(), size, "PickaxeIcon")
    end
    local pickaxeValues, pickaxeByLabel, pickaxeDefault = {}, {}, nil
    do
        local list = {}
        for name, item in pairs(Equipment.Items.Pickaxe or {}) do
            local shop = Proximities.Shop[name]
            if shop and finite(shop.Price) then table.insert(list, {name = name, power = item["Mine Power"] or 0, price = shop.Price, locked = shop.LockedText}) end
        end
        table.sort(list, function(a, b)
            if a.power ~= b.power then return a.power < b.power end
            return a.name < b.name
        end)
        local ownedSet = {}
        for _, item in ipairs(data().Inventory.Equipments or {}) do if item.Name then ownedSet[item.Name] = true end end
        for _, entry in ipairs(list) do
            local label = string.format("%s · %d power · %s gold%s", entry.name, entry.power, commas(entry.price),
                ownedSet[entry.name] and " · ✓ owned" or (entry.locked and " · 🔒" or ""))
            table.insert(pickaxeValues, label)
            pickaxeByLabel[label] = entry.name
            if entry.name == api.TargetPickaxe then pickaxeDefault = label end
        end
    end
    local pickaxeOption = tabs.Main:AddDropdown("ForgePickaxeGoal", {
        Title = "Target Pickaxe (Gold mode)", Values = pickaxeValues, Default = pickaxeDefault, Search = true,
        Description = "Farm Mode \"Gold\" saves for this pickaxe and buys it. Sorted by Mine Power.",
        Callback = function(value)
            local name = pickaxeByLabel[value]
            if name and name ~= api.TargetPickaxe then api.TargetPickaxe, lastPlan = name, 0 end
        end,
    })
    do -- Bilder in die Eintraege setzen (Fluent baut die Liste neu, z. B. bei der Suche)
        local buildPickaxeList = pickaxeOption.BuildDropdownList
        pickaxeOption.BuildDropdownList = function(self, ...)
            buildPickaxeList(self, ...)
            for button in pairs(self.Buttons) do
                local label = button:FindFirstChild("ButtonLabel")
                local name = label and pickaxeByLabel[label.Text]
                if name and not button:FindFirstChild("PickaxeIcon") then
                    local icon = pickaxeViewport(name, 24)
                    if icon then
                        icon.AnchorPoint, icon.Position, icon.ZIndex = Vector2.new(0, 0.5), UDim2.new(0, 6, 0.5, 0), label.ZIndex
                        icon.Parent = button
                        label.Position = label.Position + UDim2.fromOffset(26, 0)
                        label.Size = label.Size - UDim2.fromOffset(26, 0)
                    end
                    label.TextScaled = true
                    local fit = label:FindFirstChild("FitText") or Instance.new("UITextSizeConstraint")
                    fit.Name, fit.MaxTextSize, fit.MinTextSize, fit.Parent = "FitText", 14, 9, label
                end
            end
            -- Aufklapp-Fenster breiter (Name + Werte passen sonst nicht in 218 px)
            local anyButton = next(self.Buttons)
            local holder = anyButton and anyButton.Parent and anyButton.Parent.Parent and anyButton.Parent.Parent.Parent
            if holder and holder:IsA("GuiObject") and holder.Size.X.Offset < 380 then
                holder.Size = UDim2.new(holder.Size.X.Scale, 380, holder.Size.Y.Scale, holder.Size.Y.Offset)
            end
        end
        pickaxeOption:BuildDropdownList()
    end
    local function addTargetDropdown(flag, title, choices, setting, powers)
        local values, defaults, names = {}, {}, {}
        local color = ({"#E8C76A", "#6FDF9A", "#75BFFF", "#E890D5"})[currentWorld] or "#AAAAAA"
        for _, name in ipairs(Planner.sortedChoices(choices, powers)) do
            local label = Planner.worldLabel(name, currentWorld)
            if powers then label ..= string.format(" — %g×", Planner.orePower(name, powers)) end
            names[label] = name
            table.insert(values, label)
            if api[setting][name] then table.insert(defaults, label) end
        end
        local option = tabs.Farm:AddDropdown(flag, {
            Title = title, Values = values, Multi = true, AllowNull = true, Search = true, Default = defaults,
            Callback = function(value)
                local selected = {}
                for label, checked in pairs(value) do if checked == true and names[label] then selected[names[label]] = true end end
                api[setting] = selected
                activeTarget, activeJob, destination, followAttack, lastPlan = nil, nil, nil, nil, 0
                if api.Enabled and not api.Running then api:Start() end
            end,
        })
        local buildList = option.BuildDropdownList
        local widenedHolder
        option.BuildDropdownList = function(self, ...)
            buildList(self, ...)
            local widest, anyButton = 0, nil
            for button in pairs(self.Buttons) do
                local label = button:FindFirstChild("ButtonLabel")
                if label then
                    label.RichText = true
                    label.Text = label.Text:gsub("^(%[[IVX?]+%])", '<font color="' .. color .. '">%1</font>')
                    widest, anyButton = math.max(widest, label.TextBounds.X), button
                    -- falls ein Name trotzdem nicht passt: Schrift verkleinern statt abschneiden
                    label.TextScaled = true
                    local fit = label:FindFirstChild("FitText") or Instance.new("UITextSizeConstraint")
                    fit.Name, fit.MaxTextSize, fit.MinTextSize, fit.Parent = "FitText", 15, 9, label
                end
            end
            -- Aufklapp-Fenster (fest 218 px) so breit machen wie der laengste Eintrag (max. 380 px)
            local holder = anyButton and anyButton.Parent and anyButton.Parent.Parent and anyButton.Parent.Parent.Parent
            if holder and holder:IsA("GuiObject") then
                local width = math.clamp(widest + 70, 218, 380)
                local function widen()
                    if holder.Size.X.Offset ~= width then holder.Size = UDim2.new(holder.Size.X.Scale, width, holder.Size.Y.Scale, holder.Size.Y.Offset) end
                end
                widen()
                if widenedHolder ~= holder then
                    widenedHolder = holder
                    track(holder:GetPropertyChangedSignal("Size"):Connect(widen)) -- Fluent setzt die Groesse beim Oeffnen neu
                end
            end
        end
        option:BuildDropdownList()
    end
    addTargetDropdown("ForgeSelectedOres", "Select Ores · Forge Power ↓", availableOres, "SelectedOres", Ores)
    addTargetDropdown("ForgeSelectedRocks", "Select Rocks", availableRocks, "SelectedRocks")
    addTargetDropdown("ForgeSelectedMobs", "Select Mobs", availableMobs, "SelectedMobs")
    tabs.Farm:AddParagraph({Title = "Rock Filter", Content = "Ores Only: combine ore and rock selections, or leave ores empty to mine only the selected rock types."})
    local function resetRange() rangeMisses, lastRangeAdjust = 0, os.clock() end
    tabs.Farm:AddSlider("ForgeMobDepth", {
        Title = "Depth Below Mobs (studs)", Default = api.MobDepth, Min = 1.5, Max = 12, Rounding = 1,
        Description = "Vertical distance below the mob.",
        Callback = function(value)
            Planner.setDepth(api, "MobDepth", value)
            resetRange()
        end,
    })
    tabs.Farm:AddSlider("ForgeOreDepth", {
        Title = "Height Above Ores (studs)", Default = api.OreDepth, Min = 0, Max = 12, Rounding = 1,
        Description = "Height above the rock hitbox (0 = on top of the rock). Editing disables automatic range.",
        Callback = function(value)
            Planner.setDepth(api, "OreDepth", value)
            resetRange()
        end,
    })
    tabs.Farm:AddToggle("ForgeAutoRange", {
        Title = "Automatic Range", Default = api.AutoRange,
        Description = "Reduce distance when needed. Keep standing height above rocks. Editing a slider disables this.",
        Callback = function(value) api.AutoRange = value; resetRange() end,
    })
    tabs.Farm:AddToggle("ForgeNoclip", {
        Title = "Noclip", Default = api.Noclip,
        Callback = function(value) api.Noclip = value; if not value and not api.Running then restoreCollisions() end end,
    })
    tabs.Farm:AddSlider("ForgeKillRadius", {
        Title = "Kill All Radius (studs)", Default = api.KillRadius, Min = 20, Max = 500, Rounding = 0,
        Description = "Kill All Mobs only attacks mobs within this distance of where you pressed START.",
        Callback = function(value)
            local radius = tonumber(value)
            if finite(radius) then api.KillRadius = math.clamp(radius, 20, 500) end
        end,
    })
    tabs.Farm:AddToggle("ForgeRareFirst", {
        Title = "Rare Ores First", Default = api.RareFirst,
        Description = "Mine rocks with the highest ore multiplier first (only selected ores count), even if they are farther away.",
        Callback = function(value)
            api.RareFirst = value
            activeTarget, activeJob = nil, nil
        end,
    })
    tabs.Farm:AddToggle("ForgeSkipEnemies", {
        Title = "Skip Rocks Near Enemies", Default = api.SkipNearEnemies,
        Description = "Skips rocks with an enemy within the radius below (also while mining) and locks them for 3 minutes.",
        Callback = function(value) api.SkipNearEnemies = value end,
    })
    tabs.Farm:AddSlider("ForgeEnemySkipRadius", {
        Title = "Enemy Skip Radius (studs)", Default = api.EnemySkipRadius, Min = 5, Max = 60, Rounding = 0,
        Description = "Distance at which an enemy counts as 'near' a rock. Default 20.",
        Callback = function(value)
            local radius = tonumber(value)
            if finite(radius) then api.EnemySkipRadius = math.clamp(radius, 5, 60) end
        end,
    })
    tabs.Gear:AddToggle("ForgeAutoSell", {
        Title = "Auto Sell", Default = api.AutoSell,
        Description = "Works in every farm mode. When the stash is full, flies to Greedy Cey and sells ores below the multiplier set below. Favorites and quest ores are always kept.",
        Callback = function(value) api.AutoSell = value end,
    })
    tabs.Gear:AddSlider("ForgeSellBelowMultiplier", {
        Title = "Sell Ores Below Multiplier", Default = api.SellBelowMultiplier, Min = 0, Max = 30, Rounding = 1,
        Description = "Every ore with a LOWER multiplier gets sold (e.g. 5 = sells 4.7×, keeps 5×). 0 = sell nothing.",
        Callback = function(value)
            local multiplier = tonumber(value)
            if finite(multiplier) then api.SellBelowMultiplier = math.clamp(multiplier, 0, 30) end
        end,
    })
    tabs.Gear:AddSlider("ForgeSellAtStash", {
        Title = "Sell When Stash Is Full (%)", Default = api.SellAtStashPercent, Min = 50, Max = 100, Rounding = 0,
        Description = "Uses the in-game stash counter (e.g. 166 / 494). 100 = only when completely full.",
        Callback = function(value)
            local percent = tonumber(value)
            if finite(percent) then api.SellAtStashPercent = math.clamp(percent, 50, 100) end
        end,
    })
    tabs.Gear:AddToggle("ForgeAutoEquip", {
        Title = "Auto Equip Upgrades", Default = api.AutoEquip,
        Description = "Only in Farm Mode \"Gold\": equips better gear (with Auto Sell on, worse gear is sold too).",
        Callback = function(value) api.AutoEquip = value end,
    })
    tabs.Combat:AddToggle("ForgeFastAttack", {
        Title = "Fast Attack", Default = api.FastAttack,
        Description = "Attack / mine every frame instead of every 0.15 s. Capped by your weapon's attack speed.",
        Callback = function(value) api.FastAttack = value end,
    })
    tabs.Combat:AddToggle("ForgeAutoBlock", {
        Title = "Auto Perfect Block", Default = api.AutoBlock,
        Description = "Equip your weapon for incoming melee warnings, parry, then restore your previous tool. Skips unblockable warnings.",
        Callback = function(value)
            api.AutoBlock = value
            if not value then releaseBlock() end
        end,
    })
    do -- Forging tab
        local goalSection = tabs.Forge:AddCollapsibleSection({Title = "Plan a specific item", Icon = "target"})
        -- Schmiede-Ziel: Klasse (Waffe oder Ruestung) + Zielwert -> Rezept berechnen, Erze besorgen, mit Klassen-Sperre schmieden
        local classValues, classByLabel, classDefault = {}, {}, nil
        for _, class in ipairs(forgeGoal.classes()) do
            -- Klassen aller freigeschalteten Inseln; steht die Schmiede woanders, wird die Insel dazugeschrieben
            local label = string.format("%s · %s (%d ores)%s", class.kind, class.label, class.lock, class.here and "" or (" · Island " .. class.island))
            table.insert(classValues, label)
            classByLabel[label] = class.name
            if class.name == api.GoalClass then classDefault = label end
        end
        local metricLabels = {Damage = "Damage per hit (like theforge.gg)", DPS = "DPS (damage × attack speed)"}
        local metricByLabel = {[metricLabels.Damage] = "Damage", [metricLabels.DPS] = "DPS"}
        local function goalChanged()
            forgeGoal.attempts, forgeGoal.result = 0, nil
            api.ForgeGoalActive = api.FarmMode == "Forging" -- neues Ziel -> im Modus Forging wieder loslegen
            if api.GoalFixed then forgeGoal.setFixed(nil) end -- eigenes Ziel ersetzt ein gestartetes "Best Possible"
            forgeGoal.plan = nil -- die Status-Schleife rechnet innerhalb einer Sekunde neu
        end
        goalSection:AddDropdown("ForgeGoalClass", {
            Title = "Item class", Values = classValues, Default = classDefault, Search = true,
            Description = "Weapons and armor. The class gets locked (100 %) with this many ores; the variant inside the class is random.",
            Callback = function(value)
                local className = classByLabel[value] or ""
                if className == api.GoalClass then return end -- auch beim Aufbau des Menues: nichts aendern
                api.GoalClass = className
                goalChanged()
                forgeGoal.refresh(true)
            end,
        })
        goalSection:AddDropdown("ForgeGoalMetric", {
            Title = "Weapon stat", Values = {metricLabels.Damage, metricLabels.DPS}, Default = metricLabels[api.GoalMetric],
            Description = "What the target value means for weapons. Armor goals always use Health.",
            Callback = function(value)
                local metric = metricByLabel[value]
                if metric and metric ~= api.GoalMetric then api.GoalMetric = metric; goalChanged() end
            end,
        })
        goalSection:AddInput("ForgeGoalTarget", {
            -- Finished = false: der Wert zaehlt sofort beim Tippen (vorher nur nach Enter -> blieb ohne Enter auf 0).
            Title = "Target damage, DPS or health", Default = api.GoalTarget > 0 and tostring(api.GoalTarget) or "", Numeric = true, Finished = false,
            Description = "Damage or DPS for weapons, Health for armor – planned so that even the weakest variant reaches it.",
            Callback = function(value)
                local target = tonumber(value)
                if finite(target) and target > 0 and target ~= api.GoalTarget then
                    api.GoalTarget = target
                    goalChanged()
                end
            end,
        })
        goalSection:AddParagraph({Title = "Run the plan", Content = "Select Forging under Overview → Farm Mode, then press START. Follow progress here or above QUESTS."})
        menu.GoalPlan = goalSection:AddParagraph({Title = "Recipe and progress", Content = "Choose an item class and a target value."})
        -- Rezept als Liste: [Erz-Bild] Name  Multiplikator   Bestand / Bedarf   Status
        local goalList = Instance.new("Frame")
        goalList.Name, goalList.BackgroundTransparency = "ForgeGoalList", 1
        goalList.Size, goalList.AutomaticSize = UDim2.new(1, 0, 0, 0), Enum.AutomaticSize.Y
        local order = (goalSection._elementCount or 0) + 1
        goalSection._elementCount, goalList.LayoutOrder = order, order -- direkt unter "Goal Plan", vor dem naechsten Element
        local goalLayout = Instance.new("UIListLayout", goalList)
        goalLayout.Padding, goalLayout.SortOrder = UDim.new(0, 4), Enum.SortOrder.LayoutOrder
        goalList.Parent = goalSection.Container
        local lastSignature
        -- Zeilen des Schmiede-Plans: {name, title, sub, count, status, ok}; Abschnitte: Rezept, Abbauen, Craften.
        -- Genutzt von der Liste im Forging-Tab und von der Anzeige ueber der Quest-Liste (Goal HUD).
        api.GoalEntries = function(plan)
            local entries = {}
            if plan and plan.recipe then
                local craftedTop = {}
                for _, step in ipairs(plan.crafts or {}) do craftedTop[step.ore] = (craftedTop[step.ore] or 0) + step.amount end
                local recipeRows = {}
                for oreName, needed in pairs(plan.recipe) do
                    -- "have" wie der Planer: ohne Favoriten und Quest-Bedarf
                    local have = needed - (plan.missing[oreName] or 0)
                    local status
                    if have >= needed then status = "✓ ready"
                    elseif craftedTop[oreName] then status = string.format("craft %d", craftedTop[oreName])
                    elseif (plan.waiting or {})[oreName] then status = "crafting…"
                    else status = string.format("mine %d", needed - have) end
                    table.insert(recipeRows, {name = oreName, title = oreName, ok = have >= needed, count = string.format("%d / %d", have, needed), status = status,
                        sub = string.format("%g× multiplier%s", Planner.orePower(oreName, Ores), not api.GoalUseFavorites and (data().Favorites or {})[oreName] and " · favorites not used" or "")})
                end
                table.sort(recipeRows, function(a, b) return Planner.orePower(a.name, Ores) > Planner.orePower(b.name, Ores) end)
                for _, row in ipairs(recipeRows) do table.insert(entries, row) end
                -- Rohstoffe, die nur als Craft-Zutat gebraucht werden
                for oreName, amount in pairs(plan.mine or {}) do
                    if not plan.recipe[oreName] then
                        local island = plan.mineIsland and plan.mineIsland[oreName]
                        table.insert(entries, {name = oreName, title = "⛏ " .. oreName, ok = false, count = "+" .. amount,
                            status = island and island ~= currentWorld and ("mine on Island " .. island) or "mine for crafting",
                            sub = string.format("%g× · have %d", Planner.orePower(oreName, Ores), forgeGoal.usable(oreName))})
                    end
                end
                -- Craft-Schritte in Reihenfolge
                for _, step in ipairs(plan.crafts or {}) do
                    local parts = {}
                    for ingredient, per in pairs(step.recipe) do
                        table.insert(parts, ingredient == "Gold" and (per * step.amount .. " gold") or (per * step.amount .. " " .. ingredient))
                    end
                    table.insert(entries, {name = step.ore, title = "⚒ Craft " .. step.ore, ok = false, count = "×" .. step.amount,
                        status = forgeGoal.formatDuration(step.seconds) .. (step.island and step.island ~= currentWorld and (" · Island " .. step.island) or ""),
                        sub = table.concat(parts, " + ")})
                end
            end
            return entries
        end
        api.RenderGoalList = function(plan)
            local entries = api.GoalEntries(plan)
            local parts = {}
            for _, entry in ipairs(entries) do table.insert(parts, table.concat({entry.title, entry.count, entry.status, entry.sub}, "\0")) end
            local signature = table.concat(parts, "|")
            if signature == lastSignature then return end
            lastSignature = signature
            for _, child in ipairs(goalList:GetChildren()) do if child:IsA("Frame") then child:Destroy() end end
            for index, entry in ipairs(entries) do
                local enough = entry.ok
                local row = Instance.new("Frame")
                row.Name, row.LayoutOrder, row.Size = entry.name, index, UDim2.new(1, 0, 0, 40)
                row.BackgroundColor3, row.BackgroundTransparency = Color3.fromRGB(32, 32, 36), 0.1
                Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)
                local stroke = Instance.new("UIStroke", row)
                stroke.Color, stroke.Transparency = enough and Color3.fromRGB(70, 170, 100) or Color3.fromRGB(200, 140, 60), 0.4
                local icon = api.OreIcon(entry.name, 32)
                if icon then icon.Position, icon.Parent = UDim2.fromOffset(6, 4), row end
                local nameLabel = Instance.new("TextLabel")
                nameLabel.BackgroundTransparency, nameLabel.Position, nameLabel.Size = 1, UDim2.fromOffset(46, 3), UDim2.new(0.5, -46, 0, 18)
                nameLabel.Font, nameLabel.TextSize, nameLabel.TextXAlignment = Enum.Font.GothamBold, 14, Enum.TextXAlignment.Left
                nameLabel.TextColor3, nameLabel.Text, nameLabel.Parent = Color3.fromRGB(240, 240, 240), entry.title, row
                local multLabel = nameLabel:Clone()
                multLabel.Position, multLabel.Font, multLabel.TextSize = UDim2.fromOffset(46, 21), Enum.Font.Gotham, 12
                multLabel.Size = UDim2.new(0.7, -46, 0, 16)
                multLabel.TextColor3, multLabel.TextTruncate, multLabel.Parent = Color3.fromRGB(170, 170, 170), Enum.TextTruncate.AtEnd, row
                multLabel.Text = entry.sub
                local countLabel = Instance.new("TextLabel")
                countLabel.BackgroundTransparency, countLabel.AnchorPoint = 1, Vector2.new(1, 0)
                countLabel.Position, countLabel.Size = UDim2.new(1, -10, 0, 3), UDim2.new(0.5, -10, 0, 18)
                countLabel.Font, countLabel.TextSize, countLabel.TextXAlignment = Enum.Font.GothamBold, 15, Enum.TextXAlignment.Right
                countLabel.TextColor3 = enough and Color3.fromRGB(110, 220, 140) or Color3.fromRGB(255, 190, 90)
                countLabel.Text, countLabel.Parent = entry.count, row
                local statusLabel = countLabel:Clone()
                statusLabel.Position, statusLabel.Font, statusLabel.TextSize = UDim2.new(1, -10, 0, 21), Enum.Font.Gotham, 12
                statusLabel.Size = UDim2.new(0.3, -10, 0, 16)
                statusLabel.Text = entry.status
                statusLabel.Parent = row
                row.Parent = goalList
            end
        end
        local inventorySection = tabs.Forge:AddCollapsibleSection({Title = "Craft with my inventory", Icon = "backpack", Open = false})
        -- Bilder kommen aus dem Spiel: 3D-Modell des Items (mit Erz-Aussehen) und die Erz-Icons des Inventars.
        inventorySection:AddToggle("ForgeBestAvoidNegative", {
            Title = "Prefer gear without negative traits", Default = api.BestAvoidNegative,
            Description = "Less health (weapons), stamina or move speed from ore traits lowers the ranking.",
            Callback = function(value)
                if value == api.BestAvoidNegative then return end
                api.BestAvoidNegative = value
                if api.BestCraft.target then task.spawn(api.BestCraft.run) end
            end,
        })
        local targetIcons = {Weapon = "sword", Helmet = "shield", Chestplate = "shield", Leggings = "shield"}
        local function applyIcon(image, iconName)
            local icon = Fluent.GetIcon and Fluent:GetIcon(iconName)
            if type(icon) == "string" then image.Image = icon
            elseif type(icon) == "table" then
                image.Image = icon.Image or ""
                if icon.ImageRectOffset then image.ImageRectOffset = icon.ImageRectOffset end
                if icon.ImageRectSize then image.ImageRectSize = icon.ImageRectSize end
            end
        end
        local kindOption = inventorySection:AddDropdown("ForgeBestKind", {
            Title = "Gear slot", Values = table.clone(api.BestCraft.slots), AllowNull = true,
            Description = "Finds the best recipe for this slot using the ores in your inventory.",
            Callback = function(value)
                if targetIcons[value] then task.spawn(api.BestCraft.run, value) end
            end,
        })
        do
            local buildKindList = kindOption.BuildDropdownList
            kindOption.BuildDropdownList = function(self, ...)
                buildKindList(self, ...)
                for button in pairs(self.Buttons) do
                    local label = button:FindFirstChild("ButtonLabel")
                    local iconName = label and targetIcons[label.Text]
                    if iconName and not button:FindFirstChild("KindIcon") then
                        local image = Instance.new("ImageLabel")
                        image.Name, image.BackgroundTransparency, image.Size = "KindIcon", 1, UDim2.fromOffset(16, 16)
                        image.AnchorPoint, image.Position, image.ZIndex = Vector2.new(0, 0.5), UDim2.new(0, 8, 0.5, 0), label.ZIndex
                        image.ImageColor3 = Color3.fromRGB(200, 230, 210)
                        applyIcon(image, iconName)
                        image.Parent = button
                        label.Position = label.Position + UDim2.fromOffset(20, 0)
                    end
                end
            end
            kindOption:BuildDropdownList()
        end
        -- Karte direkt unter dem letzten Element einhaengen (gleicher Trick wie die Rezeptliste beim Schmiede-Ziel)
        local function makeCard(section, name)
            local frame = Instance.new("Frame")
            frame.Name, frame.BackgroundColor3 = name, Color3.fromRGB(15, 19, 17)
            frame.Size, frame.AutomaticSize = UDim2.new(1, 0, 0, 0), Enum.AutomaticSize.Y
            local corner = Instance.new("UICorner", frame); corner.CornerRadius = UDim.new(0, 8)
            local stroke = Instance.new("UIStroke", frame); stroke.Color, stroke.Thickness = Color3.fromRGB(34, 197, 94), 1.4
            local padding = Instance.new("UIPadding", frame)
            padding.PaddingTop, padding.PaddingBottom, padding.PaddingLeft, padding.PaddingRight = UDim.new(0, 12), UDim.new(0, 12), UDim.new(0, 12), UDim.new(0, 12)
            local layout = Instance.new("UIListLayout", frame)
            layout.Padding, layout.SortOrder = UDim.new(0, 10), Enum.SortOrder.LayoutOrder
            local order = (section._elementCount or 0) + 1
            section._elementCount, frame.LayoutOrder = order, order
            frame.Parent = section.Container
            return frame
        end
        local card = makeCard(inventorySection, "ForgeBestCard")
        local bestState, craftMessage, possibleMessage = nil, nil, nil
        local GREEN, RED, PURPLE = Color3.fromRGB(74, 222, 128), Color3.fromRGB(248, 113, 113), Color3.fromRGB(196, 132, 252)
        local function new(className, props, parent)
            local object = Instance.new(className)
            for key, value in pairs(props) do object[key] = value end
            object.Parent = parent
            return object
        end
        local function text(parent, props)
            local label = new("TextLabel", {BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 14,
                TextColor3 = Color3.fromRGB(235, 240, 237), TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = false}, parent)
            for key, value in pairs(props) do label[key] = value end
            return label
        end
        local function rounded(object, radius, strokeColor)
            new("UICorner", {CornerRadius = UDim.new(0, radius)}, object)
            if strokeColor then new("UIStroke", {Color = strokeColor, Thickness = 1}, object) end
        end
        local function craftBusy(possible)
            if possible then return api.GoalFixed ~= nil and api.FarmMode == "Forging" and api.Running and api.ForgeGoalActive end
            return api.PendingCraft ~= nil or forgeBusy
        end
        local function updateCraftButton(button, possible)
            if not button then return end
            local busy = craftBusy(possible)
            button.Text = possible and (busy and "Farming …" or "⛏  Farm & Craft") or (busy and "Crafting …" or "⚒  Craft")
            button.BackgroundColor3 = busy and Color3.fromRGB(40, 70, 52) or Color3.fromRGB(28, 150, 76)
            button.Active, button.AutoButtonColor = not busy, not busy
        end
        -- mode = "inventory" (Best Craftable) oder "possible" (Best Possible); message = Statuszeile unten
        local renderBest, renderPossible, renderCard
        renderCard = function(card, state, mode, message)
            local possible = mode == "possible"
            for _, child in ipairs(card:GetChildren()) do if child:IsA("GuiObject") then child:Destroy() end end
            if not state or state.loading or state.error or not state.best then
                text(card, {Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true,
                    TextColor3 = state and state.error and RED or Color3.fromRGB(185, 200, 192),
                    Text = state and (state.loading or state.error) or (possible
                        and "Choose Weapon, Helmet, Chestplate or Leggings above to see the best item you can get at all (without event/raid ores)."
                        or "Choose a gear slot above to see the best item you can craft right now.")})
                return
            end
            local e = state.best
            -- Kopf: Bild, Name, Abzeichen, Rang, Varianten
            local head = new("Frame", {BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 104), LayoutOrder = 1}, card)
            local frame = new("Frame", {BackgroundColor3 = Color3.fromRGB(30, 18, 44), Size = UDim2.fromOffset(100, 100)}, head)
            rounded(frame, 10, PURPLE)
            do
                local mainOre, most = nil, 0
                for oreName, k in pairs(e.recipe) do
                    if k > most and not (Ores[oreName] and Ores[oreName].NeutralMultiplier) then mainOre, most = oreName, k end
                end
                local model
                local ok, result = pcall(Equipment.GetItemModel, Equipment, {Type = e.sample, Ore = mainOre})
                if ok and typeof(result) == "Instance" then model = result end
                if not model then
                    local equipments = ReplicatedStorage:FindFirstChild("Assets") and ReplicatedStorage.Assets:FindFirstChild("Equipments")
                    local folder = equipments and equipments:FindFirstChild(e.kind == "Weapon" and "Weapons" or "Armors")
                    local template = folder and folder:FindFirstChild(e.sample, true)
                    model = template and template:IsA("Model") and template:Clone() or nil
                end
                if model then modelViewport(model, nil, "ItemImage").Parent = frame end
            end
            text(head, {Position = UDim2.fromOffset(114, 0), Size = UDim2.new(1, -114, 0, 36), Font = Enum.Font.GothamBold, TextSize = 19,
                TextColor3 = PURPLE, Text = e.label, TextWrapped = true, TextTruncate = Enum.TextTruncate.AtEnd})
            local variants = {}
            for _, v in ipairs(e.variants) do table.insert(variants, string.format("%s %d%%", v.name, math.floor(v.chance + 0.5))) end
            text(head, {Position = UDim2.fromOffset(114, 40), Size = UDim2.new(1, -114, 0, 64), TextWrapped = true, TextSize = 12,
                TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = Color3.fromRGB(165, 180, 172),
                Text = string.format("%s%d ores · %d%% quality%s\nVariants: %s", e.slot and (e.slot .. " · ") or "",
                    e.n, math.floor(e.quality), e.island and e.island ~= currentWorld and (" · forge on Island " .. e.island) or "",
                    table.concat(variants, " · "))})
            -- Werte links, Traits rechts
            local body = new("Frame", {BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2}, card)
            local statsBox = new("Frame", {BackgroundTransparency = 1, Size = UDim2.new(0.5, -6, 0, 0), AutomaticSize = Enum.AutomaticSize.Y}, body)
            new("UIListLayout", {Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder}, statsBox)
            local function commasLocal(n) return (tostring(math.floor((n or 0) + 0.5)):reverse():gsub("(%d%d%d)", "%1."):reverse():gsub("^%.", "")) end
            local rows = {}
            if e.kind == "Weapon" then
                table.insert(rows, {"swords", "DPS", "≈" .. commasLocal(e.dps), GREEN})
                table.insert(rows, {"sparkles", "Damage", string.format("%.2f – %.2f", e.damageLow, e.damageHigh)})
                table.insert(rows, {"gauge", "Hits/s", string.format("%.2f", e.hps)})
                table.insert(rows, {"gem", "Ore Multiplier", string.format("%.2f×", e.avg)})
                if e.current then
                    local diff = e.dps - e.current.dps
                    table.insert(rows, {"crosshair", "vs " .. e.current.type, (diff >= 0 and "+" or "−") .. commasLocal(math.abs(diff)) .. " DPS", diff >= 0 and GREEN or RED})
                end
            else
                table.insert(rows, {"heart", "Total HP", commasLocal(e.total), GREEN})
                table.insert(rows, {"shield", "Effective HP", commasLocal(e.ehp)})
                table.insert(rows, {"box", "Piece HP", string.format("%d – %d", math.floor(e.hpLow + 0.5), math.floor(e.hpHigh + 0.5))})
                table.insert(rows, {"gem", "Ore Multiplier", string.format("%.2f×", e.avg)})
                if e.currentEhp then
                    local diff = e.ehp - e.currentEhp
                    table.insert(rows, {"crosshair", "vs " .. e.currentType, (diff >= 0 and "+" or "−") .. commasLocal(math.abs(diff)) .. " eff. HP", diff >= 0 and GREEN or RED})
                end
            end
            for index, row in ipairs(rows) do
                local line = new("Frame", {BackgroundColor3 = Color3.fromRGB(23, 28, 25), Size = UDim2.new(1, 0, 0, 28), LayoutOrder = index}, statsBox)
                rounded(line, 6)
                local image = new("ImageLabel", {BackgroundTransparency = 1, Size = UDim2.fromOffset(16, 16), Position = UDim2.new(0, 8, 0.5, -8),
                    ImageColor3 = Color3.fromRGB(190, 215, 200)}, line)
                applyIcon(image, row[1])
                text(line, {Position = UDim2.fromOffset(32, 0), Size = UDim2.new(0.5, -32, 1, 0), Text = row[2], TextTruncate = Enum.TextTruncate.AtEnd})
                text(line, {AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -8, 0, 0), Size = UDim2.new(0.5, 0, 1, 0), Text = row[3],
                    Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = row[4] or Color3.fromRGB(235, 240, 237)})
            end
            local traitBox = new("Frame", {BackgroundTransparency = 1, Position = UDim2.new(0.5, 6, 0, 0), Size = UDim2.new(0.5, -6, 0, 0),
                AutomaticSize = Enum.AutomaticSize.Y}, body)
            new("UIListLayout", {Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder}, traitBox)
            text(traitBox, {Size = UDim2.new(1, 0, 0, 22), Text = "Traits", Font = Enum.Font.GothamBold, TextSize = 16, LayoutOrder = 0})
            if #e.traits == 0 then
                text(traitBox, {Size = UDim2.new(1, 0, 0, 20), Text = "No traits (no ore reaches 10 % share)", TextSize = 12,
                    TextColor3 = Color3.fromRGB(150, 165, 157), LayoutOrder = 1})
            end
            for index, trait in ipairs(e.traits) do
                local line = new("Frame", {BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20), LayoutOrder = index}, traitBox)
                text(line, {Size = UDim2.new(0.6, 0, 1, 0), Text = (trait.negative and "⚠  " or "•  ") .. trait.name, TextSize = 13,
                    TextColor3 = trait.negative and RED or Color3.fromRGB(225, 232, 228), TextTruncate = Enum.TextTruncate.AtEnd})
                text(line, {AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.new(0.4, 0, 1, 0), Text = trait.value,
                    Font = Enum.Font.GothamBold, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = trait.negative and RED or GREEN})
            end
            -- Crafting Requirements: Erz-Bilder aus dem Spiel, Menge, Haken; dazu der Craft-Knopf
            local reqTitle = new("Frame", {BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 22), LayoutOrder = 3}, card)
            local hammer = new("ImageLabel", {BackgroundTransparency = 1, Size = UDim2.fromOffset(16, 16), Position = UDim2.new(0, 0, 0.5, -8),
                ImageColor3 = Color3.fromRGB(190, 215, 200)}, reqTitle)
            applyIcon(hammer, "hammer")
            text(reqTitle, {Position = UDim2.fromOffset(22, 0), Size = UDim2.new(1, -22, 1, 0), Text = "Crafting Requirements", Font = Enum.Font.GothamBold, TextSize = 16})
            local grid = new("Frame", {BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 4}, card)
            new("UIGridLayout", {CellSize = UDim2.fromOffset(152, 56), CellPadding = UDim2.fromOffset(8, 8), SortOrder = Enum.SortOrder.LayoutOrder}, grid)
            -- Kacheln: Inventar-Modus = Menge + Haken; Best Possible = Bestand/Bedarf + was zu tun ist (abbauen/craften)
            local list = {}
            if possible then
                for _, req in ipairs(e.requirements or {}) do table.insert(list, {name = req.name, k = req.need, have = req.have, status = req.status}) end
            else
                for oreName, k in pairs(e.recipe) do table.insert(list, {name = oreName, k = k}) end
                table.sort(list, function(a, b)
                    if a.k ~= b.k then return a.k > b.k end
                    return a.name < b.name
                end)
            end
            for index, entry in ipairs(list) do
                local have = entry.have or forgeGoal.usable(entry.name)
                local enough = have >= entry.k
                local tile = new("Frame", {BackgroundColor3 = Color3.fromRGB(23, 28, 25), LayoutOrder = index}, grid)
                rounded(tile, 8, Color3.fromRGB(46, 60, 52))
                local icon = api.OreIcon(entry.name, 40)
                if icon then icon.Position = UDim2.new(0, 8, 0.5, -20); icon.Parent = tile end
                local nameLabel = text(tile, {Position = UDim2.fromOffset(54, 6), Size = UDim2.new(1, -80, 0, 20), Text = entry.name, Font = Enum.Font.GothamBold,
                    TextSize = 13, TextScaled = true})
                new("UITextSizeConstraint", {MaxTextSize = 13, MinTextSize = 8}, nameLabel) -- lange Namen kleiner statt abgeschnitten
                local amount = text(tile, {Position = UDim2.fromOffset(54, 28), Size = UDim2.new(1, -62, 0, 20), Font = Enum.Font.GothamBold,
                    Text = possible and string.format("%d/%d%s", math.min(have, entry.k), entry.k, enough and "" or ("  " .. entry.status)) or ("×" .. entry.k),
                    TextSize = possible and 13 or 16, TextColor3 = Color3.fromRGB(253, 224, 140), TextScaled = possible})
                if possible then new("UITextSizeConstraint", {MaxTextSize = 13, MinTextSize = 8}, amount) end
                text(tile, {AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -8, 0, 6), Size = UDim2.fromOffset(20, 20), Text = enough and "✓" or (possible and "⛏" or "✗"),
                    Font = Enum.Font.GothamBold, TextSize = possible and not enough and 15 or 20, TextXAlignment = Enum.TextXAlignment.Center,
                    TextColor3 = enough and GREEN or (possible and Color3.fromRGB(253, 224, 140) or RED)})
            end
            local craftButton = new("TextButton", {Name = "ForgeAction", Size = UDim2.new(1, 0, 0, 42), LayoutOrder = 6,
                Font = Enum.Font.GothamBold, TextSize = 18, TextColor3 = Color3.new(1, 1, 1)}, card)
            updateCraftButton(craftButton, possible)
            rounded(craftButton, 8, Color3.fromRGB(74, 222, 128))
            craftButton.Activated:Connect(function()
                if craftBusy(possible) then return end
                if possible then
                    -- Best Possible: Rezept als Schmiede-Ziel, Farm-Modus "Forging" startet abbauen/craften/reisen/schmieden
                    local ok, why = api.BestCraft.farmPossible()
                    possibleMessage = ok and ("Farming for " .. e.label .. " – progress under Plan a specific item (Farm Mode \"Forging\").") or ("Cannot start: " .. tostring(why))
                    if ok then goalSection:Open(false) end
                    renderPossible()
                    return
                end
                if api.PendingCraft or forgeBusy then return end
                local plan = api.BestCraft.plan()
                if not plan then return end
                api.PendingCraft = plan
                craftMessage = "Flying to the forge to craft " .. plan.label .. " …"
                if not api.Running then
                    api.CraftStartedBot = true
                    if not api:Start() then
                        api.PendingCraft, api.CraftStartedBot = nil, false
                        craftMessage = "Cannot start: " .. tostring(api.State)
                    end
                end
                renderBest()
            end)
            local footer
            if possible then
                local effort = e.effort or {}
                local islands = {}
                for _, island in ipairs(effort.islands or {}) do table.insert(islands, "Island " .. island) end
                footer = string.format("To get it: mine %d ores · %d craft step%s (%s) · %s gold%s%s\nUses only ores you can get permanently (no event or Tower of Hell raid ores). Procs are estimates.",
                    effort.mine or 0, effort.crafts or 0, (effort.crafts or 0) == 1 and "" or "s", forgeGoal.formatDuration(effort.craftSeconds or 0),
                    commasLocal(effort.gold or 0), effort.goldShort and " (more than you have!)" or "",
                    #islands > 0 and (" · travels to " .. table.concat(islands, ", ")) or "")
            else
                footer = "Recipe uses your whole inventory (quest items kept). Procs like Burn/Explosion are estimates; damage, hits/s, crit and HP use the game's formulas."
            end
            text(card, {Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true, TextSize = 12, LayoutOrder = 7,
                TextColor3 = message and Color3.fromRGB(253, 224, 140) or Color3.fromRGB(140, 155, 147),
                Text = (message and (message .. "\n") or "") .. footer})
        end
        renderBest = function() renderCard(card, bestState, "inventory", craftMessage) end
        api.BestCraft.onUpdate = function(state)
            if type(setIdentity) == "function" then setIdentity(8) end
            bestState = state
            renderBest()
        end
        api.BestCraft.onCrafted = function(message)
            craftMessage = message
            if type(setIdentity) == "function" then setIdentity(8) end
            renderBest()
            task.delay(1.5, function() if not destroyed then api.BestCraft.run() end end) -- Inventar hat sich geaendert
        end
        renderBest()
        -- Best Possible: das beste Item ueberhaupt (alle dauerhaft erreichbaren Erze), Waffe oder je Ruestungs-Slot,
        -- mit "Farm & Craft" (Farm-Modus "Forging" besorgt alles und schmiedet)
        local possibleSection = tabs.Forge:AddCollapsibleSection({Title = "Find the strongest gear", Icon = "trophy", Open = false})
        local possibleOption = possibleSection:AddDropdown("ForgeBestPossible", {
            Title = "Gear slot", Values = table.clone(api.BestCraft.slots), AllowNull = true,
            Description = "Compares recipes using inventory ores and materials obtainable on your unlocked islands.",
            Callback = function(value)
                if targetIcons[value] then task.spawn(api.BestCraft.runPossible, value) end
            end,
        })
        do
            local buildPossibleList = possibleOption.BuildDropdownList
            possibleOption.BuildDropdownList = function(self, ...)
                buildPossibleList(self, ...)
                for button in pairs(self.Buttons) do
                    local label = button:FindFirstChild("ButtonLabel")
                    local iconName = label and targetIcons[label.Text]
                    if iconName and not button:FindFirstChild("KindIcon") then
                        local image = Instance.new("ImageLabel")
                        image.Name, image.BackgroundTransparency, image.Size = "KindIcon", 1, UDim2.fromOffset(16, 16)
                        image.AnchorPoint, image.Position, image.ZIndex = Vector2.new(0, 0.5), UDim2.new(0, 8, 0.5, 0), label.ZIndex
                        image.ImageColor3 = Color3.fromRGB(200, 230, 210)
                        applyIcon(image, iconName)
                        image.Parent = button
                        label.Position = label.Position + UDim2.fromOffset(20, 0)
                    end
                end
            end
            possibleOption:BuildDropdownList()
        end
        local possibleCard = makeCard(possibleSection, "ForgeBestPossibleCard")
        api.UpdateForgeActions = function()
            updateCraftButton(card:FindFirstChild("ForgeAction"), false)
            updateCraftButton(possibleCard:FindFirstChild("ForgeAction"), true)
        end
        local possibleState
        renderPossible = function() renderCard(possibleCard, possibleState, "possible", possibleMessage) end
        api.BestCraft.onPossibleUpdate = function(state)
            if type(setIdentity) == "function" then setIdentity(8) end
            possibleState = state
            renderPossible()
        end
        renderPossible()
        local forgeSettings = tabs.Forge:AddCollapsibleSection({Title = "Forge settings", Icon = "settings", Open = false})
        forgeSettings:AddToggle("ForgeGoalUseFavorites", {
            Title = "Allow favorite ores", Default = api.GoalUseFavorites,
            Description = "Favorites may be used for the goal (crafting and forging). Auto Sell still never sells favorites.",
            Callback = function(value)
                api.GoalUseFavorites = value
                forgeGoal.refresh(true)
            end,
        })
        forgeSettings:AddSlider("ForgeGoalQuality", {
            Title = "Expected quality %", Default = api.GoalQuality, Min = 50, Max = 100, Rounding = 0,
            Description = "Forge quality you usually get (auto minigames reached ~94 %). Lower = safer plan.",
            Callback = function(value)
                local quality = tonumber(value)
                if finite(quality) then api.GoalQuality = math.clamp(quality, 50, 100); forgeGoal.refresh(true) end
            end,
        })
        forgeSettings:AddToggle("ForgeAutoForge", {
            Title = "Auto Craft Upgrades", Default = api.AutoForge,
            Description = "Only in Farm Mode \"Gold\": plans upgrades, mines the missing ores and crafts them.",
            Callback = function(value)
                api.AutoForge = value
                if not value then api.CraftRequested = false end
            end,
        })
        forgeSettings:AddParagraph({Title = "Auto Forge Minigames", Content = "Always active, including when master automation is stopped."})
    end
    -- (Der fruehere Schalter "Get Materials & Craft" ist jetzt der Farm-Modus "Forging" im Overview-Tab.)
    -- QUESTS-TAB (Quests laufen im Farm-Modus "Quests")
    tabs.Quests:AddParagraph({Title = "How it works", Content = "Farm Mode \"Quests\" (does ONLY quests): accepts every quest whose NPC is on this island, then works through them – preferred quests first. Item quests (e.g. skulls) are collected automatically. If a quest rock is missing (e.g. Icy Boulder), other rocks in the areas where it spawns are mined so it can respawn."})
    tabs.Quests:AddToggle("ForgeAutoAcceptQuests", {
        Title = "Auto Accept Quests", Default = api.AutoAcceptQuests,
        Description = "Talks to quest NPCs on this island and accepts all quests you can take (prerequisites met).",
        Callback = function(value) api.AutoAcceptQuests = value; questTools.lastAcceptScan = 0 end,
    })
    local questLabels = {}
    local function questLabelList()
        local labels, seen = {}, {}
        local function add(id)
            local def = Definitions[id]
            if seen[id] or type(def) ~= "table" then return end
            seen[id] = true
            local label = string.format("%s [%s]", tostring(def.Name or id), id)
            questLabels[label] = id
            table.insert(labels, label)
        end
        for id in pairs(data().Quests or {}) do add(id) end
        for _, entry in ipairs(questTools.available()) do add(entry.id) end
        for id in pairs(api.PreferredQuests) do add(id) end
        table.sort(labels)
        return labels
    end
    local function preferredLabels()
        local selected = {}
        for label, id in pairs(questLabels) do if api.PreferredQuests[id] then selected[label] = true end end
        return selected
    end
    local initialLabels = questLabelList()
    local preferredDefault = {}
    for label in pairs(preferredLabels()) do table.insert(preferredDefault, label) end
    local preferredDropdown = tabs.Quests:AddDropdown("ForgePreferredQuests", {
        Title = "Preferred Quests", Values = initialLabels, Multi = true, AllowNull = true, Search = true, Default = preferredDefault,
        Description = "Selected quests are accepted and worked on first.",
        Callback = function(value)
            local selected = {}
            for label, checked in pairs(value) do if checked == true and questLabels[label] then selected[questLabels[label]] = true end end
            api.PreferredQuests = selected
            questTools.lastAcceptScan = 0
        end,
    })
    menu.QuestStatus = tabs.Quests:AddParagraph({Title = "Active Quests", Content = "Loading ..."})
    local lastLabelKey = table.concat(initialLabels, "|")
    api.RefreshQuestMenu = function()
        -- Auswahlliste aktualisieren, wenn neue Quests dazukommen (Auswahl bleibt erhalten)
        local labels = questLabelList()
        local key = table.concat(labels, "|")
        if key ~= lastLabelKey and type(preferredDropdown.SetValues) == "function" then
            lastLabelKey = key
            preferredDropdown:SetValues(labels)
            pcall(preferredDropdown.SetValue, preferredDropdown, preferredLabels())
        end
        -- Fortschritt aller aktiven Quests
        local lines = {}
        local unsupported = {}
        for _, text in ipairs(report and report.unsupported or {}) do unsupported[text:match("^([^:]+)") or ""] = true end
        for id, quest in pairs(data().Quests or {}) do
            local def = Definitions[id] or {}
            local parts = {}
            for index, progress in ipairs(quest.Progress or {}) do
                local objective = (def.Objectives or {})[index] or {}
                table.insert(parts, string.format("%s %d/%d", tostring(objective.Description or progress.target or "?"), progress.currentProgress or 0, progress.requiredAmount or 1))
            end
            table.insert(lines, string.format("%s%s%s: %s", api.PreferredQuests[id] and "★ " or "", tostring(def.Name or id),
                unsupported[id] and " (manual)" or "", table.concat(parts, " · ")))
        end
        table.sort(lines)
        local available = {}
        for _, entry in ipairs(questTools.available()) do table.insert(available, tostring(entry.name)) end
        menu.QuestStatus:SetDesc((#lines > 0 and table.concat(lines, "\n") or "No active quests.")
            .. (#available > 0 and ("\n\nCan be accepted here: " .. table.concat(available, ", ")) or ""))
    end
    tabs.Visuals:AddToggle("ForgeGoalHud", {
        Title = "Goal HUD Above Quests", Default = api.GoalHud,
        Description = "While Farm Mode \"Forging\" farms for an item: shows every ore, mining and craft step right above the game's QUESTS list.",
        Callback = function(value) api.GoalHud = value end,
    })
    tabs.Visuals:AddToggle("ForgeShowCounter", {
        Title = "Counter Above Level", Default = api.ShowCounter,
        Description = "Bottom left above your level: alive mobs per selected mob type and rocks per selected ore/rock (0 = all dead / none loaded).",
        Callback = function(value) api.ShowCounter = value end,
    })
    tabs.Visuals:AddToggle("ForgeTargetEsp", {
        Title = "Target ESP", Default = api.TargetEsp,
        Description = "Outline plus name, HP and distance on the mob or rock the bot is flying to.",
        Callback = function(value) api.TargetEsp = value end,
    })
    tabs.Visuals:AddToggle("ForgePathLine", {
        Title = "Flight Line", Default = api.PathLine,
        Description = "Line from you to the current target (next ore, mob or NPC).",
        Callback = function(value) api.PathLine = value end,
    })
    tabs.Visuals:AddToggle("ForgeOreEsp", {
        Title = "Ore ESP", Default = api.OreEsp,
        Description = "Labels the 40 nearest rocks with your selected ores/rocks. With nothing selected: rocks whose best ore reaches the multiplier below.",
        Callback = function(value) api.OreEsp = value end,
    })
    tabs.Visuals:AddSlider("ForgeEspMinMultiplier", {
        Title = "Ore ESP Min Multiplier", Default = api.EspMinMultiplier, Min = 0, Max = 30, Rounding = 1,
        Description = "Only used when no ore or rock is selected.",
        Callback = function(value)
            local multiplier = tonumber(value)
            if finite(multiplier) then api.EspMinMultiplier = math.clamp(multiplier, 0, 30) end
        end,
    })
    Fluent:SetTheme(themeName)
    Fluent:ToggleTransparency(false)
    -- Der feste Acryl-Overlay dieser Fluent-Version ist weiss, auch ohne Blur.
    for _, layer in ipairs(window.AcrylicPaint.Frame:GetChildren()) do
        if layer:IsA("Frame") and layer.BackgroundTransparency < 1 then layer.BackgroundColor3 = Color3.fromRGB(14, 17, 15) end
        if layer:IsA("ImageLabel") and (layer.Image == "rbxassetid://9968344105" or layer.Image == "rbxassetid://9968344227") then layer.ImageTransparency = 1 end
    end
    window:SelectTab(1)
end
local menuReady, menuError = pcall(createMenu)
if type(setIdentity) == "function" then setIdentity(2) end
if not menuReady then
    api:Destroy()
    warn("[ForgeHelper] Fluent menu failed to load: " .. tostring(menuError))
    return
end
task.spawn(function()
    while not destroyed do
        local ok, why = pcall(function()
            if not report or (not api.Running and os.clock() - lastPlan > 15) then api:Refresh() end
            if type(setIdentity) == "function" then setIdentity(8) end
            local clashText = ""
            if api.ClashFocus then
                local nextIn = api.ClashNextIn and api.ClashNextIn()
                clashText = api.ClashLive() and "CLASH FOCUS (LIVE) | "
                    or ("Clash Focus waiting" .. (nextIn and string.format(" %d:%02d", nextIn // 60, nextIn % 60) or "") .. " | ")
            end
            menu.Status:SetDesc(clashText .. (api.Enabled and "Master ON | " or "Master OFF | ") .. api.FarmMode .. " | " .. (api.Running and "Farming ON | " or "Farming OFF | ")
                .. ((api.AutoRestart and api.WantRunning) and "Auto Restart | " or "") .. api.State .. (api.LastError ~= "" and "\n" .. api.LastError or ""))
            api.UpdateMasterButton()
            api.UpdateClashButton()
            updateStats()
            menu.Stats:SetDesc(statsText())
            if os.clock() - (api.QuestMenuAt or 0) > 5 then
                api.QuestMenuAt = os.clock()
                if type(setIdentity) == "function" then setIdentity(2) end
                local okQuests, questError = pcall(api.RefreshQuestMenu)
                if type(setIdentity) == "function" then setIdentity(8) end
                if not okQuests then api.LastError = "Quest menu: " .. tostring(questError) end
            end
            forgeGoal.refresh(false)
            menu.GoalPlan:SetDesc(forgeGoal.describe())
            api.RenderGoalList(forgeGoal.plan)
            api.UpdateForgeActions()
            for flag, value in pairs({ForgeAutoSell = api.AutoSell, ForgeAutoEquip = api.AutoEquip, ForgeAutoForge = api.AutoForge, ForgeAutoRange = api.AutoRange, ForgeAutoBlock = api.AutoBlock, ForgeNoclip = api.Noclip,
                ForgeSkipEnemies = api.SkipNearEnemies, ForgeAutoRestart = api.AutoRestart, ForgeAntiAfk = api.AntiAfk, ForgeFastAttack = api.FastAttack}) do
                local option = api.MenuOptions[flag]
                if option and option.Value ~= value then option:SetValue(value) end
            end
            if report then
                menu.World:SetDesc(string.format("%s%s\n%d local tasks, %d tasks from other / unknown worlds blocked.",
                    report.world.index and "World " .. tostring(report.world.index) .. ": " or "", report.world.name, #report.jobs, #report.skippedWorldJobs))
                menu.Gold:SetDesc(string.format("Gold: %.0f | Price: %s | Remaining: %s", data().Gold or 0,
                    report.quote and string.format("%.0f", report.quote) or "?", report.owned and "Owned" or string.format("%.0f", report.remaining or 0))
                )
            end
        end)
        if not ok then
            if api.LastError ~= tostring(why) then warn("[ForgeHelper] " .. tostring(why)) end
            api.LastError = tostring(why)
            if type(setIdentity) == "function" then setIdentity(8) end
            pcall(function() menu.Status:SetDesc("Planning error: " .. tostring(why)) end)
            lastPlan = os.clock()
        end
        if type(setIdentity) == "function" then setIdentity(2) end
        task.wait(1)
    end
end)
task.spawn(function()
    while not destroyed do
        if api.Enabled and api.Running then
            local token = generation
            local ok, why = pcall(step, token)
            if not ok then api.LastError = tostring(why); warn("[ForgeHelper] " .. tostring(why)); api:Stop("Error: farming stopped") end
        end
        -- Fast Attack: jeden Frame angreifen statt alle 0.15 s; der Server begrenzt weiterhin auf die Waffen-Angriffsgeschwindigkeit.
        -- Jeden Frame nur, solange ein Ziel aktiv ist; die Zielsuche (alle Steine/Mobs durchgehen) laeuft alle 0.15 s.
        -- FPS: nur jeden Frame, solange wirklich zugeschlagen wird. Fliegen und Zielsuche laufen alle 0,15 s
        -- (die Zielsuche geht ueber tausende Steine; jeden Frame liess das die FPS auf ~7 fallen).
        if api.FastAttack and swingState.attacking and activeTarget and activeTarget.Parent then task.wait() else task.wait(0.15) end
    end
end)
do -- eigener Block (Limit fuer lokale Variablen)
-- ANTI_AFK_START
-- Mehrere Eingabearten hintereinander: VirtualUser-Rechtsklicks (Linksklick oben links wuerde das Roblox-Menue treffen), eine unbelegte Taste
-- und eine kleine Mausbewegung. Laeuft bei Idled UND zusaetzlich alle 60 s, unabhaengig vom Signal.
local VirtualUser = game:GetService("VirtualUser")
local function antiAfkPulse()
    if not api.AntiAfk or destroyed then return end
    local cameraFrame = workspace.CurrentCamera and workspace.CurrentCamera.CFrame or CFrame.new()
    for _ = 1, 3 do
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
            VirtualUser:Button2Down(Vector2.new(0, 0), cameraFrame)
            task.wait(0.05)
            VirtualUser:Button2Up(Vector2.new(0, 0), cameraFrame)
        end)
        pcall(virtual, "SendKeyEvent", true, Enum.KeyCode.F15, false, game)
        task.wait(0.05)
        pcall(virtual, "SendKeyEvent", false, Enum.KeyCode.F15, false, game)
        local mouse = game:GetService("UserInputService"):GetMouseLocation()
        pcall(virtual, "SendMouseMoveEvent", math.floor(mouse.X) + 1, math.floor(mouse.Y), game)
        pcall(virtual, "SendMouseMoveEvent", math.floor(mouse.X), math.floor(mouse.Y), game)
        task.wait(0.3)
    end
end
track(player.Idled:Connect(function() task.spawn(antiAfkPulse) end))
task.spawn(function()
    while not destroyed do
        task.wait(60)
        antiAfkPulse()
    end
end)
-- ANTI_AFK_END
end
do -- eigener Block: Lua erlaubt nur 200 lokale Variablen auf oberster Ebene
-- VISUALS_START
-- 1) Zaehler unten links ueber der Level-Anzeige: lebende Mobs je ausgewaehlter Mob-Art, Steine je ausgewaehltem Erz/Stein.
-- 2) Erz-ESP: Beschriftung ueber passenden Steinen (Auswahl, sonst ab "ESP Min Multiplier").
-- 3) Target-ESP: Umriss + Infos am Mob/Stein, den der Bot gerade ansteuert.
-- 4) Fluglinie: Linie vom Spieler zum aktuellen Ziel.
-- Reste aelterer Versionen entfernen (z. B. nach einem Neuladen mitten im Lauf).
for _, old in ipairs(player:WaitForChild("PlayerGui"):GetChildren()) do
    if old.Name == "ForgeHelperOverlay" or old.Name == "ForgeHelperEsp" then old:Destroy() end
end
for _, old in ipairs(workspace.Terrain:GetChildren()) do
    if old.Name:find("^ForgeHelperLine") then old:Destroy() end
end
local overlayGui = Instance.new("ScreenGui")
overlayGui.Name, overlayGui.ResetOnSpawn, overlayGui.IgnoreGuiInset, overlayGui.DisplayOrder = "ForgeHelperOverlay", false, true, 5
overlayGui.Parent = player:WaitForChild("PlayerGui")
local espFolder = Instance.new("Folder")
espFolder.Name = "ForgeHelperEsp"
espFolder.Parent = player.PlayerGui
local worldColor = ({Color3.fromRGB(232, 199, 106), Color3.fromRGB(111, 223, 154), Color3.fromRGB(117, 191, 255), Color3.fromRGB(232, 144, 213)})[currentWorld] or Color3.fromRGB(200, 200, 200)

local counter = Instance.new("Frame")
counter.Name, counter.AnchorPoint, counter.AutomaticSize = "Counter", Vector2.new(0, 1), Enum.AutomaticSize.XY
counter.Size, counter.BackgroundColor3, counter.BackgroundTransparency = UDim2.fromOffset(150, 0), Color3.fromRGB(15, 15, 18), 0.3
counter.Visible, counter.Parent = false, overlayGui
Instance.new("UICorner", counter).CornerRadius = UDim.new(0, 6)
do -- nur fuers Einrichten gebraucht -> Register wieder frei (Limit 200 lokale Variablen gleichzeitig)
    local padding = Instance.new("UIPadding", counter)
    padding.PaddingTop, padding.PaddingBottom, padding.PaddingLeft, padding.PaddingRight = UDim.new(0, 5), UDim.new(0, 5), UDim.new(0, 8), UDim.new(0, 8)
    local listLayout = Instance.new("UIListLayout", counter)
    listLayout.Padding, listLayout.SortOrder = UDim.new(0, 1), Enum.SortOrder.LayoutOrder
end
-- Jede Zeile: [Erz-Bild] Text. Mobs/Steine ohne Bild.
local counterRows = {}
local function counterRow(index)
    local row = counterRows[index]
    if not row then
        row = Instance.new("Frame")
        row.BackgroundTransparency, row.AutomaticSize, row.Size, row.LayoutOrder = 1, Enum.AutomaticSize.X, UDim2.fromOffset(0, 20), index
        local layout = Instance.new("UIListLayout", row)
        layout.FillDirection, layout.VerticalAlignment, layout.Padding = Enum.FillDirection.Horizontal, Enum.VerticalAlignment.Center, UDim.new(0, 5)
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        local label = Instance.new("TextLabel")
        label.Name, label.BackgroundTransparency, label.AutomaticSize, label.Size = "Text", 1, Enum.AutomaticSize.X, UDim2.fromOffset(0, 18)
        label.Font, label.TextSize, label.RichText, label.LayoutOrder = Enum.Font.GothamSemibold, 13, true, 2
        label.TextColor3, label.TextXAlignment = Color3.fromRGB(235, 235, 235), Enum.TextXAlignment.Left
        label.TextStrokeTransparency, label.Parent = 0.6, row
        row.Parent = counter
        counterRows[index] = row
    end
    return row
end
local function setCounterRow(index, text, oreName)
    local row = counterRow(index)
    row.Text.Text, row.Visible = text, true
    local icon = row:FindFirstChild("Icon")
    if row:GetAttribute("Ore") ~= oreName then
        if icon then icon:Destroy() end
        icon = oreName and api.OreIcon(oreName, 18)
        if icon then icon.LayoutOrder, icon.Parent = 1, row end
        row:SetAttribute("Ore", oreName)
    end
end
local function hex(color) return "#" .. color:ToHex() end

local function bestOre(rockName, onlySelected)
    local bestName, bestPower = nil, -1
    for _, name in ipairs(Rocks[rockName] and Rocks[rockName].Ores or {}) do
        local power = Planner.orePower(name, Ores)
        if (not onlySelected or api.SelectedOres[name]) and power > bestPower then bestName, bestPower = name, power end
    end
    return bestName, math.max(bestPower, 0)
end
local function rockPart(rock)
    local part = rock:FindFirstChild("Hitbox")
    if part and part:IsA("BasePart") then return part end
    return rock.PrimaryPart or rock:FindFirstChildWhichIsA("BasePart", true)
end

-- Text einer Infotafel setzen. Die TextLabel-Kinder koennen zur Laufzeit verschwinden (ein Spielskript raeumt GUIs
-- auf) -> vorher kam jede Sekunde "Label is not a valid member of BillboardGui". Fehlt das Label, neu anlegen.
-- isTarget = true: Tafel am aktuellen Ziel (fett, gelb), sonst Erz-ESP (weiss).
local function setBoardText(board, text, isTarget)
    local label = board:FindFirstChild("Label")
    if not (label and label:IsA("TextLabel")) then
        label = Instance.new("TextLabel")
        label.Name, label.Size, label.BackgroundTransparency, label.RichText = "Label", UDim2.fromScale(1, 1), 1, true
        label.Font = isTarget and Enum.Font.GothamBold or Enum.Font.GothamSemibold
        label.TextSize = isTarget and 14 or 13
        label.TextColor3 = isTarget and Color3.fromRGB(255, 225, 120) or Color3.new(1, 1, 1)
        label.TextStrokeTransparency = isTarget and 0.2 or 0.3
        label.Parent = board
    end
    label.Text = text
end
local espBoards = {}
local function espBoard(rock)
    local board = espBoards[rock]
    if board and not board.Parent then board:Destroy(); board = nil end -- von aussen entfernt -> neu
    if not board then
        board = Instance.new("BillboardGui")
        board.Size, board.AlwaysOnTop, board.LightInfluence = UDim2.fromOffset(180, 34), true, 0
        board.StudsOffsetWorldSpace, board.MaxDistance = Vector3.new(0, 3, 0), math.huge
        board.Parent = espFolder
        espBoards[rock] = board
    end
    return board
end

local function refreshVisuals()
    local hasSelection = next(api.SelectedOres) ~= nil or next(api.SelectedRocks) ~= nil
    local wantCounter = api.ShowCounter and (hasSelection or next(api.SelectedMobs) ~= nil)
    -- Mobs zaehlen (lebend), auch Arten mit 0 anzeigen.
    local mobCounts = {}
    for name in pairs(api.SelectedMobs) do mobCounts[name] = 0 end
    if next(mobCounts) then
        for _, mob in ipairs(workspace.Living:GetChildren()) do
            if mob:GetAttribute("IsNpc") and not Players:GetPlayerFromCharacter(mob) then
                local key = mobKey(mob)
                if mobCounts[key] and healthOf(mob, "Kill") > 0 then mobCounts[key] += 1 end
            end
        end
    end
    -- Steine: Zaehler je ausgewaehltem Erz/Stein und ESP-Kandidaten in einem Durchlauf.
    local oreCounts, rockCounts, espCandidates = {}, {}, {}
    for name in pairs(api.SelectedOres) do oreCounts[name] = 0 end
    for name in pairs(api.SelectedRocks) do rockCounts[name] = 0 end
    local here = root and root.Parent and root.Position
        or (player.Character and player.Character:FindFirstChild("HumanoidRootPart") and player.Character.HumanoidRootPart.Position)
    if wantCounter or api.OreEsp then
        for _, rock in ipairs(workspace.Rocks:GetDescendants()) do
            local rockData = rock:IsA("Model") and Rocks[rock.Name]
            if rockData and rock:GetAttribute("IsInitiated") and healthOf(rock, "Mine") > 0 then
                for _, ore in ipairs(rockData.Ores or {}) do if oreCounts[ore] then oreCounts[ore] += 1 end end
                if rockCounts[rock.Name] then rockCounts[rock.Name] += 1 end
                if api.OreEsp and here then
                    local matches
                    if hasSelection then matches = Planner.rockMatches(rock.Name, rockData.Ores, api.SelectedOres, api.SelectedRocks)
                    else matches = select(2, bestOre(rock.Name, false)) >= api.EspMinMultiplier end
                    if matches then
                        local part = rockPart(rock)
                        if part then table.insert(espCandidates, {rock = rock, part = part, distance = (part.Position - here).Magnitude}) end
                    end
                end
            end
        end
    end
    -- Zaehler-Anzeige ueber der Level-Anzeige des Spiels.
    if wantCounter then
        local lines = {}
        for _, name in ipairs(Planner.sortedChoices(mobCounts)) do
            local n = mobCounts[name]
            table.insert(lines, {text = string.format('<font color="%s">●</font> %s  <b><font color="%s">%d</font></b>', "#FF6B6B", name, n > 0 and "#FFFFFF" or "#888888", n)})
        end
        for _, name in ipairs(Planner.sortedChoices(oreCounts, Ores)) do
            local n = oreCounts[name]
            local have = data().Inventory[name] or 0
            table.insert(lines, {ore = name, text = string.format('%s <font color="#AAAAAA">%g×</font>  <b><font color="%s">%d</font></b> <font color="#AAAAAA">rocks · have %d</font>',
                name, Planner.orePower(name, Ores), n > 0 and "#FFFFFF" or "#888888", n, have)})
        end
        for _, name in ipairs(Planner.sortedChoices(rockCounts)) do
            local n = rockCounts[name]
            table.insert(lines, {text = string.format('<font color="#BBBBBB">■</font> %s  <b><font color="%s">%d</font></b>', name, n > 0 and "#FFFFFF" or "#888888", n)})
        end
        for index, line in ipairs(lines) do setCounterRow(index, line.text, line.ore) end
        for index = #lines + 1, #counterRows do counterRows[index].Visible = false end
        local main = player.PlayerGui:FindFirstChild("Main")
        local level = main and main:FindFirstChild("Screen") and main.Screen:FindFirstChild("Hud") and main.Screen.Hud:FindFirstChild("Level")
        if level and level:IsA("GuiObject") and level.AbsoluteSize.Y > 0 then
            -- + Leistenhoehe: AbsolutePosition zaehlt ab unter der Roblox-Leiste, das Overlay ab der Bildschirmkante
            local inset = overlayGui.IgnoreGuiInset and game:GetService("GuiService"):GetGuiInset().Y or 0
            counter.Position = UDim2.fromOffset(level.AbsolutePosition.X, level.AbsolutePosition.Y + inset - 6)
        else
            counter.Position = UDim2.new(0, 20, 1, -150)
        end
    end
    counter.Visible = wantCounter
    -- Erz-ESP: die 40 naechsten passenden Steine beschriften.
    table.sort(espCandidates, function(a, b) return a.distance < b.distance end)
    local keep = {}
    for index = 1, math.min(40, #espCandidates) do
        local entry = espCandidates[index]
        local oreName, power = bestOre(entry.rock.Name, hasSelection and next(api.SelectedOres) ~= nil)
        local board = espBoard(entry.rock)
        board.Adornee = entry.part
        setBoardText(board, string.format('<b>%s</b>\n<font color="%s">%s %g×</font> · %d studs', entry.rock.Name, hex(worldColor), oreName or "?", power, math.floor(entry.distance)), false)
        keep[entry.rock] = true
    end
    for rock, board in pairs(espBoards) do
        if not keep[rock] then board:Destroy(); espBoards[rock] = nil end
    end
end

-- Target-ESP und Fluglinie (jeden Frame, damit die Linie dem Flug folgt).
local targetHighlight, targetBoard, lineBeam, lineStart, lineEnd
local function hideTargetVisuals()
    if targetHighlight then targetHighlight:Destroy(); targetHighlight = nil end
    if targetBoard then targetBoard.Enabled = false end
    if lineBeam then lineBeam.Enabled = false end
end
local function updateTargetVisuals()
    local target = api.Enabled and api.Running and activeTarget and activeTarget.Parent and activeTarget or nil
    local targetPosition
    if target then
        local part = target:FindFirstChild("HumanoidRootPart") or rockPart(target)
        targetPosition = part and part.Position or target:GetPivot().Position
    elseif api.Enabled and api.Running and destination then
        targetPosition = destination.Position
    end
    -- Umriss + Infotafel am aktuellen Ziel
    if api.TargetEsp and target then
        if not targetHighlight or targetHighlight.Adornee ~= target then
            if targetHighlight then targetHighlight:Destroy() end
            targetHighlight = Instance.new("Highlight")
            targetHighlight.FillColor, targetHighlight.FillTransparency = Color3.fromRGB(255, 210, 80), 0.65
            targetHighlight.OutlineColor, targetHighlight.OutlineTransparency = Color3.new(1, 1, 1), 0
            targetHighlight.DepthMode, targetHighlight.Adornee = Enum.HighlightDepthMode.AlwaysOnTop, target
            targetHighlight.Parent = target
        end
        if targetBoard and not targetBoard.Parent then targetBoard:Destroy(); targetBoard = nil end
        if not targetBoard then
            targetBoard = Instance.new("BillboardGui")
            targetBoard.Size, targetBoard.AlwaysOnTop, targetBoard.LightInfluence = UDim2.fromOffset(200, 36), true, 0
            targetBoard.StudsOffsetWorldSpace, targetBoard.MaxDistance = Vector3.new(0, 5, 0), math.huge
            targetBoard.Parent = espFolder
        end
        local isMob = target:FindFirstChildOfClass("Humanoid") ~= nil
        local health = healthOf(target, isMob and "Kill" or "Mine")
        targetBoard.Adornee = target:FindFirstChild("HumanoidRootPart") or rockPart(target)
        setBoardText(targetBoard, string.format("▶ %s\n<font color=\"#FFFFFF\">HP %s · %d studs</font>", isMob and mobKey(target) or target.Name,
            commas(health), math.floor(root and root.Parent and targetPosition and (targetPosition - root.Position).Magnitude or 0)), true)
        targetBoard.Enabled = true
    else
        if targetHighlight then targetHighlight:Destroy(); targetHighlight = nil end
        if targetBoard then targetBoard.Enabled = false end
    end
    -- Fluglinie vom Spieler zum Ziel
    if api.PathLine and targetPosition and root and root.Parent then
        -- Alles im Terrain statt am Charakter: ein Spielskript setzt Effekte am Charakter auf Transparenz 1,
        -- dadurch war die Linie vorher unsichtbar.
        if not lineBeam or lineBeam.Parent ~= workspace.Terrain then
            for _, object in pairs({lineBeam, lineStart, lineEnd}) do object:Destroy() end
            lineStart = Instance.new("Attachment")
            lineStart.Name, lineStart.Parent = "ForgeHelperLineStart", workspace.Terrain
            lineEnd = Instance.new("Attachment")
            lineEnd.Name, lineEnd.Parent = "ForgeHelperLineEnd", workspace.Terrain
            lineBeam = Instance.new("Beam")
            lineBeam.Name, lineBeam.Attachment0, lineBeam.Attachment1 = "ForgeHelperLine", lineStart, lineEnd
            lineBeam.Width0, lineBeam.Width1, lineBeam.FaceCamera, lineBeam.Segments = 0.45, 0.45, true, 1
            lineBeam.LightEmission, lineBeam.LightInfluence = 1, 0
            lineBeam.Color = ColorSequence.new(Color3.fromRGB(90, 200, 255), Color3.fromRGB(255, 220, 90))
            lineBeam.Parent = workspace.Terrain
        end
        lineBeam.Transparency = NumberSequence.new(0.1) -- jedes Mal setzen, falls etwas sie wieder ausblendet
        lineStart.WorldPosition = root.Position
        lineEnd.WorldPosition = targetPosition
        lineBeam.Enabled = true
    elseif lineBeam then
        lineBeam.Enabled = false
    end
end
track(RunService.RenderStepped:Connect(function()
    local ok, why = pcall(updateTargetVisuals)
    if not ok then api.LastError = "Visuals: " .. tostring(why); hideTargetVisuals() end
end))
task.spawn(function()
    while not destroyed do
        local ok, why = pcall(refreshVisuals)
        if not ok then api.LastError = "Visuals: " .. tostring(why) end
        task.wait(1)
    end
end)
api.DestroyVisuals = function()
    hideTargetVisuals()
    -- pairs statt ipairs: ipairs bricht beim ersten nil (z. B. noch keine Linie erstellt) ab.
    for _, object in pairs({lineBeam, lineStart, lineEnd, targetBoard, targetHighlight, overlayGui, espFolder}) do
        pcall(object.Destroy, object)
    end
    table.clear(espBoards)
end
do -- GOAL_HUD: Anzeige direkt ueber der Quest-Liste des Spiels (PlayerGui.Main.Screen.Tracker), solange der Bot im
   -- Farm-Modus "Forging" fuer ein bestimmtes Item farmt. Gleiche Zeilen wie die Liste im Forging-Tab.
    -- Nur zwei lokale Variablen hier: der Visuals-Block ist nahe am Luau-Limit von 200 gleichzeitigen Variablen.
    local hud, H = Instance.new("Frame"), {last = nil :: string?}
    hud.Name, hud.AnchorPoint, hud.BackgroundColor3, hud.BackgroundTransparency = "GoalHud", Vector2.new(0, 1), Color3.fromRGB(14, 17, 15), 0.12
    hud.Size, hud.AutomaticSize, hud.Visible, hud.Parent = UDim2.fromOffset(330, 0), Enum.AutomaticSize.Y, false, overlayGui
    Instance.new("UICorner", hud).CornerRadius = UDim.new(0, 8)
    H.stroke = Instance.new("UIStroke", hud)
    H.stroke.Color, H.stroke.Transparency, H.stroke.Thickness = Color3.fromRGB(214, 170, 80), 0.25, 1.2
    H.padding = Instance.new("UIPadding", hud)
    H.padding.PaddingTop, H.padding.PaddingBottom, H.padding.PaddingLeft, H.padding.PaddingRight = UDim.new(0, 6), UDim.new(0, 6), UDim.new(0, 6), UDim.new(0, 6)
    H.layout = Instance.new("UIListLayout", hud)
    H.layout.Padding, H.layout.SortOrder = UDim.new(0, 4), Enum.SortOrder.LayoutOrder
    H.guiService = game:GetService("GuiService")
    function H.label(parent, props)
        local object = Instance.new("TextLabel")
        object.BackgroundTransparency, object.Font, object.TextSize = 1, Enum.Font.GothamBold, 13
        object.TextColor3, object.TextXAlignment, object.TextTruncate = Color3.fromRGB(240, 240, 240), Enum.TextXAlignment.Left, Enum.TextTruncate.AtEnd
        for key, value in pairs(props) do object[key] = value end
        object.Parent = parent
        return object
    end
    H.head = Instance.new("Frame")
    H.head.BackgroundTransparency, H.head.Size, H.head.LayoutOrder, H.head.Parent = 1, UDim2.new(1, 0, 0, 34), 0, hud
    H.title = H.label(H.head, {Size = UDim2.new(0.65, 0, 0, 18), TextColor3 = Color3.fromRGB(255, 214, 120), TextSize = 14})
    H.progress = H.label(H.head, {AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.new(0.35, 0, 0, 18),
        TextXAlignment = Enum.TextXAlignment.Right, TextSize = 12})
    H.status = H.label(H.head, {Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 0, 16), Font = Enum.Font.Gotham,
        TextSize = 11, TextColor3 = Color3.fromRGB(175, 185, 180)})
    H.list = Instance.new("ScrollingFrame")
    H.list.Name, H.list.BackgroundTransparency, H.list.BorderSizePixel = "Materials", 1, 0
    H.list.ScrollingDirection, H.list.ScrollBarThickness = Enum.ScrollingDirection.Y, 4
    H.list.VerticalScrollBarInset, H.list.ScrollBarImageColor3 = Enum.ScrollBarInset.ScrollBar, Color3.fromRGB(214, 170, 80)
    H.list.CanvasSize, H.list.Active, H.list.LayoutOrder = UDim2.fromOffset(0, 0), true, 1
    H.list.Parent = hud
    H.rows = Instance.new("UIListLayout", H.list)
    H.rows.Padding, H.rows.SortOrder = H.layout.Padding, Enum.SortOrder.LayoutOrder
    H.rowHeight = 36
    function H.update()
        local label, GuiService = H.label, H.guiService
        local plan = forgeGoal.plan
        -- api.GoalHudPreview (nur zum Testen per Script): Anzeige zeigen, ohne dass der Bot laeuft
        local show = api.GoalHud and (api.GoalHudPreview or (api.Enabled and api.Running and api.FarmMode == "Forging" and api.ForgeGoalActive))
            and type(plan) == "table" and plan.recipe ~= nil and not plan.error
        hud.Visible = show and true or false
        if not show then H.list.CanvasPosition = Vector2.zero; return end
        -- Position: unten buendig direkt ueber dem "QUESTS"-Kasten des Spiels, gleiche Breite
        local main = player.PlayerGui:FindFirstChild("Main")
        local screen = main and main:FindFirstChild("Screen")
        local tracker = screen and screen:FindFirstChild("Tracker")
        local availableHeight = 300
        if tracker and tracker:IsA("GuiObject") and tracker.AbsoluteSize.X > 0 then
            -- AbsolutePosition zaehlt immer ab UNTER der Roblox-Leiste; unser Overlay (IgnoreGuiInset) positioniert ab der
            -- Bildschirmkante -> Leistenhoehe (58 px) dazurechnen, sonst sitzt die Anzeige zu hoch
            local inset = overlayGui.IgnoreGuiInset and GuiService:GetGuiInset().Y or 0
            hud.Position = UDim2.fromOffset(tracker.AbsolutePosition.X, tracker.AbsolutePosition.Y + inset - 8)
            hud.Size = UDim2.fromOffset(tracker.AbsoluteSize.X, 0)
            availableHeight = tracker.AbsolutePosition.Y - 8
        else
            hud.Position, hud.Size = UDim2.fromOffset(14, 300), UDim2.fromOffset(330, 0)
        end
        local entries = api.GoalEntries and api.GoalEntries(plan) or {}
        local contentHeight = #entries * H.rowHeight + math.max(0, #entries - 1) * H.rows.Padding.Offset
        local chromeHeight = H.head.Size.Y.Offset + H.padding.PaddingTop.Offset + H.padding.PaddingBottom.Offset + H.layout.Padding.Offset
        local listHeight = math.min(contentHeight, math.max(0, availableHeight - chromeHeight))
        H.list.Size = UDim2.new(1, 0, 0, listHeight)
        H.list.Visible = listHeight > 0
        H.list.CanvasSize = UDim2.fromOffset(0, contentHeight)
        hud.Visible = availableHeight >= chromeHeight
        local ready, total = 0, 0
        for oreName, needed in pairs(plan.recipe) do
            total += 1
            if needed - ((plan.missing or {})[oreName] or 0) >= needed then ready += 1 end
        end
        H.title.Text = string.format("⚒ FORGING · %s", tostring(plan.label or plan.className or "?"))
        H.progress.Text = ready == total and "all ores ready" or string.format("%d/%d ores ready", ready, total)
        H.progress.TextColor3 = ready == total and Color3.fromRGB(110, 220, 140) or Color3.fromRGB(255, 190, 90)
        H.status.Text = tostring(api.State)
        local parts = {}
        for _, entry in ipairs(entries) do table.insert(parts, table.concat({entry.title, entry.count, entry.status, entry.sub}, "\0")) end
        local signature = table.concat(parts, "|")
        if signature == H.last then return end
        H.last = signature
        for _, child in ipairs(H.list:GetChildren()) do if child:IsA("Frame") then child:Destroy() end end
        for index, entry in ipairs(entries) do
            local row = Instance.new("Frame")
            row.Size, row.LayoutOrder = UDim2.new(1, 0, 0, H.rowHeight), index
            row.BackgroundColor3, row.BackgroundTransparency = Color3.fromRGB(28, 30, 32), 0.1
            Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)
            local stroke = Instance.new("UIStroke", row)
            stroke.Color, stroke.Transparency = entry.ok and Color3.fromRGB(70, 170, 100) or Color3.fromRGB(200, 140, 60), 0.35
            local icon = api.OreIcon(entry.name, 28)
            if icon then icon.Position, icon.Parent = UDim2.fromOffset(4, 4), row end
            label(row, {Position = UDim2.fromOffset(38, 2), Size = UDim2.new(0.62, -38, 0, 17), Text = entry.title})
            label(row, {Position = UDim2.fromOffset(38, 18), Size = UDim2.new(0.62, -38, 0, 15), Text = entry.sub, Font = Enum.Font.Gotham,
                TextSize = 11, TextColor3 = Color3.fromRGB(165, 170, 168)})
            local color = entry.ok and Color3.fromRGB(110, 220, 140) or Color3.fromRGB(255, 190, 90)
            label(row, {AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -6, 0, 2), Size = UDim2.new(0.38, 0, 0, 17), Text = entry.count,
                TextXAlignment = Enum.TextXAlignment.Right, TextSize = 14, TextColor3 = color})
            label(row, {AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -6, 0, 18), Size = UDim2.new(0.38, 0, 0, 15), Text = entry.status,
                TextXAlignment = Enum.TextXAlignment.Right, Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = color})
            row.Parent = H.list
        end
    end
    task.spawn(function()
        while not destroyed and hud.Parent do
            local ok, why = pcall(H.update)
            if not ok then api.LastError = "Goal HUD: " .. tostring(why) end
            task.wait(1)
        end
    end)
end
-- VISUALS_END
end

do -- MANUAL_FLY_START: selbst fliegen, solange der Bot nicht farmt (Schalter ✈ in der Titelleiste)
    local UserInputService = game:GetService("UserInputService")
    local flying, flyPosition, flyBody = false, nil, nil
    local function setFlying(on)
        local human = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
        if human then human.PlatformStand = on end -- Humanoid kaempft dann nicht gegen die Bewegung (kein Fallen/Laufen)
        flying, flyPosition = on, nil
    end
    api.StopManualFly = function() if flying then setFlying(false) end end
    track(RunService.PreSimulation:Connect(function(dt)
        local body = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
        local wanted = api.ManualFly and not (api.Enabled and api.Running) and not FC.ForgeActive and body ~= nil
        if not wanted then
            if flying then setFlying(false) end
            return
        end
        if not flying then setFlying(true) end
        local camera = workspace.CurrentCamera
        local move = Vector3.zero
        if not UserInputService:GetFocusedTextBox() then
            local function down(key) return UserInputService:IsKeyDown(key) end
            if down(Enum.KeyCode.W) then move += camera.CFrame.LookVector end
            if down(Enum.KeyCode.S) then move -= camera.CFrame.LookVector end
            if down(Enum.KeyCode.D) then move += camera.CFrame.RightVector end
            if down(Enum.KeyCode.A) then move -= camera.CFrame.RightVector end
            if down(Enum.KeyCode.Space) then move += Vector3.yAxis end
            if down(Enum.KeyCode.LeftControl) or down(Enum.KeyCode.Q) then move -= Vector3.yAxis end
        end
        -- Eigene Position fuehren (nicht body.Position lesen): sonst zieht die Schwerkraft pro Frame ein Stueck nach unten.
        if not flyPosition or flyBody ~= body then flyPosition, flyBody = body.Position, body end
        flyPosition += move.Magnitude > 0 and move.Unit * api.Speed * dt or Vector3.zero
        local position = flyPosition
        local look = Vector3.new(camera.CFrame.LookVector.X, 0, camera.CFrame.LookVector.Z)
        body.CFrame = look.Magnitude > 0.01 and CFrame.lookAt(position, position + look) or CFrame.new(position)
        body.AssemblyLinearVelocity, body.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
    end))
end -- MANUAL_FLY_END

do -- eigener Block (Limit fuer lokale Variablen)
-- AUTO_REJOIN_START
-- Bei Kick/Verbindungsabbruch (Roblox-Fehlerfenster) dem Spiel neu beitreten. Nach dem Beitritt laedt Potassium
-- workspace/ForgeHelper.lua neu (queueonteleport); lief das Farmen vorher, startet es automatisch wieder.
local TeleportService = game:GetService("TeleportService")
local GuiService = game:GetService("GuiService")
local RESUME_FILE = "ForgeHelper.resume"
local rejoining, teleporting = false, false
track(player.OnTeleport:Connect(function(state)
    teleporting = state ~= Enum.TeleportState.Failed
end))
local function rejoin(reason)
    if reason == "DisconnectClientInitiated" or rejoining or teleporting or destroyed or not api.AutoRejoin then return end
    rejoining = true
    task.spawn(function()
        task.wait(3)
        if teleporting or destroyed or not api.AutoRejoin then rejoining = false; return end
        warn("[ForgeHelper] Auto-Rejoin: " .. tostring(reason))
        pcall(writefile, RESUME_FILE, os.time() .. "|" .. tostring(api.WantRunning == true))
        if type(queueonteleport) == "function" then pcall(queueonteleport, forgeGoal.loader) end
        for attempt = 1, 30 do
            if destroyed or not api.AutoRejoin then break end
            if not teleporting then pcall(function() TeleportService:Teleport(game.PlaceId, player) end) end
            if attempt < 30 then task.wait(10) end
        end
        rejoining = false
    end)
end
-- ErrorMessageChanged verlangt die RobloxScript-Berechtigung (Identitaet 8, wie beim Menue).
if type(setIdentity) == "function" then setIdentity(8) end
local connected, connectError = pcall(function()
    track(GuiService.ErrorMessageChanged:Connect(function(message)
        if type(message) == "string" and message ~= "" then rejoin(message) end
    end))
end)
if type(setIdentity) == "function" then setIdentity(2) end
if not connected then warn("[ForgeHelper] Auto-Rejoin unavailable: " .. tostring(connectError)) end
-- Nach einem Rejoin: Farmen fortsetzen, wenn es vorher lief (Datei hoechstens 10 Minuten alt).
if type(isfile) == "function" and isfile(RESUME_FILE) then
    local content = readfile(RESUME_FILE)
    pcall(delfile, RESUME_FILE)
    local stamp, wasRunning = content:match("^(%d+)|(%a+)$")
    local resumeAt = tonumber(stamp)
    if resumeAt and wasRunning == "true" and os.time() - resumeAt < 600 then
        task.spawn(function()
            for _ = 1, 20 do
                task.wait(3)
                if destroyed or api.Running then break end
                api.WantRunning = true
                if not stats.startTime then resetStats() end
                if api:Start() then log("Auto-Rejoin: farming resumed"); break end
            end
        end)
    end
end
-- Nach einer Reise fuers Schmiede-Ziel (hoechstens 15 Minuten her): Ziel und Farmen fortsetzen
if type(isfile) == "function" and isfile(forgeGoal.resumeFile) then
    local stamp = tonumber(readfile(forgeGoal.resumeFile))
    pcall(delfile, forgeGoal.resumeFile)
    if stamp and os.time() - stamp < 900 then
        api.FarmMode, api.ForgeGoalActive = "Forging", true
        pcall(function()
            if type(setIdentity) == "function" then setIdentity(8) end
            local option = api.MenuOptions and api.MenuOptions.ForgeFarmMode
            if option and option.Value ~= "Forging" then option:SetValue("Forging") end
            if type(setIdentity) == "function" then setIdentity(2) end
        end)
        task.spawn(function()
            for _ = 1, 20 do
                task.wait(3)
                if destroyed or api.Running then break end
                api.WantRunning = true
                if not stats.startTime then resetStats() end
                if api:Start() then log("Forge goal: resumed after island travel"); break end
            end
        end)
    end
end
-- AUTO_REJOIN_END
end
-- AUTO_RESTART_START
-- Startet das Farmen nach Tod, Fehler oder internem Stop neu, solange der Spieler nicht selbst STOP gedrueckt hat.
task.spawn(function()
    while not destroyed do
        task.wait(3)
        if api.AutoRestart and api.WantRunning and not api.Running and not destroyed then
            local current = player.Character
            local human = current and current:FindFirstChildOfClass("Humanoid")
            if human and human.Health > 0 and current:FindFirstChild("HumanoidRootPart") then
                if type(setIdentity) == "function" then setIdentity(2) end
                pcall(api.Start, api)
            end
        end
    end
end)
-- AUTO_RESTART_END
-- FORGE_LOOP_START
local forgeRetryAt = 0
task.spawn(function()
    while not destroyed do
        if FC.ForgeActive and FC.Sequence ~= "OreSelect" and not forgeBusy and os.clock() >= forgeRetryAt then
            forgeBusy = true
            local ok, why = pcall(assistForge)
            releaseForge()
            forgeBusy = false
            if not ok then
                forgeRetryAt = os.clock() + 5
                api.LastError = tostring(why)
                warn("[ForgeHelper] Forge helper stopped: " .. tostring(why))
                log("Forge helper error; check output")
            end
        end
        task.wait(0.2)
    end
end)
-- FORGE_LOOP_END
print("[ForgeHelper] Fluent menu loaded. Master OFF; forge minigames ALWAYS ON. " .. api.MenuKey .. ": toggle menu.")
