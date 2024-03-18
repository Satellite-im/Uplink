#![allow(clippy::type_complexity)]
// Dioxus components for [heroicons](https://heroicons.com/)
//
// MIT License
//
// Copyright (c) 2020 Refactoring UI Inc.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// This library provides two components. The [`Icon`] component produces the
// SVG for a heroicon. The [`IconButton`] component wraps the icon with a
// HTML `button`.
//
// In your own components, you can call them like this:
//
// ```rust
// use dioxus::prelude::*;
// use dioxus_heroicons::{Icon, IconButton, solid::Shape};
//
// #[component]
// fn DeleteButton( foo: u8) -> Element {
//     let onclick = move |evt| {
//         // Delete a thing
//     };
//     let disabled = if *foo < 42 { true } else { false };
//     rsx! {
//         IconButton {
//             onclick: onclick,
//             class: "some-css-class",
//             title: "Delete it",
//             disabled: disabled,
//             size: 30,
//             icon: Shape::Trash,
//         }
//     })
// }
//
// fn PointsRight() -> Element {
//     rsx! {
//         Icon {
//             icon: Shape::ArrowRight,
//             fill: "blue",
//         }
//     })
// }
// ```
//
// Check out https://jkelleyrtp.github.io/icon-chooser/ for an icon chooser
// that shows you all the solid icons and lets you copy the relevant
// component code to the clipboard.

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
    fn path(&self) -> Element;
}

/// The properties for the [`IconButton`] component.
#[derive(Clone)]
pub struct IconButtonProps<'a, S: IconShape> {
    aria_label: String,
    /// An optional onclick handler for the button.
    pub onclick: Option<EventHandler<MouseEvent>>,
    /// An optional class for the *button itself*.
    pub class: Option<String>,
    /// An optional title for the button element.
    pub title: Option<&'a str>,
    /// The size of the icon. This defaults to 20 pixels.
    pub size: u32,
    /// The fill color to use for the icon. This defaults to "currentColor".
    pub fill: &'a str,
    /// If this is true then the button's `disabled` attribute will be true,
    /// and this will be passed to the `Icon` when it is rendered.
    pub disabled: bool,
    /// The fill color to use when `disabled` is true. This is only relevant
    /// for solid icons. This defaults to "#9CA3AF", which is "coolGray 400"
    /// from tailwindcss.
    pub disabled_fill: &'a str,
    /// The icon shape to use.
    pub icon: S,
    /// An optional class for the `<span>` that is part of this component.
    pub span_class: Option<&'a str>,
    /// An optional class that will be passed to the [`Icon`].
    pub icon_class: Option<&'a str>,
    /// These are the child elements of the `IconButton` component.
    pub children: Option<Element>,
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
pub fn IconButton<'a, S: IconShape>(props: ReadOnlySignal<IconButtonProps<'a, S>>) -> Element {
    rsx! {
        button {
            aria_label: "{props.read().aria_label}",
            class: format_args!("{}", props.read().class.clone().unwrap_or_default()),
            title: format_args!("{}", props.read().title.unwrap_or("")),
            disabled: format_args!("{}", if props.read().disabled { "true" } else { "false" }),
            onclick: move |evt| if !props.read().disabled {
                if let Some(oc) = &props.read().onclick {
                    oc.call(evt);
                }
            },
            // Icon {
            //     {ReadOnlySignal::new(IconProps {
            //         class: props.read().icon_class,
            //         size: props.read().size,
            //         fill: props.read().fill,
            //         icon: props.read().icon.clone(),
            //         disabled: props.read().disabled,
            //         disabled_fill: props.read().disabled_fill
            //     })}
            // },
            {
                props.read().children.is_some().then(|| {
                    rsx!(
                        span {
                            class: format_args!("{}", props.read().span_class.unwrap_or("")),
                            {props.read().children.as_ref()},
                        },
                    )
                })
            }
        },
    }
}

/// The properties for the [`Icon`] component.
#[derive(Props, Clone)]
pub struct IconProps<S: IconShape + 'static> {
    /// An optional class for the `<svg>` element.
    #[props(default)]
    pub class: Option<String>,
    /// The size of the `<svg>` element. All the heroicons are square, so this
    /// will be turned into the `height` and `width` attributes for the
    /// `<svg>`. Defaults to 20.
    #[props(default = 20)]
    pub size: u32,
    /// The color to use for filling the icon. This is only relevant for solid
    /// icons. Defaults to "currentColor".
    #[props(default = "currentColor".to_string())]
    pub fill: String,
    /// The icon shape to use.
    pub icon: S,
    /// If this is true then the fill color will be the one set in
    /// `disabled_fill` instead of `fill`.
    #[props(default = false)]
    pub disabled: bool,
    /// The fill color to use when `disabled` is true. This is only relevant
    /// for solid icons. This defaults to "#9CA3AF", which is "coolGray 400"
    /// from tailwindcss.
    #[props(default = "#9CA3AF".to_string())]
    pub disabled_fill: String,
}

impl<S> PartialEq for IconProps<S>
where
    S: IconShape + 'static,
{
    fn eq(&self, other: &Self) -> bool {
        self.class == other.class
            && self.size == other.size
            && self.fill == other.fill
            && self.disabled == other.disabled
            && self.disabled_fill == other.disabled_fill
    }
}

/// Renders an `<svg>` element for a heroicon.
///
/// See the [`IconProps`] field documentation for details on the properties it
/// accepts.
#[allow(non_snake_case)]
pub fn Icon<S: IconShape>(props: IconProps<S>) -> Element {
    let fill = if props.disabled {
        props.disabled_fill.clone()
    } else {
        props.fill.clone()
    };
    rsx! {
        svg {
            class: format_args!("{}", props.class.clone().unwrap_or("".to_string())).to_string(),
            height: format_args!("{}", props.size),
            width: format_args!("{}", props.size),
            view_box: format_args!("{}", props.icon.view_box()),
            fill: "{fill}",
            {props.icon.path()},
        }
    }
}
