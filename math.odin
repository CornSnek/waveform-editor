package waveform_editor

import "base:intrinsics"
import "core:math"
import "core:math/linalg"

//Convert x in range [a,b] -> f(x) in [c,d]. Doesn't check if x is within [a,b]
new_range_f32 :: proc "contextless" (
	x: f32,
	a_b: linalg.Vector2f32,
	c_d: linalg.Vector2f32,
) -> f32 {
	return new_range(x, a_b.x, a_b.y, c_d.x, c_d.y)
}
new_range :: proc "contextless" (
	x: $T,
	a: T,
	b: T,
	c: T,
	d: T,
) -> T where intrinsics.type_is_float(T) {
	return (x - a) * (d - c) / (b - a) + c
}
HERTZ_A4 :: 440
HERTZ_SEMITONES :: 12 * 4 + 9
FrequencyAdjust :: enum {
	Down,
	Up,
}
frequency_relative_a4 :: proc "contextless" (rel_semitones: i16) -> f32 {
	return HERTZ_A4 * math.pow_f32(2, f32(rel_semitones) / 12)
}
semitone_relative_a4 :: proc "contextless" (freq: f32) -> f32 {
	return 12 * math.log10(freq / HERTZ_A4) / math.log10(f32(2))
}
//Adjust frequency to next appropriate semitone
//dt used to go up/down semitone by 1 or 2 appropriately
adjust_frequency_key_step :: proc(freq: f32, adj: FrequencyAdjust, dt: f32 = 0.00001) -> f32 {
	semitone_est := semitone_relative_a4(freq)
	semitone_int := i16(semitone_est)
	semitone_part := semitone_est - f32(semitone_int)
	if semitone_est > 0 {
		if adj == .Down {
			if math.abs(semitone_part) < dt {
				semitone_int -= 1
			}
		} else { 	//semitone_part ~= -1 on negative
			if math.abs(semitone_part - 1) < dt {
				semitone_int += 2
			} else {
				semitone_int += 1
			}
		}
	} else {
		if adj == .Down { 	//semitone_part ~= +1 on positive
			if math.abs(-semitone_part - 1) < dt {
				semitone_int -= 2
			} else {
				semitone_int -= 1
			}
		} else {
			if math.abs(-semitone_part - 1) >= dt { 	//It may skip by +2 if |-semitone_part-1| < dt
				semitone_int += 1
			}
		}
	}
	return frequency_relative_a4(semitone_int)
}
//x0x1 values [0,1] between x of y0 and y1 using 4 points
cubic_hermite :: proc "contextless" (x0x1, y_m1, y0, y1, y2: f32) -> f32 {
	x0x1_sq := x0x1 * x0x1
	x0x1_cu := x0x1_sq * x0x1
	a := -0.5 * y_m1 + 1.5 * y0 - 1.5 * y1 + 0.5 * y2
	b := y_m1 - 2.5 * y0 + 2.0 * y1 - 0.5 * y2
	c := -0.5 * y_m1 + 0.5 * y1
	return a * x0x1_cu + b * x0x1_sq + c * x0x1 + y0
}
//T_0(x) = 1, T_1(x) = x, T_{n+1}(x) = 2*x*T_n(x) - T_{n-1}(x)
chebyshev_wavefold :: proc "contextless" (x: $T, n: i32) -> T where intrinsics.type_is_float(T) {
	if n == 0 {
		return 1
	}
	tn, tnp1 := T(1), x
	for _ in 0 ..< n - 1 {
		old_tn := tn
		tn = tnp1
		tnp1 = 2 * x * tnp1 - old_tn
	}
	return tnp1
}

cstr_th_num :: proc "contextless" (i: i32) -> cstring {
	switch i {
	case 1:
		return "st"
	case 2:
		return "nd"
	case 3:
		return "rd"
	case:
		return "th"
	}
}

paste_interpolated_samples :: proc(dst, src: []f32, interp: InterpolationType) {
	assert(len(src) != 0 && len(dst) != 0)
	for &d_e, d_idx in dst {
		s_idxf := f32(d_idx) * f32(len(src)) / f32(len(dst)) //[0,dst_len) to [0,src_len)
		s_idxif, s_rem := math.modf(s_idxf)
		s_idx := i32(s_idxif)
		switch interp {
		case .None:
			d_e = src[s_idx]
		case .Linear:
			slope := src[(s_idx + 1) % i32(len(src))] - src[s_idx]
			d_e = src[s_idx] + slope * s_rem
		case .Cubic:
			y_m1 := src[(i32(len(src)) + s_idx - 1) % i32(len(src))]
			y0 := src[s_idx]
			y1 := src[(s_idx + 1) % i32(len(src))]
			y2 := src[(s_idx + 2) % i32(len(src))]
			d_e = cubic_hermite(s_rem, y_m1, y0, y1, y2)
		}
	}
}
