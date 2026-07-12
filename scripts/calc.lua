local calc_util = require("scripts.calc-util")
local calc_cache = require("scripts.calc-cache")

local gui = require("scripts.gui")

--- @class Set<T>: { [T]: boolean }

--- @alias CalculationError
--- | "max-crafting-speed"
--- | "incompatible-science-packs"
--- | "no-active-research"
--- | "no-input-fluid"
--- | "no-fuel"
--- | "no-mineable-resources"
--- | "no-power"
--- | "no-recipe"

--- @class CalculationSet
--- @field completed Set<string>
--- @field entities table<string, LuaEntity>
--- @field entity_rates table<string, table<string, Rates>>
--- @field errors Set<CalculationError>
--- @field fully_limited_rates table<string, Rates>?
--- @field limited_rates table<string, Rates>?
--- @field limited_logistics_data LogisticsData?
--- @field logistics_data LogisticsData?
--- @field logistics_limited_rates table<string, Rates>?
--- @field player LuaPlayer
--- @field rates table<string, Rates>
--- @field selection_area_tiles uint
--- @field selection_area_width uint
--- @field selection_area_height uint
--- @field research_data ResearchData?
--- @field pollutant string

--- @alias MachineCounts table<string, double>

--- @class Rate
--- @field machine_counts MachineCounts
--- @field machines double
--- @field rate double

--- @class Rates
--- @field type string
--- @field name string
--- @field quality string?
--- @field temperature double?
--- @field output Rate
--- @field input Rate

--- @class ResearchData
--- @field ingredients Ingredient[]
--- @field multiplier double
--- @field speed_modifier double

--- @param player LuaPlayer
--- @return CalculationSet
local function new_calculation_set(player)
  local force = player.force
  local current_research = force.current_research
  --- @type ResearchData?
  local research_data
  if current_research then
    research_data = {
      ingredients = current_research.research_unit_ingredients,
      multiplier = 1 / (current_research.research_unit_energy / 60),
      speed_modifier = force.laboratory_speed_modifier,
    }
  end
  local pollutant = ""
  local pollutant_prototype = player.surface.pollutant_type
  if pollutant_prototype then
    pollutant = pollutant_prototype.name
  end
  return {
    completed = {},
    entities = {},
    entity_rates = {},
    errors = {},
    fully_limited_rates = nil,
    limited_rates = nil,
    limited_logistics_data = nil,
    logistics_data = nil,
    logistics_limited_rates = nil,
    player = player,
    rates = {},
    selection_area_tiles = 0,
    selection_area_width = 0,
    selection_area_height = 0,
    research_data = research_data,
    pollutant = pollutant,
  }
end

local entity_blacklist = {
  -- Transport Drones
  ["buffer-depot"] = true,
  ["fluid-depot"] = true,
  ["fuel-depot"] = true,
  ["request-depot"] = true,
}

--- @param set CalculationSet
--- @param entity LuaEntity
local function process_entity(set, entity)
  if entity_blacklist[entity.name] then
    return
  end

  local emissions_per_second = entity.prototype.emissions_per_second[set.pollutant] or 0
  local type = entity.type

  if type == "burner-generator" or type == "generator" then
    calc_util.add_rate(
      set,
      "output",
      "item",
      "rcalc-power-dummy",
      "normal",
      entity.prototype.get_max_power_output(entity.quality) * 60,
      false,
      entity.name
    )
  elseif type ~= "burner-generator" and entity.prototype.electric_energy_source_prototype then
    emissions_per_second = calc_util.process_electric_energy_source(set, entity, false, emissions_per_second)
  elseif entity.prototype.fluid_energy_source_prototype then
    emissions_per_second = calc_util.process_fluid_energy_source(set, entity, false, emissions_per_second)
  elseif entity.prototype.heat_energy_source_prototype then
    calc_util.process_heat_energy_source(set, entity, false)
  end

  if entity.burner then
    emissions_per_second = calc_util.process_burner(set, entity, false, emissions_per_second)
  end

  if type == "assembling-machine" or type == "furnace" or type == "rocket-silo" then
    emissions_per_second = calc_util.process_crafter(set, entity, false, emissions_per_second)
  elseif type == "beacon" then
    calc_util.process_beacon(set, entity)
  elseif type == "boiler" then
    calc_util.process_boiler(set, entity, false)
  elseif type == "lab" then
    calc_util.process_lab(set, entity, false)
  elseif type == "generator" then
    calc_util.process_generator(set, entity, false)
  elseif type == "mining-drill" then
    calc_util.process_mining_drill(set, entity, false)
  elseif type == "offshore-pump" then
    calc_util.process_offshore_pump(set, entity, false)
  elseif type == "reactor" then
    calc_util.process_reactor(set, entity, false)
  end

  if emissions_per_second > 0 then
    calc_util.add_rate(
      set,
      "output",
      "item",
      "rcalc-pollution-dummy",
      "normal",
      emissions_per_second,
      false,
      entity.name
    )
  elseif emissions_per_second < 0 then
    calc_util.add_rate(
      set,
      "input",
      "item",
      "rcalc-pollution-dummy",
      "normal",
      -emissions_per_second,
      false,
      entity.name
    )
  end
end

--- @param source Rate
--- @return Rate
local function copy_rate(source)
  local machine_counts = {}
  for machine_name, count in pairs(source.machine_counts) do
    machine_counts[machine_name] = count
  end
  return {
    machine_counts = machine_counts,
    machines = source.machines,
    rate = source.rate,
  }
end

--- @param source Rates
--- @return Rates
local function copy_rates(source)
  return {
    type = source.type,
    name = source.name,
    quality = source.quality,
    temperature = source.temperature,
    output = copy_rate(source.output),
    input = copy_rate(source.input),
  }
end

--- @param target table<string, Rates>
--- @param source table<string, Rates>
local function merge_rates(target, source)
  for path, source_rates in pairs(source) do
    local target_rates = target[path]
    if not target_rates then
      target[path] = copy_rates(source_rates)
      goto continue
    end

    target_rates.output.rate = target_rates.output.rate + source_rates.output.rate
    target_rates.output.machines = target_rates.output.machines + source_rates.output.machines
    for machine_name, count in pairs(source_rates.output.machine_counts) do
      target_rates.output.machine_counts[machine_name] = (target_rates.output.machine_counts[machine_name] or 0) + count
    end

    target_rates.input.rate = target_rates.input.rate + source_rates.input.rate
    target_rates.input.machines = target_rates.input.machines + source_rates.input.machines
    for machine_name, count in pairs(source_rates.input.machine_counts) do
      target_rates.input.machine_counts[machine_name] = (target_rates.input.machine_counts[machine_name] or 0) + count
    end

    ::continue::
  end
end

--- @param entity LuaEntity
--- @return string
local function get_entity_key(entity)
  local unit_number = entity.unit_number
  if unit_number then
    return "u/" .. unit_number
  end
  local position = entity.position
  return string.format(
    "p/%d/%d/%s/%.3f/%.3f",
    entity.surface.index,
    entity.force.index,
    entity.name,
    position.x,
    position.y
  )
end

--- @param set CalculationSet
--- @param entities LuaEntity[]
--- @param invert boolean
local function update_selected_entities(set, entities, invert)
  local selected_entities = set.entities
  for _, entity in pairs(entities) do
    local key = get_entity_key(entity)
    if invert then
      selected_entities[key] = nil
    else
      selected_entities[key] = entity
    end
  end
end

--- @param set CalculationSet
local function update_selection_area(set)
  local min_x, min_y
  local max_x, max_y
  for entity_key, entity in pairs(set.entities) do
    if not entity.valid then
      set.entities[entity_key] = nil
      goto continue
    end

    local selection_box = entity.selection_box or entity.bounding_box
    local left_top = selection_box.left_top
    local right_bottom = selection_box.right_bottom
    min_x = min_x and math.min(min_x, left_top.x) or left_top.x
    min_y = min_y and math.min(min_y, left_top.y) or left_top.y
    max_x = max_x and math.max(max_x, right_bottom.x) or right_bottom.x
    max_y = max_y and math.max(max_y, right_bottom.y) or right_bottom.y

    ::continue::
  end

  if not min_x or not min_y or not max_x or not max_y then
    set.selection_area_width = 0
    set.selection_area_height = 0
    set.selection_area_tiles = 0
    return
  end

  local width = math.max(math.ceil(max_x) - math.floor(min_x), 0)
  local height = math.max(math.ceil(max_y) - math.floor(min_y), 0)
  set.selection_area_width = width
  set.selection_area_height = height
  set.selection_area_tiles = width * height
end

--- @param set CalculationSet
local function recalculate_set(set)
  set.entity_rates = {}
  set.errors = {}
  set.rates = {}
  calc_cache.invalidate(set)

  update_selection_area(set)

  for entity_key, entity in pairs(set.entities) do
    if not entity.valid then
      goto continue
    end

    --- @type CalculationSet
    local entity_set = {
      completed = {},
      entities = {},
      entity_rates = {},
      errors = set.errors,
      fully_limited_rates = nil,
      limited_rates = nil,
      limited_logistics_data = nil,
      logistics_data = nil,
      logistics_limited_rates = nil,
      player = set.player,
      rates = {},
      research_data = set.research_data,
      pollutant = set.pollutant,
    }
    process_entity(entity_set, entity)
    set.entity_rates[entity_key] = entity_set.rates
    merge_rates(set.rates, entity_set.rates)

    ::continue::
  end
end

--- @param set CalculationSet
--- @param entities LuaEntity[]
--- @param invert boolean
local function update_set(set, entities, invert)
  set.completed = set.completed or {}
  set.entities = set.entities or {}
  set.entity_rates = set.entity_rates or {}
  set.errors = set.errors or {}
  set.rates = set.rates or {}
  set.selection_area_tiles = set.selection_area_tiles or 0
  set.selection_area_width = set.selection_area_width or 0
  set.selection_area_height = set.selection_area_height or 0
  update_selected_entities(set, entities, invert)
  recalculate_set(set)
end

--- @param set CalculationSet
--- @param entities LuaEntity[]
local function replace_set_entities(set, entities)
  set.entities = {}
  update_set(set, entities, false)
end

--- @param entities LuaEntity[]
--- @return boolean
local function has_any_entities(entities)
  return next(entities) ~= nil
end

--- @param e EventData.on_player_selected_area|EventData.on_player_alt_selected_area|EventData.on_player_reverse_selected_area
--- @return LuaPlayer?, LuaEntity[]?
local function get_selection_data(e)
  if e.item ~= "rcalc-selection-tool" then
    return
  end
  local entities = e.entities
  if not has_any_entities(entities) then
    return
  end
  local player = game.get_player(e.player_index)
  if not player then
    return
  end
  return player, entities
end

--- @param e EventData.on_player_selected_area
local function on_player_selected_area(e)
  local player, entities = get_selection_data(e)
  if not player then
    return
  end
  local set = new_calculation_set(player)
  replace_set_entities(set, entities)
  gui.build_and_show(player, set, true)
  if player.mod_settings["rcalc-dismiss-tool-on-selection"].value then
    player.clear_cursor()
  end
end

--- @param e EventData.on_player_alt_selected_area
local function on_player_alt_selected_area(e)
  local player, entities = get_selection_data(e)
  if not player then
    return
  end
  local set = gui.get_current_set(player)
  if not set then
    set = new_calculation_set(player)
  end
  update_set(set, entities, false)
  gui.build_and_show(player, set)
end

--- @param e EventData.on_player_reverse_selected_area
local function on_player_alt_reverse_selected_area(e)
  local player, entities = get_selection_data(e)
  if not player then
    return
  end
  local set = gui.get_current_set(player)
  if not set then
    set = new_calculation_set(player)
  end
  update_set(set, entities, true)
  gui.build_and_show(player, set)
end

--- @class Calc
local calc = {}

calc.events = {
  [defines.events.on_player_alt_reverse_selected_area] = on_player_alt_reverse_selected_area,
  [defines.events.on_player_alt_selected_area] = on_player_alt_selected_area,
  [defines.events.on_player_selected_area] = on_player_selected_area,
}

return calc
