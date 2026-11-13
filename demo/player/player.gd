extends CharacterBody2D

# The AnimationTree transitions read `state` through advance expressions.
enum State { IDLE, WALK, JUMP }

@export var speed: float = 64.0

@onready var anim_tree: AnimationTree = $CharacterSprite/AnimationTree

var state: State = State.IDLE

func _physics_process(_delta: float) -> void:
	var input := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	# 4-directional: keep only the stronger axis (horizontal wins ties).
	if absf(input.x) >= absf(input.y):
		input.y = 0.0
	else:
		input.x = 0.0
	input = input.sign()

	velocity = input * speed
	move_and_slide()

	if input == Vector2.ZERO:
		state = State.IDLE
		return
	state = State.WALK
	# Both blend spaces share the facing so idle keeps the last direction.
	anim_tree.set("parameters/Idle/blend_position", input)
	anim_tree.set("parameters/Moving/blend_position", input)
