-- `vera --lsp` for Neovim 0.11+. Put editors/nvim on 'runtimepath' and call
-- vim.lsp.enable('vera'). Neovim already detects .va/.vams as `verilogams`.
return {
  cmd = { 'vera', '--lsp' },
  filetypes = { 'verilogams' },
  root_markers = { '.vera-flags', '.git' },
}
