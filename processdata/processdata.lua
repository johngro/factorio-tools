local Process = {}

-- These paths don't appear in the datafiles in the usual fashion.
local unique_paths = {
	["__base__/graphics/icons/coal.png"] = "__base__/graphics/icons/icons-new/coal.png",
	["__base__/graphics/icons/copper-ore.png"] = "__base__/graphics/icons/icons-new/copper-ore.png",
	["__base__/graphics/icons/iron-ore.png"] = "__base__/graphics/icons/icons-new/iron-ore.png",
	["__base__/graphics/icons/stone.png"] = "__base__/graphics/icons/icons-new/stone.png",
	["__base__/graphics/icons/uranium-ore.png"] = "__base__/graphics/icons/icons-new/uranium-ore.png",
}

local missing_icon = "__core__/graphics/too-far.png"

local function get_icon(data, path)
	if unique_paths[path] ~= nil then
		path = unique_paths[path]
	end
	local mod_name, icon_path = string.match(path, "__([%w%s_%-]+)__/(.*)")
	local mod = data.module_info[mod_name]
	if mod.localPath ~= nil then
		local fullpath = mod.localPath .. "/" .. icon_path
		return {source = "file", path = fullpath}
	else
		return {source = "zip", zipfile = mod.zip_path, path = mod.mod_name .. "/" .. icon_path}
	end
end

local function normalize_recipe(r)
	if r.result ~= nil then
		local amount = r.result_count
		if amount == nil then
			amount = 1
		end
		r.results = {{
			name = r.result,
			amount = amount,
		}}
		r.result = nil
		r.result_count = nil
	end
	for i, result in ipairs(r.results) do
		if result.amount == nil then
			-- If this recipe is missing an amount, but has a min/max amount,
			-- then just output it as it is.  Some of Bob's recipies (like
			-- cobalt-oxide-from-copper) output ranges instead of fixed amounts.
			-- This will be handled on the javascript side of things.
			if result.amount_min == nil and result.amount_max == nil then
				r.results[i] = {name = result[1], amount = result[2]}
			end
		end
	end
	if r.energy_required == nil then
		r.energy_required = 0.5
	end
	if r.category == nil then
		r.category = "crafting"
	end
	local ings = {}
	for i, ing in ipairs(r.ingredients) do
		if ing.name == nil then
			table.insert(ings, {name = ing[1], amount = ing[2]})
		else
			table.insert(ings, ing)
		end
	end
	r.ingredients = ings
end

local conversion_factor = {
	[""] = 1,
	["k"] = 1000,
	["M"] = 1000000,
	["G"] = 1000000000,
}

local function convert_power(s)
	local quantity, unit = string.match(s, "([^%a]+)(%a?)[WJ]")
	local factor = conversion_factor[unit]
	return tonumber(quantity) * factor
end

local function convert(d, attr)
	d[attr] = convert_power(d[attr])
end

local function copytable(t)
	local new = {}
	for k, v in pairs(t) do
		new[k] = v
	end
	return new
end

local function path_stem(path)
	return string.match(path, ".*/([^/]*)%.[^/%.]+$")
end

local function icon_compare(a, b)
	local stem_a = path_stem(a)
	local stem_b = path_stem(b)
	if stem_a == stem_b then
		return a < b
	end
	return stem_a < stem_b
end

local function localize_name(locale, name)
	local function lookup(str)
		local section, item = str:match("(.-)%.(.*)")
		return locale[section][item]
	end

	return lookup(name[1]):gsub("__(%d+)__", function(ndx)
		return lookup(name[2][tonumber(ndx)])
	end)
end

local function expand_locale_templates(locale)
	-- make multiple passes over the locale tables attempting to expand all of
	-- the templates that we encounter.  Stop when we are no longer changing
	-- strings, or when we have cycled an excessive number of times (there might
	-- be a cycle in the graph somewhere)
	local total_cycles = 0
	while true do
		local total_count = 0
		for section_ndx, section in pairs(locale) do
			for string_name, s in pairs(section) do
				local new_str = s:gsub("__(.-)__(.-)__", function(section, name)
					section = section:lower() .. "-name"
					if (locale[section]) then
						return locale[section][name]
					end
					return nil
				end)

				if locale[section_ndx][string_name] ~= new_str then
					locale[section_ndx][string_name] = new_str
					total_count = total_count + 1
				end
			end
		end
		total_cycles = total_cycles + 1
		if (total_count == 0) or (total_cycles > 10) then
			break;
		end
	end
end

function Process.process_data(data, locales, verbose)
	local function msg(...)
		if verbose then
			print(...)
		end
	end
	local function assign_localized_name(locale, raw_object, new_object, fallback)
		-- If this is:
		-- 1) A recipe with a single result field, and
		-- 2) The recipe does not have a native localised name, and
		-- 3) The result item can be found in our raw item data
		--
		-- then use that item's raw data to generate our name instead of using
		-- the recipe's raw data.  This helps with some mod overrides.	For
		-- example, Bob's inserter mods overrides the recipe for
		-- "long-handed-inserter" to take different ingredients but still
		-- produce a "long-handed-inserter".  The "long-handed-inserter" item,
		-- however, ends up _placing_ a "red-inserter", and the "red-inserter"'s
		-- name will localize (in English) to "Fast Inserter", which is really
		-- what we want to show.
		--
		if raw_object.localised_name == nil and raw_object.type == "recipe" and raw_object.result ~= nil then 
			local item = data["item"][raw_object.result]
			if item ~= nil then
				raw_object = item
			end
		end

		if raw_object.localised_name then
			new_object.localized_name = {en = localize_name(locale, raw_object.localised_name)}
		else
			local locale_sections = {"recipe-name", "item-name", "fluid-name", "equipment-name", "entity-name"}
			local localized_name = nil

			for _, obj in ipairs({raw_object, fallback}) do
				-- By default, use the object's |name| field as we attempt to find a localization
				-- for it in the tables.
				--
				-- If the object is an item, and it has a place_result, use that as the name to look
				-- up.	Bob's inserter mods, for example, overrides "long-handed-inserter" to place
				-- a "red-inserter" instead, and the "red-inserter"s English localization is "Fast
				-- Inserter".
				local name = obj.name
				if obj.type == "item" and obj.place_result ~= nil then
					name = obj.place_result
				end

				for _, section in ipairs(locale_sections) do
					localized_name = locale[section][name]
					if localized_name ~= nil then
						goto found
					end
				end
			end
			::found::
			if localized_name == nil then
				msg("no localized name for", raw_object.type, "named", raw_object.name)
			else
				new_object.localized_name = {en = localized_name}
			end
		end
	end

	-- Limit it to English for now.
	local locale = locales["en"]
	expand_locale_templates(locale)

	local item_types = {"ammo", "armor", "blueprint", "blueprint-book", "capsule", "deconstruction-item", "fluid", "gun", "item", "item-with-entity-data", "mining-tool", "module", "rail-planner", "repair-tool", "tool"}
	local no_module_icon = data["utility-sprites"]["default"]["slot_icon_module"]["filename"]
	local clock_icon = data["utility-sprites"]["default"]["clock"]["filename"]
	local icon_paths = {[no_module_icon] = true, [clock_icon] = true}
	-- Normalize items
	local item_groups = {}
	for name, d in pairs(data["item-group"]) do
		item_groups[d.name] = {order = d.order, subgroups = {}}
	end
	local item_subgroups = data["item-subgroup"]
	for name, d in pairs(item_subgroups) do
		item_groups[d["group"]]["subgroups"][name] = d["order"]
	end
	local items = {}
	local fuel = {}
	local item_attrs = {"category", "effect", "fuel_category", "fuel_value", "icon", "icons", "limitation", "name", "order", "stack_size", "subgroup", "type"}
	for i, item_type in ipairs(item_types) do
		for name, item in pairs(data[item_type]) do
			local new_item = {}
			for j, attr in ipairs(item_attrs) do
				if item[attr] ~= nil then
					new_item[attr] = item[attr]
				end
			end
			assign_localized_name(locale, item, new_item)
			item = new_item
			local subgroup
			if item.subgroup ~= nil then
				subgroup = item["subgroup"]
			else
				subgroup = "other"
				item["subgroup"] = "other"
			end
			if subgroup == "fill-barrel" or subgroup == "bob-gas-bottle" then
				goto continue
			end
			item["group"] = item_subgroups[subgroup]["group"]
			if item.icon == nil then
				if item.icons == nil then
					msg("skipped:", item)
					goto continue
				end
				-- XXX: Temporary hack.
				msg("hack icon:", name)
				item["icon"] = item["icons"][1]["icon"]
				if item.icon == nil then
					print("icon still nil:", name)
				end
				item["icons"] = nil
				--item["icon"] = missing_icon
			end
			icon_paths[item["icon"]] = true
			if item.fuel_value ~= nil and item.fuel_category ~= nil then
				convert(item, "fuel_value")
				--if "fuel_category" not in item:
				--	print(item)
				if item["fuel_category"] == "chemical" then
					table.insert(fuel, name)
				end
			end
			items[name] = item
			::continue::
		end
	end
	local fluids = {}
	for name, d in pairs(data.fluid) do
		table.insert(fluids, name)
	end
	table.sort(fluids)
	table.sort(fuel)
	local modules = {}
	for name, d in pairs(data["module"]) do
		table.insert(modules, name)
	end
	table.sort(modules)
	local new_data = {
		items = items,
		fluids = fluids,
		fuel = fuel,
		modules = modules,
		groups = item_groups,
	}
	-- Normalize recipes
	local inherited_attrs = {"subgroup", "order", "icon"}
	local normal_recipes = {}
	local expensive_recipes = {}
	for name, raw_recipe in pairs(data["recipe"]) do
		--for recipe_type, recipes in [("normal", normal_recipes), ("expensive", expensive_recipes)]:
		for i, r in ipairs({{recipe_type = "normal", recipes = normal_recipes}, {recipe_type = "expensive", recipes = expensive_recipes}}) do
			--overlap = set(raw_recipe.get(recipe_type, {})) & set(raw_recipe)
			--if overlap:
			--	print("overlap:", recipe_type, name, overlap)
			local recipe = copytable(raw_recipe)
			if recipe[r.recipe_type] ~= nil then
				for k, v in pairs(recipe[r.recipe_type]) do
					recipe[k] = v
				end
			end
			recipe.expensive = nil
			recipe.normal = nil
			-- The main_product docs are confusing and possibly contradicted by
			-- its observed behavior. We're going to do what I think is the most
			-- sensible thing:
			--
			-- If any of the icon, subgroup, or order are not provided, inherit
			-- them from the main_product if it is defined; otherwise, inherit 
			-- from the (singular) result.
			local main_product
			if recipe.result ~= nil or recipe.results ~= nil and #recipe.results == 1 then
				local result
				if recipe.result ~= nil then
					result = recipe["result"]
				else
					result = recipe["results"][1]["name"]
				end
				if recipe.main_product ~= nil and recipe.main_product ~= "" then
					if recipe["main_product"] ~= result then
						msg("main_product differs from result:", name)
					end
				end
				if items[result] ~= nil then
					main_product = items[result]
				else
					msg("main product does not exist:", name)
				end
			end
			if (main_product == nil or main_product ==  "") and items[name] ~= nil then
				msg("fell back on name:", name)
				main_product = items[name]
			elseif recipe.main_product ~= nil and recipe.main_product ~= "" then
				main_product = items[recipe["main_product"]]
				if main_product == nil then
					msg("main product is nil:", recipe.main_product)
				end
				recipe["display_name"] = main_product["name"]
			end
			if main_product ~= nil then
				for i, attr in ipairs(inherited_attrs) do
					if recipe[attr] == nil then
						recipe[attr] = main_product[attr]
					end
				end
			end
			--if "main_product" in recipe:
			--	item = items[recipe["main_product"]]
			--	for attr in inherited_attrs:
			for i, attr in ipairs(inherited_attrs) do
				if recipe[attr] == nil then
					msg("recipe skip:", name, "because of", attr)
					goto continue
				end
			end
			if recipe.subgroup == "empty-barrel" or recipe.subgroup == "fill-barrel" then
				goto continue
			end
			icon_paths[recipe.icon] = true
			normalize_recipe(recipe)
			assign_localized_name(locale, raw_recipe, recipe, recipe.results[1])
			r.recipes[name] = recipe
			::continue::
		end
	end
--		if "expensive" in recipe:
--			normal = recipe.copy()
--			del normal["expensive"]
--			del normal["normal"]
--			expensive = normal.copy()
--			normal.update(recipe["normal"])
--			normalize_recipe(normal)
--			normal_recipes[name] = normal
--			expensive.update(recipe["expensive"])
--			normalize_recipe(expensive)
--			expensive_recipes[name] = expensive
--		else:
--			normalize_recipe(recipe)
--			normal_recipes[name] = recipe
--			expensive_recipes[name] = recipe
	-- Normalize entities
	local entity_attrs = {
		["accumulator"] = {"energy_source"},
		["assembling-machine"] = {"allowed_effects", "crafting_categories", "crafting_speed", "energy_source", "energy_usage", "ingredient_count", "module_specification"},
		["boiler"] = {"energy_consumption", "energy_source"},
		["furnace"] = {"allowed_effects", "crafting_categories", "crafting_speed", "energy_source", "energy_usage", "module_specification"},
		["generator"] = {"effectivity", "fluid_usage_per_tick"},
		["mining-drill"] = {"energy_source", "energy_usage", "mining_power", "mining_speed", "module_specification", "resource_categories"},
		["offshore-pump"] = {"fluid", "pumping_speed"},
		["reactor"] = {"burner", "consumption"},
		["resource"] = {"category", "minable"},
		["rocket-silo"] = {"active_energy_usage", "allowed_effects", "crafting_categories", "crafting_speed", "energy_usage", "idle_energy_usage", "lamp_energy_usage", "module_specification", "rocket_parts_required"},
		["solar-panel"] = {"production"},
		["transport-belt"] = {"speed"},
	}
	for entity_type, attrs in pairs(entity_attrs) do
		local entities = {}
		new_data[entity_type] = entities
		for name, entity in pairs(data[entity_type]) do
			if entity.icon == nil then
				msg("entity missing icon:", name)
				entity["icon"] = missing_icon
			end
			icon_paths[entity["icon"]] = true
			local new_entity = {name = entity.name, icon = entity.icon}
			assign_localized_name(locale, entity, new_entity)
			local has_modules = false
			for i, attr in ipairs(attrs) do
				if attr == "module_specification" then
					has_modules = true
				end
				new_entity[attr] = entity[attr]
			end
			if new_entity.module_specification ~= nil then
				new_entity["module_slots"] = new_entity["module_specification"]["module_slots"]
				new_entity["module_specification"] = nil
			elseif has_modules then
				new_entity["module_slots"] = 0
			end
			if new_entity.energy_usage ~= nil then
				convert(new_entity, "energy_usage")
			end
			if new_entity.minable ~= nil then
				local m = new_entity["minable"]
				if m.result ~= nil then
					m["results"] = {{
						name = m.result,
						amount = 1,
					}}
					m.result = nil
				end
			end
			entities[name] = new_entity
		end
		new_data[entity_type] = entities
	end

	local icons = {}
	for path, v in pairs(icon_paths) do
		table.insert(icons, path)
	end
	table.sort(icons, icon_compare)
	local width = math.floor(math.sqrt(#icons))
	local icon_map = {}
	local resolved_icons = {}
	for i, path in ipairs(icons) do
		local row = math.floor((i - 1) / width)
		local col = (i - 1) % width
		icon_map[path] = {col = col, row = row}
		table.insert(resolved_icons, get_icon(data, path))
	end
	local mod = icon_map[no_module_icon]
	local clock = icon_map[clock_icon]
	-- Add hash later.
	new_data["sprites"] = {
		extra = {
			slot_icon_module = {
				name = "no module",
				icon_col = mod.col,
				icon_row = mod.row,
			},
			clock = {
				name = "time",
				icon_col = clock.col,
				icon_row = clock.row,
			},
		},
	}
	local icon_sources = {new_data.items, normal_recipes, expensive_recipes}
	for source, attrs in pairs(entity_attrs) do
		table.insert(icon_sources, new_data[source])
	end
	for i, group in ipairs(icon_sources) do
		for name, d in pairs(group) do
			if d.icon ~= nil then
				local i = icon_map[d.icon]
				d["icon_col"] = i.col
				d["icon_row"] = i.row
				d.icon = nil
			end
		end
	end
	local version = data["module_info"]["core"]["version"]
	return {
		data = new_data,
		normal = normal_recipes,
		expensive = expensive_recipes,
		icons = resolved_icons,
		width = width,
		version = version,
	}
end

return Process
