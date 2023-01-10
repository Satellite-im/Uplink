//! Dioxus components for [heroicons](https://heroicons.com/)
//!
//! This library provides two components. The [`Icon`] component produces the
//! SVG for a heroicon. The [`IconButton`] component wraps the icon with a
//! HTML `button`.
//!
//! In your own components, you can call them like this:
//!
//! ```rust
//! use dioxus::prelude::*;
//! use dioxus_heroicons::{Icon, IconButton, solid::Shape};
//!
//! #[inline_props]
//! fn DeleteButton(cx: Scope, foo: u8) -> Element {
//!     let onclick = move |evt| {
//!         // Delete a thing
//!     };
//!     let disabled = if *foo < 42 { true } else { false };
//!     cx.render(rsx! {
//!         IconButton {
//!             onclick: onclick,
//!             class: "some-css-class",
//!             title: "Delete it",
//!             disabled: disabled,
//!             size: 30,
//!             icon: Shape::Trash,
//!         }
//!     })
//! }
//!
//! fn PointsRight(cx: Scope) -> Element {
//!     cx.render(rsx! {
//!         Icon {
//!             icon: Shape::ArrowRight,
//!             fill: "blue",
//!         }
//!     })
//! }
//! ```
//!
//! Check out https://jkelleyrtp.github.io/icon-chooser/ for an icon chooser
//! that shows you all the solid icons and lets you copy the relevant
//! component code to the clipboard.

/// This module contains all the outline icon shapes.
pub mod outline {
    include!(concat!(env!("OUT_DIR"), "/outline.rs"));
}
/// This module contains all the solid icon shapes.
pub mod solid {
    include!(concat!(env!("OUT_DIR"), "/solid.rs"));
}

use dioxus::{events::MouseEvent, prelude::*};

/// This trait is used to abstract the icon shape so you can use shapes from
/// the [`outline`] or [`solid`] modules for any property that accepts a
/// shape.
pub trait IconShape: Clone + std::fmt::Debug {
    fn view_box(&self) -> &str;
    fn path(&self) -> LazyNodes;
}

/// The properties for the [`IconButton`] component.
#[derive(Props)]
pub struct IconButtonProps<'a, S: IconShape> {
    /// An optional onclick handler for the button.
    #[props(default, strip_option)]
    pub onclick: Option<EventHandler<'a, MouseEvent>>,
    #[props(default, strip_option)]
    /// An optional class for the *button itself*.
    pub class: Option<&'a str>,
    /// An optional title for the button element.
    #[props(default, strip_option)]
    pub title: Option<&'a str>,
    /// The size of the icon. This defaults to 20 pixels.
    #[props(default = 20)]
    pub size: u32,
    /// The fill color to use for the icon. This defaults to "currentColor".
    #[props(default = "currentColor")]
    pub fill: &'a str,
    /// If this is true then the button's `disabled` attribute will be true,
    /// and this will be passed to the `Icon` when it is rendered.
    #[props(default = false)]
    pub disabled: bool,
    /// The fill color to use when `disabled` is true. This is only relevant
    /// for solid icons. This defaults to "#9CA3AF", which is "coolGray 400"
    /// from tailwindcss.
    #[props(default = "#9CA3AF")]
    pub disabled_fill: &'a str,
    /// The icon shape to use.
    pub icon: S,
    /// An optional class for the `<span>` that is part of this component.
    #[props(default, strip_option)]
    pub span_class: Option<&'a str>,
    /// An optional class that will be passed to the [`Icon`].
    #[props(default, strip_option)]
    pub icon_class: Option<&'a str>,
    /// These are the child elements of the `IconButton` component.
    #[props(default, strip_option)]
    pub children: Option<Element<'a>>,
}

/// Renders a `<button>` containing an SVG icon.
///
/// This component will generate HTML like this:
///
/// ```html
/// <button>
///   <svg ...>
///   <span>
///     Child elements go here
///   </span>
/// </button>
/// ```
///
/// See the [`IconButtonProps`] field documentation for details on the
/// properties it accepts.
///
/// The child elements are optional, and are there so you can add some
/// additional text or other HTML to the button.
#[allow(non_snake_case)]
pub fn IconButton<'a, S: IconShape>(cx: Scope<'a, IconButtonProps<'a, S>>) -> Element<'a> {
    cx.render(rsx! {
        button {
            onclick: move |evt| if !cx.props.disabled {
                if let Some(oc) = &cx.props.onclick {
                    oc.call(evt);
                }
            },
            class: format_args!("{}", cx.props.class.unwrap_or("")),
            title: format_args!("{}", cx.props.title.unwrap_or("")),
            disabled: format_args!("{}", if cx.props.disabled { "true" } else { "false" }),
            Icon {
                ..IconProps {
                    class: cx.props.icon_class,
                    size: cx.props.size,
                    fill: cx.props.fill,
                    icon: cx.props.icon.clone(),
                    disabled: cx.props.disabled,
                    disabled_fill: cx.props.disabled_fill
                },
            },
            span {
                class: format_args!("{}", cx.props.span_class.unwrap_or("")),
                cx.props.children.as_ref(),
            },
        },
    })
}

/// The properties for the [`Icon`] component.
#[derive(PartialEq, Props)]
pub struct IconProps<'a, S: IconShape> {
    /// An optional class for the `<svg>` element.
    #[props(default)]
    pub class: Option<&'a str>,
    /// The size of the `<svg>` element. All the heroicons are square, so this
    /// will be turned into the `height` and `width` attributes for the
    /// `<svg>`. Defaults to 20.
    #[props(default = 20)]
    pub size: u32,
    /// The color to use for filling the icon. This is only relevant for solid
    /// icons. Defaults to "currentColor".
    #[props(default = "currentColor")]
    pub fill: &'a str,
    /// The icon shape to use.
    pub icon: S,
    /// If this is true then the fill color will be the one set in
    /// `disabled_fill` instead of `fill`.
    #[props(default = false)]
    pub disabled: bool,
    /// The fill color to use when `disabled` is true. This is only relevant
    /// for solid icons. This defaults to "#9CA3AF", which is "coolGray 400"
    /// from tailwindcss.
    #[props(default = "#9CA3AF")]
    pub disabled_fill: &'a str,
}

/// Renders an `<svg>` element for a heroicon.
///
/// See the [`IconProps`] field documentation for details on the properties it
/// accepts.
#[allow(non_snake_case)]
pub fn Icon<'a, S: IconShape>(cx: Scope<'a, IconProps<S>>) -> Element<'a> {
    let fill = if cx.props.disabled {
        cx.props.disabled_fill
    } else {
        cx.props.fill
    };
    cx.render(rsx! {
        svg {
            class: format_args!("{}", cx.props.class.unwrap_or("")),
            height: format_args!("{}", cx.props.size),
            width: format_args!("{}", cx.props.size),
            view_box: format_args!("{}", cx.props.icon.view_box()),
            fill: "{fill}",
            cx.props.icon.path(),
        }
    })
}
