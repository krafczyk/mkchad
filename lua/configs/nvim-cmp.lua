local luasnip = require('luasnip')
local cmp = require('cmp')
local lspkind = require('lspkind')

local cmp_enabled = true

-- Copilot behavior customization section
local CopilotMode = {
  DISABLED = 'disabled',
  ENABLED = 'enabled',
  ALWAYS = 'always',
}

local CopilotState = {
  session_copilot_allow = false,
  session_copilot_default = CopilotMode.DISABLED,
}

vim.api.nvim_create_user_command('CopilotReportManagerState', function()
  -- Print the current state of the Copilot manager
  local msg = "Copilot Manager State:\n"
  for k, v in pairs(CopilotState) do
    msg = msg .. k .. ": " .. tostring(v) .. "\n"
  end
  msg = msg .. "vim.b.copilot_mode: " .. tostring(vim.b.copilot_mode) .. "\n"
  print(msg)
end, { desc = "Print the current state of the Copilot manager." })

local cmp_sources_wo_copilot = {
  { name = "nvim_lsp" },
  { name = "luasnip" },
  { name = "buffer" },
  { name = "nvim_lua" },
  { name = "async_path" },
}

local cmp_sources_w_copilot = {
  { name = "copilot" , priority = 100 }, -- Unsure if this is the right priority level
  { name = "nvim_lsp" },
  { name = "luasnip" },
  { name = "buffer" },
  { name = "nvim_lua" },
  { name = "async_path" },
}

-- Initialization of nvim-cmp
cmp.setup {
  enabled = function()
    return cmp_enabled
  end,
  snippet = {
    expand = function(args)
      -- vim.snippet.expand(args.body) -- For native neovim snippets
      luasnip.lsp_expand(args.body) -- For LuaSnip users
    end,
  },
  window = {
    completion = cmp.config.window.bordered(),
    documentation = cmp.config.window.bordered(),
  },
  view = {
    entries = {name = 'custom', selection_order = 'near_cursor' },
  },
  mapping = cmp.mapping.preset.insert({
    ['<C-d>'] = cmp.mapping.scroll_docs(-4),
    ['<C-f>'] = cmp.mapping.scroll_docs(4),
    ['<C-space>'] = cmp.mapping.complete(),
    ['<CR>'] = cmp.mapping(function(fallback)
      if cmp.visible() then
        if luasnip.expandable() then
          luasnip.expand()
        else
          cmp.confirm({
            select = true,
          })
        end
      else
        fallback()
      end
    end),
    ['<Tab>'] = cmp.mapping(function(fallback)
      if cmp.visible() then
        cmp.select_next_item()
      elseif luasnip.locally_jumpable(1) then
        luasnip.jump(1)
      else
        fallback()
      end
    end, { "i", "s" }),
    ["<S-Tab>"] = cmp.mapping(function(fallback)
      if cmp.visible() then
        cmp.select_prev_item()
      elseif luasnip.locally_jumpable(-1) then
        luasnip.jump(-1)
      else
        fallback()
      end
    end, { "i", "s" }),
  }),
  sources = cmp.config.sources(cmp_sources_wo_copilot),
  matching = {
    disallow_fuzzy_matching = false,
  },
  formatting = {
    format = lspkind.cmp_format({
      mode = "symbol_text",
      ellipsis_char = "...",
      menu = ({
        copilot = "[Copilot]",
        buffer = "[Buffer]",
        nvim_lsp = "[LSP]",
        luasnip = "[LuaSnip]",
        nvim_lua = "[Lua]",
        async_path = "[Path]",
        --latex_symbols = "[Latex]",
      })
    }),
  },
}

-- Function to toggle nvim-cmp
function ToggleCmp()
    cmp_enabled = not cmp_enabled
    if cmp_enabled then
        print("nvim-cmp enabled")
    else
        print("nvim-cmp disabled")
    end
end

-- Keymap to toggle cmp
vim.api.nvim_set_keymap('n', '<leader>ct', ':lua ToggleCmp()<CR>', { noremap = true, silent = true })

-- Method to update cmp sources given the current Copilot state
local function set_cmp_sources(copilot)
  local cur_cmp = require('cmp')
  cur_cmp.abort() -- Aborting completion session
  if copilot then
    cur_cmp.setup({
      sources = cmp_sources_w_copilot
    })
  else
    cur_cmp.setup({
      sources = cmp_sources_wo_copilot
    })
  end
end

local function update_cmp_sources()
  -- Check whether copilot is allowed for the session
  if not CopilotState.session_copilot_allow then
    set_cmp_sources(false)
  end

  -- Check whether a buffer has variable tracking its copilot mode
  if vim.b.copilot_mode == nil then
    vim.b.copilot_mode = CopilotState.session_copilot_default
  end

  -- Otherwise we only set copilot as a source if it is on 'ALWAYS' mode.
  if vim.b.copilot_mode == CopilotMode.DISABLED or vim.b.copilot_mode == CopilotMode.ENABLED then
    set_cmp_sources(false)
  else
    set_cmp_sources(true)
  end
end

-- Helper function for protecting accidental enablement.
local function copilot_session_enable(prompt, quiet)
  if not CopilotState.session_copilot_allow then
    if prompt then
      vim.ui.input({ prompt = "Copilot is globally disabled. Are you sure you want to enable it? (y/n): " }, function(input)
        if input and string.lower(input) == "y" then
          CopilotState.session_copilot_allow = true
          if not quiet then
            print("Copilot globally enabled.")
          end
        else
          if not quiet then
            print("Operation canceled. Copilot remains globally disabled.")
          end
        end
      end)
    end
  else
    if not quiet then
      print("Copilot is already globally enabled.")
    end
  end
  update_cmp_sources()
end

-- Commands to enable/disable the session
vim.api.nvim_create_user_command('CopilotSessionEnable', function()
  copilot_session_enable(true, false)
end, { desc = "Enable copilot globally for the current session."})

vim.api.nvim_create_user_command('CopilotSessionDisable', function()
  if not CopilotState.session_copilot_allow then
    print("Copilot already disabled globally.")
  else
    CopilotState.session_copilot_allow = false
    print("Copilot now disabled globally.")
  end
  update_cmp_sources()
end, { desc = "Disable copilot globally for the current session."})

vim.api.nvim_create_user_command('CopilotSessionOptIn', function()
  copilot_session_enable(true, false)
  CopilotState.session_copilot_default = CopilotMode.DISABLED
end, { desc = "Set current session to opt-in for copilot." })

vim.api.nvim_create_user_command('CopilotSessionOptOut', function()
  copilot_session_enable(true, false)
  CopilotState.session_copilot_default = CopilotMode.ALWAYS
end, { desc = "Set the current session to opt-out for copilot." })

vim.api.nvim_create_user_command('CopilotBufferEnable', function()
  if not CopilotState.session_copilot_allow then
    print("Cannot enable. Copilot is currently disabled globally.")
  else
    if CopilotState.session_copilot_default == CopilotMode.DISABLED and vim.b.copilot_mode == CopilotMode.DISABLED then
      vim.ui.input({ prompt = "Copilot is currently Opt In. Are you sure you want to enable it for this buffer? (y/n): "}, function(input)
        if input and string.lower(input) == "y" then
          vim.b.copilot_mode = CopilotMode.ENABLED
          print("Copilot enabled for this buffer.")
        else
          print("Operation canceled. Copilot remains disabled for this buffer.")
        end
      end)
    else
      vim.b.copilot_mode = CopilotState.session_copilot_default
      print("Copilot enabled for this buffer.")
    end
  end
  update_cmp_sources()
end, { desc = "Enable copilot for the current buffer." })

vim.api.nvim_create_user_command('CopilotBufferSetEnable', function()
  if not CopilotState.session_copilot_allow then
    print("Cannot enable. Copilot is currently disabled globally.")
  else
    if CopilotState.session_copilot_default == CopilotMode.DISABLED and vim.b.copilot_mode == CopilotMode.DISABLED then
      vim.ui.input({ prompt = "Copilot is currently Opt In. Are you sure you want to enable it for this buffer? (y/n): "}, function(input)
        if input and string.lower(input) == "y" then
          vim.b.copilot_mode = CopilotMode.ENABLED
          print("Copilot enabled for this buffer.")
        else
          print("Operation canceled. Copilot remains disabled for this buffer.")
        end
      end)
    else
      vim.b.copilot_mode = CopilotMode.ENABLED
      print("Copilot enabled for this buffer.")
    end
  end
  update_cmp_sources()
end, { desc = "Set copilot mode to ENABLED for the current buffer." })


vim.api.nvim_create_user_command('CopilotBufferAlways', function()
  if not CopilotState.session_copilot_allow then
    print("Cannot enable. Copilot is currently disabled globally.")
  else
    if CopilotState.session_copilot_default == CopilotMode.DISABLED and vim.b.copilot_mode == CopilotMode.DISABLED then
      vim.ui.input({ prompt = "Copilot is currently Opt In. Are you sure you want to enable it for this buffer? (y/n): "}, function(input)
        if input and string.lower(input) == "y" then
          vim.b.copilot_mode = CopilotMode.ALWAYS
          print("Copilot enabled for this buffer.")
        else
          print("Operation canceled. Copilot remains disabled for this buffer.")
        end
      end)
    else
      vim.b.copilot_mode = CopilotMode.ALWAYS
      print("Copilot enabled for this buffer.")
    end
  end
  update_cmp_sources()
end, { desc = "Turn copilot on all the time for the current buffer." })

vim.api.nvim_create_user_command('CopilotBufferDisable', function()
  if not CopilotState.session_copilot_allow then
    print("No need to do anything. Copilot is currently disabled globally.")
  else
    vim.b.copilot_mode = CopilotMode.DISABLED
    print("Copilot disabled for this buffer.")
  end
  update_cmp_sources()
end, { desc = "Disable copilot for the current buffer." })

-- Command to manually request Copilot completion
local function trigger_copilot_complete()
  -- Check if Copilot is enabled (globally or for the buffer)
  if not CopilotState.session_copilot_allow or vim.b.copilot_mode == CopilotMode.DISABLED then
    print("Copilot is not enabled for this session or buffer.")
  end

  -- Request a new completion
  local cur_cmp = require('cmp')
  cur_cmp.abort()
  cmp.complete({
    config = {
      sources = cmp_sources_w_copilot,
    },
    reason = cmp.ContextReason.Manual,
  })
end

vim.keymap.set('i', '<C-c>', trigger_copilot_complete, { noremap = true, silent = true, desc = "Trigger a completion with copilot"})
