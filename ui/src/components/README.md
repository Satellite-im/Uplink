# Components

Components are one of the only place in the user facing UI that we touch state, however we should try to hoist usage of state through props when they are used for simple getters, they handle formatting and rendering using state and produce a neatly organized list of components or elements. Reusable components within the application _can_ use state, but consider if the component is better placed into the UIKit where we can render without depending on state.
