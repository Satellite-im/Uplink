# Components

Components are the only place in the user facing UI that we touch state, they handle formatting and rendering using state and produce a neatly organized list of components or elements. Reusable components within the application _can_ use state, but consider if the component is better placed into the UIKit where we can render without depending on state.