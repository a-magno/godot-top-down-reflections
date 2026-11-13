@tool
class_name MirrorMaskGenerator
extends "reflection_generator.gd"
## Mirror reflections. Add this node as a child of the TileMapLayer that holds
## the glass tiles, and set its z_index to 1 or more (the editor warns
## otherwise).
##
## Each horizontal run of mirror tiles casts down for cast_range tiles: a
## RayCast2D for a single tile, a ShapeCast2D for a longer run. When a cast
## hits a body that has a ReflectableComponent in its own subtree, that
## sprite is drawn at the mirror with its mirrored frame or animation. The
## mirror shader shows it only on pixels whose screen color matches a band.
##
## Safe to remove if you do not need it:
## - debug_casts, the debug part of _draw, and debug_mask.
## - y_tracking. Keep the pinned position (refl_world.y = cast_origin.y).
## - The "direction" and "collider" keys in detections, unless your own code
##   reads them.
## - _cull_offscreen_casts, if your maps are small. The casts then always run.
##
## Do not remove:
## - The BackBufferCopy (_ensure_backbuffer_copy and _exit_tree). Without it,
##   the mirror compares against an old copy of the screen and finds no glass.
## - A z_index of 1 or more, for the same reason.
## - _draw_occluders and the occluder buffer. The mirror draws above
##   characters, so this keeps it from drawing over them.
## - The CollisionObject2D check in _find_reflectable. Without it, a hit on a
##   tilemap returns the component of any scene tile placed on that tilemap.
## - The band_data clearing in _notification. It keeps band data out of saved
##   scenes.

## The custom data key to identify mirror tiles.
@export var mirror_key: StringName = &"is_mirror":
	set(v):
		mirror_key = v
		_rebuild()

@export_group("Detection")
## How many tiles downward each cast extends from the mirror tile center.
@export_range(1, 16) var cast_range: int = 4:
	set(v):
		cast_range = v
		_rebuild_casts()

## Physics layers the casts detect. Set this to match your characters' collision layer.
@export_flags_2d_physics var cast_collision_mask: int = 1:
	set(v):
		cast_collision_mask = v
		for cast in _casts:
			cast.collision_mask = v

@export_group("Reflection")
## When enabled, the reflection slides vertically as the character moves
## away from the mirror. When disabled, the reflection stays fixed at the
## mirror surface and only fades with distance.
@export var y_tracking: bool = true

@export_group("Color Keying")
## Glass colors (pick with the color picker) -> tolerance (0-1): how far in
## hue, saturation and value a pixel may be from that color and still count.
## A tolerance of 0 disables that band.
@export var bands: Dictionary[Color, float] = {Color(0.6, 0.85, 0.9): 0.15}:
	set(v):
		bands = v
		_push_bands()

@export_range(0.0, 0.2) var band_softness: float = 0.04:
	set(v):
		band_softness = v
		if _mask_material:
			_mask_material.set_shader_parameter("band_softness", v)

@export_range(0.0, 1.0) var reflection_opacity: float = 1.0:
	set(v):
		reflection_opacity = v
		if _mask_material:
			_mask_material.set_shader_parameter("reflection_opacity", v)

@export_group("Debugging")
@export var debug_mask: bool = false:
	set(v):
		debug_mask = v
		if _mask_material:
			_mask_material.set_shader_parameter("debug_mask", v)
		queue_redraw()

@export var debug_casts: bool = false:
	set(v):
		debug_casts = v
		for cast in _casts:
			if is_instance_valid(cast):
				cast.visible = v
		queue_redraw()

## Public read-only data
## Each entry: { collider, point, distance, direction, has_reflectable,
##               component, cast }
var detections: Array[Dictionary] = []

var _casts: Array = []

# BackBufferCopy forces a fresh screen_texture snapshot right before we draw.
# Without it, a sibling that reads screen_texture earlier (e.g. WaterReflections)
# captures the backbuffer before our parent's tiles are in the framebuffer.
var _backbuffer_copy: BackBufferCopy

const MIRROR_SHADER: Shader = preload("mirror_surface.gdshader")

# Occluders: every reflectable sprite drawn at its real position into a second
# hidden buffer. The mirror shader skips pixels covered there, so it never
# draws over a character in front of the glass. One canvas item per component.
var _occluders: Dictionary = {}  # ReflectableComponent -> canvas item RID
var _occ_viewport: SubViewport
var _occ_canvas: RID

#region Generator hooks
func _default_shader() -> Shader:
	return MIRROR_SHADER

func _buffer_name() -> String:
	return "HiddenMirrorBuffer"

func _push_params() -> void:
	_set_shader_params([&"band_softness", &"reflection_opacity", &"debug_mask"])
	_push_bands()
	_assign_texture()

# band_data is derived from `bands`: keep it out of saved scenes too.
func _notification(what: int) -> void:
	super(what)
	if what == NOTIFICATION_EDITOR_PRE_SAVE and _mask_material:
		_mask_material.set_shader_parameter("band_data", null)
		_mask_material.set_shader_parameter("occluder_texture", null)
	elif what == NOTIFICATION_EDITOR_POST_SAVE:
		_push_bands()
		_assign_occluders()
	elif what == NOTIFICATION_PREDELETE:
		for rid in _occluders.values():
			RenderingServer.free_rid(rid)
		_occluders.clear()
		if _occ_canvas.is_valid():
			RenderingServer.free_rid(_occ_canvas)

## A band as the shader reads it: rgb = the color's hue, saturation, value
## (converted here once instead of for every pixel), a = tolerance.
static func band_texel(color: Color, tolerance: float) -> Color:
	return Color(color.h, color.s, color.v, tolerance)

# One texel per band.
func _push_bands() -> void:
	if not _mask_material:
		return
	if bands.is_empty():
		_mask_material.set_shader_parameter("band_data", null)
		return
	var img := Image.create_empty(bands.size(), 1, false, Image.FORMAT_RGBAF)
	var i := 0
	for color: Color in bands:
		img.set_pixel(i, 0, band_texel(color, bands[color]))
		i += 1
	_mask_material.set_shader_parameter("band_data", ImageTexture.create_from_image(img))

func _cell_color(tile_data: TileData) -> Color:
	return Color.BLACK if tile_data.get_custom_data(mirror_key) else Color.WHITE

func _rebuild() -> void:
	super()
	_rebuild_casts()
#endregion

#region Lifecycle
func _enter_tree() -> void:
	super()
	call_deferred("_ensure_backbuffer_copy")

# The mirror reads the screen and draws over the glass, so it must come after
# every building/character tile. In a y-sorted layer, z 0 would sort it by its
# own origin and draw it underneath tiles further down the map.
func _get_configuration_warnings() -> PackedStringArray:
	if z_index < 1:
		return ["Set z_index to 1 or more (above the glass tiles), or the mirror draws under the buildings."]
	return []

func _ensure_backbuffer_copy() -> void:
	# Add a BackBufferCopy as our preceding sibling so the backbuffer is
	# re-captured with our parent's tiles in it, even if another node
	# (like WaterReflections) already triggered a capture earlier.
	var parent := get_parent()
	if not parent:
		return

	# Check if we already created one
	for child in parent.get_children():
		# Skip one freed on a previous exit_tree that hasn't been deleted yet.
		if child is BackBufferCopy and child.name == &"_MirrorBackBuffer" and not child.is_queued_for_deletion():
			_backbuffer_copy = child
			return

	_backbuffer_copy = BackBufferCopy.new()
	_backbuffer_copy.name = "_MirrorBackBuffer"
	_backbuffer_copy.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	# Same z as us: the copy must happen after tiles with a raised z_index
	# (e.g. buildings at z 1), or we color-key against what's under them.
	_backbuffer_copy.z_index = z_index
	_backbuffer_copy.z_as_relative = z_as_relative
	parent.add_child(_backbuffer_copy)
	# Move it just before us so it draws right before our shader reads screen_texture
	parent.move_child(_backbuffer_copy, get_index())

# The BackBufferCopy lives under our parent, so it can't follow us; the
# casts are our children and stay (_enter_tree re-adds the copy).
func _exit_tree() -> void:
	if is_instance_valid(_backbuffer_copy):
		_backbuffer_copy.queue_free()
		_backbuffer_copy = null
#endregion

#region Detection
func _update_reflections() -> void:
	_cull_offscreen_casts()
	_collect_detections()
	_draw_reflections()

	if debug_casts:
		queue_redraw()  # _draw shows the casts and a stats summary

func _cull_offscreen_casts() -> void:
	if _casts.is_empty():
		return

	var visible_rect := _get_visible_rect()
	var margin: float = cast_range * _tile_size.y
	var expanded := visible_rect.grow(margin)

	# Test each cast's footprint, not its centre: a mirror wider than the
	# screen has its centre off-screen while its end is visible.
	for cast in _casts:
		var local := Rect2(-cast.shape.size * 0.5, cast.shape.size) if cast is ShapeCast2D else Rect2()
		cast.enabled = expanded.intersects(cast.global_transform * local, true)

func _collect_detections() -> void:
	detections.clear()

	for cast in _casts:
		if not cast.enabled:
			continue

		if cast is RayCast2D:
			if cast.is_colliding():
				_add_detection(cast, cast.get_collider(), cast.get_collision_point())

		elif cast is ShapeCast2D:
			for i in cast.get_collision_count():
				_add_detection(cast, cast.get_collider(i), cast.get_collision_point(i))

func _add_detection(cast: Node2D, collider: Object, point: Vector2) -> void:
	if not collider is Node:
		return

	var comp: ReflectableComponent = _find_reflectable(collider as Node)
	var origin: Vector2 = cast.global_position
	var distance: float = origin.distance_to(point)
	var direction: Vector2 = (point - origin).normalized() if distance > 0.01 else Vector2.DOWN

	detections.append({
		"collider": collider,
		"point": point,
		"distance": distance,
		"direction": direction,
		"has_reflectable": comp != null,
		"component": comp,
		"cast": cast,
	})
#endregion

#region Reflection drawing into viewport
func _draw_reflections() -> void:
	# Deduplicate: if the same component is seen by multiple casts,
	# keep only the closest detection.
	var best: Dictionary = {}  # ReflectableComponent -> detection dict
	for det in detections:
		if not det["has_reflectable"]:
			continue
		var comp: ReflectableComponent = det["component"]
		if not best.has(comp) or det["distance"] < best[comp]["distance"]:
			best[comp] = det

	_prune_items(best)

	var max_dist: float = cast_range * _tile_size.y
	var to_tilemap := target_tilemap.global_transform.affine_inverse() if target_tilemap else Transform2D.IDENTITY

	for comp: ReflectableComponent in best:
		var det: Dictionary = best[comp]
		var sprite: CanvasItem = comp.target_sprite
		if not is_instance_valid(sprite) or not sprite.is_visible_in_tree():
			_hide_item(comp)
			continue
		var d := comp.get_draw_data(true)
		if d.is_empty():
			_hide_item(comp)
			continue
		var rid := _get_item(comp)

		# Position (use sprite's live position for smooth updates)
		var sprite_world: Vector2 = sprite.global_position
		var cast_node: Node2D = det["cast"]
		var cast_origin: Vector2 = cast_node.global_position
		# With y_tracking: reflection slides up as character walks away.
		# Without: reflection stays pinned at the mirror surface, only fading.
		var refl_world := Vector2(sprite_world.x, cast_origin.y)
		if y_tracking:
			refl_world.y -= absf(sprite_world.y - cast_origin.y)

		# Viewport-local coords (relative to the tilemap used_rect origin)
		var xf := Transform2D.IDENTITY
		xf.origin = to_tilemap * refl_world - _view_origin
		RenderingServer.canvas_item_set_transform(rid, xf)

		# Fade by distance from the mirror's bottom edge to the body hit
		# (the sprite center sits well below the hit point, which faded
		# a character standing at the wall down to ~17%)
		var half_tile: float = _tile_size.y * 0.5
		var gap: float = absf(det["point"].y - cast_origin.y) - half_tile
		var fade: float = 1.0 - clampf(gap / (max_dist - half_tile), 0.0, 1.0)
		var c: float = comp.clarity
		RenderingServer.canvas_item_set_modulate(rid, Color(c, c, c, fade))

		var tex: Texture2D = d.tex
		RenderingServer.canvas_item_add_texture_rect_region(rid, d.rect, tex.get_rid(), d.src)

	_draw_occluders(to_tilemap)

## Draw every reflectable sprite, unflipped, at its real position into the
## occluder buffer. Without this, the mirror draws over characters standing
## in front of the glass whenever their colors match a glass band.
func _draw_occluders(to_tilemap: Transform2D) -> void:
	_setup_occluders()
	if _occ_viewport.size != _refl_viewport.size:
		_occ_viewport.size = _refl_viewport.size
	var keep := {}
	for node in get_tree().get_nodes_in_group("reflectable"):
		if not node is ReflectableComponent:
			continue
		var comp: ReflectableComponent = node
		var sprite = comp.target_sprite
		if not is_instance_valid(sprite) or not sprite.is_visible_in_tree():
			continue
		var d := comp.get_draw_data(false)
		if d.is_empty():
			continue
		keep[comp] = true
		var rid: RID = _occluders.get(comp, RID())
		if not rid.is_valid():
			rid = RenderingServer.canvas_item_create()
			RenderingServer.canvas_item_set_parent(rid, _occ_canvas)
			_occluders[comp] = rid
		RenderingServer.canvas_item_clear(rid)
		var flip := Vector2(-1.0 if sprite.get("flip_h") else 1.0, -1.0 if sprite.get("flip_v") else 1.0)
		var xf: Transform2D = to_tilemap * sprite.global_transform.scaled_local(flip)
		xf.origin -= _view_origin
		RenderingServer.canvas_item_set_transform(rid, xf)
		var tex: Texture2D = d.tex
		RenderingServer.canvas_item_add_texture_rect_region(rid, d.rect, tex.get_rid(), d.src)
	for comp in _occluders.keys():
		if not keep.has(comp):
			RenderingServer.free_rid(_occluders[comp])
			_occluders.erase(comp)

func _setup_occluders() -> void:
	if is_instance_valid(_occ_viewport):
		return
	_occ_viewport = SubViewport.new()
	_occ_viewport.name = "HiddenMirrorOccluders"
	_occ_viewport.transparent_bg = true
	_occ_viewport.disable_3d = true
	_occ_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_occ_viewport.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	add_child(_occ_viewport, false, Node.INTERNAL_MODE_BACK)
	_occ_canvas = RenderingServer.canvas_create()
	RenderingServer.viewport_attach_canvas(_occ_viewport.get_viewport_rid(), _occ_canvas)
	_assign_occluders()

func _assign_occluders() -> void:
	if _mask_material and is_instance_valid(_occ_viewport):
		_mask_material.set_shader_parameter("occluder_texture", _occ_viewport.get_texture())
#endregion

#region Cast building
func _rebuild_casts() -> void:
	# Setters (cast_range, mirror_key, ...) run during scene load;
	# build once in _ready instead of once per setter.
	if not is_node_ready():
		return
	_clear_casts()

	if not target_tilemap or not target_tilemap.tile_set:
		return

	_tile_size = Vector2(target_tilemap.tile_set.tile_size)
	var cast_length: float = cast_range * _tile_size.y
	var groups: Array = _group_mirror_tiles()

	for group: Array in groups:
		if group.size() == 1:
			_create_raycast(group[0], cast_length)
		else:
			_create_shapecast(group, cast_length)

func _create_raycast(cell: Vector2i, length: float) -> void:
	var ray := RayCast2D.new()
	ray.position = Vector2(cell) * _tile_size + _tile_size * 0.5
	ray.target_position = Vector2(0, length)
	ray.collision_mask = cast_collision_mask
	ray.collide_with_areas = false
	ray.collide_with_bodies = true
	ray.enabled = true
	ray.visible = debug_casts
	add_child(ray)
	_casts.append(ray)

func _create_shapecast(group: Array, length: float) -> void:
	var sum := Vector2.ZERO
	for cell: Vector2i in group:
		sum += Vector2(cell) * _tile_size + _tile_size * 0.5
	var center: Vector2 = sum / group.size()

	var shape_cast := ShapeCast2D.new()
	shape_cast.position = center
	shape_cast.target_position = Vector2(0, length)
	shape_cast.collision_mask = cast_collision_mask
	shape_cast.collide_with_areas = false
	shape_cast.collide_with_bodies = true
	shape_cast.max_results = 32
	shape_cast.enabled = true
	shape_cast.visible = debug_casts

	var rect := RectangleShape2D.new()
	rect.size = Vector2(group.size() * _tile_size.x, _tile_size.y)
	shape_cast.shape = rect

	add_child(shape_cast)
	_casts.append(shape_cast)

func _clear_casts() -> void:
	for cast in _casts:
		if is_instance_valid(cast):
			cast.queue_free()
	_casts.clear()
	detections.clear()

func _group_mirror_tiles() -> Array:
	var used_rect: Rect2i = target_tilemap.get_used_rect()
	if not used_rect.has_area():
		return []

	var cells: Array[Vector2i] = []
	for y in range(used_rect.size.y):
		for x in range(used_rect.size.x):
			var cell := used_rect.position + Vector2i(x, y)
			var td := target_tilemap.get_cell_tile_data(cell)
			if td and td.get_custom_data(mirror_key):
				cells.append(cell)

	if cells.is_empty():
		return []

	var groups: Array = []
	var current: Array[Vector2i] = [cells[0]]

	for i in range(1, cells.size()):
		var prev: Vector2i = current[-1]
		var curr: Vector2i = cells[i]
		if curr.y == prev.y and curr.x == prev.x + 1:
			current.append(curr)
		else:
			groups.append(current)
			current = [curr]
	groups.append(current)

	return groups
#endregion

#region Helpers
# Only the collider's own subtree: searching siblings matched unrelated
# objects (e.g. a wall tile hit returned the player's component).
func _find_reflectable(node: Node) -> ReflectableComponent:
	if node is ReflectableComponent:
		return node
	for child in node.get_children():
		# A child body owns its own component (e.g. scene tiles under a tilemap).
		if child is CollisionObject2D:
			continue
		var result := _find_reflectable(child)
		if result:
			return result
	return null
#endregion

#region Debug drawing
func _draw() -> void:
	super()
	if not debug_casts or not _grid_texture:
		return

	for cast in _casts:
		if not is_instance_valid(cast):
			continue
		var from: Vector2 = cast.position
		var to: Vector2 = from + cast.target_position
		var color: Color = Color.GREEN if cast.enabled else Color(0.3, 0.3, 0.3, 0.4)

		if cast is ShapeCast2D:
			var half_w: float = cast.shape.size.x * 0.5
			var half_h: float = cast.shape.size.y * 0.5
			draw_rect(Rect2(from - Vector2(half_w, half_h), cast.shape.size), color, false, 1.0)
			draw_rect(Rect2(to - Vector2(half_w, half_h), cast.shape.size), color, false, 1.0)
			draw_line(from - Vector2(half_w, 0), to - Vector2(half_w, 0), color, 1.0)
			draw_line(from + Vector2(half_w, 0), to + Vector2(half_w, 0), color, 1.0)
		else:
			draw_line(from, to, color, 1.0)

		for det in detections:
			if det["cast"] == cast:
				var local_pt: Vector2 = det["point"] - global_position
				var det_color := Color.MAGENTA if det["has_reflectable"] else Color.YELLOW
				draw_circle(local_pt, 2.0, det_color)

	# Summary text
	var enabled_count: int = 0
	for cast in _casts:
		if is_instance_valid(cast) and cast.enabled:
			enabled_count += 1
	var reflectable_count: int = 0
	for det in detections:
		if det["has_reflectable"]:
			reflectable_count += 1

	var summary := "Casts: %d (%d on)  |  Hits: %d  |  Reflectable: %d  |  VP: %s" % [
		_casts.size(), enabled_count,
		detections.size(), reflectable_count,
		str(_refl_viewport.size) if is_instance_valid(_refl_viewport) else "N/A"
	]
	draw_string(ThemeDB.fallback_font, _px_origin + Vector2(2, -4), summary, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color.CYAN)
#endregion
