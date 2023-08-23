


// use crate::UPLINK_ROUTES;


pub mod compose;
pub mod create_group;
pub mod edit_group;
pub mod group_users;
pub mod pinned_messages;
pub mod sidebar;
pub mod welcome;

// #[derive(PartialEq, Clone)]
// pub struct RouteInfo {
//     pub routes: Vec<Route>,
// }

// impl Default for RouteInfo {
//     fn default() -> Self {
//         let chat_route = Route {
//             to: UPLINK_ROUTES.chat,
//             name: get_local_text("uplink.chats"),
//             icon: Icon::ChatBubbleBottomCenterText,
//             ..Route::default()
//         };
//         let settings_route = Route {
//             to: UPLINK_ROUTES.settings,
//             name: get_local_text("settings.settings"),
//             icon: Icon::Cog6Tooth,
//             ..Route::default()
//         };
//         let friends_route = Route {
//             to: UPLINK_ROUTES.friends,
//             name: get_local_text("friends.friends"),
//             icon: Icon::Users,
//             with_badge: None,
//             loading: None,
//         };
//         let files_route = Route {
//             to: UPLINK_ROUTES.files,
//             name: get_local_text("files.files"),
//             icon: Icon::Folder,
//             ..Route::default()
//         };
//         let routes = vec![
//             chat_route.clone(),
//             files_route,
//             friends_route,
//             settings_route,
//         ];
//         Self { routes }
//     }
// }
