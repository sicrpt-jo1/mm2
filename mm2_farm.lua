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
	MIN_TRAVEL = 0.1, -- أقل زمن لكل تنقّل
	AFTER_TOUCH_WAIT = 0.12,
	LOOP_WAIT = 0.35,
	MAX_COIN_DIST = 350, -- لا يروح لعملة أبعد من هذا (حماية من الذهاب للماب وأنت باللوبي)
	BAG_SIZE = 40, -- يُستخدم فقط إذا فشل كشف امتلاء الحقيبة تلقائياً
	RESET_COOLDOWN = 6,
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
	NoRoundEvents = false, -- إذا ما لقينا أحداث للجولة نعتمد على وجود العملات فقط
	InRound = false, -- هل فيه جولة شغّالة الآن
	BagFull = false,
	ResetLock = false, -- بعد الـ Reset ننتظر الجولة القادمة
	EventSeen = false, -- هل وصلنا حدث CoinCollected فعلاً
	EventCoins = 0, -- عملات هذه الجولة حسب الحدث
	Touched = 0, -- عملات هذه الجولة حسب لمسنا نحن
	Visited = {},
	Coins = 0,
	Status = "—",
	StartTime = os.clock(),
}

local playerGui = LocalPlayer:WaitForChild("PlayerGui")

local connections = {}
local function bind(signal, fn)
	local c = signal:Connect(fn)
	table.insert(connections, c)
	return c
end

--=============================================================
-- الأحداث من اللعبة
--=============================================================
local function newRound()
	State.BagFull = false
	State.ResetLock = false
	State.EventCoins = 0
	State.Touched = 0
	State.Visited = {}
end

bind(LocalPlayer.CharacterAdded, function()
	State.BagFull = false
end)

task.spawn(function()
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
	local gameplay = remotes and remotes:WaitForChild("Gameplay", 15)
	if not gameplay then
		log("ما لقيت Remotes.Gameplay — سأعتمد على قراءة الواجهة والعدّاد")
		return
	end

	local collected = gameplay:FindFirstChild("CoinCollected")
	if collected and collected:IsA("RemoteEvent") then
		bind(collected.OnClientEvent, function(...)
			State.EventSeen = true
			State.Coins += 1
			State.EventCoins += 1
			-- آخر رقمين في المعطيات = (الحالي، الأقصى)
			local nums = {}
			for _, v in ipairs({ ... }) do
				if typeof(v) == "number" then
					table.insert(nums, v)
				end
			end
			local cur, max = nums[#nums - 1], nums[#nums]
			if cur and max and max > 0 and cur >= max then
				State.BagFull = true
			end
		end)
	else
		log("ما لقيت CoinCollected")
	end

	-- أحداث الجولة: أي حدث اسمه يدل على البداية أو النهاية
	local STARTS = { "roundstart", "roundbegin", "startround", "gamestart" }
	local ENDS = { "roundend", "gameover", "endround", "roundfinish", "winner" }
	local function hasAny(name, list)
		name = string.lower(name)
		for _, w in ipairs(list) do
			if string.find(name, w, 1, true) then
				return true
			end
		end
		return false
	end
	local bound = 0
	for _, ev in ipairs(gameplay:GetChildren()) do
		if ev:IsA("RemoteEvent") then
			if hasAny(ev.Name, STARTS) or hasAny(ev.Name, ENDS) then
				bound += 1
			end
			if hasAny(ev.Name, STARTS) then
				bind(ev.OnClientEvent, function()
					newRound()
					State.InRound = true
					log("بدأت الجولة")
				end)
			elseif hasAny(ev.Name, ENDS) then
				bind(ev.OnClientEvent, function()
					newRound()
					State.InRound = false
					log("انتهت الجولة — توقف الجمع")
				end)
			end
		end
	end
	if bound == 0 then
		State.NoRoundEvents = true
		log("ما لقيت أحداث بداية/نهاية الجولة — سأعتمد على وجود العملات")
	end
end)

-- قراءة العدّاد "x/40" من واجهة اللعبة (احتياطي)
local function readBagFromGui()
	for _, d in ipairs(playerGui:GetDescendants()) do
		if d:IsA("TextLabel") and d.Text ~= "" and #d.Text <= 12 then
			local cur, max = string.match(d.Text, "^%s*(%d+)%s*/%s*(%d+)%s*$")
			if cur then
				local p, depth = d.Parent, 0
				while p and p ~= playerGui and depth < 10 do
					if string.find(string.lower(p.Name), "coin", 1, true) then
						return tonumber(cur), tonumber(max)
					end
					p, depth = p.Parent, depth + 1
				end
			end
		end
	end
	return nil, nil
end

--=============================================================
-- Auto Farm Coins
--=============================================================
local function getRoot()
	local char = LocalPlayer.Character
	if not char then
		return nil, nil
	end
	return char:FindFirstChild("HumanoidRootPart"), char:FindFirstChildOfClass("Humanoid")
end

local function findCoins(root)
	local list = {}
	local function consider(c)
		if c:IsA("BasePart") and c.Parent and not State.Visited[c] then
			if root and (c.Position - root.Position).Magnitude > Config.MAX_COIN_DIST then
				return
			end
			table.insert(list, c)
		end
	end

	-- 1) العملات المباشرة داخل CoinContainer (لا نشترط الشفافية: Coin_Server غالباً شفاف)
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d.Name == "CoinContainer" then
			for _, c in ipairs(d:GetChildren()) do
				consider(c)
			end
		end
	end

	-- 2) احتياطي: أي جزء اسمه Coin_Server في أي مكان
	if #list == 0 then
		for _, d in ipairs(Workspace:GetDescendants()) do
			if d.Name == "Coin_Server" then
				consider(d)
			end
		end
	end

	if not root then
		return list
	end
	local pos = root.Position
	table.sort(list, function(a, b)
		return (a.Position - pos).Magnitude < (b.Position - pos).Magnitude
	end)
	return list
end

local function goTo(root, part)
	State.Visited[part] = true
	local target = CFrame.new(part.Position + Vector3.new(0, 1.5, 0))
	local dist = (root.Position - target.Position).Magnitude
	local t = math.max(Config.MIN_TRAVEL, dist / Config.TRAVEL_SPEED)

	local ok = pcall(function()
		TweenService:Create(root, TweenInfo.new(t, Enum.EasingStyle.Linear), { CFrame = target }):Play()
		task.wait(t + 0.03)
	end)
	-- إذا علقنا في شي أو فشل التوين، ننقل مباشرة
	if not ok or (root.Position - target.Position).Magnitude > 6 then
		root.CFrame = target
	end
	root.AssemblyLinearVelocity = Vector3.zero

	if typeof(firetouchinterest) == "function" then
		pcall(function()
			firetouchinterest(root, part, 0)
			firetouchinterest(root, part, 1)
		end)
	end
	State.Touched += 1
	task.wait(Config.AFTER_TOUCH_WAIT)
end

-- إذا شغّلت السكربت أثناء جولة: نعتبرها جولة إذا فيه عملات قريبة منك
task.delay(2, function()
	local root = getRoot()
	if root and #findCoins(root) > 0 then
		State.InRound = true
	end
end)

-- Noclip أثناء الفارم حتى لا نعلق بالجدران
bind(RunService.Stepped, function()
	if State.Farm and (State.InRound or State.NoRoundEvents) then
		local char = LocalPlayer.Character
		if char then
			for _, p in ipairs(char:GetDescendants()) do
				if p:IsA("BasePart") then
					p.CanCollide = false
				end
			end
		end
	end
end)

task.spawn(function()
	while true do
		task.wait(Config.LOOP_WAIT)
		if not State.Farm then
			State.Status = "الفارم متوقف"
			continue
		end

		if not (State.InRound or State.NoRoundEvents) then
			State.Status = "الجولة منتهية — ينتظر جولة جديدة"
			continue
		end

		local root, hum = getRoot()
		if not root or not hum or hum.Health <= 0 then
			State.Status = "الشخصية غير موجودة / ميتة"
			continue
		end

		if State.BagFull or State.ResetLock then
			State.Status = State.AutoReset and "الحقيبة ممتلئة — Reset" or "الحقيبة ممتلئة"
			continue
		end

		local coins = findCoins(root)
		if #coins == 0 then
			State.Status = "ما فيه عملات — ادخل جولة"
			continue
		end

		State.Status = ("يجمع... (%d عملة)"):format(#coins)
		local ok, err = pcall(function()
			for _, coin in ipairs(coins) do
				if not State.Farm or not (State.InRound or State.NoRoundEvents) or State.BagFull or State.ResetLock then
					break
				end
				local r, h = getRoot()
				if not r or not h or h.Health <= 0 then
					break
				end
				if coin.Parent then
					goTo(r, coin)
				end
			end
		end)
		if not ok then
			warn("[mm2farm] " .. tostring(err))
		end
	end
end)

--=============================================================
-- Auto Reset (مستقل عن الفارم)
--=============================================================
task.spawn(function()
	while true do
		task.wait(1)
		if State.AutoReset and not State.ResetLock then
			if not State.BagFull then
				-- 1) قراءة الواجهة
				local cur, max = readBagFromGui()
				if cur and max and max > 0 and cur >= max then
					State.BagFull = true
				-- 2) عدّاد احتياطي إذا ما وصلتنا أحداث من اللعبة
				elseif not State.EventSeen and State.Touched >= Config.BAG_SIZE then
					State.BagFull = true
				end
			end

			if State.BagFull then
				local char = LocalPlayer.Character
				local hum = char and char:FindFirstChildOfClass("Humanoid")
				if hum and hum.Health > 0 then
					log("الحقيبة ممتلئة — Reset")
					State.ResetLock = true
					State.BagFull = false
					hum.Health = 0
					task.delay(1, function()
						local c2 = LocalPlayer.Character
						if c2 and c2:FindFirstChildOfClass("Humanoid") and c2:FindFirstChildOfClass("Humanoid").Health > 0 then
							pcall(function()
								c2:BreakJoints()
							end)
						end
					end)
					task.wait(Config.RESET_COOLDOWN)
				end
			end
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

local old = playerGui:FindFirstChild("MM2Farm")
if old then
	old:Destroy()
end

local screen = Instance.new("ScreenGui")
screen.Name = "MM2Farm"
screen.ResetOnSpawn = false
screen.DisplayOrder = 999
screen.IgnoreGuiInset = true
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.Parent = playerGui

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(280, 0)
main.AutomaticSize = Enum.AutomaticSize.Y
main.AnchorPoint = Vector2.new(0, 0.5)
main.Position = UDim2.new(0, 12, 0.5, 0)
main.BackgroundColor3 = COLORS.Bg
main.BorderSizePixel = 0
main.Active = true
main.Parent = screen
round(main, 12)

if UserInputService.TouchEnabled then
	local scale = Instance.new("UIScale")
	scale.Scale = 0.8
	scale.Parent = main
end

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

local statusLabel = Instance.new("TextLabel")
statusLabel.BackgroundTransparency = 1
statusLabel.Size = UDim2.new(1, 0, 0, 18)
statusLabel.LayoutOrder = 6
statusLabel.Font = Enum.Font.GothamMedium
statusLabel.TextSize = 12
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextColor3 = COLORS.Accent
statusLabel.Text = "الحالة: —"
statusLabel.Parent = body

task.spawn(function()
	while screen.Parent do
		local s = math.floor(os.clock() - State.StartTime)
		timeLabel.Text = ("⏳ %dd %dh %dm %ds   |   🪙 %d"):format(
			math.floor(s / 86400), math.floor(s % 86400 / 3600), math.floor(s % 3600 / 60), s % 60, State.Coins
		)
		statusLabel.Text = "الحالة: " .. State.Status
		task.wait(0.5)
	end
end)

-- إظهار/إخفاء + سحب
-- أيقونة عائمة: اضغطها لإخفاء/إظهار الواجهة، واسحبها لتغيير مكانها
local icon = Instance.new("TextButton")
icon.Name = "ToggleIcon"
icon.Size = UDim2.fromOffset(52, 52)
icon.AnchorPoint = Vector2.new(1, 0.5)
icon.Position = UDim2.new(1, -16, 0.35, 0)
icon.BackgroundColor3 = COLORS.Bg
icon.BorderSizePixel = 0
icon.AutoButtonColor = false
icon.Text = "🎃"
icon.TextSize = 26
icon.Font = Enum.Font.GothamBold
icon.ZIndex = 100
icon.Parent = screen
round(icon, 26)

local iconStroke = Instance.new("UIStroke")
iconStroke.Color = COLORS.Accent
iconStroke.Thickness = 2
iconStroke.Parent = icon

local function setVisible(v)
	main.Visible = v
	iconStroke.Color = v and COLORS.Accent or COLORS.Off
end

do
	local pressing, moved, startPos, startIcon = false, false, nil, nil
	icon.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			pressing, moved = true, false
			startPos, startIcon = input.Position, icon.Position
		end
	end)
	bind(UserInputService.InputChanged, function(input)
		if pressing and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - startPos
			if d.Magnitude > 8 then
				moved = true
			end
			if moved then
				icon.Position = UDim2.new(
					startIcon.X.Scale, startIcon.X.Offset + d.X,
					startIcon.Y.Scale, startIcon.Y.Offset + d.Y
				)
			end
		end
	end)
	bind(UserInputService.InputEnded, function(input)
		if pressing and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
			pressing = false
			if not moved then
				setVisible(not main.Visible)
			end
		end
	end)
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
