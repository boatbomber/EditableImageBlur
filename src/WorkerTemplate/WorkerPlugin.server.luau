--!strict

-- Plugin-context worker entry (Studio edit mode inside a plugin tree).
-- RunContext ships pre-set in the meta file because writing it at runtime
-- requires plugin capability; the Dispatcher enables only the entry script
-- matching its environment.

local run = require(script.Parent:WaitForChild("Worker") :: ModuleScript) :: (Script) -> ()
run(script)
