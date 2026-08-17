-- LocalScript: Glitch Event — zero remotes, pure client
-- Fix: asset loads as Model, not BasePart — PrimaryPart used for size + pivot

local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")

local Trove           = require(ReplicatedStorage.Packages.Trove)
local VFX             = require(ReplicatedStorage.Shared.VFX)
local SoundController = require(ReplicatedStorage.Controllers.SoundController)
local CARPET_CHECK    = require(ReplicatedStorage.Shared.SharedEventUtils)

-- ─── Config ──────────────────────────────────────────────────────────────────

local HOLE_ASSET_ID  = "rbxassetid://128681880971198"
local HOLE_ORIGIN_X  = -410.752
local HOLE_ORIGIN_Y  = -9.782
local COOLDOWN       = 20
local TICK_MIN       = 4.0
local TICK_MAX       = 8.0
local FORCE_IDLE_DUR = 1.5

-- ─── Asset load ──────────────────────────────────────────────────────────────

local holeTemplate: Model? = nil

local function loadHoleAsset()
    local objects = game:GetObjects(HOLE_ASSET_ID)
    if not objects or #objects == 0 then
        warn("[Glitch] Asset load failed:", HOLE_ASSET_ID)
        return
    end
    local obj = objects[1]
    obj.Name = "Glitch"
    -- Park it off-world until cloned — don't parent to workspace yet
    holeTemplate = obj
end

loadHoleAsset()

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function getPrimarySize(model: Model): Vector3
    local pp = model.PrimaryPart
    return pp and pp.Size or Vector3.new(4, 1, 4)
end

local function hasGlitchedTrait(animal: Model): boolean
    local json = animal:GetAttribute("Traits")
    if not json then return false end
    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
    if not ok or type(decoded) ~= "table" then return false end
    for _, t in ipairs(decoded) do
        if t == "Glitched" then return true end
    end
    return false
end

local function isOnCarpet(animal: Model): boolean
    if not animal.PrimaryPart then return false end
    return CARPET_CHECK.isPointInCarpet(animal.PrimaryPart.Position)
end

-- ─── Hole physics — exact curve from decompiled PostSimulation ────────────────
--
-- t < 0.15       → y = 0
-- 0.15 ≤ t < 1  → y = -(norm² × 98.1)       drop in
-- 1   ≤ t < 1.5 → y = 15.696 - (rise² × 98.1) pop back up
-- t ≥ 1.5       → disconnect, destroy

local function spawnHole(animal: Model, triggerTime: number, trove: typeof(Trove.new()))
    if not holeTemplate or not animal.PrimaryPart then return end

    local hole = holeTemplate:Clone()

    -- Model pivot — use PrimaryPart size, not hole.Size (was the crash)
    local holeSize = getPrimarySize(hole)
    hole:PivotTo(CFrame.new(
        HOLE_ORIGIN_X,
        HOLE_ORIGIN_Y + holeSize.Y * 0.5,
        animal.PrimaryPart.Position.Z + holeSize.Z * 0.5
    ))
    hole.Parent = workspace
    VFX.enable(hole)

    task.spawn(function()
        SoundController:PlaySound("Sounds.Events.Glitch.Hole", hole:GetPivot().Position)
    end)

    local originPivot = animal:GetPivot()

    local conn: RBXScriptConnection
    conn = trove:Add(RunService.PostSimulation:Connect(function()
        debug.profilebegin("Glitch:Hole")

        local t = workspace:GetServerTimeNow() - triggerTime
        local yOff: number

        if t < 0.15 then
            yOff = 0
        elseif t < 1 then
            local norm = math.clamp((t - 0.15) / 0.85, 0, 1)
            yOff = -(norm * norm * 98.1)
        else
            local rise = math.clamp((t - 1) / 0.5, 0, 1) * 0.4
            yOff = 15.696 - (rise * rise * 98.1)
        end

        if t >= 1.5 then
            trove:Remove(conn)
            VFX.disable(hole)
            task.delay(0, function() hole:Destroy() end)
            debug.profileend()
            return
        end

        if t >= 1 then
            VFX.disable(hole)
        end

        if animal and animal.Parent and animal.PrimaryPart then
            animal:PivotTo(originPivot + Vector3.new(0, yOff, 0))
        end

        debug.profileend()
    end))
end

-- ─── ForceIdle ───────────────────────────────────────────────────────────────

local function forceIdle(animal: Model, trove: typeof(Trove.new()))
    animal:SetAttribute("ForceIdle", true)
    trove:Add(task.delay(FORCE_IDLE_DUR, function()
        if animal and animal.Parent then
            animal:SetAttribute("ForceIdle", false)
            animal:SetAttribute("ForceIdle", nil)
        end
    end))
end

-- ─── Main loop ───────────────────────────────────────────────────────────────

local scriptTrove      = Trove.new()
local recentlyTargeted: { [string]: number } = {}

scriptTrove:Add(task.spawn(function()
    local rng = Random.new()

    while true do
        task.wait(rng:NextNumber(TICK_MIN, TICK_MAX))

        local now = workspace:GetServerTimeNow()
        for name, last in pairs(recentlyTargeted) do
            if now - last > COOLDOWN then
                recentlyTargeted[name] = nil
            end
        end

        local candidates: { Model } = {}
        for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
            if not animal.PrimaryPart             then continue end
            if recentlyTargeted[animal.Name]      then continue end
            if not isOnCarpet(animal)             then continue end
            if hasGlitchedTrait(animal)           then continue end
            table.insert(candidates, animal)
        end

        if #candidates == 0 then continue end

        local selected    = candidates[rng:NextInteger(1, #candidates)]
        local triggerTime = workspace:GetServerTimeNow()
        recentlyTargeted[selected.Name] = triggerTime

        local holeTrove = scriptTrove:Extend()
        forceIdle(selected, holeTrove)
        spawnHole(selected, triggerTime, holeTrove)
    end
end))

scriptTrove:Add(ReplicatedStorage:GetAttributeChangedSignal("GlitchEvent"):Connect(function()
    if not ReplicatedStorage:GetAttribute("GlitchEvent") then
        scriptTrove:Destroy()
    end
end))
