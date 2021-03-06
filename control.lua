require "mod-gui"
require "util"

local WAIT_CONDITIONS = {"time", "inactivity", "full", "empty", "item_count", "circuit", "robots_inactive", "fluid_count"}
local COMPARATORS = {"<", ">", "=", "≥", "≤", "≠"}
local SCHEDULE_MAX_LENGTH = 1000
local WAIT_CONDITION_MAX_LENGTH = 1000

function on_init()
  global.disabled = {}
  global.new_data = {}
  global.ghosts = {}
  global.current_ghost = 1
  global.train_id_cache = {}
  global.last_train_id = 0
  for _, player in pairs (game.players) do
    init_gui(player)
  end
end

function on_player_created(event)
  local player = game.players[event.player_index]
  init_gui(player)
end

function init_gui(player)
  local flow = mod_gui.get_button_flow(player)
  if not flow["blueprint-train-button"] then
    local button = flow.add{
      type = "sprite-button",
      name = "blueprint-train-button",
      style = mod_gui.button_style,
    }
    update_button(button, global.disabled[player.index])
    button.style.visible = true
  end
end

function on_gui_click(event)
  if event.element.name == "blueprint-train-button" then
    global.disabled[event.player_index] = not global.disabled[event.player_index]
    update_button(event.element, global.disabled[event.player_index])
  end
end

function update_button(button, disabled)
  if disabled then
    button.sprite = "blueprint-train-button-off"
    button.tooltip = {"gui.blueprint-train-button-off"}
  else
    button.sprite = "blueprint-train-button-on"
    button.tooltip = {"gui.blueprint-train-button-on"}
  end
end

function on_player_setup_blueprint(event)
  if global.disabled[event.player_index] then return end

  -- Discard old data
  global.new_data[event.player_index] = nil

  local area = event.area
  if not area
  or (area.right_bottom.x - area.left_top.x) * (area.right_bottom.y - area.left_top.y) < 1 then
    -- No area selected
    return
  end
  local player = game.players[event.player_index]
  local entities = player.surface.find_entities_filtered {
    area = area,
    force = player.force,
  }

  local found_train = false
  for _,entity in pairs(entities) do
    if entity.type == "locomotive"
    or entity.type == "cargo-wagon"
    or entity.type == "fluid-wagon"
    or entity.type == "artillery-wagon" then
      found_train = true
      break
    end
  end
  if not found_train then return end

  local data = serialize_data(entities)
  if player.cursor_stack.valid_for_read
  and player.cursor_stack.name == "blueprint" then
    add_to_blueprint(data, player.cursor_stack)
  else
    -- They are editing a new blueprint and we can't access it
    -- Save the entities and add them later
    global.new_data[event.player_index] = data
  end
end

function on_player_configured_blueprint(event)
  -- Finally, we can access the blueprint!
  local player = game.players[event.player_index]
  if not global.disabled[event.player_index]
  and player.cursor_stack.valid_for_read
  and player.cursor_stack.name == "blueprint"
  and global.new_data[event.player_index] then
    add_to_blueprint(global.new_data[event.player_index], player.cursor_stack)
  end
  -- Discard old data
  global.new_data[event.player_index] = nil
end

function on_gui_opened(event)
  -- Discard old data when a different blueprint is opened
  if event.gui_type == defines.gui_type.item
  and event.item
  and event.item.valid_for_read
  and event.item.name == "blueprint" then
    global.new_data[event.player_index] = nil
  end
end

function add_to_blueprint(data, blueprint)
  if not data then return end
  if #data < 1 then return end
  if not blueprint then return end
  if not blueprint.is_blueprint_setup() then return end
  local blueprint_entities = blueprint.get_blueprint_entities()
  if #blueprint_entities < 1 then return end

  local offset = calculate_offset(blueprint_entities, data)
  if not offset then return end

  for _, entity in pairs(data) do
    if entity.type == "locomotive"
    or entity.type == "cargo-wagon"
    or entity.type == "fluid-wagon"
    or entity.type == "artillery-wagon" then
      local name = "blueprint-train-combinator-" .. entity.name
      if game.entity_prototypes[name] then
        local data = {
          entity_number = #blueprint_entities + 1,
          name = name,
          position = {entity.position.x - offset.x, entity.position.y - offset.y},
          direction = entity.direction,
          control_behavior = {filters = entity.signals, is_on = entity.auto},
        }
        table.insert(blueprint_entities, data)
      end
    end
    blueprint.set_blueprint_entities(blueprint_entities)
  end
end

function on_marked_for_deconstruction(event)
  -- Instant deconstruction for ghosts
  if event.entity
  and event.entity.valid
  and event.entity.name
  and event.entity.name:sub(1, 22) == "blueprint-train-ghost-" then
    event.entity.destroy()
  end
end

function on_put_item(event)
  -- Shift-click to create ghosts
  if not event.shift_build then return end
  local player = game.players[event.player_index]
  if not player.cursor_stack.valid_for_read then return end
  local entity = game.entity_prototypes[player.cursor_stack.name]
  if not entity then return end
  if entity.type == "locomotive"
  or entity.type == "cargo-wagon"
  or entity.type == "fluid-wagon"
  or entity.type == "artillery-wagon" then
    entity = player.surface.create_entity{
      name = "blueprint-train-combinator-" .. entity.name,
      position = event.position,
      direction = event.direction,
      force = player.force,
    }
    if not entity then return end
    -- Write orientation
    local behavior = entity.get_or_create_control_behavior()
    behavior.set_signal(1, {
      signal = {name="signal-1", type="virtual"},
      count = pack_signal(event.direction * 32, 0, 0, 0),
    })
    behavior.enabled = false
    on_built_entity{created_entity = entity}
  end
end

function on_built_entity(event)
  local combinator = event.created_entity
  if combinator
  and combinator.valid
  and combinator.type
  and (
    combinator.type == "entity-ghost" and combinator.ghost_name:sub(1, 27) == "blueprint-train-combinator-"
    or combinator.type == "constant-combinator" and combinator.name:sub(1, 27) == "blueprint-train-combinator-"
  ) then
    build_ghost(combinator, event.stack)
  end
end

function build_ghost(combinator, blueprint)
  local entity_name = combinator.name:sub(28)
  if combinator.type == "entity-ghost" then
    entity_name = combinator.ghost_name:sub(28)
  end

  local behavior = combinator.get_or_create_control_behavior()
  local ghost = {
    name = entity_name,
    direction = combinator.direction,
    auto = behavior.enabled
  }
  unserialize_signals(ghost, behavior.parameters.parameters, blueprint)

  -- Pick from 3 different simple-entity so the selection box has the correct shape
  local orientation = ghost.orientation
  local name = "blueprint-train-ghost-dg-" .. entity_name
  if orientation < 1/16
  or orientation >= 7/16 and orientation < 9/16
  or orientation > 15/16 then
    name = "blueprint-train-ghost-ns-" .. entity_name
  end
  if orientation >= 3/16 and orientation < 5/16
  or orientation >= 11/16 and orientation < 13/16 then
    name = "blueprint-train-ghost-ew-" .. entity_name
  end

  -- Check for train collisions
  local combinator_data = {
    name = "blueprint-train-combinator-"..entity_name,
    position = combinator.position,
    direction = combinator.direction,
    force = combinator.force,
    build_check_type = defines.build_check_type.manual,
  }
  -- Check for ghost collisions
  local data = {
    name = name,
    position = combinator.position,
    force = combinator.force,
    build_check_type = defines.build_check_type.ghost_place,
  }
  local surface = combinator.surface
  combinator.destroy()

  local combinator_allowed = surface.can_place_entity(combinator_data)
  if not combinator_allowed then
    -- Maybe a player or vehicle is blocking it?
    -- We only need to avoid train collisions
    local box = game.entity_prototypes[name].collision_box
    local area = {
      {data.position.x + box.left_top.x - 1, data.position.y + box.left_top.y + 1},
      {data.position.x + box.right_bottom.x - 1, data.position.y + box.right_bottom.y + 1},
    }
    if 0 == surface.count_entities_filtered{
      type = {"locomotive", "cargo-wagon", "fluid-wagon", "artillery-wagon"},
      area = area,
    } then
      combinator_allowed = true
    end
  end
  local ghost_allowed = surface.can_place_entity(data)
  if combinator_allowed and ghost_allowed then
    ghost.entity = surface.create_entity(data)
  end
  if ghost.entity then
    ghost.entity.destructible = false

    -- Pick the correct graphics_variation
    if orientation < 5/16 or orientation >= 15/16 then
      ghost.entity.graphics_variation = 1
    elseif orientation >= 5/16 and orientation < 9/16
    or orientation >= 11/16 and orientation < 13/16 then
      ghost.entity.graphics_variation = 2
    elseif orientation >= 9/16 and orientation < 11/16 then
      ghost.entity.graphics_variation = 3
    elseif orientation >= 13/16 and orientation < 15/16 then
      ghost.entity.graphics_variation = 4
    end

    table.insert(global.ghosts, ghost)
    update_ghost(#global.ghosts)
  end
end

function on_tick()
  -- Only update 1 ghost per tick, to keep update times low
  if #global.ghosts < 1 then return end
  if global.current_ghost > #global.ghosts then global.current_ghost = 1 end
  local increment = update_ghost(global.current_ghost)
  global.current_ghost = global.current_ghost + increment

  -- Reset train id cache
  global.train_id_cache = {}
end

-- Update the 3 entities used in the fake ghost:
-- simple-entity, container, and item-request-proxy.
-- Returns the number to add to increment the current ghost.
function update_ghost(ghost_index)
  local ghost = global.ghosts[ghost_index]
  if not ghost or not ghost.entity or not ghost.entity.valid then
    return destroy_ghost(ghost_index)
  end

  if not ghost.revived then
    local area = {
      {ghost.entity.position.x - 5, ghost.entity.position.y - 5},
      {ghost.entity.position.x + 5, ghost.entity.position.y + 5},
    }
    local ghost_rails = ghost.entity.surface.count_entities_filtered{
      ghost_type = {"straight-rail", "curved_rail"},
      area = area,
      force = ghost.entity.force,
    }
    if ghost_rails > 0 then
      -- Wait for rails to be built
      return 1
    end

    local rails = ghost.entity.surface.count_entities_filtered{
      type = {"straight-rail", "curved_rail"},
      area = area,
      force = ghost.entity.force,
    }
    if rails < 1 then
      -- The rails have been destroyed, destroy the ghost too
      return destroy_ghost(ghost_index)
    end

    local item_name = ghost.entity.name:sub(26)
    if not ghost.created_proxy then
      -- We have some rails, now request a train item
      ghost.chest = ghost.entity.surface.create_entity{
        name = "blueprint-train-chest",
        position = ghost.entity.position,
        force = ghost.entity.force,
      }
      if ghost.chest then ghost.chest.destructible = false end
      ghost.request = ghost.entity.surface.create_entity{
        name = "blueprint-train-item-request",
        position = ghost.entity.position,
        force = ghost.entity.force,
        target = ghost.chest,
        modules = {[item_name] = 1},
      }
      ghost.created_proxy = true
      return 1
    end

    if not ghost.chest or not ghost.chest.valid then
      -- The chest has been destroyed, destroy the ghost too
      return destroy_ghost(ghost_index)
    end

    if ghost.chest.get_item_count(item_name) > 0
    and ghost.chest.remove_item{name = item_name, count = 1} > 0 then
      -- We have the train item
      local success = revive_ghost(ghost)
      if not ghost.revived then
        -- Refund the item
        ghost.chest.insert{name = item_name, count = 1}
      end
      if not success then
        return destroy_ghost(ghost_index)
      end
    end
  end

  if ghost.requested_items then
    if ghost.fuel and not game.item_prototypes[ghost.fuel] then
      -- A fuel mod was removed
      ghost.fuel = nil
      if ghost.request and ghost.request.valid then
        ghost.request.destroy()
        ghost.request = nil
      end
    end
    if ghost.fuel then
      local inventory = ghost.entity.get_inventory(defines.inventory.fuel)
      if inventory.get_item_count(ghost.fuel) >= game.item_prototypes[ghost.fuel].stack_size then
        -- Fuel is full
        if ghost.request and ghost.request.valid then
          ghost.request.destroy()
          ghost.request = nil
        end
      end
    end
    if not ghost.request or not ghost.request.valid then
      -- Everything is finished
      set_auto_mode(ghost)
      ghost.entity = nil
      return destroy_ghost(ghost_index, true)
    end

  elseif ghost.revived then
    -- Don't request items until every ghost in the train has been revived
    local train_complete = true
    for i = 1, #global.ghosts do
      if global.ghosts[i].train_id == ghost.train_id
      and not global.ghosts[i].revived then
        train_complete = false
        break
      end
    end
    if train_complete then
      request_items(ghost)
      if ghost.schedule then
        -- Set schedule again, in case we lost it while merging with other trains
        set_schedule(ghost.entity.train, ghost.schedule)
      end
    end
  end

  return 1
end

-- Returns false if the ghost is unbuildable (due to missing rails).
-- Returns true if a player is blocking the ghost, even though it wasn't revived.
-- Check ghost.revived to see if it was really revived.
function revive_ghost(ghost)
  -- Destroy the request, so it can't collide with the revived train
  if ghost.request and ghost.request.valid then
    ghost.request.destroy()
  end

  local data = {
    name = ghost.entity.name:sub(26),
    position = ghost.entity.position,
    direction = ghost.direction,
    force = ghost.entity.force,
    build_check_type = defines.build_check_type.script,
  }
  if not ghost.entity.surface.can_place_entity(data) then
    -- No rails to build on
    return false
  end
  local entity = ghost.entity.surface.create_entity(data)
  if not entity then
    -- Something is blocking it
    return true
  end

  local direction = get_direction(entity.orientation)
  if direction ~= ghost.direction then
    -- Try building in the opposite direction
    entity.destroy()
    data.direction = (data.direction + 4) % 8
    entity = ghost.entity.surface.create_entity(data)
    if not entity then
      -- Something is blocking it
      return true
    end
  end

  if entity.type == "cargo-wagon" then
    local inventory = entity.get_inventory(defines.inventory.cargo_wagon)
    if ghost.wagon_filters then
      for i = 1, #inventory do
        if ghost.wagon_filters[i] and game.item_prototypes[ghost.wagon_filters[i]] then
          inventory.set_filter(i, ghost.wagon_filters[i])
        end
      end
    end
    if ghost.bar and ghost.bar >= 1 and inventory.hasbar() then
      inventory.setbar(ghost.bar)
    end
  end

  if entity.type == "locomotive" then
    if ghost.schedule then
      set_schedule(entity.train, ghost.schedule)
    end

    if ghost.color then
      entity.color = ghost.color
    end
  end

  if ghost.entity and ghost.entity.valid then
    ghost.entity.destroy()
  end
  ghost.entity = entity
  ghost.revived = true
  script.raise_event(defines.events.script_raised_built, {created_entity = entity})
  return true
end

-- Returns the number to add to increment the current ghost.
function destroy_ghost(ghost_index, keep_auto_mode)
  local ghost = global.ghosts[ghost_index]
  if not ghost then return 1 end

  if ghost.entity and ghost.entity.valid then
    ghost.entity.destroy()
  end
  if ghost.request and ghost.request.valid then
    ghost.request.destroy()
  end
  if ghost.chest and ghost.chest.valid then
    local inventory = ghost.chest.get_inventory(defines.inventory.chest)
    for i = 1, #inventory do
      local stack = inventory[i]
      if stack.valid then
        ghost.chest.surface.spill_item_stack(ghost.chest.position, stack, nil, ghost.chest.force)
      end
    end
    ghost.chest.destroy()
  end

  if not keep_auto_mode then
    -- Removing a carriage cancels auto mode
    for i = 1, #global.ghosts do
      if global.ghosts[i].train_id == ghost.train_id then
        global.ghosts[i].auto = false
      end
    end
  end

  table.remove(global.ghosts, ghost_index)
  -- We shrank the ghost table instead of incrementing the current ghost
  return 0
end

function request_items(ghost)
  if ghost.fuel and not game.item_prototypes[ghost.fuel] then
    ghost.fuel = nil
  end
  if ghost.fuel then
    ghost.request = ghost.entity.surface.create_entity{
      name ="item-request-proxy",
      position = ghost.entity.position,
      force = ghost.entity.force,
      target = ghost.entity,
      modules = {[ghost.fuel] = game.item_prototypes[ghost.fuel].stack_size}
    }
  end
  ghost.requested_items = true
end

function set_auto_mode(ghost)
  if not ghost.entity.train.schedule then return end
  for i = 1, #global.ghosts do
    if global.ghosts[i].train_id == ghost.train_id
    and global.ghosts[i].entity ~= ghost.entity then
      -- There is another unfinished ghost in this train
      return
    end
  end
  ghost.entity.train.manual_mode = not ghost.auto
end

function calculate_offset(table1, table2)
  -- Pick a random entity from table 1
  local entity = table1[1]

  -- Calculate its offset to every entity in table 2
  for _, data in pairs(table2) do
    if entity.name == data.name
    and (entity.direction or 0) == (data.direction or 0) then
      local offset = {
        x = data.position.x - entity.position.x,
        y = data.position.y - entity.position.y,
      }

      -- Check if the offset works for every entity in table 1
      local count = 0
      for _, a in pairs(table1) do
        for _, b in pairs(table2) do
          if a.name == b.name
          and (a.direction or 0) == (b.direction or 0)
          and a.position.x + offset.x == b.position.x
          and a.position.y + offset.y == b.position.y then
            count = count + 1
            break
          end
        end
      end
      if count == #table1 then
        return offset
      end
    end
  end
end

function serialize_data(entities)
  -- Recalculate train ids
  local train_ids = {}
  for _, entity in pairs(entities) do
    if entity.type == "locomotive"
    or entity.type == "cargo-wagon"
    or entity.type == "fluid-wagon"
    or entity.type == "artillery-wagon" then
      if not train_ids[entity.train.id] then
        train_ids[entity.train.id] = 1
      end
    end
  end
  local id = 1
  for k,_ in pairs(train_ids) do
    train_ids[k] = id
    id = id + 1
  end

  local result = {}
  for _, entity in pairs(entities) do
    local data = {}
    data.type = entity.type
    data.name = entity.name
    if (data.type == "entity-ghost") then
      data.name = entity.ghost_name
    end
    data.position = entity.position
    data.direction = entity.direction

    if entity.type == "locomotive"
    or entity.type == "cargo-wagon"
    or entity.type == "fluid-wagon"
    or entity.type == "artillery-wagon" then
      local orientation = math.floor(entity.orientation * 256 + 0.5) % 256
      data.direction = get_direction(orientation/256)
      data.auto = not entity.train.manual_mode
      data.signals = serialize_signals(entity)
      -- Write orientation and train id
      local b2, b3, b4 = unpack_bytes(train_ids[entity.train.id], 3)
      data.signals[1].count = pack_signal(orientation, b2, b3, b4)
    end

    table.insert(result, data)
  end
  return result
end

function serialize_signals(entity)
  local signals = { {index=1, count=0, signal={name="signal-1", type="virtual"}} }

  if entity.type == "cargo-wagon" then
    local inventory = entity.get_inventory(defines.inventory.cargo_wagon)
    local signal2 = {index=2, count=0, signal={name="signal-1", type="virtual"}}
    table.insert(signals, signal2)
    -- Write bar
    if inventory.hasbar() then
      signal2.count = inventory.getbar()
    end
    -- Write wagon filters
    if inventory.is_filtered() then
      for i = 1, #inventory do
        local filter = inventory.get_filter(i)
        if filter then
          if i <= 2 then
            signals[i].signal.name = filter
            signals[i].signal.type = "item"
          else
            table.insert(signals, {index=i, count=0, signal={name=filter, type="item"}})
          end
        end
      end
    end
  elseif entity.type == "locomotive" then
    -- Write fuel
    local inventory = entity.get_inventory(defines.inventory.fuel)
    local fuel = nil
    for i = 1, #inventory do
      if inventory[i].valid and inventory[i].valid_for_read then
        fuel = inventory[i].name
        if entity.burner
        and entity.burner.currently_burning
        and entity.burner.currently_burning.name == fuel then
          -- Found the fuel we are burning!
          break
        end
        -- If the burner is empty, pick the last fuel
      end
    end
    if fuel then
      signals[1].signal.name = fuel
      signals[1].signal.type = "item"
    end

    -- Write color
    signals[2] = {index=2, count=0, signal={name="signal-1", type="virtual"}}
    if entity.color then
      signals[2].count = pack_signal(
        math.floor(entity.color.r * 255 + 0.5),
        math.floor(entity.color.g * 255 + 0.5),
        math.floor(entity.color.b * 255 + 0.5),
        math.floor(entity.color.a * 255 + 0.5)
      )
    end

    -- Write schedule
    signals[3] = {index=3, count=0, signal={name="signal-1", type="virtual"}}
    local schedule = entity.train.schedule
    if (schedule and schedule.records) then
      -- Write schedule length and current station
      local b1, b2 = unpack_bytes(#schedule.records, 2)
      local b3, b4 = unpack_bytes(schedule.current, 2)
      signals[3].count = pack_signal(b1, b2, b3, b4)

      local i = 4
      for _, record in pairs(schedule.records) do
        local name = record.station
        if name and name:len() > 0 then
          -- Write wait condition size, station name length, and first byte of station name
          local wait_conditions = record.wait_conditions or {}
          b1, b2 = unpack_bytes(#wait_conditions, 2)
          local length = math.min(name:len(), 255)
          local n = pack_signal(b1, b2, length, name:byte(1, 1))
          table.insert(signals, {index=i, count=n, signal={name="signal-1", type="virtual"}})
          i = i + 1

          -- Write remaining bytes of station name
          for s = 2, length, 4 do
            b1, b2, b3, b4 = 0, 0, 0, 0
            if s <= length then b1 = name:byte(s) end
            if s+1 <= length then b2 = name:byte(s+1) end
            if s+2 <= length then b3 = name:byte(s+2) end
            if s+3 <= length then b4 = name:byte(s+3) end
            local n = pack_signal(b1, b2, b3, b4)
            table.insert(signals, {index=i, count=n, signal={name="signal-1", type="virtual"}})
            i = i + 1
          end

          -- Write wait conditions
          for _, wait_condition in pairs(wait_conditions) do
            local and_or = 0
            if wait_condition.compare_type == "and" then and_or = 1 end
            local type_id = nil
            for k, type in pairs(WAIT_CONDITIONS) do
              if wait_condition.type == type then
                type_id = k
                break
              end
            end
            if type_id then
              -- Use the combinator as a placeholder for empty signal
              local signal = {name = "blueprint-train-combinator-" .. entity.name, type = "item"}
              local ticks = 0
              if wait_condition.ticks then
                ticks = math.min(wait_condition.ticks, 134217727)
              end
              -- Write and/or (1 bit), type (4 bits), and ticks (27 bits)
              local b1, b2, b3, b4 = unpack_bytes(ticks, 4)
              b1 = b1 + and_or * 128 + type_id * 8

              if wait_condition.condition then
                -- Ticks are not needed, we can use the bytes for something else
                -- Byte 2: comparator
                b2 = 1
                for k, comparator in pairs(COMPARATORS) do
                  if wait_condition.condition.comparator == comparator then
                    b2 = k
                    break
                  end
                end
                -- Byte 3: wildcard signal, everything=1, anything=2
                b3 = 0
                if signal.type == "virtual" then
                  if signal.name == "signal-everything" then b3 = 1 end
                  if signal.name == "signal-anything" then b3 = 2 end
                end
                if b3 == 0 then
                  -- Write the first signal
                  signal.name = wait_condition.condition.first_signal.name
                  signal.type = wait_condition.condition.first_signal.type
                end
              end
              local n = pack_signal(b1, b2, b3, b4)
              table.insert(signals, {index=i, count=n, signal=signal})
              i = i + 1

              if wait_condition.type == "item_count"
              or wait_condition.type == "circuit"
              or wait_condition.type == "fluid_count" then
                -- Write the second signal
                signal = {name = "blueprint-train-combinator-" .. entity.name, type="item"}
                local constant = 0
                if wait_condition.condition then
                  if wait_condition.condition.second_signal then
                    signal = wait_condition.condition.second_signal
                  else
                    constant = wait_condition.condition.constant
                  end
                end
                table.insert(signals, {index=i, count=constant, signal=signal})
                i = i + 1
              end
            end
          end
        end
      end
    end
  end

  return signals
end

function unserialize_signals(ghost, signals, blueprint)
  local EMPTY_SIGNAL = {count = 0, signal = {name="signal-1", type="virtual"}}
  local i = 1
  -- Read orientation and train id
  local signal = signals[i] or EMPTY_SIGNAL
  i = i + 1
  local b1, b2, b3, b4 = unpack_signal(signal.count)
  ghost.orientation = b1 / 256
  ghost.train_id = get_train_id(pack_bytes(b2, b3, b4), blueprint)
  local direction_shift = ghost.direction - get_direction(ghost.orientation)
  ghost.orientation = ghost.orientation + direction_shift/8
  if ghost.orientation >= 1 then ghost.orientation = ghost.orientation - 1 end
  if ghost.orientation < 0 then ghost.orientation = ghost.orientation + 1 end

  local type = game.entity_prototypes[ghost.name].type
  if type == "cargo-wagon" then
    ghost.wagon_filters = {}
    for _, s in pairs(signals) do
      -- Read wagon filters
      if s.signal.type == "item" then
        ghost.wagon_filters[s.index] = s.signal.name
      end
      -- Read bar
      if s.index == 2 then
        ghost.bar = s.count
      end
    end
  elseif type == "locomotive" then
    -- Read fuel
    if signal.signal.type == "item" then
      ghost.fuel = signal.signal.name
    end

    -- Read color
    signal = signals[i] or EMPTY_SIGNAL
    i = i + 1
    if signal.count ~= 0 and signal.count ~= 1 then
      b1, b2, b3, b4 = unpack_signal(signal.count)
      ghost.color = {
        r = b1 / 255,
        g = b2 / 255,
        b = b3 / 255,
        a = b4 / 255,
      }
    end

    -- Read schedule length and current station
    signal = signals[i] or EMPTY_SIGNAL
    i = i + 1
    b1, b2, b3, b4 = unpack_signal(signal.count)
    local schedule_length = pack_bytes(b1, b2)
    local current = pack_bytes(b3, b4)
    schedule_length = math.min(schedule_length, SCHEDULE_MAX_LENGTH)
    current = math.min(current, SCHEDULE_MAX_LENGTH)

    if schedule_length > 0 then
      ghost.schedule = { current = current, records = {} }
      for station = 1, schedule_length do
        -- Read wait condition size, station name length, and first byte of station name
        signal = signals[i] or EMPTY_SIGNAL
        i = i + 1
        b1, b2, b3, b4 = unpack_signal(signal.count)
        local condition_length = pack_bytes(b1, b2)
        condition_length = math.min(condition_length, WAIT_CONDITION_MAX_LENGTH)
        local name_length = b3
        local name = string.char(b4)

        -- Read remaining bytes of station name
        for s = 2, name_length, 4 do
          signal = signals[i] or EMPTY_SIGNAL
          i = i + 1
          b1, b2, b3, b4 = unpack_signal(signal.count)
          if name:len() < name_length then name = name .. string.char(b1) end
          if name:len() < name_length then name = name .. string.char(b2) end
          if name:len() < name_length then name = name .. string.char(b3) end
          if name:len() < name_length then name = name .. string.char(b4) end
        end

        local record = { station = name, wait_conditions = {} }
        for c = 1, condition_length do
          -- Read the first signal
          signal = signals[i] or EMPTY_SIGNAL
          i = i + 1
          -- Read and/or (1 bit), type (4 bits), and ticks (27 bits)
          b1, b2, b3, b4 = unpack_signal(signal.count)
          local compare_type = "or"
          if b1 >= 128 then compare_type = "and" end
          local type_id = math.floor((b1 % 128) / 8)
          if type_id < 1 or type_id > #WAIT_CONDITIONS then
            type_id = 1
          end
          local type = WAIT_CONDITIONS[type_id]
          local ticks = pack_bytes(b1 % 8, b2, b3, b4)
          local wait_condition = { type = type, compare_type = compare_type }
          if type == "time" or type == "inactivity" then
            wait_condition.ticks = ticks
          end
          if type == "item_count" or type == "circuit" or type == "fluid_count" then
            -- Ticks are not needed, we can use the bytes for something else
            local condition = { first_signal = signal.signal }
            if signal.signal.name == "blueprint-train-combinator-" .. ghost.name then
              -- Empty signal
              condition.first_signal = {type="virtual"}
            end
            -- Byte 2: comparator
            condition.comparator = COMPARATORS[b2] or COMPARATORS[1]
            -- Byte 3: wildcard signal, everything=1, anything=2
            if b3 == 1 then
              condition.first_signal = {name="signal-everything", type="virtual"}
            end
            if b3 == 2 then
              condition.first_signal = {name="signal-anything", type="virtual"}
            end

            -- Read the second signal
            signal = signals[i] or EMPTY_SIGNAL
            i = i + 1
            condition.second_signal = signal.signal
            if condition.second_signal.name == "blueprint-train-combinator-" .. ghost.name then
              -- It's a constant
              condition.constant = signal.count
              condition.second_signal = nil
            end
            wait_condition.condition = condition
          end
          table.insert(record.wait_conditions, wait_condition)
        end
        table.insert(ghost.schedule.records, record)
      end
    end
  end
end

function get_direction(orientation)
  return math.floor(orientation * 4 + 0.5) * 2 % 8
end

function get_train_id(id, blueprint)
  -- Allow duplicate train ids if they are built
  -- from the same blueprint in the same tick.
  local key = nil
  if blueprint and blueprint.valid and blueprint.item_number then
    key = blueprint.item_number .. "-" .. id
    if global.train_id_cache[key] then
      return global.train_id_cache[key]
    end
  end
  -- Generate a new id
  global.last_train_id = global.last_train_id + 1
  if key then global.train_id_cache[key] = global.last_train_id end
  return global.last_train_id
end

function set_schedule(train, schedule)
  local s = util.table.deepcopy(schedule)
  -- The schedule may contain mod items that no longer exist
  -- Remove them to prevent script errors
  if s and s.records then
    for _, record in pairs(schedule.records) do
      if record.wait_conditions then
        for _, w in pairs(record.wait_conditions) do
          if w.condition then
            if not signal_exists(w.condition.first_signal) then
              w.condition.first_signal = nil
            end
            if not signal_exists(w.condition.second_signal) then
              w.condition.second_signal = nil
            end
          end
        end
      end
    end
  end
  train.schedule = s
end

function signal_exists(signal)
  if not signal then return false end
  if not signal.name then return false end
  if not signal.type then return false end
  if signal.type == "item" then return game.item_prototypes[signal.name] end
  if signal.type == "fluid" then return game.fluid_prototypes[signal.name] end
  if signal.type == "virtual" then return game.virtual_signal_prototypes[signal.name] end
  return false
end

function pack_signal(b1, b2, b3, b4)
  local n = pack_bytes(b1, b2, b3, b4)
  if n > 2147483647 then n = n - 4294967296 end
  return n
end

function unpack_signal(n)
  n = n % 4294967296
  return unpack_bytes(n, 4)
end

function pack_bytes(...)
  local arg = table.pack(...)
  local n = 0
  for i = 1, #arg do
    n = n * 256 + arg[i] % 256
  end
  return n
end

function unpack_bytes(n, count)
  local result = {}
  for i = 1, count do
    table.insert(result, 1, n % 256)
    n = math.floor(n / 256)
  end
  return unpack(result)
end

function on_configuration_changed(data)
  local changes = data.mod_changes["blueprint-train"]
  if not changes then return end
  local old_version = changes.old_version

  -- Version 0.16.9 adds new train_id format
  if old_version and tonumber(old_version:sub(6)) < 9 then
    global.train_id_cache = {}
    global.last_train_id = 0
    for i = 1, #global.ghosts do
      global.ghosts[i].train_id = -1 * (global.ghosts[i].length or 0)
    end
  end
end

script.on_init(on_init)
script.on_configuration_changed(on_configuration_changed)
script.on_event(defines.events.on_player_created, on_player_created)
script.on_event(defines.events.on_gui_opened, on_gui_opened)
script.on_event(defines.events.on_gui_click, on_gui_click)
script.on_event(defines.events.on_put_item, on_put_item)
script.on_event(defines.events.on_built_entity, on_built_entity)
script.on_event(defines.events.on_robot_built_entity, on_built_entity)
script.on_event(defines.events.script_raised_built, on_built_entity)
script.on_event(defines.events.on_marked_for_deconstruction, on_marked_for_deconstruction)
script.on_event(defines.events.on_player_setup_blueprint, on_player_setup_blueprint)
script.on_event(defines.events.on_player_configured_blueprint, on_player_configured_blueprint)
script.on_event(defines.events.on_tick, on_tick)
