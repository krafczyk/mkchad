-- Credits to original https://github.com/altercation/solarized
-- This is modified version of it

local M = {}

-- #af5f00 -- line number color in the original theme.

-- Save original colors
--  white = "#657b83",
--  darker_black = "#fdf6e3",
--  black = "#eee8d5", --  nvim bg
--  black2 = "#d6e1c7",
--  one_bg = "#c5d4bf", -- real bg of onelight
--  one_bg2 = "#b4c8b7",
--  one_bg3 = "#a3bcad",
--  grey = "#93a1a1",
--  grey_fg = "#839496",
--  grey_fg2 = "#72888c",
--  light_grey = "#618281",
--  red = "#dc322f",
--  baby_pink = "#eb413e",
--  pink = "#d33682",
--  line = "#c3d3c9", -- for lines like vertsplit
--  green = "#859900",
--  vibrant_green = "#b2c62d",
--  nord_blue = "#197ec5",
--  blue = "#268bd2",
--  yellow = "#b58900",
--  sun = "#c4980f",
--  purple = "#6c71c4",
--  dark_purple = "#5d62b5",
--  teal = "#519ABA",
--  orange = "#cb4b16",
--  cyan = "#2aa198",
--  statusline_bg = "#d9e0d7",
--  lightbg = "#e6ebe4",
--  pmenu_bg = "#268bd2",
--  folder_bg = "#268bd2",

M.base_30 = {
white = "#657b83",
darker_black = "#fdf6e3",
black = "#f7f0e0", --  nvim bg
black2 = "#f2ecdb",
one_bg = "#eee8d5", -- real bg of onelight
one_bg2 = "#ddd6c1",
one_bg3 = "#d3cbb7",
grey = "#93a1a1",
grey_fg = "#839496",
grey_fg2 = "#72888c",
light_grey = "#618281",
red = "#dc322f",
baby_pink = "#eb413e",
pink = "#d33682",
line = "#c3d3c9", -- for lines like vertsplit
green = "#859900",
vibrant_green = "#b2c62d",
nord_blue = "#197ec5",
blue = "#268bd2",
yellow = "#b58900",
sun = "#c4980f",
purple = "#6c71c4",
dark_purple = "#5d62b5",
teal = "#519ABA",
orange = "#cb4b16",
cyan = "#2aa198",
statusline_bg = "#d9e0d7",
lightbg = "#e6ebe4",
pmenu_bg = "#268bd2",
folder_bg = "#268bd2",
}

M.base_16 = {
base00 = "#fdf6e3", -- Default bg
base01 = "#ddd6c1", -- Lighter bg (status bar, line number, folding mks)
base02 = "#eee8d5", -- Selection bg possible alternative: #f2ecdb
base03 = "#93a1a1", -- Comments, invisibles, line hl #c5d4bf
base04 = "#a89e84", -- Dark fg (status bars)
base05 = "#657b83", -- Default fg (caret, delimiters, Operators)
base06 = "#839496", -- Light fg (not often used)
base07 = "#93a1a1", -- Light bg (not often used)
base08 = "#dc322f", -- Variables, XML Tags, Markup Link Text, Markup Lists, Diff Deleted
base09 = "#cb4b16", -- Integers, Boolean, Constants, XML Attributes, Markup Link Url
base0A = "#b58900", -- Classes, Markup Bold, Search Text Background
base0B = "#859900", -- Strings, Inherited Class, Markup Code, Diff Inserted
base0C = "#2aa198", -- Support, regex, escape chars
base0D = "#268bd2", -- Function, methods, headings
base0E = "#6c71c4", -- Keywords
base0F = "#d33682", -- Deprecated, open/close embedded tags
}

M.type = "light"

M = require("base46").override_theme(M, "solarized_light")

return M
