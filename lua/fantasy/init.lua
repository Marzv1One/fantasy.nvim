-- fantasy.nvim ── JSON-RPC agent client for fantasy-server
--
-- Spawns a long-lived Go process that communicates via JSON-RPC 2.0
-- over stdin/stdout. Streams responses into a floating window.
--
-- Commands:
--   :Fantasy {question}      Ask with visual selection context
--   :FantasyChat {question}  Chat without code context
--   :FantasyPrompt           Multi-line prompt buffer
--   :FantasyOpen             Reopen last response window
--   :FantasyModel {model}    Change model at runtime
--   :FantasyModels           Interactive model picker (fzf-lua)
--   :FantasySystem {prompt}  Change system prompt at runtime
--   :FantasySessions         Fzf picker for sessions
--   :FantasySession {id}     Set active session
--   :FantasyReadSession {id} View session transcript
--   :FantasyNewSession       Create a fresh session
--   :FantasyRename {title}   Rename active session
--   :FantasyAttach {file}    Send file (image/audio) to agent
--   :FantasyCompact [id]     Manually compact session context
--   :FantasyStop             Kill the server process
--
-- Output window:
--   q   close
--   Y   copy full response to clipboard

local M = {}

-- ── Compat ──────────────────────────────────────────────────

local base64_encode
if vim.base64 and vim.base64.encode then
	base64_encode = vim.base64.encode
else
	local ok, lua_b64 = pcall(require, 'fantasy.base64')
	if ok then
		base64_encode = lua_b64.encode
	else
		error 'fantasy: no base64 encoder available'
	end
end

-- ── Config ─────────────────────────────────────────────────

local defaults = {
	server_cmd = 'fantasy-server',
	server_args = {},
	server_cwd = nil, -- defaults to cwd at spawn time
	model = nil, -- override model (or let server default)
	system_prompt = nil, -- override system prompt
	width = 0.85,
	height = 0.85,
	border = 'rounded',
	title = ' fantasy ',
}

local cfg = {}
local state = {
	win = nil,
	buf = nil,
	job_id = nil,
	request_id = 0,
	pending = '', -- partial line buffer for stdout parsing
	streaming = false,
	stream_buf = '',
	active_session_id = nil, -- current session for conversation continuity
	callbacks = {},
}
local prompt_state = { win = nil, buf = nil }
local reader_state = { win = nil, buf = nil } -- for transcript viewer

local ensure_buf -- forward declaration (defined below)

-- ── JSON-RPC Transport ────────────────────────────────────

local function next_id()
	state.request_id = state.request_id + 1
	return state.request_id
end

local function send_request(method, params, callback)
	if not state.job_id then
		vim.notify('fantasy: server not running', vim.log.levels.ERROR)
		return
	end
	local id = next_id()
	local msg = vim.json.encode {
		jsonrpc = '2.0',
		method = method,
		params = params,
		id = id,
	}
	if callback then
		state.callbacks[id] = callback
	end
	vim.fn.chansend(state.job_id, msg .. '\n')
	return id
end

local function send_notification(method, params)
	if not state.job_id then
		return
	end
	local msg = vim.json.encode {
		jsonrpc = '2.0',
		method = method,
		params = params,
	}
	vim.fn.chansend(state.job_id, msg .. '\n')
end

--- Send a JSON-RPC response back to the server (for server-initiated requests).
local function send_response(id, result, err)
	if not state.job_id then
		return
	end
	local resp = { jsonrpc = '2.0', id = id }
	if err then
		resp.error = { code = -32000, message = err }
	else
		resp.result = result
	end
	vim.fn.chansend(state.job_id, vim.json.encode(resp) .. '\n')
end

-- Parse newline-delimited JSON messages from raw stdout chunks.
local function parse_messages(raw)
	local messages = {}
	state.pending = state.pending .. raw

	for line in state.pending:gmatch '([^\n]+)\n' do
		local ok, msg = pcall(vim.json.decode, line)
		if ok and msg then
			table.insert(messages, msg)
		end
	end

	-- Keep anything after the last newline as pending
	local last_nl = state.pending:find '\n[^\n]*$'
	if last_nl then
		state.pending = state.pending:sub(last_nl + 1)
	else
		-- No trailing newline yet; check if the whole thing is a complete JSON
		-- object (edge case where encoder flushed without newline)
		if state.pending ~= '' then
			local ok, msg = pcall(vim.json.decode, state.pending)
			if ok and msg then
				table.insert(messages, msg)
				state.pending = ''
			end
		end
	end

	return messages
end

-- ── Notification Handlers ─────────────────────────────────

local handlers = {}

handlers['chat.textDelta'] = function(params)
	if not state.streaming then
		state.streaming = true
		state.stream_buf = ''
		local buf = ensure_buf()
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
	end
	state.stream_buf = state.stream_buf .. params.text
	local buf = state.buf
	if buf and vim.api.nvim_buf_is_valid(buf) then
		local lines = vim.split(state.stream_buf, '\n')
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		-- Auto-scroll to bottom
		if state.win and vim.api.nvim_win_is_valid(state.win) then
			vim.api.nvim_win_set_cursor(state.win, { #lines, 0 })
		end
	end
end

handlers['chat.toolCall'] = function(params)
	local buf = state.buf
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	vim.bo[buf].modifiable = true
	local line = string.format('\n> **Tool:** `%s`', params.toolName)
	vim.api.nvim_buf_set_lines(buf, -1, -1, false, vim.split(line, '\n'))
end

handlers['chat.toolResult'] = function(params)
	local buf = state.buf
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	local status = params.isError and 'error' or 'ok'
	local line = string.format('> *Result [%s]:* %s', status, params.output or '')
	-- Truncate long outputs in the notification
	if #line > 200 then
		line = line:sub(1, 200) .. '...'
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, -1, -1, false, vim.split(line, '\n'))
end

handlers['chat.stepFinish'] = function(params)
	-- Could update status line or similar
end

handlers['chat.error'] = function(params)
	local buf = state.buf
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, -1, -1, false, {
		'',
		'---',
		'',
		'**Error:** ' .. (params.error or 'unknown'),
	})
end

handlers['file.willChange'] = function(params)
	-- Could show a preview or notification
end

handlers['file.changed'] = function(params)
	vim.schedule(function()
		local path = params.path or ''
		local display = vim.fn.fnamemodify(path, ':.')
		vim.notify('fantasy: wrote ' .. display, vim.log.levels.INFO)
		-- Reload the buffer if it's open. Normalize both sides so Windows
		-- backslash paths from the server match Neovim buffer names.
		local norm = vim.fs and vim.fs.normalize and vim.fs.normalize(path) or path
		local bufnr = vim.fn.bufnr(norm)
		if bufnr == -1 and norm ~= path then
			bufnr = vim.fn.bufnr(path)
		end
		if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
			vim.api.nvim_buf_call(bufnr, function()
				vim.cmd 'edit!'
			end)
		end
	end)
end

handlers['shell.executing'] = function(params)
	local buf = state.buf
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	vim.bo[buf].modifiable = true
	local line = string.format('\n> `$ %s`', params.command)
	vim.api.nvim_buf_set_lines(buf, -1, -1, false, vim.split(line, '\n'))
end

handlers['shell.done'] = function(params)
	-- Already shown via tool result
end

handlers['session.compactProgress'] = function(params)
	local stage = params.stage or '?'
	local detail = params.detail or ''
	local msg = string.format('compact [%s]: %s', stage, detail)
	vim.schedule(function()
		vim.notify('fantasy: ' .. msg, vim.log.levels.INFO)
	end)
end

-- ── Floating Window ───────────────────────────────────────

ensure_buf = function()
	if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
		state.buf = vim.api.nvim_create_buf(false, true)
		vim.bo[state.buf].filetype = 'markdown'
	end
	return state.buf
end

local function close_float()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		vim.api.nvim_win_close(state.win, true)
		state.win = nil
	end
	if state.buf then
		local ok, mv = pcall(require, 'markview.actions')
		if ok then
			pcall(mv.detach, state.buf)
		end
	end
end

-- ── Server Request Handlers ───────────────────────────────

local request_handlers = {}

request_handlers['file.confirm'] = function(params, request_id)
	local path = params.path or ''
	local old_content = params.oldContent or ''
	local new_content = params.newContent or ''
	local rel = vim.fn.fnamemodify(path, ':.')

	vim.schedule(function()
		-- Close Fantasy float if open.
		close_float()

		-- Generate unified diff (vim.diff requires Neovim 0.11+; fall back
		-- to a plain before/after listing on older versions).
		local diff_lines
		if vim.diff then
			local diff_text = vim.diff(old_content .. '\n', new_content .. '\n', { result_type = 'unified', algorithm = 'myers', ctxlen = 3 })
			local header = string.format('--- a/%s\n+++ b/%s', rel, rel)
			diff_lines = vim.split(header .. '\n' .. diff_text, '\n')
		else
			diff_lines = { string.format('--- a/%s (old)', rel), string.format('+++ b/%s (new)', rel), '' }
			for _, l in ipairs(vim.split(old_content, '\n', { plain = true })) do
				table.insert(diff_lines, '-' .. l)
			end
			for _, l in ipairs(vim.split(new_content, '\n', { plain = true })) do
				table.insert(diff_lines, '+' .. l)
			end
		end

		-- Create float buffer.
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, diff_lines)
		vim.bo[buf].filetype = 'diff'
		vim.bo[buf].modifiable = false
		vim.api.nvim_buf_set_name(buf, 'diff: ' .. rel)

		-- Open floating window.
		local w = math.floor(vim.o.columns * 0.85)
		local h = math.floor(vim.o.lines * 0.7)
		local win = vim.api.nvim_open_win(buf, true, {
			relative = 'editor',
			width = w,
			height = h,
			row = math.floor((vim.o.lines - h) / 2),
			col = math.floor((vim.o.columns - w) / 2),
			style = 'minimal',
			border = 'rounded',
			title = ' ' .. rel .. ' ',
			title_pos = 'center',
		})

		-- Cleanup helper.
		local function cleanup()
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
			if vim.api.nvim_buf_is_valid(buf) then
				vim.api.nvim_buf_delete(buf, { force = true })
			end
		end

		-- Keymaps: <CR> to accept, q to cancel.
		local opts = { buffer = buf, nowait = true }
		vim.keymap.set('n', '<CR>', function()
			cleanup()
			send_response(request_id, { accepted = true })
		end, opts)
		vim.keymap.set('n', 'q', function()
			cleanup()
			send_response(request_id, nil, 'cancelled by user')
		end, opts)
	end)
end

request_handlers['shell.confirm'] = function(params, request_id)
	local command = params.command or ''
	local dir = params.dir or ''

	vim.schedule(function()
		close_float()

		local lines = {
			'# Shell Command',
			'',
			'```',
		}
		for _, l in ipairs(vim.split(command, '\n', { plain = true })) do
			table.insert(lines, l)
		end
		table.insert(lines, '```')
		if dir ~= '' then
			table.insert(lines, '')
			table.insert(lines, 'Directory: ' .. dir)
		end
		table.insert(lines, '')
		table.insert(lines, '[<CR>] Execute  [q] Cancel')

		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].filetype = 'markdown'
		vim.bo[buf].modifiable = false

		local w = math.floor(vim.o.columns * 0.6)
		local h = #lines + 2
		local win = vim.api.nvim_open_win(buf, true, {
			relative = 'editor',
			width = w,
			height = h,
			row = math.floor((vim.o.lines - h) / 2),
			col = math.floor((vim.o.columns - w) / 2),
			style = 'minimal',
			border = 'rounded',
			title = ' Execute Shell? ',
			title_pos = 'center',
		})

		local function cleanup()
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
			if vim.api.nvim_buf_is_valid(buf) then
				vim.api.nvim_buf_delete(buf, { force = true })
			end
		end

		local opts = { buffer = buf, nowait = true }
		vim.keymap.set('n', '<CR>', function()
			cleanup()
			send_response(request_id, { accepted = true })
		end, opts)
		vim.keymap.set('n', 'q', function()
			cleanup()
			send_response(request_id, nil, 'cancelled by user')
		end, opts)
	end)
end

local function show_float(content)
	local buf = ensure_buf()
	close_float()

	local lines = type(content) == 'string' and vim.split(content, '\n') or content
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	local w = math.floor(vim.o.columns * cfg.width)
	local h = math.floor(vim.o.lines * cfg.height)

	state.win = vim.api.nvim_open_win(buf, true, {
		relative = 'editor',
		width = w,
		height = h,
		row = math.floor((vim.o.lines - h) / 2),
		col = math.floor((vim.o.columns - w) / 2),
		style = 'minimal',
		border = cfg.border,
		title = cfg.title,
		title_pos = 'center',
	})

	local ok, mv = pcall(require, 'markview.actions')
	if ok then
		pcall(mv.attach, buf)
	end

	local opts = { buffer = buf, nowait = true }
	vim.keymap.set('n', 'q', close_float, opts)
	vim.keymap.set('n', 'Y', function()
		local all = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
		vim.fn.setreg('+', all)
		vim.notify('Copied to clipboard', vim.log.levels.INFO)
	end, opts)
end

-- ── Prompt Buffer ─────────────────────────────────────────

function M.open_prompt_buf()
	if prompt_state.win and vim.api.nvim_win_is_valid(prompt_state.win) then
		vim.api.nvim_set_current_win(prompt_state.win)
		vim.cmd 'startinsert'
		return
	end

	if not (prompt_state.buf and vim.api.nvim_buf_is_valid(prompt_state.buf)) then
		prompt_state.buf = vim.api.nvim_create_buf(false, true)
		vim.bo[prompt_state.buf].buftype = 'nofile'
		vim.bo[prompt_state.buf].filetype = 'markdown'
		vim.api.nvim_buf_set_lines(prompt_state.buf, 0, -1, false, { '' })
	end

	local buf = prompt_state.buf
	local w = math.floor(vim.o.columns * 0.6)
	local h = math.floor(vim.o.lines * 0.3)

	prompt_state.win = vim.api.nvim_open_win(buf, true, {
		relative = 'editor',
		width = w,
		height = h,
		row = math.floor((vim.o.lines - h) / 2),
		col = math.floor((vim.o.columns - w) / 2),
		style = 'minimal',
		border = cfg.border,
		title = state.active_session_id and (' fantasy · ' .. state.active_session_id:sub(1, 8) .. '… ') or ' fantasy prompt ',
		title_pos = 'center',
	})

	local win = prompt_state.win
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = 'no'

	local function submit()
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		while #lines > 0 and lines[#lines]:match '^%s*$' do
			table.remove(lines)
		end
		local text = table.concat(lines, '\n'):gsub('^%s+', ''):gsub('%s+$', '')
		vim.api.nvim_win_close(win, true)
		prompt_state.win = nil
		if text ~= '' then
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '' })
			local sel = M.get_visual_selection()
			if sel then
				M.ask(text) -- uses active session automatically
			else
				M.chat(text) -- uses active session automatically
			end
		end
	end

	local function hide()
		vim.api.nvim_win_close(win, true)
		prompt_state.win = nil
	end

	local opts_map = { buffer = buf, nowait = true }
	vim.keymap.set('i', '<C-CR>', submit, opts_map)
	vim.keymap.set('i', '<S-CR>', submit, opts_map)
	vim.keymap.set('i', '<C-s>', submit, opts_map)
	vim.keymap.set('n', '<C-CR>', submit, opts_map)
	vim.keymap.set('n', '<S-CR>', submit, opts_map)
	vim.keymap.set('n', '<C-s>', submit, opts_map)
	vim.keymap.set('n', '<CR>', submit, opts_map)
	vim.keymap.set('n', 'q', hide, opts_map)
	vim.keymap.set('n', '<Esc>', hide, opts_map)

	vim.cmd 'startinsert'
end

-- ── Visual Selection ──────────────────────────────────────

function M.get_visual_selection()
	local ok_s, s = pcall(vim.fn.getpos, "'<")
	local ok_e, e = pcall(vim.fn.getpos, "'>")
	if not ok_s or not ok_e then
		return nil
	end

	local sl, el = s[2], e[2]
	local lines = vim.api.nvim_buf_get_lines(0, sl - 1, el, false)
	if #lines == 0 then
		return nil
	end

	local last_line = vim.fn.getline(el)
	local linewise = s[3] == 1 and e[3] >= #last_line

	if not linewise then
		local sc, ec = s[3], e[3]
		if #lines == 1 then
			lines[1] = lines[1]:sub(sc, ec)
		else
			lines[1] = lines[1]:sub(sc)
			lines[#lines] = lines[#lines]:sub(1, ec)
		end
	end

	return { lines = lines, start = sl, stop = el }
end

local function build_context(sel)
	local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':.')
	local ft = vim.bo.filetype
	local lang = ft ~= '' and ft or ''
	local fence = '```' .. lang

	return string.format(
		'File: %s (lines %d-%d)\nLanguage: %s\n\n%s\n%s\n```',
		path,
		sel.start,
		sel.stop,
		lang ~= '' and lang or 'unknown',
		fence,
		table.concat(sel.lines, '\n')
	)
end

-- ── Server Lifecycle ──────────────────────────────────────

local function start_server()
	if state.job_id then
		return true
	end

	local cwd = cfg.server_cwd or vim.fn.getcwd()
	local cmd = { cfg.server_cmd }
	vim.list_extend(cmd, cfg.server_args)

	state.pending = ''
	state.callbacks = {}

	state.job_id = vim.fn.jobstart(cmd, {
		cwd = cwd,
		stdin = 'pipe',
		on_stdout = function(_, data, _)
			vim.schedule(function()
				if not data or #data == 0 then
					return
				end
				local raw = table.concat(data, '\n')
				local messages = parse_messages(raw)
				for _, msg in ipairs(messages) do
					if msg.id and msg.method then
						-- Server-initiated request (has both id and method).
						local handler = request_handlers[msg.method]
						if handler then
							handler(msg.params or {}, msg.id)
						else
							send_response(msg.id, nil, 'unknown method: ' .. msg.method)
						end
					elseif msg.id and msg.result then
						-- Response to a request
						local cb = state.callbacks[msg.id]
						if cb then
							cb(msg.result)
							state.callbacks[msg.id] = nil
						end
						-- Finalize streaming
						state.streaming = false
						local buf = state.buf
						if buf and vim.api.nvim_buf_is_valid(buf) then
							vim.bo[buf].modifiable = false
						end
					elseif msg.id and msg.error then
						-- Error response
						state.callbacks[msg.id] = nil
						state.streaming = false
						local buf = state.buf
						if buf and vim.api.nvim_buf_is_valid(buf) then
							vim.bo[buf].modifiable = true
							vim.api.nvim_buf_set_lines(buf, -1, -1, false, {
								'',
								'**Error:** ' .. (msg.error.message or vim.inspect(msg.error)),
							})
							vim.bo[buf].modifiable = false
						end
					elseif msg.method then
						-- Notification
						local handler = handlers[msg.method]
						if handler then
							handler(msg.params or {})
						end
					end
				end
			end)
		end,
		on_stderr = function(_, data, _)
			-- Server logs to stderr, show in :messages if debug
			if data then
				for _, line in ipairs(data) do
					if line ~= '' then
						vim.schedule(function()
							vim.notify('fantasy: ' .. line, vim.log.levels.DEBUG)
						end)
					end
				end
			end
		end,
		on_exit = function(_, code, _)
			vim.schedule(function()
				state.job_id = nil
				state.callbacks = {}
				if code ~= 0 then
					vim.notify('fantasy: server exited (code ' .. code .. ')', vim.log.levels.WARN)
				end
			end)
		end,
	})

	if state.job_id <= 0 then
		state.job_id = nil
		vim.notify('fantasy: failed to start server', vim.log.levels.ERROR)
		return false
	end

	-- Sync cwd to server
	send_request('set.cwd', { cwd = vim.fn.getcwd() })

	-- Set model if configured
	if cfg.model then
		send_request('set.model', { model = cfg.model })
	end
	if cfg.system_prompt then
		send_request('set.systemPrompt', { prompt = cfg.system_prompt })
	end

	return true
end

local function stop_server()
	if state.job_id then
		vim.fn.jobstop(state.job_id)
		state.job_id = nil
		state.callbacks = {}
	end
end

-- ── Public API ────────────────────────────────────────────

--- Send a prompt with visual selection context.
---@param question string
---@param session_id? string override active session
function M.ask(question, session_id)
	local sel = M.get_visual_selection()
	if not sel then
		vim.notify('fantasy: no visual selection', vim.log.levels.WARN)
		return
	end

	if not start_server() then
		return
	end

	local ctx = build_context(sel)
	local prompt = ctx .. '\n\n' .. question
	M._send(prompt, session_id)
end

--- Chat without code context.
---@param question string
---@param session_id? string override active session
function M.chat(question, session_id)
	if not start_server() then
		return
	end
	M._send(question, session_id)
end

--- Internal: send a prompt to the agent, handling session continuity.
---@param prompt string
---@param session_id? string
function M._send(prompt, session_id)
	if not start_server() then
		return
	end

	local sid = session_id or state.active_session_id

	state.streaming = false
	state.stream_buf = ''
	show_float { '# Thinking…', '', 'Waiting for response.' }

	local params = { prompt = prompt }
	if sid then
		params.sessionId = sid
	end

	send_request('chat.send', params, function(result)
		vim.schedule(function()
			-- Track the session for continuity.
			if result and result.sessionId then
				state.active_session_id = result.sessionId
			end
			if result and result.usage then
				local buf = state.buf
				if buf and vim.api.nvim_buf_is_valid(buf) then
					vim.bo[buf].modifiable = true
					local sid_label = result.sessionId and result.sessionId:sub(1, 8) or '?'
					local footer =
						string.format('\n\n---\n*Session:* `%s…` · *Tokens:* %d in / %d out', sid_label, result.usage.inputTokens or 0, result.usage.outputTokens or 0)
					vim.api.nvim_buf_set_lines(buf, -1, -1, false, vim.split(footer, '\n'))
					vim.bo[buf].modifiable = false
				end
			end
		end)
	end)
end

--- Reopen last response window.
function M.open()
	if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
		vim.notify('fantasy: no previous buffer to reopen', vim.log.levels.WARN)
		return
	end
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		vim.api.nvim_set_current_win(state.win)
		return
	end
	show_float(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false))
end

-- ── Session Management ─────────────────────────────────────

--- Set the active session ID.
---@param id string
function M.set_session(id)
	state.active_session_id = id
	vim.notify('fantasy: session → ' .. id:sub(1, 8) .. '…', vim.log.levels.INFO)
end

--- Create a new session and set it as active.
--- The session is created up front (via session.create) so it appears in
--- :FantasySessions even before the first message is sent.
function M.new_session()
	if not start_server() then
		return
	end
	send_request('session.create', {}, function(result)
		vim.schedule(function()
			if result and result.id then
				state.active_session_id = result.id
				vim.notify('fantasy: new session ' .. result.id:sub(1, 8) .. '…', vim.log.levels.INFO)
			else
				state.active_session_id = nil
				vim.notify('fantasy: new session (will be created on next message)', vim.log.levels.INFO)
			end
		end)
	end)
end

--- Get the active session ID.
---@return string|nil
function M.get_session_id()
	return state.active_session_id
end

--- Fzf picker for sessions. Pre-fetches all session data for previews.
function M.pick_session()
	if not start_server() then
		return
	end

	local ok, fzf = pcall(require, 'fzf-lua')
	if not ok then
		vim.notify('fzf-lua not available', vim.log.levels.ERROR)
		return
	end

	send_request('session.list', { limit = 30 }, function(sessions)
		vim.schedule(function()
			if not sessions or type(sessions) ~= 'table' or #sessions == 0 then
				vim.notify('fantasy: no sessions found', vim.log.levels.WARN)
				return
			end
			M._open_session_picker(sessions, fzf)
		end)
	end)
end

--- Internal: open the fzf picker once data is ready.
function M._open_session_picker(sessions, fzf)
	local items = {}
	for _, s in ipairs(sessions) do
		local active = s.id == state.active_session_id and ' *' or ''
		local title = s.title ~= '' and s.title or 'Untitled'
		local line = string.format('%s | %s%s', s.id, title, active)
		table.insert(items, line)
	end

	local function extract_sid(str)
		return str:match '^([^%s]+)'
	end

	fzf.fzf_exec(items, {
		prompt = 'Fantasy Sessions> ',
		actions = {
			['default'] = function(selected)
				local sid = extract_sid(selected[1])
				if sid then
					M.set_session(sid)
				end
			end,
			['ctrl-x'] = function(selected)
				local sid = extract_sid(selected[1])
				if not sid then
					return
				end
				local cur_title = selected[1]:match '|%s*(.-)%s*%*?$' or ''
				local choice = vim.fn.confirm('Delete session "' .. cur_title .. '"?', '&Yes\n&No', 2)
				if choice ~= 1 then
					return
				end
				send_request('session.delete', { id = sid }, function()
					vim.schedule(function()
						vim.notify('fantasy: deleted ' .. sid:sub(1, 8), vim.log.levels.INFO)
						if state.active_session_id == sid then
							state.active_session_id = nil
						end
					end)
				end)
			end,
			['ctrl-o'] = function(selected)
				local sid = extract_sid(selected[1])
				if not sid then
					return
				end

				local LIMIT = 5
				send_request('session.get', { id = sid, offset = 0, limit = LIMIT }, function(data)
					vim.schedule(function()
						if not data or not data.messages or #data.messages == 0 then
							vim.notify('fantasy: no messages in session', vim.log.levels.WARN)
							return
						end

						local total = data.total or #data.messages
						local fetch_offset = math.max(0, total - LIMIT)

						local function show_preview(messages)
							local lines = M._format_messages(data.session, messages)

							local buf = vim.api.nvim_create_buf(false, true)
							vim.bo[buf].filetype = 'markdown'
							vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
							vim.bo[buf].modifiable = false

							local ok_mv, mv = pcall(require, 'markview.actions')
							if ok_mv then
								pcall(mv.attach, buf)
							end

							local w = math.floor(vim.o.columns * 0.85)
							local h = math.floor(vim.o.lines * 0.85)
							local win = vim.api.nvim_open_win(buf, true, {
								relative = 'editor',
								width = w,
								height = h,
								row = math.floor((vim.o.lines - h) / 2),
								col = math.floor((vim.o.columns - w) / 2),
								style = 'minimal',
								border = cfg.border,
								title = ' last ' .. #messages .. ' messages ',
								title_pos = 'center',
							})

							vim.keymap.set('n', 'q', function()
								if vim.api.nvim_win_is_valid(win) then
									vim.api.nvim_win_close(win, true)
								end
								if vim.api.nvim_buf_is_valid(buf) then
									vim.api.nvim_buf_delete(buf, { force = true })
								end
								vim.schedule(function()
									fzf.resume()
								end)
							end, { buffer = buf, nowait = true })
						end

						if fetch_offset == 0 then
							-- Session has <= LIMIT messages, we already have them.
							show_preview(data.messages)
						else
							-- Fetch the tail.
							send_request('session.get', { id = sid, offset = fetch_offset, limit = LIMIT }, function(tail_data)
								vim.schedule(function()
									local msgs = (tail_data and tail_data.messages) and tail_data.messages or data.messages
									show_preview(msgs)
								end)
							end)
						end
					end)
				end)
			end,
			['ctrl-r'] = function(selected)
				local sid = extract_sid(selected[1])
				if not sid then
					return
				end
				-- Extract current title from the selected line for the default value.
				local cur_title = selected[1]:match '|%s*(.-)%s*%*?$' or ''
				vim.ui.input({ prompt = 'Rename session ▸ ', default = cur_title }, function(input)
					if input and input ~= '' then
						M.rename_session(input, sid)
					end
				end)
			end,
		},
	})
end

--- Format session + messages into markdown lines.
--- Each line is guaranteed to be a single line (no embedded newlines).
---@param session table|nil
---@param messages table[]
---@return string[]
function M._format_messages(session, messages)
	local lines = {}
	if session then
		local title = session.title ~= '' and session.title or 'Untitled'
		table.insert(lines, '# ' .. title)
		table.insert(lines, '')
		table.insert(lines, string.format('*Session:* `%s` · *Model:* %s', session.id, session.model or '?'))
		table.insert(lines, '')
	end

	for _, msg in ipairs(messages) do
		local role = msg.role or 'unknown'
		local icon = role == 'user' and 'U' or role == 'assistant' and 'A' or role == 'tool' and 'T' or '?'
		local label = role:sub(1, 1):upper() .. role:sub(2)

		table.insert(lines, '')
		table.insert(lines, string.format('## %s **%s**', icon, label))
		table.insert(lines, '')

		local content = msg.content or ''
		if content ~= '' then
			-- Normalize line endings and split.
			content = content:gsub('\r\n', '\n'):gsub('\r', '\n')
			for _, l in ipairs(vim.split(content, '\n', { plain = true })) do
				table.insert(lines, l)
			end
		end

		if msg.toolName and msg.toolName ~= '' then
			table.insert(lines, string.format('> Tool: `%s`', msg.toolName))
		end
	end

	return lines
end

--- Open the session transcript in a floating window.
--- Loads messages in chunks to keep Neovim responsive.
---@param session_id? string defaults to active session
function M.read_session(session_id)
	session_id = session_id or state.active_session_id
	if not session_id then
		vim.notify('fantasy: no session_id and no active session', vim.log.levels.WARN)
		return
	end

	if not start_server() then
		return
	end

	-- Close existing reader
	if reader_state.win and vim.api.nvim_win_is_valid(reader_state.win) then
		vim.api.nvim_win_close(reader_state.win, true)
		reader_state.win = nil
	end

	local CHUNK = 5

	-- Fetch first chunk (includes session header).
	send_request('session.get', { id = session_id, offset = 0, limit = CHUNK }, function(data)
		vim.schedule(function()
			local empty = { '# No messages', '', 'Session `' .. session_id .. '` has no messages.' }
			if not data or not data.messages or #data.messages == 0 then
				-- Show empty state in a float.
				if not (reader_state.buf and vim.api.nvim_buf_is_valid(reader_state.buf)) then
					reader_state.buf = vim.api.nvim_create_buf(false, true)
				end
				vim.api.nvim_buf_set_lines(reader_state.buf, 0, -1, false, empty)
				vim.bo[reader_state.buf].modifiable = false
			end

			local total = data.total or #data.messages
			local first_lines = M._format_messages(data.session, data.messages)

			-- Create / reuse buffer.
			if not (reader_state.buf and vim.api.nvim_buf_is_valid(reader_state.buf)) then
				reader_state.buf = vim.api.nvim_create_buf(false, true)
			end

			vim.bo[reader_state.buf].modifiable = true
			vim.api.nvim_buf_set_lines(reader_state.buf, 0, -1, false, first_lines)

			-- Open float.
			local w = math.floor(vim.o.columns * 0.85)
			local h = math.floor(vim.o.lines * 0.85)

			reader_state.win = vim.api.nvim_open_win(reader_state.buf, true, {
				relative = 'editor',
				width = w,
				height = h,
				row = math.floor((vim.o.lines - h) / 2),
				col = math.floor((vim.o.columns - w) / 2),
				style = 'minimal',
				border = cfg.border,
				title = ' session transcript ',
				title_pos = 'center',
			})

			local buf = reader_state.buf
			local opts = { buffer = buf, nowait = true }
			local cancelled = false

			vim.keymap.set('n', 'q', function()
				cancelled = true
				if reader_state.win and vim.api.nvim_win_is_valid(reader_state.win) then
					vim.api.nvim_win_close(reader_state.win, true)
					reader_state.win = nil
				end
			end, opts)
			vim.keymap.set('n', 'r', function()
				cancelled = true
				M.read_session(session_id)
			end, opts)

			-- Load remaining chunks incrementally.
			local offset = CHUNK
			local function load_next()
				if cancelled or offset >= total then
					-- Finalize: set filetype, lock buffer, attach markview.
					if vim.api.nvim_buf_is_valid(buf) then
						vim.bo[buf].filetype = 'markdown'
						vim.bo[buf].modifiable = false
						local ok, mv = pcall(require, 'markview.actions')
						if ok then
							pcall(mv.attach, buf)
						end
					end
					return
				end

				send_request('session.get', { id = session_id, offset = offset, limit = CHUNK }, function(chunk)
					vim.schedule(function()
						if cancelled or not vim.api.nvim_buf_is_valid(buf) then
							return
						end
						if not chunk or not chunk.messages or #chunk.messages == 0 then
							-- No more messages — finalize.
							vim.bo[buf].filetype = 'markdown'
							vim.bo[buf].modifiable = false
							local ok, mv = pcall(require, 'markview.actions')
							if ok then
								pcall(mv.attach, buf)
							end
							return
						end

						local chunk_lines = M._format_messages(nil, chunk.messages)
						vim.api.nvim_buf_set_lines(buf, -1, -1, false, chunk_lines)
						offset = offset + #chunk.messages
						load_next()
					end)
				end)
			end

			load_next()
		end)
	end)
end

--- Change model at runtime.
---@param model string
---@param role? string  -- "primary" (default), "small", or "multimodal"
function M.set_model(model, role)
	cfg.model = model
	if state.job_id then
		send_request('set.model', { model = model, role = role or '' }, function(result)
			vim.schedule(function()
				vim.notify('fantasy: model → ' .. (result.model or model), vim.log.levels.INFO)
			end)
		end)
	end
end

--- Interactive model picker: select role then select model.
function M.pick_models()
	if not start_server() then
		return
	end

	local ok, fzf = pcall(require, 'fzf-lua')
	if not ok then
		vim.notify('fzf-lua not available', vim.log.levels.ERROR)
		return
	end

	send_request('get.models', {}, function(data)
		vim.schedule(function()
			if not data then
				vim.notify('fantasy: failed to fetch models', vim.log.levels.ERROR)
				return
			end

			local roles = { 'primary', 'small', 'multimodal' }
			local role_items = {}
			for _, r in ipairs(roles) do
				table.insert(role_items, string.format('%-12s %s', r, data[r] or '(none)'))
			end

			fzf.fzf_exec(role_items, {
				prompt = 'Select role> ',
				actions = {
					['default'] = function(selected)
						local role = selected[1]:match '^(%S+)'
						if not role then
							return
						end

						local models = {}
						for id, info in pairs(data.available or {}) do
							local ctx = info.contextWindow and string.format('%.0fK', info.contextWindow / 1000) or '?'
							table.insert(models, string.format('%-40s  %s ctx', id, ctx))
						end
						table.sort(models)

						fzf.fzf_exec(models, {
							prompt = role .. ' model> ',
							actions = {
								['default'] = function(sel)
									local model_id = sel[1]:match '^(%S+)'
									if model_id then
										M.set_model(model_id, role)
									end
								end,
							},
						})
					end,
				},
			})
		end)
	end)
end

--- Change system prompt at runtime.
---@param prompt string
function M.set_system_prompt(prompt)
	cfg.system_prompt = prompt
	if state.job_id then
		send_request('set.systemPrompt', { prompt = prompt })
	end
end

--- Manually trigger context compaction for a session.
---@param session_id? string  -- defaults to active session
function M.compact_session(session_id)
	local sid = session_id or state.active_session_id
	if not sid then
		vim.notify('fantasy: no session_id and no active session', vim.log.levels.WARN)
		return
	end
	if not start_server() then
		return
	end
	send_request('session.compact', { id = sid }, function(result)
		vim.schedule(function()
			vim.notify('fantasy: session compacted ' .. sid:sub(1, 8) .. '…', vim.log.levels.INFO)
		end)
	end)
end

--- Rename a session.
---@param title string
---@param session_id? string  -- defaults to active session
function M.rename_session(title, session_id)
	local sid = session_id or state.active_session_id
	if not sid then
		vim.notify('fantasy: no session_id and no active session', vim.log.levels.WARN)
		return
	end
	if not start_server() then
		return
	end
	send_request('session.rename', { id = sid, title = title }, function(result)
		vim.schedule(function()
			vim.notify('fantasy: renamed → ' .. (result.title or title), vim.log.levels.INFO)
		end)
	end)
end

--- Attach a file (image/audio) and send with a prompt.
---@param filepaths string[]  -- one or more file paths
---@param prompt? string      -- optional text prompt
function M.attach_and_send(filepaths, prompt)
	if not start_server() then
		return
	end

	local mime_map = {
		png = 'image/png',
		jpg = 'image/jpeg',
		jpeg = 'image/jpeg',
		gif = 'image/gif',
		webp = 'image/webp',
		wav = 'audio/wav',
		mp3 = 'audio/mpeg',
		mpeg = 'audio/mpeg',
	}

	local files = {}
	for _, path in ipairs(filepaths) do
		local abs = vim.fn.fnamemodify(path, ':p')
		local f = io.open(abs, 'rb')
		if not f then
			vim.notify('fantasy: cannot read ' .. path, vim.log.levels.ERROR)
			return
		end
		local data = f:read '*a'
		f:close()

		local ext = abs:match '%.([^%.]+)$' or ''
		local mime = mime_map[ext:lower()] or 'application/octet-stream'

		table.insert(files, {
			filename = vim.fn.fnamemodify(abs, ':t'),
			data = base64_encode(data),
			mediaType = mime,
		})
	end

	prompt = prompt or ''
	if prompt == '' then
		prompt = 'Analyze the attached file(s).'
	end

	M._send_with_files(prompt, files)
end

--- Internal: send with file attachments.
function M._send_with_files(prompt, files)
	if not start_server() then
		return
	end

	local sid = state.active_session_id
	state.streaming = false
	state.stream_buf = ''
	show_float { '# Thinking…', '', 'Sending with attachments.' }

	local params = { prompt = prompt, files = files }
	if sid then
		params.sessionId = sid
	end

	send_request('chat.send', params, function(result)
		vim.schedule(function()
			if result and result.sessionId then
				state.active_session_id = result.sessionId
			end
			if result and result.usage then
				local buf = state.buf
				if buf and vim.api.nvim_buf_is_valid(buf) then
					vim.bo[buf].modifiable = true
					local sid_label = result.sessionId and result.sessionId:sub(1, 8) or '?'
					local footer =
						string.format('\n\n---\n*Session:* `%s…` · *Tokens:* %d in / %d out', sid_label, result.usage.inputTokens or 0, result.usage.outputTokens or 0)
					vim.api.nvim_buf_set_lines(buf, -1, -1, false, vim.split(footer, '\n'))
					vim.bo[buf].modifiable = false
				end
			end
		end)
	end)
end

-- ── Setup ─────────────────────────────────────────────────

function M.setup(user_cfg)
	cfg = vim.tbl_deep_extend('force', defaults, user_cfg or {})

	local rn = { range = true, nargs = '*' }

	vim.api.nvim_create_user_command('Fantasy', function(o)
		local args = o.args:gsub('^%s+', ''):gsub('%s+$', '')
		if args ~= '' then
			M.ask(args)
		else
			vim.ui.input({ prompt = 'Fantasy ▸ ' }, function(input)
				if input and input ~= '' then
					M.ask(input)
				end
			end)
		end
	end, rn)

	vim.api.nvim_create_user_command('FantasyChat', function(o)
		local args = o.args:gsub('^%s+', ''):gsub('%s+$', '')
		if args ~= '' then
			M.chat(args)
		else
			vim.ui.input({ prompt = 'Fantasy Chat ▸ ' }, function(input)
				if input and input ~= '' then
					M.chat(input)
				end
			end)
		end
	end, rn)

	vim.api.nvim_create_user_command('FantasyPrompt', M.open_prompt_buf, {})
	vim.api.nvim_create_user_command('FantasyOpen', M.open, {})
	vim.api.nvim_create_user_command('FantasyStop', stop_server, {})
	vim.api.nvim_create_user_command('FantasyNewSession', M.new_session, {})
	vim.api.nvim_create_user_command('FantasySessions', M.pick_session, {})
	vim.api.nvim_create_user_command('FantasyReadSession', function(o)
		local sid = o.args:gsub('^%s+', ''):gsub('%s+$', '')
		if sid ~= '' then
			M.read_session(sid)
		else
			M.read_session()
		end
	end, { nargs = '?' })

	vim.api.nvim_create_user_command('FantasySession', function(o)
		local sid = o.args:gsub('^%s+', ''):gsub('%s+$', '')
		if sid ~= '' then
			M.set_session(sid)
		else
			vim.notify('active session: ' .. tostring(state.active_session_id), vim.log.levels.INFO)
		end
	end, { nargs = '?' })

	vim.api.nvim_create_user_command('FantasyModel', function(o)
		local model = o.args:gsub('^%s+', ''):gsub('%s+$', '')
		if model ~= '' then
			M.set_model(model)
		else
			vim.ui.input({ prompt = 'Model ▸ ' }, function(input)
				if input and input ~= '' then
					M.set_model(input)
				end
			end)
		end
	end, { nargs = '?' })

	vim.api.nvim_create_user_command('FantasyModels', function()
		M.pick_models()
	end, {})

	vim.api.nvim_create_user_command('FantasySystem', function(o)
		local prompt = o.args:gsub('^%s+', ''):gsub('%s+$', '')
		if prompt ~= '' then
			M.set_system_prompt(prompt)
		else
			vim.ui.input({ prompt = 'System prompt ▸ ' }, function(input)
				if input and input ~= '' then
					M.set_system_prompt(input)
				end
			end)
		end
	end, { nargs = '?' })

	vim.api.nvim_create_user_command('FantasyCompact', function(o)
		local sid = o.args:gsub('^%s+', ''):gsub('%s+$', '')
		if sid ~= '' then
			M.compact_session(sid)
		else
			M.compact_session()
		end
	end, { nargs = '?' })

	vim.api.nvim_create_user_command('FantasyRename', function(o)
		local title = o.args:gsub('^%s+', ''):gsub('%s+$', '')
		if title == '' then
			vim.ui.input({ prompt = 'Rename session ▸ ' }, function(input)
				if input and input ~= '' then
					M.rename_session(input)
				end
			end)
		else
			M.rename_session(title)
		end
	end, { nargs = '?' })

	vim.api.nvim_create_user_command('FantasyAttach', function(o)
		local args = o.args:gsub('^%s+', ''):gsub('%s+$', '')
		if args == '' then
			-- Use vim.ui.input for file paths
			vim.ui.input({ prompt = 'File paths (comma-separated) ▸ ' }, function(input)
				if input and input ~= '' then
					local paths = {}
					for p in input:gmatch '[^,]+' do
						table.insert(paths, vim.trim(p))
					end
					vim.ui.input({ prompt = 'Prompt (optional) ▸ ' }, function(prompt)
						M.attach_and_send(paths, prompt ~= '' and prompt or nil)
					end)
				end
			end)
		else
			-- First arg is file path(s), rest is prompt
			local parts = {}
			for p in args:gmatch '%S+' do
				table.insert(parts, p)
			end
			local paths = { parts[1] }
			local prompt = #parts > 1 and table.concat(parts, ' ', 2) or nil
			M.attach_and_send(paths, prompt)
		end
	end, {
		nargs = '*',
		complete = function(arg_lead, cmd_line, cursor_pos)
			local completions = vim.fn.getcompletion(arg_lead, 'file')
			if #completions > 0 then
				return completions
			end
			return {}
		end,
	})

	-- Sync cwd to server on directory change
	vim.api.nvim_create_autocmd('DirChanged', {
		group = vim.api.nvim_create_augroup('fantasy-cwd', { clear = true }),
		callback = function()
			if state.job_id then
				send_request('set.cwd', { cwd = vim.fn.getcwd() })
			end
		end,
	})

	-- Start server eagerly so it's ready when first used
	vim.defer_fn(function()
		start_server()
	end, 100)
end

return M
