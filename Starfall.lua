local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local HttpService       = game:GetService("HttpService")
local Debris            = game:GetService("Debris")

if not game:IsLoaded() then game.Loaded:Wait() end

local Shake            = require(ReplicatedStorage.Packages.Shake)
local ShakePresets     = require(ReplicatedStorage.Shared.ShakePresets)
local SoundController  = require(ReplicatedStorage.Controllers.SoundController)
local EventController  = require(ReplicatedStorage.Controllers.EventController)
local ClientEventUtils = require(ReplicatedStorage.Controllers.EventController.ClientEventUtils)

local EVENT_NAME  = "Starfall"
local EventScript = ReplicatedStorage.Controllers.EventController.Events[EVENT_NAME]
local Sounds      = ReplicatedStorage.Sounds.Events[EVENT_NAME]

local shakeTemplate = Shake.new()
shakeTemplate.Amplitude         = 1.5
shakeTemplate.Frequency         = 0.1
shakeTemplate.FadeInTime        = 0
shakeTemplate.FadeOutTime       = 0.6
shakeTemplate.PositionInfluence = Vector3.new(0.2, 0.2, 0.2)
shakeTemplate.RotationInfluence = Vector3.new(2.5, 0.5, 0.5)

repeat task.wait() until EventController:GetActiveEventData(EVENT_NAME)

local activeMeteors = {}
local nextStarId    = 1

local function doExplosionAt(pos)
    local explosion = EventScript.Explosion:Clone()
    explosion:PivotTo(CFrame.new(pos))
    explosion.Parent = workspace

    for _, desc in explosion:GetDescendants() do
        if desc:IsA("ParticleEmitter") then
            task.delay(desc:GetAttribute("EmitDelay") or 0, function()
                desc:Emit(desc:GetAttribute("EmitCount") or 1)
            end)
        end
    end
    Debris:AddItem(explosion, 5)

    local dist = (workspace.CurrentCamera.CFrame.Position - pos).Magnitude
    if dist <= 150 then
        local shakeClone = shakeTemplate:Clone()
        local scale = math.pow(1 - dist / 150, 2)
        shakeClone.Amplitude         = shakeClone.Amplitude * scale
        shakeClone.RotationInfluence = shakeClone.RotationInfluence * scale
        ShakePresets.BindShakeToCamera(shakeClone)
        shakeClone:Start()
    end
end

local function spawnMeteor(starId, startPos, targetPos, fallDuration, targetAnimal)
    local meteor = EventScript.Meteor:Clone()
    meteor:PivotTo(CFrame.new(startPos))
    meteor.Parent = workspace

    local primary = meteor.PrimaryPart
    if not primary then
        warn("[Starfall] Meteor missing PrimaryPart")
        meteor:Destroy()
        return
    end

    local tween = TweenService:Create(
        primary,
        TweenInfo.new(fallDuration, Enum.EasingStyle.Linear),
        { CFrame = CFrame.lookAt(targetPos, startPos) }
    )
    tween:Play()

    activeMeteors[starId] = { Model = meteor, Tween = tween }

    task.delay(fallDuration, function()
        local data = activeMeteors[starId]
        if not data then return end
        activeMeteors[starId] = nil

        if data.Tween then data.Tween:Cancel() end

        for _, desc in meteor:GetDescendants() do
            if desc:IsA("ParticleEmitter") then
                desc.Enabled = false
            elseif desc:IsA("BasePart") then
                desc.Transparency = 1
            end
        end
        Debris:AddItem(meteor, 3)

        local animal = targetAnimal
        if animal and animal.Parent then
            local animalPos = (animal.PrimaryPart and animal.PrimaryPart.CFrame or animal:GetPivot()).Position
            local impactPos = animalPos + Vector3.new(0, animal:GetExtentsSize().Y * 0.5, 0)

            SoundController:PlaySound(Sounds.Impact, impactPos)
            ClientEventUtils.playBurst(EventScript.StruckVFX, animal.Name, {
                Sounds.BrainrotHit
            })

            task.delay(0.1, function()
                if not animal or not animal.Parent then return end

                local currentTraits = {}
                local tj = animal:GetAttribute("Traits")
                if tj then
                    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, tj)
                    if ok and type(decoded) == "table" then currentTraits = decoded end
                end

                for _, t in ipairs(currentTraits) do
                    if t == "Cometstruck" then return end
                end

                table.insert(currentTraits, "Cometstruck")
                animal:SetAttribute("Traits", HttpService:JSONEncode(currentTraits))
            end)
        else
            SoundController:PlaySound(Sounds.Impact, targetPos)
            doExplosionAt(targetPos)
        end
    end)
end

local function loop()
    while EventController:GetActiveEventData(EVENT_NAME) do
        local waitTime = math.random(25) / 100
        task.wait(waitTime)

        if not EventController:GetActiveEventData(EVENT_NAME) then break end

        local mapFloor  = workspace.Events.Starfall.MapFloor
        local floorSize = mapFloor.Size
        local floorCF   = mapFloor.CFrame

        local shouldHitAnimal = math.random(1, 100) <= 3
        local targetAnimal    = nil

        if shouldHitAnimal then
            local candidates = {}
            for _, animal in ipairs(CollectionService:GetTagged("Animal")) do
                if animal.PrimaryPart then
                    local hasComet = false
                    local tj = animal:GetAttribute("Traits")
                    if tj then
                        local ok, decoded = pcall(HttpService.JSONDecode, HttpService, tj)
                        if ok and type(decoded) == "table" then
                            for _, trait in ipairs(decoded) do
                                if trait == "Cometstruck" then hasComet = true break end
                            end
                        end
                    end
                    if not hasComet then
                        table.insert(candidates, animal)
                    end
                end
            end
            if #candidates > 0 then
                targetAnimal = candidates[math.random(1, #candidates)]
            end
        end

        local targetPos
        if targetAnimal then
            local animalPos = (targetAnimal.PrimaryPart and targetAnimal.PrimaryPart.CFrame or targetAnimal:GetPivot()).Position
            targetPos = animalPos + Vector3.new(0, targetAnimal:GetExtentsSize().Y * 0.5, 0)
        else
            local randomX = math.random(-floorSize.X / 2, floorSize.X / 2)
            local randomZ = math.random(-floorSize.Z / 2, floorSize.Z / 2)
            targetPos = (floorCF * CFrame.new(randomX, 0, randomZ)).Position
        end

        local fixedOrigin  = Vector3.new(-1000, 225, 50)
        local dir          = targetPos - fixedOrigin
        local hDist        = Vector3.new(dir.X, 0, dir.Z).Magnitude
        local startPos     = Vector3.new(fixedOrigin.X, targetPos.Y + hDist, fixedOrigin.Z)
        local fallDuration = math.random(250, 400) / 100
        local starId       = nextStarId
        nextStarId        += 1

        spawnMeteor(starId, startPos, targetPos, fallDuration, targetAnimal)
    end

    while EventController:GetActiveEventData(EVENT_NAME) do task.wait(1) end

    for _, data in activeMeteors do
        if data.Tween then data.Tween:Cancel() end
        if data.Model then data.Model:Destroy() end
    end
    table.clear(activeMeteors)
    nextStarId = 1
end

task.spawn(loop)
