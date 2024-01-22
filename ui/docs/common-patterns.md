# Guidelines

This document provides guidelines for developers to follow when contributing to the project. It outlines common patterns and steps for completing common tasks, such as adding a new component or creating a new feature that spans the renderer, state, and warp.

## Basic Flow

This is the pattern you'll follow, with obvious exceptions, when adding a simple feature to the application. This is a high-level overview of the process; for more detailed information, see the sections below.


### 1. Create a new branch
First, you'll want to start by working off your own branch, even if you're working on a feature already in progress. This will allow you to work on your feature without worrying about conflicts with other developers. You can create a new branch by running the following command:

    git checkout -b <branch-name>

### 2. Create a new component
Next, you'll want to create your UI component. It's a simple process involving as little as one file and adding one line of code. A Rust file and an associated SCSS file more often represent it. In the future, you may also see other files grouped within the new component or element, such as a test file. Explore the existing components to get a feel for how they're structured. Try to place your new component in the best logical space now, and only branch out into an entirely new parent directory if necessary.

**Create a new Rust file**

    touch src/components/<component-name>.rs

This file represents the visual portion of your new feature. It will be responsible for rendering the component and handling any events. It will also be responsible for dispatching any actions sent to the state layer. Lastly, you should expect all your user interactions to happen within this component. Components should **NOT include async tasks** as they cannot block the main thread. If you need to perform an async task, you should dispatch an action to the state layer and handle it there. The component should then have a loading state if it expects data that is async; it should self-induce this state when firing an async action and return to a normal state when the async action is complete (or the data we expect has loaded, which is more common then watching the actual task).

*NOTE:* Everything you put inside this component will be run every time this element is rendered. Again, do not put any async tasks here; only use this for rendering and handling events.

**Create a new SCSS file**

    touch src/styles/components/<component-name>.scss

This file represents the styling for your new feature. It will be responsible for defining the styles for your component and any child elements. 

**Add the new component to the `components` module**

    // src/components/mod.rs
    pub mod <component-name>;

**That's it!**
You will likely want to use your component, which can be done by simply importing the component and inside of a parent component or layout (more details on layouts below) and adding the element to the render macro. (e.g. `rsx!(MyComponent {})`).

You should refer to the Dioxus docs for more information on creating components.

### 3. Create a new action
If you want to do something with your new component, you must create a new action to dispatch to the state layer.

You can find the actions module here: `src/state/actions.rs`

**Create a new action**

    pub enum Action {
        ..
        <action-name>,
    }

You'll want to add your new action inside the Action enum. This action can be used to mutate state and perform async tasks. Here, you can provide optional expected data required to complete a given action.

### 4. Creating a new mutation or getter

Inside the `src/state/` directory, you will see several parts of the application state, represented by modules. In most cases, you can add a new mutation or getter to an existing module, but if you feel it's necessary, you can create a new module. These files should store any accompanying data you're adding to state for your new feature. You may only use a single getter, mutation, or a combination. Inside this same file, you'll want to handle your new Action in the `mutate` fn, where we match all available actions. Here, you call your new mutations when the action is called.  

You should avoid writing your mutation functions or getters directly in the `mod.rs` file if you can. Instead, you should try to organize them into one of the existing files to implement a given section within state, for example, in the UI section of state (represented by the UI Struct). We have implemented custom getters and mutations here. This way, the UI state provides its own getters and mutations used by the rest of the application. This is a good pattern to follow as it keeps the state layer clean and easy to read.

Getters can also be added here but should not be used to mutate state. They should only be used to retrieve data from state or compute data based on state. Getters can be async.

Now, inside your component, you can call your getters by importing state (`let state = use_shared_state::<State>(cx)?;`), then call `state.read().

### 5. Create a new layout

Sometimes, you're working on huge features and want to add a whole new "page" or layout in the application. These are located under the Layouts folder. Ideally, layouts should contain minimal styling and use common organizational patterns to keep the layout clean and easy to read. You can find the layouts module here: `src/layouts/mod.rs`. Your layout may mutate or read state; however, it should leave all the interaction from the user to the component. The layout should only be responsible for rendering the component and any other elements required to make the layout work.

## Other Common Patterns

### Adding or modifying the `kit`

You should avoid modifying the kit to fit a specific need. Instead, use this resource as a tool and only add new functionality or components that will be useful for Satellite, extension developers, and perhaps even others using Dioxus. This also keeps kit components and elements very reusable and

### Adding a new warp hook

// TODO
