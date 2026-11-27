//! DeepFilterNet 3 for voicefx: see Cargo.toml.
use std::ffi::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::null_mut;

use df::tract::{DfParams, DfTract, ReduceMask, RuntimeParams};
use ndarray::{ArrayView2, ArrayViewMut2};

/// What voicefx.c holds a pointer to: the model and its running state.
pub struct DFState {
    m: DfTract,
}

/// The model built in; [_path] and [_log_level] are not used. Null where it could not be made.
#[no_mangle]
pub unsafe extern "C" fn df_create(_path: *const c_char, atten_lim: f32, _log_level: *const c_char) -> *mut DFState {
    catch_unwind(|| {
        // As libDF's C API sets them.
        let r = RuntimeParams::default_with_ch(1)
            .with_atten_lim(atten_lim)
            .with_thresholds(-15.0, 35.0, 35.0)
            .with_post_filter(0.0)
            .with_mask_reduce(ReduceMask::MAX);
        DfTract::new(DfParams::default(), &r).ok().map(|m| Box::into_raw(Box::new(DFState { m })))
    })
    .ok()
    .flatten()
    .unwrap_or(null_mut())
}

/// The samples a call to df_process_frame takes and gives (the model's hop); 0 for a null state.
#[no_mangle]
pub unsafe extern "C" fn df_get_frame_length(st: *mut DFState) -> usize {
    st.as_ref().map(|s| s.m.hop_size).unwrap_or(0)
}

/// One hop of -1..1 floats from [input] into [output]; on any failure the input is passed through.
#[no_mangle]
pub unsafe extern "C" fn df_process_frame(st: *mut DFState, input: *mut f32, output: *mut f32) -> f32 {
    let Some(state) = st.as_mut() else { return 0.0 };
    let n = state.m.hop_size;
    // A panic must not cross into C: caught here, and counted as a failure.
    let done = catch_unwind(AssertUnwindSafe(|| {
        let i = ArrayView2::from_shape_ptr((1, n), input as *const f32);
        let o = ArrayViewMut2::from_shape_ptr((1, n), output);
        state.m.process(i, o).ok()
    }));
    match done {
        Ok(Some(snr)) => snr,
        _ => {
            std::ptr::copy_nonoverlapping(input, output, n);
            0.0
        }
    }
}

/// Frees a state df_create made; null is passed over.
#[no_mangle]
pub unsafe extern "C" fn df_free(st: *mut DFState) {
    if !st.is_null() {
        drop(Box::from_raw(st));
    }
}
