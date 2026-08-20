package waveform_editor

import "core:c"
import "core:mem"

import imgui "imgui:/"
import "assets"
import sdl "vendor:sdl3"
import stbimg "vendor:stb/image"

TextureNames :: enum {
	tex_atlas,
}
TexturePaths := [TextureNames]string {
	.tex_atlas = assets.tex_atlas_bytes,
}

ImageData :: struct {
	width:  c.int,
	height: c.int,
	data:   [^]u8,
}
load_image :: proc(path: cstring) -> ImageData {
	width, height, ch: c.int = ---, ---, ---
	data := stbimg.load(path, &width, &height, &ch, 4)
	if data == nil {
		return {}
	}
	return ImageData{width = width, height = height, data = data}
}
load_from_memory :: proc(bytes: string) -> ImageData {
	width, height, ch: c.int = ---, ---, ---
	data := stbimg.load_from_memory(raw_data(bytes), c.int(len(bytes)), &width, &height, &ch, 4)
	if data == nil {
		return {}
	}
	return ImageData{width = width, height = height, data = data}
}

free_image :: proc(id: ^ImageData) {
	if id.data != nil {
		stbimg.image_free(id.data)
		id.data = nil
	}
}

imgui_load_texture :: proc(gpu: ^sdl.GPUDevice, img: ^ImageData) -> ^sdl.GPUTexture {
	gpu_tex := sdl.CreateGPUTexture(
		gpu,
		sdl.GPUTextureCreateInfo {
			type = .D2,
			format = .R8G8B8A8_UNORM,
			width = u32(img.width),
			height = u32(img.height),
			layer_count_or_depth = 1,
			num_levels = 1,
			usage = {.SAMPLER},
		},
	)
	if gpu_tex == nil do return nil

	image_size := int(img.width * img.height * 4)
	tbuf := sdl.CreateGPUTransferBuffer(
		gpu,
		sdl.GPUTransferBufferCreateInfo{usage = .UPLOAD, size = u32(image_size)},
	)
	if tbuf == nil {
		sdl.ReleaseGPUTexture(gpu, gpu_tex)
		return nil
	}
	defer sdl.ReleaseGPUTransferBuffer(gpu, tbuf)

	buf_data := sdl.MapGPUTransferBuffer(gpu, tbuf, true)
	mem.copy_non_overlapping(buf_data, img.data, image_size)
	sdl.UnmapGPUTransferBuffer(gpu, tbuf)

	cmd := sdl.AcquireGPUCommandBuffer(gpu)
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUTexture(
		copy_pass,
		sdl.GPUTextureTransferInfo{transfer_buffer = tbuf, offset = 0},
		sdl.GPUTextureRegion{texture = gpu_tex, w = u32(img.width), h = u32(img.height), d = 1},
		true,
	)
	sdl.EndGPUCopyPass(copy_pass)
	assert(sdl.SubmitGPUCommandBuffer(cmd))
	assert(sdl.WaitForGPUIdle(gpu))
	return gpu_tex
}
as_texture_ref :: proc {
	as_texture_ref_asset,
	as_texture_ref_sdl3_texture,
}
as_texture_ref_asset :: #force_inline proc(app: ^App, texture: TextureNames) -> imgui.TextureRef {
	return {_TexID = u64(uintptr(app.textures[texture]))}
}
as_texture_ref_sdl3_texture :: #force_inline proc(
	texture: Maybe(^sdl.GPUTexture),
) -> imgui.TextureRef {
	return {_TexID = u64(uintptr(texture.?))}
}

custom_cursor :: proc(
	app: ^App,
	sub: assets.tex_atlas,
	mouse_size: imgui.Vec2,
	offset: imgui.Vec2,
) {
	fg_draw_list := imgui.GetForegroundDrawList()
	mouse_c := imgui.GetMousePos()
	imgui.SetMouseCursor(.None)
	imgui.DrawList_AddImage(
		fg_draw_list,
		as_texture_ref(app, TextureNames.tex_atlas),
		mouse_c + offset,
		mouse_c + offset + mouse_size,
		assets.tex_atlas_uv[sub].tl,
		assets.tex_atlas_uv[sub].br,
	)
}
