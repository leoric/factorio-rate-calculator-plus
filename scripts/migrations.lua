-- flib_migration was deprecated in favor of helpers.compare_versions and Lua migration files,
-- and has since been removed from flib entirely. Reimplemented locally.
local by_version = {
  ["3.0.0"] = function()
    for _, player in pairs(game.players) do
      for _, child in pairs(player.gui.screen.children) do
        if child.get_mod() == "RateCalculator" or child.get_mod() == "RateCalculatorPlus" then
          child.destroy()
        end
      end
    end
    storage = { gui = {} }
  end,
}

--- @param e ConfigurationChangedData
local function on_configuration_changed(e)
  local change = e.mod_changes[script.mod_name]
  if not change or not change.old_version then
    return
  end
  local old_version = change.old_version

  local versions = {}
  for version in pairs(by_version) do
    versions[#versions + 1] = version
  end
  table.sort(versions, function(a, b)
    return helpers.compare_versions(a, b) < 0
  end)

  for _, version in ipairs(versions) do
    if helpers.compare_versions(old_version, version) < 0 then
      by_version[version]()
    end
  end
end

local migrations = {}

migrations.on_configuration_changed = on_configuration_changed

return migrations
