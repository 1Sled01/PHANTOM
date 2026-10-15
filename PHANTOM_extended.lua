--[[
    PHANTOM | Roblox Studio
    Location: StarterPlayer > StarterPlayerScripts

    UI:
    - Wide purple sci-fi interface
    - Animated intro logo and menu opening
    - Falling stars and comet trails
    - Smooth buttons, toggles and sliders
    - Draggable window; position persists while this script runs
    - RightShift toggles the menu

    Features:
    - Cached NPC tracking
    - Player/NPC ESP, colors, distance, HP
    - Aim Assist with FOV and target lock while holding RMB
    - JumpPower and WalkSpeed sliders with numeric inputs
    - JSON import/export
]]

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local TAG_NAME = "PHANTOM_Target"
local RENDER_NAME = "PHANTOM_TrainingAim"

local old = playerGui:FindFirstChild("PHANTOM")
if old then old:Destroy() end

pcall(function()
    RunService:UnbindFromRenderStep(RENDER_NAME)
end)

local S = {
    PlayerESP = false,
    BotESP = false,
    PlayerWalls = false,
    BotWalls = false,
    HP = false,

    PlayerColor = Color3.fromRGB(0, 0, 0),
    BotColor = Color3.fromRGB(255, 45, 70),

    PlayerDistance = 100,
    BotDistance = 100,

    AimEnabled = false,
    AimBots = false,
    AimPart = "Head",
    FOV = 200,
    Smoothness = 8,

    JumpPower = 50,
    WalkSpeed = 16,

    CameraFOVEnabled = false,
    CameraFOV = 80,
    InfiniteJump = false,
    Fullbright = false,
    NoFog = false,
    Crosshair = false,
    ThirdPerson = false,
    ThirdPersonDistance = 12,
    SpinTest = false,
    SpinSpeed = 6,
}

local espObjects = {}
local trackedModels = {}
local lockedTarget
local rightMouseHeld = false
local menuOpen = false
local dragging = false
local dragStart
local dragPosition
local sliderState
local espElapsed = 0

local jumpPowerCustomized = false
local walkSpeedCustomized = false
local applyMovementSettings

local camera = Workspace.CurrentCamera
local rng = Random.new()

--==================================================
-- HELPERS
--==================================================

local function make(class, props, parent)
    local obj = Instance.new(class)

    for key, value in pairs(props or {}) do
        obj[key] = value
    end

    obj.Parent = parent
    return obj
end

local function corner(obj, radius)
    return make("UICorner", {
        CornerRadius = UDim.new(0, radius or 10),
    }, obj)
end

-- Four-point PHANTOM mark built from native UI shapes (no font glyph,
-- black outline, or external image asset required).
local function starMark(parent, size, color, zIndex)
    local mark = make("Frame", {
        Name = "PhantomStar",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(size, size),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ZIndex = zIndex or 8,
    }, parent)
    local armSize = size * 0.43
    local points = {{0.5, 0.08, 0}, {0.92, 0.5, 90}, {0.5, 0.92, 0}, {0.08, 0.5, 90}}
    for _, point in ipairs(points) do
        local arm = make("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(point[1], point[2]),
            Size = UDim2.fromOffset(armSize * 0.58, armSize),
            Rotation = point[3],
            BackgroundColor3 = color,
            BorderSizePixel = 0,
            ZIndex = (zIndex or 8) + 1,
        }, mark)
        corner(arm, armSize)
    end
    local center = make("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(size * 0.32, size * 0.32),
        Rotation = 45,
        BackgroundColor3 = color,
        BorderSizePixel = 0,
        ZIndex = (zIndex or 8) + 2,
    }, mark)
    corner(center, 2)
    return mark
end

local function stroke(obj, color, thickness, transparency)
    return make("UIStroke", {
        Color = color or Color3.fromRGB(145, 90, 240),
        Thickness = thickness or 1,
        Transparency = transparency or 0,
    }, obj)
end

local function tween(obj, props, duration, style)
    if not obj or not obj.Parent then return end

    local ok, tw = pcall(function()
        return TweenService:Create(
            obj,
            TweenInfo.new(
                duration or 0.18,
                style or Enum.EasingStyle.Quint,
                Enum.EasingDirection.Out
            ),
            props
        )
    end)

    if ok and tw then tw:Play() end
    return tw
end

local function round(n)
    return math.floor(n + 0.5)
end

local function clampNumber(value, minimum, maximum, fallback)
    value = tonumber(value)
    if not value then return fallback end
    return math.clamp(round(value), minimum, maximum)
end

local function addHover(button, normal, hovered)
    button.MouseEnter:Connect(function()
        tween(button, {
            BackgroundColor3 = hovered,
        }, 0.14)
    end)

    button.MouseLeave:Connect(function()
        tween(button, {
            BackgroundColor3 = normal,
        }, 0.18)
    end)
end

--==================================================
-- CHARACTER HELPERS
--==================================================

local function isPlayerCharacter(model)
    return model ~= nil
        and model:IsA("Model")
        and Players:GetPlayerFromCharacter(model) ~= nil
end

local function getHumanoid(model)
    if not model or not model:IsA("Model") then return nil end
    return model:FindFirstChildOfClass("Humanoid")
end

local function getRoot(model)
    if not model or not model:IsA("Model") then return nil end

    return model:FindFirstChild("HumanoidRootPart")
        or model:FindFirstChild("UpperTorso")
        or model:FindFirstChild("Torso")
        or model.PrimaryPart
        or model:FindFirstChild("Head")
end

local function isValidCharacterModel(model)
    if not model or not model:IsA("Model") then return false end
    if not model:IsDescendantOf(Workspace) then return false end
    if model == player.Character then return false end

    local humanoid = getHumanoid(model)
    local head = model:FindFirstChild("Head")
    local root = getRoot(model)

    return humanoid ~= nil
        and humanoid.Health > 0
        and head ~= nil
        and head:IsA("BasePart")
        and root ~= nil
        and root:IsA("BasePart")
end

--==================================================
-- CACHED NPC TRACKING
--==================================================

local function clearESP(model)
    local info = espObjects[model]
    if not info then return end

    if info.Highlight then info.Highlight:Destroy() end
    if info.Billboard then info.Billboard:Destroy() end

    espObjects[model] = nil
end

local function untrackModel(model)
    if not model or not model:IsA("Model") then return end

    trackedModels[model] = nil
    clearESP(model)

    if lockedTarget and lockedTarget.Model == model then
        lockedTarget = nil
    end
end

local function findModelAncestor(instance)
    local current = instance

    while current and current ~= Workspace do
        if current:IsA("Model") then return current end
        current = current.Parent
    end

    return nil
end

local function trackModel(model)
    if not model or not model:IsA("Model") then return end
    if model == player.Character or isPlayerCharacter(model) then return end
    if not model:IsDescendantOf(Workspace) then return end

    if getHumanoid(model) then
        trackedModels[model] = true
    end
end

-- One initial scan; afterwards update the cache through events.
for _, instance in ipairs(Workspace:GetDescendants()) do
    if instance:IsA("Model") then
        trackModel(instance)
    end
end

Workspace.DescendantAdded:Connect(function(instance)
    if instance:IsA("Model") then
        trackModel(instance)
    elseif instance:IsA("Humanoid") then
        local model = findModelAncestor(instance)
        if model then trackModel(model) end
    end
end)

Workspace.DescendantRemoving:Connect(function(instance)
    if instance:IsA("Model") then
        untrackModel(instance)
    end
end)

--==================================================
-- GUI ROOT
--==================================================

local gui = make("ScreenGui", {
    Name = "PHANTOM",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, playerGui)

-- Full-screen dimmer for the initial intro.
local dimmer = make("Frame", {
    Name = "IntroOverlay",
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Color3.fromRGB(7, 4, 16),
    BackgroundTransparency = 0,
    BorderSizePixel = 0,
    Visible = true,
    ZIndex = 50,
}, gui)

local introGlow = make("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.43),
    Size = UDim2.fromOffset(150, 150),
    BackgroundColor3 = Color3.fromRGB(117, 49, 220),
    BackgroundTransparency = 0.7,
    BorderSizePixel = 0,
    ZIndex = 51,
}, dimmer)
corner(introGlow, 100)

local introIconHolder = make("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.39),
    Size = UDim2.fromOffset(0, 0),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    ZIndex = 52,
}, dimmer)
local introIcon = starMark(introIconHolder, 82, Color3.fromRGB(179, 105, 255), 53)

local introTitle = make("TextLabel", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.49),
    Size = UDim2.fromOffset(500, 70),
    BackgroundTransparency = 1,
    Text = "PHANTOM",
    TextColor3 = Color3.fromRGB(241, 229, 255),
    TextTransparency = 1,
    Font = Enum.Font.GothamBlack,
    TextSize = 42,
    ZIndex = 52,
}, dimmer)

local introSubtitle = make("TextLabel", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.56),
    Size = UDim2.fromOffset(500, 28),
    BackgroundTransparency = 1,
    Text = "INITIALIZING INTERFACE",
    TextColor3 = Color3.fromRGB(170, 137, 214),
    TextTransparency = 1,
    Font = Enum.Font.GothamMedium,
    TextSize = 12,
    ZIndex = 52,
}, dimmer)

local introTrack = make("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.62),
    Size = UDim2.fromOffset(280, 5),
    BackgroundColor3 = Color3.fromRGB(45, 31, 65),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ZIndex = 52,
}, dimmer)
corner(introTrack, 5)

local introFill = make("Frame", {
    Size = UDim2.new(0, 0, 1, 0),
    BackgroundColor3 = Color3.fromRGB(179, 113, 255),
    BorderSizePixel = 0,
    ZIndex = 53,
}, introTrack)
corner(introFill, 5)

--==================================================
-- MAIN WINDOW: WIDE LAYOUT
--==================================================

local WINDOW_WIDTH = 850
local WINDOW_HEIGHT = 560

local main = make("Frame", {
    Name = "Window",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Size = UDim2.fromOffset(WINDOW_WIDTH - 30, WINDOW_HEIGHT - 30),
    Position = UDim2.fromScale(0.5, 0.5),
    BackgroundColor3 = Color3.fromRGB(15, 10, 27),
    BorderSizePixel = 0,
    Visible = false,
    ClipsDescendants = true,
    ZIndex = 2,
}, gui)

corner(main, 18)
stroke(main, Color3.fromRGB(135, 76, 220), 1.5, 0.08)

local mainGradient = make("UIGradient", {
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(24, 14, 43)),
        ColorSequenceKeypoint.new(0.5, Color3.fromRGB(15, 10, 27)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(31, 13, 47)),
    }),
    Rotation = 25,
}, main)

-- Background stars are kept separate from the controls.
local starLayer = make("Frame", {
    Name = "StarLayer",
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    ClipsDescendants = true,
    ZIndex = 2,
}, main)

local stars = {}

for i = 1, 24 do
    local size = rng:NextInteger(2, 4)
    local comet = rng:NextInteger(1, 5) == 1

    local star = make("Frame", {
        Name = comet and "Comet" or "Star",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(
            rng:NextNumber(0, 1), 0,
            rng:NextNumber(0, 1), 0
        ),
        Size = comet
            and UDim2.fromOffset(size * 2, size * 10)
            or UDim2.fromOffset(size, size),
        Rotation = -25,
        BackgroundColor3 = comet
            and Color3.fromRGB(190, 128, 255)
            or Color3.fromRGB(215, 188, 255),
        BackgroundTransparency = rng:NextNumber(0.1, 0.5),
        BorderSizePixel = 0,
        ZIndex = 2,
    }, starLayer)

    corner(star, 5)

    if comet then
        make("UIGradient", {
            Rotation = 90,
            Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0.1),
                NumberSequenceKeypoint.new(1, 1),
            }),
        }, star)
    end

    stars[#stars + 1] = {
        Object = star,
        Speed = rng:NextNumber(0.035, 0.12),
        Drift = rng:NextNumber(-0.025, 0.025),
        Comet = comet,
    }
end

-- Header
local header = make("Frame", {
    Name = "Header",
    Size = UDim2.new(1, 0, 0, 70),
    BackgroundColor3 = Color3.fromRGB(28, 17, 47),
    BackgroundTransparency = 0.08,
    BorderSizePixel = 0,
    Active = true,
    ZIndex = 5,
}, main)

make("Frame", {
    Position = UDim2.new(0, 0, 1, -1),
    Size = UDim2.new(1, 0, 0, 1),
    BackgroundColor3 = Color3.fromRGB(125, 73, 196),
    BackgroundTransparency = 0.4,
    BorderSizePixel = 0,
    ZIndex = 6,
}, header)

local logo = make("Frame", {
    Position = UDim2.fromOffset(18, 13),
    Size = UDim2.fromOffset(43, 43),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ZIndex = 7,
}, header)
local logoStar = starMark(logo, 34, Color3.fromRGB(179, 105, 255), 8)

make("TextLabel", {
    Position = UDim2.fromOffset(72, 8),
    Size = UDim2.fromOffset(300, 32),
    BackgroundTransparency = 1,
    Text = "PHANTOM",
    TextColor3 = Color3.fromRGB(243, 230, 255),
    Font = Enum.Font.GothamBlack,
    TextSize = 23,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 7,
}, header)

make("TextLabel", {
    Position = UDim2.fromOffset(73, 39),
    Size = UDim2.fromOffset(330, 18),
    BackgroundTransparency = 1,
    Text = "CONTROL CENTER  /  STUDIO",
    TextColor3 = Color3.fromRGB(166, 137, 202),
    Font = Enum.Font.GothamMedium,
    TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 7,
}, header)

local onlineDot = make("Frame", {
    AnchorPoint = Vector2.new(0, 0.5),
    Position = UDim2.new(1, -145, 0.5, 0),
    Size = UDim2.fromOffset(7, 7),
    BackgroundColor3 = Color3.fromRGB(123, 255, 178),
    BorderSizePixel = 0,
    ZIndex = 7,
}, header)
corner(onlineDot, 8)

make("TextLabel", {
    Position = UDim2.new(1, -132, 0, 0),
    Size = UDim2.fromOffset(90, 70),
    BackgroundTransparency = 1,
    Text = "SYSTEM ONLINE",
    TextColor3 = Color3.fromRGB(188, 170, 213),
    Font = Enum.Font.GothamMedium,
    TextSize = 9,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 7,
}, header)

local close = make("TextButton", {
    Size = UDim2.fromOffset(34, 34),
    Position = UDim2.new(1, -47, 0, 18),
    BackgroundColor3 = Color3.fromRGB(71, 38, 94),
    Text = "×",
    TextColor3 = Color3.fromRGB(255, 244, 255),
    Font = Enum.Font.GothamBold,
    TextSize = 24,
    AutoButtonColor = false,
    ZIndex = 8,
}, header)
corner(close, 10)
addHover(close, Color3.fromRGB(71, 38, 94), Color3.fromRGB(174, 58, 107))

--==================================================
-- SIDEBAR / PAGES
--==================================================

local sidebar = make("Frame", {
    Name = "Sidebar",
    Position = UDim2.fromOffset(12, 82),
    Size = UDim2.new(0, 142, 1, -94),
    BackgroundColor3 = Color3.fromRGB(20, 14, 34),
    BackgroundTransparency = 0.05,
    BorderSizePixel = 0,
    ZIndex = 5,
}, main)
corner(sidebar, 13)
stroke(sidebar, Color3.fromRGB(86, 55, 119), 1, 0.55)

make("TextLabel", {
    Position = UDim2.fromOffset(14, 13),
    Size = UDim2.new(1, -24, 0, 20),
    BackgroundTransparency = 1,
    Text = "NAVIGATION",
    TextColor3 = Color3.fromRGB(132, 107, 165),
    Font = Enum.Font.GothamBold,
    TextSize = 9,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 6,
}, sidebar)

local pages = {}
local tabButtons = {}

local function newPage(name)
    local page = make("ScrollingFrame", {
        Name = name,
        Position = UDim2.fromOffset(166, 82),
        Size = UDim2.new(1, -178, 1, -94),
        BackgroundColor3 = Color3.fromRGB(20, 14, 34),
        BackgroundTransparency = 0.08,
        BorderSizePixel = 0,
        ScrollBarThickness = 4,
        ScrollBarImageColor3 = Color3.fromRGB(157, 101, 232),
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        Visible = false,
        ZIndex = 5,
    }, main)

    corner(page, 13)
    stroke(page, Color3.fromRGB(86, 55, 119), 1, 0.55)

    pages[name] = page
    return page
end

local espPage = newPage("ESP")
local aimPage = newPage("AIMBOT")
local playerPage = newPage("PLAYER")
local importPage = newPage("IMPORT")

local tabNames = {
    {"ESP", "◈", "ESP"},
    {"AIMBOT", "⌖", "AIM"},
    {"PLAYER", "♟", "PLAYER"},
    {"IMPORT", "↔", "CONFIG"},
}

local function showTab(name)
    for pageName, page in pairs(pages) do
        page.Visible = pageName == name
    end

    for tabName, button in pairs(tabButtons) do
        local active = tabName == name

        tween(button, {
            BackgroundColor3 = active
                and Color3.fromRGB(93, 51, 145)
                or Color3.fromRGB(29, 21, 43),
        }, 0.18)

        local indicator = button:FindFirstChild("Indicator")
        if indicator then
            tween(indicator, {
                BackgroundTransparency = active and 0 or 1,
                Size = active
                    and UDim2.new(0, 3, 0, 27)
                    or UDim2.new(0, 3, 0, 10),
            }, 0.18)
        end
    end
end

for i, item in ipairs(tabNames) do
    local name, symbol, label = item[1], item[2], item[3]

    local button = make("TextButton", {
        Name = name,
        Position = UDim2.fromOffset(8, 43 + (i - 1) * 49),
        Size = UDim2.new(1, -16, 0, 41),
        BackgroundColor3 = Color3.fromRGB(29, 21, 43),
        Text = "",
        AutoButtonColor = false,
        ZIndex = 7,
    }, sidebar)
    corner(button, 9)

    local indicator = make("Frame", {
        Name = "Indicator",
        Position = UDim2.new(0, 0, 0.5, -13),
        Size = UDim2.new(0, 3, 0, 10),
        BackgroundColor3 = Color3.fromRGB(211, 164, 255),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ZIndex = 8,
    }, button)
    corner(indicator, 4)

    make("TextLabel", {
        Position = UDim2.fromOffset(10, 0),
        Size = UDim2.fromOffset(25, 41),
        BackgroundTransparency = 1,
        Text = symbol,
        TextColor3 = Color3.fromRGB(211, 174, 255),
        Font = Enum.Font.GothamBold,
        TextSize = 17,
        ZIndex = 8,
    }, button)

    make("TextLabel", {
        Position = UDim2.fromOffset(40, 0),
        Size = UDim2.new(1, -45, 1, 0),
        BackgroundTransparency = 1,
        Text = label,
        TextColor3 = Color3.fromRGB(240, 231, 255),
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 8,
    }, button)

    button.Activated:Connect(function()
        showTab(name)
    end)

    addHover(
        button,
        Color3.fromRGB(29, 21, 43),
        Color3.fromRGB(57, 36, 80)
    )

    tabButtons[name] = button
end

make("TextLabel", {
    Position = UDim2.new(0, 12, 1, -47),
    Size = UDim2.new(1, -24, 0, 30),
    BackgroundTransparency = 1,
    Text = "PHANTOM  •  V2",
    TextColor3 = Color3.fromRGB(116, 93, 145),
    Font = Enum.Font.GothamBold,
    TextSize = 9,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 6,
}, sidebar)

--==================================================
-- UI ELEMENT HELPERS
--==================================================

local toggleControls = {}
local sliderSetters = {}
local valueSetters = {}

local function section(parent, text, y)
    return make("TextLabel", {
        Size = UDim2.new(1, -28, 0, 27),
        Position = UDim2.fromOffset(14, y),
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = Color3.fromRGB(211, 176, 255),
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 7,
    }, parent)
end

local function toggle(parent, text, y, key, callback)
    local row = make("Frame", {
        Size = UDim2.new(1, -28, 0, 40),
        Position = UDim2.fromOffset(14, y),
        BackgroundColor3 = Color3.fromRGB(32, 23, 48),
        BorderSizePixel = 0,
        ZIndex = 7,
    }, parent)
    corner(row, 9)
    stroke(row, Color3.fromRGB(91, 61, 120), 1, 0.7)

    make("TextLabel", {
        Size = UDim2.new(1, -90, 1, 0),
        Position = UDim2.fromOffset(13, 0),
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = Color3.fromRGB(242, 235, 255),
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 8,
    }, row)

    local switch = make("TextButton", {
        Size = UDim2.fromOffset(46, 25),
        Position = UDim2.new(1, -59, 0.5, -12),
        BackgroundColor3 = S[key]
            and Color3.fromRGB(151, 85, 235)
            or Color3.fromRGB(66, 54, 80),
        Text = "",
        AutoButtonColor = false,
        ZIndex = 8,
    }, row)
    corner(switch, 15)

    local dot = make("Frame", {
        Size = UDim2.fromOffset(19, 19),
        Position = S[key]
            and UDim2.new(1, -22, 0.5, -9)
            or UDim2.new(0, 3, 0.5, -9),
        BackgroundColor3 = Color3.fromRGB(255, 250, 255),
        BorderSizePixel = 0,
        ZIndex = 9,
    }, switch)
    corner(dot, 12)

    local function refresh()
        tween(switch, {
            BackgroundColor3 = S[key]
                and Color3.fromRGB(151, 85, 235)
                or Color3.fromRGB(66, 54, 80),
        }, 0.2)

        tween(dot, {
            Position = S[key]
                and UDim2.new(1, -22, 0.5, -9)
                or UDim2.new(0, 3, 0.5, -9),
        }, 0.2)
    end

    toggleControls[key] = refresh

    switch.Activated:Connect(function()
        S[key] = not S[key]
        if callback then callback(S[key]) end
        refresh()
    end)

    row.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            and input.Target ~= switch then
            -- The switch itself is the primary control.
        end
    end)
end

local function slider(parent, text, y, key, minValue, maxValue)
    local label = make("TextLabel", {
        Size = UDim2.new(1, -28, 0, 20),
        Position = UDim2.fromOffset(14, y),
        BackgroundTransparency = 1,
        TextColor3 = Color3.fromRGB(241, 233, 255),
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 7,
    }, parent)

    local track = make("Frame", {
        Size = UDim2.new(1, -42, 0, 8),
        Position = UDim2.fromOffset(21, y + 29),
        BackgroundColor3 = Color3.fromRGB(62, 49, 80),
        BorderSizePixel = 0,
        Active = true,
        ZIndex = 7,
    }, parent)
    corner(track, 6)

    local fill = make("Frame", {
        Size = UDim2.new(0, 0, 1, 0),
        BackgroundColor3 = Color3.fromRGB(168, 103, 255),
        BorderSizePixel = 0,
        ZIndex = 8,
    }, track)
    corner(fill, 6)

    local knob = make("Frame", {
        Size = UDim2.fromOffset(17, 17),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0, 0, 0.5, 0),
        BackgroundColor3 = Color3.fromRGB(255, 250, 255),
        BorderSizePixel = 0,
        ZIndex = 9,
    }, track)
    corner(knob, 12)
    stroke(knob, Color3.fromRGB(190, 142, 255), 1, 0.1)

    local function setValue(value)
        S[key] = clampNumber(value, minValue, maxValue, S[key])

        local alpha = (S[key] - minValue) / (maxValue - minValue)
        tween(fill, {Size = UDim2.new(alpha, 0, 1, 0)}, 0.06)
        tween(knob, {Position = UDim2.new(alpha, 0, 0.5, 0)}, 0.06)

        label.Text = text .. ": " .. tostring(S[key])
        if key:find("Distance") then label.Text ..= " m" end
    end

    local function updateFromX(x)
        local width = math.max(track.AbsoluteSize.X, 1)
        local alpha = math.clamp(
            (x - track.AbsolutePosition.X) / width, 0, 1
        )
        setValue(minValue + alpha * (maxValue - minValue))
    end

    sliderSetters[key] = setValue

    local function begin(input)
        sliderState = {Update = updateFromX}
        updateFromX(input.Position.X)
    end

    track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            begin(input)
        end
    end)

    knob.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            begin(input)
        end
    end)

    setValue(S[key])
end

local function movementControl(parent, title, y, key, minimum, maximum)
    local valueBox = make("TextBox", {
        Size = UDim2.fromOffset(82, 29),
        Position = UDim2.new(1, -108, 0, y - 2),
        BackgroundColor3 = Color3.fromRGB(45, 31, 65),
        TextColor3 = Color3.fromRGB(255, 250, 255),
        Text = tostring(S[key]),
        ClearTextOnFocus = false,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        ZIndex = 8,
    }, parent)
    corner(valueBox, 8)
    stroke(valueBox, Color3.fromRGB(112, 72, 154), 1, 0.5)

    make("TextLabel", {
        Size = UDim2.new(1, -130, 0, 25),
        Position = UDim2.fromOffset(14, y),
        BackgroundTransparency = 1,
        Text = title,
        TextColor3 = Color3.fromRGB(241, 233, 255),
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 8,
    }, parent)

    local track = make("Frame", {
        Size = UDim2.new(1, -42, 0, 8),
        Position = UDim2.fromOffset(21, y + 39),
        BackgroundColor3 = Color3.fromRGB(62, 49, 80),
        BorderSizePixel = 0,
        Active = true,
        ZIndex = 7,
    }, parent)
    corner(track, 6)

    local fill = make("Frame", {
        Size = UDim2.new(0, 0, 1, 0),
        BackgroundColor3 = Color3.fromRGB(168, 103, 255),
        BorderSizePixel = 0,
        ZIndex = 8,
    }, track)
    corner(fill, 6)

    local knob = make("Frame", {
        Size = UDim2.fromOffset(17, 17),
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = Color3.fromRGB(255, 250, 255),
        BorderSizePixel = 0,
        ZIndex = 9,
    }, track)
    corner(knob, 12)
    stroke(knob, Color3.fromRGB(190, 142, 255), 1, 0.1)

    local function setValue(value, userChange)
        S[key] = clampNumber(value, minimum, maximum, S[key])

        local alpha = (S[key] - minimum) / (maximum - minimum)
        tween(fill, {Size = UDim2.new(alpha, 0, 1, 0)}, 0.06)
        tween(knob, {Position = UDim2.new(alpha, 0, 0.5, 0)}, 0.06)

        valueBox.Text = tostring(S[key])

        if userChange then
            if key == "JumpPower" then
                jumpPowerCustomized = true
            else
                walkSpeedCustomized = true
            end

            if applyMovementSettings then
                applyMovementSettings(player.Character)
            end
        end
    end

    local function updateFromX(x)
        local width = math.max(track.AbsoluteSize.X, 1)
        local alpha = math.clamp(
            (x - track.AbsolutePosition.X) / width, 0, 1
        )
        setValue(minimum + alpha * (maximum - minimum), true)
    end

    valueSetters[key] = function(value)
        setValue(value, false)
    end

    valueBox.FocusLost:Connect(function()
        local number = tonumber(valueBox.Text)
        if number then
            setValue(number, true)
        else
            valueBox.Text = tostring(S[key])
        end
    end)

    local function begin(input)
        sliderState = {Update = updateFromX}
        updateFromX(input.Position.X)
    end

    track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            begin(input)
        end
    end)

    knob.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            begin(input)
        end
    end)

    setValue(S[key], false)
end

local function makeCard(parent, y, height)
    local card = make("Frame", {
        Position = UDim2.fromOffset(12, y),
        Size = UDim2.new(1, -24, 0, height),
        BackgroundColor3 = Color3.fromRGB(26, 19, 40),
        BorderSizePixel = 0,
        ZIndex = 6,
    }, parent)
    corner(card, 11)
    stroke(card, Color3.fromRGB(91, 62, 119), 1, 0.65)
    return card
end

--==================================================
-- PLAYER MOVEMENT
--==================================================

section(playerPage, "MOVEMENT SETTINGS", 12)

make("TextLabel", {
    Size = UDim2.new(1, -28, 0, 42),
    Position = UDim2.fromOffset(14, 40),
    BackgroundTransparency = 1,
    Text = "Настраивай движение с помощью ползунка или введи число справа. Исходные значения сохраняются, пока ты сам их не изменишь.",
    TextColor3 = Color3.fromRGB(183, 164, 210),
    TextWrapped = true,
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top,
    ZIndex = 7,
}, playerPage)

local movementCard = makeCard(playerPage, 91, 220)

section(movementCard, "JUMP POWER", 10)
movementControl(movementCard, "Jump Power (0–1000)", 43, "JumpPower", 0, 1000)

section(movementCard, "WALK SPEED", 116)
movementControl(movementCard, "Walk Speed (0–300)", 149, "WalkSpeed", 0, 300)

make("TextLabel", {
    Size = UDim2.new(1, -28, 0, 48),
    Position = UDim2.fromOffset(14, 324),
    BackgroundTransparency = 1,
    Text = "Важно: высокие значения могут конфликтовать с другими скриптами игры. Изменения применяются только после ручного изменения настройки.",
    TextColor3 = Color3.fromRGB(166, 145, 193),
    TextWrapped = true,
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top,
    ZIndex = 7,
}, playerPage)

applyMovementSettings = function(character)
    character = character or player.Character
    if not character then return end

    task.spawn(function()
        local humanoid = character:WaitForChild("Humanoid", 10)
        if not humanoid or not humanoid:IsA("Humanoid") then return end

        if not jumpPowerCustomized then
            if humanoid.UseJumpPower then
                S.JumpPower = clampNumber(
                    humanoid.JumpPower, 0, 1000, S.JumpPower
                )
            end

            if valueSetters.JumpPower then
                valueSetters.JumpPower(S.JumpPower)
            end
        else
            humanoid.UseJumpPower = true
            humanoid.JumpPower = S.JumpPower
        end

        if not walkSpeedCustomized then
            S.WalkSpeed = clampNumber(
                humanoid.WalkSpeed, 0, 300, S.WalkSpeed
            )

            if valueSetters.WalkSpeed then
                valueSetters.WalkSpeed(S.WalkSpeed)
            end
        else
            humanoid.WalkSpeed = S.WalkSpeed
        end
    end)
end

player.CharacterAdded:Connect(function(character)
    applyMovementSettings(character)
end)

-- Extra local test utilities. These are client-side visual/movement options only.
local lightingSnapshot, fogSnapshot
local originalCameraMinZoom = player.CameraMinZoomDistance
local originalCameraMaxZoom = player.CameraMaxZoomDistance
local originalCameraMode = player.CameraMode
local crosshairGui
local jumpConnection
local spinAngle = 0
section(playerPage, "TEST UTILITIES", 390)
local utilityCard = makeCard(playerPage, 425, 355)
toggle(utilityCard, "Infinite Jump", 10, "InfiniteJump")
toggle(utilityCard, "Fullbright (local)", 53, "Fullbright", function(enabled)
    local Lighting = game:GetService("Lighting")
    if enabled then
        if not lightingSnapshot then
            lightingSnapshot = {
                Brightness = Lighting.Brightness,
                ClockTime = Lighting.ClockTime,
                GlobalShadows = Lighting.GlobalShadows,
                Ambient = Lighting.Ambient,
                OutdoorAmbient = Lighting.OutdoorAmbient,
            }
        end
        Lighting.Brightness = 3
        Lighting.ClockTime = 14
        Lighting.GlobalShadows = false
        Lighting.Ambient = Color3.fromRGB(180, 180, 180)
        Lighting.OutdoorAmbient = Color3.fromRGB(180, 180, 180)
    elseif lightingSnapshot then
        Lighting.Brightness = lightingSnapshot.Brightness
        Lighting.ClockTime = lightingSnapshot.ClockTime
        Lighting.GlobalShadows = lightingSnapshot.GlobalShadows
        Lighting.Ambient = lightingSnapshot.Ambient
        Lighting.OutdoorAmbient = lightingSnapshot.OutdoorAmbient
    end
end)
toggle(utilityCard, "No Fog (local)", 96, "NoFog", function(enabled)
    local Lighting = game:GetService("Lighting")
    if enabled then
        if not fogSnapshot then
            fogSnapshot = {FogStart = Lighting.FogStart, FogEnd = Lighting.FogEnd}
        end
        Lighting.FogStart = 0
        Lighting.FogEnd = 100000
    elseif fogSnapshot then
        Lighting.FogStart = fogSnapshot.FogStart
        Lighting.FogEnd = fogSnapshot.FogEnd
    end
end)
toggle(utilityCard, "Crosshair", 139, "Crosshair")
toggle(utilityCard, "Third Person", 182, "ThirdPerson", function(enabled)
    local cam = Workspace.CurrentCamera
    if not cam then return end
    if enabled then
        player.CameraMode = Enum.CameraMode.Classic
        player.CameraMinZoomDistance = 8
        player.CameraMaxZoomDistance = math.max(player.CameraMaxZoomDistance, S.ThirdPersonDistance)
    else
        player.CameraMinZoomDistance = originalCameraMinZoom
        player.CameraMaxZoomDistance = originalCameraMaxZoom
        player.CameraMode = originalCameraMode
    end
end)
toggle(utilityCard, "Spin Test (visual)", 225, "SpinTest")
slider(utilityCard, "Spin Speed", 270, "SpinSpeed", 1, 20)

--==================================================
-- ESP PAGE
--==================================================

section(espPage, "ESP SETTINGS", 12)

local espCard = makeCard(espPage, 47, 240)

toggle(espCard, "ESP игроков", 12, "PlayerESP")
toggle(espCard, "Игроки сквозь стены", 55, "PlayerWalls")
toggle(espCard, "ESP ботов / NPC", 98, "BotESP")
toggle(espCard, "Боты сквозь стены", 141, "BotWalls")
toggle(espCard, "Показывать HP", 184, "HP")

section(espPage, "DISTANCE", 302)

local distanceCard = makeCard(espPage, 337, 115)
slider(distanceCard, "Дистанция игроков", 9, "PlayerDistance", 25, 500)
slider(distanceCard, "Дистанция ботов", 58, "BotDistance", 25, 500)

section(espPage, "COLORS", 470)

local colorCard = makeCard(espPage, 504, 90)

local colorNames = {
    {"Чёрный", Color3.fromRGB(0, 0, 0)},
    {"Красный", Color3.fromRGB(255, 45, 70)},
    {"Зелёный", Color3.fromRGB(40, 255, 120)},
    {"Синий", Color3.fromRGB(50, 130, 255)},
    {"Жёлтый", Color3.fromRGB(255, 225, 30)},
    {"Фиолетовый", Color3.fromRGB(185, 80, 255)},
    {"Белый", Color3.fromRGB(255, 255, 255)},
    {"Голубой", Color3.fromRGB(40, 240, 255)},
}

local selectedColorTarget = "Players"

local targetSelect = make("TextButton", {
    Size = UDim2.new(1, -20, 0, 27),
    Position = UDim2.fromOffset(10, 7),
    BackgroundColor3 = Color3.fromRGB(63, 43, 88),
    Text = "Цвет для: Игроки — нажми, чтобы сменить",
    TextColor3 = Color3.new(1, 1, 1),
    Font = Enum.Font.Gotham,
    TextSize = 10,
    AutoButtonColor = false,
    ZIndex = 8,
}, colorCard)
corner(targetSelect, 7)

targetSelect.Activated:Connect(function()
    selectedColorTarget = selectedColorTarget == "Players" and "Bots" or "Players"
    targetSelect.Text = "Цвет для: "
        .. (selectedColorTarget == "Players" and "Игроки" or "Боты")
        .. " — нажми, чтобы сменить"
end)

for i, item in ipairs(colorNames) do
    local col = (i - 1) % 4
    local row = math.floor((i - 1) / 4)

    local swatch = make("TextButton", {
        Size = UDim2.fromOffset(52, 20),
        Position = UDim2.fromOffset(11 + col * 59, 42 + row * 24),
        BackgroundColor3 = item[2],
        Text = "",
        AutoButtonColor = false,
        ZIndex = 8,
    }, colorCard)
    corner(swatch, 5)
    stroke(swatch, Color3.fromRGB(205, 185, 225), 1, 0.65)

    swatch.Activated:Connect(function()
        if selectedColorTarget == "Players" then
            S.PlayerColor = item[2]
        else
            S.BotColor = item[2]
        end

        tween(swatch, {
            Size = UDim2.fromOffset(56, 22),
        }, 0.08)

        task.delay(0.09, function()
            if swatch.Parent then
                tween(swatch, {
                    Size = UDim2.fromOffset(52, 20),
                }, 0.12)
            end
        end)
    end)
end

--==================================================
-- AIM PAGE
--==================================================

section(aimPage, "AIM ASSIST", 12)

local aimCard = makeCard(aimPage, 47, 120)
toggle(aimCard, "Включить Aim Assist", 12, "AimEnabled", function(value)
    if not value then lockedTarget = nil end
end)

toggle(aimCard, "Наведение на игроков / ботов", 59, "AimBots", function(value)
    if not value then lockedTarget = nil end
end)

section(aimPage, "TARGET SETTINGS", 183)

local targetCard = makeCard(aimPage, 218, 145)

local aimPartButton = make("TextButton", {
    Size = UDim2.new(1, -24, 0, 34),
    Position = UDim2.fromOffset(12, 10),
    BackgroundColor3 = Color3.fromRGB(69, 43, 96),
    Text = "ТОЧКА НАВЕДЕНИЯ: HEAD",
    TextColor3 = Color3.fromRGB(255, 248, 255),
    Font = Enum.Font.GothamBold,
    TextSize = 11,
    AutoButtonColor = false,
    ZIndex = 8,
}, targetCard)
corner(aimPartButton, 8)

aimPartButton.Activated:Connect(function()
    S.AimPart = S.AimPart == "Head" and "Body" or "Head"
    aimPartButton.Text = "ТОЧКА НАВЕДЕНИЯ: "
        .. (S.AimPart == "Head" and "HEAD" or "BODY")
    lockedTarget = nil
end)

slider(targetCard, "Размер круга FOV (px)", 55, "FOV", 50, 900)
slider(targetCard, "Скорость наведения", 102, "Smoothness", 1, 20)

make("TextLabel", {
    Size = UDim2.new(1, -28, 0, 75),
    Position = UDim2.fromOffset(14, 377),
    BackgroundTransparency = 1,
    Text = "Удерживай ПКМ, чтобы захватить цель. После захвата цель сохраняется, даже если временно выходит из FOV или за препятствие. Отпусти ПКМ, чтобы сбросить захват.",
    TextColor3 = Color3.fromRGB(183, 164, 210),
    TextWrapped = true,
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top,
    ZIndex = 7,
}, aimPage)

-- Additional camera FOV controls (separate from the Aim Assist FOV circle).
section(aimPage, "CAMERA FIELD OF VIEW", 465)
local cameraFovCard = makeCard(aimPage, 497, 95)
local originalCameraFOV = camera and camera.FieldOfView or 70
local cameraFOVCustomized = false
toggle(cameraFovCard, "Включить Camera FOV", 8, "CameraFOVEnabled", function(enabled)
    camera = Workspace.CurrentCamera
    if not camera then return end
    if enabled then
        originalCameraFOV = camera.FieldOfView
        cameraFOVCustomized = true
        tween(camera, {FieldOfView = S.CameraFOV}, 0.25)
    else
        tween(camera, {FieldOfView = originalCameraFOV}, 0.25)
    end
end)
slider(cameraFovCard, "Camera FOV", 51, "CameraFOV", 50, 110)

--==================================================
-- FOV CIRCLE
--==================================================

local fovCircle = make("Frame", {
    Name = "FOVCircle",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(S.FOV * 2, S.FOV * 2),
    BackgroundTransparency = 1,
    Visible = false,
    ZIndex = 40,
}, gui)
corner(fovCircle, 500)
stroke(fovCircle, Color3.fromRGB(185, 115, 255), 1.5, 0.15)

--==================================================
-- IMPORT / EXPORT
--==================================================

section(importPage, "CONFIGURATION", 12)

make("TextLabel", {
    Size = UDim2.new(1, -28, 0, 38),
    Position = UDim2.fromOffset(14, 42),
    BackgroundTransparency = 1,
    Text = "Вставь JSON настроек и нажми IMPORT. EXPORT подготовит JSON текущих настроек.",
    TextColor3 = Color3.fromRGB(183, 164, 210),
    TextWrapped = true,
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 7,
}, importPage)

local importBox = make("TextBox", {
    Size = UDim2.new(1, -28, 0, 180),
    Position = UDim2.fromOffset(14, 87),
    BackgroundColor3 = Color3.fromRGB(12, 8, 20),
    TextColor3 = Color3.fromRGB(230, 220, 255),
    PlaceholderText = '{"PlayerESP": true}',
    PlaceholderColor3 = Color3.fromRGB(125, 110, 145),
    Text = "",
    ClearTextOnFocus = false,
    TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top,
    Font = Enum.Font.Code,
    TextSize = 12,
    MultiLine = true,
    ZIndex = 8,
}, importPage)
corner(importBox, 9)
stroke(importBox, Color3.fromRGB(91, 62, 119), 1, 0.5)

local importButton = make("TextButton", {
    Size = UDim2.new(0.5, -20, 0, 38),
    Position = UDim2.fromOffset(14, 280),
    BackgroundColor3 = Color3.fromRGB(105, 59, 166),
    Text = "IMPORT SETTINGS",
    TextColor3 = Color3.new(1, 1, 1),
    Font = Enum.Font.GothamBold,
    TextSize = 11,
    AutoButtonColor = false,
    ZIndex = 8,
}, importPage)
corner(importButton, 9)
addHover(importButton, Color3.fromRGB(105, 59, 166), Color3.fromRGB(136, 79, 205))

local exportButton = make("TextButton", {
    Size = UDim2.new(0.5, -20, 0, 38),
    Position = UDim2.new(0.5, 6, 0, 280),
    BackgroundColor3 = Color3.fromRGB(63, 43, 88),
    Text = "EXPORT SETTINGS",
    TextColor3 = Color3.new(1, 1, 1),
    Font = Enum.Font.GothamBold,
    TextSize = 11,
    AutoButtonColor = false,
    ZIndex = 8,
}, importPage)
corner(exportButton, 9)
addHover(exportButton, Color3.fromRGB(63, 43, 88), Color3.fromRGB(89, 59, 120))

local importStatus = make("TextLabel", {
    Size = UDim2.new(1, -28, 0, 45),
    Position = UDim2.fromOffset(14, 331),
    BackgroundTransparency = 1,
    Text = "",
    TextColor3 = Color3.fromRGB(190, 160, 255),
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 7,
}, importPage)

local importKeys = {
    "PlayerESP", "BotESP", "PlayerWalls", "BotWalls", "HP",
    "PlayerDistance", "BotDistance",
    "AimEnabled", "AimBots", "AimPart", "FOV", "Smoothness",
    "JumpPower", "WalkSpeed",
    "CameraFOVEnabled", "CameraFOV", "InfiniteJump", "Fullbright",
    "NoFog", "Crosshair", "ThirdPerson", "ThirdPersonDistance",
    "SpinTest", "SpinSpeed",
}

local function validateSetting(key, value)
    local booleanKeys = {
        PlayerESP = true,
        BotESP = true,
        PlayerWalls = true,
        BotWalls = true,
        HP = true,
        AimEnabled = true,
        AimBots = true,
        CameraFOVEnabled = true,
        InfiniteJump = true,
        Fullbright = true,
        NoFog = true,
        Crosshair = true,
        ThirdPerson = true,
        SpinTest = true,
    }

    if booleanKeys[key] then
        if typeof(value) == "boolean" then return value end
        return nil
    end

    if key == "PlayerDistance" or key == "BotDistance" then
        if typeof(value) == "number" then
            return clampNumber(value, 25, 500, S[key])
        end
        return nil
    end

    if key == "FOV" then
        if typeof(value) == "number" then
            return clampNumber(value, 50, 900, S.FOV)
        end
        return nil
    end

    if key == "Smoothness" then
        if typeof(value) == "number" then
            return clampNumber(value, 1, 20, S.Smoothness)
        end
        return nil
    end

    if key == "JumpPower" then
        if typeof(value) == "number" then
            return clampNumber(value, 0, 1000, S.JumpPower)
        end
        return nil
    end

    if key == "WalkSpeed" then
        if typeof(value) == "number" then
            return clampNumber(value, 0, 300, S.WalkSpeed)
        end
        return nil
    end

    if key == "CameraFOV" then
        if typeof(value) == "number" then return clampNumber(value, 50, 110, S.CameraFOV) end
        return nil
    end
    if key == "ThirdPersonDistance" then
        if typeof(value) == "number" then return clampNumber(value, 8, 30, S.ThirdPersonDistance) end
        return nil
    end
    if key == "SpinSpeed" then
        if typeof(value) == "number" then return clampNumber(value, 1, 20, S.SpinSpeed) end
        return nil
    end

    if key == "AimPart" then
        if value == "Head" or value == "Body" then return value end
        return nil
    end

    return nil
end

local function refreshControls()
    for _, refresh in pairs(toggleControls) do
        refresh()
    end

    for key, setValue in pairs(sliderSetters) do
        setValue(S[key])
    end

    for key, setValue in pairs(valueSetters) do
        setValue(S[key])
    end

    aimPartButton.Text = "ТОЧКА НАВЕДЕНИЯ: "
        .. (S.AimPart == "Head" and "HEAD" or "BODY")

    jumpPowerCustomized = true
    walkSpeedCustomized = true

    applyMovementSettings(player.Character)
    lockedTarget = nil
end

importButton.Activated:Connect(function()
    local ok, data = pcall(function()
        return HttpService:JSONDecode(importBox.Text)
    end)

    if not ok or type(data) ~= "table" then
        importStatus.Text = "Ошибка: проверь JSON."
        return
    end

    for _, key in ipairs(importKeys) do
        if data[key] ~= nil then
            local validated = validateSetting(key, data[key])
            if validated ~= nil then S[key] = validated end
        end
    end

    refreshControls()
    importStatus.Text = "Настройки импортированы."
end)

exportButton.Activated:Connect(function()
    local data = {}

    for _, key in ipairs(importKeys) do
        data[key] = S[key]
    end

    local ok, result = pcall(function()
        return HttpService:JSONEncode(data)
    end)

    if ok then
        importBox.Text = result
        importStatus.Text = "JSON готов. Скопируй его из поля."
    else
        importStatus.Text = "Не удалось создать JSON."
    end
end)

--==================================================
-- WINDOW DRAGGING
--==================================================

header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        dragPosition = main.Position
    end
end)

UIS.InputChanged:Connect(function(input)
    if dragging and dragStart and dragPosition and (
        input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch
    ) then
        local delta = input.Position - dragStart

        main.Position = UDim2.new(
            dragPosition.X.Scale,
            dragPosition.X.Offset + delta.X,
            dragPosition.Y.Scale,
            dragPosition.Y.Offset + delta.Y
        )
    end

    if sliderState and (
        input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch
    ) then
        sliderState.Update(input.Position.X)
    end
end)

UIS.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
        dragStart = nil
        dragPosition = nil
        sliderState = nil
    end
end)

--==================================================
-- ESP
--==================================================

local function getLocalRoot()
    local character = player.Character
    return character and getRoot(character)
end

local function distanceFromPlayer(model)
    local localRoot = getLocalRoot()
    local targetRoot = getRoot(model)

    if not localRoot or not targetRoot then return math.huge end
    return (localRoot.Position - targetRoot.Position).Magnitude
end

local function applyESP(model, humanoid, isBot)
    if not model or not model:IsA("Model") then return end

    local info = espObjects[model]

    if not info then
        info = {}
        espObjects[model] = info
    end

    if not info.Highlight or not info.Highlight.Parent then
        local highlight = Instance.new("Highlight")
        highlight.Name = "PHANTOM_Highlight"
        highlight.Adornee = model
        highlight.Parent = model
        info.Highlight = highlight
    end

    local color = isBot and S.BotColor or S.PlayerColor
    local walls = isBot and S.BotWalls or S.PlayerWalls

    info.Highlight.FillColor = color
    info.Highlight.OutlineColor = color
    info.Highlight.FillTransparency = 0.82
    info.Highlight.OutlineTransparency = 0
    info.Highlight.DepthMode = walls
        and Enum.HighlightDepthMode.AlwaysOnTop
        or Enum.HighlightDepthMode.Occluded

    if S.HP then
        local adornee = model:FindFirstChild("Head") or getRoot(model)

        if adornee then
            if not info.Billboard or not info.Billboard.Parent then
                local bill = Instance.new("BillboardGui")
                bill.Name = "PHANTOM_HP"
                bill.Size = UDim2.fromOffset(120, 24)
                bill.StudsOffset = Vector3.new(0, 2.5, 0)
                bill.AlwaysOnTop = true
                bill.Adornee = adornee
                bill.Parent = adornee

                local label = Instance.new("TextLabel")
                label.Size = UDim2.fromScale(1, 1)
                label.BackgroundTransparency = 1
                label.TextColor3 = Color3.fromRGB(120, 255, 140)
                label.TextStrokeTransparency = 0.2
                label.Font = Enum.Font.GothamBold
                label.TextSize = 12
                label.Parent = bill

                info.Billboard = bill
                info.HPLabel = label
            else
                info.Billboard.Adornee = adornee
            end

            info.HPLabel.Text = "HP: "
                .. round(humanoid.Health)
                .. " / "
                .. round(humanoid.MaxHealth)
        end
    elseif info.Billboard then
        info.Billboard:Destroy()
        info.Billboard = nil
        info.HPLabel = nil
    end
end

local function updateESP()
    local seenModels = {}

    for _, plr in ipairs(Players:GetPlayers()) do
        local character = plr.Character

        if plr ~= player and character then
            seenModels[character] = true

            local humanoid = getHumanoid(character)
            local inRange = distanceFromPlayer(character) <= S.PlayerDistance

            if S.PlayerESP and humanoid and humanoid.Health > 0 and inRange then
                applyESP(character, humanoid, false)
            else
                clearESP(character)
            end
        end
    end

    for model in pairs(trackedModels) do
        if model.Parent and model:IsDescendantOf(Workspace) then
            seenModels[model] = true

            local humanoid = getHumanoid(model)
            local inRange = distanceFromPlayer(model) <= S.BotDistance

            if S.BotESP and humanoid and humanoid.Health > 0 and inRange then
                applyESP(model, humanoid, true)
            else
                clearESP(model)
            end
        else
            untrackModel(model)
        end
    end

    for model in pairs(espObjects) do
        if not model:IsDescendantOf(Workspace) or not seenModels[model] then
            clearESP(model)
        end
    end
end

--==================================================
-- AIM TARGETING
--==================================================

local function getAimPart(model)
    if not model or not model:IsA("Model") then return nil end

    local humanoid = getHumanoid(model)
    if not humanoid or humanoid.Health <= 0 then return nil end

    if S.AimPart == "Head" then
        local head = model:FindFirstChild("Head")
        if head and head:IsA("BasePart") then return head end
        return nil
    end

    local body = model:FindFirstChild("UpperTorso")
        or model:FindFirstChild("Torso")
        or model:FindFirstChild("HumanoidRootPart")

    if body and body:IsA("BasePart") then return body end
    return nil
end

local function withinFOV(model)
    local activeCamera = Workspace.CurrentCamera
    if not activeCamera then return nil end

    local part = getAimPart(model)
    if not part then return nil end

    local viewport = activeCamera.ViewportSize
    local center = Vector2.new(viewport.X / 2, viewport.Y / 2)
    local point, onScreen = activeCamera:WorldToViewportPoint(part.Position)

    if not onScreen or point.Z <= 0 then return nil end

    local screenDistance =
        (Vector2.new(point.X, point.Y) - center).Magnitude

    if screenDistance > S.FOV then return nil end
    return part, screenDistance
end

local function hasLineOfSight(model, part)
    local activeCamera = Workspace.CurrentCamera
    if not activeCamera then return false end

    local origin = activeCamera.CFrame.Position
    local direction = part.Position - origin

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {player.Character}

    local result = Workspace:Raycast(origin, direction, params)
    return result == nil or result.Instance:IsDescendantOf(model)
end

local function getTrainingCandidates()
    local candidates = {}

    if not S.AimEnabled or not S.AimBots then return candidates end

    local seen = {}

    local function consider(model)
        if not model or seen[model] then return end
        seen[model] = true

        if not isValidCharacterModel(model) then return end

        local part, screenDistance = withinFOV(model)
        if part and hasLineOfSight(model, part) then
            candidates[#candidates + 1] = {
                Model = model,
                Part = part,
                Distance = screenDistance,
            }
        end
    end

    for _, otherPlayer in ipairs(Players:GetPlayers()) do
        if otherPlayer ~= player then consider(otherPlayer.Character) end
    end

    for model in pairs(trackedModels) do
        if model.Parent then consider(model) end
    end

    table.sort(candidates, function(a, b)
        return a.Distance < b.Distance
    end)

    return candidates
end

local function targetIsValid(model, part)
    if not model or not model:IsA("Model") then return false end
    if not isValidCharacterModel(model) then return false end
    if model == player.Character then return false end
    if not part or not part:IsDescendantOf(model) then return false end
    return getAimPart(model) ~= nil
end

local function chooseTarget()
    local candidates = getTrainingCandidates()
    local best = candidates[1]

    if best then
        return {
            Model = best.Model,
            Part = best.Part,
        }
    end

    return nil
end

--==================================================
-- MENU ANIMATIONS / OPENING
--==================================================

local function setOpen(value)
    if menuOpen == value then return end
    menuOpen = value

    if value then
        main.Visible = true
        main.Size = UDim2.fromOffset(WINDOW_WIDTH - 28, WINDOW_HEIGHT - 28)

        tween(main, {
            Size = UDim2.fromOffset(WINDOW_WIDTH, WINDOW_HEIGHT),
        }, 0.24, Enum.EasingStyle.Back)

        if not main:FindFirstChild("WindowFade") then
            local fade = make("Frame", {
                Name = "WindowFade",
                Size = UDim2.fromScale(1, 1),
                BackgroundColor3 = Color3.fromRGB(13, 8, 23),
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                ZIndex = 49,
            }, main)

            tween(fade, {
                BackgroundTransparency = 1,
            }, 0.15)

            task.delay(0.2, function()
                if fade.Parent then fade:Destroy() end
            end)
        end
    else
        lockedTarget = nil

        local closeTween = tween(main, {
            Size = UDim2.fromOffset(WINDOW_WIDTH - 25, WINDOW_HEIGHT - 25),
        }, 0.15)

        if closeTween then
            closeTween.Completed:Connect(function()
                if not menuOpen and main.Parent then
                    main.Visible = false
                    main.Size = UDim2.fromOffset(WINDOW_WIDTH, WINDOW_HEIGHT)
                end
            end)
        else
            main.Visible = false
        end
    end
end

close.Activated:Connect(function()
    setOpen(false)
end)

UIS.InputBegan:Connect(function(input, processed)
    if input.KeyCode == Enum.KeyCode.RightShift and not processed then
        setOpen(not menuOpen)
        return
    end

    if input.UserInputType == Enum.UserInputType.MouseButton2 then
        rightMouseHeld = true
        lockedTarget = nil
    end
end)

UIS.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton2 then
        rightMouseHeld = false
        lockedTarget = nil
    end
end)

--==================================================
-- ANIMATED STARS
--==================================================

local starUpdateElapsed = 0

RunService.RenderStepped:Connect(function(dt)
    starUpdateElapsed += dt
    if starUpdateElapsed < 1 / 30 then return end

    local step = starUpdateElapsed
    starUpdateElapsed = 0

    for _, data in ipairs(stars) do
        local obj = data.Object

        if obj and obj.Parent then
            local pos = obj.Position
            local newY = pos.Y.Scale + data.Speed * step
            local newX = pos.X.Scale + data.Drift * step

            if newY > 1.08 then
                newY = -0.08
                newX = rng:NextNumber(0, 1)
            end

            if newX < -0.08 then newX = 1.05 end
            if newX > 1.08 then newX = -0.05 end

            obj.Position = UDim2.new(newX, 0, newY, 0)
        end
    end
end)

--==================================================
-- AIM CAMERA UPDATE
--==================================================

RunService:BindToRenderStep(
    RENDER_NAME,
    Enum.RenderPriority.Camera.Value + 1,
    function(dt)
        camera = Workspace.CurrentCamera

        fovCircle.Visible = S.AimEnabled and S.AimBots
        fovCircle.Size = UDim2.fromOffset(S.FOV * 2, S.FOV * 2)

        if camera then
            local viewport = camera.ViewportSize
            fovCircle.Position = UDim2.fromOffset(
                viewport.X / 2,
                viewport.Y / 2
            )
        end

        if not camera then
            lockedTarget = nil
            return
        end

        if not S.AimEnabled or not S.AimBots or not rightMouseHeld then
            lockedTarget = nil
            return
        end

        if lockedTarget then
            local model = lockedTarget.Model
            local currentPart = getAimPart(model)

            -- Keep the lock when the target leaves FOV or is briefly obscured.
            if targetIsValid(model, currentPart) then
                lockedTarget.Part = currentPart
            else
                lockedTarget = nil
            end
        end

        if not lockedTarget then
            lockedTarget = chooseTarget()
        end

        if not lockedTarget then return end

        local model = lockedTarget.Model
        local part = getAimPart(model)

        if not targetIsValid(model, part) then
            lockedTarget = nil
            return
        end

        local origin = camera.CFrame.Position
        local destination = part.Position

        if (destination - origin).Magnitude < 0.01 then return end

        local desired = CFrame.lookAt(origin, destination)
        local speed = 21 - S.Smoothness
        local alpha = math.clamp(dt * speed, 0, 1)

        camera.CFrame = camera.CFrame:Lerp(desired, alpha)
    end
)

-- Crosshair is a single lightweight ScreenGui element; no second menu is created.
local crosshair = make("Frame", {
    Name = "PHANTOM_Crosshair",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(4, 4),
    BackgroundColor3 = Color3.fromRGB(185, 115, 255),
    BorderSizePixel = 0,
    Visible = false,
    ZIndex = 45,
}, gui)
local crosshairH = make("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(18, 2),
    BackgroundColor3 = Color3.fromRGB(185, 115, 255),
    BorderSizePixel = 0,
    ZIndex = 45,
}, crosshair)
local crosshairV = make("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(2, 18),
    BackgroundColor3 = Color3.fromRGB(185, 115, 255),
    BorderSizePixel = 0,
    ZIndex = 45,
}, crosshair)

RunService.RenderStepped:Connect(function(dt)
    crosshair.Visible = S.Crosshair
    if S.CameraFOVEnabled and camera then
        local targetFOV = S.CameraFOV
        if math.abs(camera.FieldOfView - targetFOV) > 0.1 then
            camera.FieldOfView += (targetFOV - camera.FieldOfView) * math.clamp(dt * 8, 0, 1)
        end
    end
    if S.SpinTest then
        -- Placeholder is intentionally visual-only; rotating the HumanoidRootPart from
        -- a LocalScript can fight character controls and server replication.
        spinAngle = (spinAngle + math.rad(360 * S.SpinSpeed) * dt) % (math.pi * 2)
    end
end)

UIS.JumpRequest:Connect(function()
    if not S.InfiniteJump then return end
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if humanoid and humanoid.Health > 0 then
        humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
    end
end)

--==================================================
-- PERIODIC ESP UPDATE
--==================================================

RunService.Heartbeat:Connect(function(dt)
    espElapsed += dt

    if espElapsed >= 0.25 then
        espElapsed = 0
        updateESP()
    end
end)

--==================================================
-- PLAYER JOIN / LEAVE
--==================================================

local function onPlayerCharacterAdded(character)
    task.defer(function()
        trackModel(character)
    end)
end

local function connectPlayer(plr)
    if plr == player then return end

    plr.CharacterAdded:Connect(onPlayerCharacterAdded)

    plr.CharacterRemoving:Connect(function(character)
        clearESP(character)
    end)

    if plr.Character then
        onPlayerCharacterAdded(plr.Character)
    end
end

for _, plr in ipairs(Players:GetPlayers()) do
    connectPlayer(plr)
end

Players.PlayerAdded:Connect(connectPlayer)

Players.PlayerRemoving:Connect(function(plr)
    if plr.Character then
        clearESP(plr.Character)
    end
end)

player.CharacterRemoving:Connect(function()
    lockedTarget = nil
    rightMouseHeld = false
end)

--==================================================
-- INTRO SEQUENCE
--==================================================

showTab("ESP")

task.spawn(function()
    tween(introGlow, {
        BackgroundTransparency = 0.45,
        Size = UDim2.fromOffset(190, 190),
    }, 0.6)

    tween(introIconHolder, {
        Size = UDim2.fromOffset(110, 110),
        Position = UDim2.fromScale(0.5, 0.36),
    }, 0.65, Enum.EasingStyle.Back)
    introIcon.Rotation = -18
    tween(introIcon, {Rotation = 0}, 0.65, Enum.EasingStyle.Back)

    task.wait(0.25)

    tween(introTitle, {
        TextTransparency = 0,
        Position = UDim2.fromScale(0.5, 0.47),
    }, 0.55, Enum.EasingStyle.Back)

    task.wait(0.2)

    tween(introSubtitle, {TextTransparency = 0}, 0.4)
    tween(introTrack, {BackgroundTransparency = 0}, 0.3)
    tween(introFill, {Size = UDim2.new(1, 0, 1, 0)}, 1.1)

    task.wait(1.15)

    tween(introIconHolder, {Size = UDim2.fromOffset(0, 0)}, 0.25)
    tween(introTitle, {TextTransparency = 1}, 0.25)
    tween(introSubtitle, {TextTransparency = 1}, 0.2)
    tween(introTrack, {BackgroundTransparency = 1}, 0.2)
    tween(dimmer, {BackgroundTransparency = 1}, 0.4)

    task.wait(0.42)

    if dimmer.Parent then dimmer:Destroy() end

    -- Initial menu position is centered.
    main.Position = UDim2.fromScale(0.5, 0.5)
    main.Size = UDim2.fromOffset(WINDOW_WIDTH - 35, WINDOW_HEIGHT - 35)
    main.Visible = true
    menuOpen = true

    tween(main, {
        Size = UDim2.fromOffset(WINDOW_WIDTH, WINDOW_HEIGHT),
    }, 0.38, Enum.EasingStyle.Back)
end)

--==================================================
-- CLEANUP
--==================================================

local function cleanup()
    pcall(function()
        RunService:UnbindFromRenderStep(RENDER_NAME)
    end)

    local Lighting = game:GetService("Lighting")
    if lightingSnapshot then
        Lighting.Brightness = lightingSnapshot.Brightness
        Lighting.ClockTime = lightingSnapshot.ClockTime
        Lighting.GlobalShadows = lightingSnapshot.GlobalShadows
        Lighting.Ambient = lightingSnapshot.Ambient
        Lighting.OutdoorAmbient = lightingSnapshot.OutdoorAmbient
    end
    if fogSnapshot then
        Lighting.FogStart = fogSnapshot.FogStart
        Lighting.FogEnd = fogSnapshot.FogEnd
    end
    if camera then
        camera.FieldOfView = originalCameraFOV
    end
    player.CameraMinZoomDistance = originalCameraMinZoom
    player.CameraMaxZoomDistance = originalCameraMaxZoom
    player.CameraMode = originalCameraMode

    for model in pairs(espObjects) do
        clearESP(model)
    end
end

script.Destroying:Connect(cleanup)

applyMovementSettings(player.Character)

print("[PHANTOM] Loaded successfully.")
print("[PHANTOM] Menu: RightShift")
print("[PHANTOM] Aim: enable Aim Assist + targeting, then hold RMB.")
print("[PHANTOM] ESP uses cached models.")
print("[PHANTOM] Movement settings: PLAYER tab")