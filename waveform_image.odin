package waveform_editor

import "core:container/handle_map"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:strings"

import imgui "../../shared/odin-imgui/"
import "assets"
import sdl "vendor:sdl3"
import stbimg "vendor:stb/image"

CropDrag :: enum {
	Up,
	Down,
	Left,
	Right,
}

EyeDropState :: enum {
	Idle,
	IdleHold,
	Active,
}

WEImageState :: struct {
	pixels:        ImageData,
	texture:       Maybe(^sdl.GPUTexture),
	scale:         f32,
	ox:            f32, //o = offset of top left corner of window
	oy:            f32,
	rx:            f32, //r = region
	ry:            f32,
	rw:            f32,
	rh:            f32,
	mid_rx:        f32, //Mid coordinates of r after dragging the first time
	mid_ry:        f32,
	cr:            i32,
	cg:            i32,
	cb:            i32,
	parse_color:   u32,
	crop:          bit_set[CropDrag],
	old_c:         [3]u8,
	eyedrop_state: EyeDropState,
	interp:        InterpolationType,
	use_lmb:       bool,
	use_pan:       bool,
	init_center:   bool,
}

we_image_state_new :: proc(app: ^App, file_cstr: cstring) -> (WEImageState, bool) {
	state: WEImageState = {
		scale  = 1,
		cr     = 0xff,
		cg     = 0xff,
		cb     = 0xff,
		interp = .Linear,
	}
	state.pixels = load_image(file_cstr)
	if (state.pixels.data == nil) {
		log.errorf("Unable to load image %s: %s", file_cstr, stbimg.failure_reason())
		return {}, false
	}
	state.rw = f32(state.pixels.width)
	state.rh = f32(state.pixels.height)
	state.texture = imgui_load_texture(app.gpu, &state.pixels)
	if state.texture == nil {
		free_image(&state.pixels)
		return {}, false
	}
	return state, true
}

we_image_state_destroy :: proc(we_img: ^WEImageState, app: ^App) {
	if img_txt, exists := we_img.texture.?; exists {
		sdl.ReleaseGPUTexture(app.gpu, img_txt)
		we_img.texture = nil
	}
	free_image(&we_img.pixels)
}

we_image_new :: proc(app: ^App) -> bool {
	if !app.windows.image.base.is_active {
		frame_size := imgui.GetFrameHeight()
		app.windows.image = imgui_window_new(
			"Image",
			0,
			container_f = f_image_draw,
			destroy_f = f_image_destroy,
			position = {UDim{s = 0.25}, UDim{o = frame_size}},
			size = {UDim{s = 0.75}, UDim{s = 0.75, o = -frame_size}},
			flags = {.NoScrollWithMouse, .NoScrollbar, .MenuBar},
		)
		imgui_obj_add_handle(app, &app.windows.image.base)
		return true
	} else do return false
}

//Transformation: T(tl.x,tl.y) * T(we_img.ox,we_img.oy) * S(we_img.scale)
image_to_window_m :: #force_inline proc(
	win_tl: [2]f32,
	we_img: ^WEImageState,
) -> linalg.Matrix3x3f32 {
    //odinfmt: disable
    return {
        we_img.scale, 0,            we_img.ox + win_tl.x,
        0,            we_img.scale, we_img.oy + win_tl.y,
        0,            0,            1,
    }
    //odinfmt: enable
}
//Transformation: S(1/we_img.scale) * T(-tl.x,-tl.y) * T(-we_img.ox,-we_img.oy)
window_to_image_m :: #force_inline proc(
	win_tl: [2]f32,
	we_img: ^WEImageState,
) -> linalg.Matrix3x3f32 {
    //odinfmt: disable
    return {
        1 / we_img.scale, 0,                (-we_img.ox - win_tl.x) / we_img.scale,
        0,                1 / we_img.scale, (-we_img.oy - win_tl.y) / we_img.scale,
        0,                0,                1,
    }
    //odinfmt: enable
}

f_image_draw :: proc(base: ^ImGuiBase, app: ^App, win_idx: int, userdata: rawptr) {
	frame_size := imgui.GetFrameHeight()
	draw_list := imgui.GetWindowDrawList()
	io := imgui.GetIO()
	style := imgui.GetStyle()
	wp := imgui.GetWindowPos()
	imgui_tl := [2]f32{0, frame_size * 2}
	win_tl := wp + imgui_tl
	win_br := wp + imgui.GetWindowSize()
	content_size := imgui.GetWindowSize() - imgui_tl
	mouse_c := imgui.GetMousePos()
	we_img := &app.state.we_img
	if !we_img.init_center {
		we_img.ox = (content_size.x - f32(we_img.pixels.width)) / 2
		we_img.oy = (content_size.y - f32(we_img.pixels.height)) / 2
		we_img.init_center = true
	}
	if imgui.IsWindowFocused() || imgui.IsWindowHovered() {
		la := imgui.GetKeyData(.LeftArrow)
		ra := imgui.GetKeyData(.RightArrow)
		ua := imgui.GetKeyData(.UpArrow)
		da := imgui.GetKeyData(.DownArrow)
		if la.Down {
			we_img.ox += math.pow_f32(1.5, la.DownDuration)
		}
		if ra.Down {
			we_img.ox -= math.pow_f32(1.5, ra.DownDuration)
		}
		if ua.Down {
			we_img.oy += math.pow_f32(1.5, ua.DownDuration)
		}
		if da.Down {
			we_img.oy -= math.pow_f32(1.5, da.DownDuration)
		}
		if imgui.IsKeyPressed(.I) || io.MouseWheel > 0 {
			img_coord := (window_to_image_m(win_tl, we_img) * [3]f32{mouse_c.x, mouse_c.y, 1}).xy
			old_scale := we_img.scale
			we_img.scale = min(we_img.scale * 2, 256)
			scale_to_move := we_img.scale - old_scale
			we_img.ox -= img_coord.x * scale_to_move
			we_img.oy -= img_coord.y * scale_to_move
		}
		if imgui.IsKeyPressed(.O) || io.MouseWheel < 0 {
			img_coord := (window_to_image_m(win_tl, we_img) * [3]f32{mouse_c.x, mouse_c.y, 1}).xy
			old_scale := we_img.scale
			we_img.scale = max(we_img.scale / 2, 1 / 256)
			scale_to_move := we_img.scale - old_scale
			we_img.ox -= img_coord.x * scale_to_move
			we_img.oy -= img_coord.y * scale_to_move
		}
		if imgui.IsMouseDown(.Right) {
			we_img.use_pan = true
		}
		if imgui.IsKeyPressed(.R) || imgui.IsMouseClicked(.Middle, false) {
			we_img.ox = 0
			we_img.oy = 0
			we_img.scale = 1
		}
		_image_keybinds(base, app, win_idx, userdata)
	}
	if we_img.use_pan {
		if mouse_dt := mouse_c - io.MousePosPrev; mouse_dt != {0.0, 0.0} {
			we_img.ox += mouse_dt.x
			we_img.oy += mouse_dt.y
		}
		if imgui.IsMouseReleased(.Right) {
			we_img.use_pan = false
		}
	}
	image_to_window := image_to_window_m(win_tl, we_img)
	window_to_image := window_to_image_m(win_tl, we_img)
	img_tl := (image_to_window * [3]f32{0, 0, 1}).xy
	img_br :=
		(image_to_window * [3]f32{f32(app.state.we_img.pixels.width), f32(app.state.we_img.pixels.height), 1}).xy

	imgui.DrawList_AddCallback(
		draw_list,
		imgui.GetPlatformIO().DrawCallback_SetSamplerNearest,
		nil,
	)
	imgui.DrawList_AddImage(draw_list, as_texture_ref(app.state.we_img.texture), img_tl, img_br)
	imgui.DrawList_AddCallback(draw_list, imgui.GetPlatformIO().DrawCallback_SetSamplerLinear, nil)

	imgui.DrawList_AddRect(
		draw_list,
		(image_to_window * [3]f32{we_img.rx, we_img.ry, 1}).xy,
		(image_to_window * [3]f32{we_img.rx + we_img.rw, we_img.ry + we_img.rh, 1}).xy,
		0xff000000,
		thickness = 3,
	)
	imgui.DrawList_AddRect(
		draw_list,
		(image_to_window * [3]f32{we_img.rx, we_img.ry, 1}).xy,
		(image_to_window * [3]f32{we_img.rx + we_img.rw, we_img.ry + we_img.rh, 1}).xy,
		0xffffffff,
	)
	imgui.DrawList_AddLine(
		draw_list,
		(image_to_window * [3]f32{we_img.rx, we_img.ry + we_img.rh / 2, 1}).xy,
		(image_to_window * [3]f32{we_img.rx + we_img.rw, we_img.ry + we_img.rh / 2, 1}).xy,
		0xff0000ff,
	)
	img_coord := (window_to_image * [3]f32{mouse_c.x, mouse_c.y, 1}).xy
	if !we_img.use_lmb {
		imgui.SetCursorPos(imgui_tl)
		imgui.InvisibleButton("LMBDrag", content_size)
		if imgui.IsItemHovered() {
			if we_img.eyedrop_state == .Idle &&
			   we_img.crop == {} &&
			   imgui.IsMouseClicked(.Left, false) {
				less_dist: f32 = math.inf_f32(1)
				if img_coord.x >= we_img.rx && img_coord.x <= we_img.rx + we_img.rw {
					dist: f32 = ---
					if dist = math.abs(img_coord.y - we_img.ry); dist < less_dist {
						we_img.crop = {.Up}
						less_dist = dist
					}
					if dist = math.abs(img_coord.y - we_img.ry - we_img.rh); dist < less_dist {
						we_img.crop = {.Down}
						less_dist = dist
					}
				} else if img_coord.y >= we_img.ry && img_coord.y <= we_img.ry + we_img.rh {
					dist: f32 = ---
					if dist = math.abs(img_coord.x - we_img.rx); dist < less_dist {
						we_img.crop = {.Left}
						less_dist = dist
					}
					if dist = math.abs(img_coord.x - we_img.rx - we_img.rw); dist < less_dist {
						we_img.crop = {.Right}
						less_dist = dist
					}
				} else {
					switch {
					case img_coord.x < we_img.rx && img_coord.y < we_img.ry:
						we_img.crop = {.Up, .Left}
					case img_coord.x > we_img.rx + we_img.rw && img_coord.y < we_img.ry:
						we_img.crop = {.Up, .Right}
					case img_coord.x < we_img.rx && img_coord.y > we_img.ry + we_img.rh:
						we_img.crop = {.Down, .Left}
					case img_coord.x > we_img.rx + we_img.rw &&
					     img_coord.y > we_img.ry + we_img.rh:
						we_img.crop = {.Down, .Right}
					}
				}
				we_img.mid_rx = we_img.rx + we_img.rw / 2
				we_img.mid_ry = we_img.ry + we_img.rh / 2
			}
		}
	}
	#partial switch we_img.eyedrop_state {
	case .IdleHold:
		if !imgui.IsMouseDown(.Left) {
			we_img.eyedrop_state = .Active
		}
	case .Active:
		custom_cursor(app, .Eyedropper, {20, 20}, {0, -20})
		round_img_coord := [2]i32{i32(img_coord.x), i32(img_coord.y)}
		if round_img_coord.x >= 0 &&
		   round_img_coord.x <= i32(we_img.pixels.width - 1) &&
		   round_img_coord.y >= 0 &&
		   round_img_coord.y <= i32(we_img.pixels.height - 1) {
			p_off := cast([^]u8)&we_img.pixels.data[4 * (round_img_coord.y * we_img.pixels.width + round_img_coord.x)]
			we_img.cr = i32(p_off[0])
			we_img.cg = i32(p_off[1])
			we_img.cb = i32(p_off[2])
			if imgui.IsMouseClicked(.Left) {
				we_img.eyedrop_state = .Idle
			}
		}
		if imgui.IsKeyPressed(.Escape) {
			we_img.eyedrop_state = .Idle
			we_img.cr = i32(we_img.old_c.r)
			we_img.cg = i32(we_img.old_c.g)
			we_img.cb = i32(we_img.old_c.b)
		}
	}
	imgui.DrawList_AddRectFilled(draw_list, win_tl + {0, content_size.y - 100}, win_br, 0xff1f1f1f)
	imgui.SetCursorPos(imgui_tl + {0, content_size.y - 100})
	if imgui.BeginChild("Bottom Panel", {content_size.x, 100}) {
		imgui.SetCursorPos(style.FramePadding)
		defer imgui.EndChild()
		help_marker(
			"Parse Region determines the region of the image\nwhere the code will parse the image for a waveform\nof an oscilloscope.",
		)
		imgui.Text("Parse Region")
		imgui.SetCursorPosX(style.FramePadding.x)
		imgui.SetNextItemWidth(100)
		old_rx := we_img.rx
	        //odinfmt: disable
		if imgui.DragFloat("X", &we_img.rx, 1.0, 0, f32(we_img.pixels.width), "%.0f", {.ClampOnInput}) {
            we_img.rx = math.round(we_img.rx)
            if we_img.rx + we_img.rw > f32(we_img.pixels.width) {
                we_img.rx = old_rx
            }
		}
        //odinfmt: enable
		imgui.SameLine()
		imgui.SetNextItemWidth(100)
		old_ry := we_img.ry
	        //odinfmt: disable
		if imgui.DragFloat("Y", &we_img.ry, 1.0, 0, f32(we_img.pixels.height), "%.0f", {.ClampOnInput}) {
            we_img.ry = math.round(we_img.ry)
            if we_img.ry + we_img.rh > f32(we_img.pixels.height) {
                we_img.ry = old_ry
            }
        }
        //odinfmt: enable
		imgui.SameLine()
		imgui.SetNextItemWidth(100)
		old_rw := we_img.rw
	        //odinfmt: disable
		if imgui.DragFloat("Width", &we_img.rw, 1.0, 0, f32(we_img.pixels.width), "%.0f", {.ClampOnInput}) {
            we_img.rw = math.round(we_img.rw)
			if we_img.rx + we_img.rw > f32(we_img.pixels.width) {
				we_img.rw = old_rw
			}
		}
        //odinfmt: enable
		imgui.SameLine()
		imgui.SetNextItemWidth(100)
		old_rh := we_img.rh
	        //odinfmt: disable
		if imgui.DragFloat("Height", &we_img.rh, 1.0, 0, f32(we_img.pixels.height), "%.0f", {.ClampOnInput}) {
            we_img.rh = math.round(we_img.rh)
            if we_img.ry + we_img.rh > f32(we_img.pixels.height) {
                we_img.rh = old_rh
            }
        }
        //odinfmt: enable
		imgui.SetCursorPosX(style.FramePadding.x)
		help_marker(
			"Parse Color determines the line color that will be used to\ninterpret as sample values of a waveform in an oscilloscope image.",
		)
		imgui.Text("Parse Color")
		imgui.SetCursorPosX(style.FramePadding.x)
		imgui.SetNextItemWidth(100)
		imgui.DragInt("Red", &we_img.cr, 1.0, 0, 255, flags = {.ClampOnInput})
		imgui.SameLine()
		imgui.SetNextItemWidth(100)
		imgui.DragInt("Green", &we_img.cg, 1.0, 0, 255, flags = {.ClampOnInput})
		imgui.SameLine()
		imgui.SetNextItemWidth(100)
		imgui.DragInt("Blue", &we_img.cb, 1.0, 0, 255, flags = {.ClampOnInput})
		imgui.SameLine()
		imgui.ColorButton(
			"Color",
			{f32(we_img.cr) / f32(255), f32(we_img.cg) / f32(255), f32(we_img.cb) / f32(255), 1},
		)
		imgui.SameLine()
		if imgui.ImageButton(
			"Extract",
			as_texture_ref(app, TextureNames.tex_atlas),
			{imgui.GetTextLineHeightWithSpacing(), imgui.GetTextLineHeightWithSpacing()},
			assets.tex_atlas_uv[.Eyedropper].tl,
			assets.tex_atlas_uv[.Eyedropper].br,
		) {
			we_img.old_c = {u8(we_img.cr), u8(we_img.cg), u8(we_img.cb)}
			we_img.eyedrop_state = .IdleHold
		}
	}
	if we_img.crop != {} {
		if .Up in we_img.crop do _we_image_drag_up(app, img_coord)
		if .Down in we_img.crop do _we_image_drag_down(app, img_coord)
		if .Left in we_img.crop do _we_image_drag_left(app, img_coord)
		if .Right in we_img.crop do _we_image_drag_right(app, img_coord)
		switch {
		case we_img.crop == {.Up, .Left} || we_img.crop == {.Down, .Right}:
			imgui.SetMouseCursor(.ResizeNWSE)
		case we_img.crop == {.Up, .Right} || we_img.crop == {.Down, .Left}:
			imgui.SetMouseCursor(.ResizeNESW)
		case .Up in we_img.crop || .Down in we_img.crop:
			imgui.SetMouseCursor(.ResizeNS)
		case .Left in we_img.crop || .Right in we_img.crop:
			imgui.SetMouseCursor(.ResizeEW)
		}
		if imgui.IsMouseReleased(.Left) {
			we_img.crop = {}
		}
	}
	if imgui.BeginMenuBar() {
		defer imgui.EndMenuBar()
		if imgui.BeginMenu("Window") {
			defer imgui.EndMenu()
			help_marker("Disables LMB to allow dragging image window")
			if imgui.MenuItem("Disable LMB", "Ctrl+W", we_img.use_lmb) {
				we_img.use_lmb = !we_img.use_lmb
			}
			_image_keybinds(base, app, win_idx, userdata)
		}
		if imgui.BeginMenu("Process To") {
			defer imgui.EndMenu()
			at_least_one := false
			imgui.Text("Waveform Editor Window:")
			for win_i in 0 ..< MAX_WAVEFORM_EDITOR_WINDOWS {
				window := &app.windows.waveform_editors[win_i]
				if window.base.is_active {
					we_state := &app.state.we[win_i]
					sb := &window.base.id.(strings.Builder)
					no_create: if imgui.MenuItem(cstring(&sb.buf[0])) {
						image_samples := make([dynamic]f32)
						defer delete(image_samples)
						for x in i32(we_img.rx) ..< i32(we_img.rx) + i32(we_img.rw) {
							choose_y: i32 = 0
							min_dist: f32 = math.inf_f32(1)
							for y := i32(we_img.ry) + i32(we_img.rh) - 1;
							    y >= i32(we_img.ry);
							    y -= 1 {
								p_off := cast([^]u8)&we_img.pixels.data[4 * (y * i32(we_img.pixels.width) + x)]
								dr := f32(we_img.cr) - f32(p_off[0])
								dg := f32(we_img.cg) - f32(p_off[1])
								db := f32(we_img.cb) - f32(p_off[2])
								dist := math.sqrt(dr * dr + dg * dg + db * db)
								if dist < min_dist {
									min_dist = dist
									choose_y = y - i32(we_img.ry)
								}
							}
							append_elem(&image_samples, f32(i32(we_img.rh) - 1 - choose_y)) //Flip y as + up and - down
						}
						for &s in image_samples {
							assert(s < we_img.rh)
							s = new_range_f32(s, {0, we_img.rh - 1}, {-1, 1})
						}
						undo_redo_manager_undo_add_stop(&we_state.undo_redo)
						if app.state.import_wf_at_end {
							if we_state.num_frames == MAX_WAVEFORM_FRAMES do break no_create
							we_state.data_frame = we_state.num_frames
							undo_redo_manager_undo_setmaxframes(
								&we_state.undo_redo,
								app,
								win_idx,
								we_state.num_frames,
							)
							set_frames(app, win_idx, we_state.num_frames + 1)
							we_state.num_frames += 1
						}
						undo_redo_manager_undo_data_frame(
							&we_state.undo_redo,
							app,
							win_idx,
							we_state.data_frame,
						)
						for npi in 0 ..< we_state.num_points {
							undo_redo_manager_undo_wedraw(
								&we_state.undo_redo,
								app,
								win_idx,
								npi,
								we_state.data_frame,
							)
						}
						paste_interpolated_samples(
							we_state.data[data_index(we_state.data_frame, 0):data_index(
								we_state.data_frame,
								u32(we_state.num_points),
							)],
							image_samples[:],
							we_img.interp,
						)
						if app.state.import_wf_norm {
							effect_normalization_full(app, win_idx, 1)
						}
					}
					at_least_one = true
				}
			}
			if !at_least_one do imgui.MenuItem("(No Windows Available)", enabled = false)
			imgui.Separator()
			help_marker(
				"Interpolates values between sample points using the following\nNone: Interpolate using the leftmost point only\nLinear: Interpolation between the last and next point\nCubic Hermite: Interpolation using 4 points (f(x_m1), f(x0), f(x1), f(x2))\nto calculate between x0 and x1",
			)
			imgui.Text("Audio Interpolation")
			imgui.Combo("##Interpolation", cast(^i32)&we_img.interp, _INTERPOLATION_TYPE_CSTR)
			imgui.Separator()
			help_marker(
				"Appends waveform data as a frame at the end and increase maximum frames by 1",
			)
			if imgui.MenuItem("Import At End", selected = app.state.import_wf_at_end) {
				app.state.import_wf_at_end = !app.state.import_wf_at_end
			}
			help_marker(
				"Normalize waveform so that its peaks reach either 1 or -1\nWaveform must cross 0 for this to work",
			)
			if imgui.MenuItem("Normalize", selected = app.state.import_wf_norm) {
				app.state.import_wf_norm = !app.state.import_wf_norm
			}
		}
	}
}
_we_image_drag_up :: proc(app: ^App, img_coord: [2]f32, use_shift: bool = true) {
	we_img := &app.state.we_img
	if use_shift {
		if imgui.IsKeyDown(.ImGuiMod_Shift) {
			if img_coord.y < we_img.mid_ry {
				_we_image_drag_down(
					app, //Reflect img_coord at line mid_ry
					{img_coord.x, img_coord.y + 2 * (we_img.mid_ry - img_coord.y)},
					false,
				)
			} else {
				we_img.ry = we_img.mid_ry
				we_img.rh = 0
				return
			}
		}
	}
	old_ry := we_img.ry
	we_img.ry = math.max(0, math.round(img_coord.y))
	ry_dif := we_img.ry - old_ry
	ry_adj := math.min(we_img.rh - ry_dif, 0)
	we_img.rh -= ry_dif + ry_adj
	we_img.ry += ry_adj
}
_we_image_drag_down :: proc(app: ^App, img_coord: [2]f32, use_shift: bool = true) {
	we_img := &app.state.we_img
	if use_shift {
		if imgui.IsKeyDown(.ImGuiMod_Shift) {
			if img_coord.y > we_img.mid_ry {
				_we_image_drag_up(
					app,
					{img_coord.x, img_coord.y + 2 * (we_img.mid_ry - img_coord.y)},
					false,
				)
			} else {
				we_img.ry = we_img.mid_ry
				we_img.rh = 0
				return
			}
		}
	}
	we_img.rh = math.clamp(
		math.round(img_coord.y) - we_img.ry,
		0,
		f32(we_img.pixels.height) - we_img.ry,
	)
}
_we_image_drag_left :: proc(app: ^App, img_coord: [2]f32, use_shift: bool = true) {
	we_img := &app.state.we_img
	if use_shift {
		if imgui.IsKeyDown(.ImGuiMod_Shift) {
			if img_coord.x < we_img.mid_rx {
				_we_image_drag_right(
					app, //Reflect img_coord at line mid_rx
					{img_coord.x + 2 * (we_img.mid_rx - img_coord.x), img_coord.y},
					false,
				)
			} else {
				we_img.rx = we_img.mid_rx
				we_img.rw = 0
				return
			}
		}
	}
	old_rx := we_img.rx
	we_img.rx = math.max(0, math.round(img_coord.x))
	rx_dif := we_img.rx - old_rx
	rx_adj := math.min(we_img.rw - rx_dif, 0)
	we_img.rw -= rx_dif + rx_adj
	we_img.rx += rx_adj
}
_we_image_drag_right :: proc(app: ^App, img_coord: [2]f32, use_shift: bool = true) {
	we_img := &app.state.we_img
	if use_shift {
		if imgui.IsKeyDown(.ImGuiMod_Shift) {
			if img_coord.x > we_img.mid_rx {
				_we_image_drag_left(
					app,
					{img_coord.x + 2 * (we_img.mid_rx - img_coord.x), img_coord.y},
					false,
				)
			} else {
				we_img.rx = we_img.mid_rx
				we_img.rw = 0
				return
			}
		}
	}
	we_img.rw = math.clamp(
		math.round(img_coord.x) - we_img.rx,
		0,
		f32(we_img.pixels.width) - we_img.rx,
	)
}

_image_keybinds :: proc(base: ^ImGuiBase, app: ^App, win_idx: int, userdata: rawptr) {
	we_img := &app.state.we_img
	if imgui.IsKeyDown(.ImGuiMod_Ctrl) {
		if imgui.IsKeyPressed(.W, false) {
			we_img.use_lmb = !we_img.use_lmb
		}
	}
}

f_image_destroy :: proc(base: ^ImGuiBase, app: ^App, win_idx: int, userdata: rawptr) {
	handle_map.remove(&app.imgui_hm, base.handle)
	we_image_state_destroy(&app.state.we_img, app)
	base.is_active = false
}
