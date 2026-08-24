--[[
	PRISM UI  ·  v2 (carbon + bone)
	Roblox port of "Prism Script Menu v2.dc.html" — same palette, sizes, easing and behavior.

	USAGE
		local Prism  = loadstring(game:HttpGet("https://cdn.jsdelivr.net/gh/S2kh/prism@v1.3.3/PrismUI.lua"))()
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
		· tab underline that slides with overshoot; pages shutter in from the top
		· config list -> click a row to load it into the name box
		· header sheen sweep, mouse-following specular, glow / low-end / notification-corner hooks

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

	-- filled in below: Enum.Font carries no weight, FontFace does
	Display  = nil, Bold = nil, Mono = nil, MonoSemi = nil,

	GlowAsset = "rbxassetid://6014261993",
}

-- Saira -> Titillium Web, Azeret Mono -> Roboto Mono: the nearest built-ins.
-- The mockup leans on weights (500/600/700) that Enum.Font can't express, so
-- these are FontFace values. Roblox has no letter-spacing at all, so the
-- mockup's .1em-.24em tracking on mono labels cannot be reproduced.
local function face(enumFont, weight)
	local base = Font.fromEnum(enumFont)
	local ok, f = pcall(Font.new, base.Family, weight, Enum.FontStyle.Normal)
	return ok and f or base
end
Theme.Display  = face(Enum.Font.TitilliumWeb, Enum.FontWeight.Medium)    -- rowLabel 500
Theme.Bold     = face(Enum.Font.TitilliumWeb, Enum.FontWeight.Bold)      -- wordmark 700
Theme.Mono     = face(Enum.Font.RobotoMono,   Enum.FontWeight.Medium)    -- mono 500
Theme.MonoSemi = face(Enum.Font.RobotoMono,   Enum.FontWeight.SemiBold)  -- ticker title 600


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
Prism.Version = "1.3.3"  -- bump every release; the tag in your loadstring URL should match this
Prism.Theme   = Theme
Prism.Mobile  = MOBILE
Prism.Flags   = {}     -- every control with a Flag writes here; this is what a config saves
Prism.Binds   = {}     -- Flag -> { Key = "F", Mode = "Toggle" } for toggles with a bound key
Prism.Reduced = false  -- true = every tween is instant (the mockup's "Reduce animations")
Prism.Folder  = "prism"

-- Flag -> control API, so LoadConfig can push saved values back into the controls
local CONTROLS = {}
local function register(flag, api)
	if flag then CONTROLS[flag] = api end
end

--==============================================================
-- CONFIG FILES  (prism/<name>.json = { Flags = {...}, Binds = {...} };
--                prism/settings.json = { Autoload = "<name>" })
--==============================================================
local function hasFS() return writefile and readfile and isfile end
local function ensureFolder()
	if makefolder and not (isfolder and isfolder(Prism.Folder)) then pcall(makefolder, Prism.Folder) end
end
local function cfgPath(name) return Prism.Folder .. "/" .. name .. ".json" end
local SETTINGS_FILE = "settings"

-- executors without listfiles still see every config saved this session (KNOWN),
-- and settings.json remembers names across sessions so the list survives a rejoin
local KNOWN = {}
function Prism:ListConfigs()
	local seen, names = {}, {}
	local function add(n)
		if n and n ~= SETTINGS_FILE and not seen[n] and isfile and isfile(cfgPath(n)) then
			seen[n] = true table.insert(names, n)
		end
	end
	if listfiles and isfolder and isfolder(self.Folder) then
		for _, f in ipairs(listfiles(self.Folder)) do add(f:match("([^/\\]+)%.json$")) end
	end
	for n in pairs(KNOWN) do add(n) end
	for _, n in ipairs(self:GetSettings().Known or {}) do add(n) end
	table.sort(names)
	return names
end

function Prism:SaveConfig(name)
	name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if name == "" then return false, "name required" end
	if not hasFS() then return false, "this executor can't write files" end
	ensureFolder()
	local ok, err = pcall(writefile, cfgPath(name),
		HttpService:JSONEncode({ Flags = self.Flags, Binds = self.Binds }))
	if not ok then return false, tostring(err) end
	KNOWN[name] = true
	local known = self:GetSettings().Known or {}
	if not table.find(known, name) then table.insert(known, name) self:SetSetting("Known", known) end
	return true
end

-- pushes every saved flag back into its control (firing callbacks) and re-applies binds
function Prism:LoadConfig(name)
	name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if name == "" or not hasFS() or not isfile(cfgPath(name)) then return false, "not found" end
	local ok, data = pcall(function() return HttpService:JSONDecode(readfile(cfgPath(name))) end)
	if not ok or type(data) ~= "table" then return false, "corrupt file" end
	local flags = type(data.Flags) == "table" and data.Flags or data   -- accept a bare Flags dump too
	local binds = type(data.Binds) == "table" and data.Binds or {}
	for flag, v in pairs(flags) do
		local c = CONTROLS[flag]
		if c and c.Set then pcall(c.Set, v, true) else self.Flags[flag] = v end
	end
	for flag, b in pairs(binds) do
		local c = CONTROLS[flag]
		if c and c.SetBind and type(b) == "table" then pcall(c.SetBind, b.Key, b.Mode) end
	end
	self.Loaded = name
	return true
end

function Prism:DeleteConfig(name)
	if not (delfile and isfile) or not name or not isfile(cfgPath(name)) then return false end
	pcall(delfile, cfgPath(name))
	if self.Loaded == name then self.Loaded = nil end
	return true
end

function Prism:GetSettings()
	if not hasFS() or not isfile(cfgPath(SETTINGS_FILE)) then return {} end
	local ok, t = pcall(function() return HttpService:JSONDecode(readfile(cfgPath(SETTINGS_FILE))) end)
	return (ok and type(t) == "table") and t or {}
end

function Prism:SetSetting(key, value)
	if not hasFS() then return end
	local t = self:GetSettings()
	t[key] = value
	ensureFolder()
	pcall(writefile, cfgPath(SETTINGS_FILE), HttpService:JSONEncode(t))
end

--==============================================================
-- CONNECTION REGISTRY
-- Signals on UserInputService outlive the ScreenGui they were made for. When the
-- script is re-run from a loadstring the old chunk is still connected and starts
-- throwing on destroyed instances, so every global connection is parked here and
-- Window:Destroy() tears the whole set down. Named conn, not bind: AddToggle
-- has a local `bind` table for its keybind that would shadow it.
--==============================================================
local CONNS = {}
local function conn(signal, fn)
	local c = signal:Connect(fn)
	CONNS[#CONNS + 1] = c
	return c
end
local function dropConns()
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
-- Any property set to Theme.Accent at build time is tagged (attribute "PrismAccent"
-- = comma list of property names) so Window:SetAccent can repaint the whole
-- chassis in one sweep. Conditional paints (toggle slots, config dots) register a
-- closure in PAINTERS instead.
local PAINTERS = {}
local function new(class, props, children)
	local i = Instance.new(class)
	local tags
	for k, v in pairs(props or {}) do
		if k ~= "Parent" then
			i[k] = v
			if typeof(v) == "Color3" and v == Theme.Accent then tags = tags and (tags .. "," .. k) or k end
		end
	end
	if tags then i:SetAttribute("PrismAccent", tags) end
	for _, c in ipairs(children or {}) do c.Parent = i end
	if props and props.Parent then i.Parent = props.Parent end
	return i
end
local function untag(i) i:SetAttribute("PrismAccent", nil) return i end

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

-- Prism.Reduced = true is the mockup's "reduce animations": every tween lands instantly
local function tw(inst, info, goal)
	if Prism.Reduced then
		for k, v in pairs(goal) do inst[k] = v end
		return nil
	end
	local t = TweenService:Create(inst, info, goal) t:Play() return t
end

-- vertical gradient; the mockup's linear-gradient(180deg, a, b)
local function gradient(parent, top, bottom, rotation)
	return new("UIGradient", {
		Color = ColorSequence.new(top, bottom), Rotation = rotation or 90, Parent = parent,
	})
end

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

-- the wordmark is the one place tracking is reproducible: at 22px a real
-- space lands close to the mockup's .3em, and it isn't monospaced
local function spaced(t) return (tostring(t):gsub("(.)", "%1 "):gsub(" $", "")) end

local function label(parent, text, size, color, font, mono)
	local l = new("TextLabel", {
		BackgroundTransparency = 1, Text = text, TextSize = size,
		TextColor3 = color or Theme.Bone, FontFace = font or Theme.Display,
		TextXAlignment = Enum.TextXAlignment.Left, RichText = true,
		Size = UDim2.new(1, 0, 0, math.floor(size * 1.35)), Parent = parent,
	})
	if mono then l.FontFace = Theme.Mono end
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

-- Roboto Mono has no ✕ / ▾ glyphs, so the close mark and dropdown chevrons are
-- drawn from 1px lines instead of text.
local function glyphX(parent, size, color)
	local holder = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(size, size), BackgroundTransparency = 1, ZIndex = 2, Parent = parent,
	})
	for _, rot in ipairs({ 45, -45 }) do
		new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(0, math.floor(size * 1.3), 0, 1), Rotation = rot,
			BackgroundColor3 = color, BorderSizePixel = 0, ZIndex = 2, Parent = holder,
		})
	end
	return holder
end
local function glyphMinus(parent, size, color)
	return new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(size, 2), BackgroundColor3 = color, BorderSizePixel = 0, ZIndex = 2, Parent = parent,
	})
end
local function glyphChevron(parent, color)
	local holder = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -11, 0.5, 0),
		Size = UDim2.fromOffset(8, 8), BackgroundTransparency = 1, ZIndex = 2, Parent = parent,
	})
	for _, s in ipairs({ { 45, -2 }, { -45, 2 } }) do
		new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, s[2], 0.5, -1),
			Size = UDim2.fromOffset(6, 1), Rotation = s[1],
			BackgroundColor3 = color, BorderSizePixel = 0, ZIndex = 2, Parent = holder,
		})
	end
	return holder
end

-- Popups (bind menus, dropdown lists) live in the window's overlay layer so later
-- rows can't paint over them. Converts an instance's screen position into the
-- overlay's own (pre-UIScale) pixels.
local function overlayXY(win, inst)
	local sc = win.Scale.Scale
	if sc <= 0 then sc = 1 end
	local d = inst.AbsolutePosition - win.Window.AbsolutePosition
	return d.X / sc, d.Y / sc, inst.AbsoluteSize.X / sc, inst.AbsoluteSize.Y / sc
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
				TextSize = 14, FontFace = Theme.Mono, TextColor3 = Theme.Bone, Parent = col,
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
	label(col, string.upper(title), 10, Theme.Bone, Theme.MonoSemi)
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

local ROW_H   = MOBILE and 72 or 58
local CTRL_H  = MOBILE and 44 or 32

-- one full-width row: label + description on the left, control on the right
-- opts: Divider (default true), LabelWidth (offset px; default = row minus 190),
--       Hover (default = text ~= nil)
function Section:_row(text, desc, height, opts)
	opts = opts or {}
	local r = new("Frame", {
		BackgroundColor3 = Color3.fromHex("101012"), BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, height or ROW_H), LayoutOrder = self._order, Parent = self.Frame,
	})
	self._order += 1
	if opts.Divider ~= false then
		new("Frame", {
			AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 1),
			BackgroundColor3 = Theme.Line, BorderSizePixel = 0, Parent = r,
		})
	end
	pad(r, 0, 22)

	-- Instances reject custom fields, so the header strip is returned to the
	-- caller rather than parked on the row. nil when the row has no text.
	local head
	if text then
		local colSize = opts.LabelWidth and UDim2.new(0, opts.LabelWidth, 1, 0) or UDim2.new(1, -190, 1, 0)
		local col = new("Frame", { BackgroundTransparency = 1, Size = colSize, Parent = r })
		list(col, 3, nil, Enum.VerticalAlignment.Center)
		head = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18), Parent = col })
		list(head, 8, Enum.FillDirection.Horizontal, Enum.VerticalAlignment.Center)
		local t = label(head, text, 13.5, Theme.Bone)
		t.Size = UDim2.fromOffset(t.TextBounds.X + 4, 18)
		t.AutomaticSize = Enum.AutomaticSize.X
		if desc then label(col, string.upper(desc), 9, Theme.Bone3, Theme.Mono, true) end
	end

	-- hover wash #101012 (desktop only, and only on rows that have a label — the
	-- mockup's config group / input / button rows don't hover)
	local hover = opts.Hover
	if hover == nil then hover = text ~= nil end
	if not MOBILE and hover then
		r.MouseEnter:Connect(function() tw(r, FAST, { BackgroundTransparency = 0 }) end)
		r.MouseLeave:Connect(function() tw(r, FAST, { BackgroundTransparency = 1 }) end)
	end
	return r, head
end

--------------------------------------------------------------------
-- TOGGLE  (+ right-click bind popup on desktop)
--------------------------------------------------------------------
function Section:AddToggle(o)
	local state = o.Default or false
	local bind  = { Key = o.BindKey, Mode = o.BindMode or "Toggle" }
	local win   = self.Window
	local r, head = self:_row(o.Text, o.Desc)

	local W, H   = MOBILE and 64 or 46, MOBILE and 36 or 24
	local KW, KH = MOBILE and 27 or 19, MOBILE and 30 or 18

	local badge = new("TextLabel", {
		BackgroundColor3 = Theme.Accent, BackgroundTransparency = 0.87,
		Size = UDim2.fromOffset(0, 15), AutomaticSize = Enum.AutomaticSize.X,
		Text = "", TextSize = 9, FontFace = Theme.Mono, TextColor3 = Theme.Accent,
		Visible = false, LayoutOrder = 2, Parent = head or r,
	})
	stroke(badge, Theme.Accent, 0.5)
	pad(badge, 0, 5)

	local led = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -(W + 9), 0.5, 0),
		Size = UDim2.fromOffset(MOBILE and 6 or 5, MOBILE and 6 or 5),
		BackgroundColor3 = Theme.Edge, BorderSizePixel = 0, Parent = r,
	})

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
		BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, ZIndex = 3, Parent = well,
	})
	-- the gradient carries the colour so the base stays white and multiplies cleanly
	local knobGrad = gradient(knob, Color3.fromHex("4A483F"), Color3.fromHex("2E2D28"))
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
		tw(knob, SNAP, { Position = UDim2.fromOffset(on and (W - KW - 3) or 3, math.floor((H - KH) / 2)) })
		knobGrad.Color = on
			and ColorSequence.new(Color3.fromHex("F6F2E8"), Color3.fromHex("C9C4B7"))
			or  ColorSequence.new(Color3.fromHex("4A483F"), Color3.fromHex("2E2D28"))
		knobEdge.BackgroundColor3 = on and Color3.fromHex("FFFDF6") or Color3.fromHex("5C5A50")
		tw(led, FAST, { BackgroundColor3 = on and Theme.Accent or Theme.Edge })
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

			-- right: calc(100% + 12px) off the LED+switch group, i.e. clear of the
			-- 9px gap and the LED before the 12px margin
			local MH, MX = 162, 12 + 9 + (MOBILE and 6 or 5)
			-- in the overlay layer: right edge MX left of the LED+switch group, vertically
			-- centred on the switch, clamped inside the scrolling body
			local wx, wy, _, wh = overlayXY(win, well)
			local bx, by, _, bh = overlayXY(win, win._body)
			local top = math.clamp(wy + wh / 2 - MH / 2, by + 10, by + bh - MH - 10)
			menu = new("Frame", {
				AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromOffset(wx - MX, top),
				Size = UDim2.fromOffset(196, MH), BackgroundColor3 = Color3.fromHex("0C0C0E"),
				ClipsDescendants = true, ZIndex = 40, Parent = win._overlay,
			})
			stroke(menu, Color3.fromHex("33322B"))
			glow(menu, Theme.Accent, 0.72, 22)
			-- the glow must NOT sit in the list: a UIListLayout stacks every GuiObject child,
			-- so the padded list lives in an inner box and the glow stays on the outer frame
			local box = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 2, Parent = menu })
			pad(box, 11)
			list(box, 7)

			local head = label(box, "BIND · " .. string.upper(o.Text or ""), 8, Theme.Bone4, Theme.Mono, true)
			head.LayoutOrder = 1

			local keyBtn = new("TextButton", {
				Size = UDim2.new(1, 0, 0, 30), BackgroundColor3 = Theme.Well, AutoButtonColor = false,
				Text = bind.Key and string.upper(keyName(bind.Key)) or "CLICK TO BIND",
				TextSize = 11, FontFace = Theme.Mono,
				TextColor3 = bind.Key and Theme.Bone or Theme.Bone4, LayoutOrder = 2, Parent = box,
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

			local modeRow = new("Frame", { Size = UDim2.new(1, 0, 0, 24), BackgroundTransparency = 1, LayoutOrder = 3, Parent = box })
			list(modeRow, 3, Enum.FillDirection.Horizontal)
			local hint = label(box, "", 8, Theme.Bone3, Theme.Mono, true)
			hint.LayoutOrder = 4
			hint.Size = UDim2.new(1, 0, 0, 22)
			hint.TextWrapped = true

			local HINTS = {
				Always = "FORCED ON — KEY AND CLICKS IGNORED",
				Toggle = "KEY FLIPS IT ON AND OFF",
				Hold   = "ON ONLY WHILE THE KEY IS HELD",
			}
			local modeBtns = {}   -- mode -> { btn = TextButton, stroke = UIStroke }
			local function paintModes()
				hint.Text = HINTS[bind.Mode]
				for m, rec in pairs(modeBtns) do
					local on = bind.Mode == m
					tw(rec.btn, FAST, { BackgroundTransparency = on and 0.82 or 1 })
					rec.btn.TextColor3 = on and Theme.Bone or Theme.Bone4
					rec.stroke.Color = on and Theme.Accent or Theme.Edge2
					rec.stroke.Transparency = on and 0.45 or 0
				end
			end
			for _, m in ipairs({ "Always", "Toggle", "Hold" }) do
				local b = new("TextButton", {
					Size = UDim2.new(0.333, -2, 1, 0), BackgroundColor3 = Theme.Accent, BackgroundTransparency = 1,
					AutoButtonColor = false, Text = string.upper(m), TextSize = 9, FontFace = Theme.Mono,
					TextColor3 = Theme.Bone4, Parent = modeRow,
				})
				modeBtns[m] = { btn = b, stroke = stroke(b, Theme.Edge2) }
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
				AutoButtonColor = false, Text = "CLEAR BIND", TextSize = 9, FontFace = Theme.Mono,
				TextColor3 = Theme.Danger, LayoutOrder = 5, Parent = box,
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

		conn(UserInputService.InputBegan, function(i, gpe)
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
			-- gameProcessedEvent is true for keys the game also uses (Shift = shift-lock),
			-- so only a focused text box blocks a bind
			if UserInputService:GetFocusedTextBox() or not bind.Key or i.KeyCode ~= bind.Key then return end
			if bind.Mode == "Toggle" then set(not state, true)
			elseif bind.Mode == "Hold" then set(true, true) end
		end)
		conn(UserInputService.InputEnded, function(i)
			if bind.Mode == "Hold" and bind.Key and i.KeyCode == bind.Key then set(false, true) end
		end)
	end

	set(bind.Mode == "Always" and true or state, false)
	refreshBadge()
	table.insert(PAINTERS, paint)   -- slot / LED colours are chosen at paint time

	-- binds are saved by key *name* so the JSON stays readable
	local function syncBind()
		if not o.Flag then return end
		Prism.Binds[o.Flag] = (bind.Key or bind.Mode ~= "Toggle")
			and { Key = bind.Key and keyName(bind.Key) or nil, Mode = bind.Mode } or nil
	end
	local origRefresh = refreshBadge
	refreshBadge = function() origRefresh() syncBind() end
	syncBind()

	local api = {
		Set = function(v, fire) set(v and true or false, fire ~= false) end,
		Get = function() return state end,
		SetBind = function(key, mode)
			if type(key) == "string" then key = Enum.KeyCode[key] end   -- accept a saved name
			bind.Key, bind.Mode = key, mode or bind.Mode
			if bind.Mode == "Always" then set(true, true) end
			refreshBadge() paint()
		end,
		GetBind = function() return bind end,
	}
	register(o.Flag, api)
	return api
end

--------------------------------------------------------------------
-- SLIDER  (fader + detent ticks + odometer)
--------------------------------------------------------------------
function Section:AddSlider(o)
	local min, max, step = o.Min or 0, o.Max or 100, o.Step or 1
	local places = o.Places or #tostring(max)
	local value = math.clamp(o.Default or min, min, max)
	-- mockup: label column is a fixed 150px, the fader takes everything else (gap 24)
	local r = self:_row(o.Text, o.Desc, nil, { LabelWidth = 150 })

	local right = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.new(1, -174, 0, 26), BackgroundTransparency = 1, Parent = r,
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
		BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, ZIndex = 3, Parent = track,
	})
	gradient(cap, Color3.fromHex("F2EEE3"), Color3.fromHex("B8B3A6"))   -- linear-gradient(180deg,#F2EEE3,#B8B3A6)
	grip(cap, false)
	new("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Color3.fromHex("FFFDF6"), BorderSizePixel = 0, ZIndex = 3, Parent = cap })
	new("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 2), BackgroundColor3 = Color3.fromHex("08080A"), BorderSizePixel = 0, ZIndex = 3, Parent = cap })
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
	conn(UserInputService.InputEnded, function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
	end)
	UserInputService.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			fromX(i.Position.X)
		end
	end)

	set(value, false)
	local api = { Set = function(v, fire) set(tonumber(v) or value, fire ~= false) end, Get = function() return value end }
	register(o.Flag, api)
	return api
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
		Text = string.upper(keyName(key)), TextSize = 11, FontFace = Theme.Mono, TextColor3 = Theme.Bone, Parent = r,
	})
	local bs = stroke(btn, Theme.Edge2)
	local bar = new("Frame", {
		Size = UDim2.new(0, 3, 1, 0), BackgroundColor3 = Theme.Accent,
		BackgroundTransparency = 1, BorderSizePixel = 0, Parent = btn,
	})

	btn.MouseButton1Click:Connect(function()
		listening = true
		bs.Color, bar.BackgroundTransparency = Theme.Accent, 0
		btn.BackgroundColor3, btn.BackgroundTransparency = Theme.Accent, 0.86
		scrambleTask = task.spawn(function()
			local n = 0
			while listening do
				btn.Text = KEYPOOL[math.random(#KEYPOOL)]
				n += 1
				-- listenBar .55s steps(2): the bar blinks while listening
				bar.BackgroundTransparency = (n % 10 < 5) and 0 or 0.75
				task.wait(0.055)
			end
		end)
	end)

	conn(UserInputService.InputBegan, function(i, gpe)
		if not listening or i.UserInputType ~= Enum.UserInputType.Keyboard then return end
		listening = false
		if scrambleTask then task.cancel(scrambleTask) scrambleTask = nil end
		key = i.KeyCode
		btn.Text = string.upper(keyName(key))
		bs.Color, bar.BackgroundTransparency = Theme.Edge2, 1
		btn.BackgroundColor3, btn.BackgroundTransparency = Theme.Well, 0
		if o.Flag then Prism.Flags[o.Flag] = keyName(key) end
		Prism:Notify("KEYBIND SET", (o.Text or "bind") .. " → " .. string.upper(keyName(key)))
		if o.Changed then task.spawn(o.Changed, key) end
	end)

	if o.Flag then Prism.Flags[o.Flag] = keyName(key) end
	local api = {
		Get = function() return key end,
		Set = function(k, fire)
			if type(k) == "string" then local ok, kc = pcall(function() return Enum.KeyCode[k] end) k = ok and kc or nil end
			if not k then return end
			key = k
			btn.Text = string.upper(keyName(key))
			if o.Flag then Prism.Flags[o.Flag] = keyName(key) end
			if fire ~= false and o.Changed then task.spawn(o.Changed, key) end
		end,
	}
	register(o.Flag, api)
	return api
end

--------------------------------------------------------------------
-- DROPDOWN / MULTI-SELECT
--------------------------------------------------------------------
local function optionRow(parent, text, selected, order)
	local b = new("TextButton", {
		Size = UDim2.new(1, 0, 0, MOBILE and 44 or 30), BackgroundColor3 = Theme.Accent,
		BackgroundTransparency = selected and 0.86 or 1, AutoButtonColor = false,
		Text = "     " .. string.upper(text), TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 10, FontFace = Theme.Mono,
		TextColor3 = selected and Theme.Bone or Theme.Bone2, LayoutOrder = order, Parent = parent,
	})
	local edge = new("Frame", {
		Size = UDim2.new(0, 2, 1, 0), BackgroundColor3 = Theme.Accent,
		BackgroundTransparency = selected and 0 or 1, BorderSizePixel = 0, Parent = b,
	})
	return b, edge
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
	local chev = glyphChevron(btn, Theme.Bone4)
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
		local ax, ay, aw, ah = overlayXY(win, anchor)
		menu = new("Frame", {
			Position = UDim2.fromOffset(ax, ay + ah + 4), Size = UDim2.fromOffset(aw, 0),
			BackgroundColor3 = Color3.fromHex("0C0C0E"), ClipsDescendants = true, ZIndex = 30, Parent = win._overlay,
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
		tw(menu, SMOOTH, { Size = UDim2.fromOffset(aw, H) })
		win._closePopups = close
	end)

	if o.Flag then Prism.Flags[o.Flag] = value end
	local api = {
		Get = function() return value end,
		Set = function(v, fire)
			if not table.find(o.Options, v) then return end
			value = v
			txt.Text = string.upper(value)
			close()
			if o.Flag then Prism.Flags[o.Flag] = value end
			if fire ~= false and o.Callback then task.spawn(o.Callback, value) end
		end,
	}
	register(o.Flag, api)
	return api
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
		local ax, ay, aw, ah = overlayXY(win, anchor)
		menu = new("Frame", {
			Position = UDim2.fromOffset(ax, ay + ah + 4), Size = UDim2.fromOffset(aw, 0),
			BackgroundColor3 = Color3.fromHex("0C0C0E"), ClipsDescendants = true, ZIndex = 30, Parent = win._overlay,
		})
		stroke(menu, Theme.Edge2)
		pad(menu, 3)
		list(menu, 0)
		for i, name in ipairs(o.Options) do
			local ob, edge = optionRow(menu, "   " .. name, has(name), i)
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
				edge.BackgroundTransparency = on and 0 or 1
				ob.TextColor3 = on and Theme.Bone or Theme.Bone2
				txt.Text = lab()
				if o.Flag then Prism.Flags[o.Flag] = selected end
				if o.Callback then task.spawn(o.Callback, selected) end
			end)
		end
		tw(menu, SMOOTH, { Size = UDim2.fromOffset(aw, #o.Options * rowH + 6) })
		win._closePopups = close
	end)

	if o.Flag then Prism.Flags[o.Flag] = selected end
	local api = {
		Get = function() return selected end,
		Set = function(v, fire)
			if type(v) ~= "table" then return end
			table.clear(selected)
			for _, x in ipairs(v) do if table.find(o.Options, x) then table.insert(selected, x) end end
			txt.Text = lab()
			close()
			if o.Flag then Prism.Flags[o.Flag] = selected end
			if fire ~= false and o.Callback then task.spawn(o.Callback, selected) end
		end,
	}
	register(o.Flag, api)
	return api
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

	local btns, currentHex = {}, nil
	-- selected swatch: 2px bone border, bloom, lifted 2px (translateY(-2px))
	local function paint(hex)
		currentHex = hex
		for h, rec in pairs(btns) do
			local on = h == hex
			rec.stroke.Color = on and Theme.Bone or Color3.new(0, 0, 0)
			rec.stroke.Transparency = on and 0 or 0.4
			rec.stroke.Thickness = on and 2 or 1
			rec.glow.ImageTransparency = on and 0.35 or 1
			tw(rec.slot, SNAP, { Position = UDim2.fromOffset(0, on and -2 or 0) })
		end
	end
	for i, hex in ipairs(hexes) do
		local c = Color3.fromHex(hex)
		-- a fixed layout slot so the lift doesn't shove neighbours around
		local slotFrame = new("Frame", { Size = UDim2.fromOffset(size, size), BackgroundTransparency = 1, LayoutOrder = i, Parent = tray })
		local slot = new("Frame", { Size = UDim2.fromOffset(size, size), BackgroundTransparency = 1, Parent = slotFrame })
		local b = new("TextButton", {
			Size = UDim2.fromScale(1, 1), BackgroundColor3 = c, AutoButtonColor = false,
			Text = "", Parent = slot,
		})
		-- a swatch that happens to equal the current accent must NOT follow accent changes
		btns[hex] = { btn = untag(b), slot = slot, stroke = stroke(b, Color3.new(0, 0, 0), 0.4), glow = untag(glow(b, c, 1, 10)) }
		b.MouseButton1Click:Connect(function()
			value = c
			paint(hex)
			if o.Flag then Prism.Flags[o.Flag] = hex end
			if o.Callback then task.spawn(o.Callback, c) end
		end)
	end
	-- the mockup renders with the default swatch already selected
	local defHex = string.upper(typeof(value) == "Color3" and value:ToHex() or tostring(value))
	for _, hex in ipairs(hexes) do
		if string.upper(hex) == defHex then paint(hex) value = Color3.fromHex(hex) break end
	end
	if o.Flag and currentHex then Prism.Flags[o.Flag] = currentHex end
	local api = {
		Get = function() return value end,
		Set = function(hex, fire)
			if typeof(hex) == "Color3" then hex = hex:ToHex() end
			hex = string.upper(tostring(hex or "")):gsub("^#", "")
			if not table.find(hexes, hex) then
				for _, h in ipairs(hexes) do if string.upper(h) == hex then hex = h end end
			end
			local ok, c = pcall(Color3.fromHex, hex)
			if not ok then return end
			value = c
			paint(hex)
			if o.Flag then Prism.Flags[o.Flag] = hex end
			if fire ~= false and o.Callback then task.spawn(o.Callback, c) end
		end,
	}
	register(o.Flag, api)
	return api
end

--------------------------------------------------------------------
-- TEXT INPUT  (tag + recessed well)
--------------------------------------------------------------------
-- Divider = false drops the hairline and the 14px vertical padding, for use
-- inside a group (the mockup's config block: list / name / buttons, gap 12)
function Section:AddInput(o)
	local grouped = o.Divider == false
	local r = self:_row(nil, nil, grouped and CTRL_H or CTRL_H + 28, { Divider = not grouped })
	local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = r })
	list(row, 10, Enum.FillDirection.Horizontal, Enum.VerticalAlignment.Center)

	local tag = label(row, string.upper(o.Tag or o.Text or "TEXT"), 9, Theme.Bone4, Theme.Mono, true)
	tag.Size = UDim2.fromOffset(38, 14)
	tag.LayoutOrder = 1

	local box = new("TextBox", {
		Size = UDim2.new(1, -48, 0, CTRL_H), BackgroundColor3 = Theme.Well,
		Text = o.Default or "", PlaceholderText = o.Placeholder or "",
		PlaceholderColor3 = Color3.fromHex("4E4B45"), TextSize = 11, FontFace = Theme.Mono,
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
	local api = {
		Get = function() return box.Text end,
		Set = function(t, fire)
			box.Text = tostring(t or "")
			if o.Flag then Prism.Flags[o.Flag] = box.Text end
			if fire and o.Callback then task.spawn(o.Callback, box.Text) end
		end,
	}
	register(o.Flag, api)
	return api
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

-- closes the mockup's config group: 12px above (the group gap), 16px below, then the divider
function Section:AddButtonRow(items)
	local h = MOBILE and 44 or 30
	local r = self:_row(nil, nil, h + 28)
	local row = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 12), Size = UDim2.new(1, 0, 0, h), Parent = r })
	list(row, 6, Enum.FillDirection.Horizontal)
	local n = #items
	for i, it in ipairs(items) do
		local b = new("TextButton", {
			Size = UDim2.new(1 / n, -6 + 6 / n, 1, 0), AutoButtonColor = false,
			Text = string.upper(it.Text), TextSize = 9.5, FontFace = Theme.Mono, LayoutOrder = i, Parent = row,
		})
		styleButton(b, it.Style)
		local base = b.BackgroundTransparency
		b.MouseEnter:Connect(function() tw(b, FAST, { BackgroundTransparency = math.max(0, base - 0.08) }) end)
		b.MouseLeave:Connect(function() tw(b, FAST, { BackgroundTransparency = base }) end)
		b.MouseButton1Click:Connect(function() if it.Callback then task.spawn(it.Callback) end end)
	end
end

function Section:AddButton(o)
	-- mockup: padding 16px 22px 22px, no divider under the last row
	local h = o.Tall and (MOBILE and 48 or 38) or (MOBILE and 44 or 30)
	local r = self:_row(nil, nil, h + 38, { Divider = o.Divider })
	local b = new("TextButton", {
		Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 0, h), AutoButtonColor = false,
		Text = string.upper(o.Text), TextSize = o.Tall and 10.5 or 9.5, FontFace = Theme.Mono, Parent = r,
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

	-- opens the mockup's config group: 16px above, 12px gap below, no divider —
	-- AddInput({ Divider = false }) and AddButtonRow follow it directly
	local r = self:_row(nil, nil, maxH + 28, { Divider = false })
	local box = new("ScrollingFrame", {
		Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 0, maxH),
		BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.58, BorderSizePixel = 0,
		ScrollBarThickness = 3, ScrollBarImageColor3 = Theme.Edge2, ScrollBarImageTransparency = 0.3,
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = r,
	})
	stroke(box, Color3.fromHex("22211C"))
	list(box, 0)

	local empty = new("TextLabel", {
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 52),
		Text = "NO CONFIGS ON DISK — NAME ONE BELOW AND SAVE",
		TextSize = 9, FontFace = Theme.Mono, TextColor3 = Theme.Bone3, TextWrapped = true, Parent = box,
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
		local keep = Prism.Folder
		Prism.Folder = folder
		local names = Prism:ListConfigs()
		Prism.Folder = keep
		return names
	end

	function api.Refresh()
		for _, row in pairs(rows) do row.Button:Destroy() end
		rows = {}
		loaded = Prism.Loaded or loaded
		local names = api.List()
		empty.Visible = #names == 0
		if o.OnCount then task.spawn(o.OnCount, #names) end

		for i, name in ipairs(names) do
			local b = new("TextButton", {
				Size = UDim2.new(1, 0, 0, rowH), BackgroundColor3 = Theme.Accent, BackgroundTransparency = 1,
				AutoButtonColor = false, Text = "      " .. name, TextXAlignment = Enum.TextXAlignment.Left,
				TextSize = 10, FontFace = Theme.Mono, TextColor3 = Theme.Bone2, LayoutOrder = i, Parent = box,
			})
			local edge = new("Frame", { Size = UDim2.new(0, 2, 1, 0), BackgroundColor3 = Theme.Accent, BackgroundTransparency = 1, BorderSizePixel = 0, Parent = b })
			local dot = new("Frame", {
				AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 10, 0.5, 0), Size = UDim2.fromOffset(4, 4),
				BackgroundColor3 = (name == loaded) and Theme.Accent or Color3.fromHex("2E2D26"), BorderSizePixel = 0, Parent = b,
			})
			local tag = new("TextLabel", {
				AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(50, 12),
				BackgroundTransparency = 1, Text = "LOADED", TextXAlignment = Enum.TextXAlignment.Right,
				TextSize = 8, FontFace = Theme.Mono, TextColor3 = Theme.Accent, Visible = name == loaded, Parent = b,
			})
			rows[name] = { Button = b, Edge = edge, Dot = dot, Tag = tag }
			b.MouseButton1Click:Connect(function() api.Select(name) end)
		end
		if selected then api.Select(selected) end
	end

	api.Refresh()
	table.insert(PAINTERS, function() api.SetLoaded(loaded) end)
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
		TextSize = 9, FontFace = Theme.Mono, TextColor3 = Color3.fromHex("3E3C37"), Parent = strip,
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
		local r, head = origRow(s, ...)
		self._order = s._order
		return r, head
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
	local chassisGlow = glow(win, Theme.Accent, 1, 34)   -- off until SetGlow(true); glow defaults off
	self.Window = win
	self.Scale = new("UIScale", { Scale = 1, Parent = win })

	-- linear-gradient(180deg, rgba(233,228,216,.035), transparent 30%)
	local wash = new("Frame", {
		Size = UDim2.new(1, 0, 0.3, 0), BackgroundColor3 = Theme.Bone,
		BorderSizePixel = 0, ZIndex = 1, Parent = win,
	})
	new("UIGradient", {
		Rotation = 90, Parent = wash,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.965), NumberSequenceKeypoint.new(1, 1),
		}),
	})

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
	-- padding 17px 22px 15px around a 22px wordmark (+1 border) = 55; mobile the 44px button sets it
	local HEADER_H = MOBILE and 76 or 55
	local header = new("Frame", { Size = UDim2.new(1, 0, 0, HEADER_H), BackgroundTransparency = 1, ClipsDescendants = true, ZIndex = 4, Parent = win })
	new("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Theme.Edge, BorderSizePixel = 0, Parent = header })

	-- sweep: a 60px sheen crossing the header every 9s
	local sweep = new("Frame", {
		Position = UDim2.new(0, -80, 0, 0), Size = UDim2.new(0, 60, 1, 0),
		BackgroundColor3 = Theme.Bone, BorderSizePixel = 0, ZIndex = 4, Parent = header,
	})
	new("UIGradient", {
		Rotation = 0, Parent = sweep,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.95), NumberSequenceKeypoint.new(1, 1),
		}),
	})
	task.spawn(function()
		while sweep.Parent do
			if not Prism.Reduced then
				sweep.Position = UDim2.new(0, -80, 0, 0)
				tw(sweep, TweenInfo.new(9, Enum.EasingStyle.Cubic, Enum.EasingDirection.InOut), { Position = UDim2.new(1, 80, 0, 0) })
			end
			task.wait(9)
		end
	end)
	pad(header, 0, 22)

	local wordmark = new("TextLabel", {
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.new(1, -70, 0, 26),
		BackgroundTransparency = 1, Text = spaced(o.Name or "PRISM"), TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 22, FontFace = Theme.Bold, TextColor3 = Theme.Bone, Parent = header,
	})

	local hb = MOBILE and 44 or 28
	local hideBtn = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(hb, hb),
		BackgroundColor3 = Theme.Well, AutoButtonColor = false, Text = "", Parent = header,
	})
	stroke(hideBtn, Theme.Edge2)
	-- ✕ on desktop, – on mobile: drawn, since the mono font lacks the glyphs
	if MOBILE then glyphMinus(hideBtn, 16, Theme.Bone2) else glyphX(hideBtn, 9, Theme.Bone4) end

	----------------------------------------------------------------
	-- tab strip + sliding underline
	----------------------------------------------------------------
	local strip = new("Frame", {
		Position = UDim2.fromOffset(0, HEADER_H), Size = UDim2.new(1, 0, 0, MOBILE and 48 or 40),
		BackgroundColor3 = Color3.fromHex("0C0C0E"), ZIndex = 4, Parent = win,
	})
	new("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Theme.Edge, BorderSizePixel = 0, Parent = strip })
	local tabRow = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = strip })
	pad(tabRow, 0, 22)
	-- mockup: padding-right 18 + margin-right 22 between tabs
	list(tabRow, 40, Enum.FillDirection.Horizontal, Enum.VerticalAlignment.Center)
	local underline = new("Frame", {
		AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 22, 1, 0), Size = UDim2.fromOffset(0, 2),
		BackgroundColor3 = Theme.Accent, BorderSizePixel = 0, ZIndex = 5, Parent = strip,
	})
	glow(underline, Theme.Accent, 0.4, 8)

	----------------------------------------------------------------
	-- scrolling body
	----------------------------------------------------------------
	local bodyTop = HEADER_H + (MOBILE and 48 or 40)
	local body = new("Frame", {
		Position = UDim2.fromOffset(0, bodyTop), Size = UDim2.new(1, 0, 1, -bodyTop),
		BackgroundTransparency = 1, ClipsDescendants = true, ZIndex = 4, Parent = win,
	})
	self._body = body

	-- popup layer: bind menus and dropdown lists are parented here so they sit
	-- above every row (sibling ZIndex only orders against siblings)
	self._overlay = new("Frame", {
		Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 50, Parent = win,
	})

	----------------------------------------------------------------
	-- notifications + mobile floating icon
	----------------------------------------------------------------
	self._notif = new("Frame", {
		AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -26, 1, -26),
		Size = UDim2.fromOffset(286, 320), BackgroundTransparency = 1, Parent = gui,
	})
	list(self._notif, 7, nil, Enum.VerticalAlignment.Bottom)
	Prism._notif = self._notif   -- Prism:Notify() is called on the module, not the window

	local icon = new("TextButton", {
		AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -28), Size = UDim2.fromOffset(56, 56),
		BackgroundColor3 = Theme.Chassis, AutoButtonColor = false, Visible = false,
		Text = "P", TextSize = 24, FontFace = Theme.Bold, TextColor3 = Theme.Bone, Parent = gui,
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
		-- overlay popups are positioned absolutely; scrolling would leave them floating
		page:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
			if self._closePopups then self._closePopups() self._closePopups = nil end
		end)

		local btn = new("TextButton", {
			Size = UDim2.fromOffset(0, MOBILE and 48 or 40), AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1, AutoButtonColor = false, Text = string.upper(name),
			TextSize = 9.5, FontFace = Theme.Mono, TextColor3 = index == 1 and Theme.Bone or Theme.Bone4,
			LayoutOrder = index, Parent = tabRow,
		})

		local tab = setmetatable({ Page = page, Button = btn, Window = self, Name = name, _order = 1 }, Tab)
		table.insert(self.Tabs, tab)
		btn.MouseButton1Click:Connect(function() self:SelectTab(index) end)
		-- AutomaticSize settles a frame late (and again on UIScale changes): keep the
		-- underline pinned to the active tab whenever its button moves or resizes
		local function track() if self.Current == index then self:_placeUnderline(btn, false) end end
		btn:GetPropertyChangedSignal("AbsoluteSize"):Connect(track)
		btn:GetPropertyChangedSignal("AbsolutePosition"):Connect(track)
		if index == 1 then task.defer(function() self:SelectTab(1) end) end
		return tab
	end

	-- underline geometry in the strip's own (pre-UIScale) pixels
	function self:_placeUnderline(btn, animate)
		local sc = self.Scale.Scale
		if sc <= 0 then return end
		local goal = {
			Position = UDim2.new(0, (btn.AbsolutePosition.X - strip.AbsolutePosition.X) / sc, 1, 0),
			Size = UDim2.fromOffset(btn.AbsoluteSize.X / sc, 2),
		}
		if animate then tw(underline, SLIDE, goal) else underline.Position, underline.Size = goal.Position, goal.Size end
	end

	function self:SelectTab(i)
		self.Current = i
		for n, t in ipairs(self.Tabs) do
			local on = n == i
			t.Page.Visible = on
			tw(t.Button, FAST, { TextColor3 = on and Theme.Bone or Theme.Bone4 })
			if on then
				-- underline slides with overshoot, matching the CSS
				self:_placeUnderline(t.Button, true)
				-- shutter the page in (clip-path inset(0 0 100% 0) -> 0, .34s)
				t.Page.Position = UDim2.fromOffset(0, 0)
				t.Page.CanvasPosition = Vector2.new(0, 0)
				t.Page.Size = UDim2.new(1, 0, 0, 0)
				tw(t.Page, TweenInfo.new(0.34, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Size = UDim2.fromScale(1, 1) })
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
			tw(win, SMOOTH, { Size = SIZE, BackgroundTransparency = self._lowEnd and 0 or 0.12 })
			self.Blur.Enabled = self.Blur.Size > 0 and not self._lowEnd   -- backdrop blur returns with the menu
		else
			self.Blur.Enabled = false                                      -- and leaves with it
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

	-- repaints every accent-tagged property in the chassis, then runs the
	-- conditional painters (toggle slots / LEDs, config dots)
	function self:SetAccent(c)
		if typeof(c) == "string" then c = Color3.fromHex(c) end
		Theme.Accent = c
		for _, d in ipairs(gui:GetDescendants()) do
			local tags = d:GetAttribute("PrismAccent")
			if tags then
				for prop in string.gmatch(tags, "[^,]+") do pcall(function() d[prop] = c end) end
			end
		end
		for _, p in ipairs(PAINTERS) do task.spawn(p) end
	end

	-- "Glow effects": the bloom behind the chassis (box-shadow 0 0 90px accent)
	self._glow, self._lowEnd = false, false
	local function paintGlow()
		local on = self._glow and not self._lowEnd
		tw(chassisGlow, SMOOTH, { ImageTransparency = on and 0.62 or 1 })
	end
	function self:SetGlow(on) self._glow = on and true or false paintGlow() end

	-- "Low-end mode": opaque chassis, no bloom, no blur
	function self:SetLowEnd(on)
		self._lowEnd = on and true or false
		tw(win, SMOOTH, { BackgroundTransparency = self._lowEnd and 0 or 0.12 })
		if self.Blur then self.Blur.Enabled = (not self._lowEnd) and self.Blur.Size > 0 end
		paintGlow()
	end

	-- "Notifications": which corner the tickers stack in
	function self:SetNotificationCorner(corner)
		corner = string.lower(tostring(corner or "Bottom Right"))
		local top, left = corner:find("top") ~= nil, corner:find("left") ~= nil
		self._notif.AnchorPoint = Vector2.new(left and 0 or 1, top and 0 or 1)
		self._notif.Position = UDim2.new(left and 0 or 1, left and 26 or -26, top and 0 or 1, top and 26 or -26)
		self._notif:FindFirstChildOfClass("UIListLayout").VerticalAlignment =
			top and Enum.VerticalAlignment.Top or Enum.VerticalAlignment.Bottom
	end

	-- Destroy()      = smooth unload: chassis collapses to a hairline and fades, then goes
	-- Destroy(true)  = instant (panic key, re-injection)
	function self:Destroy(instant)
		if self._dead then return end
		self._dead = true
		dropConns()
		table.clear(PAINTERS) table.clear(CONTROLS)
		if self.Blur then pcall(function() self.Blur:Destroy() end) end
		local g = genv()
		if g.__PRISM_UNLOAD == self._unload then g.__PRISM_UNLOAD = nil end

		if instant or Prism.Reduced or not win.Visible then
			pcall(function() gui:Destroy() end)
			return
		end
		if self._closePopups then pcall(self._closePopups) self._closePopups = nil end
		icon.Visible = false
		-- reverse of the boot: squash to a bright hairline, then let it die out
		tw(win, TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.In),
			{ Size = UDim2.fromOffset(SIZE.X.Offset, 2) })
		task.delay(0.28, function()
			tw(win, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Size = UDim2.fromOffset(0, 2), BackgroundTransparency = 1 })
			tw(chassisGlow, TweenInfo.new(0.22), { ImageTransparency = 1 })
			task.wait(0.26)
			pcall(function() gui:Destroy() end)
		end)
	end

	-- published so the *next* run of the script can find and unload this one
	self._unload = function() self:Destroy(true) end
	G.__PRISM_UNLOAD = self._unload

	----------------------------------------------------------------
	-- keys (desktop only — mobile uses the header button + icon)
	----------------------------------------------------------------
	if not MOBILE then
		conn(UserInputService.InputBegan, function(i)
			-- not gated on gameProcessedEvent: Shift is "processed" by shift-lock in most
			-- games, which silently ate the default RightShift toggle
			if i.UserInputType ~= Enum.UserInputType.Keyboard or UserInputService:GetFocusedTextBox() then return end
			if i.KeyCode == self.PanicKey then
				self:Destroy(true)
			elseif i.KeyCode == self.ToggleKey then
				self:Toggle()
			end
		end)
	end

	----------------------------------------------------------------
	-- built-in CONFIG & THEMES + SETTINGS tabs (the mockup), with the
	-- config mechanism wired inside the library. Deferred so they land
	-- after the caller's own tabs; pass Builtin = false to skip them.
	----------------------------------------------------------------
	function self:AddBuiltinTabs()
		if self._builtin then return self._builtin end
		local settings = Prism:GetSettings()
		local B = {}
		self._builtin = B

		------------------------------------------------ CONFIG & THEMES
		local Config = self:AddTab("Config & Themes")
		local Look = Config:AddSection("Appearance")
		Look:SetCount(5)

		Look:AddColorPicker({ Text = "Accent color", Desc = "signal / active state", Flag = "prism_accent",
			Callback = function(c) self:SetAccent(c) end })

		local PRESETS = { Amethyst = "C77DFF", Midnight = "5B8CFF", Void = "00E5A0", Ember = "FFB020" }
		Look:AddDropdown({ Text = "Preset", Desc = "full palette swap", Flag = "prism_preset",
			Options = { "Amethyst", "Midnight", "Void", "Ember" }, Default = "Amethyst",
			Callback = function(p) if CONTROLS.prism_accent then CONTROLS.prism_accent.Set(PRESETS[p], true) end end })

		Look:AddSlider({ Text = "Backdrop blur", Desc = "behind the chassis", Flag = "prism_blur",
			Min = 0, Max = 40, Default = 26, Places = 2, Suffix = "PX",
			Callback = function(v) self.Blur.Size = v self.Blur.Enabled = v > 0 and not self._lowEnd end })

		Look:AddSlider({ Text = "Corner radius", Desc = "chassis edge", Flag = "prism_radius",
			Min = 0, Max = 24, Default = Theme.Radius, Places = 2, Suffix = "PX",
			Callback = function(v) win:FindFirstChildOfClass("UICorner").CornerRadius = UDim.new(0, v) end })

		Look:AddToggle({ Text = "Glow effects", Desc = "bloom behind the panel", Default = false, Flag = "prism_glow",
			Callback = function(v) self:SetGlow(v) end })

		local Saves = Config:AddSection("Configs")
		local NameBox, List, AutoToggle

		List = Saves:AddConfigList({
			Loaded = settings.Autoload,
			OnSelect = function(name) NameBox.Set(name) end,
			OnCount  = function(n) Saves:SetCount(n) end,
		})
		NameBox = Saves:AddInput({ Tag = "NAME", Placeholder = "my-config", Default = settings.Autoload or "default", Divider = false })

		local function autoloadName()
			local n = NameBox.Get():gsub("^%s+", ""):gsub("%s+$", "")
			return n ~= "" and n or nil
		end

		Saves:AddButtonRow({
			-- NEW writes <name>.json right away so it appears in the list above and
			-- LOAD / SAVE / DELETE have something to act on
			{ Text = "New", Callback = function()
				local n = autoloadName()
				if not n then return Prism:Notify("NAME REQUIRED", "type a name in the box, then NEW") end
				if isfile and isfile(cfgPath(n)) then
					return Prism:Notify("ALREADY EXISTS", n .. ".json — use SAVE to overwrite")
				end
				local ok, err = Prism:SaveConfig(n)
				if not ok then return Prism:Notify("CAN'T CREATE", tostring(err)) end
				Prism.Loaded = n
				List.Refresh() List.SetLoaded(n) List.Select(n)
				Prism:Notify("NEW CONFIG", n .. ".json created")
			end },
			{ Text = "Load", Callback = function()
				local n = autoloadName()
				local ok, err = Prism:LoadConfig(n)
				if ok then
					List.SetLoaded(n)
					Prism:Notify("CONFIG LOADED", n .. ".json applied")
				else
					Prism:Notify("NOT FOUND", (n or "untitled") .. ".json — " .. tostring(err))
				end
			end },
			{ Text = "Save", Style = "Primary", Callback = function()
				local n = autoloadName()
				if not n then return Prism:Notify("NAME REQUIRED", "type a config name first") end
				local ok, err = Prism:SaveConfig(n)
				if not ok then return Prism:Notify("SAVE FAILED", tostring(err)) end
				Prism.Loaded = n
				List.Refresh() List.SetLoaded(n)
				if AutoToggle and AutoToggle.Get() then Prism:SetSetting("Autoload", n) end
				Prism:Notify("CONFIG SAVED", n .. ".json written")
			end },
			{ Text = "Delete", Style = "Danger", Callback = function()
				local n = autoloadName()
				if not n or not Prism:DeleteConfig(n) then
					return Prism:Notify("NOT FOUND", (n or "untitled") .. ".json")
				end
				if settings.Autoload == n then Prism:SetSetting("Autoload", false) end
				NameBox.Set("") List.Refresh()
				Prism:Notify("CONFIG DELETED", n .. ".json removed")
			end },
		})

		AutoToggle = Saves:AddToggle({ Text = "Autoload on join", Desc = "apply this config at spawn",
			Default = settings.Autoload and true or false,
			Callback = function(v)
				local n = autoloadName()
				if v and n then
					Prism:SetSetting("Autoload", n)
					Prism:Notify("AUTOLOAD ON", n .. ".json applies at spawn")
				else
					Prism:SetSetting("Autoload", false)
					if v then Prism:Notify("NAME REQUIRED", "pick or type a config first") end
				end
			end })

		------------------------------------------------ SETTINGS
		local Settings = self:AddTab("Settings")
		local Iface = Settings:AddSection("Interface")
		Iface:SetCount(MOBILE and 2 or 4)

		Iface:AddKeybind({ Text = "Toggle menu", Desc = "show / hide the window", Flag = "prism_toggle_key",
			Default = self.ToggleKey, Changed = function(k) self.ToggleKey = k end })
		Iface:AddKeybind({ Text = "Panic hide", Desc = "destroys the gui instantly", Flag = "prism_panic_key",
			Default = self.PanicKey, Changed = function(k) self.PanicKey = k end })

		Iface:AddSlider({ Text = "UI scale", Desc = "whole chassis", Flag = "prism_scale",
			Min = 75, Max = 125, Step = 5, Default = 100, Places = 3, Suffix = "%",
			Callback = function(v) self.Scale.Scale = v / 100 end })

		Iface:AddDropdown({ Text = "Notifications", Desc = "corner for tickers", Flag = "prism_notif",
			Options = { "Bottom Right", "Bottom Left", "Top Right" }, Default = "Bottom Right",
			Callback = function(c) self:SetNotificationCorner(c) end })

		local Perf = Settings:AddSection("Performance")
		Perf:SetCount(5)

		Perf:AddToggle({ Text = "Reduce animations", Desc = "cuts every tween to instant", Flag = "prism_reduce",
			Callback = function(v) Prism.Reduced = v end })
		Perf:AddToggle({ Text = "Low-end mode", Desc = "drops blur and bloom", Flag = "prism_lowend",
			Callback = function(v) self:SetLowEnd(v) end })
		Perf:AddMultiDropdown({ Text = "Auto-disable in", Desc = "game categories to skip", Flag = "prism_disable",
			Options = { "Obbies", "Simulators", "Shooters", "Roleplay" }, Default = {} })
		Perf:AddInput({ Tag = "HOOK", Placeholder = "https://discord.com/api/webhooks/…", Flag = "prism_hook" })
		Perf:AddButton({ Text = "Unload PRISM", Style = "Danger", Tall = true, Divider = false, Callback = function()
			Prism:Notify("UNLOADED", "ScreenGui:Destroy()")
			task.wait(0.3)
			self:Destroy()
		end })

		B.Config, B.Settings, B.List, B.NameBox = Config, Settings, List, NameBox
		return B
	end

	-- applies prism/settings.json's Autoload config (every control is registered by now)
	function self:Autoload()
		local name = Prism:GetSettings().Autoload
		if type(name) ~= "string" or name == "" then return false end
		local ok = Prism:LoadConfig(name)
		if ok then
			if self._builtin then self._builtin.List.SetLoaded(name) end
			Prism:Notify("AUTOLOAD", name .. ".json applied")
		end
		return ok
	end

	if o.Builtin ~= false then
		task.defer(function()
			if not gui.Parent then return end
			self:AddBuiltinTabs()
			if o.Autoload ~= false then self:Autoload() end
		end)
	end

	return self
end

return Prism
