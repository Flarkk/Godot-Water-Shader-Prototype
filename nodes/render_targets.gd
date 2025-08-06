@tool
extends Node

@export var forward_offset : float = 1.5
@export var forward_fadeoff : float = 0.001
@export var flow_strength : float = 1.0
@export var flow_randomize : float = 0.2
@export var flow_random_speed : float = 0.5
@export var blur_strength : float = 0.02
@export var blur_offset : float = 1.0
@export var curl_strength : float = 0.6
@export var curl_offset : float = 7.0
@export var shift_vector := Vector2(0.01, 0.05)
@export var shift_speed : float = 1.0
@export var flow_texture : Texture2D

var texture: Texture2DRD
var next_texture: int = 0
var texture_size = Vector2i(1024, 1024)
var time = 0.0


func _ready() -> void:
	RenderingServer.call_on_render_thread(_initialize_compute_code.bind(texture_size, flow_texture))

	# Get our texture from our material so we set our RID.
	var material: ShaderMaterial = $"../waterplane".material_override
	if material:
		texture = $"../waterplane".material_override.get_shader_parameter("vector_map")

func _exit_tree() -> void:
	# Make sure we clean up!
	if texture:
		texture.texture_rd_rid = RID()

	RenderingServer.call_on_render_thread(_free_compute_resources)

func _process(delta: float) -> void:
	if texture:
		texture.texture_rd_rid = texture_rds[next_texture]
	next_texture = (next_texture + 1) % 2
	time += delta
	RenderingServer.call_on_render_thread(_render_process.bind(next_texture, texture_size, time))

###############################################################################
# Everything after this point is designed to run on our rendering thread.

var rd: RenderingDevice

var shader: RID
var pipeline: RID
var sampler : RID

var texture_rds: Array[RID] = [RID(), RID()]
var texture_sets_samplers: Array[RID] = [RID(), RID()]
var texture_sets_images: Array[RID] = [RID(), RID()]
var flow_texture_set: RID

func _create_image_uniform_set(texture_rd: RID, uniform_set : int) -> RID:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = 0
	uniform.add_id(texture_rd)
	return rd.uniform_set_create([uniform], shader, uniform_set)
	
func _create_sampler_uniform_set(texture_rd: RID, uniform_set : int) -> RID:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = 0
	uniform.add_id(sampler)
	uniform.add_id(texture_rd)
	return rd.uniform_set_create([uniform], shader, uniform_set)

func _initialize_compute_code(init_with_texture_size: Vector2i, flow_tex : Texture) -> void:
	rd = RenderingServer.get_rendering_device()

	shader = rd.shader_create_from_spirv(load("res://shaders/vector_map.glsl").get_spirv())
	pipeline = rd.compute_pipeline_create(shader)
	
	var sampler_state : RDSamplerState = RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler = rd.sampler_create(sampler_state)

	flow_texture_set = _create_sampler_uniform_set(RenderingServer.texture_get_rd_texture(flow_tex.get_rid()), 3)
	
	var tf: RDTextureFormat = RDTextureFormat.new()
	tf.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.width = init_with_texture_size.x
	tf.height = init_with_texture_size.y
	tf.depth = 1
	tf.array_layers = 1
	tf.mipmaps = 1
	tf.usage_bits = (
			RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
			RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT |
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
			RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT |
			RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT |
			RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)

	for i in 2:
		texture_rds[i] = rd.texture_create(tf, RDTextureView.new(), [])
		rd.texture_clear(texture_rds[i], Color(0.735, 0.735, 0.0, 1.0), 0, 1, 0, 1) # sRGB equivalent to (0.5, 0.5, 0.0, 1.0) in linear space

		texture_sets_samplers[i] = _create_sampler_uniform_set(texture_rds[i], 0)
		texture_sets_images[i] = _create_image_uniform_set(texture_rds[i], 1)


func _render_process(with_next_texture : int, tex_size : Vector2i, curr_time : float) -> void:
	var push_constant : PackedFloat32Array = [
		forward_offset,
		forward_fadeoff,
		flow_strength,
		flow_randomize,
		
		flow_random_speed,
		blur_strength,
		blur_offset,
		curl_strength,
		
		curl_offset,
		0.0, # padding
		shift_vector.x,
		shift_vector.y,
		
		shift_speed,
		curr_time,
		0.0, # padding
		0.0 # padding
		]
	
	@warning_ignore("integer_division")
	var x_groups : int = (tex_size.x - 1) / 8 + 1
	@warning_ignore("integer_division")
	var y_groups : int = (tex_size.y - 1) / 8 + 1

	var current_set := texture_sets_samplers[(with_next_texture - 1) % 2]
	var next_set := texture_sets_images[with_next_texture]

	# Run our compute shader.
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, current_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, next_set, 1)
	rd.compute_list_bind_uniform_set(compute_list, flow_texture_set, 3)
	rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
	rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
	rd.compute_list_end()

func _free_compute_resources() -> void:
	# Note that our sets and pipeline are cleaned up automatically as they are dependencies :P
	for i in 2:
		if texture_rds[i]:
			rd.free_rid(texture_rds[i])

	if shader:
		rd.free_rid(shader)
