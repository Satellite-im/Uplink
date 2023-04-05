use kit::components::nav::Route;

pub mod compose;
pub mod create_group;
pub mod sidebar;
pub mod welcome;

#[derive(PartialEq, Clone)]
pub struct RouteInfo {
    pub routes: Vec<Route>,
    pub active: Route,
}
