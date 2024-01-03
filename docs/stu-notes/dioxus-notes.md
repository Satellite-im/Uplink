> dioxus 
---

# docs
- [guide](https://dioxuslabs.com/guide/index.html)
- [reference](https://dioxuslabs.com/reference/index.html)
- [rustdoc](https://docs.rs/dioxus/0.2.4/dioxus/)

# Overview
- good web support 
- least support for mobile
- limited support for desktop

# Hello World
- import `dioxus::prelude::*`
- call `dioxus::desktop::launch()`
- pass it a function that takes a `Scope` and returns an `Element`
- the `Scope object 
    + controls how the component renders and stores data. has a `render` function

# Describing the UI
## Intro
- declare the UI and declare how the state should change when the user triggers an event
- use `Container` like a vector
- use `rsx!` macro and pass it a list of `tag {}` patterns
- can pass `String` or `&str` to `rsx!`
- attributes
    ```
    rsx!(
        div {
            hidden: "true",
            background_color: "blue",
            class: "card color-{mycolor}"
        }
    )
    ```
- can also use custom attributes: "customAttr": "value"
- attributes must occur before child elements
- listeners: a special attribute that always starts with "on" and accepts closures
## Conditional Rendering
- make the `app` function return a different UI depending on the `Scope`
- can nest RSX
    ```
    let screen = match logged_in {
        true => rsx!(DashboardScreen {}),
        false => rsx!(LoginScreen {})
    };

    cx.render(rsx!{
        Navbar {}
        screen,
        Footer {}
    })
    ```
- boolean mapping
    + turn a boolean into an Option where the Some value is returned by a closure
    ```user_name.map(|name| rsx!("Hello {name}"))```
## Conditional Lists and Keys
- `names.iter().map(|name| rsx!( li {"{name}"}))` 
- don't call `collect()` - Dioxus will consume the iterator in the `render` call
- each item in a list must be uniquely identifiable. add a `key` field to each list element so that less items are re-rendered - only items that have changed
    + if no `key` is specified, Dioxus will use the item's index in the list
- keys must be unique among siblings
- don't generate keys on the fly
- if a key is passed to a custom component, it won't receive the key as a property. so if your component needs an ID, you have to give it an additional property
- use property `dangerous_inner_html` to include html directly
- boolean attributes, such as `hidden` are true if they are present. giving them a value of `false` in Dioxus will caus them to be removed
- `prevent_default` on event and EventHandlers is not available in Desktop. but can use `prevent_default` attribute. 

- # Components
- group elements to forma  component 
- a component is a special function that takes input properties and outputs an Element
## Props
- a generic within a `Scope`: `fn SomeButton(cx: Scope<SomeButtonProps>) -> Element`
- `SomeButtonProps` needs to `#[derive(PartialEq, Props)]`
- access from with `SomeButton` like this: `cx.props.struct_field`
- use `SomeButton` from with an RSX liek this: `rsx!(SomeButton { field_name: field_value })`
- the `App` component takes `()` as Props. that is, `Scope` equals `Scope<()>`
- Props can be include references.
- Dioxus uses "memoization" to determine if an owned Prop needs to be re-rendered
- for borrowed props, needs to check the parent Prop
- use the `#[inline_props]` macro to that a prop can be passed as an argument rather than having to define a struct and put it in a Scope. 
## Children field
- give a prop a field called `children: Element<'a>` and it will render automatically. see docs.
## thinking in Reactively
- Dioxus has a VirtualDom
- update dataflow graph as follows
    + `Scope.use_hook()` returns a `&mut T` which can be modified. then need to call `Scope.needs_update()`
- for global state, use `Scope.provide_context` and `Scope.consume_context` followed by `schedule_update_any`
- to override the memoization strategy for components, implement your own PartialEq
- Props that have lifetimes will always be re-rendered

# Adding Interactivity
- need to change state dynamically 
- use a `hook` to store state in a component
    + `use_state`
    + `set_post`
- use listeners
    + `onclick`
    ```
    let (post, set_post) = use_state(&cx, || PostData::new());
    cx.render(rsx!(
        button {
            onclick: move|_| set_post(PostData::random())
            "Generate a Random Post"
        }
        Post { props: &post }
    ))
    ```
- use `Futures` and `Coroutines`
## Event handlers
- call `cancel_bubble()` to make an event stop propagating
- can use `prevent_default: "onclick"` to prevetn default behavior for a handler
## hooks
- super nasty because it's an array that gets dynamically appended to. needs to be called in order
- `use_hook(..)` returna a `&mut T`
    + may need to call `&*ctx.use_hook` to get a `&T`
    + can use `&Cell` to let you replace a value through interior mutability
- don't use hooks inside of a hook
- don't call `use_` functions out of order
- don't call `use_` functions inside of loops or conditionals
- use hooks to update state
    ```
    let name = use_state(&ctx, || ...);
    cx.render(rsx!(
        button { onclick: move |_| name.set("foo"), }
    ))
    ```
    + here, would need to use Deref to access the value. ex: `*name`
- more hooks provided by the Dioxus-Hooks package
## use_state
- good for cheaply cloneable state like numbers and strings
- basically returns a Rc<T>. has some functions
    + `.current()` returns the current value
    + `.setter()`
    + `.modify(|x| x + 1)`
    + `.with_mut(|x| *x += 1)`
    + `.make_mut()`
## use_ref
- good for managing complex data local to the component
    + a Scope can take UseRef as a type
- basically returns a Rc<RefCell<T>>. has some functions
    + `read()`. can call `read().iter()` 
    + `write()`. can call `write().push(val)`
    + `write_silent()` wont' re-render the component when updated
## user input 
- controlled inputs
    + user input updates the state
    + use one call to `use_state` per input
- uncontrolled inputs
    + attach on `oninput` handler

# Managing State
- local or global state may be stored within the Dioxus VirtualDom
- local state
    + try to have each Prop manage its own state. reduces re-rendering. refactors the "view" layer out of the data model
    + storing all the state inside of a single `use_ref` might cause issues with borrowing. can instead use multiple `use_state`s 
    + use `im_rc:HashMap` instead of HashMap within a `use_state`
- global state
    + if the app gets big enough, may need global state. use the context API for this
    + in a parent element use `provide_context`. uses the NewType pattern
    + in a child element call `consume_context` or `use_hook` which can cache the result
    + consume_context clones the Context. can wrap the Context in an Rc or Arc to make this cheaper. 
- lifting state: `lift-up`
    + pass the same `use_state` (cloned) to child components
- fanning out: `fan-out`
    + apparently you can get global state in a wrapper component via `use_read`

# important Types
- Container
- Element: an alias for Option<VNode>
- Scope
- Props

# important functions
- use_state
- use_ref
- use_read
- use_context
- use_context_provider
- provide_context
- consume_context or preferably use_hook