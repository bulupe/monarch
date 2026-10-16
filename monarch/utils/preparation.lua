-- A navigation deadline and readiness token. Engine resource operations may
-- finish after cancellation; their owner must still dispose of those resources.
local M = {}
local sequence = 0

function M.new(timeout, clock, schedule, cancel, completed)
	assert(timeout == nil or (type(timeout) == "number" and timeout >= 0 and timeout < math.huge),
		"Preparation timeout must be a finite non-negative number")
	sequence = sequence + 1
	local request = { id = sequence, stage = "loading", done = false, ready = false }
	local deadline = timeout and timeout > 0 and (clock() + timeout) or nil
	local timer_handle
	local function finish(ok, reason)
		if request.done then return false end
		request.done, request.ok, request.reason = true, ok, reason
		if timer_handle then cancel(timer_handle); timer_handle = nil end
		completed(ok, reason, request)
		return true
	end
	function request.check()
		if not request.done and deadline and clock() >= deadline then finish(false, "timeout") end
		return not request.done
	end
	function request.fail(reason)
		if not request.check() then return false end
		return finish(false, reason or "preparation_failed")
	end
	function request.signal(token)
		if token ~= request.id or not request.check() or request.ready then return false end
		request.ready = true
		return true
	end
	function request.complete()
		if not request.check() then return false end
		return finish(true)
	end
	if deadline then
		timer_handle = schedule(timeout, function()
			-- The scheduled deadline is authoritative even on coarse clocks.
			finish(false, "timeout")
		end)
	end
	return request
end

return M
