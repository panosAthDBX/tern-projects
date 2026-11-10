--!strict
-- Local macOS install: build through the mbx-managed Cargo shim into the
-- indexer's own target; plugin data holds only the source fingerprint stamp.
local backend = {}
local building = false
local ready: string? = nil
local waiters: { (string?, string?) -> () } = {}
local root = tern.plugin.data .. "/backend"
local indexer = tern.plugin.dir .. "/indexer"
local executable = indexer .. "/target/release/tern-projects"

local function diagnostics(output: string): string
	local errors = {}
	for line in output:gmatch("[^\r\n]+") do
		if line:find("error:", 1, true) or line:match("^error%[") then
			table.insert(errors, (line:gsub("^%s+", "")))
		end
	end
	return if #errors > 0 then table.concat(errors, "\n") else output
end

local function inputs(): string
	local files = { "lib/backend.luau", "indexer/Cargo.toml", "indexer/Cargo.lock" }
	local function visit(dir: string)
		for _, name in tern.fs.list(tern.plugin.dir .. "/" .. dir) do
			local path = dir .. "/" .. name
			if name:sub(-3) == ".rs" then
				table.insert(files, path)
			elseif not name:find("%.") then
				visit(path)
			end
		end
	end
	visit("indexer/src")
	table.sort(files)
	local values = { tern.runtime.os }
	for _, path in files do
		table.insert(values, path)
		table.insert(values, tern.fs.read(tern.plugin.dir .. "/" .. path))
	end
	return tern.json.encode(values)
end

function backend.status(): string?
	return building and "Building Rust backend…" or nil
end

function backend.ensure(cb: (string?, string?) -> ())
	-- mbx may evict the managed target; rebuild rather than hand out a missing binary.
	if ready and tern.fs.exists(ready) then cb(ready, nil); return end
	ready = nil
	if building then table.insert(waiters, cb); return end
	local home = tern.getenv("HOME") or ""
	if tern.runtime.os ~= "macos" or home == "" then
		cb(nil, "This installation builds the backend only on macOS with HOME set (mbx-managed Cargo).")
		return
	end
	local ok, source = pcall(inputs)
	if not ok then cb(nil, "Cannot read backend sources: " .. tostring(source)); return end
	local cached, stamp = pcall(tern.fs.read, root .. "/inputs.json")
	if cached and stamp == source and tern.fs.exists(executable) then
		ready = executable
		cb(ready, nil)
		return
	end
	local shimDir = home .. "/Library/Application Support/mbx/bin"
	local localBin = home .. "/.local/bin"
	local cargo = shimDir .. "/cargo"
	local check = localBin .. "/mbx-check"
	for _, tool in { cargo, check } do
		if not tern.fs.exists(tool) then
			cb(nil, "Missing mbx tool " .. tool .. ". Install mbx, then Refresh to retry.")
			return
		end
	end
	-- `tern.process.run` extends the inherited environment with `env`.
	-- mbx must also find rustup's real Cargo when the GUI host PATH omits it.
	local cargoHome = tern.getenv("CARGO_HOME") or (home .. "/.cargo")
	local pathEntries = { shimDir, localBin, cargoHome .. "/bin" }
	local currentPath = tern.getenv("PATH") or ""
	if currentPath ~= "" then table.insert(pathEntries, currentPath) end
	table.insert(pathEntries, "/usr/bin")
	table.insert(pathEntries, "/bin")
	local envPath = table.concat(pathEntries, ":")
	building = true
	table.insert(waiters, cb)
	local finished = false
	local function finish(path: string?, err: string?)
		if finished then return end
		finished = true
		building = false
		ready = path
		local pending = waiters
		waiters = {}
		-- One waiter raising must not withhold the build result from the rest.
		for _, done in pending do
			local ok, failure = pcall(done, path, err)
			if not ok then tern.log.error("Project backend waiter failed: " .. tostring(failure)) end
		end
	end
	local function compile(env: { [string]: string })
		local started, err = pcall(tern.process.run, { cargo, "build", "--release", "--locked", "--manifest-path", indexer .. "/Cargo.toml" }, { timeout_ms = 1200000, env = env }, function(result)
			if finished then return end
			if result.status ~= 0 or result.timed_out then
				tern.log.error("Cargo build output:\n" .. result.stdout .. result.stderr)
				local detail = if result.timed_out then "Build timed out after 20 minutes." else diagnostics(if result.stderr ~= "" then result.stderr else result.stdout)
				if detail == "" then detail = "Cargo exited with status " .. tostring(result.status) .. "." end
				finish(nil, "Backend build failed. " .. detail .. "\nRefresh to retry. Full compiler output is in Tern's log.")
				return
			end
			if not tern.fs.exists(executable) then finish(nil, "Cargo succeeded but the backend executable is missing: " .. executable); return end
			local saved, saveErr = pcall(tern.fs.write, root .. "/inputs.json", source)
			if not saved then finish(nil, "Cannot save backend build state: " .. tostring(saveErr)); return end
			finish(executable, nil)
		end)
		if not started then finish(nil, "Cannot start mbx Cargo. Check mbx, then Refresh to retry: " .. tostring(err)) end
	end
	-- mbx-check gates every build with the same environment Cargo will see.
	local function precheck(env: { [string]: string })
		local started, err = pcall(tern.process.run, { check, indexer }, { timeout_ms = 60000, env = env }, function(result)
			if finished then return end
			if result.status ~= 0 or result.timed_out then
				local output = result.stdout .. result.stderr
				tern.log.error("mbx-check refused backend build:\n" .. output)
				local detail = if result.timed_out then "mbx-check timed out after 60 seconds." else output
				finish(nil, "mbx-check refused the backend build. " .. detail .. "\nRefresh to retry.")
				return
			end
			compile(env)
		end)
		if not started then finish(nil, "Cannot start mbx-check. Check mbx, then Refresh to retry: " .. tostring(err)) end
	end
	local function prepare()
		tern.fs.mkdir(root)
		-- Keep the SDK and compiler in the selected Apple toolchain, not a mix
		-- of PATH's cc/linker and a newer Command Line Tools SDK chosen by rustc.
		tern.process.run({ "/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path" }, { timeout_ms = 10000 }, function(result)
			if finished then return end
			local sdk = (result.stdout:gsub("^%s+", ""):gsub("%s+$", ""))
			if result.status ~= 0 or result.timed_out or sdk == "" then
				local detail = if result.timed_out then "xcrun timed out after 10 seconds." else result.stderr
				finish(nil, "Cannot select a macOS SDK. Install or select Apple developer tools, then Refresh to retry. " .. detail)
				return
			end
			precheck({
				SDKROOT = sdk,
				CC = "/usr/bin/clang",
				PATH = envPath,
				CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER = "/usr/bin/clang",
				CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER = "/usr/bin/clang",
			})
		end)
	end
	-- mbx-check canonicalizes its argument; Cargo must receive that same path
	-- or a linked plugin can create a second target owner for one checkout.
	local started, err = pcall(tern.process.run, { "/bin/realpath", indexer }, { timeout_ms = 10000 }, function(result)
		if finished then return end
		local resolved = result.stdout:gsub("[\r\n]+$", "")
		if result.status ~= 0 or result.timed_out or resolved:sub(1, 1) ~= "/" then
			finish(nil, "Cannot resolve the backend workspace. " .. result.stderr .. "\nRefresh to retry.")
			return
		end
		indexer = resolved
		executable = indexer .. "/target/release/tern-projects"
		local ok, failure = pcall(prepare)
		if not ok then finish(nil, "Cannot prepare backend build: " .. tostring(failure)) end
	end)
	if not started then finish(nil, "Cannot resolve backend workspace: " .. tostring(err)) end
end

return backend
