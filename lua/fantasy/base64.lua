-- Pure-Lua base64 encoder. Used as the last-resort fallback when
-- vim.base64 is unavailable (all currently released Neovim versions)
-- so attachments work on Windows without GNU coreutils.

local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local M = {}

function M.encode(data)
	-- Process 3-byte groups; pad the final group with '=' as needed.
	local out = {}
	local len = #data
	local i = 1

	while i <= len do
		local c1 = data:byte(i)
		local c2 = data:byte(i + 1)
		local c3 = data:byte(i + 2)

		local n = c1 * 65536 + (c2 or 0) * 256 + (c3 or 0)

		local quad = {
			b64chars:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1),
			b64chars:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1),
			b64chars:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1),
			b64chars:sub(n % 64 + 1, n % 64 + 1),
		}

		if not c2 then
			quad[3], quad[4] = '=', '='
		elseif not c3 then
			quad[4] = '='
		end

		out[#out + 1] = table.concat(quad)
		i = i + 3
	end

	return table.concat(out)
end

return M
