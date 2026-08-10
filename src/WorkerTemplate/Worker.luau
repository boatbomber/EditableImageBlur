--!strict

--[[
	Blur worker body, shared by the context-specific entry scripts
	(WorkerClient, WorkerServer, WorkerPlugin). Writing RunContext at runtime
	requires plugin capability, so the template ships one pre-set entry script
	per context and the Dispatcher enables only the one matching its
	environment; each entry just calls this with itself.

	Messages are handled in a parallel phase, so the blur runs off the main
	thread. The blurred center rows (padding discarded) go back to the
	Dispatcher as a string in the request's SharedTable, and completion is
	signaled by bumping the pool folder's Completed counter attribute from a
	serial phase. No BindableEvents cross the VM boundary.
]]

return function(workerScript: Script)
	local actor = workerScript:GetActor()
	if actor == nil then
		-- A stray copy running outside an Actor.
		return
	end

	local kernelRef = workerScript:WaitForChild("KernelRef") :: ObjectValue
	local Kernel = require(kernelRef.Value :: ModuleScript) :: any

	actor:BindToMessageParallel(
		"Blur",
		function(
			bandIndex: number,
			slice: buffer,
			width: number,
			sliceHeight: number,
			padTop: number,
			centerCount: number,
			sigma: number,
			skipAlpha: boolean,
			results: SharedTable
		)
			local success, problem = pcall(function()
				Kernel.blur(slice, width, sliceHeight, sigma, skipAlpha)
			end)

			if success then
				local stride = width * 4
				results[bandIndex] = buffer.readstring(slice, padTop * stride, centerCount * stride)
			else
				-- The error key is per band so two failing bands cannot race on a
				-- shared slot and hide one of the causes.
				results["error" .. bandIndex] = tostring(problem)
				results[bandIndex] = false
			end
			-- The Dispatcher reads this counter (not the band slots, whose string
			-- payloads would be copied across the VM boundary on every probe) to
			-- decide when a request is finished.
			SharedTable.increment(results, "completed", 1)

			task.synchronize()
			local container = actor.Parent
			if container then
				container:SetAttribute("Completed", (container:GetAttribute("Completed") :: number or 0) + 1)
			end
		end
	)

	-- Signal readiness only after the message handler is bound; messages sent
	-- before binding would be lost.
	actor:SetAttribute("Ready", true)
end
