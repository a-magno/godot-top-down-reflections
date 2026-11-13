@tool
extends Node2D
## Shared base for the water and mirror generators. It is not used on its own.
##
## What it does:
## - Copies the node's ShaderMaterial (one copy per instance) and sets the
##   shader the subclass returns from _default_shader.
## - Builds a grid texture with one pixel per tile from the tilemap's custom
##   data. Each subclass decides the pixel color in _cell_color.
## - Owns a hidden SubViewport. Reflections are drawn into it as
##   RenderingServer canvas items, one per ReflectableComponent. The viewport
##   only covers the camera view plus VIEW_MARGIN pixels.
## - Draws one white rect over the whole tilemap. The shader turns that rect
##   into the reflection, using the grid, the screen colors and the viewport.
##
## To change behavior, override the functions in the "Virtuals" region in a
## subclass instead of editing this file.
##
## Safe to remove if you do not need it:
## - debug_texture_rect and _bind_debug_rect. They only preview the buffer.
##
## Do not remove:
## - The NOTIFICATION_EDITOR_PRE_SAVE and POST_SAVE code. Without it, the
##   grid, the viewport texture and the view data are saved into your scenes.
## - The NOTIFICATION_PREDELETE code. It frees RenderingServer resources.
## - _update_view and view_data. Both shaders read the view rect and the map
##   size from it and show nothing without it.
## - The is_node_ready checks. They stop work from running during scene load
##   and repeating when the node re-enters the tree.

## Optionally assign the TileMapLayer manually. If left empty, checks parent.
@export var target_tilemap: TileMapLayer:
	set(v):
		# Stop listening to the old tilemap, or its edits keep rebuilding us.
		if is_instance_valid(target_tilemap) and target_tilemap.changed.is_connected(_rebuild):
			target_tilemap.changed.disconnect(_rebuild)
		target_tilemap = v
		_find_tilemap()

## Assign a TextureRect here to preview the raw reflection viewport output.
@export var debug_texture_rect: TextureRect:
	set(v):
		debug_texture_rect = v
		_bind_debug_rect()

var _mask_material: ShaderMaterial
var _grid_texture: ImageTexture
var _refl_viewport: SubViewport
var _refl_canvas: RID
var _refl_items: Dictionary = {}  # ReflectableComponent -> canvas item RID
var _tile_size: Vector2 = Vector2(16, 16)
var _px_origin: Vector2 = Vector2.ZERO  # tilemap-local top-left of used_rect
var _map_size: Vector2 = Vector2.ONE  # used_rect size in pixels
# The reflection buffer only covers what the camera sees (plus a margin for
# the water distortion), not the whole map: a big map would otherwise need a
# huge texture redrawn every frame. Tilemap-local top-left of that view:
var _view_origin: Vector2 = Vector2.ZERO
# Shader input "view_data": texel 0 = view rect, texel 1 = map size (a texture
# because plain uniforms can't be kept out of saved scenes).
var _view_image := Image.create_empty(2, 1, false, Image.FORMAT_RGBAF)
var _view_texture: ImageTexture

const VIEW_MARGIN := 8.0

#region Virtuals
func _default_shader() -> Shader:
	return null

## Name of the hidden viewport. Saved ViewportTexture paths in scenes use it.
func _buffer_name() -> String:
	return "ReflectionBuffer"

## Internal children are hidden from the Scene dock.
func _buffer_internal() -> bool:
	return false

## Grid pixel for a tile. WHITE = not tagged; R < 0.5 = tagged.
func _cell_color(_tile_data: TileData) -> Color:
	return Color.WHITE

## Push every exported shader setting (setters run before the material exists).
func _push_params() -> void:
	pass

## Called every frame once the viewport canvas exists.
func _update_reflections() -> void:
	pass
#endregion

#region Lifecycle
func _enter_tree() -> void:
	# Keep the scene's material (settings that only live there survive).
	# Duplicate so instances of the same scene don't share grid/viewport textures.
	# On re-entry, keep the material we already set up.
	if is_node_ready():
		return
	_mask_material = material.duplicate() if material is ShaderMaterial else ShaderMaterial.new()
	if not _mask_material.shader:
		_mask_material.shader = _default_shader()
	material = _mask_material

func _ready() -> void:
	_setup_viewport()
	_assign_texture()
	_find_tilemap()  # connects and runs the first _rebuild
	_push_params()
	queue_redraw()

func _process(_delta: float) -> void:
	if target_tilemap:
		global_transform = target_tilemap.global_transform
	if _refl_canvas.is_valid():
		_update_view()
		_update_reflections()

# Computed values are rebuilt at runtime: keep them out of saved scenes.
func _notification(what: int) -> void:
	if what == NOTIFICATION_EDITOR_PRE_SAVE:
		if _mask_material:
			for p in [&"grid_data", &"reflection_texture", &"view_data"]:
				_mask_material.set_shader_parameter(p, null)
		if debug_texture_rect and is_instance_valid(_refl_viewport) \
				and debug_texture_rect.texture == _refl_viewport.get_texture():
			debug_texture_rect.texture = null
	elif what == NOTIFICATION_EDITOR_POST_SAVE:
		_update_mask()
	elif what == NOTIFICATION_PREDELETE:
		# Free RenderingServer RIDs only when the node is deleted, not on
		# exit_tree: _ready doesn't run again when a node re-enters the tree
		# (editor tab switch, reparenting), so nothing would rebuild them.
		# The viewport is a child and is freed with us.
		for rid in _refl_items.values():
			if rid.is_valid():
				RenderingServer.free_rid(rid)
		_refl_items.clear()
		if _refl_canvas.is_valid():
			RenderingServer.free_rid(_refl_canvas)
			_refl_canvas = RID()
#endregion

#region Viewport
func _setup_viewport() -> void:
	if is_instance_valid(_refl_viewport):
		return

	# Reuse an existing buffer (e.g. after a script reload in the editor).
	for child in get_children(true):
		if child is SubViewport and child.name == StringName(_buffer_name()):
			_refl_viewport = child
			if not _refl_canvas.is_valid():
				_refl_canvas = RenderingServer.canvas_create()
				RenderingServer.viewport_attach_canvas(_refl_viewport.get_viewport_rid(), _refl_canvas)
			return

	_refl_viewport = SubViewport.new()
	_refl_viewport.name = _buffer_name()
	_refl_viewport.transparent_bg = true
	_refl_viewport.disable_3d = true
	_refl_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_refl_viewport.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	_refl_viewport.msaa_2d = Viewport.MSAA_DISABLED
	add_child(_refl_viewport, false, Node.INTERNAL_MODE_BACK if _buffer_internal() else Node.INTERNAL_MODE_DISABLED)

	_refl_canvas = RenderingServer.canvas_create()
	RenderingServer.viewport_attach_canvas(_refl_viewport.get_viewport_rid(), _refl_canvas)

func _assign_texture() -> void:
	if _mask_material and is_instance_valid(_refl_viewport):
		_mask_material.set_shader_parameter("reflection_texture", _refl_viewport.get_texture())
		_bind_debug_rect()

func _bind_debug_rect() -> void:
	if debug_texture_rect and is_instance_valid(_refl_viewport):
		debug_texture_rect.texture = _refl_viewport.get_texture()
#endregion

#region Tilemap + grid mask
func _find_tilemap() -> void:
	if not target_tilemap:
		var parent := get_parent()
		if parent is TileMapLayer:
			target_tilemap = parent as TileMapLayer

	if target_tilemap:
		if not target_tilemap.changed.is_connected(_rebuild):
			target_tilemap.changed.connect(_rebuild)
		# Setters run during scene load; _ready does the first rebuild.
		if is_node_ready():
			_rebuild()

func _rebuild() -> void:
	_update_mask()

func _update_mask() -> void:
	if not _mask_material or not is_instance_valid(_refl_viewport):
		return
	if not target_tilemap or not target_tilemap.tile_set:
		return

	var used_rect: Rect2i = target_tilemap.get_used_rect()
	if not used_rect.has_area():
		return

	_tile_size = Vector2(target_tilemap.tile_set.tile_size)
	_px_origin = Vector2(used_rect.position) * _tile_size

	var img := Image.create_empty(used_rect.size.x, used_rect.size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	for x in range(used_rect.size.x):
		for y in range(used_rect.size.y):
			var td := target_tilemap.get_cell_tile_data(used_rect.position + Vector2i(x, y))
			if td:
				img.set_pixel(x, y, _cell_color(td))

	_grid_texture = ImageTexture.create_from_image(img)
	_mask_material.set_shader_parameter("grid_data", _grid_texture)

	_map_size = Vector2(used_rect.size) * _tile_size
	_update_view()
	_assign_texture()
	queue_redraw()

## Fit the reflection buffer to the visible part of the map.
func _update_view() -> void:
	if not _mask_material or not is_instance_valid(_refl_viewport):
		return
	# This node follows the tilemap's transform, so its local space is the tilemap's.
	var visible := global_transform.affine_inverse() * _get_visible_rect()
	var view := _view_rect(visible, Rect2(_px_origin, _map_size), VIEW_MARGIN)
	_view_origin = Vector2(view.position)
	# Resizing reallocates the texture: only on zoom or window changes.
	if _refl_viewport.size != view.size:
		_refl_viewport.size = view.size
	var rel := _view_origin - _px_origin
	_view_image.set_pixel(0, 0, Color(rel.x, rel.y, view.size.x, view.size.y))
	_view_image.set_pixel(1, 0, Color(_map_size.x, _map_size.y, 0.0, 0.0))
	if _view_texture:
		_view_texture.update(_view_image)
	else:
		_view_texture = ImageTexture.create_from_image(_view_image)
	_mask_material.set_shader_parameter("view_data", _view_texture)

## `visible` grown by `margin`, snapped outward to whole pixels and clamped to
## `map`. Whole pixels keep nearest sampling aligned with the map's pixels.
## Falls back to the whole map when nothing is visible.
static func _view_rect(visible: Rect2, map: Rect2, margin: float) -> Rect2i:
	var map_i := Rect2i(map.position.floor(), map.size.ceil()).abs()
	if not visible.has_area():
		return map_i
	var grown := visible.grow(margin)
	var pos := grown.position.floor()
	var view := Rect2i(Vector2i(pos), Vector2i(grown.end.ceil() - pos)).intersection(map_i)
	return view if view.has_area() else map_i

## The world-space rect the camera currently shows.
func _get_visible_rect() -> Rect2:
	var vp := get_viewport()
	if not vp:
		return Rect2()
	var inv := vp.get_canvas_transform().affine_inverse()
	var tl: Vector2 = inv * Vector2.ZERO
	var br: Vector2 = inv * Vector2(get_viewport_rect().size)
	return Rect2(tl, br - tl)

func _draw() -> void:
	if not target_tilemap or not _grid_texture:
		return
	draw_rect(Rect2(_px_origin, _map_size), Color.WHITE)
#endregion

#region Canvas items
## The component's canvas item, created if needed and cleared for redrawing.
func _get_item(comp: ReflectableComponent) -> RID:
	var rid: RID = _refl_items.get(comp, RID())
	if not rid.is_valid():
		rid = RenderingServer.canvas_item_create()
		RenderingServer.canvas_item_set_parent(rid, _refl_canvas)
		_refl_items[comp] = rid
	RenderingServer.canvas_item_clear(rid)
	return rid

## Clear without freeing (sprite hidden or has no texture this frame).
func _hide_item(comp: ReflectableComponent) -> void:
	if _refl_items.has(comp):
		RenderingServer.canvas_item_clear(_refl_items[comp])

## Free items whose component is gone or not in `keep`.
func _prune_items(keep: Dictionary) -> void:
	for comp in _refl_items.keys():
		if not is_instance_valid(comp) or not keep.has(comp):
			RenderingServer.free_rid(_refl_items[comp])
			_refl_items.erase(comp)

## Copy exported properties of the same name into the shader.
func _set_shader_params(names: Array[StringName]) -> void:
	if _mask_material:
		for n in names:
			_mask_material.set_shader_parameter(n, get(n))
#endregion
