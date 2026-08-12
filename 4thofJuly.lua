local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")

local VFX              = require(ReplicatedStorage.Shared.VFX)
local SoundController  = require(ReplicatedStorage.Controllers.SoundController)
local MathUtils        = require(ReplicatedStorage.Utils.MathUtils)
local SharedEventUtils = require(ReplicatedStorage.Shared.SharedEventUtils)

local EventAssets = ReplicatedStorage.Controllers.EventController.Events["4th of July"]
local Sounds      = ReplicatedStorage.Sounds.Events["4th of July"]

local RayParams = RaycastParams.new()
RayParams.FilterType = Enum.RaycastFilterType.Include
RayParams.FilterDescendantsInstances = {
    workspace:WaitForChild("Map"),
    workspace:WaitForChild("Plots")
}

local launchers = {}
do
    local children = ReplicatedStorage.Models.Events["4th of July"].Fireworks:GetChildren()
    table.sort(children, function(a, b) return tonumber(a.Name) < tonumber(b.Name) end)
    for i, obj in ipairs(children) do
        launchers[i] = (obj:IsA("Model") and obj.PrimaryPart and obj.PrimaryPart.CFrame)
                    or (obj:IsA("BasePart") and obj.CFrame)
    end
end

local function fireOne(launchCF)
    local height = math.random(80, 120)
    local peakCF = launchCF + Vector3.new(0, height, 0)
    local travel = height / 20

    local startup = EventAssets.FireworkStartup:Clone()
    startup.CFrame = launchCF
    startup.Parent = workspace
    VFX.emit(startup)
    local s1 = Sounds.Shot:Clone(); s1.Parent = startup
    SoundController:PlaySound(s1)
    task.delay(2, function() startup:Destroy() end)

    local proj = EventAssets.Firework:Clone()
    proj.CFrame = launchCF
    proj.Parent = workspace
    local s2 = Sounds["Trail Sound Ball"]:Clone(); s2.Parent = proj
    SoundController:PlaySound(s2)

    local rise = TweenService:Create(proj,
        TweenInfo.new(travel, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { CFrame = peakCF })
    rise:Play()

    task.delay(travel * 0.8, function()
        rise:Destroy(); proj:Destroy()
        SoundController:PlaySound(Sounds["Firework Explosion"], peakCF.Position)

        local fx = EventAssets.Effects[tostring(math.random(1, 3))]:Clone()
        fx.CFrame = peakCF; fx.Parent = workspace
        VFX.emit(fx)
        task.delay(4, function() fx:Destroy() end)

        for _ = 1, math.random(6, 9) do
            local angle  = math.random() * math.pi * 2
            local r      = math.random() * 70
            local ox, oz = math.cos(angle) * r, math.sin(angle) * r
            local hit    = workspace:Raycast(peakCF.Position + Vector3.new(ox, 0, oz), Vector3.new(0, -200, 0), RayParams)
            local destCF = hit and CFrame.new(hit.Position) or (launchCF + Vector3.new(ox, 0, oz))

            local trail   = EventAssets.Falloff:Clone()
            trail.CFrame  = peakCF; trail.Parent = workspace
            local elapsed = 0
            local conn
            conn = RunService.PostSimulation:Connect(function(dt)
                elapsed = elapsed + dt
                local t = elapsed / 2.3
                SharedEventUtils.pushPartCFrame(trail, CFrame.new(MathUtils.quadBezier(t,
                    peakCF.Position,
                    peakCF.Position + Vector3.new(0, height, 0)
                        + (destCF.Position - peakCF.Position) * Vector3.new(1, 0, 1) * 0.7,
                    destCF.Position
                )))
                if t >= 1 then
                    local impact = EventAssets.GroundImpact:Clone()
                    impact.CFrame = destCF + Vector3.new(0, impact.Size.Y * 0.5, 0)
                    impact.Parent = workspace
                    VFX.emit(impact)
                    VFX.disable(trail)
                    task.delay(3, function() trail:Destroy(); impact:Destroy() end)
                    conn:Disconnect()
                end
            end)
        end
    end)
end

-- salvo loop runs until event ends via attribute
task.spawn(function()
    while ReplicatedStorage:GetAttribute("4thOfJulyEvent") do
        local indices = {}
        for i in pairs(launchers) do table.insert(indices, i) end
        for _ = 1, math.random(1, 3) do
            fireOne(launchers[indices[math.random(1, #indices)]])
        end
        task.wait(math.random(20, 40) / 10)
    end
end)
