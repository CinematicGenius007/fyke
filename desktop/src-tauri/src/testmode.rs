//! Test mode, as gui/Sources/Reader/TestMode.swift reads it: `FYKE_SCREEN` opens one
//! screen, `FYKE_KEYS` plays key presses and then quits, `FYKE_SNAPSHOT` saves a picture,
//! `FYKE_HEADLESS` keeps all of it out of sight. The UI gets every `FYKE_` variable,
//! since some screens take their own (`FYKE_SNAPSHOT_DELAY` and the like).

use std::collections::BTreeMap;

pub fn variables(all: impl Iterator<Item = (String, String)>) -> BTreeMap<String, String> {
    all.filter(|(name, _)| name.starts_with("FYKE_")).collect()
}

/// A headless run never shows a window, so it cannot take focus from the person at the computer.
pub fn headless() -> bool {
    std::env::var_os("FYKE_HEADLESS").is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_fyke_variables_reach_the_ui() {
        let all = [("FYKE_SCREEN", "settings"), ("HOME", "/h"), ("FYKE_KEYS", "j j"), ("PATH", "/bin")];
        let seen = variables(all.iter().map(|(k, v)| (k.to_string(), v.to_string())));
        assert_eq!(seen.keys().collect::<Vec<_>>(), ["FYKE_KEYS", "FYKE_SCREEN"]);
    }
}
