local TRAIN_WHEEL_VERTICAL_SHIFT = -0.25 -- Magic wheel shift constant
local GHOST_TINT = {r=0.6, g=0.6, b=0.6, a=0.3}

function add_prototypes(entity)
  local combinator = table.deepcopy(data.raw["constant-combinator"]["constant-combinator"]);
  combinator.name = "blueprint-train-combinator-" .. entity.name
  combinator.localised_name = {"entity-name." .. entity.name}
  combinator.flags = {"player-creation", "placeable-off-grid", "not-on-map", "hide-alt-info"}
  combinator.icon = entity.icon
  combinator.icon_size = entity.icon_size
  combinator.max_health = entity.max_health
  combinator.minable = { mining_time = 0, results={} }
  local width = entity.selection_box[2][1] - entity.selection_box[1][1]
  local height = entity.selection_box[2][2] - entity.selection_box[1][2]
  -- Make sure the selection box is wider than the rails
  width = math.max(width, 3)
  combinator.selection_box = {{-width/2, -height/2}, {width/2, height/2}}
  combinator.vertical_selection_shift = entity.vertical_selection_shift
  combinator.drawing_box = entity.drawing_box
  combinator.collision_box = entity.collision_box
  combinator.collision_mask = {"train-layer"}
  if entity.type == "locomotive" then
    -- Reserve 1000 slots to store complex train schedules
    combinator.item_slot_count = 1000
  elseif entity.type == "cargo-wagon" then
    -- One slot for every inventory filter
    combinator.item_slot_count = entity.inventory_size
  else
    combinator.item_slot_count = 1
  end
  combinator.activity_led_sprites = {}
  combinator.activity_led_light_offsets = {}
  combinator.circuit_wire_connection_points = {}
  for _, direction in pairs{"north", "east", "south", "west"} do
    local layers = get_train_layers(entity, defines.direction[direction])
    combinator.sprites[direction] = {layers=layers}
    combinator.activity_led_sprites[direction] = {
      filename = "__core__/graphics/empty.png",
      frame_count = 1,
      width = 1,
      height = 1,
    }
    table.insert(combinator.activity_led_light_offsets, {0,0})
    table.insert(combinator.circuit_wire_connection_points, {
      wire = {green={0,0}, red={0,0}},
      shadow = {green={0,0}, red={0,0}},
    })
  end
  data:extend{combinator}

  local item = {
    type = "item",
    name = combinator.name,
    localised_name = combinator.localised_name,
    place_result = combinator.name,
    subgroup = "transport",
    order = "a[train-system]-z",
    flags = {"hidden"},
    stack_size = 1,
  }
  -- Try to find a matching item icon
  for _,i in pairs(data.raw.item) do
    if i.place_result == entity.name then
      item.icon = i.icon
      item.icon_size = i.icon_size
      break
    end
  end
  if not item.icon then
    item.icon = combinator.icon
    item.icon_size = combinator.icon_size
  end
  if not item.icon then
    item.icon = "__core__/graphics/empty.png"
    item.icon_size = 1
  end
  data:extend{item}

  local ghost_vertical = {
    type = "simple-entity-with-force",
    name = "blueprint-train-ghost-ns-" .. entity.name,
    localised_name = {"entity-name." .. entity.name},
    flags = {"player-creation", "placeable-off-grid", "not-on-map", "hide-alt-info", "not-flammable", "not-repairable", "not-blueprintable"},
    icon = entity.icon,
    icon_size = entity.icon_size,
    max_health = entity.max_health,
    minable = { mining_time = 0, results = {} },
    mined_sound = { volume = 0, filename = "__core__/sound/deconstruct-medium.ogg" },
    selection_box = combinator.selection_box,
    collision_box = combinator.collision_box,
    collision_mask = {"ghost-layer"},
    pictures = {},
  }
  for _, direction in pairs{"north", "south"} do
    local layers = get_train_layers(entity, defines.direction[direction])
    for _, layer in pairs(layers) do
      layer.tint = GHOST_TINT
      if layer.hr_version then layer.hr_version.tint = GHOST_TINT end
    end
    table.insert(ghost_vertical.pictures, {layers=layers})
  end
  data:extend{ghost_vertical}

  local ghost_horizontal = table.deepcopy(ghost_vertical)
  ghost_horizontal.name = "blueprint-train-ghost-ew-" .. entity.name
  width = math.max(width, height) / math.sqrt(2)
  ghost_horizontal.selection_box = {{-height/2, -width/2}, {height/2, width/2}}
  width = entity.collision_box[2][1] - entity.collision_box[1][1]
  height = entity.collision_box[2][2] - entity.collision_box[1][2]
  width = math.max(width, height) / math.sqrt(2)
  ghost_horizontal.collision_box = {
    {entity.collision_box[1][2], entity.collision_box[1][1]},
    {entity.collision_box[2][2], entity.collision_box[2][1]},
  }
  ghost_horizontal.pictures = {}
  for _, direction in pairs{"east", "west"} do
    local layers = get_train_layers(entity, defines.direction[direction])
    for _, layer in pairs(layers) do
      layer.tint = GHOST_TINT
      if layer.hr_version then layer.hr_version.tint = GHOST_TINT end
    end
    table.insert(ghost_horizontal.pictures, {layers=layers})
  end
  data:extend{ghost_horizontal}

  local ghost_diagonal = table.deepcopy(ghost_vertical)
  ghost_diagonal.name = "blueprint-train-ghost-dg-" .. entity.name
  width = math.max(width, height) / math.sqrt(2)
  ghost_diagonal.selection_box = {{-width/2, -width/2}, {width/2, width/2}}
  width = entity.collision_box[2][1] - entity.collision_box[1][1]
  height = entity.collision_box[2][2] - entity.collision_box[1][2]
  width = math.max(width, height) / math.sqrt(2)
  ghost_diagonal.collision_box = {{-width/2, -width/2}, {width/2, width/2}}
  ghost_diagonal.pictures = {}
  for _, direction in pairs{"northeast", "southeast", "southwest", "northwest"} do
    local layers = get_train_layers(entity, defines.direction[direction])
    for _, layer in pairs(layers) do
      layer.tint = GHOST_TINT
      if layer.hr_version then layer.hr_version.tint = GHOST_TINT end
    end
    table.insert(ghost_diagonal.pictures, {layers=layers})
  end
  data:extend{ghost_diagonal}
end

function get_train_layers(entity, direction)
  local layers = {}
  copy_wheels(entity, layers, 1, direction)
  copy_wheels(entity, layers, -1, direction)
  copy_layers(entity, layers, "pictures", direction)
  if entity.type == "artillery-wagon" then
    copy_layers(entity, layers, "cannon_barrel_pictures", direction)
    copy_layers(entity, layers, "cannon_base_pictures", direction)
  end
  return layers
end

function copy_layers(entity, layers, pictures, direction)
    if not entity[pictures] then return end
    for _, source in pairs(entity[pictures].layers) do
      local layer = table.deepcopy(source)
      fix_graphics(entity, layer, pictures, direction)
      if layer.hr_version then
        fix_graphics(entity, layer.hr_version, pictures, direction)
      end
      table.insert(layers, layer)
  end
end

function copy_wheels(entity, layers, wheel_direction, direction)
  if not entity.wheels then return end
  local j = entity.joint_distance/2 * wheel_direction
  local s45 = {x=0.64, y=0.67} -- Shift factor for 45 degree angle
  local wheel_shifts = {
    [0] = {0, j},
    [1] = {-j * s45.x, j * s45.y},
    [2] = {-j, 0},
    [3] = {-j * s45.x, -j * s45.y},
    [4] = {0, -j},
    [5] = {j * s45.x, -j * s45.y},
    [6] = {j, 0},
    [7] = {j * s45.x, j * s45.y},
  }
  local shift = wheel_shifts[direction]
  shift[2] = shift[2] + TRAIN_WHEEL_VERTICAL_SHIFT
  if wheel_direction == -1 then direction = (direction + 4) % 8 end
  local layer = table.deepcopy(entity.wheels)
  layer.shift = shift
  fix_graphics(entity, layer, pictures, direction)
  if layer.hr_version then
    layer.hr_version.shift = shift
    fix_graphics(entity, layer.hr_version, pictures, direction)
  end
  table.insert(layers, layer)
end

function fix_graphics(entity, layer, pictures, direction)
  local count = layer.direction_count
  if layer.back_equals_front then
    count = count * 2
  end
  local orientation = (math.floor(count * orientation_bias(direction / 8) + 0.5) % layer.direction_count)
  local file = math.floor(orientation / (layer.line_length * layer.lines_per_file))
  layer.filename = layer.filenames[file + 1]
  local slot = orientation - file * layer.line_length * layer.lines_per_file
  layer.x = layer.width * (slot % layer.line_length)
  layer.y = layer.height * math.floor(slot / layer.line_length)
  if layer.apply_runtime_tint then
    layer.tint = entity.color
  end
  if pictures == "cannon_barrel_pictures" or pictures == "cannon_base_pictures" then
    local cannon_shift = entity.cannon_base_shiftings[orientation + 1]
    if not layer.shift then layer.shift = {0,0} end
    layer.shift = {layer.shift[1] + cannon_shift[1], layer.shift[2] + cannon_shift[2]}
  end
end

function orientation_bias(n)
  -- There are more horizontal train sprites than vertical
  -- so we need to bias our sprite picking function to match.
  -- The graphic artists probably used a different function,
  -- but this is accurate for the 8 directions I care about.
  n = (n - math.floor(n)) * 4
  local whole = math.floor(n)
  local fraction = n - whole
  if whole % 2 == 0 then
    fraction = math.pow(fraction, 1.35)
  else
    fraction = 1 - math.pow(1 - fraction, 1.35)
  end
  return (whole + fraction) / 4
end


for _, entity in pairs(data.raw["locomotive"]) do
  add_prototypes(entity)
end
for _, entity in pairs(data.raw["cargo-wagon"]) do
  add_prototypes(entity)
end
for _, entity in pairs(data.raw["fluid-wagon"]) do
  add_prototypes(entity)
end
for _, entity in pairs(data.raw["artillery-wagon"]) do
  add_prototypes(entity)
end
