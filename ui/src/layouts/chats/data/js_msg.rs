use serde::{Deserialize, Serialize};
use uuid::Uuid;

// this is used to communicate with javascript. the conversation id
// is included to be sure that events are handled from the correct conversation
#[derive(Serialize, Deserialize, Debug)]
pub enum JsMsg {
    // ex json: "{\"Add\":{\"msg_id\":\"a53630d6-7200-4877-ae02-d50dd2c45c99\",\"conv_id\":\"ece192c1-a9b7-4dc8-aafa-dfef03ebe62b\"}}"
    Add { msg_id: Uuid, key: Uuid },
    Remove { msg_id: Uuid, key: Uuid },
    Top { key: Uuid },
    Bottom { key: Uuid },
}

#[cfg(test)]
mod test {
    use super::*;

    // this test was used to determine how JsMsg is serialized.
    #[test]
    fn js_msg_test1() {
        let m = JsMsg::Add {
            msg_id: Uuid::new_v4(),
            key: Uuid::new_v4(),
        };
        let _s = serde_json::to_string(&m).unwrap();
        //assert_eq!(_s, "".to_string());
        assert!(true);
    }
}
