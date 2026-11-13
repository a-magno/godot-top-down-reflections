@tool
class_name ReflectableComponent
extends Node2D
## Marks a sprite as reflectable. Add it as a child of a Sprite2D or an
## AnimatedSprite2D and move it to the sprite's feet: water reflections flip
## around this node's position.
##
## It adds itself to the "reflectable" group, which the water generator reads.
## Mirrors find it through the physics body that owns the sprite.
##
## Safe to remove if you do not need it:
## - The "Mirror" exports and get_mirrored_frame, if you have no mirrors. Also
##   remove the "mirrored" branches in get_draw_data.
## - clarity, if reflections never need to be darker.
##
## Do not remove:
## - get_draw_data and get_frame_rect. Both generators use them.
## - The "reflectable" group.

## The sprite to reflect. If left empty, it will try to use its parent.
@export var target_sprite: CanvasItem
## 1.0 is full color. 0.0 draws a pure black silhouette.
@export_range(0.0, 1.0) var clarity: float = 1.0

@export_group("Mirror")
## Frame range mirroring rules for Sprite2D (hframes/vframes sheets).
## Each Vector3i = (range_start, range_end, offset).
## If current frame is in [start, end] -> mirrored frame = frame + offset.
## Inverse is automatic: frames in [start+offset, end+offset] -> frame - offset.
## Example: a 4-column sheet where row 0 faces down, row 1 faces up:
##   Vector3i(0, 3, 4) swaps frames 0-3 <-> 4-7.
@export var mirror_frame_rules: Array[Vector3i] = []
## Animation name mapping for mirror reflections (AnimatedSprite2D).
## Maps current animation -> mirrored animation, e.g. {"walk_left": "walk_right"}.
@export var mirror_animation_map: Dictionary = {}

func _ready() -> void:
	add_to_group("reflectable")

	if not target_sprite:
		var parent = get_parent()
		if parent is CanvasItem:
			target_sprite = parent

## Given a flat frame index, returns the mirrored frame using the rules.
func get_mirrored_frame(frame: int) -> int:
	for rule: Vector3i in mirror_frame_rules:
		# Forward: frame is in the source range
		if frame >= rule.x and frame <= rule.y:
			return frame + rule.z
		# Inverse: frame is in the target range
		if frame >= rule.x + rule.z and frame <= rule.y + rule.z:
			return frame - rule.z
	# No rule matched : return as-is
	return frame

## What to draw for target_sprite this frame: {tex, src, rect}, where rect is
## the local draw rect (centered/offset applied). Empty when nothing to draw.
## mirrored: apply mirror_frame_rules / mirror_animation_map.
func get_draw_data(mirrored: bool) -> Dictionary:
	var sprite = target_sprite
	var tex: Texture2D
	var src: Rect2
	if sprite is Sprite2D:
		tex = sprite.texture
		if tex:
			src = get_frame_rect(sprite, get_mirrored_frame(sprite.frame) if mirrored else sprite.frame)
	elif sprite is AnimatedSprite2D and sprite.sprite_frames:
		var frames: SpriteFrames = sprite.sprite_frames
		var anim: StringName = sprite.animation
		# Missing mapped names fall back to the current animation.
		if mirrored and frames.has_animation(mirror_animation_map.get(anim, &"")):
			anim = mirror_animation_map[anim]
		# The mirrored animation may be shorter: wrap the frame index.
		var count := frames.get_frame_count(anim)
		if count > 0:
			tex = frames.get_frame_texture(anim, sprite.frame % count)
		if tex:
			src = Rect2(Vector2.ZERO, tex.get_size())
	if not tex:
		return {}
	var rect := Rect2(-src.size * 0.5 if sprite.centered else Vector2.ZERO, src.size)
	rect.position += sprite.offset
	return {"tex": tex, "src": src, "rect": rect}

## Source rect of `frame`, matching Sprite2D: hframes/vframes split the
## region when region_enabled, else the whole texture.
static func get_frame_rect(sprite: Sprite2D, frame: int) -> Rect2:
	var base := sprite.region_rect if sprite.region_enabled else Rect2(Vector2.ZERO, sprite.texture.get_size())
	var size := base.size / Vector2(sprite.hframes, sprite.vframes)
	@warning_ignore("integer_division")  # row index: whole frames per row
	var cell := Vector2(frame % sprite.hframes, frame / sprite.hframes)
	return Rect2(base.position + cell * size, size)
