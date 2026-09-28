-- :checkhealth fantasy

local M = {}

local function check(name, ok, msg)
	if ok then
		vim.health.ok(name .. ': ' .. msg)
	else
		vim.health.error(name .. ': ' .. msg)
	end
end

function M.check()
	vim.health.start 'fantasy'

	-- Neovim version (vim.diff requires 0.11+ for unified diffs)
	if vim.diff then
		vim.health.ok 'vim.diff available (Neovim 0.11+), unified diffs enabled'
	else
		vim.health.warn 'vim.diff not available (Neovim < 0.11); file edits will show a plain before/after listing'
	end

	-- base64 encoder
	if vim.base64 and vim.base64.encode then
		vim.health.ok 'vim.base64 available'
	else
		local ok, lua_b64 = pcall(require, 'fantasy.base64')
		if ok then
			vim.health.ok 'using bundled pure-Lua base64 encoder'
		else
			vim.health.error 'no base64 encoder available; :FantasyAttach will fail'
		end
	end

	-- Server binary on PATH
	local server_bin = 'fantasy-server'
	if vim.fn.executable(server_bin) == 1 then
		vim.health.ok(server_bin .. ' found on PATH')
	else
		vim.health.error(
			server_bin .. ' not found on PATH; build it from the fantasy-server repo with `go build -o fantasy-server.exe .` or set opts.server_cmd'
		)
	end

	-- Optional dependencies
	local ok_fzf = pcall(require, 'fzf-lua')
	check('fzf-lua', ok_fzf, ok_fzf and 'found (:FantasySessions, :FantasyModels available)' or 'missing (:FantasySessions, :FantasyModels unavailable)')

	local ok_mv = pcall(require, 'markview')
	check('markview.nvim', ok_mv, ok_mv and 'found (markdown rendering enabled)' or 'missing (responses render as plain text)')

	-- Live ping if the plugin is configured
	local ok_plugin, fantasy = pcall(require, 'fantasy')
	if not ok_plugin then
		vim.health.error('failed to load lua/fantasy/init.lua: ' .. tostring(fantasy))
		return
	end

	local sid = fantasy.get_session_id and fantasy.get_session_id() or nil
	if sid then
		vim.health.ok('active session: ' .. sid:sub(1, 8) .. '…')
	else
		vim.health.info 'no active session yet (created on first message)'
	end
end

return M
