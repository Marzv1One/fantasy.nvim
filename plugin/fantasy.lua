-- Minimal bootstrap: the plugin is configured via require('fantasy').setup().
-- Kept as a separate file so lazy-loading plugin managers can safely
-- `dir = ...` without executing the full module until setup() runs.

if vim.g.loaded_fantasy then
	return
end
vim.g.loaded_fantasy = 1
