-- win-lerp.applescript <delta-px>
-- Smoothly grows (positive delta) or shrinks (negative delta) the frontmost
-- window by delta px in both dimensions, keeping it centered, with ease-out.
on run argv
	set delta to (item 1 of argv) as integer
	set steps to 22

	tell application "System Events"
		set frontApp to first application process whose frontmost is true
		set win to front window of frontApp
		set {w0, h0} to size of win
		set {x0, y0} to position of win
	end tell

	set dw to delta
	set dh to delta
	-- don't shrink below a sane floor
	if (w0 + dw) < 300 then set dw to 300 - w0
	if (h0 + dh) < 200 then set dh to 200 - h0
	if dw = 0 and dh = 0 then return

	repeat with i from 1 to steps
		set t to i / steps
		set e to t * t * (3 - 2 * t) -- smoothstep: gentle start and end
		set nw to (w0 + dw * e) as integer
		set nh to (h0 + dh * e) as integer
		set nx to (x0 - (dw * e) / 2) as integer
		set ny to (y0 - (dh * e) / 2) as integer
		-- keep on screen: never past the left edge or under the menu bar
		if nx < 0 then set nx to 0
		if ny < 25 and y0 ≥ 25 then set ny to 25
		tell application "System Events"
			try
				set size of win to {nw, nh}
			on error
				exit repeat -- hit a size limit (screen edge / app min); stop here
			end try
			try
				set position of win to {nx, ny}
			end try
		end tell
	end repeat
end run
