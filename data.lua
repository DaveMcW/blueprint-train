local request = table.deepcopy(data.raw["item-request-proxy"]["item-request-proxy"])
request.name = "blueprint-train-item-request"
request.localised_name = {"entity-name.item-request-proxy"}
request.use_target_entity_alert_icon_shift = false
request.selection_box = nil
request.collision_box = nil
request.collision_mask = {}
request.picture = {
  filename = "__core__/graphics/empty.png",
  width = 1,
  height = 1,
}
data:extend{request}

local chest = table.deepcopy(data.raw.container["steel-chest"])
chest.name = "blueprint-train-chest"
chest.localised_name = {"entity-name.logistic-chest-requester"}
chest.flags = {"placeable-off-grid", "not-on-map", "hide-alt-info", "not-flammable", "not-repairable", "not-blueprintable", "not-deconstructable"}
chest.order = "a[train-system]-z"
chest.minable = { mining_time = 0, results={} }
chest.selection_box = nil
chest.collision_box = nil
chest.collision_mask = {}
chest.picture = {
  filename = "__core__/graphics/empty.png",
  width = 1,
  height = 1,
}
data:extend{chest}

data:extend{
  {
    type = "sprite",
    name = "blueprint-train-button-on",
    filename = "__blueprint-train__/button_on.png",
    priority = "extra-high-no-scale",
    width = 64,
    height = 64,
  },
  {
    type = "sprite",
    name = "blueprint-train-button-off",
    filename = "__blueprint-train__/button_off.png",
    priority = "extra-high-no-scale",
    width = 64,
    height = 64,
  },
}
