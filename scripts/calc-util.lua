local flib_bounding_box = require("__flib__.bounding-box")
local flib_math = require("__flib__.math")
local flib_migration = require("__flib__.migration")
local flib_table = require("__flib__.table")

local gui_util = require("scripts.gui-util")

--- @alias RateCategory
--- | "output"
--- | "input"

--- @class ResourceData
--- @field occurrences uint
--- @field products Product[]
--- @field required_fluid Product?
--- @field mining_time double

--- @class LogisticsData
--- @field item_demand double
--- @field fluid_demand double
--- @field inserter_capacity double
--- @field belt_capacity double
--- @field pipe_capacity double
--- @field pump_capacity double
--- @field item_scale double
--- @field fluid_scale double
--- @field scale double
--- @field inserter_transfer double
--- @field belt_transfer double
--- @field pipe_transfer double
--- @field pump_transfer double

--- @alias Timescale
--- | "per-second",
--- | "per-minute",
--- | "per-10-minutes",
--- | "per-hour",
--- | "transport-belts",
--- | "inserters",

--- @class CalcUtil
local calc_util = {}

--- @param set CalculationSet
--- @param error CalculationError
function calc_util.add_error(set, error)
  set.errors[error] = true
end

--- @param set CalculationSet
--- @param category RateCategory
--- @param type string
--- @param name string
--- @param quality string
--- @param amount double
--- @param invert boolean
--- @param machine_name string?
--- @param temperature double?
function calc_util.add_rate(set, category, type, name, quality, amount, invert, machine_name, temperature)
  local set_rates = set.rates
  local path = type .. "/" .. name .. "/" .. quality .. (temperature or "")
  local rates = set_rates[path]
  if not rates then
    if invert then
      return -- Don't remove from rates that don't exist.
    end
    --- @type Rates
    rates = {
      type = type,
      name = name,
      quality = quality,
      temperature = temperature,
      output = { machines = 0, machine_counts = {}, rate = 0 },
      input = { machines = 0, machine_counts = {}, rate = 0 },
    }
    set_rates[path] = rates
  end
  if invert then
    amount = -amount
  end
  --- @type Rate
  local rate = rates[category]
  if machine_name then
    local counts = rate.machine_counts
    -- Don't remove a machine that doesn't exist
    if not counts[machine_name] and invert then
      goto no_rate
    end
    counts[machine_name] = (counts[machine_name] or 0) + (invert and -1 or 1)
    if counts[machine_name] == 0 then
      counts[machine_name] = nil
    end
  end
  rate.rate = math.max(rate.rate + amount, 0)
  rate.machines = rate.machines + (invert and -1 or 1)
  -- Account for floating-point imprecision
  if rate.rate < 0.00001 then
    rate.rate = 0
  end

  ::no_rate::
  if rates.input.machines == 0 and rates.output.machines == 0 then
    set_rates[path] = nil
  end
end

--- @param set CalculationSet
--- @param entity LuaEntity
--- @param invert boolean
--- @param emissions_per_second double
--- @return double
function calc_util.process_burner(set, entity, invert, emissions_per_second)
  local entity_prototype = entity.prototype
  local burner_prototype = entity_prototype.burner_prototype --[[@as LuaBurnerPrototype]]
  local burner = entity.burner --[[@as LuaBurner]]

  local currently_burning = burner.currently_burning
  if not currently_burning then
    local item = burner.inventory.get_contents()[1]
    if item then
      currently_burning = { name = prototypes.item[item.name], quality = prototypes.quality[item.quality] }
    end
  end
  if not currently_burning then
    calc_util.add_error(set, "no-fuel")
    return emissions_per_second
  end

  local currently_burning_prototype = currently_burning.name

  local max_energy_usage = entity_prototype.get_max_energy_usage(entity.quality) * (entity.consumption_bonus + 1)
  local burns_per_second = 1
    / (currently_burning_prototype.fuel_value / (max_energy_usage / burner_prototype.effectivity) / 60)

  calc_util.add_rate(
    set,
    "input",
    "item",
    currently_burning_prototype.name,
    currently_burning.quality.name,
    burns_per_second,
    invert,
    entity.name
  )

  local burnt_result = currently_burning_prototype.burnt_result
  if burnt_result then
    calc_util.add_rate(
      set,
      "output",
      "item",
      burnt_result.name,
      currently_burning.quality.name,
      burns_per_second,
      invert,
      entity.name
    )
  end

  local emissions = (burner_prototype.emissions_per_joule[set.pollutant] or 0)
    * 60
    * max_energy_usage
    * currently_burning_prototype.fuel_emissions_multiplier
  return emissions_per_second + emissions
end

--- @param fluidbox LuaFluidBox
--- @param index uint
--- @return LuaFluidPrototype?
local function get_fluid(fluidbox, index)
  local fluid = fluidbox.get_filter(index)
  if not fluid then
    fluid = fluidbox[index] --[[@as FluidBoxFilter?]]
  end
  if fluid then
    return prototypes.fluid[fluid.name]
  end
end

--- @param set CalculationSet
--- @param entity LuaEntity
function calc_util.process_beacon(set, entity)
  if entity.status == defines.entity_status.no_power then
    calc_util.add_error(set, "no-power")
  end
end

--- @param set CalculationSet
--- @param entity LuaEntity
--- @param invert boolean
function calc_util.process_boiler(set, entity, invert)
  local entity_prototype = entity.prototype
  local fluidbox = entity.fluidbox

  local input_fluid = get_fluid(fluidbox, 1)
  if not input_fluid then
    calc_util.add_error(set, "no-input-fluid")
    return
  end

  local minimum_temperature = fluidbox.get_prototype(1).minimum_temperature or input_fluid.default_temperature
  local energy_per_amount = (entity_prototype.target_temperature - minimum_temperature) * input_fluid.heat_capacity
  local fluid_usage = entity_prototype.get_max_energy_usage(entity.quality) / energy_per_amount * 60
  calc_util.add_rate(set, "input", "fluid", input_fluid.name, "normal", fluid_usage, invert, entity.name)

  if entity_prototype.boiler_mode == "heat-water-inside" then
    calc_util.add_rate(
      set,
      "output",
      "fluid",
      input_fluid.name,
      "normal",
      fluid_usage,
      invert,
      entity.name,
      input_fluid.max_temperature
    )
    return
  end

  local output_fluid = get_fluid(fluidbox, 2)
  if not output_fluid then
    return
  end

  local minimum_temperature = fluidbox.get_prototype(2).minimum_temperature or output_fluid.default_temperature
  local energy_per_amount = (entity_prototype.target_temperature - minimum_temperature) * output_fluid.heat_capacity
  local fluid_usage = entity_prototype.get_max_energy_usage(entity.quality) / energy_per_amount * 60
  calc_util.add_rate(set, "output", "fluid", output_fluid.name, "normal", fluid_usage, invert, entity.name)
end

--- @param set CalculationSet
--- @param entity LuaEntity
--- @param invert boolean
--- @return double
function calc_util.process_crafter(set, entity, invert, emissions_per_second)
  local recipe, quality = entity.get_recipe()
  if not recipe and entity.type == "furnace" then
    local prev = entity.previous_recipe
    if prev then
      recipe = set.player.force.recipes[prev.name.name]
      quality = prev.quality --[[@as LuaQualityPrototype]]
    end
  end
  if not recipe then
    calc_util.add_error(set, "no-recipe")
    return emissions_per_second
  end
  --- @cast quality -?

  local recipe_duration = recipe.energy / entity.crafting_speed

  for _, ingredient in pairs(recipe.ingredients) do
    local amount = ingredient.amount / recipe_duration
    calc_util.add_rate(
      set,
      "input",
      ingredient.type,
      ingredient.name,
      ingredient.type == "item" and quality.name or "normal",
      amount,
      invert,
      entity.name
    )
  end

  local productivity = 1
    + math.min(entity.productivity_bonus + recipe.productivity_bonus, recipe.prototype.maximum_productivity)

  for _, product in pairs(recipe.products) do
    if product.type == "research-progress" then
      goto continue
    end

    -- stylua: ignore start
    local extra_count_fraction_contribution = product.extra_count_fraction or 0
    local max_amount = product.amount_max or product.amount
    local min_amount = product.amount_min or product.amount
    local expected_amount = (product.probability or 1) * 0.5 * (max_amount + min_amount) + extra_count_fraction_contribution
    local productivity_base_complement = math.min(expected_amount, product.ignored_by_productivity or 0)
    local productivity_base = expected_amount - productivity_base_complement
    -- stylua: ignore end

    local amount = (productivity_base_complement + productivity_base * productivity) / recipe_duration

    calc_util.add_rate(
      set,
      "output",
      product.type,
      product.name,
      product.type == "item" and quality.name or "normal",
      amount,
      invert,
      entity.name,
      product.temperature
    )

    ::continue::
  end

  return emissions_per_second * recipe.prototype.emissions_multiplier * (1 + entity.pollution_bonus)
end

--- @param set CalculationSet
--- @param entity LuaEntity
--- @param invert boolean
--- @param emissions_per_second double
--- @return double
function calc_util.process_electric_energy_source(set, entity, invert, emissions_per_second)
  local entity_prototype = entity.prototype

  -- Electric energy interfaces can have their settings adjusted at runtime, so checking the energy source is pointless.
  if entity.type == "electric-energy-interface" then
    local production = entity.power_production * 60
    if production > 0 then
      calc_util.add_rate(set, "output", "item", "rcalc-power-dummy", "normal", production, invert, entity.name)
    end
    local usage = entity.power_usage * 60
    if usage > 0 then
      calc_util.add_rate(set, "input", "item", "rcalc-power-dummy", "normal", usage, invert, entity.name)
    end
    return emissions_per_second
  end

  local electric_energy_source_prototype = entity_prototype.electric_energy_source_prototype --[[@as LuaElectricEnergySourcePrototype]]

  local added_emissions = 0
  local max_energy_usage = entity_prototype.get_max_energy_usage(entity.quality) or 0
  if max_energy_usage > 0 and max_energy_usage < flib_math.max_int53 then
    local consumption_bonus = (entity.consumption_bonus + 1)
    local drain = electric_energy_source_prototype.drain
    local amount = max_energy_usage * consumption_bonus
    if max_energy_usage ~= drain then
      amount = amount + drain
    end
    calc_util.add_rate(set, "input", "item", "rcalc-power-dummy", "normal", amount * 60, invert, entity.name)
    if entity.status == defines.entity_status.no_power then
      calc_util.add_error(set, "no-power")
    end
    added_emissions = (electric_energy_source_prototype.emissions_per_joule[set.pollutant] or 0)
      * (max_energy_usage * consumption_bonus)
      * 60
  end

  local max_energy_production = entity_prototype.get_max_energy_production(entity.quality)
  if max_energy_production > 0 and max_energy_production < flib_math.max_int53 then
    if entity.type == "solar-panel" then
      max_energy_production = max_energy_production
        * entity.surface.solar_power_multiplier
        * entity.surface.get_property("solar-power")
        / prototypes.surface_property["solar-power"].default_value
    end
    calc_util.add_rate(
      set,
      "output",
      "item",
      "rcalc-power-dummy",
      "normal",
      max_energy_production * 60,
      invert,
      entity.name
    )
  end

  return emissions_per_second + added_emissions
end

--- @param set CalculationSet
--- @param entity LuaEntity
--- @param invert boolean
--- @param emissions_per_second double
--- @return double
function calc_util.process_fluid_energy_source(set, entity, invert, emissions_per_second)
  --- @type LuaEntityPrototype
  local entity_prototype = entity.prototype
  local fluid_energy_source_prototype = entity_prototype.fluid_energy_source_prototype --[[@as LuaFluidEnergySourcePrototype]]

  local fluidbox = entity.fluidbox
  -- The fluid energy source fluidbox will always be the first one
  local fluid_prototype
  if entity.type == "boiler" then
    fluid_prototype = get_fluid(fluidbox, #fluidbox)
  else
    fluid_prototype = get_fluid(fluidbox, 1)
  end
  if not fluid_prototype then
    calc_util.add_error(set, "no-input-fluid")
    return emissions_per_second
  end
  local max_energy_usage = entity_prototype.get_max_energy_usage(entity.quality) * (entity.consumption_bonus + 1)

  local value
  if fluid_energy_source_prototype.scale_fluid_usage then
    if fluid_energy_source_prototype.burns_fluid and fluid_prototype.fuel_value > 0 then
      value = max_energy_usage / (fluid_prototype.fuel_value / 60) / fluid_energy_source_prototype.effectivity
    else
      -- Now we need the actual fluid to get its temperature
      local fluid = fluidbox[#fluidbox]
      if not fluid then
        calc_util.add_error(set, "no-input-fluid")
        return emissions_per_second
      end
      -- If the fluid is equal to its default temperature, then nothing will happen
      local temperature_value = fluid.temperature - fluid_prototype.default_temperature
      if temperature_value > 0 then
        value = max_energy_usage
          / (temperature_value * fluid_prototype.heat_capacity)
          / fluid_energy_source_prototype.effectivity
          * 60
      end
    end
  else
    value = fluid_energy_source_prototype.fluid_usage_per_tick / fluid_energy_source_prototype.effectivity * 60
  end
  if not value then
    return emissions_per_second -- No error, but not rate either
  end

  calc_util.add_rate(set, "input", "fluid", fluid_prototype.name, "normal", value, invert, entity.name)

  return (fluid_energy_source_prototype.emissions_per_joule[set.pollutant] or 0) * max_energy_usage * 60
end

--- @param set CalculationSet
--- @param entity LuaEntity
--- @param invert boolean
function calc_util.process_generator(set, entity, invert)
  local entity_prototype = entity.prototype
  local fluid = get_fluid(entity.fluidbox, 1)
  if not fluid then
    calc_util.add_error(set, "no-input-fluid")
    return
  end
  calc_util.add_rate(
    set,
    "input",
    "fluid",
    fluid.name,
    "normal",
    entity_prototype.get_fluid_usage_per_tick(entity.quality) * 60,
    invert,
    entity.name
  )
end

--- @param set CalculationSet
--- @param entity LuaEntity
--- @param invert boolean
function calc_util.process_heat_energy_source(set, entity, invert)
  calc_util.add_rate(
    set,
    "input",
    "item",
    "rcalc-heat-dummy",
    "normal",
    entity.prototype.get_max_energy_usage(entity.quality) * (1 + entity.consumption_bonus) * 60,
    invert,
    entity.name
  )
end

--- @param set CalculationSet
--- @param entity LuaEntity
--- @param invert boolean
function calc_util.process_lab(set, entity, invert)
  local research_data = set.research_data
  if not research_data then
    calc_util.add_error(set, "no-active-research")
    return
  end

  local science_pack_drain = entity.prototype.science_pack_drain_rate_percent / 100
  local research_multiplier = research_data.multiplier
  local researching_speed = entity.prototype.get_researching_speed(entity.quality)
  local speed_modifier = research_data.speed_modifier
  -- XXX: Due to a bug with entity_speed_bonus, we must subtract the force's lab speed bonus and convert it to a
  -- multiplicative relationship
  local lab_multiplier = research_multiplier
    * ((entity.speed_bonus + 1 - speed_modifier) * (speed_modifier + 1))
    * researching_speed
    * science_pack_drain

  local inputs = flib_table.invert(entity.prototype.lab_inputs)
  for _, ingredient in pairs(research_data.ingredients) do
    if not inputs[ingredient.name] then
      calc_util.add_error(set, "incompatible-science-packs")
      return
    end
  end

  for _, ingredient in ipairs(research_data.ingredients) do
    -- TODO: Select quality
    local amount = (ingredient.amount * lab_multiplier) / prototypes.item[ingredient.name].get_durability()
    calc_util.add_rate(set, "input", "item", ingredient.name, "normal", amount, invert, entity.name)
  end
end

--- @param set CalculationSet
--- @param entity LuaEntity
--- @param invert boolean
function calc_util.process_mining_drill(set, entity, invert)
  local entity_prototype = entity.prototype
  local entity_productivity_bonus = entity.productivity_bonus
  local entity_speed_bonus = entity.speed_bonus

  -- Look for resource entities under the drill
  local radius = entity_prototype.mining_drill_radius + 0.01
  local box = flib_bounding_box.from_dimensions(entity.position, radius * 2, radius * 2)
  local resource_entities = entity.surface.find_entities_filtered({ area = box })
  local resource_entities_len = #resource_entities
  if resource_entities_len == 0 then
    calc_util.add_error(set, "no-mineable-resources")
    return
  end

  --- @type table<string, ResourceData>
  local resources = {}
  local num_resource_entities = 0
  local has_fluidbox = next(entity_prototype.fluidbox_prototypes) and true or false
  local resource_categories = entity_prototype.resource_categories or {}
  for i = 1, resource_entities_len do
    local resource = resource_entities[i]
    local resource_name = resource.name

    -- If this resource has already been processed
    local resource_data = resources[resource_name]
    if resource_data then
      resource_data.occurrences = resource_data.occurrences + 1
      num_resource_entities = num_resource_entities + 1
      goto continue
    end

    local resource_prototype = resource.prototype
    if not resource_categories[resource_prototype.resource_category] then
      goto continue
    end
    num_resource_entities = num_resource_entities + 1
    local mineable_properties = resource_prototype.mineable_properties
    local required_fluid = mineable_properties.required_fluid
    if required_fluid and not has_fluidbox then
      goto continue
    end

    resource_data = {
      occurrences = 1,
      products = mineable_properties.products,
      mining_time = mineable_properties.mining_time,
    }

    if resource_prototype.infinite_resource then
      resource_data.mining_time = resource_data.mining_time
        / (resource.amount / resource_prototype.normal_resource_amount)
    end

    if required_fluid then
      resource_data.required_fluid = {
        type = "fluid",
        name = required_fluid,
        amount = mineable_properties.fluid_amount / 10, -- Ten mining operations per fluid consumed
        probability = 1,
      }
    end

    resources[resource_name] = resource_data

    ::continue::
  end

  if num_resource_entities == 0 then
    calc_util.add_error(set, "no-mineable-resources")
    return
  end

  -- Process resource entities

  local adjusted_mining_speed = entity_prototype.mining_speed
    * (entity_speed_bonus + 1)
    * (entity_productivity_bonus + 1)

  for _, resource_data in pairs(resources) do
    local resource_multiplier = (adjusted_mining_speed / resource_data.mining_time)
      * (resource_data.occurrences / num_resource_entities)

    -- Add required fluid to inputs
    local required_fluid = resource_data.required_fluid
    if required_fluid then
      -- Productivity does not apply to ingredients
      local fluid_per_second = required_fluid.amount * resource_multiplier / (entity_productivity_bonus + 1)

      -- Add to inputs table
      local fluid_name = required_fluid.name
      calc_util.add_rate(set, "input", "fluid", fluid_name, "normal", fluid_per_second, invert, entity.name)
    end

    -- Iterate each product
    for _, product in pairs(resource_data.products or {}) do
      -- Get rate per second for this product on this drill
      local product_per_second
      if product.amount then
        product_per_second = product.amount * resource_multiplier
      else
        product_per_second = product.amount_max - (product.amount_max - product.amount_min) / 2 * resource_multiplier
      end

      -- Account for probability
      local adjusted_product_per_second = product_per_second * (product.probability or 1)

      -- Add to outputs table
      calc_util.add_rate(
        set,
        "output",
        product.type,
        product.name,
        "normal",
        adjusted_product_per_second,
        invert,
        entity.name,
        product.temperature
      )
    end
  end
end

--- @param set CalculationSet
--- @param entity LuaEntity
--- @param invert boolean
function calc_util.process_offshore_pump(set, entity, invert)
  local fluid = entity.fluidbox[1]
  if not fluid then
    return
  end
  local pumping_speed = 0
  if flib_migration.is_newer_version("2.0.32", script.active_mods.base) then -- 2.0.33 or higher
    pumping_speed = entity.prototype.get_pumping_speed(entity.quality)
  else
    pumping_speed = entity.prototype.pumping_speed
  end

  calc_util.add_rate(set, "output", "fluid", fluid.name, "normal", pumping_speed * 60, invert, entity.name)
end

--- @param set CalculationSet
--- @param entity LuaEntity
--- @param invert boolean
function calc_util.process_reactor(set, entity, invert)
  calc_util.add_rate(
    set,
    "output",
    "item",
    "rcalc-heat-dummy",
    "normal",
    entity.prototype.get_max_energy_usage(entity.quality)
      * (1 + entity.neighbour_bonus)
      * (1 + entity.consumption_bonus)
      * 60,
    invert,
    entity.name
  )
end

local excluded_limiting_paths = {
  ["item/rcalc-heat-dummy/normal"] = true,
  ["item/rcalc-pollution-dummy/normal"] = true,
  ["item/rcalc-power-dummy/normal"] = true,
}

local limitation_epsilon = 0.00001
local limitation_max_iterations = 64

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

--- @param source table<string, Rates>
--- @return table<string, Rates>
local function copy_rates_table(source)
  local copied = {}
  for path, rates in pairs(source) do
    copied[path] = copy_rates(rates)
  end
  return copied
end

--- @class VariableFlow
--- @field index integer
--- @field amount double
--- @field key string?

--- @param table_by_path table<string, VariableFlow[]>
--- @param path string
--- @param variable_index integer
--- @param amount double
--- @param key string?
local function add_variable_flow(table_by_path, path, variable_index, amount, key)
  local entries = table_by_path[path]
  if not entries then
    entries = {}
    table_by_path[path] = entries
  end
  entries[#entries + 1] = { index = variable_index, amount = amount, key = key }
end

--- @param target Rate
--- @param source Rate
--- @param scale double
local function add_scaled_rate(target, source, scale)
  target.rate = target.rate + source.rate * scale
  target.machines = target.machines + source.machines * scale
  for machine_name, count in pairs(source.machine_counts) do
    target.machine_counts[machine_name] = (target.machine_counts[machine_name] or 0) + count * scale
  end
end

--- @param rates table<string, Rates>
local function cleanup_rates(rates)
  for path, rate_data in pairs(rates) do
    local input = rate_data.input
    local output = rate_data.output
    if input.rate < limitation_epsilon then
      input.rate = 0
      input.machines = 0
      input.machine_counts = {}
    end
    if output.rate < limitation_epsilon then
      output.rate = 0
      output.machines = 0
      output.machine_counts = {}
    end
    if input.rate == 0 and output.rate == 0 then
      rates[path] = nil
      goto continue
    end

    for machine_name, count in pairs(input.machine_counts) do
      if count < limitation_epsilon then
        input.machine_counts[machine_name] = nil
      end
    end
    for machine_name, count in pairs(output.machine_counts) do
      if count < limitation_epsilon then
        output.machine_counts[machine_name] = nil
      end
    end

    ::continue::
  end
end

--- @param rates table<string, Rates>
--- @return string
local function make_rates_signature(rates)
  local path_keys = {}
  for path in pairs(rates) do
    path_keys[#path_keys + 1] = path
  end
  table.sort(path_keys)

  local parts = {}
  for i = 1, #path_keys do
    local path = path_keys[i]
    local rate_data = rates[path]
    local input = rate_data.input
    local output = rate_data.output

    parts[#parts + 1] = path
    parts[#parts + 1] = tostring(input.rate)
    parts[#parts + 1] = tostring(output.rate)
    parts[#parts + 1] = tostring(input.machines)
    parts[#parts + 1] = tostring(output.machines)

    local input_machine_keys = {}
    for machine_name in pairs(input.machine_counts) do
      input_machine_keys[#input_machine_keys + 1] = machine_name
    end
    table.sort(input_machine_keys)
    for j = 1, #input_machine_keys do
      local machine_name = input_machine_keys[j]
      parts[#parts + 1] = "i/" .. machine_name
      parts[#parts + 1] = tostring(input.machine_counts[machine_name])
    end

    local output_machine_keys = {}
    for machine_name in pairs(output.machine_counts) do
      output_machine_keys[#output_machine_keys + 1] = machine_name
    end
    table.sort(output_machine_keys)
    for j = 1, #output_machine_keys do
      local machine_name = output_machine_keys[j]
      parts[#parts + 1] = "o/" .. machine_name
      parts[#parts + 1] = tostring(output.machine_counts[machine_name])
    end
  end

  return table.concat(parts, "|")
end

--- @param entity_rates table<string, table<string, Rates>>
--- @param max_input_by_path table<string, table<string, double>>?
--- @return table<integer, table<string, Rates>>, table<integer, double>, table<integer, string?>
local function collect_limiting_variables(entity_rates, max_input_by_path)
  --- @type table<integer, table<string, Rates>>
  local variable_rates = {}
  --- @type table<integer, double>
  local variable_upper_bounds = {}
  --- @type table<integer, string?>
  local variable_keys = {}

  -- Per-entity caps rely on exact entity keys, so do not aggregate in that mode.
  if max_input_by_path and next(max_input_by_path) ~= nil then
    local entity_keys = {}
    for key in pairs(entity_rates) do
      entity_keys[#entity_keys + 1] = key
    end
    table.sort(entity_keys)
    for i = 1, #entity_keys do
      local key = entity_keys[i]
      variable_rates[i] = entity_rates[key]
      variable_upper_bounds[i] = 1
      variable_keys[i] = key
    end
    return variable_rates, variable_upper_bounds, variable_keys
  end

  --- @type table<string, { rates: table<string, Rates>, count: integer }>
  local classes_by_signature = {}
  local signatures = {}
  for _, rates in pairs(entity_rates) do
    local signature = make_rates_signature(rates)
    local class = classes_by_signature[signature]
    if not class then
      class = { rates = rates, count = 0 }
      classes_by_signature[signature] = class
      signatures[#signatures + 1] = signature
    end
    class.count = class.count + 1
  end
  table.sort(signatures)

  for i = 1, #signatures do
    local class = classes_by_signature[signatures[i]]
    variable_rates[i] = class.rates
    variable_upper_bounds[i] = class.count
  end
  return variable_rates, variable_upper_bounds, variable_keys
end

--- @param variable_rates table<integer, table<string, Rates>>
--- @param variable_count integer
--- @param path_set table<string, boolean>
--- @return table<integer, double>, boolean
local function build_path_output_objective(variable_rates, variable_count, path_set)
  local objective = {}
  local has_objective = false
  for i = 1, variable_count do
    local coeff = 0
    local rates = variable_rates[i]
    for path, rate_data in pairs(rates) do
      if path_set[path] and rate_data.output.rate > limitation_epsilon then
        coeff = coeff + rate_data.output.rate
      end
    end
    objective[i] = coeff
    if coeff > limitation_epsilon then
      has_objective = true
    end
  end
  return objective, has_objective
end

--- @param constrained_A table<integer, table<integer, double>>
--- @param constrained_b table<integer, double>
--- @param objective table<integer, double>
--- @param objective_value double?
--- @param variable_count integer
local function add_objective_lock(constrained_A, constrained_b, objective, objective_value, variable_count)
  local lock_coeffs = {}
  for i = 1, variable_count do
    lock_coeffs[i] = -(objective[i] or 0)
  end
  constrained_A[#constrained_A + 1] = lock_coeffs
  constrained_b[#constrained_b + 1] = -((objective_value or 0) - limitation_epsilon)
end

--- @param variable_rates table<integer, table<string, Rates>>
--- @param producers_by_path table<string, VariableFlow[]>
--- @param consumers_by_path table<string, VariableFlow[]>
--- @param final_paths table<string, boolean>
--- @return table<integer, table<string, boolean>>, table<string, boolean>
local function build_intermediate_level_sets(variable_rates, producers_by_path, consumers_by_path, final_paths)
  local internal_paths = {}
  for path in pairs(producers_by_path) do
    if not excluded_limiting_paths[path] and consumers_by_path[path] then
      internal_paths[path] = true
    end
  end

  --- @type table<string, table<string, boolean>>
  local reverse_edges = {}

  --- @param output_path string
  --- @param input_path string
  local function add_reverse_edge(output_path, input_path)
    local inputs = reverse_edges[output_path]
    if not inputs then
      inputs = {}
      reverse_edges[output_path] = inputs
    end
    inputs[input_path] = true
  end

  for i = 1, #variable_rates do
    local rates = variable_rates[i]
    local input_paths = {}
    local output_paths = {}
    for path, rate_data in pairs(rates) do
      if excluded_limiting_paths[path] then
        goto continue
      end
      if rate_data.input.rate > limitation_epsilon and internal_paths[path] then
        input_paths[#input_paths + 1] = path
      end
      if rate_data.output.rate > limitation_epsilon then
        output_paths[#output_paths + 1] = path
      end
      ::continue::
    end

    if #input_paths > 0 and #output_paths > 0 then
      for output_index = 1, #output_paths do
        local output_path = output_paths[output_index]
        for input_index = 1, #input_paths do
          local input_path = input_paths[input_index]
          if input_path ~= output_path then
            add_reverse_edge(output_path, input_path)
          end
        end
      end
    end
  end

  local distance_to_final = {}
  local queue = {}
  for final_path in pairs(final_paths) do
    distance_to_final[final_path] = 0
    queue[#queue + 1] = final_path
  end

  local queue_index = 1
  while queue_index <= #queue do
    local path = queue[queue_index]
    queue_index = queue_index + 1
    local base_distance = distance_to_final[path] or 0
    local inputs = reverse_edges[path]
    if inputs then
      local next_distance = base_distance + 1
      for input_path in pairs(inputs) do
        if distance_to_final[input_path] == nil then
          distance_to_final[input_path] = next_distance
          queue[#queue + 1] = input_path
        end
      end
    end
  end

  --- @type table<integer, table<string, boolean>>
  local level_sets = {}
  for path in pairs(internal_paths) do
    local distance = distance_to_final[path]
    if distance and distance > 0 then
      local level = level_sets[distance]
      if not level then
        level = {}
        level_sets[distance] = level
      end
      level[path] = true
    end
  end

  return level_sets, internal_paths
end

--- @param prototype LuaEntityPrototype
--- @return boolean
local function is_belt_type(prototype)
  local type = prototype.type
  return type == "transport-belt"
    or type == "underground-belt"
    or type == "splitter"
    or type == "loader"
    or type == "loader-1x1"
end

--- @param prototype LuaEntityPrototype
--- @return boolean
local function is_pipe_type(prototype)
  local type = prototype.type
  return type == "pipe" or type == "pipe-to-ground" or type == "infinity-pipe"
end

--- @param entity LuaEntity
--- @return boolean
local function has_fluidbox(entity)
  local fluidbox = entity.fluidbox
  if not fluidbox then
    return false
  end
  local ok, length = pcall(function()
    return #fluidbox
  end)
  return ok and length > 0
end

--- @param prototype LuaEntityPrototype
--- @return double
local function get_pipe_capacity_per_second(prototype)
  local capacity = 0
  for _, fluidbox in pairs(prototype.fluidbox_prototypes) do
    capacity = math.max(capacity, fluidbox.volume or 0)
  end
  if capacity <= 0 then
    capacity = 100 -- Sensible fallback for vanilla-like pipes.
  end
  return capacity * 60
end

--- @param entity LuaEntity
--- @return double
local function get_pump_capacity_per_second(entity)
  local prototype = entity.prototype
  local base_speed = prototype.pumping_speed or 0
  local get_quality_speed = prototype.get_pumping_speed
  if get_quality_speed then
    local ok, quality_speed = pcall(get_quality_speed, prototype, entity.quality)
    if ok and quality_speed then
      base_speed = quality_speed
    end
  end
  return base_speed * 60
end

--- @param prototype LuaEntityPrototype
--- @return double
local function get_belt_capacity_per_second(prototype)
  local speed = prototype.belt_speed or 0
  if speed <= 0 then
    return 0
  end
  -- Splitters effectively handle two full lanes.
  if prototype.type == "splitter" then
    return speed * 960
  end
  return speed * 480
end

--- @class TransportEdge
--- @field from string
--- @field to string
--- @field capacity double
--- @field mode string?

--- @class TransportGraph
--- @field capacities table<string, double>
--- @field edges TransportEdge[]
--- @field entry_node_by_entity table<string, string>
--- @field exit_node_by_entity table<string, string>

--- @class ResidualEdge
--- @field base_id integer
--- @field cap double
--- @field forward boolean
--- @field mode string?
--- @field rev integer
--- @field to string

--- @class ResourcePathFlow
--- @field consumers table<string, double>
--- @field demand double
--- @field path string
--- @field producers table<string, double>

local unlimited_capacity = 10 ^ 30

--- @param table_by_path table<string, table<string, double>>
--- @param path string
--- @param key string
--- @param amount double
local function add_amount_by_path(table_by_path, path, key, amount)
  local entries = table_by_path[path]
  if not entries then
    entries = {}
    table_by_path[path] = entries
  end
  entries[key] = (entries[key] or 0) + amount
end

--- @param source table<string, double>
--- @return table<string, double>
local function copy_double_table(source)
  local copied = {}
  for key, value in pairs(source) do
    copied[key] = value
  end
  return copied
end

--- @param source table<string, double>
--- @return boolean
local function has_positive_entries(source)
  for _, value in pairs(source) do
    if value > limitation_epsilon then
      return true
    end
  end
  return false
end

--- @param graph TransportGraph
--- @param from string
--- @param to string
--- @param capacity double
--- @param mode string?
local function add_transport_edge(graph, from, to, capacity, mode)
  if capacity <= limitation_epsilon or from == to then
    return
  end
  graph.edges[#graph.edges + 1] = {
    from = from,
    to = to,
    capacity = capacity,
    mode = mode,
  }
  if mode then
    graph.capacities[mode] = (graph.capacities[mode] or 0) + capacity
  end
end

--- @param entity LuaEntity
--- @param field string
--- @return any?
local function safe_get_field(entity, field)
  local ok, value = pcall(function()
    return entity[field]
  end)
  if ok then
    return value
  end
end

--- @param entity LuaEntity
--- @return LuaEntity[], boolean
local function collect_belt_outputs(entity)
  local outputs = {}
  local seen = {}
  local directional = false

  local belt_neighbours = safe_get_field(entity, "belt_neighbours")
  if belt_neighbours then
    local neighbor_outputs = safe_get_field(belt_neighbours, "outputs")
    if neighbor_outputs then
      directional = true
      for _, neighbor in pairs(neighbor_outputs) do
        if neighbor and neighbor.valid and not seen[neighbor] then
          seen[neighbor] = true
          outputs[#outputs + 1] = neighbor
        end
      end
    end
  end

  if #outputs > 0 then
    return outputs, directional
  end

  local neighbors = safe_get_field(entity, "neighbours")
  if neighbors then
    for _, neighbor in pairs(neighbors) do
      if neighbor and neighbor.valid and not seen[neighbor] then
        seen[neighbor] = true
        outputs[#outputs + 1] = neighbor
      end
    end
  end

  return outputs, false
end

--- @param connection any
--- @return LuaEntity?
local function extract_connection_entity(connection)
  if not connection then
    return
  end
  if connection.valid then
    return connection --[[@as LuaEntity]]
  end

  local target = safe_get_field(connection, "target")
  if target then
    local owner = safe_get_field(target, "owner")
    if owner and owner.valid then
      return owner --[[@as LuaEntity]]
    end
    if target.valid then
      return target --[[@as LuaEntity]]
    end
  end

  local owner = safe_get_field(connection, "owner")
  if owner and owner.valid then
    return owner --[[@as LuaEntity]]
  end
end

--- @param entity LuaEntity
--- @return LuaEntity[]
local function collect_fluid_neighbors(entity)
  local neighbors = {}
  local seen = {}

  local direct_neighbors = safe_get_field(entity, "neighbours")
  if direct_neighbors then
    for _, neighbor in pairs(direct_neighbors) do
      if neighbor and neighbor.valid and not seen[neighbor] then
        seen[neighbor] = true
        neighbors[#neighbors + 1] = neighbor
      end
    end
  end

  local fluidbox = entity.fluidbox
  if not fluidbox then
    return neighbors
  end

  local get_connections = safe_get_field(fluidbox, "get_connections")
  if not get_connections then
    return neighbors
  end

  local ok_len, fluidbox_len = pcall(function()
    return #fluidbox
  end)
  if not ok_len then
    return neighbors
  end

  for fluidbox_index = 1, fluidbox_len do
    local ok_connections, connections = pcall(get_connections, fluidbox, fluidbox_index)
    if not ok_connections or not connections then
      goto continue
    end
    for _, connection in pairs(connections) do
      local neighbor = extract_connection_entity(connection)
      if neighbor and neighbor.valid and not seen[neighbor] then
        seen[neighbor] = true
        neighbors[#neighbors + 1] = neighbor
      end
    end
    ::continue::
  end

  return neighbors
end

--- @param entities table<string, LuaEntity>
--- @return table<LuaEntity, string>
local function build_entity_key_lookup(entities)
  local lookup = {}
  for entity_key, entity in pairs(entities) do
    if entity.valid then
      lookup[entity] = entity_key
    end
  end
  return lookup
end

--- @param entities table<string, LuaEntity>
--- @param player LuaPlayer
--- @param entity_key_lookup table<LuaEntity, string>
--- @return TransportGraph
local function build_item_transport_graph(entities, player, entity_key_lookup)
  --- @type TransportGraph
  local graph = {
    capacities = {},
    edges = {},
    entry_node_by_entity = {},
    exit_node_by_entity = {},
  }

  for entity_key, entity in pairs(entities) do
    if not entity.valid then
      goto continue
    end
    local prototype = entity.prototype
    if is_belt_type(prototype) then
      local entry_node = "item/belt/in/" .. entity_key
      local exit_node = "item/belt/out/" .. entity_key
      graph.entry_node_by_entity[entity_key] = entry_node
      graph.exit_node_by_entity[entity_key] = exit_node
      add_transport_edge(graph, entry_node, exit_node, get_belt_capacity_per_second(prototype), "belt")
      goto continue
    end

    local node = "item/entity/" .. entity_key
    graph.entry_node_by_entity[entity_key] = node
    graph.exit_node_by_entity[entity_key] = node

    ::continue::
  end

  for _, entity in pairs(entities) do
    if not entity.valid then
      goto continue
    end
    local prototype = entity.prototype
    if prototype.type ~= "inserter" then
      goto continue
    end

    local pickup_target = entity.pickup_target
    local drop_target = entity.drop_target
    if not pickup_target or not pickup_target.valid or not drop_target or not drop_target.valid then
      goto continue
    end
    if pickup_target == drop_target then
      goto continue
    end

    local pickup_key = entity_key_lookup[pickup_target]
    local drop_key = entity_key_lookup[drop_target]
    if not pickup_key or not drop_key then
      goto continue
    end

    local from_node = graph.exit_node_by_entity[pickup_key]
    local to_node = graph.entry_node_by_entity[drop_key]
    if not from_node or not to_node then
      goto continue
    end

    local cycles_per_second = gui_util.calc_inserter_cycles_per_second(prototype, entity.quality)
    local stack_bonus = prototype.bulk and player.force.bulk_inserter_capacity_bonus
      or player.force.inserter_stack_size_bonus
    local stack_size = 1 + prototype.inserter_stack_size_bonus + stack_bonus
    local capacity = cycles_per_second * stack_size
    add_transport_edge(graph, from_node, to_node, capacity, "inserter")

    ::continue::
  end

  local added_belt_links = {}
  for entity_key, entity in pairs(entities) do
    if not entity.valid or not is_belt_type(entity.prototype) then
      goto continue
    end

    local outputs, directional = collect_belt_outputs(entity)
    local from_node = graph.exit_node_by_entity[entity_key]
    if not from_node then
      goto continue
    end

    for _, output_entity in pairs(outputs) do
      local target_key = entity_key_lookup[output_entity]
      if not target_key then
        goto output_continue
      end
      local target_node = graph.entry_node_by_entity[target_key]
      if not target_node then
        goto output_continue
      end

      local link_key = from_node .. "->" .. target_node
      if not added_belt_links[link_key] then
        added_belt_links[link_key] = true
        add_transport_edge(graph, from_node, target_node, unlimited_capacity, nil)
      end

      if not directional then
        local reverse_node = graph.exit_node_by_entity[target_key]
        local back_node = graph.entry_node_by_entity[entity_key]
        if reverse_node and back_node then
          local reverse_key = reverse_node .. "->" .. back_node
          if not added_belt_links[reverse_key] then
            added_belt_links[reverse_key] = true
            add_transport_edge(graph, reverse_node, back_node, unlimited_capacity, nil)
          end
        end
      end

      ::output_continue::
    end

    ::continue::
  end

  return graph
end

--- @param entities table<string, LuaEntity>
--- @param entity_key_lookup table<LuaEntity, string>
--- @return TransportGraph
local function build_fluid_transport_graph(entities, entity_key_lookup)
  --- @type TransportGraph
  local graph = {
    capacities = {},
    edges = {},
    entry_node_by_entity = {},
    exit_node_by_entity = {},
  }

  for entity_key, entity in pairs(entities) do
    if not entity.valid or not has_fluidbox(entity) then
      goto continue
    end

    local prototype = entity.prototype
    if is_pipe_type(prototype) then
      local entry_node = "fluid/pipe/in/" .. entity_key
      local exit_node = "fluid/pipe/out/" .. entity_key
      local pipe_capacity = get_pipe_capacity_per_second(prototype)
      graph.entry_node_by_entity[entity_key] = entry_node
      graph.exit_node_by_entity[entity_key] = exit_node
      add_transport_edge(graph, entry_node, exit_node, pipe_capacity, "pipe")
      add_transport_edge(graph, exit_node, entry_node, pipe_capacity, nil)
      goto continue
    end
    if prototype.type == "pump" or prototype.type == "offshore-pump" then
      local entry_node = "fluid/pump/in/" .. entity_key
      local exit_node = "fluid/pump/out/" .. entity_key
      graph.entry_node_by_entity[entity_key] = entry_node
      graph.exit_node_by_entity[entity_key] = exit_node
      add_transport_edge(graph, entry_node, exit_node, get_pump_capacity_per_second(entity), "pump")
      goto continue
    end

    local node = "fluid/entity/" .. entity_key
    graph.entry_node_by_entity[entity_key] = node
    graph.exit_node_by_entity[entity_key] = node

    ::continue::
  end

  local added_fluid_links = {}
  for entity_key, entity in pairs(entities) do
    if not entity.valid then
      goto continue
    end

    local from_node = graph.exit_node_by_entity[entity_key]
    if not from_node then
      goto continue
    end
    local fluid_neighbors = collect_fluid_neighbors(entity)
    for _, neighbor in pairs(fluid_neighbors) do
      local neighbor_key = entity_key_lookup[neighbor]
      if not neighbor_key then
        goto neighbor_continue
      end
      local to_node = graph.entry_node_by_entity[neighbor_key]
      if not to_node then
        goto neighbor_continue
      end
      local link_key = from_node .. "->" .. to_node
      if not added_fluid_links[link_key] then
        added_fluid_links[link_key] = true
        add_transport_edge(graph, from_node, to_node, unlimited_capacity, nil)
      end
      local reverse_node = graph.exit_node_by_entity[neighbor_key]
      local back_node = graph.entry_node_by_entity[entity_key]
      if reverse_node and back_node then
        local reverse_key = reverse_node .. "->" .. back_node
        if not added_fluid_links[reverse_key] then
          added_fluid_links[reverse_key] = true
          add_transport_edge(graph, reverse_node, back_node, unlimited_capacity, nil)
        end
      end
      ::neighbor_continue::
    end

    ::continue::
  end

  return graph
end

--- @param graph TransportGraph
--- @return table<string, integer[]>, ResidualEdge[]
local function build_residual_network(graph)
  local adjacency = {}
  --- @type ResidualEdge[]
  local residual_edges = {}

  --- @param from string
  --- @param to string
  --- @param cap double
  --- @param base_id integer
  --- @param mode string?
  local function add_residual_edge(from, to, cap, base_id, mode)
    local forward_id = #residual_edges + 1
    local reverse_id = forward_id + 1
    residual_edges[forward_id] = {
      base_id = base_id,
      cap = cap,
      forward = true,
      mode = mode,
      rev = reverse_id,
      to = to,
    }
    residual_edges[reverse_id] = {
      base_id = base_id,
      cap = 0,
      forward = false,
      mode = mode,
      rev = forward_id,
      to = from,
    }
    local from_list = adjacency[from]
    if not from_list then
      from_list = {}
      adjacency[from] = from_list
    end
    from_list[#from_list + 1] = forward_id
    local to_list = adjacency[to]
    if not to_list then
      to_list = {}
      adjacency[to] = to_list
    end
    to_list[#to_list + 1] = reverse_id
  end

  for base_id, edge in ipairs(graph.edges) do
    add_residual_edge(edge.from, edge.to, edge.capacity, base_id, edge.mode)
  end

  return adjacency, residual_edges
end

--- @param adjacency table<string, integer[]>
--- @param residual_edges ResidualEdge[]
--- @param supplies table<string, double>
--- @param demands table<string, double>
--- @param flow_limit double
--- @param edge_usage table<integer, double>
--- @return double
local function push_flow(adjacency, residual_edges, supplies, demands, flow_limit, edge_usage)
  if flow_limit <= limitation_epsilon then
    return 0
  end

  local flow = 0
  while flow_limit - flow > limitation_epsilon and has_positive_entries(supplies) and has_positive_entries(demands) do
    for node, supply in pairs(supplies) do
      if supply <= limitation_epsilon then
        goto direct_continue
      end
      local demand = demands[node] or 0
      if demand <= limitation_epsilon then
        goto direct_continue
      end
      local local_transfer = math.min(flow_limit - flow, supply, demand)
      if local_transfer <= limitation_epsilon then
        goto direct_continue
      end
      supplies[node] = supply - local_transfer
      demands[node] = demand - local_transfer
      flow = flow + local_transfer
      if flow_limit - flow <= limitation_epsilon then
        return flow
      end
      ::direct_continue::
    end

    local queue = {}
    local queue_head = 1
    local queue_tail = 0
    local visited = {}
    local parent_edge = {}
    local parent_node = {}
    local source_of = {}
    local sink_node

    for source_node, supply in pairs(supplies) do
      if supply > limitation_epsilon and not visited[source_node] then
        queue_tail = queue_tail + 1
        queue[queue_tail] = source_node
        visited[source_node] = true
        source_of[source_node] = source_node
      end
    end

    while queue_head <= queue_tail do
      local node = queue[queue_head]
      queue_head = queue_head + 1
      local edges = adjacency[node]
      if not edges then
        goto bfs_continue
      end
      for i = 1, #edges do
        local edge_id = edges[i]
        local edge = residual_edges[edge_id]
        if edge.cap <= limitation_epsilon then
          goto edge_continue
        end
        local neighbor = edge.to
        if visited[neighbor] then
          goto edge_continue
        end
        visited[neighbor] = true
        parent_edge[neighbor] = edge_id
        parent_node[neighbor] = node
        source_of[neighbor] = source_of[node]
        if (demands[neighbor] or 0) > limitation_epsilon then
          sink_node = neighbor
          break
        end
        queue_tail = queue_tail + 1
        queue[queue_tail] = neighbor
        ::edge_continue::
      end
      if sink_node then
        break
      end
      ::bfs_continue::
    end

    if not sink_node then
      break
    end

    local source_node = source_of[sink_node]
    if not source_node then
      break
    end

    local bottleneck = math.min(flow_limit - flow, supplies[source_node] or 0, demands[sink_node] or 0)
    local trace_node = sink_node
    while trace_node ~= source_node do
      local edge_id = parent_edge[trace_node]
      if not edge_id then
        bottleneck = 0
        break
      end
      local edge = residual_edges[edge_id]
      bottleneck = math.min(bottleneck, edge.cap)
      trace_node = parent_node[trace_node]
    end

    if bottleneck <= limitation_epsilon then
      break
    end

    trace_node = sink_node
    while trace_node ~= source_node do
      local edge_id = parent_edge[trace_node]
      local edge = residual_edges[edge_id]
      edge.cap = edge.cap - bottleneck
      local reverse_edge = residual_edges[edge.rev]
      reverse_edge.cap = reverse_edge.cap + bottleneck
      local delta = edge.forward and bottleneck or -bottleneck
      edge_usage[edge.base_id] = (edge_usage[edge.base_id] or 0) + delta
      trace_node = parent_node[trace_node]
    end

    supplies[source_node] = (supplies[source_node] or 0) - bottleneck
    demands[sink_node] = (demands[sink_node] or 0) - bottleneck
    flow = flow + bottleneck
  end

  return flow
end

--- @param entity_rates table<string, table<string, Rates>>
--- @param rates table<string, Rates>
--- @param resource_type "item"|"fluid"
--- @param entry_node_by_entity table<string, string>
--- @param exit_node_by_entity table<string, string>
--- @return ResourcePathFlow[], double
local function build_resource_path_flows(entity_rates, rates, resource_type, entry_node_by_entity, exit_node_by_entity)
  --- @type table<string, table<string, double>>
  local producers_by_path = {}
  --- @type table<string, table<string, double>>
  local consumers_by_path = {}

  for entity_key, entity_rate_data in pairs(entity_rates) do
    for path, rate_data in pairs(entity_rate_data) do
      if rate_data.type ~= resource_type or excluded_limiting_paths[path] then
        goto continue
      end
      local output_rate = rate_data.output.rate
      local input_rate = rate_data.input.rate
      local local_transfer = math.min(output_rate, input_rate)
      output_rate = output_rate - local_transfer
      input_rate = input_rate - local_transfer
      if output_rate > limitation_epsilon then
        add_amount_by_path(producers_by_path, path, entity_key, output_rate)
      end
      if input_rate > limitation_epsilon then
        add_amount_by_path(consumers_by_path, path, entity_key, input_rate)
      end
      ::continue::
    end
  end

  --- @type ResourcePathFlow[]
  local path_flows = {}
  local total_demand = 0

  for path, aggregated in pairs(rates) do
    if aggregated.type ~= resource_type or excluded_limiting_paths[path] then
      goto continue
    end

    local demand = math.min(aggregated.output.rate, aggregated.input.rate)
    if demand <= limitation_epsilon then
      goto continue
    end

    local raw_producers = producers_by_path[path]
    local raw_consumers = consumers_by_path[path]
    if not raw_producers or not raw_consumers then
      goto continue
    end

    local mapped_producers = {}
    local mapped_consumers = {}
    local total_output = 0
    local total_input = 0

    for entity_key, amount in pairs(raw_producers) do
      local node = exit_node_by_entity[entity_key]
      if node then
        mapped_producers[node] = (mapped_producers[node] or 0) + amount
        total_output = total_output + amount
      end
    end
    for entity_key, amount in pairs(raw_consumers) do
      local node = entry_node_by_entity[entity_key]
      if node then
        mapped_consumers[node] = (mapped_consumers[node] or 0) + amount
        total_input = total_input + amount
      end
    end

    if total_output <= limitation_epsilon or total_input <= limitation_epsilon then
      goto continue
    end

    local capped_demand = math.min(demand, total_output, total_input)
    if capped_demand <= limitation_epsilon then
      goto continue
    end

    if not next(mapped_producers) or not next(mapped_consumers) then
      goto continue
    end

    path_flows[#path_flows + 1] = {
      consumers = mapped_consumers,
      demand = capped_demand,
      path = path,
      producers = mapped_producers,
    }
    total_demand = total_demand + capped_demand

    ::continue::
  end

  table.sort(path_flows, function(left, right)
    return left.demand > right.demand
  end)

  return path_flows, total_demand
end

--- @param graph TransportGraph
--- @param path_flows ResourcePathFlow[]
--- @return double, table<string, double>, table<string, double>, table<string, table<string, double>>
local function route_path_flows(graph, path_flows)
  if not next(graph.edges) or #path_flows == 0 then
    return 0, {}, {}, {}
  end

  local adjacency, residual_edges = build_residual_network(graph)
  local edge_usage = {}
  local delivered = 0
  local delivered_by_path = {}
  --- @type table<string, table<string, double>>
  local delivered_consumers_by_path = {}

  for i = 1, #path_flows do
    local path_flow = path_flows[i]
    local producers = copy_double_table(path_flow.producers)
    local initial_consumers = copy_double_table(path_flow.consumers)
    local consumers = copy_double_table(path_flow.consumers)
    local path_delivered = push_flow(adjacency, residual_edges, producers, consumers, path_flow.demand, edge_usage)
    delivered = delivered + path_delivered
    delivered_by_path[path_flow.path] = (delivered_by_path[path_flow.path] or 0) + path_delivered

    local delivered_consumers = {}
    for consumer_node, initial_demand in pairs(initial_consumers) do
      local delivered_amount = initial_demand - (consumers[consumer_node] or 0)
      if delivered_amount > limitation_epsilon then
        delivered_consumers[consumer_node] = delivered_amount
      end
    end
    delivered_consumers_by_path[path_flow.path] = delivered_consumers
  end

  local transfer_by_mode = {}
  for edge_id, usage in pairs(edge_usage) do
    if math.abs(usage) <= limitation_epsilon then
      goto continue
    end
    local mode = graph.edges[edge_id].mode
    if mode then
      transfer_by_mode[mode] = (transfer_by_mode[mode] or 0) + math.abs(usage)
    end
    ::continue::
  end

  return delivered, transfer_by_mode, delivered_by_path, delivered_consumers_by_path
end

--- @param source table<string, Rates>
--- @param scale double
--- @return table<string, Rates>
local function scale_rates_table(source, scale)
  local scaled = {}
  for path, source_rates in pairs(source) do
    if source_rates.input.rate <= limitation_epsilon and source_rates.output.rate <= limitation_epsilon then
      goto continue
    end

    local target_rates = {
      type = source_rates.type,
      name = source_rates.name,
      quality = source_rates.quality,
      temperature = source_rates.temperature,
      output = { machine_counts = {}, machines = 0, rate = 0 },
      input = { machine_counts = {}, machines = 0, rate = 0 },
    }
    add_scaled_rate(target_rates.input, source_rates.input, scale)
    add_scaled_rate(target_rates.output, source_rates.output, scale)
    scaled[path] = target_rates

    ::continue::
  end
  cleanup_rates(scaled)
  return scaled
end

--- Calculates effective rates constrained by selected logistics entities.
--- @param entities table<string, LuaEntity>
--- @param entity_rates table<string, table<string, Rates>>
--- @param rates table<string, Rates>
--- @param player LuaPlayer
--- @return table<string, Rates>, LogisticsData
function calc_util.calculate_logistics_limited_rates(entities, entity_rates, rates, player)
  entity_rates = entity_rates or {}

  local entity_key_lookup = build_entity_key_lookup(entities)
  local item_graph = build_item_transport_graph(entities, player, entity_key_lookup)
  local fluid_graph = build_fluid_transport_graph(entities, entity_key_lookup)

  local item_path_flows, item_demand =
    build_resource_path_flows(entity_rates, rates, "item", item_graph.entry_node_by_entity, item_graph.exit_node_by_entity)
  local fluid_path_flows, fluid_demand = build_resource_path_flows(
    entity_rates,
    rates,
    "fluid",
    fluid_graph.entry_node_by_entity,
    fluid_graph.exit_node_by_entity
  )

  local delivered_items, item_transfer_by_mode, delivered_item_by_path, delivered_item_consumers_by_path =
    route_path_flows(item_graph, item_path_flows)
  local delivered_fluids, fluid_transfer_by_mode, delivered_fluid_by_path, delivered_fluid_consumers_by_path =
    route_path_flows(fluid_graph, fluid_path_flows)

  local logistics_caps_by_path = {}
  for path, delivered in pairs(delivered_item_by_path) do
    logistics_caps_by_path[path] = delivered
  end
  for path, delivered in pairs(delivered_fluid_by_path) do
    logistics_caps_by_path[path] = delivered
  end

  local item_entity_by_entry_node = {}
  for entity_key, entry_node in pairs(item_graph.entry_node_by_entity) do
    item_entity_by_entry_node[entry_node] = entity_key
  end
  local fluid_entity_by_entry_node = {}
  for entity_key, entry_node in pairs(fluid_graph.entry_node_by_entity) do
    fluid_entity_by_entry_node[entry_node] = entity_key
  end

  --- @type table<string, table<string, double>>
  local logistics_input_caps_by_path = {}
  for path, node_caps in pairs(delivered_item_consumers_by_path) do
    local entity_caps = {}
    for node, delivered in pairs(node_caps) do
      local entity_key = item_entity_by_entry_node[node]
      if entity_key then
        entity_caps[entity_key] = (entity_caps[entity_key] or 0) + delivered
      end
    end
    logistics_input_caps_by_path[path] = entity_caps
  end
  for path, node_caps in pairs(delivered_fluid_consumers_by_path) do
    local entity_caps = logistics_input_caps_by_path[path] or {}
    for node, delivered in pairs(node_caps) do
      local entity_key = fluid_entity_by_entry_node[node]
      if entity_key then
        entity_caps[entity_key] = (entity_caps[entity_key] or 0) + delivered
      end
    end
    logistics_input_caps_by_path[path] = entity_caps
  end

  local item_scale = item_demand <= limitation_epsilon and 1 or math.min(1, delivered_items / item_demand)
  local fluid_scale = fluid_demand <= limitation_epsilon and 1 or math.min(1, delivered_fluids / fluid_demand)
  local scale = math.min(item_scale, fluid_scale)

  local inserter_capacity = item_graph.capacities.inserter or 0
  local belt_capacity = item_graph.capacities.belt or 0
  local pipe_capacity = fluid_graph.capacities.pipe or 0
  local pump_capacity = fluid_graph.capacities.pump or 0

  local inserter_transfer = item_transfer_by_mode.inserter or 0
  local belt_transfer = item_transfer_by_mode.belt or 0
  local pipe_transfer = fluid_transfer_by_mode.pipe or 0
  local pump_transfer = fluid_transfer_by_mode.pump or 0

  --- @type LogisticsData
  local logistics_data = {
    item_demand = item_demand,
    fluid_demand = fluid_demand,
    inserter_capacity = inserter_capacity,
    belt_capacity = belt_capacity,
    pipe_capacity = pipe_capacity,
    pump_capacity = pump_capacity,
    item_scale = item_scale,
    fluid_scale = fluid_scale,
    scale = scale,
    inserter_transfer = inserter_transfer,
    belt_transfer = belt_transfer,
    pipe_transfer = pipe_transfer,
    pump_transfer = pump_transfer,
  }

  local limited_rates =
    calc_util.calculate_limited_rates(entity_rates, rates, logistics_caps_by_path, logistics_input_caps_by_path)
  return limited_rates, logistics_data
end

local simplex_epsilon = 0.000000001

--- @param D table<integer, table<integer, double>>
--- @param B table<integer, integer>
--- @param N table<integer, integer>
--- @param m integer
--- @param n integer
--- @param r integer
--- @param s integer
local function simplex_pivot(D, B, N, m, n, r, s)
  local inverse = 1 / D[r][s]
  for i = 1, m + 2 do
    if i == r then
      goto row_continue
    end
    for j = 1, n + 2 do
      if j == s then
        goto col_continue
      end
      D[i][j] = D[i][j] - D[r][j] * D[i][s] * inverse
      ::col_continue::
    end
    ::row_continue::
  end
  for j = 1, n + 2 do
    if j ~= s then
      D[r][j] = D[r][j] * inverse
    end
  end
  for i = 1, m + 2 do
    if i ~= r then
      D[i][s] = -D[i][s] * inverse
    end
  end
  D[r][s] = inverse

  local basis_value = B[r]
  B[r] = N[s]
  N[s] = basis_value
end

--- @param D table<integer, table<integer, double>>
--- @param B table<integer, integer>
--- @param N table<integer, integer>
--- @param m integer
--- @param n integer
--- @param phase integer
--- @return boolean
local function simplex_phase(D, B, N, m, n, phase)
  local objective_row = phase == 1 and (m + 2) or (m + 1)
  while true do
    local s
    for j = 1, n + 1 do
      if phase == 2 and N[j] == -1 then
        goto continue
      end
      if not s
        or D[objective_row][j] < D[objective_row][s] - simplex_epsilon
        or (
          math.abs(D[objective_row][j] - D[objective_row][s]) <= simplex_epsilon
          and N[j] < N[s]
        )
      then
        s = j
      end
      ::continue::
    end
    if not s or D[objective_row][s] >= -simplex_epsilon then
      return true
    end

    local r
    for i = 1, m do
      if D[i][s] <= simplex_epsilon then
        goto continue
      end
      local ratio = D[i][n + 2] / D[i][s]
      local best_ratio = r and (D[r][n + 2] / D[r][s]) or 0
      if not r
        or ratio < best_ratio - simplex_epsilon
        or (math.abs(ratio - best_ratio) <= simplex_epsilon and B[i] < B[r])
      then
        r = i
      end
      ::continue::
    end

    if not r then
      return false
    end

    simplex_pivot(D, B, N, m, n, r, s)
  end
end

--- @param A table<integer, table<integer, double>>
--- @param b table<integer, double>
--- @param c table<integer, double>
--- @return table<integer, double>?, double?, string?
local function simplex_maximize(A, b, c)
  local m = #A
  local n = #c

  --- @type table<integer, table<integer, double>>
  local D = {}
  for i = 1, m + 2 do
    local row = {}
    for j = 1, n + 2 do
      row[j] = 0
    end
    D[i] = row
  end

  --- @type table<integer, integer>
  local B = {}
  --- @type table<integer, integer>
  local N = {}

  for i = 1, m do
    B[i] = n + i
    for j = 1, n do
      D[i][j] = A[i][j] or 0
    end
    D[i][n + 1] = -1
    D[i][n + 2] = b[i] or 0
  end

  for j = 1, n do
    N[j] = j
    D[m + 1][j] = -(c[j] or 0)
  end
  N[n + 1] = -1
  D[m + 2][n + 1] = 1

  if m > 0 then
    local r = 1
    for i = 2, m do
      if D[i][n + 2] < D[r][n + 2] then
        r = i
      end
    end

    if D[r][n + 2] < -simplex_epsilon then
      simplex_pivot(D, B, N, m, n, r, n + 1)
      if not simplex_phase(D, B, N, m, n, 1) or D[m + 2][n + 2] < -simplex_epsilon then
        return nil, nil, "infeasible"
      end
      if math.abs(D[m + 2][n + 2]) > simplex_epsilon then
        return nil, nil, "infeasible"
      end
      for i = 1, m do
        if B[i] == -1 then
          local s
          for j = 1, n + 1 do
            if not s
              or D[i][j] < D[i][s] - simplex_epsilon
              or (math.abs(D[i][j] - D[i][s]) <= simplex_epsilon and N[j] < N[s])
            then
              s = j
            end
          end
          if s then
            simplex_pivot(D, B, N, m, n, i, s)
          end
        end
      end
    end
  end

  if not simplex_phase(D, B, N, m, n, 2) then
    return nil, nil, "unbounded"
  end

  local x = {}
  for j = 1, n do
    x[j] = 0
  end
  for i = 1, m do
    if B[i] >= 1 and B[i] <= n then
      x[B[i]] = D[i][n + 2]
    end
  end
  return x, D[m + 1][n + 2], nil
end

--- Calculates effective rates constrained by internally available ingredients.
--- @param entity_rates table<string, table<string, Rates>>
--- @param fallback_rates table<string, Rates>
--- @param max_output_by_path table<string, double>?
--- @param max_input_by_path table<string, table<string, double>>?
--- @return table<string, Rates>
function calc_util.calculate_limited_rates(entity_rates, fallback_rates, max_output_by_path, max_input_by_path)
  if not next(entity_rates) then
    return copy_rates_table(fallback_rates)
  end

  local variable_rates, variable_upper_bounds, variable_keys = collect_limiting_variables(entity_rates, max_input_by_path)
  local variable_count = #variable_rates
  if variable_count == 0 then
    return copy_rates_table(fallback_rates)
  end

  --- @type table<string, VariableFlow[]>
  local consumers_by_path = {}
  --- @type table<string, VariableFlow[]>
  local producers_by_path = {}
  for i = 1, variable_count do
    local rates = variable_rates[i]
    local key = variable_keys[i]
    for path, rate_data in pairs(rates) do
      local input_rate = rate_data.input.rate
      if input_rate > limitation_epsilon then
        add_variable_flow(consumers_by_path, path, i, input_rate, key)
      end
      local output_rate = rate_data.output.rate
      if output_rate > limitation_epsilon then
        add_variable_flow(producers_by_path, path, i, output_rate, key)
      end
    end
  end

  local has_constraints = false
  --- @type table<integer, table<integer, double>>
  local A = {}
  --- @type table<integer, double>
  local b = {}

  --- @param coeffs table<integer, double>
  --- @param rhs double
  local function add_constraint(coeffs, rhs)
    local row = {}
    for i = 1, variable_count do
      row[i] = coeffs[i] or 0
    end
    A[#A + 1] = row
    b[#b + 1] = rhs
    has_constraints = true
  end

  for path, consumers in pairs(consumers_by_path) do
    if excluded_limiting_paths[path] then
      goto continue
    end
    local producers = producers_by_path[path]
    if not producers then
      goto continue -- External ingredient: don't constrain.
    end

    local balance_coeffs = {}
    for i = 1, #consumers do
      local flow = consumers[i]
      local index = flow.index
      balance_coeffs[index] = (balance_coeffs[index] or 0) + flow.amount
    end
    for i = 1, #producers do
      local flow = producers[i]
      local index = flow.index
      balance_coeffs[index] = (balance_coeffs[index] or 0) - flow.amount
    end
    add_constraint(balance_coeffs, 0)

    local max_output = max_output_by_path and max_output_by_path[path]
    if max_output then
      local cap_coeffs = {}
      for i = 1, #consumers do
        local flow = consumers[i]
        local index = flow.index
        cap_coeffs[index] = (cap_coeffs[index] or 0) + flow.amount
      end
      add_constraint(cap_coeffs, max_output)
    end

    local max_inputs = max_input_by_path and max_input_by_path[path]
    if max_inputs then
      for i = 1, #consumers do
        local flow = consumers[i]
        local index = flow.index
        if index then
          local coeffs = {}
          coeffs[index] = flow.amount
          add_constraint(coeffs, max_inputs[flow.key] or 0)
        end
      end
    end

    ::continue::
  end

  if not has_constraints then
    return copy_rates_table(fallback_rates)
  end

  for i = 1, variable_count do
    local coeffs = {}
    coeffs[i] = 1
    add_constraint(coeffs, variable_upper_bounds[i] or 1)
  end

  local final_paths = {}
  for path, rates in pairs(fallback_rates) do
    if excluded_limiting_paths[path] then
      goto continue
    end
    -- "Final products": internally produced but not internally consumed within the current selection.
    if rates.output.rate > limitation_epsilon and rates.input.rate <= limitation_epsilon then
      final_paths[path] = true
    end
    ::continue::
  end

  local primary_objective = {}
  for i = 1, variable_count do
    primary_objective[i] = 0
  end
  local has_objective = false
  for i = 1, variable_count do
    local rates = variable_rates[i]
    for path in pairs(final_paths) do
      local rate_data = rates[path]
      if rate_data then
        local net = rate_data.output.rate - rate_data.input.rate
        if net > limitation_epsilon then
          primary_objective[i] = primary_objective[i] + net
          has_objective = true
        end
      end
    end
  end

  if not has_objective then
    for i = 1, variable_count do
      local rates = variable_rates[i]
      for path, rate_data in pairs(rates) do
        if excluded_limiting_paths[path] then
          goto continue
        end
        local net = rate_data.output.rate - rate_data.input.rate
        if net > limitation_epsilon then
          primary_objective[i] = primary_objective[i] + net
          has_objective = true
        end
        ::continue::
      end
    end
  end

  -- If there are no net-positive paths, optimize downstream consumers of internally produced resources.
  -- This avoids the ambiguous "maximize all machines equally" behavior in closed production graphs.
  if not has_objective then
    for i = 1, variable_count do
      local rates = variable_rates[i]
      for path, rate_data in pairs(rates) do
        if excluded_limiting_paths[path] then
          goto continue
        end
        if rate_data.input.rate > limitation_epsilon and producers_by_path[path] then
          primary_objective[i] = primary_objective[i] + rate_data.input.rate
          has_objective = true
        end
        ::continue::
      end
    end
  end

  if not has_objective then
    return copy_rates_table(fallback_rates)
  end

  local primary_solution, primary_value, error_kind = simplex_maximize(A, b, primary_objective)
  if not primary_solution then
    if error_kind == "unbounded" then
      return copy_rates_table(fallback_rates)
    end
    return {}
  end

  --- @type table<integer, double>
  local solution = primary_solution

  -- Secondary objectives are lexicographic by dependency depth:
  -- 1) keep primary optimum
  -- 2) maximize intermediate outputs closest to finals
  -- 3) then maximize deeper and deeper intermediate layers
  -- 4) finally maximize active machine scales as a stable tie-breaker
  -- This keeps shortages on the lowest-level ingredients even in long chains.
  local constrained_A = {}
  for i = 1, #A do
    constrained_A[i] = A[i]
  end
  local constrained_b = {}
  for i = 1, #b do
    constrained_b[i] = b[i]
  end

  add_objective_lock(constrained_A, constrained_b, primary_objective, primary_value, variable_count)

  local level_sets, internal_paths =
    build_intermediate_level_sets(variable_rates, producers_by_path, consumers_by_path, final_paths)
  local ordered_levels = {}
  for level in pairs(level_sets) do
    ordered_levels[#ordered_levels + 1] = level
  end
  table.sort(ordered_levels)

  if #ordered_levels > 0 then
    for level_index = 1, #ordered_levels do
      local level = ordered_levels[level_index]
      local level_objective, has_level_objective =
        build_path_output_objective(variable_rates, variable_count, level_sets[level])
      if has_level_objective then
        local level_solution, level_value = simplex_maximize(constrained_A, constrained_b, level_objective)
        if level_solution then
          solution = level_solution
          add_objective_lock(constrained_A, constrained_b, level_objective, level_value, variable_count)
        end
      end
    end
  else
    -- Fallback for disconnected/closed graphs: still prioritize all internal intermediates.
    local intermediate_objective, has_intermediate_objective =
      build_path_output_objective(variable_rates, variable_count, internal_paths)
    if has_intermediate_objective then
      local intermediate_solution, intermediate_value =
        simplex_maximize(constrained_A, constrained_b, intermediate_objective)
      if intermediate_solution then
        solution = intermediate_solution
        add_objective_lock(constrained_A, constrained_b, intermediate_objective, intermediate_value, variable_count)
      end
    end
  end

  local activity_objective = {}
  for i = 1, variable_count do
    activity_objective[i] = 1
  end

  local activity_solution = simplex_maximize(constrained_A, constrained_b, activity_objective)
  if activity_solution then
    solution = activity_solution
  end

  local all_full = true
  for i = 1, variable_count do
    local scale = solution[i] or 0
    local full_scale = variable_upper_bounds[i] or 1
    if scale < full_scale - limitation_epsilon then
      all_full = false
      break
    end
  end
  if all_full then
    return copy_rates_table(fallback_rates)
  end

  --- @type table<string, Rates>
  local limited_rates = {}
  for i = 1, variable_count do
    local scale = solution[i] or 0
    if scale <= limitation_epsilon then
      goto continue_entity
    end
    local rates = variable_rates[i]
    for path, source_rates in pairs(rates) do
      local target_rates = limited_rates[path]
      if not target_rates then
        target_rates = {
          type = source_rates.type,
          name = source_rates.name,
          quality = source_rates.quality,
          temperature = source_rates.temperature,
          output = { machine_counts = {}, machines = 0, rate = 0 },
          input = { machine_counts = {}, machines = 0, rate = 0 },
        }
        limited_rates[path] = target_rates
      end
      add_scaled_rate(target_rates.input, source_rates.input, scale)
      add_scaled_rate(target_rates.output, source_rates.output, scale)
    end
    ::continue_entity::
  end

  cleanup_rates(limited_rates)
  return limited_rates
end

return calc_util
