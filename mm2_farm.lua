--[[
	MM2 Coin Farm  (كود مفتوح — لا يحمّل أي شي من الإنترنت)
	الميزات:
	  1) Auto Farm Coins   : يجمع العملات في الجولة
	  2) Auto Reset        : عند امتلاء الحقيبة يعمل Reset للشخصية
	  3) Disable Render    : يطفي رسم العالم ثلاثي الأبعاد لتخفيف الحمل
	  4) Anti-AFK          : يمنع الطرد بسبب الخمول
	  + عدّاد وقت اللعب
	RightShift = إظهار / إخفاء الواجهة

	ملاحظة: كتبته أنا بناءً على أسماء الأحداث التي ظهرت في السكربت المشفّر
	(Remotes.Gameplay.CoinCollected / RoundStart / RoundEndFade)، ولم أجرّبه داخل اللعبة.
	إذا لم يجمع شي، افتح Console (F9) وشوف الرسائل التي تبدأ بـ [mm2farm].
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualUser = game:GetService("VirtualUser")

local LocalPlayer = Players.LocalPlayer

--=============================================================
-- الإعدادات
--=============================================================
local Config = {
	TRAVEL_SPEED = 26, -- ستود/ثانية (أقل = أأمن)
	MIN_TRAVEL = 0.12, -- أقل زمن لكل تنقّل
	AFTER_TOUCH_WAIT = 0.15,
	LOOP_WAIT = 0.4,
	RESET_ON_FULL = true,
	KEYBIND = Enum.KeyCode.RightShift,
}

local function log(msg)
	print("[mm2farm] " .. tostring(msg))
end

--=============================================================
-- الحالة
--=============================================================
local State = {
	Farm = false,
	AutoReset = false,
	RenderOff = false,
	AntiAfk = false,
	BagFull = false,
	Coins = 0,
	StartTime = os.clock(),
}

local connections = {}
local function bind(signal, fn)
	local c = signal:Connect(fn)
	table.insert(connections, c)
	return c
end

--=============================================================
-- الأحداث من اللعبة
--=============================================================
local function getGameplayRemote(name)
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local gameplay = remotes and remotes:FindFirstChild("Gameplay")
	return gameplay and gameplay:FindFirstChild(name)
end

task.spawn(function()
	local coinEvent = ReplicatedStorage:WaitForChild("Remotes", 15)
	coinEvent = coinEvent and coinEvent:WaitForChild("Gameplay", 15)
	if not coinEvent then
		log("ما لقيت Remotes.Gameplay — الجمع سيعمل بدون كشف امتلاء الحقيبة")
		return
	end

	local collected = coinEvent:FindFirstChild("CoinCollected")
	if collected and collected:IsA("RemoteEvent") then
		bind(collected.OnClientEvent, function(_coinType, current, max)
			State.Coins += 1
			if typeof(current) == "number" and typeof(max) == "number" and current >= max then
				State.BagFull = true
			end
		end)
	end

	local roundStart = coinEvent:FindFirstChild("RoundStart")
	if roundStart and roundStart:IsA("RemoteEvent") then
		bind(roundStart.OnClientEvent, function()
			State.BagFull = false
		end)
	end

	local roundEnd = coinEvent:FindFirstChild("RoundEndFade")
	if roundEnd and roundEnd:IsA("RemoteEvent") then
		bind(roundEnd.OnClientEvent, function()
			State.BagFull = false
		end)
	end
end)

--=============================================================
-- Auto Farm Coins
--=============================================================
local function getRoot()
	local char = LocalPlayer.Character
	return char and char:FindFirstChild("HumanoidRootPart"), char and char:FindFirstChildOfClass("Humanoid")
end

local function isCoin(part)
	if not part:IsA("BasePart") or part.Transparency >= 1 then
		return false
	end
	local n = string.lower(part.Name)
	return n == "coin_server" or string.find(n, "coin", 1, true) ~= nil
end

local function findCoins(root)
	local list = {}
	-- في MM2 العملات داخل حاوية اسمها CoinContainer داخل الخريطة
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d.Name == "CoinContainer" then
			for _, c in ipairs(d:GetChildren()) do
				if isCoin(c) then
					table.insert(list, c)
				end
			end
		end
	end
	local pos = root.Position
	table.sort(list, function(a, b)
		return (a.Position - pos).Magnitude < (b.Position - pos).Magnitude
	end)
	return list
end

local function goTo(root, part)
	local dist = (root.Position - part.Position).Magnitude
	local t = math.max(Config.MIN_TRAVEL, dist / Config.TRAVEL_SPEED)
	local tween = TweenService:Create(root, TweenInfo.new(t, Enum.EasingStyle.Linear), {
		CFrame = CFrame.new(part.Position + Vector3.new(0, 1, 0)),
	})
	tween:Play()
	tween.Completed:Wait()
	if typeof(firetouchinterest) == "function" then
		pcall(function()
			firetouchinterest(root, part, 0)
			firetouchinterest(root, part, 1)
		end)
	end
	task.wait(Config.AFTER_TOUCH_WAIT)
end

local function resetCharacter()
	local _, hum = getRoot()
	if hum then
		hum.Health = 0
	end
	State.BagFull = false
	log("Reset — الحقيبة ممتلئة")
	task.wait(4) -- ننتظر الرجوع للحياة
end

task.spawn(function()
	while true do
		task.wait(Config.LOOP_WAIT)
		if not State.Farm then
			continue
		end

		local root, hum = getRoot()
		if not root or not hum or hum.Health <= 0 then
			continue
		end

		if State.BagFull then
			if State.AutoReset then
				resetCharacter()
			end
			continue
		end

		local ok, err = pcall(function()
			for _, coin in ipairs(findCoins(root)) do
				if not State.Farm or State.BagFull then
					break
				end
				if coin.Parent and coin.Transparency < 1 then
					goTo(root, coin)
				end
			end
		end)
		if not ok then
			warn("[mm2farm] " .. tostring(err))
		end
	end
end)

--=============================================================
-- Disable Render
--=============================================================
local function setRender(off)
	State.RenderOff = off
	pcall(function()
		RunService:Set3dRenderingEnabled(not off)
	end)
end

--=============================================================
-- Anti-AFK
--=============================================================
bind(LocalPlayer.Idled, function()
	if State.AntiAfk then
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end
end)

--=============================================================
-- الواجهة
--=============================================================
local COLORS = {
	Bg = Color3.fromRGB(18, 14, 24),
	Row = Color3.fromRGB(34, 28, 46),
	Accent = Color3.fromRGB(255, 130, 40),
	On = Color3.fromRGB(80, 210, 130),
	Off = Color3.fromRGB(90, 90, 105),
	Text = Color3.fromRGB(240, 238, 248),
	Muted = Color3.fromRGB(150, 145, 170),
}

local function round(inst, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
end

local playerGui = LocalPlayer:WaitForChild("PlayerGui")
local old = playerGui:FindFirstChild("MM2Farm")
if old then
	old:Destroy()
end

local screen = Instance.new("ScreenGui")
screen.Name = "MM2Farm"
screen.ResetOnSpawn = false
screen.DisplayOrder = 50
screen.Parent = playerGui

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(280, 0)
main.AutomaticSize = Enum.AutomaticSize.Y
main.Position = UDim2.new(0, 20, 0.5, -150)
main.BackgroundColor3 = COLORS.Bg
main.BorderSizePixel = 0
main.Active = true
main.Parent = screen
round(main, 12)

local stroke = Instance.new("UIStroke")
stroke.Color = COLORS.Accent
stroke.Transparency = 0.5
stroke.Parent = main

local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 40)
header.BackgroundTransparency = 1
header.Parent = main

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(14, 0)
title.Size = UDim2.new(1, -56, 1, 0)
title.Font = Enum.Font.GothamBold
title.TextSize = 15
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = COLORS.Text
title.Text = "MM2 Coin Farm"
title.Parent = header

local close = Instance.new("TextButton")
close.Size = UDim2.fromOffset(26, 26)
close.Position = UDim2.new(1, -36, 0, 7)
close.BackgroundColor3 = COLORS.Row
close.BorderSizePixel = 0
close.Text = "✕"
close.TextColor3 = COLORS.Muted
close.Font = Enum.Font.GothamBold
close.TextSize = 13
close.Parent = header
round(close, 7)

local body = Instance.new("Frame")
body.Position = UDim2.fromOffset(0, 40)
body.Size = UDim2.new(1, 0, 0, 0)
body.AutomaticSize = Enum.AutomaticSize.Y
body.BackgroundTransparency = 1
body.Parent = main

local pad = Instance.new("UIPadding")
pad.PaddingLeft = UDim.new(0, 14)
pad.PaddingRight = UDim.new(0, 14)
pad.PaddingBottom = UDim.new(0, 14)
pad.Parent = body

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 8)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = body

local function addToggle(order, text, onChange)
	local row = Instance.new("TextButton")
	row.Size = UDim2.new(1, 0, 0, 36)
	row.BackgroundColor3 = COLORS.Row
	row.BorderSizePixel = 0
	row.AutoButtonColor = false
	row.Text = ""
	row.LayoutOrder = order
	row.Parent = body
	round(row, 8)

	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Position = UDim2.fromOffset(12, 0)
	lbl.Size = UDim2.new(1, -70, 1, 0)
	lbl.Font = Enum.Font.GothamMedium
	lbl.TextSize = 13
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextColor3 = COLORS.Text
	lbl.Text = text
	lbl.Parent = row

	local pill = Instance.new("Frame")
	pill.Size = UDim2.fromOffset(40, 20)
	pill.Position = UDim2.new(1, -52, 0.5, -10)
	pill.BackgroundColor3 = COLORS.Off
	pill.BorderSizePixel = 0
	pill.Parent = row
	round(pill, 10)

	local knob = Instance.new("Frame")
	knob.Size = UDim2.fromOffset(16, 16)
	knob.Position = UDim2.fromOffset(2, 2)
	knob.BackgroundColor3 = Color3.new(1, 1, 1)
	knob.BorderSizePixel = 0
	knob.Parent = pill
	round(knob, 8)

	local on = false
	local function apply()
		TweenService:Create(pill, TweenInfo.new(0.15), { BackgroundColor3 = on and COLORS.On or COLORS.Off }):Play()
		TweenService:Create(knob, TweenInfo.new(0.15), {
			Position = on and UDim2.fromOffset(22, 2) or UDim2.fromOffset(2, 2),
		}):Play()
	end
	row.MouseButton1Click:Connect(function()
		on = not on
		apply()
		onChange(on)
	end)
end

addToggle(1, "🎃 Auto Farm Coins", function(v)
	State.Farm = v
	log("Auto Farm: " .. tostring(v))
end)
addToggle(2, "💀 Auto Reset (عند امتلاء الحقيبة)", function(v)
	State.AutoReset = v
end)
addToggle(3, "👻 Disable Render", function(v)
	setRender(v)
end)
addToggle(4, "💤 Anti-AFK", function(v)
	State.AntiAfk = v
end)

local timeLabel = Instance.new("TextLabel")
timeLabel.BackgroundTransparency = 1
timeLabel.Size = UDim2.new(1, 0, 0, 20)
timeLabel.LayoutOrder = 5
timeLabel.Font = Enum.Font.Gotham
timeLabel.TextSize = 12
timeLabel.TextXAlignment = Enum.TextXAlignment.Left
timeLabel.TextColor3 = COLORS.Muted
timeLabel.Text = "⏳ 0d 0h 0m 0s   |   🪙 0"
timeLabel.Parent = body

task.spawn(function()
	while screen.Parent do
		local s = math.floor(os.clock() - State.StartTime)
		timeLabel.Text = ("⏳ %dd %dh %dm %ds   |   🪙 %d"):format(
			math.floor(s / 86400), math.floor(s % 86400 / 3600), math.floor(s % 3600 / 60), s % 60, State.Coins
		)
		task.wait(1)
	end
end)

-- إظهار/إخفاء + سحب
local function setVisible(v)
	main.Visible = v
end
close.MouseButton1Click:Connect(function()
	setVisible(false)
end)
bind(UserInputService.InputBegan, function(input, processed)
	if not processed and input.KeyCode == Config.KEYBIND then
		setVisible(not main.Visible)
	end
end)

do
	local dragging, startMouse, startPos = false, nil, nil
	header.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, startMouse, startPos = true, input.Position, main.Position
		end
	end)
	bind(UserInputService.InputChanged, function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - startMouse
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
	bind(UserInputService.InputEnded, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
end

log("تم التحميل")
