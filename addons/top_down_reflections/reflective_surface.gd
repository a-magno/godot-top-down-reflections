@tool
class_name ReflectionMaskGenerator
extends "reflection_generator.gd"
## Water reflections. Add this node as a child of the TileMapLayer that holds
## the water tiles.
##
## Every ReflectableComponent in the "reflectable" group is drawn upside down
## around its own position. The water shader shows it only on tiles tagged
## with water_key, and only on pixels whose screen color passes the hue,
## saturation and value checks.
##
## The grid texture stores, per tile: R = 0 for water, G = distortion
## strength, A = opacity (see _cell_color).
##
## Safe to remove if you do not need it:
## - Cloud shadows: the "Cloud Shadows" exports, _shadows, _setup_shadows,
##   _update_shadows and its call, the _rebuild override, CLOUD_PARAMS,
##   SHADOW_SHADER and cloud_shadows.gdshader. Also remove the shadow part at
##   the end of water_surface.gdshader.
## - Fading of tall reflections: fade_tall_reflections, fade_gradient and the
##   polygon code at the end of _update_reflections. Keep the
##   canvas_item_add_texture_rect_region call.
## - opacity_key and distortion_key, if all water tiles use the same values.
##   Then return Color(0, 1, 0, 1) for water tiles in _cell_color.
## - debug_mask.
##
## Do not remove:
## - _push_params. Values set in the inspector reach the shader there,
##   because the setters run before the material exists.
## - The "0 means not set" rule in _tile_float, unless every water tile sets
##   reflection_opacity. Godot reads unset float custom data as 0.

## The custom data key defined in your TileSet to identify reflective tiles.
@export var water_key: StringName = &"is_reflective":
	set(v):
		water_key = v
		_update_mask()

## Optional custom data key for per-tile reflection opacity (float 0-1).
## Multiplies the global reflection_opacity. 0 means "not set" (Godot's default
## for unset floats) and counts as 1.0; untag is_reflective to hide a tile.
@export var opacity_key: StringName = &"reflection_opacity":
	set(v):
		opacity_key = v
		_update_mask()

## Optional custom data key for per-tile distortion strength (float 0-1).
## 0 = no distortion (also the default for tiles that don't set it, e.g. ice),
## 1 = every row ripples. Rows always move by whole pixels; lower values make
## fewer rows move, not smaller moves.
@export var distortion_key: StringName = &"reflection_distortion":
	set(v):
		distortion_key = v
		_update_mask()

@export_group("Alignment")
@export var reflection_y_offset: float = 0.0

@export_group("Visuals")
@export_range(0.0, 1.0) var reflection_opacity: float = 0.7:
	set(v):
		reflection_opacity = v
		_set_shader_params([&"reflection_opacity"])

@export var fade_tall_reflections: bool = true
@export var fade_gradient: Gradient

@export_group("Color Keying")
## The target hue (0-1). Blue water is typically around 0.55-0.6.
@export_range(0.0, 1.0) var hue_center: float = 0.58:
	set(v):
		hue_center = v
		_set_shader_params([&"hue_center"])

## How far from the center hue still counts as water.
@export_range(0.0, 0.5) var hue_tolerance: float = 0.08:
	set(v):
		hue_tolerance = v
		_set_shader_params([&"hue_tolerance"])

## Min/max saturation. Filters out desaturated colors (dirt, grey stones).
@export var saturation_range: Vector2 = Vector2(0.25, 1.0):
	set(v):
		saturation_range = v
		_set_shader_params([&"saturation_range"])

## Min/max brightness. Filters out very dark or very bright pixels.
@export var value_range: Vector2 = Vector2(0.2, 1.0):
	set(v):
		value_range = v
		_set_shader_params([&"value_range"])

## Edge softness at band boundaries. 0 = perfectly hard cutoff.
@export_range(0.0, 0.1) var band_softness: float = 0.02:
	set(v):
		band_softness = v
		_set_shader_params([&"band_softness"])

@export_group("Cloud Shadows")
## Darken the whole map under the same clouds the water reflects. Cloud shape,
## size and speed come from the cloud_* settings on the water material.
@export var cloud_shadows: bool = true
@export var shadow_color: Color = Color(0.05, 0.05, 0.15, 0.25)
## Shadows land this many pixels away from where the clouds are reflected.
## Water pixels never get shadows (they show the reflected cloud instead).
@export var shadow_offset: Vector2i = Vector2i(24, 40)
## Absolute z_index of the shadow overlay: above characters and buildings.
@export var shadow_z_index: int = 10

@export_group("Debugging")
@export var debug_mask: bool = false:
	set(v):
		debug_mask = v
		_set_shader_params([&"debug_mask"])

const MASK_SHADER: Shader = preload("water_surface.gdshader")
const SHADOW_SHADER: Shader = preload("cloud_shadows.gdshader")
const CLOUD_PARAMS: Array[StringName] = [&"clouds_enabled", &"cloud_scale", &"cloud_coverage",
	&"cloud_softness", &"cloud_speed"]

# Internal, unowned child: never saved into the scene, material included.
var _shadows: Node2D

func _ready() -> void:
	super()
	_setup_shadows()

func _setup_shadows() -> void:
	for child in get_children(true):  # reuse after a script reload in the editor
		if child.name == &"CloudShadows":
			_shadows = child
			return
	_shadows = Node2D.new()
	_shadows.name = "CloudShadows"
	_shadows.z_as_relative = false
	var mat := ShaderMaterial.new()
	mat.shader = SHADOW_SHADER
	_shadows.material = mat
	# One quad over the map; the node sits at the map's top-left.
	_shadows.draw.connect(func(): _shadows.draw_rect(Rect2(Vector2.ZERO, _map_size), Color.WHITE))
	add_child(_shadows, false, Node.INTERNAL_MODE_BACK)

func _rebuild() -> void:
	super()
	if is_instance_valid(_shadows):
		_shadows.queue_redraw()

func _update_shadows() -> void:
	if not is_instance_valid(_shadows):
		return
	_shadows.visible = cloud_shadows
	# The water shader shades the non-water pixels of water tiles itself.
	_mask_material.set_shader_parameter(&"shadow_color", shadow_color if cloud_shadows else Color(0, 0, 0, 0))
	_mask_material.set_shader_parameter(&"shadow_offset", Vector2(shadow_offset))
	if not cloud_shadows:
		return
	_shadows.position = _px_origin
	_shadows.z_index = shadow_z_index
	var mat: ShaderMaterial = _shadows.material
	# Same clouds as the water: copy its settings so tweaks there apply here.
	for p in CLOUD_PARAMS:
		mat.set_shader_parameter(p, _mask_material.get_shader_parameter(p))
	mat.set_shader_parameter(&"shadow_color", shadow_color)
	mat.set_shader_parameter(&"shadow_offset", Vector2(shadow_offset))
	mat.set_shader_parameter(&"grid_data", _grid_texture)
	mat.set_shader_parameter(&"map_size", _map_size)

func _default_shader() -> Shader:
	return MASK_SHADER

func _buffer_name() -> String:
	return "HiddenReflectionBuffer"

func _buffer_internal() -> bool:
	return true

func _push_params() -> void:
	_set_shader_params([&"reflection_opacity", &"debug_mask", &"hue_center", &"hue_tolerance",
		&"saturation_range", &"value_range", &"band_softness"])

# R = 0 marks water, G = per-tile distortion, A = per-tile opacity.
func _cell_color(tile_data: TileData) -> Color:
	if not tile_data.get_custom_data(water_key):
		return Color.WHITE
	var distortion := 1.0
	if distortion_key != &"" and tile_data.has_custom_data(distortion_key):
		distortion = clampf(float(tile_data.get_custom_data(distortion_key)), 0.0, 1.0)
	return Color(0.0, distortion, 0.0, _tile_float(tile_data, opacity_key))

# Unset float custom data reads as 0.0 (never null), so 0 means "use 1.0".
func _tile_float(tile_data: TileData, key: StringName) -> float:
	if key == &"" or not tile_data.has_custom_data(key):
		return 1.0
	var v := float(tile_data.get_custom_data(key))
	return clampf(v, 0.0, 1.0) if v > 0.0 else 1.0

func _update_reflections() -> void:
	_update_shadows()
	var keep := {}
	for node in get_tree().get_nodes_in_group("reflectable"):
		if node is ReflectableComponent:
			keep[node] = true
	_prune_items(keep)

	var to_tilemap := target_tilemap.global_transform.affine_inverse() if target_tilemap else Transform2D.IDENTITY

	for comp: ReflectableComponent in keep:
		var sprite = comp.target_sprite
		if not is_instance_valid(sprite) or not sprite.is_visible_in_tree():
			_hide_item(comp)
			continue
		var d := comp.get_draw_data(false)
		if d.is_empty():
			_hide_item(comp)
			continue
		var rid := _get_item(comp)

		# Flip the sprite upside down around the component (its "feet").
		var local_to_pivot: Transform2D = comp.global_transform.affine_inverse() * sprite.global_transform
		var flip_x := -1.0 if sprite.get("flip_h") else 1.0
		var flip_y := -1.0 if sprite.get("flip_v") else 1.0
		var xf: Transform2D = to_tilemap * comp.global_transform * local_to_pivot.scaled(Vector2(flip_x, -flip_y))
		xf.origin -= _view_origin
		xf.origin.y += reflection_y_offset
		RenderingServer.canvas_item_set_transform(rid, xf)
		# Clarity darkens toward a silhouette.
		var c := comp.clarity
		RenderingServer.canvas_item_set_modulate(rid, Color(c, c, c, 1.0))

		var tex: Texture2D = d.tex
		var src: Rect2 = d.src
		var rect: Rect2 = d.rect
		if not fade_tall_reflections:
			RenderingServer.canvas_item_add_texture_rect_region(rid, rect, tex.get_rid(), src)
			continue

		var points := PackedVector2Array([rect.position, rect.position + Vector2(rect.size.x, 0),
			rect.end, rect.position + Vector2(0, rect.size.y)])
		var t_size := tex.get_size()
		var uv := Rect2(src.position / t_size, src.size / t_size)
		var uvs := PackedVector2Array([uv.position, uv.position + Vector2(uv.size.x, 0),
			uv.end, uv.position + Vector2(0, uv.size.y)])
		# Before the flip, points 0 and 1 are the head: fade it out.
		var head_col := fade_gradient.sample(0.0) if fade_gradient else Color(1, 1, 1, 0.0)
		var feet_col := fade_gradient.sample(1.0) if fade_gradient else Color(1, 1, 1, 1.0)
		var colors := PackedColorArray([head_col, head_col, feet_col, feet_col])
		RenderingServer.canvas_item_add_polygon(rid, points, colors, uvs, tex.get_rid())
