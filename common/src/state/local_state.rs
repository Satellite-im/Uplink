#![allow(non_snake_case)]

use dioxus::prelude::*;
use std::cell::{Ref, RefCell, RefMut};
use std::collections::HashSet;
use std::fmt::Display;
use std::rc::Rc;

#[derive(Clone)]
pub struct LocalSubscription<T> {
    inner: Rc<RefCell<T>>,
    subscribed: Rc<RefCell<HashSet<ScopeId>>>,
}

impl<T> PartialEq for LocalSubscription<T> {
    fn eq(&self, other: &Self) -> bool {
        true //TODO
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

    pub fn use_state<'a>(&self, cx: &'a ScopeState) -> &'a UseLocal<T> {
        cx.use_hook(|| {
            let id = cx.scope_id();
            self.subscribed.borrow_mut().insert(id);
            let sub = self.subscribed.clone();
            let update_any = cx.schedule_update_any();
            UseLocal {
                inner: self.inner.clone(),
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

    pub fn use_write_only<'a>(&self, cx: &'a ScopeState) -> &'a LocalWrite<T> {
        cx.use_hook(|| {
            let update_any = cx.schedule_update_any();
            let sub = self.subscribed.clone();
            LocalWrite {
                inner: self.inner.clone(),
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

    // This should only be used outside of components. This will not subscribe to any state.
    pub fn write(&self) -> RefMut<T> {
        //(self.update)();
        self.inner.borrow_mut()
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
}
