--[[
	PRISM UI  ·  v2 (carbon + bone)
	Roblox port of "Prism Script Menu v2.dc.html" — same palette, sizes, easing and behavior.

	USAGE
		local Prism  = loadstring(game:HttpGet("https://cdn.jsdelivr.net/gh/S2kh/prism@v1.0.0/PrismUI.lua"))()
		-- local file instead:  loadstring(readfile("PrismUI.lua"))()
		local Window = Prism:CreateWindow({ Name = "PRISM" })
		local Tab    = Window:AddTab("Config & Themes")
		local Sec    = Tab:AddSection("Appearance")
		Sec:AddToggle({ Text = "Glow effects", Desc = "bloom behind the panel", Default = true,
		                Callback = function(v) end })

	WHAT CARRIES OVER FROM THE MOCKUP
		· rack rows with hairline dividers + recessed section strips
		· rocker switches (grip-lined knob, overshoot snap) with a status LED per row
		· faders with detent ticks + odometer digit readouts
		· right-click a switch -> bind a key, mode = Always / Toggle / Hold   (DESKTOP ONLY)
		· scrambling keybind chips while listening
		· ticker notifications with a draining rule
		· tab underline that slides with overshoot
		· config list -> click a row to load it into the name box

	MOBILE (UserInputService.TouchEnabled and not KeyboardEnabled)
		· NO keybinds. AddKeybind is a no-op, right-click binding is disabled.
		· header button minimizes the chassis into a 56px floating icon; tap it to reopen.
		· every control is sized to a 44px touch minimum.

	TWO THINGS CSS DOES THAT ROBLOX DOESN'T
		· backdrop-filter    -> BackgroundTransparency 0.12 + optional Lighting.BlurEffect (Window.Blur)
		· box-shadow / glow  -> 9-slice ImageLabel (Theme.GlowAsset)
]]

local TweenService     = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local HttpService       = game:GetService("HttpService")
local Players           = game:GetService("Players")
local Lighting          = game:GetService("Lighting")

local MOBILE = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

--==============================================================
-- THEME
--==============================================================
local Theme = {
	Accent   = Color3.fromHex("C77DFF"),
	Bone     = Color3.fromHex("E9E4D8"),   -- primary text / metal highlight
	Bone2    = Color3.fromHex("9C978C"),   -- secondary text
	Bone3    = Color3.fromHex("89847A"),   -- row descriptions (readable dim)
	Bone4    = Color3.fromHex("5C594F"),   -- deepest dim
	Chassis  = Color3.fromHex("0F0F11"),
	Well     = Color3.fromHex("0A0A0B"),   -- recessed inputs
	Line     = Color3.fromHex("1B1A17"),   -- row divider
	Edge     = Color3.fromHex("23221E"),   -- panel edge
	Edge2    = Color3.fromHex("2C2B26"),   -- control border
	Danger   = Color3.fromHex("D9584A"),
	Radius   = 6,

	-- Saira / Azeret Mono have no Roblox equivalent; closest built-ins.
	Display  = Enum.Font.GothamMedium,
	Bold     = Enum.Font.GothamBold,
	Mono     = Enum.Font.Code,

	GlowAsset = "rbxassetid://6014261993",
}

-- easing curves lifted from the CSS
local SNAP    = TweenInfo.new(0.15, Enum.EasingStyle.Back,  Enum.EasingDirection.Out)  -- rocker knob
local SLIDE   = TweenInfo.new(0.34, Enum.EasingStyle.Back,  Enum.EasingDirection.Out)  -- tab underline
local FAST    = TweenInfo.new(0.13, Enum.EasingStyle.Quad,  Enum.EasingDirection.Out)
local SMOOTH  = TweenInfo.new(0.30, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local ROLL    = TweenInfo.new(0.40, Enum.EasingStyle.Back,  Enum.EasingDirection.Out)  -- odometer
local LINEARF = TweenInfo.new(0.09, Enum.EasingStyle.Linear)

local KEYPOOL = { "Q","W","E","R","T","F","G","V","B","X","Z","C","H","J","K","N","M","P",
                  "LeftAlt","RightShift","End","Insert","F1","F4","Tab","CapsLock" }

local Prism = {}
Prism.__index = Prism
Prism.Version = "1.0.0"  -- bump every release; the tag in your loadstring URL should match this
Prism.Theme   = Theme
Prism.Mobile  = MOBILE
Prism.Flags   = {}     -- every control with a Flag writes here; this is what you save/load

--==============================================================
-- CONNECTION REGISTRY
-- Signals on UserInputService outlive the ScreenGui they were made for. When the
-- script is re-run from a loadstring the old chunk is still connected and starts
-- throwing on destroyed instances, so every global connection is parked here and
-- Window:Destroy() tears the whole set down.
--==============================================================
local CONNS = {}
local function bind(signal, fn)
	local c = signal:Connect(fn)
	CONNS[#CONNS + 1] = c
	return c
end
local function unbindAll()
	for _, c in ipairs(CONNS) do pcall(function() c:Disconnect() end) end
	table.clear(CONNS)
end

-- where the previous run parks its unloader so the next run can find it
local function genv()
	if getgenv then
		local ok, g = pcall(getgenv)
		if ok and type(g) == "table" then return g end
	end
	return _G
end

--==============================================================
-- helpers
--==============================================================
local function new(class, props, children)
	local i = Instance.new(class)
	for k, v in pairs(props or {}) do if k ~= "Parent" then i[k] = v end end
	for _, c in ipairs(children or {}) do c.Parent = i end
	if props and props.Parent then i.Parent = props.Parent end
	return i
end

local function corner(p, r) return new("UICorner", { CornerRadius = UDim.new(0, r or 0), Parent = p }) end

local function stroke(p, color, transparency)
	return new("UIStroke", {
		Color = color or Theme.Edge2, Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = p,
	})
end

local function pad(p, t, r, b, l)
	return new("UIPadding", {
		PaddingTop = UDim.new(0, t), PaddingRight = UDim.new(0, r or t),
		PaddingBottom = UDim.new(0, b or t), PaddingLeft = UDim.new(0, l or r or t), Parent = p,
	})
end

local function list(p, gap, dir, align)
	return new("UIListLayout", {
		FillDirection = dir or Enum.FillDirection.Vertical,
		Padding = UDim.new(0, gap or 0), SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = align or Enum.VerticalAlignment.Top, Parent = p,
	})
end

local function tw(inst, info, goal) local t = TweenService:Create(inst, info, goal) t:Play() return t end

local function glow(parent, color, transparency, spread)
	spread = spread or 30
	return new("ImageLabel", {
		BackgroundTransparency = 1, Image = Theme.GlowAsset,
		ImageColor3 = color or Theme.Accent, ImageTransparency = transparency or 0.7,
		ScaleType = Enum.ScaleType.Slice, SliceCenter = Rect.new(49, 49, 450, 450),
		Size = UDim2.new(1, spread * 2, 1, spread * 2), Position = UDim2.fromOffset(-spread, -spread),
		ZIndex = 0, Parent = parent,
	})
end

local function label(parent, text, size, color, font, mono)
	local l = new("TextLabel", {
		BackgroundTransparency = 1, Text = text, TextSize = size,
		TextColor3 = color or Theme.Bone, Font = font or Theme.Display,
		TextXAlignment = Enum.TextXAlignment.Left, RichText = true,
		Size = UDim2.new(1, 0, 0, math.floor(size * 1.35)), Parent = parent,
	})
	if mono then l.Font = Theme.Mono end
	return l
end

-- brushed-metal + grip lines on a knob (the CSS repeating-linear-gradient stack)
local function grip(parent, vertical)
	return new("ImageLabel", {
		BackgroundTransparency = 1, Image = "rbxassetid://2454009026", -- fine noise/lines
		ImageTransparency = 0.82, ImageColor3 = Color3.new(0, 0, 0),
		ScaleType = Enum.ScaleType.Tile,
		TileSize = vertical and UDim2.fromOffset(4, 100) or UDim2.fromOffset(100, 4),
		Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = parent,
	})
end

local function draggable(frame, handle)
	local dragging, startPos, startInput
	handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
			dragging, startInput, startPos = true, input.Position, frame.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if not dragging then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch then
			local d = input.Position - startInput
			frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
			                          startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
end

local function keyName(code)
	local n = tostring(code):gsub("Enum.KeyCode.", "")
	return n
end

--==============================================================
-- ODOMETER  (rolling digits, like the slider readouts)
--==============================================================
local DIGIT_H = 17
local function odometer(parent, places, unit)
	local holder = new("Frame", {
		BackgroundTransparency = 1, Size = UDim2.fromOffset(places * 9 + 24, DIGIT_H),
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Parent = parent,
	})
	list(holder, 1, Enum.FillDirection.Horizontal, Enum.VerticalAlignment.Center)

	local strips = {}
	for i = 1, places do
		local window = new("Frame", {
			BackgroundTransparency = 1, ClipsDescendants = true,
			Size = UDim2.fromOffset(9, DIGIT_H), LayoutOrder = i, Parent = holder,
		})
		local col = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(9, DIGIT_H * 10), Parent = window })
		for d = 0, 9 do
			new("TextLabel", {
				BackgroundTransparency = 1, Position = UDim2.fromOffset(0, d * DIGIT_H),
				Size = UDim2.fromOffset(9, DIGIT_H), Text = tostring(d),
				TextSize = 14, Font = Theme.Mono, TextColor3 = Theme.Bone, Parent = col,
			})
		end
		strips[i] = col
	end

	if unit then
		local u = label(holder, unit, 9, Theme.Bone4, Theme.Mono, true)
		u.Size = UDim2.fromOffset(20, DIGIT_H)
		u.LayoutOrder = places + 1
	end

	return {
		Set = function(value)
			local s = string.rep("0", places) .. tostring(value)
			s = s:sub(-places)
			for i = 1, places do
				local d = tonumber(s:sub(i, i)) or 0
				tw(strips[i], ROLL, { Position = UDim2.fromOffset(0, -d * DIGIT_H) })
			end
		end
	}
end

--==============================================================
-- NOTIFICATIONS  (ticker strip + draining rule)
--==============================================================
function Prism:Notify(title, body, duration)
	local holder = self._notif
	if not holder then return end
	duration = duration or 3.6

	local card = new("Frame", {
		BackgroundColor3 = Color3.fromHex("0C0C0E"), Size = UDim2.new(1, 0, 0, 50),
		ClipsDescendants = true, Parent = holder,
	})
	stroke(card, Theme.Edge2)
	new("Frame", { BackgroundColor3 = Theme.Accent, Size = UDim2.new(0, 3, 1, 0), BorderSizePixel = 0, Parent = card })
	glow(card, Theme.Accent, 0.88, 18)

	local col = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(14, 10), Size = UDim2.new(1, -20, 1, -20), Parent = card })
	list(col, 4)
	label(col, string.upper(title), 10, Theme.Bone, Theme.Mono, true)
	label(col, body, 10, Theme.Bone3, Theme.Mono, true)

	local drain = new("Frame", {
		AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Theme.Accent, BorderSizePixel = 0, Parent = card,
	})

	-- shutter in from the right (tickerIn)
	card.Size = UDim2.new(0, 0, 0, 50)
	tw(card, SMOOTH, { Size = UDim2.new(1, 0, 0, 50) })
	tw(drain, TweenInfo.new(duration, Enum.EasingStyle.Linear), { Size = UDim2.new(0, 0, 0, 1) })

	task.delay(duration, function()
		tw(card, FAST, { Size = UDim2.new(0, 0, 0, 50) })
		task.wait(0.16)
		card:Destroy()
	end)
end

--==============================================================
-- SECTION  (a run of rack rows)
--==============================================================
local Section = {}
Section.__index = Section

local ROW_H   = MOBILE and 62 or 52
local CTRL_H  = MOBILE and 44 or 32

-- one full-width row: label + description on the left, control on the right
function Section:_row(text, desc, height)
	local r = new("Frame", {
		BackgroundColor3 = Theme.Chassis, BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, height or ROW_H), LayoutOrder = self._order, Parent = self.Frame,
	})
	self._order += 1
	new("Frame", {
		AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = Theme.Line, BorderSizePixel = 0, Parent = r,
	})
	pad(r, 0, 22)

	if text then
		local col = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -190, 1, 0), Parent = r })
		list(col, 3, nil, Enum.VerticalAlignment.Center)
		local head = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18), Parent = col })
		list(head, 8, Enum.FillDirection.Horizontal, Enum.VerticalAlignment.Center)
		local t = label(head, text, 14, Theme.Bone)
		t.Size = UDim2.fromOffset(t.TextBounds.X + 4, 18)
		t.AutomaticSize = Enum.AutomaticSize.X
		r._head = head
		if desc then label(col, string.upper(desc), 9, Theme.Bone3, Theme.Mono, true) end
	end

	-- hover wash (desktop only)
	if not MOBILE then
		r.MouseEnter:Connect(function() tw(r, FAST, { BackgroundTransparency = 0.88 }) end)
		r.MouseLeave:Connect(function() tw(r, FAST, { BackgroundTransparency = 1 }) end)
	end
	return r
end

--------------------------------------------------------------------
-- TOGGLE  (+ right-click bind popup on desktop)
--------------------------------------------------------------------
function Section:AddToggle(o)
	local state = o.Default or false
	local bind  = { Key = o.BindKey, Mode = o.BindMode or "Toggle" }
	local win   = self.Window
	local r     = self:_row(o.Text, o.Desc)

	local W, H   = MOBILE and 64 or 46, MOBILE and 36 or 24
	local KW, KH = MOBILE and 27 or 19, MOBILE and 30 or 18

	local badge = new("TextLabel", {
		BackgroundColor3 = Theme.Accent, BackgroundTransparency = 0.87,
		Size = UDim2.fromOffset(0, 15), AutomaticSize = Enum.AutomaticSize.X,
		Text = "", TextSize = 9, Font = Theme.Mono, TextColor3 = Theme.Accent,
		Visible = false, LayoutOrder = 2, Parent = r._head,
	})
	stroke(badge, Theme.Accent, 0.5)
	pad(badge, 0, 5)

	local led = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -(W + 9), 0.5, 0),
		Size = UDim2.fromOffset(MOBILE and 6 or 5, MOBILE and 6 or 5),
		BackgroundColor3 = Theme.Edge, BorderSizePixel = 0, Parent = r,
	})
	local ledGlow = glow(led, Theme.Accent, 1, 7)

	local well = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(W, H), BackgroundColor3 = Color3.fromHex("111113"),
		AutoButtonColor = false, Text = "", Parent = r,
	})
	stroke(well, Theme.Edge2)
	local slot = new("Frame", {
		Position = UDim2.fromOffset(2, 2), Size = UDim2.new(1, -4, 1, -4),
		BackgroundColor3 = Theme.Well, BorderSizePixel = 0, Parent = well,
	})
	local knob = new("Frame", {
		Position = UDim2.fromOffset(3, math.floor((H - KH) / 2)), Size = UDim2.fromOffset(KW, KH),
		BackgroundColor3 = Color3.fromHex("3B3A33"), BorderSizePixel = 0, ZIndex = 3, Parent = well,
	})
	grip(knob, true)
	local knobEdge = new("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Color3.fromHex("5C5A50"), BorderSizePixel = 0, ZIndex = 3, Parent = knob })

	local function refreshBadge()
		if bind.Mode == "Always" then
			badge.Visible, badge.Text = true, " ALWAYS "
		elseif bind.Key then
			badge.Visible = true
			badge.Text = " " .. string.upper(keyName(bind.Key)) .. (bind.Mode == "Hold" and " HOLD" or "") .. " "
		else
			badge.Visible = false
		end
	end

	local function paint()
		local on = state
		tw(slot, FAST, { BackgroundColor3 = on and Theme.Accent or Theme.Well, BackgroundTransparency = on and 0.7 or 0 })
		tw(knob, SNAP, {
			Position = UDim2.fromOffset(on and (W - KW - 3) or 3, math.floor((H - KH) / 2)),
			BackgroundColor3 = on and Color3.fromHex("E4DFD3") or Color3.fromHex("3B3A33"),
		})
		knobEdge.BackgroundColor3 = on and Color3.fromHex("FFFDF6") or Color3.fromHex("5C5A50")
		tw(led, FAST, { BackgroundColor3 = on and Theme.Accent or Theme.Edge })
		ledGlow.ImageTransparency = on and 0.45 or 1
	end

	local function set(v, fire)
		if bind.Mode == "Always" then v = true end
		state = v
		paint()
		if o.Flag then Prism.Flags[o.Flag] = v end
		if fire and o.Callback then task.spawn(o.Callback, v) end
	end

	well.MouseButton1Click:Connect(function()
		if bind.Mode == "Always" then
			Prism:Notify("LOCKED ON", (o.Text or "toggle") .. " is set to always")
			return
		end
		set(not state, true)
	end)

	----------------------------------------------------------------
	-- bind popup (DESKTOP ONLY — mobile has no keyboard)
	----------------------------------------------------------------
	if not MOBILE then
		local menu, listening, scrambleTask

		local function closeMenu()
			listening = false
			if scrambleTask then task.cancel(scrambleTask) scrambleTask = nil end
			if menu then menu:Destroy() menu = nil end
		end

		local function openMenu()
			if menu then closeMenu() return end
			if win._closePopups then win._closePopups() end

			local MH = 162
			menu = new("Frame", {
				AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(0, -12, 0.5, -MH / 2),
				Size = UDim2.fromOffset(196, MH), BackgroundColor3 = Color3.fromHex("0C0C0E"),
				ClipsDescendants = true, ZIndex = 40, Parent = well,
			})
			stroke(menu, Color3.fromHex("33322B"))
			glow(menu, Theme.Accent, 0.72, 22)
			pad(menu, 11)
			list(menu, 7)

			-- clamp inside the scrolling body so it never clips
			local body = win._body
			task.defer(function()
				if not menu then return end
				local top = menu.AbsolutePosition.Y
				local minY, maxY = body.AbsolutePosition.Y + 10, body.AbsolutePosition.Y + body.AbsoluteSize.Y - MH - 10
				local clamped = math.clamp(top, minY, maxY)
				if clamped ~= top then
					menu.Position = UDim2.new(0, -12, 0.5, -MH / 2 + (clamped - top))
				end
			end)

			local head = label(menu, "BIND · " .. string.upper(o.Text or ""), 8, Theme.Bone4, Theme.Mono, true)
			head.LayoutOrder = 1

			local keyBtn = new("TextButton", {
				Size = UDim2.new(1, 0, 0, 30), BackgroundColor3 = Theme.Well, AutoButtonColor = false,
				Text = bind.Key and string.upper(keyName(bind.Key)) or "CLICK TO BIND",
				TextSize = 11, Font = Theme.Mono,
				TextColor3 = bind.Key and Theme.Bone or Theme.Bone4, LayoutOrder = 2, Parent = menu,
			})
			local keyStroke = stroke(keyBtn, Theme.Edge2)

			keyBtn.MouseButton1Click:Connect(function()
				listening = true
				keyStroke.Color = Theme.Accent
				keyBtn.BackgroundColor3 = Theme.Accent
				keyBtn.BackgroundTransparency = 0.86
				scrambleTask = task.spawn(function()          -- scrambling readout
					while listening do
						keyBtn.Text = KEYPOOL[math.random(#KEYPOOL)]
						task.wait(0.055)
					end
				end)
			end)

			local modeRow = new("Frame", { Size = UDim2.new(1, 0, 0, 24), BackgroundTransparency = 1, LayoutOrder = 3, Parent = menu })
			list(modeRow, 3, Enum.FillDirection.Horizontal)
			local hint = label(menu, "", 8, Theme.Bone3, Theme.Mono, true)
			hint.LayoutOrder = 4
			hint.Size = UDim2.new(1, 0, 0, 22)
			hint.TextWrapped = true

			local HINTS = {
				Always = "FORCED ON — KEY AND CLICKS IGNORED",
				Toggle = "KEY FLIPS IT ON AND OFF",
				Hold   = "ON ONLY WHILE THE KEY IS HELD",
			}
			local modeBtns = {}
			local function paintModes()
				hint.Text = HINTS[bind.Mode]
				for m, b in pairs(modeBtns) do
					local on = bind.Mode == m
					tw(b, FAST, { BackgroundTransparency = on and 0.82 or 1 })
					b.TextColor3 = on and Theme.Bone or Theme.Bone4
					b._stroke.Color = on and Theme.Accent or Theme.Edge2
					b._stroke.Transparency = on and 0.45 or 0
				end
			end
			for _, m in ipairs({ "Always", "Toggle", "Hold" }) do
				local b = new("TextButton", {
					Size = UDim2.new(0.333, -2, 1, 0), BackgroundColor3 = Theme.Accent, BackgroundTransparency = 1,
					AutoButtonColor = false, Text = string.upper(m), TextSize = 9, Font = Theme.Mono,
					TextColor3 = Theme.Bone4, Parent = modeRow,
				})
				b._stroke = stroke(b, Theme.Edge2)
				modeBtns[m] = b
				b.MouseButton1Click:Connect(function()
					bind.Mode = m
					paintModes(); refreshBadge()
					if m == "Always" then set(true, true) end
					if o.BindChanged then task.spawn(o.BindChanged, bind) end
				end)
			end
			paintModes()

			local clear = new("TextButton", {
				Size = UDim2.new(1, 0, 0, 24), BackgroundColor3 = Theme.Danger, BackgroundTransparency = 0.9,
				AutoButtonColor = false, Text = "CLEAR BIND", TextSize = 9, Font = Theme.Mono,
				TextColor3 = Theme.Danger, LayoutOrder = 5, Parent = menu,
			})
			stroke(clear, Theme.Danger, 0.7)
			clear.MouseButton1Click:Connect(function()
				bind.Key, bind.Mode = nil, "Toggle"
				refreshBadge(); closeMenu()
			end)

			menu.Size = UDim2.fromOffset(196, 0)
			tw(menu, SMOOTH, { Size = UDim2.fromOffset(196, MH) })
			win._closePopups = closeMenu
		end

		well.MouseButton2Click:Connect(openMenu)

		bind(UserInputService.InputBegan, function(i, gpe)
			if i.UserInputType ~= Enum.UserInputType.Keyboard then return end
			if listening then
				bind.Key = i.KeyCode
				closeMenu()
				refreshBadge()
				Prism:Notify("BOUND · " .. string.upper(keyName(i.KeyCode)),
				             (o.Text or "toggle") .. " set to " .. string.lower(bind.Mode))
				if o.BindChanged then task.spawn(o.BindChanged, bind) end
				return
			end
			if gpe or not bind.Key or i.KeyCode ~= bind.Key then return end
			if bind.Mode == "Toggle" then set(not state, true)
			elseif bind.Mode == "Hold" then set(true, true) end
		end)
		bind(UserInputService.InputEnded, function(i)
			if bind.Mode == "Hold" and bind.Key and i.KeyCode == bind.Key then set(false, true) end
		end)
	end

	set(bind.Mode == "Always" and true or state, false)
	refreshBadge()

	return {
		Set = set, Get = function() return state end,
		SetBind = function(key, mode) bind.Key, bind.Mode = key, mode or bind.Mode refreshBadge() paint() end,
		GetBind = function() return bind end,
	}
end

--------------------------------------------------------------------
-- SLIDER  (fader + detent ticks + odometer)
--------------------------------------------------------------------
function Section:AddSlider(o)
	local min, max, step = o.Min or 0, o.Max or 100, o.Step or 1
	local places = o.Places or #tostring(max)
	local value = math.clamp(o.Default or min, min, max)
	local r = self:_row(o.Text, o.Desc)

	local right = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(MOBILE and 210 or 280, 26), BackgroundTransparency = 1, Parent = r,
	})
	local odo = odometer(right, places, o.Suffix)

	local track = new("Frame", {
		Position = UDim2.new(0, 0, 0.5, -1), Size = UDim2.new(1, -(places * 9 + 34), 0, 3),
		BackgroundColor3 = Color3.fromHex("232320"), BorderSizePixel = 0, Parent = right,
	})
	local fill = new("Frame", {
		Size = UDim2.fromScale((value - min) / (max - min), 1),
		BackgroundColor3 = Theme.Accent, BorderSizePixel = 0, Parent = track,
	})
	glow(fill, Theme.Accent, 0.6, 8)

	-- detent ticks
	local ticks = new("Frame", { Position = UDim2.fromOffset(0, 7), Size = UDim2.new(1, 0, 0, 4), BackgroundTransparency = 1, Parent = track })
	for i = 0, 18 do
		new("Frame", {
			Position = UDim2.new(i / 18, 0, 0, 0), Size = UDim2.fromOffset(1, 4),
			BackgroundColor3 = Color3.fromHex("302F29"), BorderSizePixel = 0, Parent = ticks,
		})
	end

	local cap = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new((value - min) / (max - min), 0, 0.5, 0),
		Size = UDim2.fromOffset(MOBILE and 14 or 10, MOBILE and 30 or 22),
		BackgroundColor3 = Color3.fromHex("D8D3C6"), BorderSizePixel = 0, ZIndex = 3, Parent = track,
	})
	grip(cap, false)
	new("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Color3.fromHex("FFFDF6"), BorderSizePixel = 0, ZIndex = 3, Parent = cap })
	glow(cap, Theme.Accent, 0.55, 10)

	local hit = new("TextButton", {
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.new(1, 0, 0, MOBILE and 44 or 26), BackgroundTransparency = 1,
		Text = "", ZIndex = 4, Parent = track,
	})

	local function set(v, fire)
		v = math.clamp(math.floor(v / step + 0.5) * step, min, max)
		value = v
		local a = (v - min) / (max - min)
		tw(fill, LINEARF, { Size = UDim2.fromScale(a, 1) })
		tw(cap,  LINEARF, { Position = UDim2.new(a, 0, 0.5, 0) })
		odo.Set(v)
		if o.Flag then Prism.Flags[o.Flag] = v end
		if fire and o.Callback then task.spawn(o.Callback, v) end
	end

	local dragging = false
	local function fromX(x) set(min + ((x - track.AbsolutePosition.X) / track.AbsoluteSize.X) * (max - min), true) end
	hit.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging = true fromX(i.Position.X)
		end
	end)
	bind(UserInputService.InputEnded, function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
	end)
	UserInputService.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			fromX(i.Position.X)
		end
	end)

	set(value, false)
	return { Set = set, Get = function() return value end }
end

--------------------------------------------------------------------
-- KEYBIND CHIP  (desktop only — no-op on touch)
--------------------------------------------------------------------
function Section:AddKeybind(o)
	if MOBILE then return { Get = function() return o.Default end } end   -- mobile has no keyboard

	local key = o.Default or Enum.KeyCode.RightShift
	local listening, scrambleTask = false, nil
	local r = self:_row(o.Text, o.Desc)

	local btn = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(132, 34), BackgroundColor3 = Theme.Well, AutoButtonColor = false,
		Text = string.upper(keyName(key)), TextSize = 11, Font = Theme.Mono, TextColor3 = Theme.Bone, Parent = r,
	})
	local bs = stroke(btn, Theme.Edge2)
	local bar = new("Frame", {
		Size = UDim2.new(0, 3, 1, 0), BackgroundColor3 = Theme.Accent,
		BackgroundTransparency = 1, BorderSizePixel = 0, Parent = btn,
	})

	btn.MouseButton1Click:Connect(function()
		listening = true
		bs.Color, bar.BackgroundTransparency = Theme.Accent, 0
		scrambleTask = task.spawn(function()
			while listening do
				btn.Text = KEYPOOL[math.random(#KEYPOOL)]
				task.wait(0.055)
			end
		end)
	end)

	bind(UserInputService.InputBegan, function(i, gpe)
		if not listening or i.UserInputType ~= Enum.UserInputType.Keyboard then return end
		listening = false
		if scrambleTask then task.cancel(scrambleTask) scrambleTask = nil end
		key = i.KeyCode
		btn.Text = string.upper(keyName(key))
		bs.Color, bar.BackgroundTransparency = Theme.Edge2, 1
		if o.Flag then Prism.Flags[o.Flag] = keyName(key) end
		Prism:Notify("KEYBIND SET", (o.Text or "bind") .. " → " .. string.upper(keyName(key)))
		if o.Changed then task.spawn(o.Changed, key) end
	end)

	return { Get = function() return key end }
end

--------------------------------------------------------------------
-- DROPDOWN / MULTI-SELECT
--------------------------------------------------------------------
local function optionRow(parent, text, selected, order)
	local b = new("TextButton", {
		Size = UDim2.new(1, 0, 0, MOBILE and 44 or 30), BackgroundColor3 = Theme.Accent,
		BackgroundTransparency = selected and 0.86 or 1, AutoButtonColor = false,
		Text = "     " .. string.upper(text), TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 10, Font = Theme.Mono,
		TextColor3 = selected and Theme.Bone or Theme.Bone2, LayoutOrder = order, Parent = parent,
	})
	b._edge = new("Frame", {
		Size = UDim2.new(0, 2, 1, 0), BackgroundColor3 = Theme.Accent,
		BackgroundTransparency = selected and 0 or 1, BorderSizePixel = 0, Parent = b,
	})
	return b
end

function Section:_ddButton(r, textFn)
	local anchor = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(150, CTRL_H), BackgroundTransparency = 1, Parent = r,
	})
	local btn = new("TextButton", {
		Size = UDim2.fromScale(1, 1), BackgroundColor3 = Theme.Well, AutoButtonColor = false,
		Text = "", Parent = anchor,
	})
	stroke(btn, Theme.Edge2)
	local txt = label(btn, textFn(), 10, Theme.Bone, Theme.Mono, true)
	txt.Position = UDim2.fromOffset(11, 0)
	txt.Size = UDim2.new(1, -32, 1, 0)
	txt.TextYAlignment = Enum.TextYAlignment.Center
	local chev = new("TextLabel", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(10, 10),
		BackgroundTransparency = 1, Text = "▾", TextSize = 10, Font = Theme.Mono, TextColor3 = Theme.Bone4, Parent = btn,
	})
	return anchor, btn, txt, chev
end

function Section:AddDropdown(o)
	local value = o.Default or o.Options[1]
	local r = self:_row(o.Text, o.Desc)
	local win = self.Window
	local menu
	local anchor, btn, txt, chev = self:_ddButton(r, function() return string.upper(value) end)

	local function close() if menu then menu:Destroy() menu = nil end tw(chev, FAST, { Rotation = 0 }) end

	btn.MouseButton1Click:Connect(function()
		if menu then close() return end
		if win._closePopups then win._closePopups() end
		tw(chev, FAST, { Rotation = 180 })

		local rowH = MOBILE and 44 or 30
		local H = #o.Options * rowH + 6
		menu = new("Frame", {
			Position = UDim2.new(0, 0, 1, 4), Size = UDim2.new(1, 0, 0, 0),
			BackgroundColor3 = Color3.fromHex("0C0C0E"), ClipsDescendants = true, ZIndex = 30, Parent = anchor,
		})
		stroke(menu, Theme.Edge2)
		pad(menu, 3)
		list(menu, 0)
		for i, name in ipairs(o.Options) do
			local ob = optionRow(menu, name, name == value, i)
			ob.MouseButton1Click:Connect(function()
				value = name
				txt.Text = string.upper(value)
				close()
				if o.Flag then Prism.Flags[o.Flag] = value end
				if o.Callback then task.spawn(o.Callback, value) end
			end)
		end
		tw(menu, SMOOTH, { Size = UDim2.new(1, 0, 0, H) })
		win._closePopups = close
	end)

	if o.Flag then Prism.Flags[o.Flag] = value end
	return { Get = function() return value end }
end

function Section:AddMultiDropdown(o)
	local selected = o.Default or {}
	local r = self:_row(o.Text, o.Desc)
	local win = self.Window
	local menu

	local function lab() return #selected > 0 and (#selected .. " SELECTED") or "NONE" end
	local anchor, btn, txt, chev = self:_ddButton(r, lab)
	local function has(v) for _, x in ipairs(selected) do if x == v then return true end end return false end
	local function close() if menu then menu:Destroy() menu = nil end tw(chev, FAST, { Rotation = 0 }) end

	btn.MouseButton1Click:Connect(function()
		if menu then close() return end
		if win._closePopups then win._closePopups() end
		tw(chev, FAST, { Rotation = 180 })

		local rowH = MOBILE and 44 or 30
		menu = new("Frame", {
			Position = UDim2.new(0, 0, 1, 4), Size = UDim2.new(1, 0, 0, 0),
			BackgroundColor3 = Color3.fromHex("0C0C0E"), ClipsDescendants = true, ZIndex = 30, Parent = anchor,
		})
		stroke(menu, Theme.Edge2)
		pad(menu, 3)
		list(menu, 0)
		for i, name in ipairs(o.Options) do
			local ob = optionRow(menu, "   " .. name, has(name), i)
			local box = new("Frame", {
				AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 10, 0.5, 0), Size = UDim2.fromOffset(10, 10),
				BackgroundColor3 = has(name) and Theme.Accent or Color3.fromHex("0A0A0B"), BorderSizePixel = 0, ZIndex = 2, Parent = ob,
			})
			stroke(box, has(name) and Theme.Accent or Color3.fromHex("33322B"))
			ob.MouseButton1Click:Connect(function()
				if has(name) then
					for j, x in ipairs(selected) do if x == name then table.remove(selected, j) break end end
				else
					table.insert(selected, name)
				end
				local on = has(name)
				box.BackgroundColor3 = on and Theme.Accent or Color3.fromHex("0A0A0B")
				box:FindFirstChildOfClass("UIStroke").Color = on and Theme.Accent or Color3.fromHex("33322B")
				ob.BackgroundTransparency = on and 0.86 or 1
				ob._edge.BackgroundTransparency = on and 0 or 1
				ob.TextColor3 = on and Theme.Bone or Theme.Bone2
				txt.Text = lab()
				if o.Flag then Prism.Flags[o.Flag] = selected end
				if o.Callback then task.spawn(o.Callback, selected) end
			end)
		end
		tw(menu, SMOOTH, { Size = UDim2.new(1, 0, 0, #o.Options * rowH + 6) })
		win._closePopups = close
	end)

	if o.Flag then Prism.Flags[o.Flag] = selected end
	return { Get = function() return selected end }
end

--------------------------------------------------------------------
-- COLOR SWATCHES
--------------------------------------------------------------------
function Section:AddColorPicker(o)
	local hexes = o.Swatches or { "C77DFF", "5B8CFF", "00E5A0", "FF4D6D", "FFB020", "E9E4D8" }
	local value = o.Default or Theme.Accent
	local r = self:_row(o.Text, o.Desc)
	local size = MOBILE and 36 or 22

	local tray = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(#hexes * (size + 5) + 3, size + 8),
		BackgroundColor3 = Theme.Well, Parent = r,
	})
	stroke(tray, Theme.Edge)
	pad(tray, 4)
	list(tray, 5, Enum.FillDirection.Horizontal, Enum.VerticalAlignment.Center)

	local btns = {}
	for i, hex in ipairs(hexes) do
		local c = Color3.fromHex(hex)
		local b = new("TextButton", {
			Size = UDim2.fromOffset(size, size), BackgroundColor3 = c, AutoButtonColor = false,
			Text = "", LayoutOrder = i, Parent = tray,
		})
		b._stroke = stroke(b, Color3.new(0, 0, 0), 0.4)
		b._glow = glow(b, c, 1, 10)
		btns[hex] = b
		b.MouseButton1Click:Connect(function()
			value = c
			for h, other in pairs(btns) do
				local on = h == hex
				other._stroke.Color = on and Theme.Bone or Color3.new(0, 0, 0)
				other._stroke.Transparency = on and 0 or 0.4
				other._stroke.Thickness = on and 2 or 1
				other._glow.ImageTransparency = on and 0.35 or 1
				tw(other, SNAP, { Size = UDim2.fromOffset(size, size) })
			end
			if o.Flag then Prism.Flags[o.Flag] = hex end
			if o.Callback then task.spawn(o.Callback, c) end
		end)
	end
	return { Get = function() return value end }
end

--------------------------------------------------------------------
-- TEXT INPUT  (tag + recessed well)
--------------------------------------------------------------------
function Section:AddInput(o)
	local r = self:_row(nil, nil, MOBILE and 62 or 52)
	local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = r })
	list(row, 10, Enum.FillDirection.Horizontal, Enum.VerticalAlignment.Center)

	local tag = label(row, string.upper(o.Tag or o.Text or "TEXT"), 9, Theme.Bone4, Theme.Mono, true)
	tag.Size = UDim2.fromOffset(42, 14)
	tag.LayoutOrder = 1

	local box = new("TextBox", {
		Size = UDim2.new(1, -52, 0, CTRL_H), BackgroundColor3 = Theme.Well,
		Text = o.Default or "", PlaceholderText = o.Placeholder or "",
		PlaceholderColor3 = Color3.fromHex("4E4B45"), TextSize = 11, Font = Theme.Mono,
		TextColor3 = Theme.Bone, TextXAlignment = Enum.TextXAlignment.Left,
		ClearTextOnFocus = false, LayoutOrder = 2, Parent = row,
	})
	stroke(box, Theme.Edge2)
	pad(box, 0, 11)
	new("Frame", { Size = UDim2.new(0, 2, 1, 0), BackgroundColor3 = Theme.Accent, BackgroundTransparency = 0.45, BorderSizePixel = 0, Parent = box })

	box.Focused:Connect(function() tw(box, FAST, { BackgroundColor3 = Color3.fromHex("121215") }) end)
	box.FocusLost:Connect(function()
		tw(box, FAST, { BackgroundColor3 = Theme.Well })
		if o.Flag then Prism.Flags[o.Flag] = box.Text end
		if o.Callback then task.spawn(o.Callback, box.Text) end
	end)

	if o.Flag then Prism.Flags[o.Flag] = box.Text end
	return { Get = function() return box.Text end, Set = function(t) box.Text = t end }
end

--------------------------------------------------------------------
-- BUTTONS  (single, or an N-across grid row)
--------------------------------------------------------------------
local function styleButton(b, style)
	if style == "Primary" then
		b.BackgroundColor3, b.BackgroundTransparency, b.TextColor3 = Theme.Accent, 0.82, Theme.Bone
		stroke(b, Theme.Accent, 0.45)
		glow(b, Theme.Accent, 0.72, 12)
	elseif style == "Danger" then
		b.BackgroundColor3, b.BackgroundTransparency, b.TextColor3 = Theme.Danger, 0.9, Theme.Danger
		stroke(b, Theme.Danger, 0.68)
	else
		b.BackgroundTransparency, b.TextColor3 = 1, Theme.Bone2
		stroke(b, Theme.Edge2)
	end
end

function Section:AddButtonRow(items)
	local h = MOBILE and 44 or 30
	local r = self:_row(nil, nil, h + 20)
	local row = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 10), Size = UDim2.new(1, 0, 0, h), Parent = r })
	list(row, 6, Enum.FillDirection.Horizontal)
	local n = #items
	for i, it in ipairs(items) do
		local b = new("TextButton", {
			Size = UDim2.new(1 / n, -6 + 6 / n, 1, 0), AutoButtonColor = false,
			Text = string.upper(it.Text), TextSize = 10, Font = Theme.Mono, LayoutOrder = i, Parent = row,
		})
		styleButton(b, it.Style)
		local base = b.BackgroundTransparency
		b.MouseEnter:Connect(function() tw(b, FAST, { BackgroundTransparency = math.max(0, base - 0.08) }) end)
		b.MouseLeave:Connect(function() tw(b, FAST, { BackgroundTransparency = base }) end)
		b.MouseButton1Click:Connect(function() if it.Callback then task.spawn(it.Callback) end end)
	end
end

function Section:AddButton(o)
	local h = o.Tall and (MOBILE and 48 or 38) or (MOBILE and 44 or 30)
	local r = self:_row(nil, nil, h + 22)
	local b = new("TextButton", {
		Position = UDim2.fromOffset(0, 11), Size = UDim2.new(1, 0, 0, h), AutoButtonColor = false,
		Text = string.upper(o.Text), TextSize = o.Tall and 11 or 10, Font = Theme.Mono, Parent = r,
	})
	styleButton(b, o.Style)
	local base = b.BackgroundTransparency
	b.MouseEnter:Connect(function() tw(b, FAST, { BackgroundTransparency = math.max(0, base - 0.08) }) end)
	b.MouseLeave:Connect(function() tw(b, FAST, { BackgroundTransparency = base }) end)
	b.MouseButton1Click:Connect(function() if o.Callback then task.spawn(o.Callback) end end)
	return b
end

--------------------------------------------------------------------
-- CONFIG LIST  (click a row to load it into the name box)
--------------------------------------------------------------------
function Section:AddConfigList(o)
	local folder   = o.Folder or "prism"
	local rowH     = MOBILE and 44 or 28
	local maxH     = MOBILE and 152 or 108
	local rows, selected, loaded = {}, nil, o.Loaded

	local r = self:_row(nil, nil, maxH + 24)
	local box = new("ScrollingFrame", {
		Position = UDim2.fromOffset(0, 12), Size = UDim2.new(1, 0, 0, maxH),
		BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.58, BorderSizePixel = 0,
		ScrollBarThickness = 3, ScrollBarImageColor3 = Theme.Edge2, ScrollBarImageTransparency = 0.3,
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = r,
	})
	stroke(box, Color3.fromHex("22211C"))
	list(box, 0)

	local empty = new("TextLabel", {
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 52),
		Text = "NO CONFIGS ON DISK — NAME ONE BELOW AND SAVE",
		TextSize = 9, Font = Theme.Mono, TextColor3 = Theme.Bone3, TextWrapped = true, Parent = box,
	})

	local api = {}

	function api.Select(name)
		selected = name
		for n, row in pairs(rows) do
			local on = n == name
			tw(row.Button, FAST, { BackgroundTransparency = on and 0.87 or 1 })
			row.Button.TextColor3 = on and Theme.Bone or Theme.Bone2
			row.Edge.BackgroundTransparency = on and 0 or 1
		end
		if o.OnSelect then task.spawn(o.OnSelect, name) end
	end

	function api.SetLoaded(name)
		loaded = name
		for n, row in pairs(rows) do
			row.Dot.BackgroundColor3 = (n == loaded) and Theme.Accent or Color3.fromHex("2E2D26")
			row.Tag.Visible = n == loaded
		end
	end

	function api.List()
		if o.List then return o.List() end
		local names = {}
		if listfiles and isfolder and isfolder(folder) then
			for _, f in ipairs(listfiles(folder)) do
				local n = f:match("([^/\\]+)%.json$")
				if n then table.insert(names, n) end
			end
		end
		return names
	end

	function api.Refresh()
		for _, row in pairs(rows) do row.Button:Destroy() end
		rows = {}
		local names = api.List()
		empty.Visible = #names == 0
		if o.OnCount then task.spawn(o.OnCount, #names) end

		for i, name in ipairs(names) do
			local b = new("TextButton", {
				Size = UDim2.new(1, 0, 0, rowH), BackgroundColor3 = Theme.Accent, BackgroundTransparency = 1,
				AutoButtonColor = false, Text = "      " .. name, TextXAlignment = Enum.TextXAlignment.Left,
				TextSize = 10, Font = Theme.Mono, TextColor3 = Theme.Bone2, LayoutOrder = i, Parent = box,
			})
			local edge = new("Frame", { Size = UDim2.new(0, 2, 1, 0), BackgroundColor3 = Theme.Accent, BackgroundTransparency = 1, BorderSizePixel = 0, Parent = b })
			local dot = new("Frame", {
				AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 10, 0.5, 0), Size = UDim2.fromOffset(4, 4),
				BackgroundColor3 = (name == loaded) and Theme.Accent or Color3.fromHex("2E2D26"), BorderSizePixel = 0, Parent = b,
			})
			local tag = new("TextLabel", {
				AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(50, 12),
				BackgroundTransparency = 1, Text = "LOADED", TextXAlignment = Enum.TextXAlignment.Right,
				TextSize = 8, Font = Theme.Mono, TextColor3 = Theme.Accent, Visible = name == loaded, Parent = b,
			})
			rows[name] = { Button = b, Edge = edge, Dot = dot, Tag = tag }
			b.MouseButton1Click:Connect(function() api.Select(name) end)
		end
		if selected then api.Select(selected) end
	end

	api.Refresh()
	return api
end

--==============================================================
-- TAB
--==============================================================
local Tab = {}
Tab.__index = Tab

function Tab:AddSection(title)
	local strip = new("Frame", {
		BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.6,
		Size = UDim2.new(1, 0, 0, 28), LayoutOrder = self._order, Parent = self.Page,
	})
	self._order += 1
	new("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Theme.Edge, BorderSizePixel = 0, Parent = strip })
	new("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Theme.Edge, BorderSizePixel = 0, Parent = strip })
	pad(strip, 0, 22)

	local tick = new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(2, 9),
		BackgroundColor3 = Theme.Accent, BorderSizePixel = 0, Parent = strip,
	})
	glow(tick, Theme.Accent, 0.5, 6)
	local t = label(strip, string.upper(title), 9, Theme.Bone2, Theme.Mono, true)
	t.Position = UDim2.fromOffset(11, 0)
	t.Size = UDim2.new(1, -60, 1, 0)
	t.TextYAlignment = Enum.TextYAlignment.Center
	local count = new("TextLabel", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(30, 12),
		BackgroundTransparency = 1, Text = "", TextXAlignment = Enum.TextXAlignment.Right,
		TextSize = 9, Font = Theme.Mono, TextColor3 = Color3.fromHex("3E3C37"), Parent = strip,
	})

	local sec = setmetatable({
		Frame = self.Page, Window = self.Window, Tab = self, _order = self._order, _count = count,
	}, Section)

	-- keep the section's rows ordered after the strip
	sec._order = self._order
	local mt = getmetatable(sec)
	sec.SetCount = function(_, n) count.Text = string.format("%02d", n) end

	-- rows added to this section push the tab's order forward too
	local origRow = Section._row
	sec._row = function(s, ...)
		local r = origRow(s, ...)
		self._order = s._order
		return r
	end
	return sec
end

--==============================================================
-- WINDOW
--==============================================================
local function guiParent()
	if gethui then
		local ok, h = pcall(gethui)
		if ok and typeof(h) == "Instance" then return h end
	end
	local ok = pcall(function() return game:GetService("CoreGui").Name end)
	if ok and not RunService:IsStudio() then return game:GetService("CoreGui") end
	return Players.LocalPlayer:WaitForChild("PlayerGui")
end

function Prism:CreateWindow(o)
	o = o or {}

	-- A loadstring gets re-run constantly. Unload whatever PRISM is already live
	-- before building a second one, or the user ends up with stacked windows and
	-- two sets of keybinds fighting over the same toggle key.
	local G = genv()
	if type(G.__PRISM_UNLOAD) == "function" then pcall(G.__PRISM_UNLOAD) end

	local self = setmetatable({}, Prism)
	self.Tabs, self.Visible = {}, true
	self.ToggleKey = o.Keybind  or Enum.KeyCode.RightShift
	self.PanicKey  = o.PanicKey or Enum.KeyCode.End

	local gui = new("ScreenGui", {
		Name = o.Name or "PRISM", ResetOnSpawn = false, IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 9999, Parent = guiParent(),
	})
	self.Gui = gui

	-- Belt and braces: a PRISM built before the unload hook existed leaves its
	-- ScreenGui behind, and __PRISM_UNLOAD can't reach it. Sweep by name.
	for _, old in ipairs(gui.Parent:GetChildren()) do
		if old ~= gui and old:IsA("ScreenGui") and old.Name == gui.Name then
			pcall(function() old:Destroy() end)
		end
	end
	self.Blur = new("BlurEffect", { Size = 0, Enabled = false, Parent = Lighting })

	local SIZE = MOBILE and UDim2.fromOffset(400, 620) or UDim2.fromOffset(800, 560)

	----------------------------------------------------------------
	-- chassis
	----------------------------------------------------------------
	local win = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = SIZE,
		BackgroundColor3 = Theme.Chassis, BackgroundTransparency = 0.12,
		ClipsDescendants = true, Parent = gui,
	})
	corner(win, Theme.Radius)
	stroke(win, Theme.Edge)
	local chassisGlow = glow(win, Theme.Accent, 0.62, 34)
	self.Window = win
	self.Scale = new("UIScale", { Scale = 1, Parent = win })

	-- brushed vertical grain + top sheen
	new("ImageLabel", {
		BackgroundTransparency = 1, Image = "rbxassetid://2454009026", ImageTransparency = 0.97,
		ScaleType = Enum.ScaleType.Tile, TileSize = UDim2.fromOffset(3, 200),
		Size = UDim2.fromScale(1, 1), ZIndex = 1, Parent = win,
	})
	new("Frame", {
		Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Theme.Bone, BackgroundTransparency = 0.92,
		BorderSizePixel = 0, ZIndex = 13, Parent = win,
	})
	-- scanlines
	new("ImageLabel", {
		BackgroundTransparency = 1, Image = "rbxassetid://2454009026", ImageTransparency = 0.9,
		ImageColor3 = Color3.new(0, 0, 0), ScaleType = Enum.ScaleType.Tile, TileSize = UDim2.fromOffset(200, 3),
		Size = UDim2.fromScale(1, 1), ZIndex = 12, Parent = win,
	})
	-- corner screws
	for _, p in ipairs({ { 9, 9, 0, 0 }, { -9, 9, 1, 0 }, { 9, -9, 0, 1 }, { -9, -9, 1, 1 } }) do
		local s = new("Frame", {
			AnchorPoint = Vector2.new(p[3], p[4]), Position = UDim2.new(p[3], p[1], p[4], p[2]),
			Size = UDim2.fromOffset(6, 6), BackgroundColor3 = Color3.fromHex("2A2822"), ZIndex = 14, Parent = win,
		})
		corner(s, 3)
		stroke(s, Color3.fromHex("4B483F"), 0.4)
	end

	-- boot: CRT hairline expanding to full height
	win.Size = UDim2.fromOffset(SIZE.X.Offset, 2)
	tw(win, TweenInfo.new(0.55, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Size = SIZE })

	----------------------------------------------------------------
	-- header: wordmark + close/minimize
	----------------------------------------------------------------
	local header = new("Frame", { Size = UDim2.new(1, 0, 0, MOBILE and 76 or 64), BackgroundTransparency = 1, ZIndex = 4, Parent = win })
	new("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Theme.Edge, BorderSizePixel = 0, Parent = header })
	pad(header, 0, 22)

	local wordmark = new("TextLabel", {
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.new(1, -70, 0, 26),
		BackgroundTransparency = 1, Text = o.Name or "PRISM", TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 22, Font = Theme.Bold, TextColor3 = Theme.Bone, Parent = header,
	})

	local hb = MOBILE and 44 or 28
	local hideBtn = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(hb, hb),
		BackgroundColor3 = Theme.Well, AutoButtonColor = false,
		Text = MOBILE and "–" or "✕", TextSize = MOBILE and 18 or 11, Font = Theme.Mono,
		TextColor3 = MOBILE and Theme.Bone2 or Theme.Bone4, Parent = header,
	})
	stroke(hideBtn, Theme.Edge2)

	----------------------------------------------------------------
	-- tab strip + sliding underline
	----------------------------------------------------------------
	local strip = new("Frame", {
		Position = UDim2.fromOffset(0, MOBILE and 76 or 64), Size = UDim2.new(1, 0, 0, MOBILE and 48 or 40),
		BackgroundColor3 = Color3.fromHex("0C0C0E"), ZIndex = 4, Parent = win,
	})
	new("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Theme.Edge, BorderSizePixel = 0, Parent = strip })
	local tabRow = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = strip })
	pad(tabRow, 0, 22)
	list(tabRow, 22, Enum.FillDirection.Horizontal, Enum.VerticalAlignment.Center)
	local underline = new("Frame", {
		AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 22, 1, 0), Size = UDim2.fromOffset(0, 2),
		BackgroundColor3 = Theme.Accent, BorderSizePixel = 0, ZIndex = 5, Parent = strip,
	})
	glow(underline, Theme.Accent, 0.4, 8)

	----------------------------------------------------------------
	-- scrolling body
	----------------------------------------------------------------
	local bodyTop = (MOBILE and 76 or 64) + (MOBILE and 48 or 40)
	local body = new("Frame", {
		Position = UDim2.fromOffset(0, bodyTop), Size = UDim2.new(1, 0, 1, -bodyTop),
		BackgroundTransparency = 1, ClipsDescendants = true, ZIndex = 4, Parent = win,
	})
	self._body = body

	----------------------------------------------------------------
	-- notifications + mobile floating icon
	----------------------------------------------------------------
	self._notif = new("Frame", {
		AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -26, 1, -26),
		Size = UDim2.fromOffset(286, 320), BackgroundTransparency = 1, Parent = gui,
	})
	list(self._notif, 7, nil, Enum.VerticalAlignment.Bottom)

	local icon = new("TextButton", {
		AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -28), Size = UDim2.fromOffset(56, 56),
		BackgroundColor3 = Theme.Chassis, AutoButtonColor = false, Visible = false,
		Text = "P", TextSize = 24, Font = Theme.Bold, TextColor3 = Theme.Bone, Parent = gui,
	})
	stroke(icon, Theme.Accent, 0.55)
	glow(icon, Theme.Accent, 0.55, 22)
	local iconLed = new("Frame", {
		Position = UDim2.fromOffset(6, 6), Size = UDim2.fromOffset(4, 4),
		BackgroundColor3 = Theme.Accent, BorderSizePixel = 0, Parent = icon,
	})
	task.spawn(function()                              -- pulsing LED
		while iconLed.Parent do
			tw(iconLed, TweenInfo.new(1.3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { BackgroundTransparency = 0.75 })
			task.wait(1.3)
			tw(iconLed, TweenInfo.new(1.3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { BackgroundTransparency = 0 })
			task.wait(1.3)
		end
	end)

	draggable(win, header)
	if MOBILE then draggable(icon, icon) end

	----------------------------------------------------------------
	-- tabs
	----------------------------------------------------------------
	function self:AddTab(name)
		local index = #self.Tabs + 1
		local page = new("ScrollingFrame", {
			Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0,
			ScrollBarThickness = 3, ScrollBarImageColor3 = Theme.Edge2, ScrollBarImageTransparency = 0.3,
			CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
			Visible = index == 1, ClipsDescendants = true, Parent = body,
		})
		list(page, 0)

		local btn = new("TextButton", {
			Size = UDim2.fromOffset(0, MOBILE and 48 or 40), AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1, AutoButtonColor = false, Text = string.upper(name),
			TextSize = 10, Font = Theme.Mono, TextColor3 = index == 1 and Theme.Bone or Theme.Bone4,
			LayoutOrder = index, Parent = tabRow,
		})

		local tab = setmetatable({ Page = page, Button = btn, Window = self, Name = name, _order = 1 }, Tab)
		table.insert(self.Tabs, tab)
		btn.MouseButton1Click:Connect(function() self:SelectTab(index) end)
		if index == 1 then task.defer(function() self:SelectTab(1) end) end
		return tab
	end

	function self:SelectTab(i)
		for n, t in ipairs(self.Tabs) do
			local on = n == i
			t.Page.Visible = on
			tw(t.Button, FAST, { TextColor3 = on and Theme.Bone or Theme.Bone4 })
			if on then
				-- underline slides with overshoot, matching the CSS
				tw(underline, SLIDE, {
					Position = UDim2.new(0, t.Button.AbsolutePosition.X - strip.AbsolutePosition.X, 1, 0),
					Size = UDim2.fromOffset(t.Button.AbsoluteSize.X, 2),
				})
				-- shutter the page in
				t.Page.Position = UDim2.fromOffset(0, 0)
				local clip = t.Page
				clip.CanvasPosition = Vector2.new(0, 0)
			end
		end
		if self._closePopups then self._closePopups() self._closePopups = nil end
	end

	----------------------------------------------------------------
	-- show / hide
	----------------------------------------------------------------
	function self:Toggle(force)
		local show = force
		if show == nil then show = not self.Visible end
		self.Visible = show
		if self._closePopups then self._closePopups() self._closePopups = nil end

		if show then
			win.Visible, icon.Visible = true, false
			win.Size = UDim2.fromOffset(SIZE.X.Offset, 2)
			tw(win, SMOOTH, { Size = SIZE, BackgroundTransparency = 0.12 })
		else
			tw(win, FAST, { Size = UDim2.fromOffset(SIZE.X.Offset, 2), BackgroundTransparency = 1 })
			task.delay(0.15, function()
				if self.Visible then return end
				win.Visible = false
				if MOBILE then
					icon.Visible = true                         -- tap-to-reopen icon
					icon.Size = UDim2.fromOffset(0, 0)
					tw(icon, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = UDim2.fromOffset(56, 56) })
				else
					-- PC: a notification is enough, and it names the live keybind
					Prism:Notify("MENU HIDDEN", "press " .. string.upper(keyName(self.ToggleKey)) .. " to open it again")
				end
			end)
		end
	end

	hideBtn.MouseButton1Click:Connect(function() self:Toggle(false) end)
	icon.MouseButton1Click:Connect(function() self:Toggle(true) end)

	function self:SetAccent(c)
		Theme.Accent = c
		chassisGlow.ImageColor3 = c
		underline.BackgroundColor3 = c
		-- controls read Theme.Accent on their next paint; new rows pick it up immediately
	end

	function self:Destroy()
		unbindAll()
		if self.Blur then pcall(function() self.Blur:Destroy() end) end
		pcall(function() gui:Destroy() end)
		local g = genv()
		if g.__PRISM_UNLOAD == self._unload then g.__PRISM_UNLOAD = nil end
	end

	-- published so the *next* run of the script can find and unload this one
	self._unload = function() self:Destroy() end
	G.__PRISM_UNLOAD = self._unload

	----------------------------------------------------------------
	-- keys (desktop only — mobile uses the header button + icon)
	----------------------------------------------------------------
	if not MOBILE then
		bind(UserInputService.InputBegan, function(i, gpe)
			if gpe or i.UserInputType ~= Enum.UserInputType.Keyboard then return end
			if i.KeyCode == self.PanicKey then
				Prism:Notify("PANIC", "ScreenGui:Destroy()")
				task.wait(0.05)
				self:Destroy()
			elseif i.KeyCode == self.ToggleKey then
				self:Toggle()
			end
		end)
	end

	return self
end

--==============================================================
-- EXAMPLE — reproduces the mockup exactly. Delete or move to your own script.
--==============================================================
--[[
local Window = Prism:CreateWindow({ Name = "PRISM" })

---------------------------------------------------------------- CONFIG & THEMES
local Config = Window:AddTab("Config & Themes")

local Look = Config:AddSection("Appearance")
Look:SetCount(5)
Look:AddColorPicker({ Text = "Accent color", Desc = "signal / active state", Flag = "accent",
	Callback = function(c) Window:SetAccent(c) end })
Look:AddDropdown({ Text = "Preset", Desc = "full palette swap", Flag = "preset",
	Options = { "Amethyst", "Midnight", "Void", "Ember" }, Default = "Amethyst" })
Look:AddSlider({ Text = "Backdrop blur", Desc = "behind the chassis", Flag = "blur",
	Min = 0, Max = 40, Default = 26, Places = 2, Suffix = "PX",
	Callback = function(v) Window.Blur.Enabled = v > 0 Window.Blur.Size = v end })
Look:AddSlider({ Text = "Corner radius", Desc = "chassis edge", Flag = "radius",
	Min = 0, Max = 24, Default = 6, Places = 2, Suffix = "PX",
	Callback = function(v) Window.Window:FindFirstChildOfClass("UICorner").CornerRadius = UDim.new(0, v) end })
Look:AddToggle({ Text = "Glow effects", Desc = "bloom behind the panel", Default = true, Flag = "glow" })

local Saves = Config:AddSection("Configs")
local NameBox, ConfigList

ConfigList = Saves:AddConfigList({
	Folder = "prism", Loaded = "default",
	OnSelect = function(name) Prism.Flags.cfgName = name NameBox.Set(name) end,
	OnCount  = function(n) Saves:SetCount(n) end,
})
NameBox = Saves:AddInput({ Tag = "NAME", Placeholder = "my-config", Default = "default", Flag = "cfgName" })

Saves:AddButtonRow({
	{ Text = "New", Callback = function()
		NameBox.Set("") Prism.Flags.cfgName = ""
		Prism:Notify("NEW CONFIG", "name it, then save")
	end },
	{ Text = "Load", Callback = function()
		local n = NameBox.Get()
		if isfile and isfile("prism/" .. n .. ".json") then
			Prism.Flags = HttpService:JSONDecode(readfile("prism/" .. n .. ".json"))
			ConfigList.SetLoaded(n)
			Prism:Notify("CONFIG LOADED", n .. ".json applied")
		else
			Prism:Notify("NOT FOUND", n .. ".json")
		end
	end },
	{ Text = "Save", Style = "Primary", Callback = function()
		local n = NameBox.Get()
		if n == "" then return Prism:Notify("NAME REQUIRED", "type a config name first") end
		if makefolder and not (isfolder and isfolder("prism")) then makefolder("prism") end
		writefile("prism/" .. n .. ".json", HttpService:JSONEncode(Prism.Flags))
		ConfigList.Refresh() ConfigList.SetLoaded(n)
		Prism:Notify("CONFIG SAVED", n .. ".json written")
	end },
	{ Text = "Delete", Style = "Danger", Callback = function()
		local n = NameBox.Get()
		if delfile then delfile("prism/" .. n .. ".json") end
		NameBox.Set("") ConfigList.Refresh()
		Prism:Notify("CONFIG DELETED", n .. ".json removed")
	end },
})
Saves:AddToggle({ Text = "Autoload on join", Desc = "apply this config at spawn", Default = true, Flag = "autoload" })

---------------------------------------------------------------- SETTINGS
local Settings = Window:AddTab("Settings")

local Iface = Settings:AddSection("Interface")
Iface:SetCount(Prism.Mobile and 2 or 4)
-- these two are skipped automatically on touch devices
Iface:AddKeybind({ Text = "Toggle menu", Desc = "show / hide the window",
	Default = Enum.KeyCode.RightShift, Changed = function(k) Window.ToggleKey = k end })
Iface:AddKeybind({ Text = "Panic hide", Desc = "destroys the gui instantly",
	Default = Enum.KeyCode.End, Changed = function(k) Window.PanicKey = k end })
Iface:AddSlider({ Text = "UI scale", Desc = "whole chassis", Flag = "scale",
	Min = 75, Max = 125, Step = 5, Default = 100, Places = 3, Suffix = "%",
	Callback = function(v) Window.Scale.Scale = v / 100 end })
Iface:AddDropdown({ Text = "Notifications", Desc = "corner for tickers",
	Options = { "Bottom Right", "Bottom Left", "Top Right" }, Default = "Bottom Right" })

local Perf = Settings:AddSection("Performance")
Perf:SetCount(5)
Perf:AddToggle({ Text = "Reduce animations", Desc = "cuts every tween to instant", Flag = "reduce" })
Perf:AddToggle({ Text = "Low-end mode", Desc = "drops blur and bloom", Flag = "lowend",
	Callback = function(v) Window.Window.BackgroundTransparency = v and 0 or 0.12 end })
Perf:AddMultiDropdown({ Text = "Auto-disable in", Desc = "game categories to skip",
	Options = { "Obbies", "Simulators", "Shooters", "Roleplay" }, Default = {} })
Perf:AddInput({ Tag = "HOOK", Placeholder = "https://discord.com/api/webhooks/…", Flag = "hook" })
Perf:AddButton({ Text = "Unload PRISM", Style = "Danger", Tall = true, Callback = function()
	Prism:Notify("UNLOADED", "ScreenGui:Destroy()")
	task.wait(0.3)
	Window:Destroy()
end })

Prism:Notify("PRISM ATTACHED", "injected in 0.42s · 2 modules")
]]

return Prism
