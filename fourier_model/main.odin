package fourier_model

import "core:math"

Waveform_Model :: struct {
	n:     int,
	amp:   [dynamic]f32,
	phase: [dynamic]f32,
}

//Using Discrete Fourier Transform (DFT)
//
//Modelling as f(x) = sum(amp_h * sin(h * omega * x + phase_h))
//
//Where h=1 is the fundamental, omega = 2*pi / len(values)
//
//amp_h = sqrt(a_h^2 + b_h^2), phase_h = atan2(a_h, b_h)
waveform_model_new :: proc(values: []f32, num_harmonics: int) -> Waveform_Model {
	len_v := len(values)
	max_h := min(num_harmonics, len_v / 2)
	model := Waveform_Model {
		n     = max_h,
		amp   = make([dynamic]f32, 0, max_h + 1),
		phase = make([dynamic]f32, 0, max_h + 1),
	}
	sum: f32 = 0.0
	for v in values {
		sum += v
	}
	append(&model.amp, math.abs(sum / f32(len_v)))
	append(&model.phase, 0.0)
	for h in 1 ..= max_h {
		ac, bc: f32
		for i in 0 ..< len_v {
			angle := 2.0 * math.PI * f32(h) * f32(i) / f32(len_v)
			ac += values[i] * math.cos(angle)
			bc += values[i] * math.sin(angle)
		}
		append(&model.amp, math.sqrt(ac * ac + bc * bc) * 2.0 / f32(len_v))
		append(&model.phase, math.atan2(ac, bc))
	}
	return model
}
waveform_model_evaluate_f :: proc(model: ^Waveform_Model, x: f32, v_len: i32) -> f32 {
	omega := 2.0 * math.PI / f32(v_len)
	result := model.amp[0]
	for h in 1 ..= model.n {
		result += model.amp[h] * math.sin(omega * f32(h) * x + model.phase[h])
	}
	return result
}
waveform_model_destroy :: proc(model: ^Waveform_Model) {
	delete(model.amp)
	delete(model.phase)
}
