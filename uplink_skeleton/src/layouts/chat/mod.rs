use ui_kit::components::nav::Route;

pub mod compose;
pub mod sidebar;

#[derive(PartialEq, Clone)]
pub struct RouteInfo {
    pub routes: Vec<Route>,
    pub active: Route,
}