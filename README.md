# PRISM — script menu

A script menu library for Roblox. The repo holds one file — **`PrismUI.lua`** — served over a CDN. Your own scripts stay on your machine and pull it in at runtime.

```lua
local Prism = loadstring(game:HttpGet("https://cdn.jsdelivr.net/gh/S2kh/prism@v1.3.1/PrismUI.lua"))()

local Window = Prism:CreateWindow({ Name = "PRISM" })
local Tab    = Window:AddTab("Main")
local Sec    = Tab:AddSection("Player")

Sec:AddToggle({ Text = "Speed", Desc = "walkspeed override", Flag = "speed",
                Callback = function(v) print(v) end })
```

That is the whole integration. The library builds the **Config & Themes** and **Settings** tabs itself (accent, preset, blur, radius, glow, config save / load / delete / autoload, keybinds, UI scale, notification corner, reduce animations, low-end mode, unload) — they land after your own tabs. Pass `Builtin = false` to `CreateWindow` to skip them, `Autoload = false` to skip applying the saved autoload config.

**Pin a tag, never a branch.** `@v1.3.1` is immutable and cached forever. `@main` is cached about 12 hours at the edge, so after a fix is pushed some users get the old file and some get the new one for half a day — every bug report stops matching the code. `https://raw.githubusercontent.com/S2kh/prism/main/PrismUI.lua` is the 5-minute-cache URL to test against; hand out tags.

Loading from disk instead: `loadstring(readfile("PrismUI.lua"))()`. On single-file executors, paste `PrismUI.lua` above your script and drop the `loadstring` line.

## A sturdier loader

The one-liner has no recourse if the CDN is unreachable. This tries jsDelivr, falls back to GitHub raw, and caches the library to `prism/lib_<version>.lua` so relaunches are instant:

```lua
local PRISM_VERSION = "v1.3.1"   -- a git TAG, not a branch

local function loadPrism()
	local sources = {
		("https://cdn.jsdelivr.net/gh/S2kh/prism@%s/PrismUI.lua"):format(PRISM_VERSION),
		("https://raw.githubusercontent.com/S2kh/prism/%s/PrismUI.lua"):format(PRISM_VERSION),
	}
	local cache = ("prism/lib_%s.lua"):format(PRISM_VERSION)

	-- cached copy first; keyed by version so a pinned script never picks up a stale file
	if isfile and isfile(cache) then
		local ok, chunk = pcall(loadstring, readfile(cache))
		if ok and type(chunk) == "function" then
			local built, lib = pcall(chunk)
			if built and lib then return lib end
		end
		if delfile then pcall(delfile, cache) end   -- cache was truncated or corrupt
	end

	for _, url in ipairs(sources) do
		local ok, body = pcall(game.HttpGet, game, url)
		-- a CDN 404 page still arrives as a 200 with HTML in it, and loadstring on
		-- HTML gives a baffling syntax error instead of a clear failure
		if ok and type(body) == "string" and #body > 1000 and not body:match("^%s*<") then
			local chunk, err = loadstring(body)
			if chunk then
				if writefile then
					if makefolder and not (isfolder and isfolder("prism")) then pcall(makefolder, "prism") end
					pcall(writefile, cache, body)
				end
				return chunk()
			end
			warn("[PRISM] " .. url .. " parsed badly: " .. tostring(err))
		end
	end

	error("[PRISM] could not fetch the library — check your connection, or that " ..
	      PRISM_VERSION .. " is a tag that exists", 0)
end

local Prism = loadPrism()
```

## Releasing

1. Bump `Prism.Version` in `PrismUI.lua`.
2. `git commit -am "v1.0.3 — what changed" && git push`
3. `git tag v1.0.3 && git push origin v1.0.3`
4. Bump `PRISM_VERSION` in your caller.

Scripts pinned to an older tag keep working untouched.

Not worth hosting on: Pastebin (guest pastes expire, heavily rate-limited, commonly blocked), Gist raw links (the URL carries a revision SHA that changes on every edit), Discord CDN links (they expire with signed params now).

## Re-injection

Running the script twice is normal, so the library handles it. `CreateWindow` looks for `__PRISM_UNLOAD` in `getgenv()` and calls it before building, so the previous menu is torn down first. Every `UserInputService` connection goes through an internal registry that `Window:Destroy()` disconnects — otherwise the old chunk stays connected and keeps firing on a destroyed GUI, and two copies fight over the same toggle key.

## Controls

| Call | Notes |
|---|---|
| `AddToggle` | rocker switch. Right-click to bind a key + pick Always / Toggle / Hold |
| `AddSlider` | fader with detent ticks and a rolling odometer readout. `Min`, `Max`, `Step`, `Places`, `Suffix` |
| `AddKeybind` | key chip that scrambles while listening. **No-op on touch devices** |
| `AddDropdown` | single select |
| `AddMultiDropdown` | checkbox list, returns an array |
| `AddColorPicker` | swatch strip. Pass `Swatches = {"C77DFF", …}` |
| `AddInput` | recessed text field. `Tag` is the short label on the left. `Divider = false` drops the hairline + padding so it sits inside a group |
| `AddButton` / `AddButtonRow` | one button, or N across. `Style = "Primary"` / `"Danger"`, `Tall = true` |
| `AddConfigList` | scrollable list of `prism/*.json`. Click a row to select it. Opens a group: follow it with `AddInput({ Divider = false })` and `AddButtonRow` for the mockup's config block |
| `Prism:Notify(title, body, duration)` | ticker with a draining rule |
| `Section:SetCount(n)` | the number on the right of a section strip |
| `Window:SetAccent(Color3 or hex)` | repaints every accent-coloured part of the chassis |
| `Window:SetGlow(bool)` | bloom behind the chassis on/off (off by default) |
| `Window:SetLowEnd(bool)` | opaque chassis, no bloom, no blur |
| `Window:SetNotificationCorner("Bottom Right" / "Bottom Left" / "Top Right")` | where tickers stack |
| `Prism.Reduced = true` | every tween lands instantly ("Reduce animations") |
| `Window:Destroy()` / `Window:Destroy(true)` | animated unload / instant (what the panic key uses) |

## Configs

Every control taking a `Flag` writes into `Prism.Flags`; toggles with a bound key also write `Prism.Binds[flag] = { Key, Mode }`. The built-in Config tab handles the rest, but the same calls are public:

| Call | Notes |
|---|---|
| `Prism:SaveConfig(name)` | writes `prism/<name>.json` = `{ Flags, Binds }` |
| `Prism:LoadConfig(name)` | pushes every saved value back into its control (callbacks fire) and re-applies binds |
| `Prism:DeleteConfig(name)` / `Prism:ListConfigs()` | |
| `Prism:SetSetting("Autoload", name or false)` | `prism/settings.json`; `Window:Autoload()` applies it (runs automatically after your tabs are built) |
| `Prism.Folder` | `"prism"` — change before `CreateWindow` to use another folder |

Built-in controls use `prism_*` flags (`prism_accent`, `prism_blur`, `prism_scale`, `prism_toggle_key`, …) so they never collide with yours.

## Mobile

`Prism.Mobile` is `true` when `TouchEnabled and not KeyboardEnabled`. On those devices:

- **No keybinds.** `AddKeybind` returns a stub and adds no row; right-click binding on toggles is disabled.
- The header button becomes a 44px `–` that minimizes the chassis into a draggable 56px floating icon. Tap it to reopen.
- Every control is at a 44px touch minimum; rocker switches go 46×24 → 64×36.

On desktop, hiding the menu fires a notification naming the live toggle key instead of leaving a button on screen.

## Swaps to make

- **Fonts.** Saira and Azeret Mono aren't on Roblox. The nearest built-ins are Titillium Web and Roboto Mono, set as `FontFace` values so the mockup's 500/600/700 weights survive. Swap in your own `FontFace` if you have the real families uploaded.
- **Letter-spacing has no Roblox equivalent.** The mockup tracks mono labels at `.1em`–`.24em`; there is no property for it, and padding a monospace string with spaces overshoots by roughly 4x. Only the wordmark fakes it, where a real space at 22px lands close to `.3em`.
- **`Theme.GlowAsset`** is the standard 9-slice soft shadow (`6014261993`). Replace with your own if you want a tighter bloom.
- **Grain and scanlines** use tiled `2454009026`. Any 1px noise tile works.
- **`backdrop-filter`** has no equivalent — the chassis is `BackgroundTransparency 0.12` and `Window.Blur` is a `Lighting.BlurEffect` the blur slider drives.

## Theming at runtime

`Window:SetAccent(Color3 or "C77DFF")` repaints everything accent-coloured in one sweep — switches, faders, section ticks, tab underline, tickers. Set `Prism.Theme.Accent` before building for a different default; the built-in Accent swatches and Preset dropdown call this for you.
