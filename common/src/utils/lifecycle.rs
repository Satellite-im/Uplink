use dioxus::prelude::*;

pub struct LifeCycle<D: FnOnce()> {
    ondestroy: Option<D>,
}

/// It works like a useEffect hook, but it will be called only once
/// when the component is mounted
/// and when the component is unmounted
pub fn use_component_lifecycle<C: FnOnce() + 'static, D: FnOnce() + 'static>(
    
    create: C,
    destroy: D,
) -> &LifeCycle<D> {
    cx.use_hook(|| {
        cx.spawn(async move {
            // This will be run once the component is mounted
            std::future::ready::<()>(()).await;
            create();
        });
        LifeCycle {
            ondestroy: Some(destroy),
        }
    })
}

impl<D: FnOnce()> Drop for LifeCycle<D> {
    fn drop(&mut self) {
        let f = self.ondestroy.take().unwrap();
        f();
    }
}
