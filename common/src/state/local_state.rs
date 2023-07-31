use dioxus::prelude::*;
use serde::{Deserialize, Serialize};
use std::cell::{Ref, RefCell, RefMut};
use std::collections::HashSet;
use std::fmt::Display;
use std::rc::Rc;

pub type ScopeUpdate = std::sync::Arc<dyn Fn(ScopeId) + Send + Sync>;

/// A local subscription tracker
#[derive(Clone, Debug)]
pub struct LocalSubscription<T> {
    inner: Rc<RefCell<T>>,
    subscribed: Rc<RefCell<HashSet<ScopeId>>>,
}

impl<T: PartialEq + 'static> PartialEq for LocalSubscription<T> {
    fn eq(&self, other: &Self) -> bool {
        self.inner.any_cmp(&other.inner)
    }
}

impl<T: Eq + 'static> Eq for LocalSubscription<T> {}

impl<T: Serialize> Serialize for LocalSubscription<T> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        self.inner.borrow().serialize(serializer)
    }
}

impl<'de, T: Deserialize<'de> + 'static> Deserialize<'de> for LocalSubscription<T> {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let deserialize: Result<T, _> = Deserialize::deserialize(deserializer);
        match deserialize {
            Ok(inner) => Result::Ok(LocalSubscription::create(inner)),
            Err(e) => Result::Err(e),
        }
    }
}

impl<T: 'static> From<T> for LocalSubscription<T> {
    fn from(value: T) -> Self {
        LocalSubscription::create(value)
    }
}

impl<T: 'static> LocalSubscription<T> {
    pub fn create(inner: T) -> Self {
        let inner = Rc::new(RefCell::new(inner));
        Self {
            inner,
            subscribed: Default::default(),
        }
    }

    /// Give access to the value of the LocalSubscription while subscribing the component to this instance
    pub fn use_state<'a>(&self, cx: &'a ScopeState) -> &'a UseLocal<T> {
        cx.use_hook(|| {
            let id = cx.scope_id();
            self.subscribed.borrow_mut().insert(id);
            let sub = Rc::clone(&self.subscribed);
            let sub_2 = Rc::clone(&sub);
            let update_any = cx.schedule_update_any();
            UseLocal {
                inner: Rc::clone(&self.inner),
                update: Rc::new(RefCell::new({
                    move || {
                        for id in sub.borrow().iter() {
                            update_any(*id);
                        }
                    }
                })),
                drop_func: Rc::new(RefCell::new(move || {
                    sub_2.borrow_mut().remove(&id);
                })),
            }
        })
    }

    /// Give write access to the value of the LocalSubscription. Does NOT subscribe the component
    pub fn use_write_only<'a>(&self, cx: &'a ScopeState) -> &'a LocalWrite<T> {
        let update_any = cx.schedule_update_any();
        cx.use_hook(|| {
            let sub = Rc::clone(&self.subscribed);
            LocalWrite {
                inner: Rc::clone(&self.inner),
                update: Rc::new(RefCell::new({
                    move || {
                        for id in sub.borrow().iter() {
                            update_any(*id);
                        }
                    }
                })),
            }
        })
    }

    /// Write to the state without triggering an update.
    pub fn write_silent(&self) -> RefMut<T> {
        self.inner.borrow_mut()
    }

    /// This should only be used outside of components. Updates all subscribed components
    pub fn write_with_update(&self, update: ScopeUpdate) -> RefMut<T> {
        for id in self.subscribed.borrow().iter() {
            update(*id);
        }
        self.inner.borrow_mut()
    }

    pub fn replace_and_update(&self, update: ScopeUpdate, val: T) {
        for id in self.subscribed.borrow().iter() {
            update(*id);
        }
        self.inner.replace(val);
    }

    // This should only be used outside of components. This will not subscribe to any state.
    pub fn read(&self) -> Ref<T> {
        self.inner.borrow()
    }
}

/// A read/write version of the local state. This allows mutating the state and reading state.
pub struct UseLocal<T> {
    inner: Rc<RefCell<T>>,
    update: Rc<RefCell<dyn Fn()>>,
    drop_func: Rc<RefCell<dyn Fn()>>,
}

impl<T> UseLocal<T> {
    pub fn read(&self) -> Ref<T> {
        self.inner.borrow()
    }

    pub fn write(&self) -> RefMut<T> {
        (self.update.borrow())();
        self.inner.borrow_mut()
    }
}

impl<T: Display> Display for UseLocal<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.inner.borrow().fmt(f)
    }
}

impl<T> Drop for UseLocal<T> {
    /// Unsubscribe this component from the LocalState
    fn drop(&mut self) {
        (self.drop_func.borrow())();
    }
}

/// A write only version of the local state. This only allows mutating the state, not reading state because you can only access the inner type in a impl Fn(&mut T) closure.
pub struct LocalWrite<T> {
    inner: Rc<RefCell<T>>,
    update: Rc<RefCell<dyn Fn()>>,
}

impl<T> LocalWrite<T> {
    pub fn with_mut(&self, f: impl Fn(&mut T)) {
        f(&mut *self.inner.borrow_mut());
        (self.update.borrow())();
    }

    pub fn replace(&self, val: T) {
        self.inner.replace(val);
        (self.update.borrow())();
    }
}
