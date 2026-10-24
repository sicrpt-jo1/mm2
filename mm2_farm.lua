--[[
	MM2 Coin Farm  (كود مفتوح — لا يحمّل أي شي من الإنترنت)
	الميزات:
	  1) Auto Farm Coins   : يجمع العملات في الجولة
	  2) Auto Reset        : عند امتلاء الحقيبة يعمل Reset للشخصية
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
local VERSION = "v9"

--=============================================================
-- الإعدادات
--=============================================================
local Config = {
	TRAVEL_SPEED = 15, -- ستود/ثانية (15 = قريب من المشي العادي، كل ما زاد صار أخطر)
	MIN_TRAVEL = 0.08,
	AFTER_TOUCH_WAIT = 0.15, -- نبقى لحظة على العملة حتى يسجّل السيرفر اللمس
	LOOP_WAIT = 0.35,
	MAX_COIN_DIST = 350, -- لا يروح لعملة أبعد من هذا (حماية من الذهاب للماب وأنت باللوبي)
	UNDERGROUND_DEPTH = 7, -- كم ستود تحت العملة يغوص (وضع تحت الأرض)
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
	Underground = false, -- ميزة: الفارم وأنت متمدد تحت الأرض
	UndergroundOn = false,
	UndergroundChar = nil,
	Hold = nil,
	SurfaceY = nil,
	LastError = "-",
	LastResult = "-",
	Attempts = 0,
	Moving = false,
	Noclip = true,
	AutoReset = false,
	AntiAfk = false,
	NoRoundEvents = false, -- إذا ما لقينا أحداث للجولة نعتمد على وجود العملات فقط
	RoundEndedAt = nil,
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
					State.RoundEndedAt = os.clock()
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

local containerCache = nil

local function getContainer()
	if containerCache and containerCache.Parent then
		return containerCache
	end
	containerCache = nil
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d.Name == "CoinContainer" then
			containerCache = d
			break
		end
	end
	return containerCache
end

local function findCoins(root)
	local list = {}
	local function consider(c)
		if c:IsA("Model") then
			c = c.PrimaryPart or c:FindFirstChildWhichIsA("BasePart", true)
		end
		if c and c:IsA("BasePart") and c.Parent and not State.Visited[c] then
			if root and (c.Position - root.Position).Magnitude > Config.MAX_COIN_DIST then
				return
			end
			table.insert(list, c)
		end
	end

	-- العملات المباشرة داخل CoinContainer (لا نشترط الشفافية: Coin_Server غالباً شفاف)
	local container = getContainer()
	if container then
		for _, c in ipairs(container:GetChildren()) do
			consider(c)
		end
	elseif #list == 0 then
		-- احتياطي: أي جزء اسمه Coin_Server
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

-- هل العملة ما زالت موجودة؟ (تختفي إذا أخذها لاعب آخر)
local function coinAlive(part, hadVisual)
	if not part.Parent or not part:IsDescendantOf(Workspace) then
		return false
	end
	if hadVisual and not part:FindFirstChild("CoinVisual") then
		return false
	end
	return true
end

-- اختراق الجدران (Noclip): فقط أثناء الطيران نحو عملة. وهو واقف نرجّع التصادم
-- (وإلا تسقط الشخصية من الأرض!)
local noclipParts, noclipChar, originalCollide = {}, nil, {}

local function collectParts(char)
	noclipChar, noclipParts, originalCollide = char, {}, {}
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(noclipParts, d)
		end
	end
	char.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			table.insert(noclipParts, d)
		end
	end)
end

local function applyNoclip()
	if not ((State.Noclip or State.Underground) and (State.Moving or State.UndergroundOn)) then
		return
	end
	local char = LocalPlayer.Character
	if not char then
		return
	end
	if noclipChar ~= char then
		collectParts(char)
	end
	for _, p in ipairs(noclipParts) do
		if p.Parent then
			if originalCollide[p] == nil then
				originalCollide[p] = p.CanCollide
			end
			p.CanCollide = false
		end
	end
end

local function restoreCollisions()
	for p, v in pairs(originalCollide) do
		if p.Parent then
			p.CanCollide = v
		end
	end
	originalCollide = {}
end

-- قبل الفيزياء وبعدها، حتى ما يرجّع الـ Humanoid التصادم
bind(RunService.Stepped, applyNoclip)
bind(RunService.Heartbeat, applyNoclip)

--=============================================================
-- وضع "تحت الأرض": الشخصية متمددة تحت الأرض، وتطلع للعملة وترجع تغوص
-- تحذير: موقع تحت الأرض قد يعتبره السيرفر "Invalid position" (خطأ 267)
--=============================================================
local LYING = CFrame.Angles(math.rad(90), 0, 0)

local function undergroundActive()
	if not (State.Underground and State.Farm and (State.InRound or State.NoRoundEvents)) then
		return false
	end
	if State.BagFull or State.ResetLock then
		return false
	end
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.Health > 0
end

-- نضع الشخصية في مكان معيّن (متمددة إذا كان وضع تحت الأرض شغّال)
local function setPos(root, pos)
	if State.Underground then
		State.Hold = CFrame.new(pos) * LYING
		root.CFrame = State.Hold
	else
		root.CFrame = CFrame.new(pos) * (root.CFrame - root.Position)
	end
	root.AssemblyLinearVelocity = Vector3.zero
end

local function leaveUnderground()
	local sameChar = LocalPlayer.Character ~= nil and LocalPlayer.Character == State.UndergroundChar
	State.UndergroundOn = false
	State.Hold = nil
	State.UndergroundChar = nil
	local root, hum = getRoot()
	if hum then
		hum.PlatformStand = false
	end
	restoreCollisions()
	-- نطلّع الشخصية فوق الأرض (وإلا تسقط من الماب بعد رجوع التصادم)
	if sameChar and root and State.SurfaceY then
		root.CFrame = CFrame.new(root.Position.X, State.SurfaceY + 1, root.Position.Z)
		root.AssemblyLinearVelocity = Vector3.zero
	end
end

bind(RunService.Heartbeat, function()
	if undergroundActive() then
		local root, hum = getRoot()
		if not root or not hum then
			return
		end
		if not State.UndergroundOn then
			State.UndergroundOn = true
			State.UndergroundChar = LocalPlayer.Character
			State.SurfaceY = root.Position.Y
			State.Hold = CFrame.new(root.Position - Vector3.new(0, Config.UNDERGROUND_DEPTH, 0)) * LYING
		end
		hum.PlatformStand = true
		if State.Hold then
			root.CFrame = State.Hold
			root.AssemblyLinearVelocity = Vector3.zero
		end
	elseif State.UndergroundOn then
		leaveUnderground()
	end
end)

--=============================================================
-- الطيران نحو العملة
--=============================================================
local function checkAbort(root, part, hadVisual, deadline)
	if part and not coinAlive(part, hadVisual) then
		return "gone"
	end
	if not (State.Farm and (State.InRound or State.NoRoundEvents)) or State.BagFull or State.ResetLock then
		return "stopped"
	end
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not root.Parent or not hum or hum.Health <= 0 then
		return "stopped"
	end
	if os.clock() > deadline then
		return "timeout"
	end
	return nil
end

-- يطير بخطوات صغيرة نحو نقطة. يرجع nil عند الوصول، أو سبب التوقف
local function flyTo(root, target, part, hadVisual, deadline)
	while true do
		local abort = checkAbort(root, part, hadVisual, deadline)
		if abort then
			return abort
		end
		local delta = target - root.Position
		local dist = delta.Magnitude
		if dist < 0.8 then
			return nil
		end
		applyNoclip()
		State.Status = ("متجه لعملة (%.0f ستود)"):format(dist)
		local dt = RunService.Heartbeat:Wait()
		local step = math.min(Config.TRAVEL_SPEED * dt, dist)
		setPos(root, root.Position + delta.Unit * step)
	end
end

local function goToInner(root, part)
	State.Visited[part] = true
	local hadVisual = part:FindFirstChild("CoinVisual") ~= nil
	local coinPos = part.Position -- مركز الشخصية على العملة نفسها حتى يحس السيرفر باللمس
	local under = Vector3.new(coinPos.X, coinPos.Y - Config.UNDERGROUND_DEPTH, coinPos.Z)
	local startDist = (root.Position - coinPos).Magnitude
	local deadline = os.clock() + (startDist + 4 * Config.UNDERGROUND_DEPTH) / Config.TRAVEL_SPEED * 2 + 4

	local abort
	if State.Underground then
		-- نمشي تحت الأرض لتحت العملة (نمر تحت الجدران)
		abort = flyTo(root, under, part, hadVisual, deadline)
		if abort then
			return abort
		end
	end

	-- نطلع لمركز العملة (Noclip يخليك تخترق الجدران في الطريق)
	abort = flyTo(root, coinPos, part, hadVisual, deadline)
	if abort then
		return abort
	end
	State.SurfaceY = coinPos.Y

	if typeof(firetouchinterest) == "function" then
		pcall(function()
			firetouchinterest(root, part, 0)
			firetouchinterest(root, part, 1)
		end)
	end
	State.Touched += 1
	task.wait(Config.AFTER_TOUCH_WAIT)

	if State.Underground then
		-- نغوص مرة ثانية (بدون فحص العملة لأنها غالباً اختفت بعد جمعها)
		flyTo(root, under, nil, false, os.clock() + 4 * Config.UNDERGROUND_DEPTH / Config.TRAVEL_SPEED + 3)
	end
	return "ok"
end

local function goTo(root, part)
	State.Moving = true
	local ok, result = pcall(goToInner, root, part)
	State.Moving = false
	if not State.UndergroundOn then
		restoreCollisions()
		if root.Parent then
			root.AssemblyLinearVelocity = Vector3.zero
		end
	end
	if not ok then
		State.LastError = "goTo: " .. tostring(result)
		warn("[mm2farm] " .. tostring(result))
		return "stopped"
	end
	return result
end

-- إذا شغّلت السكربت أثناء جولة: نعتبرها جولة إذا فيه عملات قريبة منك
task.delay(2, function()
	local root = getRoot()
	if root and #findCoins(root) > 0 then
		State.InRound = true
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
			-- اكتشاف تلقائي: إذا فيه عملات قريبة منك ومرّ وقت على نهاية آخر جولة، نعتبرها جولة
			local r0 = getRoot()
			local recentlyEnded = State.RoundEndedAt and (os.clock() - State.RoundEndedAt) < 45
			if r0 and not recentlyEnded and #findCoins(r0) > 0 then
				State.InRound = true
				log("تم اكتشاف جولة (عملات قريبة)")
			else
				State.Status = "الجولة منتهية — ينتظر جولة جديدة"
				continue
			end
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
			while State.Farm and (State.InRound or State.NoRoundEvents) and not State.BagFull and not State.ResetLock do
				local r, h = getRoot()
				if not r or not h or h.Health <= 0 then
					break
				end
				-- نختار دائماً أقرب عملة موجودة الآن (لو اختفت عملة نتحول لغيرها تلقائياً)
				local nearest = findCoins(r)[1]
				if not nearest then
					break
				end
				State.Attempts += 1
				local result = goTo(r, nearest)
				State.LastResult = tostring(result)
				if result == "gone" then
					State.Status = "العملة اختفت — تغيير المسار"
				elseif result == "stopped" then
					break
				end
			end
		end)
		if not ok then
			State.LastError = "loop: " .. tostring(err)
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
title.Text = "MM2 Coin Farm " .. VERSION
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

local function addToggle(order, text, onChange, default)
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

	local on = default == true
	local function apply()
		TweenService:Create(pill, TweenInfo.new(0.15), { BackgroundColor3 = on and COLORS.On or COLORS.Off }):Play()
		TweenService:Create(knob, TweenInfo.new(0.15), {
			Position = on and UDim2.fromOffset(22, 2) or UDim2.fromOffset(2, 2),
		}):Play()
	end
	if on then
		apply()
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
addToggle(4, "💤 Anti-AFK", function(v)
	State.AntiAfk = v
end)
addToggle(5, "🧱 اختراق الجدران (Noclip)", function(v)
	State.Noclip = v
end, true)
addToggle(6, "🛌 تحت الأرض (خطر طرد 267)", function(v)
	State.Underground = v
end)

-- التحكم بسرعة التنقّل بين العملات (يتغيّر مباشرة أثناء الفارم)
do
	local MIN_SPEED, MAX_SPEED, STEP = 8, 80, 2

	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 36)
	row.BackgroundColor3 = COLORS.Row
	row.BorderSizePixel = 0
	row.LayoutOrder = 3
	row.Parent = body
	round(row, 8)

	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Position = UDim2.fromOffset(12, 0)
	lbl.Size = UDim2.new(0.4, 0, 1, 0)
	lbl.Font = Enum.Font.GothamMedium
	lbl.TextSize = 13
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextColor3 = COLORS.Text
	lbl.Text = "⚡ السرعة"
	lbl.Parent = row

	local function makeBtn(text, x)
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(30, 26)
		b.Position = UDim2.new(1, x, 0.5, -13)
		b.BackgroundColor3 = COLORS.Bg
		b.BorderSizePixel = 0
		b.AutoButtonColor = true
		b.Text = text
		b.TextColor3 = COLORS.Text
		b.Font = Enum.Font.GothamBold
		b.TextSize = 16
		b.Parent = row
		round(b, 6)
		return b
	end

	local minus = makeBtn("−", -120)
	local plus = makeBtn("+", -40)

	local valueLabel = Instance.new("TextLabel")
	valueLabel.BackgroundTransparency = 1
	valueLabel.Size = UDim2.fromOffset(44, 26)
	valueLabel.Position = UDim2.new(1, -86, 0.5, -13)
	valueLabel.Font = Enum.Font.GothamBold
	valueLabel.TextSize = 14
	valueLabel.Parent = row

	local function refresh()
		local v = Config.TRAVEL_SPEED
		valueLabel.Text = tostring(v)
		-- أخضر = قريب من المشي العادي، برتقالي = متوسط، أحمر = خطر الطرد أعلى
		valueLabel.TextColor3 = v <= 16 and COLORS.On or (v <= 30 and COLORS.Accent or Color3.fromRGB(255, 80, 80))
	end
	refresh()

	minus.MouseButton1Click:Connect(function()
		Config.TRAVEL_SPEED = math.max(MIN_SPEED, Config.TRAVEL_SPEED - STEP)
		refresh()
	end)
	plus.MouseButton1Click:Connect(function()
		Config.TRAVEL_SPEED = math.min(MAX_SPEED, Config.TRAVEL_SPEED + STEP)
		refresh()
	end)
end

-- تشخيص: يوضح ليش ما يجمع
local debugBtn = Instance.new("TextButton")
debugBtn.Size = UDim2.new(1, 0, 0, 30)
debugBtn.BackgroundColor3 = COLORS.Row
debugBtn.BorderSizePixel = 0
debugBtn.Text = "🔍 تشخيص"
debugBtn.TextColor3 = COLORS.Text
debugBtn.Font = Enum.Font.GothamBold
debugBtn.TextSize = 12
debugBtn.LayoutOrder = 9
debugBtn.Parent = body
round(debugBtn, 8)

local debugLabel = Instance.new("TextLabel")
debugLabel.BackgroundTransparency = 1
debugLabel.Size = UDim2.new(1, 0, 0, 0)
debugLabel.AutomaticSize = Enum.AutomaticSize.Y
debugLabel.TextWrapped = true
debugLabel.TextXAlignment = Enum.TextXAlignment.Left
debugLabel.TextYAlignment = Enum.TextYAlignment.Top
debugLabel.Font = Enum.Font.Code
debugLabel.TextSize = 11
debugLabel.TextColor3 = COLORS.Muted
debugLabel.Text = ""
debugLabel.Visible = false
debugLabel.LayoutOrder = 10
debugLabel.Parent = body

local function buildDebug()
	local L = {}
	local function add(t)
		table.insert(L, t)
	end
	local root, hum = getRoot()
	add(("Farm=%s InRound=%s NoEvents=%s"):format(tostring(State.Farm), tostring(State.InRound), tostring(State.NoRoundEvents)))
	add(("BagFull=%s ResetLock=%s EventSeen=%s"):format(tostring(State.BagFull), tostring(State.ResetLock), tostring(State.EventSeen)))
	add(("Char=%s HP=%s"):format(tostring(root ~= nil), hum and tostring(math.floor(hum.Health)) or "-"))
	add("Version: " .. VERSION)
	add("Status: " .. tostring(State.Status))
	add(("Attempts=%d Last=%s Touched=%d"):format(State.Attempts, State.LastResult, State.Touched))
	add(("Underground=%s On=%s"):format(tostring(State.Underground), tostring(State.UndergroundOn)))
	add("LastError: " .. tostring(State.LastError):sub(1, 160))
	if root then
		local p = root.Position
		add(("Pos: %.0f, %.0f, %.0f"):format(p.X, p.Y, p.Z))
	end

	local container = getContainer()
	if container then
		local kids = container:GetChildren()
		add(("CoinContainer: موجود (%s) عدد=%d"):format(container:GetFullName(), #kids))
		for i = 1, math.min(5, #kids) do
			local k = kids[i]
			local tr = k:IsA("BasePart") and (" T=" .. tostring(k.Transparency)) or ""
			add(("  %s [%s]%s"):format(k.Name, k.ClassName, tr))
		end
		if root then
			local list = findCoins(root)
			add(("بعد الفلترة (قريبة <%d): %d"):format(Config.MAX_COIN_DIST, #list))
			if list[1] then
				local c = list[1].Position
				add(("أقرب عملة: %.0f ستود  (%.0f, %.0f, %.0f)"):format((c - root.Position).Magnitude, c.X, c.Y, c.Z))
			end
			local far = 0
			for _, k in ipairs(kids) do
				if k:IsA("BasePart") and (k.Position - root.Position).Magnitude > Config.MAX_COIN_DIST then
					far += 1
				end
			end
			add(("عملات أبعد من الحد: %d"):format(far))
		end
	else
		add("CoinContainer: غير موجود")
		local n, sample = 0, nil
		for _, d in ipairs(Workspace:GetDescendants()) do
			if d:IsA("BasePart") and string.find(string.lower(d.Name), "coin", 1, true) then
				n += 1
				sample = sample or d:GetFullName()
			end
		end
		add(("أجزاء اسمها فيه coin: %d"):format(n))
		if sample then
			add("مثال: " .. sample)
		end
	end

	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local gp = remotes and remotes:FindFirstChild("Gameplay")
	if gp then
		local names = {}
		for _, ev in ipairs(gp:GetChildren()) do
			if ev:IsA("RemoteEvent") then
				table.insert(names, ev.Name)
			end
		end
		add("Events: " .. table.concat(names, ", "))
	else
		add("Remotes.Gameplay: غير موجود")
	end
	add("firetouchinterest: " .. tostring(typeof(firetouchinterest) == "function"))
	return table.concat(L, "\n")
end

debugBtn.MouseButton1Click:Connect(function()
	local ok, text = pcall(buildDebug)
	text = ok and text or ("خطأ: " .. tostring(text))
	debugLabel.Text = text
	debugLabel.Visible = true
	print("[mm2farm] --- تشخيص ---\n" .. text)
end)

local timeLabel = Instance.new("TextLabel")
timeLabel.BackgroundTransparency = 1
timeLabel.Size = UDim2.new(1, 0, 0, 20)
timeLabel.LayoutOrder = 7
timeLabel.Font = Enum.Font.Gotham
timeLabel.TextSize = 12
timeLabel.TextXAlignment = Enum.TextXAlignment.Left
timeLabel.TextColor3 = COLORS.Muted
timeLabel.Text = "⏳ 0d 0h 0m 0s   |   🪙 0"
timeLabel.Parent = body

local statusLabel = Instance.new("TextLabel")
statusLabel.BackgroundTransparency = 1
statusLabel.Size = UDim2.new(1, 0, 0, 18)
statusLabel.LayoutOrder = 8
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
