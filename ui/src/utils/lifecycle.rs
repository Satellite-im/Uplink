//use dioxus::prelude::*;

// pub fn use_on_unmount<F: FnOnce() + 'static>(cx: &ScopeState, on_unmount: F) -> &LifeCycle<F> {
//     cx.use_hook(|| LifeCycle {
//         on_unmount: Some(on_unmount),
//     })
// }
//
pub struct LifeCycle<D: FnOnce()> {
    on_unmount: Option<D>,
}

impl<D: FnOnce()> Drop for LifeCycle<D> {
    fn drop(&mut self) {
        let f = self.on_unmount.take().unwrap();
        f();
    }
}
