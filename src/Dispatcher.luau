--!strict

--[[
	Internal actor pool for the parallel blur path. The consumer never touches
	an Actor: on first use this module clones the package's WorkerTemplate into
	a runtime bin (ServerScriptService on the server, PlayerScripts on the
	client), one Actor per worker, and scatters padded row bands to them via
	Actor:SendMessage.

	Results come back through the two channels sanctioned for crossing VM
	boundaries (BindableEvents are deliberately not used, per
	https://create.roblox.com/docs/scripting/multithreading):
	- payload: each worker stores its blurred center rows into a per-request
	  SharedTable, as a string since SharedTables cannot hold buffers;
	- completion: each worker bumps a counter attribute on the pool folder
	  from its serial phase, which this module listens to and uses to re-check
	  every in-flight request.

	Every request carries a unique requestId so overlapping or out-of-order
	calls cannot cross-contaminate results. Any worker failure or timeout makes
	blurAsync return false and the caller falls back to the synchronous kernel.
]]

local RunService = game:GetService("RunService")

local Kernel = require(script.Parent.Kernel)
local Bands = require(script.Parent.Bands)

local WORKER_START_TIMEOUT = 5
local REQUEST_TIMEOUT = 10

type Pending = {
	thread: thread,
	bandCount: number,
	results: SharedTable,
	timeoutThread: thread?,
	timedOut: boolean,
}

local Dispatcher = {}

local pool: { Actor } = {}
local container: Folder? = nil
local poolBroken = false
local poolInitializing = false
local nextRequestId = 0
local pendingByRequestId: { [number]: Pending } = {}
local warnedFallbackClasses: { [string]: boolean } = {}

-- Warns once per failure class. A transient failure (a timeout under load)
-- therefore cannot silence the diagnostic for a later, differently-caused
-- one (a worker error, a broken pool).
local function warnFallbackOnce(class: string, reason: string)
	if warnedFallbackClasses[class] then
		return
	end
	warnedFallbackClasses[class] = true
	warn("EditableImageBlur: parallel blur unavailable (" .. reason .. "), falling back to synchronous blur")
end

-- Wakes every request whose bands have all reported in. Runs on each bump of
-- the pool folder's Completed counter; re-checking every in-flight request
-- makes missed or coalesced attribute events harmless. Completion is read
-- from each request's own counter; probing the band slots instead would
-- materialize their payload strings across the VM boundary on every bump.
local function wakeFinishedRequests()
	local finished: { number } = {}
	for requestId, pending in pendingByRequestId do
		if pending.results.completed == pending.bandCount then
			table.insert(finished, requestId)
		end
	end

	for _, requestId in finished do
		local pending = pendingByRequestId[requestId]
		pendingByRequestId[requestId] = nil
		if pending.timeoutThread then
			task.cancel(pending.timeoutThread)
		end
		task.spawn(pending.thread)
	end
end

local function getWorkerBin(): (Instance, string)
	if not RunService:IsRunning() then
		-- Studio edit mode: only Plugin-context scripts execute, and only
		-- when they live inside a plugin's tree. Parenting the workers into
		-- the package module itself keeps them in plugin context when the
		-- package is part of a plugin; anywhere else they can never start,
		-- so fail fast here instead of paying the worker-start timeout.
		if script:FindFirstAncestorOfClass("Plugin") == nil then
			error("Studio edit mode outside a plugin tree, where workers cannot run")
		end
		return script.Parent :: Instance, "WorkerPlugin"
	elseif RunService:IsServer() then
		return game:GetService("ServerScriptService"), "WorkerServer"
	else
		local player = game:GetService("Players").LocalPlayer
		return player:WaitForChild("PlayerScripts"), "WorkerClient"
	end
end

local function createWorker(parent: Folder, workerName: string): Actor
	local template = (script.Parent :: Instance):FindFirstChild("WorkerTemplate")
	assert(template and template:IsA("Actor"), "EditableImageBlur is missing its WorkerTemplate")
	local actor = template:Clone()

	local workerScript = actor:FindFirstChild(workerName) :: Script
	assert(
		workerScript and workerScript:IsA("Script"),
		"EditableImageBlur's WorkerTemplate is missing its " .. workerName .. " script"
	)

	-- Writing RunContext at runtime requires plugin capability, so the
	-- template ships one pre-set entry script per context; drop the ones for
	-- the other contexts. (ModuleScripts are not "Script"s, so the shared
	-- worker body survives this.)
	for _, child in actor:GetChildren() do
		if child ~= workerScript and child:IsA("Script") then
			child:Destroy()
		end
	end

	-- The clone loses its place in the package tree, so hand it an explicit
	-- reference to the kernel module to require from its own VM.
	local kernelRef = Instance.new("ObjectValue")
	kernelRef.Name = "KernelRef"
	kernelRef.Value = script.Parent:FindFirstChild("Kernel")
	kernelRef.Parent = workerScript

	actor.Parent = parent
	workerScript.Disabled = false

	return actor
end

-- Grows the pool to at least `count` workers. Yields until they are all
-- bound and ready. Returns false if workers could not be started.
local function ensurePool(count: number): boolean
	-- A concurrent call may already be growing the pool; wait for it to finish
	-- before deciding whether more growth is needed.
	while poolInitializing do
		task.wait()
	end
	if poolBroken then
		-- Workers could not start at all once already (for example edit mode
		-- outside a plugin); don't make every call re-pay the startup cost.
		return false
	end

	-- Prune workers whose actors were destroyed or unparented (for example a
	-- cleanup script wiping the runtime bin), so the pool rebuilds instead of
	-- sending messages to destroyed actors.
	if container and container.Parent == nil then
		container = nil
	end
	for index = #pool, 1, -1 do
		if container == nil or pool[index].Parent == nil then
			table.remove(pool, index)
		end
	end

	if #pool >= count then
		return true
	end

	poolInitializing = true
	local success, problem = pcall(function()
		local bin, workerName = getWorkerBin()
		if not container then
			local folder = Instance.new("Folder")
			folder.Name = "EditableImageBlurWorkers"
			folder:SetAttribute("Completed", 0)
			folder:GetAttributeChangedSignal("Completed"):Connect(wakeFinishedRequests)
			folder.Parent = bin
			container = folder
		end
		local folder = container :: Folder

		local created = table.create(count - #pool)
		for _ = #pool + 1, count do
			created[#created + 1] = createWorker(folder, workerName)
		end

		-- Workers set the Ready attribute from their serial startup after
		-- binding their message handler; messages sent before that are lost.
		-- Ready workers are adopted into the pool as they come up; any still
		-- not ready at the deadline are destroyed.
		local deadline = os.clock() + WORKER_START_TIMEOUT
		while #created > 0 do
			for index = #created, 1, -1 do
				if created[index]:GetAttribute("Ready") == true then
					pool[#pool + 1] = created[index]
					table.remove(created, index)
				end
			end
			if #created == 0 then
				break
			end
			if os.clock() > deadline then
				local missing = #created
				for _, actor in created do
					actor:Destroy()
				end
				error(missing .. " worker(s) did not start within " .. WORKER_START_TIMEOUT .. " seconds")
			end
			task.wait()
		end
	end)

	poolInitializing = false

	if not success then
		-- Latch the permanent sync fallback only when the environment clearly
		-- cannot run workers at all; if some workers did start, the next call
		-- retries the deficit.
		if #pool == 0 then
			poolBroken = true
		end
		warnFallbackOnce("startup", tostring(problem))
		return false
	end
	return true
end

--[[
	Blurs the buffer in place using the worker pool. Yields until all bands
	come back. Returns true on success; false when the parallel path is
	unavailable (edit mode, image too short to band, worker failure/timeout),
	in which case the caller should blur synchronously instead.
]]
function Dispatcher.blurAsync(
	pixels: buffer,
	width: number,
	height: number,
	sigma: number,
	skipAlpha: boolean,
	workerCount: number
): boolean
	local support = Kernel.supportForSigma(sigma)
	local bands = Bands.compute(height, support, workerCount)
	if #bands < 2 then
		return false
	end

	if not ensurePool(#bands) then
		return false
	end

	nextRequestId += 1
	local requestId = nextRequestId
	local stride = width * 4
	local results = SharedTable.new()
	results.completed = 0

	local pending: Pending = {
		thread = coroutine.running(),
		bandCount = #bands,
		results = results,
		timeoutThread = nil,
		timedOut = false,
	}
	pendingByRequestId[requestId] = pending

	for index, band in bands do
		local sliceHeight = Bands.sliceHeight(band)
		local slice = buffer.create(sliceHeight * stride)
		buffer.copy(slice, 0, pixels, Bands.sliceStart(band) * stride, sliceHeight * stride)

		-- ensurePool guaranteed at least #bands workers.
		local actor = pool[index]
		actor:SendMessage(
			"Blur",
			index,
			slice,
			width,
			sliceHeight,
			band.padTop,
			band.centerCount,
			sigma,
			skipAlpha,
			results
		)
	end

	pending.timeoutThread = task.delay(REQUEST_TIMEOUT, function()
		local timedOut = pendingByRequestId[requestId]
		if timedOut then
			pendingByRequestId[requestId] = nil
			timedOut.timedOut = true
			task.spawn(timedOut.thread)
		end
	end)

	coroutine.yield()

	if pending.timedOut then
		warnFallbackOnce("timeout", "request timed out after " .. REQUEST_TIMEOUT .. " seconds")
		return false
	end

	-- Splice each band's center rows back into the master buffer. Workers
	-- store a false sentinel (plus a per-band error message) when their
	-- kernel call failed. Validation completes for every band before any
	-- write: the sync fallback blurs the caller's buffer in place, so a
	-- partial splice would leave rows that get double-blurred. Payloads are
	-- kept in locals between the two loops because every SharedTable string
	-- read materializes a fresh cross-VM copy.
	local payloads: { string } = table.create(#bands)
	for index, band in bands do
		local payload = results[index]
		if type(payload) ~= "string" or #payload ~= band.centerCount * stride then
			warnFallbackOnce("worker-error", "worker error: " .. tostring(results["error" .. index]))
			return false
		end
		payloads[index] = payload
	end
	for index, band in bands do
		buffer.writestring(pixels, band.centerStart * stride, payloads[index])
	end
	return true
end

return Dispatcher
