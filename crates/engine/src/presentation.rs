//! Local display handoff. Never replicated or included in world snapshots.
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    time::{Duration, Instant},
};
use uuid::Uuid;

const START_TIMEOUT: Duration = Duration::from_secs(35);

struct Session {
    parent: u64,
    child: Option<u64>,
    token: String,
    started: Instant,
    active: bool,
}

#[derive(Default)]
pub struct Bridge {
    session: Option<Session>,
    retired: HashSet<u64>,
}

#[derive(Default)]
pub struct Change {
    pub notices: Vec<(u64, Value)>,
    pub stop_input: bool,
}

impl Bridge {
    pub fn permits_input(&self, id: u64) -> bool {
        !self.retired.contains(&id)
            && self
                .session
                .as_ref()
                .is_none_or(|s| s.active && s.child == Some(id))
    }

    pub fn request(
        &mut self,
        id: u64,
        body: &Value,
        now: Instant,
    ) -> Result<(Value, Change), &'static str> {
        match body["action"].as_str().unwrap_or("") {
            "begin" => {
                if self.session.is_some() || self.retired.contains(&id) {
                    return Err("A display switch is already in progress");
                }
                let token = Uuid::new_v4().to_string();
                self.session = Some(Session {
                    parent: id,
                    child: None,
                    token: token.clone(),
                    started: now,
                    active: false,
                });
                Ok((
                    json!({"token":token}),
                    Change {
                        stop_input: true,
                        ..Default::default()
                    },
                ))
            }
            "attach" => {
                let s = self.session.as_mut().ok_or("Display switch expired")?;
                if body["token"] != s.token
                    || id == s.parent
                    || s.child.is_some()
                    || self.retired.contains(&id)
                {
                    return Err("Invalid display handoff");
                }
                s.child = Some(id);
                Ok((json!({"token":s.token}), Change::default()))
            }
            "ready" => {
                let s = self.session.as_mut().ok_or("Display switch expired")?;
                if body["token"] != s.token || s.child != Some(id) || s.active {
                    return Err("Invalid display handoff");
                }
                s.active = true;
                let notices = vec![
                    (
                        s.parent,
                        json!({"kind":"presentation_state","state":"vr","token":s.token,"control":false}),
                    ),
                    (
                        id,
                        json!({"kind":"presentation_state","state":"vr","token":s.token,"control":true}),
                    ),
                ];
                Ok((
                    json!({}),
                    Change {
                        notices,
                        stop_input: true,
                    },
                ))
            }
            "stop" => {
                let s = self
                    .session
                    .as_ref()
                    .ok_or("Display switch already ended")?;
                if body["token"] != s.token || (id != s.parent && s.child != Some(id)) {
                    return Err("Invalid display handoff");
                }
                // A bounded diagnostic from our local display, not shared world content.
                let message: String = body["message"]
                    .as_str()
                    .unwrap_or("")
                    .chars()
                    .take(240)
                    .collect();
                Ok((json!({}), self.finish(&message)))
            }
            _ => Err("Unknown display action"),
        }
    }

    fn finish(&mut self, message: &str) -> Change {
        let Some(s) = self.session.take() else {
            return Change::default();
        };
        let mut notices = vec![(
            s.parent,
            json!({"kind":"presentation_state","state":"desktop","token":s.token,"control":true,"message":message}),
        )];
        if let Some(child) = s.child {
            self.retired.insert(child);
            notices.push((child, json!({"kind":"presentation_state","state":"desktop","token":s.token,"control":false,"shutdown":true})));
        }
        Change {
            notices,
            stop_input: true,
        }
    }

    pub fn closed(&mut self, id: u64) -> Change {
        let change = if self
            .session
            .as_ref()
            .is_some_and(|s| s.parent == id || s.child == Some(id))
        {
            self.finish("VR display disconnected")
        } else {
            Change::default()
        };
        self.retired.remove(&id);
        change
    }

    pub fn expire(&mut self, now: Instant) -> Change {
        if self
            .session
            .as_ref()
            .is_some_and(|s| !s.active && now.duration_since(s.started) >= START_TIMEOUT)
        {
            self.finish("VR startup timed out")
        } else {
            Change::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(
        bridge: &mut Bridge,
        id: u64,
        action: &str,
        token: &str,
        now: Instant,
    ) -> Result<(Value, Change), &'static str> {
        bridge.request(id, &json!({"action":action,"token":token}), now)
    }

    #[test]
    fn handoff_has_one_input_owner_and_retired_child_cannot_resume() {
        let mut b = Bridge::default();
        let now = Instant::now();
        let (reply, change) = request(&mut b, 1, "begin", "", now).unwrap();
        let token = reply["token"].as_str().unwrap();
        assert!(change.stop_input);
        assert!(!b.permits_input(1));
        assert!(!b.permits_input(2));
        assert!(request(&mut b, 3, "attach", "wrong", now).is_err());
        request(&mut b, 2, "attach", token, now).unwrap();
        assert!(request(&mut b, 3, "ready", token, now).is_err());
        request(&mut b, 2, "ready", token, now).unwrap();
        assert!(b.permits_input(2));
        assert!(!b.permits_input(1));
        request(&mut b, 1, "stop", token, now).unwrap();
        assert!(b.permits_input(1));
        assert!(!b.permits_input(2));
        assert!(request(&mut b, 2, "ready", token, now).is_err());
        assert!(!b.closed(2).stop_input); // Late close must not stop desktop input.
    }

    #[test]
    fn cancelled_and_timed_out_attempts_cannot_take_over_the_next_attempt() {
        let mut b = Bridge::default();
        let now = Instant::now();
        let (old, _) = request(&mut b, 1, "begin", "", now).unwrap();
        assert!(request(&mut b, 1, "begin", "", now).is_err());
        assert!(b.expire(now + START_TIMEOUT).stop_input);
        let (new, _) = request(&mut b, 1, "begin", "", now + START_TIMEOUT).unwrap();
        assert_ne!(old["token"], new["token"]);
        assert!(request(&mut b, 2, "attach", old["token"].as_str().unwrap(), now).is_err());
        assert!(request(&mut b, 1, "stop", old["token"].as_str().unwrap(), now).is_err());
        assert!(!b.permits_input(1));
    }

    #[test]
    fn losing_either_display_ends_the_handoff() {
        for closed in [1, 2] {
            let mut b = Bridge::default();
            let now = Instant::now();
            let (reply, _) = request(&mut b, 1, "begin", "", now).unwrap();
            request(&mut b, 2, "attach", reply["token"].as_str().unwrap(), now).unwrap();
            let change = b.closed(closed);
            assert!(change.stop_input);
            assert!(
                change
                    .notices
                    .iter()
                    .any(|(id, v)| *id == 1 && v["state"] == "desktop")
            );
        }
    }
}
