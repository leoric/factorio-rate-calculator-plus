local calc_util = require("scripts.calc-util")

--- @class CalcCache
local calc_cache = {}

--- @type LogisticsData
local empty_logistics_data = {
  item_demand = 0,
  fluid_demand = 0,
  inserter_capacity = 0,
  belt_capacity = 0,
  pipe_capacity = 0,
  pump_capacity = 0,
  item_scale = 1,
  fluid_scale = 1,
  scale = 1,
  inserter_transfer = 0,
  belt_transfer = 0,
  pipe_transfer = 0,
  pump_transfer = 0,
}

--- @param set CalculationSet
function calc_cache.invalidate(set)
  set.limited_rates = nil
  set.logistics_limited_rates = nil
  set.fully_limited_rates = nil
  set.logistics_data = nil
  set.limited_logistics_data = nil
end

--- @param set CalculationSet
--- @return table<string, Rates>
function calc_cache.ensure_limited_rates(set)
  local limited_rates = set.limited_rates
  if limited_rates then
    return limited_rates
  end
  limited_rates = calc_util.calculate_limited_rates(set.entity_rates, set.rates)
  set.limited_rates = limited_rates
  return limited_rates
end

--- @param set CalculationSet
--- @return table<string, Rates>, LogisticsData
function calc_cache.ensure_logistics_rates(set)
  local logistics_limited_rates = set.logistics_limited_rates
  if logistics_limited_rates then
    return logistics_limited_rates, set.logistics_data or empty_logistics_data
  end
  logistics_limited_rates, set.logistics_data =
    calc_util.calculate_logistics_limited_rates(set.entities, set.entity_rates, set.rates, set.player)
  set.logistics_limited_rates = logistics_limited_rates
  return logistics_limited_rates, set.logistics_data or empty_logistics_data
end

--- @param set CalculationSet
--- @return table<string, Rates>, LogisticsData
function calc_cache.ensure_fully_limited_rates(set)
  local fully_limited_rates = set.fully_limited_rates
  if fully_limited_rates then
    return fully_limited_rates, set.limited_logistics_data or empty_logistics_data
  end
  local limited_rates = calc_cache.ensure_limited_rates(set)
  fully_limited_rates, set.limited_logistics_data =
    calc_util.calculate_logistics_limited_rates(set.entities, set.entity_rates, limited_rates, set.player)
  set.fully_limited_rates = fully_limited_rates
  return fully_limited_rates, set.limited_logistics_data or empty_logistics_data
end

--- @param set CalculationSet
--- @param limit_final_products boolean
--- @param limit_logistics boolean
--- @return table<string, Rates>
function calc_cache.get_rates_table(set, limit_final_products, limit_logistics)
  if limit_logistics then
    if limit_final_products then
      local rates = calc_cache.ensure_fully_limited_rates(set)
      return rates
    end
    local rates = calc_cache.ensure_logistics_rates(set)
    return rates
  end
  if limit_final_products then
    return calc_cache.ensure_limited_rates(set)
  end
  return set.rates
end

--- @param set CalculationSet
--- @param limit_final_products boolean
--- @param limit_logistics boolean
--- @return LogisticsData
function calc_cache.get_logistics_data(set, limit_final_products, limit_logistics)
  if not limit_logistics then
    if limit_final_products then
      return set.limited_logistics_data or empty_logistics_data
    end
    return set.logistics_data or empty_logistics_data
  end
  if limit_final_products then
    local _, logistics_data = calc_cache.ensure_fully_limited_rates(set)
    return logistics_data
  end
  local _, logistics_data = calc_cache.ensure_logistics_rates(set)
  return logistics_data
end

return calc_cache
