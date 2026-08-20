local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")

if not game:IsLoaded() then game.Loaded:Wait() end

local Trove            = require(ReplicatedStorage.Packages.Trove)
local VFX              = require(ReplicatedStorage.Shared.VFX)
local MathUtils        = require(ReplicatedStorage.Utils.MathUtils)
local SharedEventUtils = require(ReplicatedStorage.Shared.SharedEventUtils)
local SoundController  = require(ReplicatedStorage.Controllers.SoundController)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)

local EVENT_NAME  = "4th of July"
local EventAssets = ReplicatedStorage.Controllers.EventController.Events[EVENT_NAME]
local Sounds      = ReplicatedStorage.Sounds.Events[EVENT_NAME]

local BLOCKING_TRAIT        = "Fireworks"
local FIREWORK_HIT_RADIUS   = 10
local FALLOFF_TRAVEL_TIME   = 2.3
local FALLOFF_SPREAD_RADIUS = 70
local FIREWORK_HEIGHT_MIN   = 80
local FIREWORK_HEIGHT_MAX   = 120
local FIREWORK_EFFECT_COUNT = 3
local FALLOFF_COUNT_MIN     = 6
local FALLOFF_COUNT_MAX     = 9

local RayParams = RaycastParams.new()
RayParams.FilterType = Enum.RaycastFilterType.Include
RayParams.FilterDescendantsInstances = {
    workspace:WaitForChild("Map"),
    workspace:WaitForChild("Plots"),
}

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)
local eventData = EventController:GetActiveEventData(EVENT_NAME)

local eventTrove = Trove.new()
local isActive   = true

-- ─── Trait helpers ────────────────────────────────────────────────────────────

local function getTraits(animal)
    local json = animal:GetAttribute("Traits")
    if not json then return {}, {} end
    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
    if not ok or type(decoded) ~= "table" then return {}, {} end
    local set = {}
    for _, t in ipairs(decoded) do set[t] = true end
    return decoded, set
end

local function hasTrait(animal, trait)
    local _, set = getTraits(animal)
    return set[trait] == true
end

local function addTrait(animal, trait)
    local list, set = getTraits(animal)
    if set[trait] then return end
    table.insert(list, trait)
    animal:SetAttribute("Traits", HttpService:JSONEncode(list))
end

local function getAnimalsNear(pos, radius)
    local out = {}
    for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
        if animal.PrimaryPart and (animal.PrimaryPart.Position - pos).Magnitude <= radius then
            table.insert(out, animal)
        end
    end
    return out
end

-- ─── Firework ─────────────────────────────────────────────────────────────────

local function fireOne(launcher, originalCFrames)
    local launchCF = originalCFrames[launcher]
    local height   = math.random(FIREWORK_HEIGHT_MIN, FIREWORK_HEIGHT_MAX)
    local peakCF   = launchCF + Vector3.new(0, height, 0)
    local travel   = height / 20

    local startup = EventAssets.FireworkStartup:Clone()
    startup.CFrame = launchCF + Vector3.new(0, launcher.Size.Y * 0.5 - startup.Size.Y * 0.5, 0)
    startup.Parent = workspace
    VFX.emit(startup)
    local shotSfx = Sounds.Shot:Clone()
    shotSfx.Parent = startup
    SoundController:PlaySound(shotSfx)
    task.delay(2, function() startup:Destroy() end)

    local proj = EventAssets.Firework:Clone()
    proj.CFrame = launchCF
    proj.Parent = workspace
    local trailSfx = Sounds["Trail Sound Ball"]:Clone()
    trailSfx.Parent = proj
    SoundController:PlaySound(trailSfx)

    local rise = TweenService:Create(proj,
        TweenInfo.new(travel, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { CFrame = peakCF }
    )
    rise:Play()

    task.delay(travel * 0.8, function()
        rise:Destroy()
        proj:Destroy()

        SoundController:PlaySound(Sounds["Firework Explosion"], peakCF.Position)

        local fx = EventAssets.Effects[tostring(math.random(1, FIREWORK_EFFECT_COUNT))]:Clone()
        fx.CFrame = peakCF
        fx.Parent = workspace
        VFX.emit(fx)
        task.delay(4, function() fx:Destroy() end)

        local groundCF = launchCF - Vector3.new(0, launcher.Size.Y, 0)

        for _ = 1, math.random(FALLOFF_COUNT_MIN, FALLOFF_COUNT_MAX) do
            local angle  = math.random() * math.pi * 2
            local r      = math.random() * FALLOFF_SPREAD_RADIUS
            local ox, oz = math.cos(angle) * r, math.sin(angle) * r
            local hit    = workspace:Raycast((peakCF + Vector3.new(ox, 0, oz)).Position, Vector3.new(0, -200, 0), RayParams)
            local destCF = hit and CFrame.new(hit.Position) or groundCF + Vector3.new(ox, 0, oz)

            local trail   = EventAssets.Falloff:Clone()
            trail.CFrame  = peakCF
            trail.Parent  = workspace
            local elapsed = 0
            local fired   = false
            local conn
            conn = RunService.PostSimulation:Connect(function(dt)
                debug.profilebegin("4th of July:Falloff")
                elapsed += dt
                local t = elapsed / FALLOFF_TRAVEL_TIME
                SharedEventUtils.pushPartCFrame(trail, CFrame.new(MathUtils.quadBezier(t,
                    peakCF.Position,
                    peakCF.Position + Vector3.new(0, height, 0) + (destCF.Position - peakCF.Position) * Vector3.new(1, 0, 1) * 0.7,
                    destCF.Position
                )))
                if t >= 1 and not fired then
                    fired = true
                    local impact = EventAssets.GroundImpact:Clone()
                    impact.CFrame = destCF + Vector3.new(0, impact.Size.Y * 0.5, 0)
                    impact.Parent = workspace
                    VFX.emit(impact)
                    VFX.disable(trail)
                    task.delay(3, function() trail:Destroy() impact:Destroy() end)
                    conn:Disconnect()

                    for _, animal in ipairs(getAnimalsNear(destCF.Position, FIREWORK_HIT_RADIUS)) do
                        if not hasTrait(animal, BLOCKING_TRAIT) then
                            ClientEventUtils.playBurst(EventAssets.FireworkBurst, animal.Name, {
                                Sounds["Brainrot Hit"],
                            })
                            addTrait(animal, BLOCKING_TRAIT)
                        end
                    end
                end
                debug.profileend()
            end)
            eventTrove:Add(conn)
        end
    end)
end

-- ─── Main ─────────────────────────────────────────────────────────────────────

local function main()
    local fireworksModel = workspace:WaitForChild("Fireworks", 30)
    if not fireworksModel then
        warn("[4thJuly] Fireworks model never appeared in workspace")
        return
    end

    local source        = ReplicatedStorage.Models.Events[EVENT_NAME].Fireworks
    local targets       = {}
    local launchers     = {}
    local originalCFrames = {}

    for _, p in source:GetChildren() do
        if p:IsA("BasePart") then targets[p.Name] = p.Position end
    end

    for _, p in fireworksModel:GetChildren() do
        if p:IsA("BasePart") and targets[p.Name] then
            table.insert(launchers, p)
            originalCFrames[p] = CFrame.new(targets[p.Name])
        end
    end

    if #launchers == 0 then
        warn("[4thJuly] No launcher parts found")
        return
    end

    -- wait for all launchers to rise
    local risen    = 0
    local riseDone = Instance.new("BindableEvent")

    for _, p in launchers do
        local targetPos = targets[p.Name]
        if (p.Position - targetPos).Magnitude <= 0.2 then
            risen += 1
            if risen >= #launchers then riseDone:Fire() end
        else
            local conn
            conn = p:GetPropertyChangedSignal("Position"):Connect(function()
                if (p.Position - targetPos).Magnitude <= 0.2 then
                    conn:Disconnect()
                    risen += 1
                    if risen >= #launchers then riseDone:Fire() end
                end
            end)
            eventTrove:Add(conn)
        end
    end

    riseDone.Event:Wait()
    riseDone:Destroy()
    if not isActive then return end

    -- firework loop — wait for launchers to fall via model.Destroying
    eventTrove:Add(task.spawn(function()
        while isActive do
            for _ = 1, math.random(1, 3) do
                fireOne(launchers[math.random(1, #launchers)], originalCFrames)
            end
            task.wait(math.random(20, 40) / 10)
        end
    end))

    fireworksModel.Destroying:Wait()
    isActive = false

    -- Cleanup watchdog
    while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end
    isActive = false
    eventTrove:Destroy()
end

task.spawn(main)
